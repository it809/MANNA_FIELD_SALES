import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/location_service.dart';
import 'package:manna_field_sales/widgets/photo_source_sheet.dart';

class VisitPunchCard extends StatefulWidget {
  final String? customer;
  final String? lead;
  const VisitPunchCard({super.key, this.customer, this.lead});
  @override
  State<VisitPunchCard> createState() => _VisitPunchCardState();
}

class _VisitPunchCardState extends State<VisitPunchCard> {
  Map<String, dynamic>? _open;
  bool _busy = false, _loading = true;
  String? _lastDuration;

  /// Optional photo staged for the next punch. Never gates the punch itself —
  /// this is visit evidence, not the customer's location capture.
  String? _photoPath;

  /// Leads already carry a location/banner photo of their own, so their punch
  /// card is timer-only.
  bool get _photoAllowed => widget.lead == null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _open =
      await Api.getOpenVisit(customer: widget.customer, lead: widget.lead);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), duration: const Duration(seconds: 3)));
  }

  Future<void> _pickPhoto() async {
    final img = await pickPhoto(context, title: 'Visit photo');
    if (img == null) return;
    if (mounted) setState(() => _photoPath = img.path);
  }

  /// Uploads the staged photo, if any. A failure here is reported but never
  /// rolls back the punch — the visit is already recorded.
  Future<void> _uploadStagedPhoto(String visitName, {required bool checkOut}) async {
    final path = _photoPath;
    if (path == null) return;
    try {
      await Api.uploadVisitPhoto(
          visitName: visitName, filePath: path, checkOut: checkOut);
      _photoPath = null;
    } catch (_) {
      _snack('Punch saved, but the photo failed to upload.');
    }
  }

  Future<void> _punchIn() async {
    if (Session.I.salesPerson == null) {
      return _snack('No rep linked to this login.');
    }
    setState(() => _busy = true);
    _snack('Getting GPS...');
    try {
      final pos = await getCurrentLocation();
      final visit = await Api.punchInVisit(
          customer: widget.customer,
          lead: widget.lead,
          lat: pos.latitude,
          lng: pos.longitude);
      _snack('Punched in ✓');
      await _uploadStagedPhoto(visit, checkOut: false);
      await _load();
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _punchOut() async {
    if (_open == null) return;
    setState(() => _busy = true);
    _snack('Getting GPS...');
    try {
      final pos = await getCurrentLocation();
      final mins = await Api.punchOutVisit(
        name: _open!['name'] as String,
        lat: pos.latitude,
        lng: pos.longitude,
        checkInTime: '${_open!['check_in_time'] ?? ''}',
      );
      _lastDuration = mins.toStringAsFixed(0);
      _snack('Punched out ✓ — ${mins.toStringAsFixed(0)} min');
      await _uploadStagedPhoto(_open!['name'] as String, checkOut: true);
      await _load();
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _fmtT(dynamic t) {
    final s = '$t';
    return s.length >= 16 ? s.substring(11, 16) : s;
  }

  String _elapsed() {
    try {
      final inT =
      DateTime.parse('${_open!['check_in_time']}'.replaceFirst(' ', 'T'));
      return '${DateTime.now().difference(inT).inMinutes} min';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final open = _open != null;
    return Card(
      color: open ? const Color(0xFFE0F2F1) : const Color(0xFFF3F4F6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(open ? Icons.timer : Icons.timer_outlined,
                color: const Color(0xFFF46A21)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _loading
                    ? 'Visit timer...'
                    : open
                    ? 'On visit since ${_fmtT(_open!['check_in_time'])}  ·  ${_elapsed()}'
                    : (_lastDuration != null
                    ? 'Last visit: $_lastDuration min'
                    : 'Not on a visit'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ]),
          if (!_loading && _photoAllowed) ...[
            const SizedBox(height: 8),
            Row(children: [
              if (_photoPath != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(File(_photoPath!),
                      width: 48, height: 48, fit: BoxFit.cover),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _pickPhoto,
                  icon: Icon(_photoPath == null
                      ? Icons.add_a_photo
                      : Icons.check_circle),
                  label: Text(
                      _photoPath == null ? 'Add photo (optional)' : 'Photo ready'),
                ),
              ),
            ]),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: open
                ? FilledButton.icon(
              style:
              FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: _busy ? null : _punchOut,
              icon: const Icon(Icons.logout),
              label: const Padding(
                  padding: EdgeInsets.all(8), child: Text('Punch out')),
            )
                : FilledButton.icon(
              onPressed: _busy || _loading ? null : _punchIn,
              icon: const Icon(Icons.login),
              label: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('Punch in (start visit)')),
            ),
          ),
        ]),
      ),
    );
  }
}

