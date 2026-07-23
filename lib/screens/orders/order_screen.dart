import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/net_error.dart';
import 'package:manna_field_sales/screens/orders/order_detail_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/error_view.dart';

class OrderScreen extends StatefulWidget {
  final Map<String, dynamic> customer;
  const OrderScreen({super.key, required this.customer});
  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  late Future<void> _init;
  List<Map<String, dynamic>> _items = [];
  String _company = '';
  final Map<String, int> _qty = {};
  bool _submitting = false;
  String _q = '';
  DateTime? _deliveryDate;

  List<Map<String, dynamic>> get _filtered {
    if (_q.trim().isEmpty) return _items;
    final qq = _q.toLowerCase();
    return _items
        .where((it) => ('${it['item_name'] ?? ''} ${it['name'] ?? ''}')
        .toLowerCase()
        .contains(qq))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _init = _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([Api.getItems(), Api.getCompany()]);
    _items = results[0] as List<Map<String, dynamic>>;
    _company = results[1] as String;
  }

  void _reload() => setState(() => _init = _load());

  double get _total {
    double t = 0;
    for (final it in _items) {
      final q = _qty[it['name']] ?? 0;
      t += q * ((it['standard_rate'] ?? 0) as num).toDouble();
    }
    return t;
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  Future<void> _submit() async {
    final lines = <Map<String, dynamic>>[];
    for (final it in _items) {
      final q = _qty[it['name']] ?? 0;
      if (q > 0) {
        lines.add({
          'item_code': it['name'],
          'qty': q,
          'rate': ((it['standard_rate'] ?? 0) as num).toDouble(),
        });
      }
    }
    if (lines.isEmpty) {
      _snack('Add at least one item (use + ).');
      return;
    }
    if (_deliveryDate == null) {
      _snack('Pick a required delivery date.');
      return;
    }
    setState(() => _submitting = true);
    try {
      final dd =
          '${_deliveryDate!.year}-${_deliveryDate!.month.toString().padLeft(2, '0')}-${_deliveryDate!.day.toString().padLeft(2, '0')}';
      final name = await Api.createSalesOrder(
          customer: widget.customer['name'],
          company: _company,
          items: lines,
          deliveryDate: dd);
      _snack('Order saved ✓  $name');
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) {
        Navigator.pushReplacement(
            context,
            MaterialPageRoute(
                builder: (_) => OrderDetailScreen(orderName: name)));
      }
    } catch (e) {
      _snack(errorLine(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(
              'Order — ${widget.customer['customer_name'] ?? widget.customer['name']}')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search products…',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Expanded(
          child: FutureBuilder<void>(
            future: _init,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return ErrorView(error: snap.error, onRetry: _reload);
              }
              if (_items.isEmpty) {
                return const Center(child: Text('No sellable items found.'));
              }
              final shown = _filtered;
              if (shown.isEmpty) {
                return const Center(child: Text('No matching products.'));
              }
              return ListView.separated(
                itemCount: shown.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final it = shown[i];
                  final code = it['name'] as String;
                  final rate = ((it['standard_rate'] ?? 0) as num).toDouble();
                  final q = _qty[code] ?? 0;
                  return ListTile(
                    title: Text(it['item_name'] ?? code),
                    subtitle:
                    Text('₹${rate.toStringAsFixed(2)} / ${it['stock_uom'] ?? ''}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed:
                          q > 0 ? () => setState(() => _qty[code] = q - 1) : null),
                      Text('$q', style: const TextStyle(fontSize: 16)),
                      IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: () => setState(() => _qty[code] = q + 1)),
                    ]),
                  );
                },
              );
            },
          ),
        ),
      ]),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          InkWell(
            onTap: _submitting
                ? null
                : () async {
              final now = DateTime.now();
              final d = await showDatePicker(
                context: context,
                initialDate:
                _deliveryDate ?? now.add(const Duration(days: 7)),
                firstDate: now,
                lastDate: now.add(const Duration(days: 365)),
              );
              if (d != null) setState(() => _deliveryDate = d);
            },
            child: InputDecorator(
              decoration: const InputDecoration(
                  labelText: 'Required delivery date',
                  border: OutlineInputBorder(),
                  isDense: true),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_deliveryDate == null
                        ? 'Tap to pick a date'
                        : '${_deliveryDate!.day}/${_deliveryDate!.month}/${_deliveryDate!.year}'),
                    const Icon(Icons.event, size: 18),
                  ]),
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
                child: Text('Total: ₹${_total.toStringAsFixed(2)}',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold))),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              child: Padding(
                padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: _submitting
                    ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                    : const Text('Submit Order'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

// -------------------- COLLECTION --------------------
