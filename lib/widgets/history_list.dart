import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/app_bus.dart';
import 'package:manna_field_sales/widgets/error_view.dart';


class HistoryList extends StatefulWidget {
  final String title;
  final Future<List<Map<String, dynamic>>> Function() loader;
  final Widget Function(BuildContext, Map<String, dynamic>) tileBuilder;

  /// Reload whenever anything in the app writes. Set on lists whose rows can
  /// be changed from the row itself, so an edit or delete leaves the list it
  /// was made from without waiting for a manual refresh.
  final bool liveRefresh;

  const HistoryList(
      {required this.title,
      required this.loader,
      required this.tileBuilder,
      this.liveRefresh = false});
  @override
  State<HistoryList> createState() => _HistoryListState();
}

class _HistoryListState extends State<HistoryList> {
  late Future<List<Map<String, dynamic>>> _future;
  String _q = '';
  @override
  void initState() {
    super.initState();
    _future = widget.loader();
    if (widget.liveRefresh) AppBus.I.addListener(_reload);
  }

  @override
  void dispose() {
    if (widget.liveRefresh) AppBus.I.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    setState(() { _future = widget.loader(); });
  }

  bool _match(Map<String, dynamic> r) {
    if (_q.isEmpty) return true;
    final hay = r.values.map((e) => (e ?? '').toString().toLowerCase()).join(' ');
    return hay.contains(_q.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search…',
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
                return const Center(child: Text('Nothing here yet.'));
              }
              if (rows.isEmpty) {
                return const Center(child: Text('No matches.'));
              }
              return ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) => widget.tileBuilder(ctx, rows[i]),
              );
            },
          ),
        ),
      ]),
    );
  }
}

