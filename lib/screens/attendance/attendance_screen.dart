import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/models/attendance.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/location_service.dart';

/// Punch in and out for the logged-in rep.
///
/// There is no rep picker: the server derives the Sales Person from the
/// session, so a rep can only ever punch for themselves. Every rule — the
/// 05:00 open, the 21:30 cutoff, latest-punch-out-wins — is decided on the
/// server against the server clock. The window checks here only decide whether
/// a button looks tappable.
class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});
  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  AttendanceStatus? _status;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await Api.getAttendanceStatus();
      if (mounted) setState(() => _status = s);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _punch(Future<PunchResult> Function() send) async {
    setState(() => _busy = true);
    _snack('Getting GPS…');
    try {
      final r = await send();
      // A rejection is surfaced as plainly as an acceptance — the rep must
      // never be left believing a blocked punch succeeded.
      _snack(r.outcome.isAccepted ? '${r.message} ✓' : r.message);
      await _load();
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _punchIn() => _punch(() async {
        final pos = await getCurrentLocation();
        return Api.punchIn(lat: pos.latitude, lng: pos.longitude);
      });

  Future<void> _punchOut() => _punch(() async {
        final pos = await getCurrentLocation();
        return Api.punchOut(lat: pos.latitude, lng: pos.longitude);
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Attendance')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (Session.I.salesPersonLabel != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(Session.I.salesPersonLabel!,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
              ),
            if (_loading)
              const Padding(
                  padding: EdgeInsets.only(top: 40),
                  child: Center(child: CircularProgressIndicator()))
            else if (_error != null)
              Center(child: Text('Error: $_error'))
            else
              ..._body(_status!),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(AttendanceStatus s) => [
        ..._priorDayWarnings(s),
        _statusCard(s),
      ];

  /// Days that still need regularizing. The server lists only days before
  /// today, so nothing shows up on the night a punch-out was missed.
  List<Widget> _priorDayWarnings(AttendanceStatus s) {
    return s.pendingRegularizations
        .map((p) => Card(
              color: const Color(0xFFFFF7ED),
              child: ListTile(
                leading:
                    const Icon(Icons.warning_amber, color: Color(0xFFF59E0B)),
                title: Text('${p.attendanceDate} needs regularizing'),
                subtitle: const Text('Punched in but never punched out.'),
              ),
            ))
        .toList();
  }

  Widget _statusCard(AttendanceStatus s) {
    if (s.isPunchedOut) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.check_circle, color: Color(0xFFF46A21)),
          title: Text('Day complete · ${s.workingHours.toStringAsFixed(2)} h'),
          subtitle: Text('In ${hhmm(s.punchInTime)}  ·  '
              'Out ${hhmm(s.punchOutTime)}'),
        ),
      );
    }

    if (s.isPunchedIn) {
      final shut = s.punchOutBlockedReason;
      return Column(children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.login, color: Colors.green),
            title: Text('Punched in at ${hhmm(s.punchInTime)}'),
            subtitle: Text(shut ?? 'You are currently on duty.'),
          ),
        ),
        const SizedBox(height: 20),
        _bigButton('Punch Out', Icons.logout,
            (_busy || !s.punchOutEnabled) ? null : _punchOut),
      ]);
    }

    final shut = s.punchInBlockedReason;
    return Column(children: [
      Card(
        child: ListTile(
          leading: const Icon(Icons.schedule, color: Colors.orange),
          title: const Text('Not punched in today'),
          subtitle: Text(shut ?? 'Tap below to start your day.'),
        ),
      ),
      const SizedBox(height: 20),
      _bigButton('Punch In', Icons.login,
          (_busy || !s.punchInEnabled) ? null : _punchIn),
    ]);
  }

  Widget _bigButton(String label, IconData icon, VoidCallback? onTap) {
    return FilledButton.icon(
      onPressed: onTap,
      icon: _busy
          ? const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white))
          : Icon(icon),
      label: Padding(padding: const EdgeInsets.all(12), child: Text(label)),
    );
  }
}
