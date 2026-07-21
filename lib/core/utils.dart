// Small helpers shared across the app.

/// Today's date as an ISO-8601 `yyyy-MM-dd` string — the format the backend
/// expects for date fields.
String today() => DateTime.now().toIso8601String().substring(0, 10);

/// The clock part of a `yyyy-MM-dd HH:mm:ss` timestamp, for display only.
String hhmm(dynamic stamp) {
  final s = (stamp ?? '').toString();
  return s.length >= 16 ? s.substring(11, 16) : '—';
}
