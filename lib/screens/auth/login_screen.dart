import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/screens/home/home_dashboard.dart';
import 'package:manna_field_sales/services/api.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _url = TextEditingController(text: Session.I.baseUrl);
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _showUrl = false;
  bool _obscurePassword = true;

  void _showUrlField() => setState(() => _showUrl = !_showUrl);

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final p = await SharedPreferences.getInstance();
    final url = p.getString('baseUrl') ?? Session.I.baseUrl;
    final email = p.getString('email') ?? '';
    final sid = p.getString('sid') ?? '';
    setState(() {
      _url.text = url;
      _email.text = email;
    });
    // If we still have a saved session, try to resume without re-login.
    if (sid.isNotEmpty) {
      Session.I.baseUrl = url;
      Session.I.email = email;
      Session.I.sid = sid;
      Session.I.init();
      try {
        await Api.fetchCsrf();
        if (await Api.testAuth()) {
          await Api.resolveMySalesPerson();
          await Api.resolveManagerContext();
          if ((Session.I.salesPerson != null ||
              Session.I.isManager ||
              Session.I.isGM ||
              Session.I.isHR ||
              Session.I.isProductionManager) &&
              mounted) {
            Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const HomeDashboard()));
          }
        }
      } catch (_) {/* fall through to login screen */}
    }
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      Session.I.baseUrl = _url.text.trim();
      Session.I.init();
      await Api.sessionLogin(_email.text.trim(), _password.text);
      await Api.resolveMySalesPerson();
      await Api.resolveManagerContext();
      if (Session.I.salesPerson == null &&
          !Session.I.isManager &&
          !Session.I.isGM &&
          !Session.I.isHR &&
          !Session.I.isProductionManager) {
        throw Exception(
            'This login is not linked to a Sales Person or team. Contact admin.');
      }
      final p = await SharedPreferences.getInstance();
      await p.setString('baseUrl', Session.I.baseUrl);
      await p.setString('email', Session.I.email);
      await p.setString('sid', Session.I.sid);
      if (mounted) {
        Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const HomeDashboard()));
      }
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: ListView(children: [
          const SizedBox(height: 48),
          Center(
            child: Image.asset(
              'assets/manna_logo.png',
              height: 96,
              errorBuilder: (_, __, ___) => const Text(
                'MANNA',
                style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFFF46A21)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text('Field Sales',
                style: TextStyle(
                    fontSize: 16,
                    letterSpacing: 2,
                    color: Color(0xFF3F3F3F),
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 36),
          TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(
              controller: _password,
              obscureText: _obscurePassword,
              onSubmitted: (_) => _busy ? null : _login(),
              decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    tooltip:
                    _obscurePassword ? 'Show password' : 'Hide password',
                    onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword),
                  ),
                  border: const OutlineInputBorder())),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => _showUrlField(),
              child: const Text('Server settings',
                  style: TextStyle(fontSize: 12)),
            ),
          ),
          if (_showUrl)
            TextField(
                controller: _url,
                decoration: const InputDecoration(
                    labelText: 'ERPNext URL', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          if (_error != null)
            Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child:
                Text(_error!, style: const TextStyle(color: Colors.red))),
          FilledButton(
            onPressed: _busy ? null : _login,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _busy
                  ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
                  : const Text('Log in'),
            ),
          ),
        ]),
      ),
    );
  }
}

// -------------------- HOME DASHBOARD --------------------
