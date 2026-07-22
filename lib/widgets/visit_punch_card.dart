import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/location_service.dart';

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
  String? _photoPath;

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

  /// Asks where the visit photo should come from. Returns null if the rep
  /// backs out of the sheet.
  Future<ImageSource?> _askSource() => showModalBottomSheet<ImageSource>(
        context: context,
        builder: (_) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Visit photo',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ]),
        ),
      );

  Future<void> _pickPhoto() async {
    final src = await _askSource();
    if (src == null) return;
    final img =
        await ImagePicker().pickImage(source: src, imageQuality: 60, maxWidth: 1280);
    if (img == null) return;
    if (mounted) setState(() => _photoPath = img.path);
  }

  Future<void> _punchIn() async {
    if (Session.I.salesPerson == null) {
      return _snack('No rep linked to this login.');
    }
    if (_photoPath == null) {
      await _pickPhoto();
      if (_photoPath == null) return _snack('A visit photo is required.');
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
      await Api.uploadVisitPhoto(visitName: visit, filePath: _photoPath!);
      _photoPath = null;
      _snack('Punched in ✓');
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
          if (!open && !_loading) ...[
            const SizedBox(height: 8),
            Row(children: [
              if (_photoPath != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(File(_photoPath!),
                      width: 48, height: 48, fit: BoxFit.cover),
                ),
              if (_photoPath != null) const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _pickPhoto,
                  icon: Icon(_photoPath == null
                      ? Icons.add_a_photo
                      : Icons.check_circle),
                  label: Text(
                      _photoPath == null ? 'Add visit photo' : 'Photo ready'),
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

