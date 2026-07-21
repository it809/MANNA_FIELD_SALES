import 'dart:async';

import 'package:flutter/material.dart';


class HistoryList extends StatefulWidget {
  final String title;
  final Future<List<Map<String, dynamic>>> Function() loader;
  final Widget Function(BuildContext, Map<String, dynamic>) tileBuilder;
  const HistoryList(
      {required this.title, required this.loader, required this.tileBuilder});
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
        IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() { _future = widget.loader(); })),
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
                return Center(
                    child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text('Error: ${snap.error}')));
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

