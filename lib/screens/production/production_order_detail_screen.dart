import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/services/api.dart';

class ProductionOrderDetailScreen extends StatefulWidget {
  final String orderName;
  const ProductionOrderDetailScreen({super.key, required this.orderName});
  @override
  State<ProductionOrderDetailScreen> createState() =>
      _ProductionOrderDetailScreenState();
}

class _ProductionOrderDetailScreenState
    extends State<ProductionOrderDetailScreen> {
  Map<String, dynamic>? _order;
  bool _loading = true;
  bool _saving = false;
  String _status = 'Not Started';
  DateTime? _finish;

  static const _statuses = [
    'Not Started',
    'In Production',
    'Ready',
    'Dispatched'
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final o = await Api.getOrder(widget.orderName);
      _order = o;
      _status = '${o['custom_production_status'] ?? ''}'.isEmpty
          ? 'Not Started'
          : '${o['custom_production_status']}';
      final fd = '${o['custom_production_finish_date'] ?? ''}';
      if (fd.isNotEmpty && fd != 'null') _finish = DateTime.tryParse(fd);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final fd = _finish == null
          ? null
          : '${_finish!.year}-${_finish!.month.toString().padLeft(2, '0')}-${_finish!.day.toString().padLeft(2, '0')}';
      await Api.setProductionStatus(
          orderName: widget.orderName, status: _status, finishDate: fd);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Production status saved ✓')));
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.orderName)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final o = _order ?? {};
    final items = (o['items'] as List?) ?? [];
    final total = items.fold<double>(
        0, (s, it) => s + (((it['amount'] ?? 0) as num).toDouble()));
    return Scaffold(
      appBar: AppBar(title: Text(widget.orderName)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('${o['customer_name'] ?? o['customer'] ?? ''}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text('Order ${o['name']}  ·  ${o['transaction_date'] ?? ''}'),
        if ('${o['custom_po_number'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('Customer PO: ${o['custom_po_number']}'),
          ),
        if ('${o['delivery_date'] ?? ''}'.isNotEmpty &&
            '${o['delivery_date']}' != 'null')
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              const Icon(Icons.event_available,
                  size: 18, color: Color(0xFFB45309)),
              const SizedBox(width: 6),
              Text('Required delivery: ${o['delivery_date']}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, color: Color(0xFFB45309))),
            ]),
          ),
        const SizedBox(height: 16),
        Card(
          color: const Color(0xFFF5F3FF),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Production',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF7C3AED))),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: _status,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: 'Production status',
                        border: OutlineInputBorder(),
                        isDense: true),
                    items: _statuses
                        .map((s) =>
                        DropdownMenuItem(value: s, child: Text(s)))
                        .toList(),
                    onChanged: _saving
                        ? null
                        : (v) => setState(() => _status = v ?? _status),
                  ),
                  const SizedBox(height: 10),
                  InkWell(
                    onTap: _saving
                        ? null
                        : () async {
                      final now = DateTime.now();
                      final d = await showDatePicker(
                        context: context,
                        initialDate: _finish ?? now,
                        firstDate: now.subtract(const Duration(days: 30)),
                        lastDate: now.add(const Duration(days: 365)),
                      );
                      if (d != null) setState(() => _finish = d);
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(
                          labelText: 'Estimated finish date',
                          border: OutlineInputBorder(),
                          isDense: true),
                      child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_finish == null
                                ? 'Not set'
                                : '${_finish!.day}/${_finish!.month}/${_finish!.year}'),
                            const Icon(Icons.calendar_today, size: 18),
                          ]),
                    ),
                  ),
                  if (_finish != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _saving
                            ? null
                            : () => setState(() => _finish = null),
                        child: const Text('Clear date'),
                      ),
                    ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                          : const Text('Save status'),
                    ),
                  ),
                ]),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: const Color(0xFFF3E8FF),
              borderRadius: BorderRadius.circular(8)),
          child: Row(children: const [
            Icon(Icons.info_outline, color: Color(0xFF7C3AED), size: 20),
            SizedBox(width: 8),
            Expanded(
                child: Text(
                    'Create this Sales Order in SAP manually using the details below.',
                    style: TextStyle(fontSize: 13))),
          ]),
        ),
        const SizedBox(height: 16),
        const Text('Items', style: TextStyle(fontWeight: FontWeight.bold)),
        const Divider(),
        ...items.map((it) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(
                child: Text('${it['item_name'] ?? it['item_code'] ?? ''}')),
            Text('${(it['qty'] ?? 0)} × ₹${(it['rate'] ?? 0)}'),
            const SizedBox(width: 8),
            Text('₹${((it['amount'] ?? 0) as num).toStringAsFixed(0)}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
        )),
        const Divider(),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Total', style: TextStyle(fontWeight: FontWeight.bold)),
          Text('₹${total.toStringAsFixed(2)}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
      ]),
    );
  }
}

// -------------------- RETREAD PROFORMA (Manna Tyre Retreads reps) --------------------
