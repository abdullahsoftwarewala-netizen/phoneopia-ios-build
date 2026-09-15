/// Kill switches for experimental features — flip off here rather than
/// deleting the code, so a feature can be disabled fast if it turns out
/// unstable without losing the work.
library;

/// Mid-call automatic handoff to the Nearby (Bluetooth) audio pipeline when
/// internet drops. Was off while investigating reports of unreliable call
/// audio/delivery over that pipeline; re-enabled after confirming the
/// underlying AudioRecord/AudioTrack resource-race retries (see
/// MainActivity.kt) and the ws-relay.php ICE-candidate delivery fix — with
/// this off, a dropped connection only shows "Reconnecting…" and attempts a
/// same-transport ICE restart, it never switches transport at all.
const bool kCallNearbyFailoverEnabled = true;
