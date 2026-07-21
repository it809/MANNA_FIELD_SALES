// Small helpers shared across the app.

/// Today's date as an ISO-8601 `yyyy-MM-dd` string — the format the backend
/// expects for date fields.
String today() => DateTime.now().toIso8601String().substring(0, 10);
