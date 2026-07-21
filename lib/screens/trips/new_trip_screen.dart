import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/screens/trips/trip_detail_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/location_service.dart';
import 'package:manna_field_sales/services/trip_tracker.dart';

class NewTripScreen extends StatefulWidget {
  const NewTripScreen({super.key});
  @override
  State<NewTripScreen> createState() => _NewTripScreenState();
}

class _NewTripScreenState extends State<NewTripScreen> {
  DateTime _date = DateTime.now();
  final _purpose = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      double? lat, lng;
      try {
        final pos = await getCurrentLocation();
        lat = pos.latitude;
        lng = pos.longitude;
      } catch (_) {}
      final ds =
          '${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';
      final name = await Api.createTrip(
        tripDate: ds,
        purpose: _purpose.text.trim(),
        lat: lat,
        lng: lng,
      );
      final startErr = await TripTracker.I.start(name);
      if (mounted) {
        if (startErr != null) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Trip created. Route recording off: $startErr')));
        }
        Navigator.of(context).pushReplacement(MaterialPageRoute(
            builder: (_) => TripDetailScreen(tripName: name)));
      }
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New Trip')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Trip date'),
          subtitle: Text('${_date.day}/${_date.month}/${_date.year}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          trailing: const Icon(Icons.calendar_today),
          onTap: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: _date,
              firstDate: DateTime.now().subtract(const Duration(days: 365)),
              lastDate: DateTime.now(),
            );
            if (d != null) setState(() => _date = d);
          },
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _purpose,
          decoration: const InputDecoration(
              labelText: 'Purpose (e.g. Ernakulam dealer round)',
              border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        const Text(
            'Odometer readings and photos are captured per vehicle leg (in "Add / switch vehicle") after the trip starts.',
            style: TextStyle(fontSize: 12, color: Colors.black45)),
        const SizedBox(height: 20),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Start Trip'),
        ),
      ]),
    );
  }
}

// -------------------- TRIP ROUTE TRACKER (foreground GPS) --------------------
// Records a GPS point ~every 5 min while a trip is Active. Uses geolocator's
// foreground-service notification so points keep logging with the screen off.
// Only one trip records at a time; state lives for the app session.
