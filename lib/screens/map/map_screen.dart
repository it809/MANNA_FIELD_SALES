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
  // How far back the visit overlay reaches.
  static const int _visitDays = 30;

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _customers = [];
  List<Map<String, dynamic>> _visits = [];
  bool _showCustomers = true;
  bool _showVisits = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Future.wait([
        Api.getCustomers(),
        Api.getMyVisitsWithLocation(days: _visitDays),
      ]);
      _customers = res[0]
          .where((c) => isMappableLatLng(
              _num(c['custom_latitude']), _num(c['custom_longitude'])))
          .toList();
      _visits = res[1]
          .where((v) => isMappableLatLng(
              _num(v['check_in_latitude']), _num(v['check_in_longitude'])))
          .toList();
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  double _num(dynamic v) => (v is num) ? v.toDouble() : 0.0;

  String _fmtTime(dynamic dt) {
    if (dt == null) return '';
    final d = DateTime.tryParse('$dt'.replaceFirst(' ', 'T'));
    if (d == null) return '';
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  void _sheet(IconData icon, Color color, String title, String subtitle,
      double lat, double lng) {
    showModalBottomSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
              ),
            ]),
            const SizedBox(height: 4),
            Text(subtitle),
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

  void _showCustomer(Map<String, dynamic> c, double lat, double lng) => _sheet(
      Icons.location_pin,
      Colors.red,
      '${c['customer_name'] ?? c['name']}',
      [c['customer_group'], c['territory']]
          .where((x) => x != null && '$x'.isNotEmpty)
          .join(' · '),
      lat,
      lng);

  void _showVisit(Map<String, dynamic> v, double lat, double lng) {
    final isLead = Api.isLeadVisit(v);
    _sheet(
        isLead ? Icons.person_pin_circle : Icons.store,
        isLead ? const Color(0xFF0F766E) : const Color(0xFFF46A21),
        Api.visitParty(v),
        [
          isLead ? 'Lead visit' : 'Visit',
          '${v['visit_date']}',
          if (_fmtTime(v['check_in_time']).isNotEmpty)
            _fmtTime(v['check_in_time']),
          '${v['visit_status']}',
        ].where((x) => x.isNotEmpty && x != 'null').join(' · '),
        lat,
        lng);
  }

  Widget _filters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Wrap(spacing: 8, children: [
        FilterChip(
          selected: _showCustomers,
          avatar: const Icon(Icons.location_pin, size: 18),
          label: Text('Customers (${_customers.length})'),
          onSelected: (v) => setState(() => _showCustomers = v),
        ),
        FilterChip(
          selected: _showVisits,
          avatar: const Icon(Icons.store, size: 18),
          label: Text('My visits (${_visits.length})'),
          onSelected: (v) => setState(() => _showVisits = v),
        ),
      ]),
    );
  }

  Widget _legend() {
    Widget chip(Color c, IconData ic, String t) =>
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ic, color: c, size: 16),
          const SizedBox(width: 4),
          Text(t, style: const TextStyle(fontSize: 11)),
        ]);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(spacing: 14, runSpacing: 8, children: [
        if (_showCustomers) chip(Colors.red, Icons.location_pin, 'Customer'),
        if (_showVisits) ...[
          chip(const Color(0xFFF46A21), Icons.store, 'Visit'),
          chip(const Color(0xFF0F766E), Icons.person_pin_circle, 'Lead visit'),
          Text('last $_visitDays days',
              style: const TextStyle(fontSize: 11, color: Colors.black45)),
        ],
      ]),
    );
  }

  Widget _map() {
    final markers = <Marker>[];
    final latlngs = <LatLng>[];
    if (_showCustomers) {
      for (final c in _customers) {
        final lat = _num(c['custom_latitude']);
        final lng = _num(c['custom_longitude']);
        latlngs.add(LatLng(lat, lng));
        markers.add(Marker(
          point: LatLng(lat, lng),
          width: 44,
          height: 44,
          child: GestureDetector(
            onTap: () => _showCustomer(c, lat, lng),
            child: const Icon(Icons.location_pin, color: Colors.red, size: 44),
          ),
        ));
      }
    }
    // Visits draw after customers so a visited spot stays tappable on top.
    if (_showVisits) {
      for (final v in _visits) {
        final lat = _num(v['check_in_latitude']);
        final lng = _num(v['check_in_longitude']);
        final isLead = Api.isLeadVisit(v);
        latlngs.add(LatLng(lat, lng));
        markers.add(Marker(
          point: LatLng(lat, lng),
          width: 40,
          height: 40,
          child: GestureDetector(
            onTap: () => _showVisit(v, lat, lng),
            child: Icon(isLead ? Icons.person_pin_circle : Icons.store,
                color: isLead
                    ? const Color(0xFF0F766E)
                    : const Color(0xFFF46A21),
                size: 34),
          ),
        ));
      }
    }
    if (markers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
              (!_showCustomers && !_showVisits)
                  ? 'Turn on a layer to see it on the map.'
                  : 'Nothing to show yet — no customer has coordinates and no visit in the last $_visitDays days has a check-in location.',
              textAlign: TextAlign.center),
        ),
      );
    }
    final cz = mapCenterZoom(latlngs);
    return FlutterMap(
      options: MapOptions(initialCenter: cz.center, initialZoom: cz.zoom),
      children: [
        TileLayer(
          urlTemplate: mapTileUrl(),
          userAgentPackageName: 'com.manna.fieldsales',
        ),
        MarkerLayer(markers: markers),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Map'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              _filters(),
              if (_error != null)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child:
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                ),
              Expanded(child: _map()),
              _legend(),
            ]),
    );
  }
}

// -------------------- ATTENDANCE --------------------
