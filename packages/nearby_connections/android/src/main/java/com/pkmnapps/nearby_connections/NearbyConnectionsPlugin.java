package com.pkmnapps.nearby_connections;

import android.app.Activity;
import android.util.Log;
import android.os.Build.VERSION;
import android.os.Build.VERSION_CODES;
import android.os.ParcelFileDescriptor;
import android.net.Uri;

import androidx.annotation.NonNull;

import com.google.android.gms.nearby.Nearby;
import com.google.android.gms.nearby.connection.AdvertisingOptions;
import com.google.android.gms.nearby.connection.ConnectionInfo;
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback;
import com.google.android.gms.nearby.connection.ConnectionOptions;
import com.google.android.gms.nearby.connection.ConnectionResolution;
import com.google.android.gms.nearby.connection.ConnectionType;
import com.google.android.gms.nearby.connection.ConnectionsStatusCodes;
import com.google.android.gms.nearby.connection.DiscoveredEndpointInfo;
import com.google.android.gms.nearby.connection.DiscoveryOptions;
import com.google.android.gms.nearby.connection.EndpointDiscoveryCallback;
import com.google.android.gms.nearby.connection.Payload;
import com.google.android.gms.nearby.connection.PayloadCallback;
import com.google.android.gms.nearby.connection.PayloadTransferUpdate;
import com.google.android.gms.nearby.connection.Strategy;
import com.google.android.gms.tasks.OnFailureListener;
import com.google.android.gms.tasks.OnSuccessListener;

import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.FileOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.LinkedBlockingDeque;
import java.util.concurrent.TimeUnit;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.plugin.common.EventChannel;

/**
 * NearbyConnectionsPlugin
 */
public class NearbyConnectionsPlugin implements MethodCallHandler, FlutterPlugin, ActivityAware {
	private Activity activity;
	private static final String SERVICE_ID = "com.pkmnapps.nearby_connections";
	private static MethodChannel channel;
	private static EventChannel eventChannel;
	private static EventChannel.EventSink eventSink;
	private final Map<String, AudioStreamSender> audioStreamSenders = new ConcurrentHashMap<>();
	private final Map<String, InputStream> incomingAudioStreams = new ConcurrentHashMap<>();
	private NearbyConnectionsPlugin(Activity activity) {
		this.activity = activity;
	}

	public NearbyConnectionsPlugin() {
	}

	@Override
	public void onMethodCall(MethodCall call, final Result result) {

		switch (call.method) {
			case "copyFileAndDeleteOriginal":
				Log.d("nearby_connections", "copyFileAndDeleteOriginal");
				String sourceUri = (String) call.argument("sourceUri");
				String destinationFilepath = (String) call.argument("destinationFilepath");

				try {
					// Copy the file to a new location.
					Uri uri = Uri.parse(sourceUri);
					InputStream in = activity.getContentResolver().openInputStream(uri);
					copyStream(in, new FileOutputStream(new File(destinationFilepath)));
					// Delete the original file.
					activity.getContentResolver().delete(uri, null, null);
					result.success(true);
				} catch (IOException e) {
					// Log the error.
					Log.e("nearby_connections", e.getMessage());
					result.success(false);
				}
				break;
			case "stopAdvertising":
				Log.d("nearby_connections", "stopAdvertising");
				Nearby.getConnectionsClient(activity).stopAdvertising();
				result.success(null);
				break;
			case "stopDiscovery":
				Log.d("nearby_connections", "stopDiscovery");
				Nearby.getConnectionsClient(activity).stopDiscovery();
				result.success(null);
				break;
			case "startAdvertising": {
				String userNickName = (String) call.argument("userNickName");
				int strategy = (int) call.argument("strategy");
				String serviceId = (String) call.argument("serviceId");

				assert userNickName != null;
				if (serviceId == null || serviceId == "")
					serviceId = SERVICE_ID;

				AdvertisingOptions advertisingOptions = new AdvertisingOptions.Builder()
						.setStrategy(getStrategy(strategy))
						// Use Bluetooth Classic + both legacy/extended BLE advertising
						// formats. BLE-only low-power advertising is incompatible between
						// some older Oppo radios and newer Android scanners. NON_DISRUPTIVE
						// is the important guard: it prevents Nearby from toggling Wi-Fi.
						.setLowPower(false)
						.setConnectionType(ConnectionType.NON_DISRUPTIVE)
						.build();

				Nearby.getConnectionsClient(activity).startAdvertising(userNickName, serviceId,
								advertConnectionLifecycleCallback, advertisingOptions)
						.addOnSuccessListener(new OnSuccessListener<Void>() {
							@Override
							public void onSuccess(Void aVoid) {
								Log.d("nearby_connections", "startAdvertising");
								result.success(true);
							}
						}).addOnFailureListener(new OnFailureListener() {
							@Override
							public void onFailure(@NonNull Exception e) {
								result.error("Failure", e.getMessage(), null);
							}
						});
				break;
			}
			case "startDiscovery": {
				String userNickName = (String) call.argument("userNickName");
				int strategy = (int) call.argument("strategy");
				String serviceId = (String) call.argument("serviceId");

				assert userNickName != null;
				if (serviceId == null || serviceId == "")
					serviceId = SERVICE_ID;

				// Android 12+ reliably supports Nearby's BLE-only scan and must not
				// let Play Services touch Wi-Fi. A few older Oppo/Android 10 radios
				// repeatedly fail GATT reads (error 133); on those devices use the
				// compatibility scanner so Bluetooth Classic can take over. Their OS
				// rejects background Wi-Fi state changes, so Wi-Fi remains untouched.
				boolean bluetoothOnlyDiscovery = VERSION.SDK_INT >= VERSION_CODES.S;
				DiscoveryOptions discoveryOptions = new DiscoveryOptions.Builder()
						.setStrategy(getStrategy(strategy))
						.setLowPower(bluetoothOnlyDiscovery)
						.build();
				Nearby.getConnectionsClient(activity)
						.startDiscovery(serviceId, endpointDiscoveryCallback, discoveryOptions)
						.addOnSuccessListener(new OnSuccessListener<Void>() {
							@Override
							public void onSuccess(Void aVoid) {
								Log.d("nearby_connections", "startDiscovery");
								result.success(true);
							}
						}).addOnFailureListener(new OnFailureListener() {
							@Override
							public void onFailure(@NonNull Exception e) {
								result.error("Failure", e.getMessage(), null);
							}
						});
				break;
			}
			case "stopAllEndpoints":
				Log.d("nearby_connections", "stopAllEndpoints");
				closeAllAudioStreams();
				Nearby.getConnectionsClient(activity).stopAllEndpoints();
				result.success(null);
				break;
			case "disconnectFromEndpoint": {
				Log.d("nearby_connections", "disconnectFromEndpoint");
				String endpointId = call.argument("endpointId");
				assert endpointId != null;
				closeAudioStreams(endpointId);
				Nearby.getConnectionsClient(activity).disconnectFromEndpoint(endpointId);
				result.success(null);
				break;
			}
			case "requestConnection": {
				Log.d("nearby_connections", "requestConnection");
				String userNickName = (String) call.argument("userNickName");
				String endpointId = (String) call.argument("endpointId");

				assert userNickName != null;
				assert endpointId != null;
				ConnectionOptions connectionOptions = new ConnectionOptions.Builder()
						// Use the reliable/high-power path for Phoneopia chat and
						// voice calls. Low-power requests were intermittently failing
						// with STATUS_RADIO_ERROR (8007) after discovery.
						.setLowPower(false)
						.setConnectionType(ConnectionType.NON_DISRUPTIVE)
						.build();
				Nearby.getConnectionsClient(activity)
						.requestConnection(userNickName, endpointId,
								discoverConnectionLifecycleCallback, connectionOptions)
						.addOnSuccessListener(new OnSuccessListener<Void>() {
							@Override
							public void onSuccess(Void aVoid) {
								Log.d("nearby_connections", "requestConnection issued: " + endpointId);
								result.success(true);
							}
						}).addOnFailureListener(new OnFailureListener() {
							@Override
							public void onFailure(@NonNull Exception e) {
								Log.e("nearby_connections", "requestConnection failed: " + endpointId, e);
								result.error("Failure", e.getMessage(), null);
							}
						});
				break;
			}
			case "acceptConnection": {
				String endpointId = (String) call.argument("endpointId");

				assert endpointId != null;
				Nearby.getConnectionsClient(activity).acceptConnection(endpointId, payloadCallback)
						.addOnSuccessListener(new OnSuccessListener<Void>() {
							@Override
							public void onSuccess(Void aVoid) {
								Log.d("nearby_connections", "acceptConnection");
								result.success(true);
							}
						}).addOnFailureListener(new OnFailureListener() {
							@Override
							public void onFailure(@NonNull Exception e) {
								result.error("Failure", e.getMessage(), null);
							}
						});
				break;
			}
			case "rejectConnection": {
				String endpointId = (String) call.argument("endpointId");

				assert endpointId != null;
				Nearby.getConnectionsClient(activity).rejectConnection(endpointId)
						.addOnSuccessListener(new OnSuccessListener<Void>() {
							@Override
							public void onSuccess(Void aVoid) {
								Log.d("nearby_connections", "rejectConnection");
								result.success(true);
							}
						}).addOnFailureListener(new OnFailureListener() {
							@Override
							public void onFailure(@NonNull Exception e) {
								result.error("Failure", e.getMessage(), null);
							}
						});
				break;
			}
			case "sendPayload": {
				String endpointId = (String) call.argument("endpointId");
				byte[] bytes = call.argument("bytes");

				assert endpointId != null;
				assert bytes != null;
				Payload bytesPayload = Payload.fromBytes(bytes);
				Nearby.getConnectionsClient(activity).sendPayload(endpointId, bytesPayload);
				Log.d("nearby_connections", "sentPayload");
				// Return the id so latency-sensitive callers (Nearby voice) can
				// cancel an older queued packet before it becomes stale audio.
				result.success(bytesPayload.getId());
				break;
			}
			case "sendAudioStreamChunk": {
				String endpointId = (String) call.argument("endpointId");
				byte[] bytes = call.argument("bytes");
				assert endpointId != null;
				assert bytes != null;
				try {
					AudioStreamSender sender = audioStreamSenders.get(endpointId);
					if (sender == null || !sender.isRunning()) {
						sender = new AudioStreamSender(endpointId);
						AudioStreamSender old = audioStreamSenders.put(endpointId, sender);
						if (old != null) old.close();
						sender.start();
					}
					sender.offer(bytes);
					result.success(sender.payloadId());
				} catch (IOException e) {
					Log.e("nearby_connections", "Unable to start audio stream", e);
					result.error("Failure", e.getMessage(), null);
				}
				break;
			}
			case "stopAudioStream": {
				String endpointId = (String) call.argument("endpointId");
				assert endpointId != null;
				AudioStreamSender sender = audioStreamSenders.remove(endpointId);
				if (sender != null) sender.close();
				result.success(null);
				break;
			}
			case "sendFilePayload": {
				String endpointId = (String) call.argument("endpointId");
				String filePath = (String) call.argument("filePath");

				assert endpointId != null;
				assert filePath != null;

				try {
					File file = new File(filePath);

					Payload filePayload = Payload.fromFile(file);
					Nearby.getConnectionsClient(activity).sendPayload(endpointId, filePayload);
					Log.d("nearby_connections", "sentFilePayload");
					result.success(filePayload.getId()); // return payload id to dart
				} catch (FileNotFoundException e) {
					Log.e("nearby_connections", "File not found", e);
					result.error("Failure", e.getMessage(), null);
					return;
				}
				break;
			}
			case "cancelPayload": {
				String payloadId = (String) call.argument("payloadId");
				assert payloadId != null;
				Nearby.getConnectionsClient(activity).cancelPayload(Long.parseLong(payloadId));
				Log.d("nearby_connections", "cancelPayload");
				result.success(null);
				break;
			}
			default:
				result.notImplemented();
		}
	}

	private final ConnectionLifecycleCallback advertConnectionLifecycleCallback = new ConnectionLifecycleCallback() {
		@Override
		public void onConnectionInitiated(@NonNull String endpointId, @NonNull ConnectionInfo connectionInfo) {
			Log.d("nearby_connections", "ad.onConnectionInitiated");
			Map<String, Object> args = new HashMap<>();
			args.put("endpointId", endpointId);
			args.put("endpointName", connectionInfo.getEndpointName());
			args.put("authenticationToken", connectionInfo.getAuthenticationToken());
			args.put("isIncomingConnection", connectionInfo.isIncomingConnection());

			args.put("method", "ad.onConnectionInitiated");
			eventSink.success(args);
		}

		@Override
		public void onConnectionResult(@NonNull String endpointId, @NonNull ConnectionResolution connectionResolution) {
			Log.d("nearby_connections", "ad.onConnectionResult");
			Map<String, Object> args = new HashMap<>();
			args.put("endpointId", endpointId);
			int statusCode = -1;
			switch (connectionResolution.getStatus().getStatusCode()) {
				case ConnectionsStatusCodes.STATUS_OK:
					statusCode = 0;
					// We're connected! Can now start sending and receiving data.
					break;
				case ConnectionsStatusCodes.STATUS_CONNECTION_REJECTED:
					statusCode = 1;
					// The connection was rejected by one or both sides.
					break;
				case ConnectionsStatusCodes.STATUS_ERROR:
					statusCode = 2;
					// The connection broke before it was able to be accepted.
					break;
				default:
					// Unknown status code
			}
			args.put("statusCode", statusCode);
			args.put("method", "ad.onConnectionResult");
			eventSink.success(args);
		}

		@Override
		public void onDisconnected(@NonNull String endpointId) {
			Log.d("nearby_connections", "ad.onDisconnected");
			closeAudioStreams(endpointId);
			Map<String, Object> args = new HashMap<>();
			args.put("endpointId", endpointId);

			args.put("method", "ad.onDisconnected");
			eventSink.success(args);
		}
	};

	private final ConnectionLifecycleCallback discoverConnectionLifecycleCallback = new ConnectionLifecycleCallback() {
		@Override
		public void onConnectionInitiated(@NonNull String endpointId, @NonNull ConnectionInfo connectionInfo) {
			Log.d("nearby_connections", "dis.onConnectionInitiated");
			Map<String, Object> args = new HashMap<>();
			args.put("endpointId", endpointId);
			args.put("endpointName", connectionInfo.getEndpointName());
			args.put("authenticationToken", connectionInfo.getAuthenticationToken());
			args.put("isIncomingConnection", connectionInfo.isIncomingConnection());

			args.put("method", "dis.onConnectionInitiated");
			eventSink.success(args);
		}

		@Override
		public void onConnectionResult(@NonNull String endpointId, @NonNull ConnectionResolution connectionResolution) {
			Log.d("nearby_connections", "dis.onConnectionResult");
			Map<String, Object> args = new HashMap<>();
			args.put("endpointId", endpointId);
			int statusCode = -1;
			switch (connectionResolution.getStatus().getStatusCode()) {
				case ConnectionsStatusCodes.STATUS_OK:
					statusCode = 0;
					// We're connected! Can now start sending and receiving data.
					break;
				case ConnectionsStatusCodes.STATUS_CONNECTION_REJECTED:
					statusCode = 1;
					// The connection was rejected by one or both sides.
					break;
				case ConnectionsStatusCodes.STATUS_ERROR:
					statusCode = 2;
					// The connection broke before it was able to be accepted.
					break;
				default:
					// Unknown status code
			}
			args.put("statusCode", statusCode);

			args.put("method", "dis.onConnectionResult");
			eventSink.success(args);
		}

		@Override
		public void onDisconnected(@NonNull String endpointId) {
			Log.d("nearby_connections", "dis.onDisconnected");
			closeAudioStreams(endpointId);
			Map<String, Object> args = new HashMap<>();
			args.put("endpointId", endpointId);

			args.put("method","dis.onDisconnected");
			eventSink.success(args);
		}
	};

	private final PayloadCallback payloadCallback = new PayloadCallback() {
		@Override
		public void onPayloadReceived(@NonNull String endpointId, @NonNull Payload payload) {
			Log.d("nearby_connections", "onPayloadReceived");
			if (payload.getType() == Payload.Type.STREAM) {
				InputStream input = payload.asStream().asInputStream();
				InputStream old = incomingAudioStreams.put(endpointId, input);
				if (old != null) {
					try { old.close(); } catch (IOException ignored) {}
				}
				startIncomingAudioReader(endpointId, payload.getId(), input);
				return;
			}
			Map<String, Object> args = new HashMap<>();
			args.put("endpointId", endpointId);
			args.put("payloadId", payload.getId());
			args.put("type", payload.getType());

			if (payload.getType() == Payload.Type.BYTES) {
				byte[] bytes = payload.asBytes();
				assert bytes != null;
				args.put("bytes", bytes);
			} else if (payload.getType() == Payload.Type.FILE) {
				args.put("uri", payload.asFile().asUri().toString());
				if (VERSION.SDK_INT < VERSION_CODES.Q) {
					// This is deprecated and only available on Android 10 and below.
					args.put("filePath", payload.asFile().asJavaFile().getAbsolutePath());
				}
			}


			args.put("method","onPayloadReceived");
			eventSink.success(args);
		}

		@Override
		public void onPayloadTransferUpdate(@NonNull String endpointId,
											@NonNull PayloadTransferUpdate payloadTransferUpdate) {
			// required for files and streams

			Log.d("nearby_connections", "onPayloadTransferUpdate");
			Map<String, Object> args = new HashMap<>();
			args.put("endpointId", endpointId);
			args.put("payloadId", payloadTransferUpdate.getPayloadId());
			args.put("status", payloadTransferUpdate.getStatus());
			args.put("bytesTransferred", payloadTransferUpdate.getBytesTransferred());
			args.put("totalBytes", payloadTransferUpdate.getTotalBytes());

			args.put("method","onPayloadTransferUpdate");
			eventSink.success(args);
		}
	};

	/**
	 * One long-lived Nearby STREAM per peer is used for call audio. Sending a
	 * separate reliable BYTES payload for every microphone frame made Play
	 * Services queue old speech, so it arrived seconds late. The stream keeps
	 * framing (length + bytes) but has no per-packet Nearby transfer backlog.
	 */
	private final class AudioStreamSender {
		private final String endpointId;
		private final Payload payload;
		private final DataOutputStream output;
		// A short FIFO absorbs Android/Play-Services scheduling bursts. The old
		// two-frame queue plus newest-frame jump discarded syllables whenever the
		// sender was briefly delayed, which sounded like chopped Nearby audio.
		private final LinkedBlockingDeque<byte[]> queue = new LinkedBlockingDeque<>(8);
		private volatile boolean running = true;
		private Thread worker;

		AudioStreamSender(String endpointId) throws IOException {
			this.endpointId = endpointId;
			ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe();
			InputStream input = new ParcelFileDescriptor.AutoCloseInputStream(pipe[0]);
			this.output = new DataOutputStream(new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]));
			this.payload = Payload.fromStream(input);
		}

		long payloadId() { return payload.getId(); }
		boolean isRunning() { return running; }

		void start() {
			Nearby.getConnectionsClient(activity).sendPayload(endpointId, payload)
					.addOnFailureListener(e -> {
						Log.e("nearby_connections", "Audio stream send failed: " + endpointId, e);
						close();
					});
			worker = new Thread(() -> {
				try {
					while (running) {
						byte[] frame = queue.poll(500, TimeUnit.MILLISECONDS);
						if (frame == null) continue;
						// Preserve FIFO order. Skipping to the newest frame makes words
						// sound clipped whenever the UI thread has a short scheduling burst.
						output.writeInt(frame.length);
						output.write(frame);
						output.flush();
					}
				} catch (InterruptedException ignored) {
					Thread.currentThread().interrupt();
				} catch (IOException e) {
					if (running) Log.w("nearby_connections", "Audio stream closed: " + endpointId, e);
				} finally {
					running = false;
					try { output.close(); } catch (IOException ignored) {}
				}
			}, "PhoneopiaNearbyAudioSend");
			worker.start();
		}

		void offer(byte[] bytes) {
			if (!running || bytes.length == 0) return;
			byte[] copy = bytes.clone();
			if (!queue.offerLast(copy)) {
				queue.pollFirst();
				queue.offerLast(copy);
			}
		}

		void close() {
			running = false;
			queue.clear();
			if (worker != null) worker.interrupt();
			try { output.close(); } catch (IOException ignored) {}
			Nearby.getConnectionsClient(activity).cancelPayload(payload.getId());
		}
	}

	private void startIncomingAudioReader(String endpointId, long payloadId, InputStream rawInput) {
		Thread reader = new Thread(() -> {
			DataInputStream input = new DataInputStream(rawInput);
			try {
				while (incomingAudioStreams.get(endpointId) == rawInput) {
					int length = input.readInt();
					if (length <= 0 || length > 65536) throw new IOException("Invalid audio frame: " + length);
					byte[] frame = new byte[length + 1];
					frame[0] = 0x01; // existing Dart audio envelope
					input.readFully(frame, 1, length);
					Map<String, Object> args = new HashMap<>();
					args.put("endpointId", endpointId);
					args.put("payloadId", payloadId);
					args.put("type", Payload.Type.BYTES);
					args.put("bytes", frame);
					args.put("method", "onPayloadReceived");
					Activity currentActivity = activity;
					if (currentActivity != null) {
						currentActivity.runOnUiThread(() -> {
							EventChannel.EventSink sink = eventSink;
							if (sink != null) sink.success(args);
						});
					}
				}
			} catch (EOFException ignored) {
			} catch (IOException e) {
				if (incomingAudioStreams.get(endpointId) == rawInput) {
					Log.w("nearby_connections", "Incoming audio stream ended: " + endpointId, e);
				}
			} finally {
				incomingAudioStreams.remove(endpointId, rawInput);
				try { input.close(); } catch (IOException ignored) {}
			}
		}, "PhoneopiaNearbyAudioReceive");
		reader.start();
	}

	private void closeAudioStreams(String endpointId) {
		AudioStreamSender sender = audioStreamSenders.remove(endpointId);
		if (sender != null) sender.close();
		InputStream input = incomingAudioStreams.remove(endpointId);
		if (input != null) {
			try { input.close(); } catch (IOException ignored) {}
		}
	}

	private void closeAllAudioStreams() {
		for (String endpointId : audioStreamSenders.keySet()) closeAudioStreams(endpointId);
		for (String endpointId : incomingAudioStreams.keySet()) closeAudioStreams(endpointId);
	}

	private final EndpointDiscoveryCallback endpointDiscoveryCallback = new EndpointDiscoveryCallback() {
		@Override
		public void onEndpointFound(@NonNull String endpointId,
									@NonNull DiscoveredEndpointInfo discoveredEndpointInfo) {
			Log.d("nearby_connections", "onEndpointFound");
			Map<String, Object> args = new HashMap<>();
			args.put("endpointId", endpointId);
			args.put("endpointName", discoveredEndpointInfo.getEndpointName());
			args.put("serviceId", discoveredEndpointInfo.getServiceId());

			args.put("method","dis.onEndpointFound");
			eventSink.success(args);
		}

		@Override
		public void onEndpointLost(@NonNull String endpointId) {
			Log.d("nearby_connections", "onEndpointLost");
			Map<String, Object> args = new HashMap<>();
			args.put("endpointId", endpointId);

			args.put("method","dis.onEndpointLost");
			eventSink.success(args);
		}
	};

	private Strategy getStrategy(int strategy) {
		switch (strategy) {
			case 0:
				return Strategy.P2P_CLUSTER;
			case 1:
				return Strategy.P2P_STAR;
			case 2:
				return Strategy.P2P_POINT_TO_POINT;
			default:
				return Strategy.P2P_CLUSTER;
		}
	}

	@Override
	public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
		channel = new MethodChannel(binding.getBinaryMessenger(), "nearby_connections");
		channel.setMethodCallHandler(this);
		eventChannel=new EventChannel(binding.getBinaryMessenger(), "nearby_connections/events");
		eventChannel.setStreamHandler(
				new EventChannel.StreamHandler() {
					@Override
					public void onListen(Object arguments, EventChannel.EventSink events) {
						eventSink=events;
					}
					@Override
					public void onCancel(Object arguments) {
						eventSink=null;
					}
				});
	}

	@Override
	public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
	}

	@Override
	public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
		this.activity = binding.getActivity();
	}

	@Override
	public void onDetachedFromActivity() {
	}

	@Override
	public void onDetachedFromActivityForConfigChanges() {
	}

	@Override
	public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
		this.activity = binding.getActivity();
	}

	/** Copies a stream from one location to another. */
	private static void copyStream(InputStream in, OutputStream out) throws IOException {
		try {
			byte[] buffer = new byte[1024];
			int read;
			while ((read = in.read(buffer)) != -1) {
				out.write(buffer, 0, read);
			}
			out.flush();
		} finally {
			in.close();
			out.close();
		}
	}
}
