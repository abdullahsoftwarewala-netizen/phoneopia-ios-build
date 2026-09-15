/// The server sends naive "YYYY-MM-DD HH:MM:SS" (or ISO without an offset)
/// timestamps — MySQL's NOW()/CURRENT_TIMESTAMP under this server's
/// UTC-configured PHP/MySQL never include a 'Z' or +00:00 suffix, even
/// though the values genuinely are UTC. DateTime.parse silently treats a
/// string with no timezone marker as already being in the DEVICE'S OWN
/// local time — which made every timestamp in the app wrong by exactly the
/// device's UTC offset (e.g. 5 hours off in Pakistan): message times, call
/// log times, last-seen, conversation previews, all of it. Force it as UTC
/// before converting to local so it's actually correct everywhere.
DateTime? parseServerTime(dynamic raw) {
  if (raw == null) return null;
  var s = raw.toString().trim();
  if (s.isEmpty) return null;
  final hasOffset = s.endsWith('Z') || RegExp(r'[+-]\d\d:?\d\d$').hasMatch(s);
  if (!hasOffset) {
    s = s.contains('T') ? '${s}Z' : '${s.replaceFirst(' ', 'T')}Z';
  }
  return DateTime.tryParse(s)?.toLocal();
}
