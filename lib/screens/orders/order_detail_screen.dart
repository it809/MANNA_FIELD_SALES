import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:manna_field_sales/pdf/proforma_pdf.dart';
import 'package:manna_field_sales/services/api.dart';

class OrderDetailScreen extends StatefulWidget {
  final String orderName;
  const OrderDetailScreen({super.key, required this.orderName});
  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  late Future<void> _init;
  Map<String, dynamic> _order = {};
  Map<String, dynamic> _customer = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init = _load();
  }

  Future<void> _load() async {
    _order = await Api.getOrder(widget.orderName);
    final cust = _order['customer'];
    if (cust != null) {
      try {
        _customer = await Api.getCustomerDoc(cust as String);
      } catch (_) {}
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  double get _outstanding => (_customer['custom_outstanding_balance'] is num)
      ? (_customer['custom_outstanding_balance'] as num).toDouble()
      : 0.0;
  double get _limit => (_customer['custom_credit_limit'] is num)
      ? (_customer['custom_credit_limit'] as num).toDouble()
      : 0.0;
  bool get _overLimit => _limit > 0 && _outstanding > _limit;

  Future<void> _generateProforma({required bool asPO}) async {
    setState(() => _busy = true);
    final err = await openProformaPdf(
        order: _order, customer: _customer, isPurchaseOrder: asPO);
    if (mounted) setState(() => _busy = false);
    if (err != null && mounted) _snack('Proforma error: $err');
  }

  Future<void> _sendProforma() async {
    final released = _order['custom_proforma_status'] == 'Released';
    if (_overLimit && !released) {
      _snack('Over credit limit — request manager release first.');
      return;
    }
    await _generateProforma(asPO: false);
    try {
      await Api.setOrderField(
          _order['name'] as String, {'custom_proforma_status': 'Sent'});
      _order['custom_proforma_status'] = 'Sent';
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _requestRelease() async {
    setState(() => _busy = true);
    try {
      await Api.setOrderField(_order['name'] as String,
          {'custom_proforma_status': 'Pending Release Approval'});
      _order['custom_proforma_status'] = 'Pending Release Approval';
      _snack('Release requested — your manager will approve.');
      setState(() {});
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scanPO() async {
    final shot = await ImagePicker()
        .pickImage(source: ImageSource.camera, imageQuality: 70);
    if (shot == null) return;
    final poNo = await _askPoNumber();
    setState(() => _busy = true);
    try {
      await Api.uploadSignedPO(
          orderName: _order['name'] as String,
          filePath: shot.path,
          poNumber: poNo);
      _order['custom_po_status'] = 'PO Uploaded - Pending Approval';
      _snack('Signed PO uploaded ✓ — awaiting manager PO approval.');
      setState(() {});
    } catch (e) {
      _snack('Upload failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askPoNumber() async {
    final ctrl = TextEditingController();
    return showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Customer PO Number (optional)'),
          content: TextField(
              controller: ctrl,
              decoration: const InputDecoration(hintText: 'e.g. 192')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, ''),
                child: const Text('Skip')),
            FilledButton(
                onPressed: () => Navigator.pop(context, ctrl.text),
                child: const Text('OK')),
          ],
        ));
  }

  Widget _statusRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(label, style: const TextStyle(color: Colors.black54)),
      Flexible(
          child: Text(value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w600))),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Order ${widget.orderName}')),
      body: FutureBuilder<void>(
        future: _init,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
          final pf = '${_order['custom_proforma_status'] ?? 'Ready'}';
          final po = '${_order['custom_po_status'] ?? 'No PO Yet'}';
          final items = (_order['items'] as List?) ?? [];
          final total = items.fold<double>(
              0, (s, it) => s + (((it['amount'] ?? 0) as num).toDouble()));
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text('${_customer['customer_name'] ?? _order['customer'] ?? ''}',
                style:
                const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
                'Order total: Rs ${total.toStringAsFixed(2)}  ·  ${items.length} item(s)'),
            const SizedBox(height: 12),
            if (_overLimit)
              Container(
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                      color: const Color(0xFFFFEBEE),
                      borderRadius: BorderRadius.circular(8)),
                  child: Row(children: [
                    const Icon(Icons.block, color: Colors.red, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(
                            'Over credit limit (Out: Rs ${_outstanding.toStringAsFixed(0)} / Limit: Rs ${_limit.toStringAsFixed(0)}). Proforma blocked until manager release.',
                            style: const TextStyle(color: Colors.red))),
                  ])),
            _statusRow('Proforma', pf),
            _statusRow('Purchase Order', po),
            if ('${_order['delivery_date'] ?? ''}'.isNotEmpty &&
                '${_order['delivery_date']}' != 'null')
              _statusRow('Required delivery', '${_order['delivery_date']}'),
            if (po == 'PO Approved - Ready for SAP')
              _statusRow(
                  'Production',
                  '${_order['custom_production_status'] ?? 'Not Started'}'
                      '${('${_order['custom_production_finish_date'] ?? ''}'.isNotEmpty && '${_order['custom_production_finish_date']}' != 'null') ? '  ·  est. finish ${_order['custom_production_finish_date']}' : ''}'),
            const Divider(height: 28),
            const Text('1 · Proforma',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_overLimit && pf != 'Released')
              FilledButton.icon(
                onPressed: _busy || pf == 'Pending Release Approval'
                    ? null
                    : _requestRelease,
                icon: const Icon(Icons.lock_clock),
                label: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(pf == 'Pending Release Approval'
                        ? 'Release requested — awaiting manager'
                        : 'Request Manager Release')),
              )
            else
              FilledButton.icon(
                onPressed: _busy ? null : _sendProforma,
                icon: const Icon(Icons.picture_as_pdf),
                label: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Text('Generate & Send Proforma')),
              ),
            const SizedBox(height: 20),
            const Text('2 · Customer Purchase Order',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text(
                'Customer signs the proforma and returns it. Scan the signed copy to upload.',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 8),
            if (po == 'PO Approved - Ready for SAP')
              Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: const Color(0xFFE8F5E9),
                      borderRadius: BorderRadius.circular(8)),
                  child: Row(children: const [
                    Icon(Icons.check_circle, color: Colors.green),
                    SizedBox(width: 8),
                    Expanded(
                        child: Text('PO approved — ready to push to SAP.',
                            style: TextStyle(color: Colors.green)))
                  ]))
            else
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.indigo),
                onPressed: _busy ? null : _scanPO,
                icon: const Icon(Icons.document_scanner),
                label: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(po == 'PO Uploaded - Pending Approval'
                        ? 'Re-scan Signed PO'
                        : 'Scan & Upload Signed PO')),
              ),
            if (_busy)
              const Padding(
                  padding: EdgeInsets.only(top: 20),
                  child: Center(child: CircularProgressIndicator())),
          ]);
        },
      ),
    );
  }
}

// -------------------- MANAGER --------------------
