// Small helpers shared across the app.

import 'package:manna_field_sales/core/server_clock.dart';

/// Today's date as an ISO-8601 `yyyy-MM-dd` string — the format the backend
/// expects for date fields. Read off the server's clock, so a phone set to
/// tomorrow does not file today's work under the wrong date.
String today() => ServerClock.I.now().toIso8601String().substring(0, 10);

/// The clock part of a `yyyy-MM-dd HH:mm:ss` timestamp, for display only.
String hhmm(dynamic stamp) {
  final s = (stamp ?? '').toString();
  return s.length >= 16 ? s.substring(11, 16) : '—';
}
