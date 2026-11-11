import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:timely_core/timely_core.dart';

import '../native.dart';
import '../state.dart';
import '../widgets/common.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  CollectorStatus? status;
  Timer? t;

  @override
  void initState() {
    super.initState();
    _load();
    t = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    t?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await NativeBridge.status();
      if (mounted) setState(() => status = s);
    } catch (_) {}
  }

  String _ago(int ms) {
    if (ms == 0) return 'never';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final p = PaletteScope.of(context);
    final s = status;
    return TPage(
      onRefresh: st.refresh,
      children: [
        const SectionLabel('this device'),
        if (s == null) Mono('…', color: p.muted),
        if (s != null) ...[
          for (final e in s.checks.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Mono(e.value ? '[x]' : '[ ]', color: e.value ? p.accent : p.muted),
                const SizedBox(width: 10),
                Expanded(child: Mono(e.key, size: 12)),
                if (!e.value)
                  TextButton(onPressed: () async {
                    await NativeBridge.fix(e.key);
                    await Future<void>.delayed(const Duration(seconds: 1));
                    _load();
                  }, child: const Text('fix →')),
              ]),
            ),
          const SizedBox(height: 4),
          Mono('last upload ${_ago(s.lastSync)}${s.error != null ? ' · ${s.error}' : ''}', wrap: true, size: 11, color: p.muted),
          if (s.pending > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Mono('${s.pending} day${s.pending == 1 ? '' : 's'} saved on this device, uploads when online', wrap: true,
                  size: 11, color: p.accent),
            ),
          if (!s.checks.values.first)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Mono(
                  NativeBridge.platform == 'android'
                      ? 'grant "usage access" to Timely so it can read which apps are in the foreground.'
                      : NativeBridge.platform == 'linux'
                          ? 'agent not running. install the .deb or run: systemctl --user enable --now timely-agent'
                          : 'agent not running. reinstall Timely or start timely-agent.exe.',
                  wrap: true,
                  size: 11,
                  color: p.muted),
            ),
        ],
        SectionLabel('devices', trailing: Mono('${st.devices.length}', size: 11, color: p.muted)),
        for (final d in st.devices)
          InkWell(
            onTap: () => _manage(context, d),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(children: [
                SizedBox(width: 70, child: Mono(d.platform, size: 11, color: p.muted)),
                Expanded(child: Mono(d.name + (d.id == st.creds?.deviceId ? '  (this)' : ''))),
                Mono(_ago(d.lastSeen), size: 11, color: p.muted),
              ]),
            ),
          ),
        const SizedBox(height: 20),
        FilledButton(onPressed: () => _addDevice(context), child: const Text('+ add device')),
        if (st.removedDevices.isNotEmpty) ...[
          const SectionLabel('removed devices'),
          Mono('history of devices that are no longer in your account. hide it from the statistics or delete it.',
              size: 11, color: p.muted, wrap: true),
          const SizedBox(height: 8),
          for (final r in st.removedDevices) _removedRow(context, r),
        ],
      ],
    );
  }

  Widget _removedRow(BuildContext context, RemovedDevice r) {
    final st = AppScope.of(context);
    final p = PaletteScope.of(context);
    final hidden = st.settings.hiddenDevices.contains(r.id);
    String day(String d) {
      final t = DateTime.parse(d);
      return '${t.day}.${t.month}.${t.year % 100}';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Mono(hidden ? 'removed device (hidden)' : 'removed device', color: hidden ? p.muted : null),
            Mono('${day(r.firstDay)} - ${day(r.lastDay)} · ${fmtDur(r.focus)}', size: 11, color: p.muted),
          ]),
        ),
        TextButton(
          onPressed: () => st.setDeviceHidden(r.id, !hidden),
          child: Text(hidden ? 'show' : 'hide'),
        ),
        TextButton(
          onPressed: () => _deleteHistory(context, r),
          child: const Text('delete', style: TextStyle(color: Color(0xFFE5735C))),
        ),
      ]),
    );
  }

  Future<void> _deleteHistory(BuildContext context, RemovedDevice r) async {
    final st = AppScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Mono('permanently delete ${fmtDur(r.focus)} of history from this removed device?', size: 12, wrap: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await st.deleteDeviceHistory(r.id);
    } catch (e) {
      if (context.mounted) toast(context, e.toString());
    }
  }

  Future<void> _manage(BuildContext context, RemoteDevice d) async {
    final st = AppScope.of(context);
    final name = TextEditingController(text: d.name);
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Mono(d.name, size: 14),
        content: TextField(controller: name, decoration: const InputDecoration(labelText: 'name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'remove'), child: const Text('remove')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'purge'), child: const Text('remove + delete data')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('save')),
        ],
      ),
    );
    try {
      if (action == 'save' && name.text.trim() != d.name) await st.renameDevice(d.id, name.text.trim());
      if (action == 'remove' || action == 'purge') await st.removeDevice(d.id, purge: action == 'purge');
    } catch (e) {
      if (context.mounted) toast(context, e.toString());
    }
  }

  Future<void> _addDevice(BuildContext context) async {
    final st = AppScope.of(context);
    PairInfo info;
    try {
      info = await st.api.createPair();
    } catch (e) {
      if (context.mounted) toast(context, 'could not create code: $e');
      return;
    }
    if (!context.mounted) return;
    await showDialog<void>(context: context, builder: (_) => _PairDialog(info));
    st.refresh();
  }
}

class _PairDialog extends StatefulWidget {
  final PairInfo info;
  const _PairDialog(this.info);
  @override
  State<_PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends State<_PairDialog> {
  late Timer t;
  @override
  void initState() {
    super.initState();
    t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final left = widget.info.expiresAt.difference(DateTime.now());
    final expired = left.isNegative;
    final server = Uri.parse(widget.info.link).origin;
    return AlertDialog(
      content: SizedBox(
        width: 300,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Mono('add device', color: p.muted, size: 11),
          const SizedBox(height: 16),
          Container(
            color: p.isDark ? p.fg : Colors.transparent,
            padding: const EdgeInsets.all(10),
            child: QrImageView(
              data: widget.info.appLink,
              backgroundColor: p.isDark ? p.fg : p.bg,
              eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.square, color: p.isDark ? p.bg : p.fg),
              dataModuleStyle: QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: p.isDark ? p.bg : p.fg),
            ),
          ),
          const SizedBox(height: 16),
          SelectableText(widget.info.code,
              textAlign: TextAlign.center, style: TextStyle(fontSize: 26, letterSpacing: 4, color: p.accent)),
          const SizedBox(height: 4),
          Mono(expired ? 'expired' : 'valid ${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')} · single use',
              size: 11, color: p.muted),
          const SizedBox(height: 12),
          Mono('server', size: 10, color: p.muted),
          SelectableText(server, style: const TextStyle(fontSize: 11)),
          const SizedBox(height: 8),
          Mono('scan with the Timely app, or enter the code + server on the new device.', wrap: true, size: 11, color: p.muted),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: widget.info.link));
            toast(context, 'link copied');
          },
          child: const Text('copy link'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('done')),
      ],
    );
  }
}
