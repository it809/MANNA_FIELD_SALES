import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/map_service.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = Api.getCustomers();
  }

  double _num(dynamic v) => (v is num) ? v.toDouble() : 0.0;

  void _showCustomer(
      BuildContext context, Map<String, dynamic> c, double lat, double lng) {
    showModalBottomSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(c['customer_name'] ?? c['name'],
                style:
                const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text([c['customer_group'], c['territory']]
                .where((x) => x != null && '$x'.isNotEmpty)
                .join(' · ')),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                navigateTo(lat, lng);
              },
              icon: const Icon(Icons.directions),
              label: const Text('Navigate'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Customer Map')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          final withCoords = snap.data!
              .where((c) =>
          _num(c['custom_latitude']) != 0 &&
              _num(c['custom_longitude']) != 0)
              .toList();
          if (withCoords.isEmpty) {
            return const Center(
                child: Text('No customers have coordinates yet.'));
          }
          final markers = withCoords.map((c) {
            final lat = _num(c['custom_latitude']);
            final lng = _num(c['custom_longitude']);
            return Marker(
              point: LatLng(lat, lng),
              width: 44,
              height: 44,
              child: GestureDetector(
                onTap: () => _showCustomer(context, c, lat, lng),
                child:
                const Icon(Icons.location_pin, color: Colors.red, size: 44),
              ),
            );
          }).toList();
          return FlutterMap(
            options: const MapOptions(
              initialCenter: LatLng(10.2, 76.3),
              initialZoom: 7.2,
            ),
            children: [
              TileLayer(
                urlTemplate: mapTileUrl(),
                userAgentPackageName: 'com.manna.fieldsales',
              ),
              MarkerLayer(markers: markers),
            ],
          );
        },
      ),
    );
  }
}

// -------------------- ATTENDANCE --------------------
