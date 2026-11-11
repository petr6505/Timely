import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:timely_core/timely_core.dart';

import '../native.dart';
import '../state.dart';
import '../widgets/common.dart';

// Can be overridden at build time with --dart-define=TIMELY_SERVER=https://...
const _serverOverride = String.fromEnvironment('TIMELY_SERVER');
const defaultServer = _serverOverride == '' ? 'https://timely.example.workers.dev' : _serverOverride;

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

enum _Mode { signIn, register, pair }

class _AuthScreenState extends State<AuthScreen> {
  _Mode mode = _Mode.pair;
  final server = TextEditingController(text: defaultServer);
  final email = TextEditingController();
  final pw = TextEditingController();
  final pw2 = TextEditingController();
  final code = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    NativeBridge.onLink = _handleLink;
    NativeBridge.initialLink().then((l) {
      if (l != null) _handleLink(l);
    });
  }

  @override
  void dispose() {
    NativeBridge.onLink = null;
    super.dispose();
  }

  void _handleLink(String link) {
    final p = AppState.parsePairLink(link);
    if (p == null) return;
    setState(() {
      mode = _Mode.pair;
      server.text = p.$1;
      code.text = p.$2;
    });
    _submit();
  }

  Future<void> _submit() async {
    final st = AppScope.of(context);
    setState(() {
      busy = true;
      error = null;
    });
    try {
      // allow pasting a full pairing link into the code field
      final link = AppState.parsePairLink(code.text);
      if (link != null) {
        server.text = link.$1;
        code.text = link.$2;
      }
      if (server.text.trim().isEmpty) throw ApiException(0, 'enter your server address');
      switch (mode) {
        case _Mode.signIn:
          await st.login(server.text, email.text, pw.text);
        case _Mode.register:
          if (pw.text != pw2.text) throw ApiException(0, 'passwords do not match');
          await st.register(server.text, email.text, pw.text);
        case _Mode.pair:
          await st.redeem(server.text, code.text);
      }
    } on ApiException catch (e) {
      setState(() => error = e.message);
    } on SocketException {
      setState(() => error = 'cannot reach server');
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _scan() async {
    final res = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _Scanner()));
    if (res != null) _handleLink(res);
  }

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    Widget field(TextEditingController c, String label, {bool obscure = false, TextInputType? kb}) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: c,
            obscureText: obscure,
            keyboardType: kb,
            autocorrect: false,
            decoration: InputDecoration(labelText: label),
            onSubmitted: (_) => _submit(),
          ),
        );
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Mono('timely', size: 28, color: p.accent),
                const SizedBox(height: 4),
                Mono('screen time, everywhere.', color: p.muted),
                const SizedBox(height: 36),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  Tog('add this device', on: mode == _Mode.pair, onTap: () => setState(() => mode = _Mode.pair)),
                  Tog('sign in', on: mode == _Mode.signIn, onTap: () => setState(() => mode = _Mode.signIn)),
                  Tog('new account', on: mode == _Mode.register, onTap: () => setState(() => mode = _Mode.register)),
                ]),
                const SizedBox(height: 24),
                if (mode == _Mode.pair) ...[
                  Mono('on a device that is already set up, open devices → add device.', wrap: true, color: p.muted, size: 12),
                  const SizedBox(height: 16),
                  if (Platform.isAndroid) ...[
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                          shape: const RoundedRectangleBorder(), side: BorderSide(color: p.line),
                          padding: const EdgeInsets.symmetric(vertical: 14)),
                      onPressed: busy ? null : _scan,
                      child: Text('scan qr code', style: TextStyle(color: p.fg)),
                    ),
                    const SizedBox(height: 16),
                    Center(child: Mono('or', color: p.muted, size: 11)),
                    const SizedBox(height: 16),
                  ],
                  field(code, 'pairing code or link'),
                ],
                field(server, 'server'),
                if (mode != _Mode.pair) ...[
                  field(email, 'email', kb: TextInputType.emailAddress),
                  field(pw, 'password', obscure: true),
                  if (mode == _Mode.register) field(pw2, 'repeat password', obscure: true),
                ],
                if (error != null) Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(error!, style: const TextStyle(color: Color(0xFFE5735C), fontSize: 12)),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: busy ? null : _submit,
                  child: busy
                      ? SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2, color: p.bg))
                      : Text(switch (mode) { _Mode.pair => 'pair', _Mode.signIn => 'sign in', _Mode.register => 'create account' }),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Scanner extends StatefulWidget {
  const _Scanner();
  @override
  State<_Scanner> createState() => _ScannerState();
}

class _ScannerState extends State<_Scanner> {
  bool done = false;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('scan pairing code')),
      body: MobileScanner(
        onDetect: (cap) {
          if (done) return;
          for (final b in cap.barcodes) {
            final v = b.rawValue;
            if (v != null && AppState.parsePairLink(v) != null) {
              done = true;
              Navigator.of(context).pop(v);
              return;
            }
          }
        },
      ),
    );
  }
}
