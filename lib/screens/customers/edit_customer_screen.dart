import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/net_error.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/error_view.dart';

/// Edits a customer's own particulars — name, route, group, phone and the ERP
/// customer id. Pops with the updated row so the caller can refresh in place,
/// or with nothing if the rep backed out.
///
/// The routes come from [Api.getRoutes] rather than from the routes already in
/// use, so a customer can be moved onto a route in the rep's region that has no
/// customers on it yet — and onto one that does not exist yet, which the rep
/// can add from the field without waiting on the office.
class EditCustomerScreen extends StatefulWidget {
  final Map<String, dynamic> customer;
  const EditCustomerScreen({super.key, required this.customer});
  @override
  State<EditCustomerScreen> createState() => _EditCustomerScreenState();
}

class _EditCustomerScreenState extends State<EditCustomerScreen> {
  // Prefixes the "add this as a new route" entry in the suggestion list, so it
  // can travel through the autocomplete as an option like any other. Nobody
  // names a route this, and if they did the entry would simply offer to create
  // it — which is what it does anyway.
  static const _addRoute = '::add-route::';

  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _id = TextEditingController();
  // Group is typed rather than picked: the list is long, rarely changes, and
  // reps know the handful they use. The server has the final word — it is a
  // link field, so a group it does not know comes back as a plain error.
  final _group = TextEditingController();
  // The route is typed too, and matched against the rep's routes before saving
  // for the same reason. What is typed and matches nothing becomes an offer to
  // create the route rather than a refused save.
  final _route = TextEditingController();
  final _routeFocus = FocusNode();
  List<String> _routes = [];
  bool _routesLoading = true;
  Object? _routesError;
  bool _busy = false;

  late final String _originalId;

  @override
  void initState() {
    super.initState();
    final c = widget.customer;
    String s(String k) => (c[k] ?? '').toString();
    _originalId = s('name');
    _id.text = _originalId;
    _name.text = s('customer_name');
    _phone.text = s('custom_phone');
    _group.text = s('customer_group');
    _route.text = s('territory');
    _loadRoutes();
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _id.dispose();
    _group.dispose();
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
      // The route the customer already sits on may be outside what the rep is
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

  /// The typed route as the server knows it: matched case-insensitively against
  /// the rep's routes so 'kochi south' saves as 'Kochi South'. A null name with
  /// `ok: false` means the text matches nothing, which is what stops the save
  /// and offers to add the route instead.
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
    final name = _name.text.trim();
    final id = _id.text.trim();
    final group = _group.text.trim();
    if (name.isEmpty) return _snack('Enter a customer name.');
    if (id.isEmpty) return _snack('Enter a customer ID.');
    if (group.isEmpty) return _snack('Enter a customer group.');
    if (_route.text.trim().isEmpty) return _snack('Enter a route.');

    var (route, routeOk) = _resolveRoute();
    // Typed a route nobody has yet — offer to add it rather than refusing the
    // save outright.
    if (!routeOk) {
      route = await _addNewRoute(_route.text);
      if (route == null || !mounted) return;
    }

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
          group: group,
          territory: route,
          phone: _phone.text);
      // Trust the id the server reports back: on a site that names customers
      // after customer_name, editing the name renames the document too.
      final row = Map<String, dynamic>.from(widget.customer)..addAll(updated);
      row['name'] = '${updated['name'] ?? target}';
      _snack('Customer updated ✓');
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) Navigator.pop(context, row);
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
              labelText: 'Route *',
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
                    final label = adding ? o.substring(_addRoute.length) : o;
                    return ListTile(
                      dense: true,
                      leading: Icon(adding ? Icons.add_road : Icons.alt_route,
                          size: 18,
                          color:
                              adding ? Theme.of(context).primaryColor : null),
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
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Customer')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
                labelText: 'Customer name *',
                prefixIcon: Icon(Icons.store, size: 18),
                border: OutlineInputBorder())),
        const SizedBox(height: 14),
        _routeField(),
        const SizedBox(height: 14),
        TextField(
            controller: _group,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
                labelText: 'Group *',
                prefixIcon: Icon(Icons.category_outlined, size: 18),
                helperText: 'Type the group exactly as it is named in the ERP.',
                helperMaxLines: 2,
                border: OutlineInputBorder())),
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
        if (_routesError != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: InlineError(
              error: _routesError,
              label: 'Could not load your routes',
              onRetry: _loadRoutes,
            ),
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
      ]),
    );
  }
}
