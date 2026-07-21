import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/screens/customers/customer_detail_screen.dart';
import 'package:manna_field_sales/services/api.dart';

class CustomerListScreen extends StatefulWidget {
  const CustomerListScreen({super.key});
  @override
  State<CustomerListScreen> createState() => _CustomerListScreenState();
}

class _CustomerListScreenState extends State<CustomerListScreen> {
  late Future<List<List<Map<String, dynamic>>>> _future;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<List<Map<String, dynamic>>>> _load() async {
    return await Future.wait([Api.getCustomers(), Api.getSalesPersons()]);
  }

  bool _match(Map<String, dynamic> c) {
    if (_q.isEmpty) return true;
    final hay = [c['customer_name'], c['name'], c['customer_group'], c['territory']]
        .map((e) => (e ?? '').toString().toLowerCase())
        .join(' ');
    return hay.contains(_q.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Customers'), actions: [
        IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() { _future = _load(); })),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search customers…',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<List<Map<String, dynamic>>>>(
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
              final all = snap.data![0];
              final reps = snap.data![1];
              final customers = all.where(_match).toList();
              if (all.isEmpty) {
                return const Center(child: Text('No customers found.'));
              }
              if (customers.isEmpty) {
                return const Center(child: Text('No matches.'));
              }
              return ListView.separated(
                itemCount: customers.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final c = customers[i];
                  final sub = [c['customer_group'], c['territory']]
                      .where((x) => x != null && '$x'.isNotEmpty)
                      .join(' · ');
                  final bal = (c['custom_outstanding_balance'] is num)
                      ? (c['custom_outstanding_balance'] as num).toDouble()
                      : 0.0;
                  return ListTile(
                    title: Text(c['customer_name'] ?? c['name']),
                    subtitle: sub.isEmpty ? null : Text(sub),
                    trailing: bal > 0
                        ? Text('₹${bal.toStringAsFixed(0)}',
                        style: const TextStyle(
                            color: Colors.red, fontWeight: FontWeight.bold))
                        : const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            CustomerDetailScreen(customer: c, reps: reps))),
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

