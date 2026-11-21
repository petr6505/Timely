import 'package:flutter/material.dart';
import 'package:timely_core/timely_core.dart';

import 'charts.dart';
import 'common.dart';

/// One app in the dashboard list. Tapping it shows the time per device and
/// lets the user recategorise, rename or link it with another app.
class AppRow extends StatelessWidget {
  final AppStat app;
  final int maxFocus;
  final bool open;
  final VoidCallback onToggle;

  /// Called with the key of the app this one was linked into.
  final void Function(String key) onLinked;

  const AppRow(
    this.app, {
    super.key,
    required this.maxFocus,
    required this.open,
    required this.onToggle,
    required this.onLinked,
  });

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final p = PaletteScope.of(context);
    final c = catColor(st.settings, app.category);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          onLongPress: () => _pickCategory(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(width: 7, height: 7, color: c),
                    const SizedBox(width: 10),
                    Expanded(child: Mono(app.name)),
                    if (app.media > 0) ...[
                      Mono('♪ ${fmtDur(app.media)}', size: 11, color: p.muted),
                      const SizedBox(width: 14),
                    ],
                    SizedBox(
                      width: 64,
                      child: Text(fmtDur(app.focus), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13)),
                    ),
                    Icon(open ? Icons.expand_less : Icons.expand_more, size: 16, color: p.muted),
                  ],
                ),
                const SizedBox(height: 6),
                Meter(app.focus / maxFocus, c),
              ],
            ),
          ),
        ),
        if (open) ...[
          for (final e in (app.perDevice.entries.toList()..sort((x, y) => y.value.focus.compareTo(x.value.focus))))
            Padding(
              padding: const EdgeInsets.only(left: 17, bottom: 6),
              child: Row(
                children: [
                  Mono('└ ', color: p.muted),
                  Expanded(
                    child: Mono(
                      [st.deviceName(e.key), ...e.value.names.where((n) => n != app.name)].join(' · '),
                      size: 12,
                      color: p.muted,
                    ),
                  ),
                  if (e.value.media > 0) ...[
                    Mono('♪ ${fmtDur(e.value.media)}', size: 11, color: p.muted),
                    const SizedBox(width: 14),
                  ],
                  SizedBox(
                    width: 64,
                    child: Text(
                      fmtDur(e.value.focus),
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 12, color: p.muted),
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 17, bottom: 10),
            child: Wrap(
              spacing: 18,
              runSpacing: 8,
              children: [
                _action(context, 'category: ${st.settings.category(app.category).name} ✎', () => _pickCategory(context)),
                _action(context, 'rename ✎', () => _rename(context)),
                _action(context, 'link with… ⇄', () => _link(context)),
              ],
            ),
          ),
          for (final m in app.members.entries)
            if (m.key != app.key)
              Padding(
                padding: const EdgeInsets.only(left: 17, bottom: 8),
                child: Row(
                  children: [
                    Expanded(child: Mono('linked: ${m.value}', size: 11, color: p.muted)),
                    _action(context, 'unlink ✕', () => st.updateSettings((s) => s.unlinkApp(m.key))),
                    const SizedBox(width: 16),
                  ],
                ),
              ),
        ],
      ],
    );
  }

  Widget _action(BuildContext context, String label, VoidCallback onTap) => InkWell(
    onTap: onTap,
    child: Mono(label, size: 11, color: PaletteScope.of(context).accent),
  );

  Future<void> _rename(BuildContext context) async {
    final st = AppScope.of(context);
    // selected, so typing replaces it
    final name = TextEditingController(text: app.name)
      ..selection = TextSelection(baseOffset: 0, extentOffset: app.name.length);
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Mono('rename ${app.name}', size: 14),
        content: TextField(
          controller: name,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'name on every device'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          if (st.settings.appNames.containsKey(app.key))
            TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('original name')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, name.text), child: const Text('save')),
        ],
      ),
    );
    if (picked != null) st.updateSettings((s) => s.renameApp(app.key, picked));
  }

  Future<void> _link(BuildContext context) async {
    final st = AppScope.of(context);
    final others = knownApps(st.chunks, st.settings).entries.where((e) => e.key != app.key).toList()
      ..sort((x, y) => x.value.toLowerCase().compareTo(y.value.toLowerCase()));
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => _LinkDialog(app: app.name, apps: others),
    );
    if (picked == null) return;
    st.updateSettings((s) => s.linkApp(app.key, picked, app.members.keys));
    onLinked(picked);
  }

  Future<void> _pickCategory(BuildContext context) async {
    final st = AppScope.of(context);
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Mono('${app.name} →', size: 14),
        children: [
          for (final c in st.settings.categories)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, c.id),
              child: Row(
                children: [
                  Container(width: 8, height: 8, color: catColor(st.settings, c.id)),
                  const SizedBox(width: 10),
                  Mono(c.name, color: c.id == app.category ? PaletteScope.of(context).accent : null),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked != null) st.updateSettings((s) => s.appCategory[app.key] = picked);
  }
}

/// Searchable list of apps to count together with [app].
class _LinkDialog extends StatefulWidget {
  final String app;
  final List<MapEntry<String, String>> apps;
  const _LinkDialog({required this.app, required this.apps});
  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final q = query.toLowerCase();
    final shown = widget.apps.where((e) => e.value.toLowerCase().contains(q)).toList();
    return AlertDialog(
      title: Mono('count ${widget.app} as', size: 14),
      content: SizedBox(
        width: 360,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(labelText: 'search'),
              onChanged: (v) => setState(() => query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  for (final e in shown)
                    InkWell(
                      onTap: () => Navigator.pop(context, e.key),
                      child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Mono(e.value)),
                    ),
                  if (shown.isEmpty) Mono('no app matches', size: 12, color: p.muted),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('cancel'))],
    );
  }
}
