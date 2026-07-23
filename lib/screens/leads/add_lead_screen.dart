import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/net_error.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/error_view.dart';

class AddLeadScreen extends StatefulWidget {
  /// Pass an existing lead row to edit it; omit it to create a new one.
  final Map<String, dynamic>? lead;
  const AddLeadScreen({super.key, this.lead});
  @override
  State<AddLeadScreen> createState() => _AddLeadScreenState();
}

class _AddLeadScreenState extends State<AddLeadScreen> {
  // Prefixes the "add this as a new route" entry in the suggestion list, so it
  // can travel through the autocomplete as an option like any other. Nobody
  // names a route this, and if they did the entry would simply offer to create
  // it — which is what it does anyway.
  static const _addRoute = '::add-route::';

  final _name = TextEditingController();
  final _company = TextEditingController();
  final _mobile = TextEditingController();
  final _email = TextEditingController();
  final _gstin = TextEditingController();
  final _address = TextEditingController();
  // The route is typed rather than picked from a list — reps know their route
  // names and a long dropdown is slow to work down on a phone. The text is
  // still matched against the rep's routes before saving, because territory is
  // a link on the server and a name it doesn't know would be rejected.
  final _route = TextEditingController();
  final _routeFocus = FocusNode();
  List<String> _routes = [];
  bool _routesLoading = true;
  Object? _routesError;
  String? _terms;
  bool _busy = false;

  bool get _editing => widget.lead != null;

  @override
  void initState() {
    super.initState();
    final l = widget.lead;
    if (l != null) {
      String s(String k) => (l[k] ?? '').toString();
      _name.text = s('lead_name');
      _company.text = s('company_name');
      _mobile.text = s('mobile_no');
      _email.text = s('email_id');
      _gstin.text = s('custom_gstin');
      _address.text = s('custom_address');
      _terms = s('custom_payment_terms').isEmpty
          ? null
          : s('custom_payment_terms');
      _route.text = s('territory');
    }
    _loadRoutes();
  }

  @override
  void dispose() {
    _name.dispose();
    _company.dispose();
    _mobile.dispose();
    _email.dispose();
    _gstin.dispose();
    _address.dispose();
    _route.dispose();
    _routeFocus.dispose();
    super.dispose();
  }

  Future<void> _loadRoutes() async {
    setState(() {
      _routesLoading = true;
      _routesError = null;
    });
    try {
      final r = await Api.getRoutes();
      if (!mounted) return;
      // The route the lead already sits on may be outside what the rep is
      // offered — a retired route, or one in another region. Keep it valid so
      // an unrelated edit can't be blocked by it.
      final saved = _route.text.trim();
      final all = [...r];
      if (saved.isNotEmpty &&
          !all.any((t) => t.toLowerCase() == saved.toLowerCase())) {
        all.insert(0, saved);
      }
      setState(() {
        _routes = all;
        _routesLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _routesError = e;
        _routesLoading = false;
      });
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  /// The typed route as the server knows it: matched case-insensitively against
  /// the rep's routes so 'kochi south' saves as 'Kochi South'. Returns `('', ...)`
  /// for a blank route — it stays optional — and a null name when the text
  /// matches nothing, which is what stops the save.
  (String? name, bool ok) _resolveRoute() {
    final typed = _route.text.trim();
    if (typed.isEmpty) return (null, true);
    for (final r in _routes) {
      if (r.toLowerCase() == typed.toLowerCase()) return (r, true);
    }
    // The list never loaded, so there is nothing to check against — send what
    // was typed and let the server have the final word.
    if (_routes.isEmpty) return (typed, true);
    return (null, false);
  }

  /// Adds a route the tree does not have yet. Territory is master data shared
  /// by everyone working the region, so the rep confirms before it is written.
  /// Returns the name the server gave it, or null if they backed out or it
  /// failed — a login without create rights is refused by the server.
  Future<String?> _addNewRoute(String typed) async {
    final name = typed.trim();
    if (name.isEmpty) return null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add a new route?'),
        content: Text('"$name" is not one of your routes yet. Adding it '
            'creates the route for everyone working your region, so check the '
            'spelling first.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Add route')),
        ],
      ),
    );
    if (ok != true || !mounted) return null;

    setState(() => _busy = true);
    try {
      final created = await Api.createRoute(name);
      if (!mounted) return null;
      setState(() {
        _routes = [
          created,
          ..._routes.where((r) => r.toLowerCase() != created.toLowerCase()),
        ];
        _route.text = created;
      });
      _snack('Route "$created" added ✓');
      return created;
    } catch (e) {
      if (mounted) _snack(errorLine(e));
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      _snack('Enter a lead name.');
      return;
    }
    var (route, routeOk) = _resolveRoute();
    // Typed a route nobody has yet — offer to add it rather than refusing the
    // save outright.
    if (!routeOk) {
      route = await _addNewRoute(_route.text);
      if (route == null || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      if (_editing) {
        final updated = await Api.updateLead(
            name: widget.lead!['name'] as String,
            leadName: _name.text.trim(),
            company: _company.text,
            mobile: _mobile.text,
            email: _email.text,
            gstin: _gstin.text,
            address: _address.text,
            paymentTerms: _terms,
            territory: route);
        _snack('Lead updated ✓');
        await Future.delayed(const Duration(milliseconds: 500));
        if (mounted) Navigator.pop(context, updated);
      } else {
        final n = await Api.createLead(
            leadName: _name.text.trim(),
            company: _company.text,
            mobile: _mobile.text,
            email: _email.text,
            gstin: _gstin.text,
            address: _address.text,
            paymentTerms: _terms,
            territory: route);
        _snack('Lead created ✓  $n');
        await Future.delayed(const Duration(milliseconds: 500));
        if (mounted) Navigator.pop(context, true);
      }
    } catch (e) {
      _snack(errorLine(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Type-to-search over the rep's routes. Typing filters the list; an empty
  /// box offers every route the rep works, so it still browses like a dropdown.
  Widget _routeField() {
    return LayoutBuilder(builder: (context, box) {
      return RawAutocomplete<String>(
        textEditingController: _route,
        focusNode: _routeFocus,
        displayStringForOption: (o) =>
            o.startsWith(_addRoute) ? o.substring(_addRoute.length) : o,
        optionsBuilder: (value) {
          final typed = value.text.trim();
          final q = typed.toLowerCase();
          if (q.isEmpty) return _routes;
          final hits =
              _routes.where((r) => r.toLowerCase().contains(q)).toList();
          // Nothing on the list is exactly what they typed, so offer to add it.
          // This also keeps the overlay open when nothing matches at all —
          // otherwise there would be nowhere to put the option.
          if (!_routes.any((r) => r.toLowerCase() == q)) {
            hits.add('$_addRoute$typed');
          }
          return hits;
        },
        onSelected: (v) {
          if (v.startsWith(_addRoute)) {
            _addNewRoute(v.substring(_addRoute.length));
          } else {
            _route.text = v;
          }
        },
        fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
          return TextField(
            controller: controller,
            focusNode: focusNode,
            textCapitalization: TextCapitalization.words,
            onSubmitted: (_) => onFieldSubmitted(),
            decoration: InputDecoration(
              labelText: 'Territory / Route (optional)',
              prefixIcon: const Icon(Icons.alt_route, size: 18),
              border: const OutlineInputBorder(),
              helperText: _routesLoading
                  ? 'Loading your routes…'
                  : 'Type to search, or tap to see all your routes',
              helperMaxLines: 2,
              suffixIcon: _routesLoading
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)))
                  : (controller.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear route',
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () => setState(controller.clear),
                        )),
            ),
          );
        },
        optionsViewBuilder: (context, onSelected, options) {
          final list = options.toList();
          return Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 4,
              child: SizedBox(
                width: box.maxWidth,
                height: list.length > 5 ? 260.0 : null,
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: list.length <= 5,
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final o = list[i];
                    final adding = o.startsWith(_addRoute);
                    final label =
                        adding ? o.substring(_addRoute.length) : o;
                    return ListTile(
                      dense: true,
                      leading: Icon(
                          adding ? Icons.add_road : Icons.alt_route,
                          size: 18,
                          color: adding ? Theme.of(context).primaryColor : null),
                      title: Text(adding ? 'Add new route "$label"' : label,
                          overflow: TextOverflow.ellipsis,
                          style: adding
                              ? TextStyle(
                                  color: Theme.of(context).primaryColor,
                                  fontWeight: FontWeight.w600)
                              : null),
                      onTap: () => onSelected(o),
                    );
                  },
                ),
              ),
            ),
          );
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final terms = ['Cash', 'Net 15', 'Net 30'];
    if (_terms != null && !terms.contains(_terms)) terms.insert(0, _terms!);

    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Edit Lead' : 'Add Lead')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
                labelText: 'Name *', border: OutlineInputBorder())),
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
                labelText: 'Mobile (optional)', border: OutlineInputBorder())),
        const SizedBox(height: 14),
        TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
                labelText: 'Email (optional)', border: OutlineInputBorder())),
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
                labelText: 'Address (optional)', border: OutlineInputBorder())),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          value: _terms,
          isExpanded: true,
          decoration: const InputDecoration(
              labelText: 'Terms of payment (optional)',
              border: OutlineInputBorder()),
          items: terms
              .map((t) => DropdownMenuItem(value: t, child: Text(t)))
              .toList(),
          onChanged: (v) => setState(() => _terms = v),
        ),
        const SizedBox(height: 14),
        _routeField(),
        if (_routesError != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: InlineError(
              error: _routesError,
              label: 'Could not load your routes',
              onRetry: _loadRoutes,
            ),
          ),
        const SizedBox(height: 12),
        if (!_editing)
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
                : Text(_editing ? 'Save Changes' : 'Save Lead'),
          ),
        ),
      ]),
    );
  }
}
