
import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/server_clock.dart';
import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/history_list.dart';

class MyVisitsScreen extends StatelessWidget {
  const MyVisitsScreen({super.key});

  /// Opens the tapped visit. The list row only carries the few fields the tile
  /// renders, so the full document is read first — the editor needs the
  /// purpose and both punch stamps, which the list never asks for.
  ///
  /// The messenger is taken before the first await: a delete drops the row
  /// this was tapped from, and the tile's own context is gone by the time
  /// there is something to say about it.
  Future<void> _open(BuildContext context, Map<String, dynamic> row) async {
    final name = '${row['name'] ?? ''}';
    if (name.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    Map<String, dynamic> doc;
    try {
      doc = await Api.getVisit(name);
    } catch (e) {
      _say(messenger, 'Could not open this visit: $e');
      return;
    }
    // The list resolved the lead's name for the row; the raw document only
    // carries its id, and the rep knows the shop by its name.
    final leadName = row['custom_lead_name'];
    if (leadName != null) doc['custom_lead_name'] = leadName;
    if (!context.mounted) return;
    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _VisitDialog(visit: doc),
    );
    if (res == null) return;
    if (res['action'] == 'delete') {
      if (!context.mounted) return;
      await _delete(context, doc);
    } else {
      await _save(messenger, doc, res);
    }
  }

  static void _say(ScaffoldMessengerState m, String text) =>
      m.showSnackBar(SnackBar(content: Text(text)));

  Future<void> _save(ScaffoldMessengerState messenger,
      Map<String, dynamic> doc, Map<String, dynamic> edit) async {
    try {
      await Api.updateVisit(
        name: '${doc['name']}',
        purpose: '${edit['purpose'] ?? ''}',
        checkInTime: '${doc['check_in_time'] ?? ''}',
        checkOutTime: edit['check_out_time'] as String?,
      );
      _say(messenger, 'Visit updated ✓');
    } catch (e) {
      _say(messenger, 'Could not save: $e');
    }
  }

  Future<void> _delete(BuildContext context, Map<String, dynamic> doc) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Delete this visit?'),
        content: Text(
            'The visit to ${Api.visitParty(doc)} on ${doc['visit_date']} will be '
            'removed for good, along with the GPS it was punched in at. It '
            'disappears from the Day Map, from its trip, and from today\'s '
            'visit count.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('Keep visit')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.deleteVisit('${doc['name']}');
      _say(messenger, 'Visit deleted ✓');
    } catch (e) {
      _say(messenger, 'Could not delete: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return HistoryList(
      title: 'My Visits',
      loader: Api.getMyVisitsIncludingTagged,
      // Edits and deletes are made from these rows, so the list follows them.
      liveRefresh: true,
      tileBuilder: (ctx, r) {
        final by = '${r['sales_person'] ?? ''}';
        // Ownership decides both how the row reads and whether it can be
        // touched, so the two can never disagree — a row nobody owns falls
        // through to read-only rather than offering an edit that would fail.
        final mine = Api.canEditVisit(r);
        final shared = !mine;
        final isLead = Api.isLeadVisit(r);
        return ListTile(
          leading: Icon(
              shared
                  ? Icons.group
                  : (isLead ? Icons.person_pin_circle : Icons.location_on),
              color: shared ? const Color(0xFFF46A21) : null),
          title: Text(Api.visitParty(r)),
          subtitle: Text(
              '${isLead ? 'Lead  ·  ' : ''}'
                  '${r['visit_date'] ?? ''}  ·  ${r['visit_status'] ?? ''}'
                  '${shared && by.isNotEmpty ? '  ·  logged by $by' : ''}'),
          trailing: mine
              ? PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'edit') {
                      await _open(ctx, r);
                    } else if (v == 'delete') {
                      // The row already names the party and the date, which is
                      // all the confirmation quotes back — no need to fetch
                      // the document just to throw it away.
                      await _delete(ctx, r);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit visit')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                )
              : const Chip(
                  label: Text('Shared', style: TextStyle(fontSize: 10)),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: Color(0xFFFFE8DC)),
          onTap: () => _open(ctx, r),
        );
      },
    );
  }
}

/// Edits one visit. Pops `{'action':'save', 'purpose':…, 'check_out_time':…}`,
/// or `{'action':'delete'}`, or null when the rep backs out. Nothing is written
/// from here — the caller owns the API calls and the messages they produce.
class _VisitDialog extends StatefulWidget {
  final Map<String, dynamic> visit;
  const _VisitDialog({required this.visit});
  @override
  State<_VisitDialog> createState() => _VisitDialogState();
}

class _VisitDialogState extends State<_VisitDialog> {
  late final TextEditingController _purpose;
  DateTime? _checkIn;
  DateTime? _checkOut;

  @override
  void initState() {
    super.initState();
    final v = widget.visit;
    _purpose = TextEditingController(text: '${v['visit_purpose'] ?? ''}');
    _checkIn = _parse(v['check_in_time']);
    _checkOut = _parse(v['check_out_time']);
  }

  @override
  void dispose() {
    _purpose.dispose();
    super.dispose();
  }

  static DateTime? _parse(dynamic v) {
    final s = '${v ?? ''}';
    if (s.isEmpty || s == 'null') return null;
    return DateTime.tryParse(s.replaceFirst(' ', 'T'));
  }

  static String _stamp(DateTime d) =>
      d.toIso8601String().substring(0, 19).replaceFirst('T', ' ');

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m)));

  /// The day the visit belongs to — its check-in, else the date field. A visit
  /// is a single day's event, so the punch-out is picked as a time on that day
  /// rather than as a free date and time.
  DateTime get _day {
    final anchor = _checkIn ?? _parse(widget.visit['visit_date']);
    final d = anchor ?? ServerClock.I.now();
    return DateTime(d.year, d.month, d.day);
  }

  Future<void> _pickCheckOut() async {
    final init = _checkOut ??
        (_checkIn?.add(const Duration(minutes: 30)) ?? ServerClock.I.now());
    final t = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(init));
    if (t == null) return;
    final picked =
        DateTime(_day.year, _day.month, _day.day, t.hour, t.minute);
    if (_checkIn != null && !picked.isAfter(_checkIn!)) {
      return _snack(
          'Punch-out has to be after ${hhmm(widget.visit['check_in_time'])}, when the visit started.');
    }
    // The server's clock, not the phone's — the same rule the punch card runs.
    if (picked.isAfter(ServerClock.I.now())) {
      return _snack('That time has not happened yet.');
    }
    setState(() => _checkOut = picked);
  }

  String _durationLine() {
    if (_checkOut == null) return 'Still open — no punch-out on record';
    if (_checkIn == null) return 'Completed';
    final m = _checkOut!.difference(_checkIn!).inMinutes;
    return 'Completed  ·  $m min';
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 92,
              child: Text(k,
                  style: const TextStyle(
                      color: Colors.black54, fontSize: 13))),
          Expanded(
              child: Text(v,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final v = widget.visit;
    final editable = Api.canEditVisit(v);
    final trip = '${v['custom_trip'] ?? ''}';
    return AlertDialog(
      title: Text(Api.visitParty(v)),
      content: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${Api.isLeadVisit(v) ? 'Lead visit' : 'Visit'}  ·  ${v['name']}',
                  style:
                      const TextStyle(fontSize: 12, color: Colors.black45)),
              const SizedBox(height: 10),
              _row('Date', '${v['visit_date'] ?? '—'}'),
              _row('Punched in', hhmm(v['check_in_time'])),
              if (trip.isNotEmpty && trip != 'null') _row('Trip', trip),
              if (!editable) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEEF2FF),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                      'Logged by ${v['sales_person']}. You can see this visit '
                      'because you are tagged on its trip — only the rep who '
                      'punched it in can change it.',
                      style: const TextStyle(fontSize: 12)),
                ),
                const SizedBox(height: 10),
                _row('Purpose', '${v['visit_purpose'] ?? '—'}'),
                _row('Punched out', hhmm(v['check_out_time'])),
                _row('Status', '${v['visit_status'] ?? '—'}'),
              ] else ...[
                const SizedBox(height: 14),
                TextField(
                  controller: _purpose,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                      labelText: 'Purpose', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(
                    child: Text(
                        _checkOut == null
                            ? 'Not punched out'
                            : 'Punched out ${hhmm(_stamp(_checkOut!))}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  TextButton(
                      onPressed: _pickCheckOut,
                      child: Text(_checkOut == null ? 'Set time' : 'Change')),
                  if (_checkOut != null)
                    IconButton(
                      tooltip: 'Reopen this visit',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(() => _checkOut = null),
                    ),
                ]),
                const SizedBox(height: 4),
                Text(_durationLine(),
                    style: const TextStyle(
                        fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 8),
                const Text(
                    'The check-in time and its GPS stay as punched — they are '
                    'the record that the visit happened.',
                    style: TextStyle(fontSize: 11, color: Colors.black45)),
              ],
            ]),
      ),
      actions: editable
          ? [
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, {'action': 'delete'}),
                child: const Text('Delete',
                    style: TextStyle(color: Colors.red)),
              ),
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: () => Navigator.pop(context, {
                  'action': 'save',
                  'purpose': _purpose.text.trim(),
                  'check_out_time':
                      _checkOut == null ? null : _stamp(_checkOut!),
                }),
                child: const Text('Save'),
              ),
            ]
          : [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close')),
            ],
    );
  }
}
