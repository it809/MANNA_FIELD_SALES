import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/screens/collections/collection_screen.dart';
import 'package:manna_field_sales/screens/complaints/complaint_screen.dart';
import 'package:manna_field_sales/screens/orders/order_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/location_service.dart';
import 'package:manna_field_sales/widgets/visit_punch_card.dart';

class CustomerDetailScreen extends StatefulWidget {
  final Map<String, dynamic> customer;
  final List<Map<String, dynamic>> reps;
  const CustomerDetailScreen(
      {super.key, required this.customer, required this.reps});
  @override
  State<CustomerDetailScreen> createState() => _CustomerDetailScreenState();
}

class _CustomerDetailScreenState extends State<CustomerDetailScreen> {
  late Map<String, dynamic> c;
  bool _busy = false;
  List<Map<String, dynamic>> _sites = [];
  bool _sitesLoading = true;

  @override
  void initState() {
    super.initState();
    c = Map<String, dynamic>.from(widget.customer);
    _loadSites();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  double _num(dynamic v) => (v is num) ? v.toDouble() : 0.0;
  String get _status =>
      (c['custom_location_status'] ?? 'Not Captured').toString();

  Future<void> _capture() async {
    final rep = Session.I.salesPerson;
    if (rep == null) return _snack('No rep linked to this login.');
    final img = await ImagePicker().pickImage(
        source: ImageSource.camera, imageQuality: 60, maxWidth: 1280);
    if (img == null) return _snack('A shop banner photo is required.');
    setState(() => _busy = true);
    _snack('Getting GPS...');
    try {
      final pos = await getCurrentLocation();
      final active = await Api.getActiveTrip();
      await Api.createSalesVisit(
        customer: c['name'],
        salesPerson: rep,
        lat: pos.latitude,
        lng: pos.longitude,
        trip: active?['name'] as String?,
      );
      await Api.captureCustomerLocation(
        customer: c['name'],
        salesPerson: rep,
        lat: pos.latitude,
        lng: pos.longitude,
      );
      await Api.uploadPhoto(
        doctype: 'Customer',
        docname: c['name'],
        fieldname: 'custom_banner_photo',
        filePath: img.path,
        filename: 'banner.jpg',
      );
      setState(() {
        c['custom_location_status'] = 'Pending Verification';
        c['custom_latitude'] = pos.latitude;
        c['custom_longitude'] = pos.longitude;
      });
      _snack('Captured - sent for manager verification.');
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Map<String, dynamic>> _verifiedLocations() {
    final out = <Map<String, dynamic>>[];
    if (_status == 'Verified') {
      out.add({
        'name': 'Main',
        'lat': _num(c['custom_verified_latitude']),
        'lng': _num(c['custom_verified_longitude']),
      });
    }
    for (final s in _sites) {
      if ('${s['location_status']}' == 'Verified') {
        out.add({
          'name': '${s['site_name']}',
          'lat': _num(s['verified_latitude']),
          'lng': _num(s['verified_longitude']),
        });
      }
    }
    return out;
  }

  Future<void> _verifiedCheckIn() async {
    final rep = Session.I.salesPerson;
    if (rep == null) return _snack('No rep linked to this login.');
    final locs = _verifiedLocations();
    if (locs.isEmpty) {
      return _snack('No verified location for this customer yet.');
    }
    setState(() => _busy = true);
    _snack('Getting GPS...');
    try {
      final pos = await getCurrentLocation();
      double bestD = double.infinity;
      Map<String, dynamic>? best;
      for (final l in locs) {
        final d = Geolocator.distanceBetween(l['lat'] as double,
            l['lng'] as double, pos.latitude, pos.longitude);
        if (d < bestD) {
          bestD = d;
          best = l;
        }
      }
      if (best == null || bestD > 100) {
        _snack(
            'Nearest verified location is ${bestD.toStringAsFixed(0)} m away (max 100 m). Move closer.');
        return;
      }
      final siteName = '${best['name']}';
      final name = await Api.createSalesVisit(
        customer: c['name'],
        salesPerson: rep,
        lat: pos.latitude,
        lng: pos.longitude,
        site: siteName,
        trip: (await Api.getActiveTrip())?['name'] as String?,
      );
      _snack('Checked in at $siteName — $name (${bestD.toStringAsFixed(0)} m)');
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadSites() async {
    try {
      final s = await Api.getCustomerSites(c['name'] as String);
      if (mounted) {
        setState(() {
          _sites = s;
          _sitesLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _sitesLoading = false);
    }
  }

  Future<void> _addSite() async {
    final rep = Session.I.salesPerson;
    if (rep == null) return _snack('No rep linked to this login.');
    final ctrl = TextEditingController();
    final siteName = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New site name'),
        content: TextField(
          controller: ctrl,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'e.g. Godown, Branch 2'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Next')),
        ],
      ),
    );
    if (siteName == null || siteName.isEmpty) return;
    final img = await ImagePicker().pickImage(
        source: ImageSource.camera, imageQuality: 60, maxWidth: 1280);
    if (img == null) return _snack('A site banner photo is required.');
    setState(() => _busy = true);
    _snack('Getting GPS...');
    try {
      final pos = await getCurrentLocation();
      final created = await Api.createCustomerSite(
        customer: c['name'],
        siteName: siteName,
        lat: pos.latitude,
        lng: pos.longitude,
      );
      await Api.uploadPhoto(
        doctype: 'Customer Site',
        docname: created,
        fieldname: 'banner_photo',
        filePath: img.path,
        filename: 'site_banner.jpg',
      );
      _snack('Site "$siteName" captured — sent for manager verification.');
      await _loadSites();
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _sitesSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('Sites',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        TextButton.icon(
            onPressed: _busy ? null : _addSite,
            icon: const Icon(Icons.add_location_alt, size: 18),
            label: const Text('Add site')),
      ]),
      if (_sitesLoading)
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('Loading sites…',
              style: TextStyle(fontSize: 12, color: Colors.black45)),
        )
      else if (_sites.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
              'No extra sites. The main location is used for check-in; add a site for a second shop or godown.',
              style: TextStyle(fontSize: 12, color: Colors.black45)),
        )
      else
        ..._sites.map((s) {
          final st = '${s['location_status']}';
          Color col;
          IconData ic;
          if (st == 'Verified') {
            col = Colors.green;
            ic = Icons.verified;
          } else if (st == 'Pending Verification') {
            col = Colors.orange;
            ic = Icons.hourglass_top;
          } else if (st == 'Rejected') {
            col = Colors.red;
            ic = Icons.cancel;
          } else {
            col = Colors.grey;
            ic = Icons.location_off;
          }
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              dense: true,
              leading: Icon(ic, color: col),
              title: Text('${s['site_name']}'),
              subtitle: Text(st),
            ),
          );
        }),
    ]);
  }

  Widget _creditSection() {
    final out = (c['custom_outstanding_balance'] is num)
        ? (c['custom_outstanding_balance'] as num).toDouble()
        : 0.0;
    final lim = (c['custom_credit_limit'] is num)
        ? (c['custom_credit_limit'] as num).toDouble()
        : 0.0;
    final over = lim > 0 && out > lim;
    Widget box(String label, String value, Color? bg) => Expanded(
      child: Card(
        color: bg,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 4),
            Text(value,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
          ]),
        ),
      ),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        box('Outstanding', '₹${out.toStringAsFixed(0)}',
            out > 0 ? const Color(0xFFFFF3E0) : null),
        box('Credit Limit', lim > 0 ? '₹${lim.toStringAsFixed(0)}' : '—',
            over ? const Color(0xFFFFEBEE) : null),
      ]),
      if (over)
        Container(
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: const Color(0xFFFFEBEE),
              borderRadius: BorderRadius.circular(8)),
          child: Row(children: const [
            Icon(Icons.warning_amber, color: Colors.red, size: 20),
            SizedBox(width: 8),
            Expanded(
                child: Text(
                    'Over credit limit — proforma will need manager release.',
                    style: TextStyle(color: Colors.red))),
          ]),
        ),
    ]);
  }

  Widget _statusChip() {
    final s = _status;
    Color col;
    IconData ic;
    if (s == 'Verified') {
      col = Colors.green;
      ic = Icons.verified;
    } else if (s == 'Pending Verification') {
      col = Colors.orange;
      ic = Icons.hourglass_top;
    } else {
      col = Colors.grey;
      ic = Icons.location_off;
    }
    return Chip(
      avatar: Icon(ic, color: col, size: 18),
      label: Text(s),
      backgroundColor: col.withOpacity(0.12),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(c['customer_name'] ?? c['name'])),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child:
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(c['customer_name'] ?? c['name'],
              style:
              const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text([c['customer_group'], c['territory']]
              .where((x) => x != null && '$x'.isNotEmpty)
              .join(' - ')),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: _statusChip()),
          const SizedBox(height: 16),
          _creditSection(),
          const SizedBox(height: 16),
          if (_verifiedLocations().isNotEmpty)
            FilledButton.icon(
              onPressed: _busy ? null : _verifiedCheckIn,
              icon: const Icon(Icons.location_on),
              label: const Padding(
                  padding: EdgeInsets.all(12), child: Text('GPS Check-in')),
            ),
          if (_verifiedLocations().isNotEmpty) const SizedBox(height: 12),
          if (_status != 'Verified')
            Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_status == 'Pending Verification')
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                          'Main location awaiting manager verification. Recapture only if needed.',
                          style: TextStyle(color: Colors.orange)),
                    ),
                  FilledButton.icon(
                    onPressed: _busy ? null : _capture,
                    icon: const Icon(Icons.add_a_photo),
                    label: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(_status == 'Pending Verification'
                            ? 'Recapture Main Banner + Location'
                            : 'Capture Main Banner + Location')),
                  ),
                ]),
          const SizedBox(height: 16),
          VisitPunchCard(customer: c['name'] as String),
          const SizedBox(height: 16),
          _sitesSection(),
          const SizedBox(height: 16),
          if (Session.I.company != 'Manna Tyre Retreads') ...[
            FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => OrderScreen(customer: c))),
              icon: const Icon(Icons.shopping_cart),
              label: const Padding(
                  padding: EdgeInsets.all(12), child: Text('New Order')),
            ),
            const SizedBox(height: 16),
          ],
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) =>
                    CollectionScreen(customer: c, reps: widget.reps))),
            icon: const Icon(Icons.payments),
            label: const Padding(
                padding: EdgeInsets.all(12), child: Text('Record Collection')),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.deepOrange),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ComplaintScreen(customer: c))),
            icon: const Icon(Icons.report_problem_outlined),
            label: const Padding(
                padding: EdgeInsets.all(12), child: Text('Raise Complaint')),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 20),
              child: Center(child: CircularProgressIndicator()),
            ),
        ]),
      ),
    );
  }
}

// -------------------- PROFORMA / PO PDF --------------------
