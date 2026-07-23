import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/services/api.dart';

/// Edits a customer's own particulars — name, route, group, phone and the ERP
/// customer id. Pops with the updated row so the caller can refresh in place,
/// or with nothing if the rep backed out.
///
/// The routes come from [Api.getRoutes] rather than from the routes already in
/// use, so a customer can be moved onto a route in the rep's region that has no
/// customers on it yet.
class EditCustomerScreen extends StatefulWidget {
  final Map<String, dynamic> customer;
  const EditCustomerScreen({super.key, required this.customer});
  @override
  State<EditCustomerScreen> createState() => _EditCustomerScreenState();
}

class _EditCustomerScreenState extends State<EditCustomerScreen> {
  // [routes, groups] — both dropdowns fill from one round trip.
  late Future<List<List<String>>> _options;
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _id = TextEditingController();
  String? _group;
  String? _route;
  bool _busy = false;

  late final String _originalId;

  @override
  void initState() {
    super.initState();
    _options = Future.wait([Api.getRoutes(), Api.getCustomerGroups()]);
    final c = widget.customer;
    String s(String k) => (c[k] ?? '').toString();
    _originalId = s('name');
    _id.text = _originalId;
    _name.text = s('customer_name');
    _phone.text = s('custom_phone');
    _group = s('customer_group').isEmpty ? null : s('customer_group');
    _route = s('territory').isEmpty ? null : s('territory');
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _id.dispose();
    super.dispose();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  /// The id is the document key, so changing it is a rename that reaches every
  /// document linked to this customer. Worth one deliberate tap.
  Future<bool> _confirmRename(String newId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Change customer ID?'),
        content: Text(
            'Every order, invoice, collection and visit points at "$_originalId". '
            'Renaming it to "$newId" rewrites all of them, and the server will '
            'refuse if your login has no rename rights.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Change ID')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final id = _id.text.trim();
    if (name.isEmpty) return _snack('Enter a customer name.');
    if (id.isEmpty) return _snack('Enter a customer ID.');
    if (_group == null) return _snack('Pick a customer group.');
    if (_route == null) return _snack('Pick a route.');

    final renaming = id != _originalId;
    if (renaming && !await _confirmRename(id)) return;

    setState(() => _busy = true);
    try {
      // Rename first: if the server refuses nothing has been written yet, and
      // the field update has to land on whichever id the document keeps.
      final target =
          renaming ? await Api.renameCustomer(_originalId, id) : _originalId;
      final updated = await Api.updateCustomer(
          name: target,
          customerName: name,
          group: _group,
          territory: _route,
          phone: _phone.text);
      // Trust the id the server reports back: on a site that names customers
      // after customer_name, editing the name renames the document too.
      final row = Map<String, dynamic>.from(widget.customer)..addAll(updated);
      row['name'] = '${updated['name'] ?? target}';
      _snack('Customer updated ✓');
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) Navigator.pop(context, row);
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Customer')),
      body: FutureBuilder<List<List<String>>>(
        future: _options,
        builder: (context, snap) {
          final loading = !snap.hasData && snap.error == null;
          final routes = [...?snap.data?[0]];
          final groups = [...?snap.data?[1]];
          // The saved value may not be in the fetched list (still loading, or
          // the route/group was retired) — keep it selectable so an unrelated
          // edit can't silently move the customer off it.
          if (_route != null && !routes.contains(_route)) {
            routes.insert(0, _route!);
          }
          if (_group != null && !groups.contains(_group)) {
            groups.insert(0, _group!);
          }
          return ListView(padding: const EdgeInsets.all(16), children: [
            TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Customer name *',
                    prefixIcon: Icon(Icons.store, size: 18),
                    border: OutlineInputBorder())),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              value: _route,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Route *',
                prefixIcon: const Icon(Icons.alt_route, size: 18),
                border: const OutlineInputBorder(),
                suffixIcon: loading
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2)))
                    : null,
              ),
              hint: Text(loading ? 'Loading routes…' : 'Select a route'),
              items: routes
                  .map((r) => DropdownMenuItem(
                      value: r,
                      child: Text(r, overflow: TextOverflow.ellipsis)))
                  .toList(),
              onChanged: (v) => setState(() => _route = v),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              value: _group,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Group *',
                  prefixIcon: Icon(Icons.category_outlined, size: 18),
                  border: OutlineInputBorder()),
              hint: Text(loading ? 'Loading groups…' : 'Select a group'),
              items: groups
                  .map((g) => DropdownMenuItem(
                      value: g,
                      child: Text(g, overflow: TextOverflow.ellipsis)))
                  .toList(),
              onChanged: (v) => setState(() => _group = v),
            ),
            const SizedBox(height: 14),
            TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                    labelText: 'Phone',
                    prefixIcon: Icon(Icons.phone, size: 18),
                    border: OutlineInputBorder())),
            const SizedBox(height: 14),
            TextField(
                controller: _id,
                decoration: const InputDecoration(
                    labelText: 'Customer ID *',
                    prefixIcon: Icon(Icons.badge_outlined, size: 18),
                    helperText:
                        'Renames the customer everywhere it is linked. Leave it '
                        'alone unless the ID itself is wrong.',
                    helperMaxLines: 3,
                    border: OutlineInputBorder())),
            if (snap.hasError)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text('Could not load routes/groups: ${snap.error}',
                    style: const TextStyle(fontSize: 12, color: Colors.red)),
              ),
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
                    : const Text('Save Changes'),
              ),
            ),
          ]);
        },
      ),
    );
  }
}
