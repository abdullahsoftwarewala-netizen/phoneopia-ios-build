package com.phoneopia.phoneopia_mobile

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.net.InetSocketAddress
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private var deepLinkChannel: MethodChannel? = null
    // ── Raw PCM voice pipeline for Bluetooth-only Nearby calls ──────────
    // WebRTC needs a real IP link (WiFi Direct) — Bluetooth Classic/BLE has
    // none, so a Nearby call that never upgrades to WiFi has no way to carry
    // audio at all. This is a minimal, uncompressed 16kHz mono PCM
    // capture/playback pipeline instead, streamed as raw byte chunks over
    // Nearby's own byte-payload channel (see NearbyService on the Dart
    // side) — no IP networking involved, works over plain Bluetooth.
    private val nearbyAudioTag = "PhoneopiaNearbyAudio"
    // "POU1" marks a G.711 mu-law payload inside the existing Nearby audio
    // envelope. Four-byte magic keeps this backward-compatible with older
    // raw-PCM clients instead of guessing from a single sample byte.
    private val muLawMagic = byteArrayOf(0x50, 0x4F, 0x55, 0x01)
    // Telephone-grade PCM halves the Bluetooth bandwidth versus 16kHz while
    // keeping speech clear. Nearby BYTES was dropping the old ~32KB/s stream.
    private val sampleRate = 8000
    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var recordThread: Thread? = null
    private var playbackThread: Thread? = null
    // Keep enough audio to absorb short Nearby/Android delivery bursts. A
    // three-frame queue frequently underruns and cuts the caller's words.
    private val playbackQueue = LinkedBlockingDeque<ByteArray>(8)
    @Volatile private var recording = false
    @Volatile private var playbackRunning = false
    private var capturedPacketCount = 0
    private var playbackPacketCount = 0
    private val mainHandler = Handler(Looper.getMainLooper())
    private var captureEventSink: EventChannel.EventSink? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableLockScreenCallUi()
        handleDeepLink(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleDeepLink(intent)
    }

    private fun handleDeepLink(intent: Intent?) {
        val uri = intent?.data?.toString() ?: return
        deepLinkChannel?.invokeMethod("onDeepLink", uri)
    }

    private fun enableLockScreenCallUi() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "phoneopia/secure")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enable" -> {
                        window.setFlags(
                            WindowManager.LayoutParams.FLAG_SECURE,
                            WindowManager.LayoutParams.FLAG_SECURE
                        )
                        result.success(true)
                    }
                    "disable" -> {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(messenger, "phoneopia/call")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "wakeForIncomingCall" -> {
                        enableLockScreenCallUi()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // OEM autostart/battery-management screens — the standard Android
        // ignoreBatteryOptimizations permission does nothing on ColorOS
        // (Oppo/Realme), FuntouchOS/OriginOS (Vivo), or MIUI (Xiaomi): those
        // skins have their own SEPARATE background-app killer that's off by
        // default and silently drops FCM wake-ups for apps not explicitly
        // whitelisted there. That's the root cause behind "calls/messages
        // arrive sometimes, not others" on exactly these brands — confirmed
        // against this app's own test devices (an Oppo CPH2711 and a Vivo
        // V2131). No public API for this; each OEM has its own settings
        // activity, most of which change between firmware versions, so this
        // tries a list of known component names and falls through silently
        // if none resolve on this device/build.
        MethodChannel(messenger, "phoneopia/oem_autostart")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openAutostartSettings" -> result.success(openOemAutostartSettings())
                    "manufacturer" -> result.success(Build.MANUFACTURER.lowercase())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(messenger, "phoneopia/bluetooth")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isEnabled" -> {
                        try {
                            val adapter = BluetoothAdapter.getDefaultAdapter()
                            result.success(adapter?.isEnabled == true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "enable" -> {
                        try {
                            val adapter = BluetoothAdapter.getDefaultAdapter()
                            if (adapter == null) {
                                result.success(false)
                            } else if (adapter.isEnabled) {
                                result.success(true)
                            } else {
                                // Android has required an explicit user tap on this
                                // system dialog since Android 13 — an app can never
                                // silently flip Bluetooth on for privacy reasons.
                                val intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
                                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(intent)
                                result.success(true)
                            }
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(messenger, "phoneopia/nearby_audio")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startRecording" -> {
                        startNearbyAudioRecording()
                        result.success(true)
                    }
                    "stopRecording" -> {
                        stopNearbyAudioRecording()
                        result.success(true)
                    }
                    "startPlayback" -> {
                        startNearbyAudioPlayback()
                        result.success(true)
                    }
                    "writePlayback" -> {
                        val bytes = call.arguments as? ByteArray
                        if (bytes != null) writeNearbyAudioPlayback(bytes)
                        result.success(true)
                    }
                    "stopPlayback" -> {
                        stopNearbyAudioPlayback()
                        result.success(true)
                    }
                    "setSpeaker" -> {
                        val on = call.arguments as? Boolean ?: true
                        try {
                            val am = getSystemService(AUDIO_SERVICE) as AudioManager
                            am.mode = AudioManager.MODE_IN_COMMUNICATION
                            @Suppress("DEPRECATION")
                            am.isSpeakerphoneOn = on
                        } catch (e: Exception) {}
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(messenger, "phoneopia/nearby_audio_capture")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                    captureEventSink = sink
                }
                override fun onCancel(args: Any?) {
                    captureEventSink = null
                }
            })

        // ── Bluetooth internet sharing (Android-only) ───────────────────────
        // IMPORTANT platform constraint: BluetoothPan.connect() requires
        // BLUETOOTH_PRIVILEGED, which Google never grants to third-party
        // apps — there is no public API for an app to programmatically join
        // or drive a Bluetooth PAN internet-sharing connection. What IS
        // achievable without any privileged permission: (1) classic
        // Bluetooth discovery + createBond() to pair the two specific
        // physical devices identified over the already-authenticated Nearby
        // channel, (2) deep-linking both users to the one system-settings
        // screen each side needs (sender: Bluetooth Tethering toggle;
        // receiver: the paired device's "Internet access" checkbox), and
        // (3) verifying — never assuming — that real internet became
        // reachable over that Bluetooth network path once the user has done
        // their part. This channel implements exactly those three things;
        // it does not and cannot silently establish the tunnel itself.
        MethodChannel(messenger, "phoneopia/bluetooth_sharing")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setDiscoverableName" -> {
                        val tag = call.arguments as? String
                        try {
                            val adapter = BluetoothAdapter.getDefaultAdapter()
                            if (adapter != null && tag != null) {
                                previousBtName = previousBtName ?: adapter.name
                                @Suppress("MissingPermission")
                                adapter.name = tag
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "restoreDiscoverableName" -> {
                        try {
                            val adapter = BluetoothAdapter.getDefaultAdapter()
                            val prev = previousBtName
                            if (adapter != null && prev != null) {
                                @Suppress("MissingPermission")
                                adapter.name = prev
                            }
                            previousBtName = null
                        } catch (e: Exception) {}
                        result.success(true)
                    }
                    "startClassicDiscovery" -> {
                        try {
                            startClassicBtDiscovery()
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "stopClassicDiscovery" -> {
                        try {
                            stopClassicBtDiscovery()
                        } catch (e: Exception) {}
                        result.success(true)
                    }
                    "pairDevice" -> {
                        val address = call.arguments as? String
                        try {
                            val adapter = BluetoothAdapter.getDefaultAdapter()
                            val device = if (address != null) adapter?.getRemoteDevice(address) else null
                            if (device == null) {
                                result.success(false)
                            } else if (device.bondState == BluetoothDevice.BOND_BONDED) {
                                result.success(true)
                            } else {
                                @Suppress("MissingPermission")
                                result.success(device.createBond())
                            }
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "isPaired" -> {
                        val address = call.arguments as? String
                        try {
                            val adapter = BluetoothAdapter.getDefaultAdapter()
                            val device = if (address != null) adapter?.getRemoteDevice(address) else null
                            result.success(device?.bondState == BluetoothDevice.BOND_BONDED)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "openBluetoothTetheringSettings" -> {
                        // No stable cross-OEM deep link exists straight to the
                        // Bluetooth Tethering row specifically — this opens the
                        // general tethering screen, which is the closest stable
                        // public target; the app's own UI tells the user which
                        // toggle to tap.
                        try {
                            val intent = Intent("android.settings.TETHER_SETTINGS")
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                val intent = Intent(Settings.ACTION_WIRELESS_SETTINGS)
                                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(intent)
                                result.success(true)
                            } catch (e2: Exception) {
                                result.success(false)
                            }
                        }
                    }
                    "openBluetoothSettings" -> {
                        try {
                            val intent = Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "checkBluetoothInternet" -> {
                        // Real verification, not a guess: the OS network path
                        // must actually be TRANSPORT_BLUETOOTH AND a live probe
                        // (TCP connect, matching section 7's DNS/HTTPS
                        // reachability requirement) must actually succeed
                        // before this is allowed to report true.
                        thread {
                            val ok = checkRealBluetoothInternet()
                            mainHandler.post { result.success(ok) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(messenger, "phoneopia/bluetooth_sharing_discovery")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                    discoveryEventSink = sink
                }
                override fun onCancel(args: Any?) {
                    discoveryEventSink = null
                }
            })

        // ── Deep link channel (phoneopia://chat/{username} + web /s/ links) ──
        deepLinkChannel = MethodChannel(messenger, "phoneopia/deeplink")
            .also { ch ->
                ch.setMethodCallHandler { call, result ->
                    if (call.method == "getInitialLink") {
                        result.success(intent?.data?.toString())
                    } else {
                        result.notImplemented()
                    }
                }
            }
    }

    private var previousBtName: String? = null
    private var discoveryEventSink: EventChannel.EventSink? = null
    private var discoveryReceiver: BroadcastReceiver? = null

    private fun startClassicBtDiscovery() {
        stopClassicBtDiscovery()
        val adapter = BluetoothAdapter.getDefaultAdapter() ?: return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != BluetoothDevice.ACTION_FOUND) return
                @Suppress("DEPRECATION")
                val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE) ?: return
                val name = try { device.name } catch (e: SecurityException) { null } ?: return
                mainHandler.post {
                    discoveryEventSink?.success(mapOf("name" to name, "address" to device.address))
                }
            }
        }
        discoveryReceiver = receiver
        registerReceiver(receiver, IntentFilter(BluetoothDevice.ACTION_FOUND))
        @Suppress("MissingPermission")
        adapter.startDiscovery()
    }

    private fun stopClassicBtDiscovery() {
        try {
            val adapter = BluetoothAdapter.getDefaultAdapter()
            @Suppress("MissingPermission")
            adapter?.cancelDiscovery()
        } catch (e: Exception) {}
        discoveryReceiver?.let {
            try { unregisterReceiver(it) } catch (e: Exception) {}
        }
        discoveryReceiver = null
    }

    /** Runs on a background thread — never call from the main thread. */
    private fun checkRealBluetoothInternet(): Boolean {
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val network = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(network) ?: return false
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH)) return false
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return false
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) return false
        } catch (e: Exception) {
            return false
        }
        // Live reachability probe over that network path, bound to it
        // specifically so this can't accidentally pass via a different
        // active network (e.g. mobile data quietly still up).
        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val network = cm.activeNetwork ?: return false
            val socket = network.socketFactory.createSocket()
            socket.connect(InetSocketAddress("1.1.1.1", 443), 4000)
            val reached = socket.isConnected
            socket.close()
            reached
        } catch (e: Exception) {
            false
        }
    }

    private fun startNearbyAudioRecording(attempt: Int = 0) {
        if (recording) return
        val minBuf = AudioRecord.getMinBufferSize(
            sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        val bufSize = if (minBuf > 0) minBuf * 2 else 4096
        // VOICE_COMMUNICATION gives echo cancellation, but a few ColorOS /
        // MIUI builds keep that source locked briefly after WebRTC closes.
        // Retry it first, then fall back to MIC so handoff never stays silent.
        val source = if (attempt < 3) {
            MediaRecorder.AudioSource.VOICE_COMMUNICATION
        } else {
            MediaRecorder.AudioSource.MIC
        }
        val rec: AudioRecord
        try {
            rec = AudioRecord(
                source,
                sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufSize
            )
        } catch (e: Exception) {
            Log.e(nearbyAudioTag, "AudioRecord create failed attempt=$attempt source=$source", e)
            retryNearbyAudioRecording(attempt)
            return
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            // Switching mid-call from an active WebRTC call to Nearby tears
            // down WebRTC's own VOICE_COMMUNICATION AudioRecord first, but
            // that release happens asynchronously — grabbing this one right
            // away can lose the race and come up STATE_UNINITIALIZED,
            // leaving the mic silent for the whole rest of the Nearby call
            // instead of just failing once and retrying.
            try { rec.release() } catch (e: Exception) {}
            Log.w(nearbyAudioTag, "AudioRecord uninitialized attempt=$attempt source=$source")
            retryNearbyAudioRecording(attempt)
            return
        }
        try {
            rec.startRecording()
        } catch (e: Exception) {
            Log.e(nearbyAudioTag, "AudioRecord start failed attempt=$attempt source=$source", e)
            try { rec.release() } catch (ignored: Exception) {}
            retryNearbyAudioRecording(attempt)
            return
        }
        if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            Log.w(nearbyAudioTag, "AudioRecord did not enter RECORDING attempt=$attempt source=$source")
            try { rec.release() } catch (ignored: Exception) {}
            retryNearbyAudioRecording(attempt)
            return
        }
        audioRecord = rec
        recording = true
        Log.i(nearbyAudioTag, "capture started rate=$sampleRate source=$source attempt=$attempt")
        // 500ms chunks. Live transport logs show this Bluetooth link delivers
        // about two BYTES payloads/sec; sending four 250ms payloads/sec makes
        // Google Play Services build a reliable internal queue, so speech is
        // eventually heard several seconds late. Two payloads/sec carries the
        // same 8KB/s audio but matches measured link capacity and stays live.
        // cut down how often Nearby().sendBytesPayload() gets called, but
        // live logcat during an actual Nearby call showed successful
        // payload deliveries landing only once every ~400-800ms no matter
        // what we sent — Nearby Connections' BYTES payload channel just
        // cannot sustain a real streaming rate, so at 25/sec almost every
        // chunk was being silently dropped in transit (confirmed by
        // AudioTrack logging constant "disabled due to previous underrun"
        // as playback starved between the rare packets that did arrive).
        // ~4 payloads/sec sits inside what was actually observed to get
        // through reliably — the latency tradeoff (up to ~250ms one-way) is
        // a real cost, but it's the difference between choppy-but-audible
        // and near-total silence.
        // 100ms frames go through one long-lived Nearby STREAM. This removes
        // the old 500ms capture delay and per-payload reliable queue.
        val chunkSamples = sampleRate / 10
        val chunkBytes = ByteArray(chunkSamples * 2)
        recordThread = Thread {
            while (recording) {
                val read = rec.read(chunkBytes, 0, chunkBytes.size)
                if (read > 0) {
                    // G.711 mu-law compresses every 16-bit speech sample to
                    // 8 bits. Combined with 8kHz capture this is ~8KB/s —
                    // one quarter of the original 16kHz PCM stream that
                    // intermittently saturated Nearby/BLE and went silent.
                    val chunk = encodeMuLaw(chunkBytes, read)
                    capturedPacketCount++
                    if (capturedPacketCount % 20 == 0) {
                        Log.d(nearbyAudioTag, "capture packets=$capturedPacketCount encodedBytes=${chunk.size}")
                    }
                    mainHandler.post { captureEventSink?.success(chunk) }
                }
            }
        }
        recordThread?.start()
    }

    private fun retryNearbyAudioRecording(attempt: Int) {
        if (attempt >= 8 || recording) {
            if (!recording) Log.e(nearbyAudioTag, "capture unavailable after retries")
            return
        }
        mainHandler.postDelayed({ startNearbyAudioRecording(attempt + 1) }, 250)
    }

    private fun stopNearbyAudioRecording() {
        recording = false
        try { recordThread?.join(300) } catch (e: Exception) {}
        recordThread = null
        try { audioRecord?.stop() } catch (e: Exception) {}
        try { audioRecord?.release() } catch (e: Exception) {}
        audioRecord = null
    }

    private fun startNearbyAudioPlayback(attempt: Int = 0) {
        if (playbackRunning && audioTrack?.state == AudioTrack.STATE_INITIALIZED) return
        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        // Chunks now arrive as one big ~250ms write every ~250-800ms instead
        // of a steady trickle of small ones — a buffer only 2x the device
        // minimum was sized for the old high-frequency-small-chunk pattern
        // and underran between arrivals under the new one. 4x gives enough
        // headroom to actually hold a full incoming chunk (or two) without
        // running dry while waiting on the next one.
        // Keep the device minimum without forcing the former 500ms buffer.
        val targetLowLatencyBytes = sampleRate / 5 // 100ms mono PCM16
        val bufSize = if (minBuf > 0) maxOf(minBuf, targetLowLatencyBytes) else targetLowLatencyBytes
        val track: AudioTrack
        try {
            track = AudioTrack(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
                AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build(),
                bufSize,
                AudioTrack.MODE_STREAM,
                AudioManager.AUDIO_SESSION_ID_GENERATE
            )
        } catch (e: Exception) {
            Log.e(nearbyAudioTag, "AudioTrack create failed attempt=$attempt", e)
            if (attempt < 6) mainHandler.postDelayed({ startNearbyAudioPlayback(attempt + 1) }, 250)
            return
        }
        // Same resource race as the mic side (see startNearbyAudioRecording):
        // switching mid-call from WebRTC releases its own playback AudioTrack
        // asynchronously, so grabbing one right away can come up
        // uninitialized and silently never play anything for the rest of the
        // Nearby call. Retry instead of giving up on the first miss.
        if (track.state != AudioTrack.STATE_INITIALIZED) {
            try { track.release() } catch (e: Exception) {}
            if (attempt < 6) {
                mainHandler.postDelayed({ startNearbyAudioPlayback(attempt + 1) }, 250)
            }
            return
        }
        audioTrack = track
        playbackQueue.clear()
        playbackRunning = true
        playbackThread = Thread {
            var started = false
            Log.i(nearbyAudioTag, "playback worker ready rate=$sampleRate buffer=$bufSize")
            while (playbackRunning) {
                val first = try {
                    playbackQueue.poll(300, TimeUnit.MILLISECONDS)
                } catch (e: InterruptedException) {
                    null
                } ?: continue
                if (!started) {
                    // Prime one current frame then play immediately. Waiting
                    // for a second frame duplicated Dart-side buffering and
                    // added another 500ms before every fresh playback start.
                    writeNearbyTrackFully(track, first)
                    if (!playbackRunning) break
                    try {
                        track.play()
                        started = true
                        Log.i(nearbyAudioTag, "playback started")
                    } catch (e: Exception) {
                        Log.e(nearbyAudioTag, "AudioTrack play failed", e)
                        break
                    }
                } else {
                    writeNearbyTrackFully(track, first)
                }
            }
        }.also { it.name = "PhoneopiaNearbyPlayback"; it.start() }
    }

    private fun writeNearbyAudioPlayback(bytes: ByteArray) {
        if (!playbackRunning || bytes.isEmpty()) return
        // MethodChannel runs on Android's main thread. Never call the
        // blocking AudioTrack.write() there: a 250ms write blocked Nearby's
        // own receive callbacks and starved the stream. Queue it for the
        // dedicated playback worker and return to Flutter immediately.
        val pcm = decodeMuLawIfPresent(bytes)
        playbackPacketCount++
        if (playbackPacketCount % 20 == 0) {
            Log.d(nearbyAudioTag, "playback packets=$playbackPacketCount wireBytes=${bytes.size} pcmBytes=${pcm.size}")
        }
        if (!playbackQueue.offerLast(pcm)) {
            playbackQueue.pollFirst()
            playbackQueue.offerLast(pcm)
        }
    }

    private fun encodeMuLaw(pcm: ByteArray, length: Int): ByteArray {
        val samples = length / 2
        val out = ByteArray(muLawMagic.size + samples)
        System.arraycopy(muLawMagic, 0, out, 0, muLawMagic.size)
        for (i in 0 until samples) {
            val lo = pcm[i * 2].toInt() and 0xFF
            val hi = pcm[i * 2 + 1].toInt()
            val sample = (hi shl 8) or lo
            out[muLawMagic.size + i] = linearToMuLaw(sample)
        }
        return out
    }

    private fun decodeMuLawIfPresent(wire: ByteArray): ByteArray {
        if (wire.size <= muLawMagic.size ||
            !wire.copyOfRange(0, muLawMagic.size).contentEquals(muLawMagic)) {
            return wire.copyOf()
        }
        val samples = wire.size - muLawMagic.size
        val pcm = ByteArray(samples * 2)
        for (i in 0 until samples) {
            val sample = muLawToLinear(wire[muLawMagic.size + i])
            pcm[i * 2] = (sample and 0xFF).toByte()
            pcm[i * 2 + 1] = ((sample shr 8) and 0xFF).toByte()
        }
        return pcm
    }

    /** ITU-T G.711 mu-law encoder (16-bit signed PCM -> 8-bit companded). */
    private fun linearToMuLaw(input: Int): Byte {
        val bias = 0x84
        val clip = 32635
        var sample = input
        var sign = 0
        if (sample < 0) {
            sign = 0x80
            sample = -sample
        }
        if (sample > clip) sample = clip
        sample += bias
        var exponent = 7
        var mask = 0x4000
        while (exponent > 0 && (sample and mask) == 0) {
            exponent--
            mask = mask shr 1
        }
        val mantissa = (sample shr (exponent + 3)) and 0x0F
        return (sign or (exponent shl 4) or mantissa).inv().toByte()
    }

    /** ITU-T G.711 mu-law decoder (8-bit companded -> 16-bit signed PCM). */
    private fun muLawToLinear(encoded: Byte): Int {
        val bias = 0x84
        val value = encoded.toInt().inv() and 0xFF
        val sign = value and 0x80
        val exponent = (value shr 4) and 0x07
        val mantissa = value and 0x0F
        var sample = ((mantissa shl 3) + bias) shl exponent
        sample -= bias
        return if (sign != 0) -sample else sample
    }

    private fun writeNearbyTrackFully(track: AudioTrack, bytes: ByteArray) {
        var offset = 0
        while (playbackRunning && offset < bytes.size) {
            val wrote = try {
                track.write(bytes, offset, bytes.size - offset, AudioTrack.WRITE_BLOCKING)
            } catch (e: Exception) {
                Log.e(nearbyAudioTag, "AudioTrack write failed", e)
                return
            }
            if (wrote <= 0) return
            offset += wrote
        }
    }

    private fun stopNearbyAudioPlayback() {
        playbackRunning = false
        playbackQueue.clear()
        playbackThread?.interrupt()
        val track = audioTrack
        try { track?.pause() } catch (e: Exception) {}
        try { track?.flush() } catch (e: Exception) {}
        try { track?.stop() } catch (e: Exception) {}
        try { playbackThread?.join(400) } catch (e: Exception) {}
        playbackThread = null
        try { track?.release() } catch (e: Exception) {}
        audioTrack = null
        // setSpeaker() switches the WHOLE PHONE's audio session into
        // MODE_IN_COMMUNICATION for the Nearby call — that's a system-wide
        // AudioManager setting, not scoped to this call, and was never being
        // put back. Left stuck in that mode, it could keep interfering with
        // a completely unrelated NEXT call's audio routing (a normal
        // WebRTC call sets its own speaker state via flutter_webrtc, but
        // that doesn't override an already-wedged system audio mode).
        try {
            val am = getSystemService(AUDIO_SERVICE) as AudioManager
            am.mode = AudioManager.MODE_NORMAL
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = false
        } catch (e: Exception) {}
    }

    // Known autostart/background-permission screens per OEM. Tried in order;
    // the first one whose activity actually resolves on this device wins.
    // Falls back to the app's own battery-optimization detail page (works
    // everywhere) if none of them do.
    private fun openOemAutostartSettings(): Boolean {
        val candidates = listOf(
            // Oppo / Realme / OnePlus (ColorOS)
            Intent().setComponent(android.content.ComponentName(
                "com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity")),
            Intent().setComponent(android.content.ComponentName(
                "com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity")),
            Intent().setComponent(android.content.ComponentName(
                "com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity")),
            // Vivo (FuntouchOS / OriginOS)
            Intent().setComponent(android.content.ComponentName(
                "com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity")),
            Intent().setComponent(android.content.ComponentName(
                "com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity")),
            // Xiaomi (MIUI)
            Intent().setComponent(android.content.ComponentName(
                "com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity")),
            // Huawei / Honor
            Intent().setComponent(android.content.ComponentName(
                "com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity")),
            // Samsung (device care / battery)
            Intent().setComponent(android.content.ComponentName(
                "com.samsung.android.lool", "com.samsung.android.sm.ui.battery.BatteryActivity"))
        )
        for (intent in candidates) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return true
            } catch (e: Exception) { /* not this OEM/build — try next */ }
        }
        // Universal fallback: this app's own battery-usage detail screen.
        try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            intent.data = android.net.Uri.parse("package:$packageName")
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            return true
        } catch (e: Exception) {
            return false
        }
    }
}
