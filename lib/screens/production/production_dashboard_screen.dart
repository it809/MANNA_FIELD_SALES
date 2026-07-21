import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/screens/production/production_order_detail_screen.dart';
import 'package:manna_field_sales/services/api.dart';

class ProductionDashboardScreen extends StatefulWidget {
  const ProductionDashboardScreen({super.key});
  @override
  State<ProductionDashboardScreen> createState() =>
      _ProductionDashboardScreenState();
}

class _ProductionDashboardScreenState extends State<ProductionDashboardScreen> {
  late Future<List<Map<String, dynamic>>> _future;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _future = Api.getApprovedPOsForProduction();
  }

  void _reload() =>
      setState(() => _future = Api.getApprovedPOsForProduction());

  bool _match(Map<String, dynamic> r) {
    if (_q.isEmpty) return true;
    final hay = [r['customer_name'], r['customer'], r['name'], r['custom_po_number']]
        .map((e) => (e ?? '').toString().toLowerCase())
        .join(' ');
    return hay.contains(_q.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text('Production · ${Session.I.productionCompany ?? ''}'),
          actions: [
            IconButton(icon: const Icon(Icons.refresh), onPressed: _reload)
          ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search customer / PO…',
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
                return Center(
                    child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text('Error: ${snap.error}')));
              }
              final all = snap.data ?? [];
              final rows = all.where(_match).toList();
              if (all.isEmpty) {
                return const Center(
                    child: Text('No approved POs waiting for SAP entry 🎉'));
              }
              if (rows.isEmpty) {
                return const Center(child: Text('No matches.'));
              }
              return ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final r = rows[i];
                  final po = '${r['custom_po_number'] ?? ''}';
                  final pstatus = '${r['custom_production_status'] ?? ''}'.isEmpty
                      ? 'Not Started'
                      : '${r['custom_production_status']}';
                  final fin = '${r['custom_production_finish_date'] ?? ''}';
                  return ListTile(
                    isThreeLine: true,
                    leading: const Icon(Icons.receipt_long,
                        color: Color(0xFF7C3AED)),
                    title: Text('${r['customer_name'] ?? r['customer'] ?? ''}'),
                    subtitle: Text('${r['name']}  ·  ${r['transaction_date'] ?? ''}'
                        '${po.isNotEmpty ? '  ·  PO $po' : ''}'
                        '\n$pstatus${(fin.isNotEmpty && fin != 'null') ? '  ·  finish $fin' : ''}'),
                    trailing: Text('₹${(r['grand_total'] ?? 0)}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    onTap: () async {
                      await Navigator.push(
                          ctx,
                          MaterialPageRoute(
                              builder: (_) => ProductionOrderDetailScreen(
                                  orderName: r['name'] as String)));
                      _reload();
                    },
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

