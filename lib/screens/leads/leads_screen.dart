import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:manna_field_sales/screens/leads/add_lead_screen.dart';
import 'package:manna_field_sales/screens/leads/lead_detail_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/map_service.dart';
import 'package:manna_field_sales/widgets/error_view.dart';

class LeadsScreen extends StatefulWidget {
  const LeadsScreen({super.key});
  @override
  State<LeadsScreen> createState() => _LeadsScreenState();
}

class _LeadsScreenState extends State<LeadsScreen> {
  late Future<List<Map<String, dynamic>>> _future;
  String _q = '';
  @override
  void initState() {
    super.initState();
    _future = Api.getLeads();
  }

  void _reload() => setState(() { _future = Api.getLeads(); });

  bool _match(Map<String, dynamic> r) {
    if (_q.isEmpty) return true;
    final hay = [
      r['lead_name'],
      r['company_name'],
      r['mobile_no'],
      r['territory'],
      r['status']
    ].map((e) => (e ?? '').toString().toLowerCase()).join(' ');
    return hay.contains(_q.toLowerCase());
  }

  static double _num(dynamic v) =>
      (v is num) ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

  // Where the lead's location sits: captured and verified, waiting on the
  // manager, rejected, or never captured at all.
  ({Color color, String label}) _locationBadge(Map<String, dynamic> r) {
    final s = (r['custom_location_status'] ?? 'Not Captured').toString();
    if (s == 'Verified') return (color: Colors.green, label: 'Verified');
    if (s == 'Pending Verification') {
      return (color: Colors.orange, label: 'Pending verification');
    }
    if (s == 'Rejected') return (color: Colors.red, label: 'Rejected');
    return (color: Colors.grey, label: 'No location');
  }

  Future<void> _call(String phone) async {
    final uri = Uri.parse('tel:${phone.replaceAll(RegExp(r'[^0-9+]'), '')}');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No dialler available.')));
      }
    }
  }

  Future<void> _open(Map<String, dynamic> r) async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => LeadDetailScreen(lead: r)));
    if (mounted) _reload();
  }

  /// Quick look at one lead without leaving the list — everything the rep
  /// captured about it, plus call/navigate shortcuts.
  void _showDetails(Map<String, dynamic> r) {
    final badge = _locationBadge(r);
    final lat = _num(r['custom_latitude']);
    final lng = _num(r['custom_longitude']);
    final mappable = isMappableLatLng(lat, lng);
    final phone = '${r['mobile_no'] ?? ''}'.trim();

    Widget row(String label, String value, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
                width: 110,
                child: Text(label,
                    style:
                        const TextStyle(fontSize: 13, color: Colors.black54))),
            Expanded(
                child: Text(value,
                    style: TextStyle(
                        fontSize: 14,
                        color: color,
                        fontWeight: color == null
                            ? FontWeight.normal
                            : FontWeight.bold))),
          ]),
        );

    String val(String key) {
      final v = '${r[key] ?? ''}'.trim();
      return v.isEmpty ? '—' : v;
    }

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('${r['lead_name'] ?? r['name']}',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                row('Company', val('company_name')),
                row('Route', val('territory')),
                row('Phone', phone.isEmpty ? '—' : phone),
                row('Email', val('email_id')),
                row('GST', val('custom_gstin')),
                row('Address', val('custom_address')),
                row('Terms', val('custom_payment_terms')),
                row('Status', val('status')),
                row('Lead ID', '${r['name']}'),
                row('Location', badge.label, color: badge.color),
                if (mappable)
                  row('Coordinates',
                      '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: phone.isEmpty
                          ? null
                          : () {
                              Navigator.pop(sheet);
                              _call(phone);
                            },
                      icon: const Icon(Icons.call),
                      label: const Text('Call'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: mappable
                          ? () {
                              Navigator.pop(sheet);
                              navigateTo(lat, lng);
                            }
                          : null,
                      icon: const Icon(Icons.directions),
                      label: const Text('Navigate'),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(sheet);
                    _open(r);
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open full details'),
                ),
              ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Leads'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Add Lead'),
        onPressed: () async {
          final created = await Navigator.push<bool>(context,
              MaterialPageRoute(builder: (_) => const AddLeadScreen()));
          if (created == true) _reload();
        },
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search leads…',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return ErrorView(error: snap.error, onRetry: _reload);
              }
              final all = snap.data!;
              final rows = all.where(_match).toList();
              if (all.isEmpty) {
                return const Center(
                    child: Text('No leads yet. Tap “Add Lead”.'));
              }
              if (rows.isEmpty) return const Center(child: Text('No matches.'));
              return ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final r = rows[i];
                  return ListTile(
                    leading: const Icon(Icons.emoji_objects_outlined),
                    title: Text(r['lead_name'] ?? r['name']),
                    subtitle: Text([r['company_name'], r['territory'], r['mobile_no']]
                        .where((x) => x != null && '$x'.isNotEmpty)
                        .join(' · ')),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: 'Details',
                        icon: const Icon(Icons.info_outline),
                        color: Colors.blueGrey,
                        onPressed: () => _showDetails(r),
                      ),
                      const Icon(Icons.chevron_right),
                    ]),
                    onTap: () => _open(r),
                    onLongPress: () => _showDetails(r),
                  );
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}

