import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'package:manna_field_sales/services/api.dart';

class TripTracker {
  static final TripTracker I = TripTracker._();
  TripTracker._();

  final ValueNotifier<String?> activeTrip = ValueNotifier<String?>(null);
  StreamSubscription<Position>? _sub;
  DateTime? _lastSaved;
  static const Duration interval = Duration(minutes: 5);

  bool isRecording(String tripName) => activeTrip.value == tripName;

  Future<String?> start(String tripName) async {
    if (activeTrip.value == tripName) return null;
    if (activeTrip.value != null) {
      return 'Another trip (${activeTrip.value}) is already recording. Stop it first.';
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'Turn on GPS/location first.';
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return 'Location permission denied. Allow location to record the route.';
    }
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
      intervalDuration: const Duration(minutes: 1),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'Manna — recording trip route',
        notificationText:
        'Logging your route while the trip is active. Tap to open.',
        enableWakeLock: true,
        setOngoing: true,
        notificationIcon:
        AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
      ),
    );
    activeTrip.value = tripName;
    _lastSaved = null;
    // Log an immediate first point so the route starts right away.
    try {
      final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      await _save(tripName, pos);
    } catch (_) {}
    _sub = Geolocator.getPositionStream(locationSettings: settings)
        .listen((pos) {
      final now = DateTime.now();
      if (_lastSaved == null || now.difference(_lastSaved!) >= interval) {
        _save(tripName, pos);
      }
    }, onError: (_) {});
    return null;
  }

  Future<void> _save(String tripName, Position pos) async {
    _lastSaved = DateTime.now();
    try {
      await Api.appendTripGpsPoint(tripName, pos.latitude, pos.longitude);
    } catch (_) {}
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _lastSaved = null;
    activeTrip.value = null;
  }
}

