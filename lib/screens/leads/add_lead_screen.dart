import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';

class AddLeadScreen extends StatefulWidget {
  const AddLeadScreen({super.key});
  @override
  State<AddLeadScreen> createState() => _AddLeadScreenState();
}

class _AddLeadScreenState extends State<AddLeadScreen> {
  late Future<List<String>> _terrFut;
  final _name = TextEditingController();
  final _company = TextEditingController();
  final _mobile = TextEditingController();
  final _email = TextEditingController();
  final _gstin = TextEditingController();
  final _address = TextEditingController();
  String? _terms;
  String? _territory;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _terrFut = Api.getTerritories();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      _snack('Enter a lead name.');
      return;
    }
    setState(() => _busy = true);
    try {
      final n = await Api.createLead(
          leadName: _name.text.trim(),
          company: _company.text,
          mobile: _mobile.text,
          email: _email.text,
          gstin: _gstin.text,
          address: _address.text,
          paymentTerms: _terms,
          territory: _territory);
      _snack('Lead created ✓  $n');
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add Lead')),
      body: FutureBuilder<List<String>>(
        future: _terrFut,
        builder: (context, snap) {
          final terrs = snap.data ?? [];
          return ListView(padding: const EdgeInsets.all(16), children: [
            TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Name *',
                    border: OutlineInputBorder())),
            const SizedBox(height: 14),
            TextField(
                controller: _company,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Company (optional)',
                    border: OutlineInputBorder())),
            const SizedBox(height: 14),
            TextField(
                controller: _mobile,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                    labelText: 'Mobile (optional)',
                    border: OutlineInputBorder())),
            const SizedBox(height: 14),
            TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                    labelText: 'Email (optional)',
                    border: OutlineInputBorder())),
            const SizedBox(height: 14),
            TextField(
                controller: _gstin,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                    labelText: 'GST number (optional)',
                    border: OutlineInputBorder())),
            const SizedBox(height: 14),
            TextField(
                controller: _address,
                minLines: 2,
                maxLines: 3,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Address (optional)',
                    border: OutlineInputBorder())),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              value: _terms,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Terms of payment (optional)',
                  border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'Cash', child: Text('Cash')),
                DropdownMenuItem(value: 'Net 15', child: Text('Net 15')),
                DropdownMenuItem(value: 'Net 30', child: Text('Net 30')),
              ],
              onChanged: (v) => setState(() => _terms = v),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              value: _territory,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Territory / Route (optional)',
                  border: OutlineInputBorder()),
              items: terrs
                  .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                  .toList(),
              onChanged: (v) => setState(() => _territory = v),
            ),
            const SizedBox(height: 12),
            Text(
                'Lead is assigned to you (${Session.I.salesPersonLabel ?? 'you'}). Take an order next — your manager approves it before you can send the proforma.',
                style: const TextStyle(fontSize: 13, color: Colors.black54)),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: _busy
                    ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                    : const Text('Save Lead'),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

