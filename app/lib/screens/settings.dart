import 'package:flutter/material.dart';
import 'package:timely_core/timely_core.dart';

import '../theme.dart';
import '../widgets/common.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final p = PaletteScope.of(context);
    final s = st.settings;

    Widget colorRow(String label, String value, void Function(TimelySettings, String) set) => InkWell(
          onTap: () async {
            final c = await pickColor(context, value);
            if (c != null) st.updateSettings((x) => set(x, c));
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              Container(width: 18, height: 18, decoration: BoxDecoration(color: hex(value), border: Border.all(color: p.line))),
              const SizedBox(width: 12),
              Expanded(child: Mono(label)),
              Mono(value, size: 11, color: p.muted),
            ]),
          ),
        );

    return TPage(children: [
      const SectionLabel('theme'),
      Mono('synced to all your devices.', wrap: true, size: 11, color: p.muted),
      const SizedBox(height: 12),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final e in TimelySettings.presets.entries)
          Tog(e.key,
              dot: hex(e.value[1]),
              on: s.bg == e.value[0] && s.fg == e.value[1] && s.accent == e.value[2],
              onTap: () => st.updateSettings((x) => x.applyPreset(e.key))),
      ]),
      const SizedBox(height: 12),
      colorRow('background', s.bg, (x, c) => x.bg = c),
      colorRow('text', s.fg, (x, c) => x.fg = c),
      colorRow('accent', s.accent, (x, c) => x.accent = c),
      colorRow('muted', s.muted, (x, c) => x.muted = c),

      SectionLabel('categories', trailing: InkWell(
        onTap: () => _editCategory(context, null),
        child: Mono('+ add', size: 11, color: p.accent),
      )),
      Mono('long-press an app on the dashboard to change its category.', wrap: true, size: 11, color: p.muted),
      const SizedBox(height: 8),
      for (final c in s.categories)
        InkWell(
          onTap: () => _editCategory(context, c),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              Container(width: 18, height: 18, color: hex(c.color)),
              const SizedBox(width: 12),
              Expanded(child: Mono(c.name)),
              Mono('${s.appCategory.values.where((v) => v == c.id).length} manual', size: 11, color: p.muted),
            ]),
          ),
        ),

      const SectionLabel('tracking'),
      Row(children: [
        const Expanded(child: Mono('desktop idle timeout')),
        IconButton(
            onPressed: s.idleMinutes <= 1 ? null : () => st.updateSettings((x) => x.idleMinutes--),
            icon: const Icon(Icons.remove)),
        Mono('${s.idleMinutes} min'),
        IconButton(
            onPressed: s.idleMinutes >= 30 ? null : () => st.updateSettings((x) => x.idleMinutes++),
            icon: const Icon(Icons.add)),
      ]),
      Mono('no keyboard/mouse input for this long stops counting screen time (unless media is playing in the focused app).', wrap: true,
          size: 11, color: p.muted),

      const SectionLabel('account'),
      Mono(st.creds?.server ?? '', size: 11, color: p.muted),
      const SizedBox(height: 12),
      Row(children: [
        TextButton(onPressed: () => _confirmSignOut(context), child: const Text('sign out this device')),
        const Spacer(),
        TextButton(
          onPressed: () => _deleteAccount(context),
          child: const Text('delete account', style: TextStyle(color: Color(0xFFE5735C))),
        ),
      ]),
      const SizedBox(height: 24),
      Mono('timely 1.0.0', size: 10, color: p.muted),
    ]);
  }

  Future<void> _confirmSignOut(BuildContext context) async {
    final st = AppScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: const Mono('sign out? this device stops tracking. its history stays in your account.', wrap: true, size: 12),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('sign out')),
        ],
      ),
    );
    if (ok == true) await st.signOut();
  }

  Future<void> _deleteAccount(BuildContext context) async {
    final st = AppScope.of(context);
    final pw = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Mono('permanently delete your account, all devices and all history?', wrap: true, size: 12),
          const SizedBox(height: 12),
          TextField(controller: pw, obscureText: true, decoration: const InputDecoration(labelText: 'password')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('delete everything')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await st.api.deleteAccount(pw.text);
      await st.signOut(remote: false);
    } catch (e) {
      if (context.mounted) toast(context, e.toString());
    }
  }

  Future<void> _editCategory(BuildContext context, CategoryDef? c) async {
    final st = AppScope.of(context);
    final name = TextEditingController(text: c?.name ?? '');
    var color = c?.color ?? '#9a8f80';
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'name')),
            const SizedBox(height: 16),
            _Swatches(selected: color, onPick: (x) => set(() => color = x)),
          ]),
          actions: [
            if (c != null && c.id != 'other')
              TextButton(onPressed: () => Navigator.pop(ctx, 'delete'), child: const Text('delete')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('save')),
          ],
        ),
      ),
    );
    if (res == 'save' && name.text.trim().isNotEmpty) {
      st.updateSettings((s) {
        final n = name.text.trim().toLowerCase();
        if (c == null) {
          var id = n.replaceAll(RegExp(r'[^a-z0-9]'), '');
          if (id.isEmpty || s.categories.any((x) => x.id == id)) id = 'c${DateTime.now().millisecondsSinceEpoch}';
          s.categories.add(CategoryDef(id, n, color));
        } else {
          final i = s.categories.indexWhere((x) => x.id == c.id);
          s.categories[i] = CategoryDef(c.id, n, color);
        }
      });
    } else if (res == 'delete' && c != null) {
      st.updateSettings((s) {
        s.categories.removeWhere((x) => x.id == c.id);
        if (defaultCategories.any((d) => d.id == c.id)) s.removedCategories.add(c.id);
        s.appCategory.removeWhere((_, v) => v == c.id);
      });
    }
  }
}

const _swatches = [
  '#ffb000', '#ffcc66', '#ff8c42', '#e5735c', '#d6635f', '#c2569a', '#8f7ad6', '#5aa7d8', '#7cc4ff', '#4fb99f',
  '#7dff9a', '#8fb35a', '#d9a441', '#9a8f80', '#6f747a', '#e8e4dc', '#c9d4e3', '#f4f1ea', '#1d1c1a', '#0f0f0e',
  '#0a0f0b', '#0d1117', '#3f7a4c', '#8a6a2a', '#7c776f', '#5c6b7e', '#c25b2a', '#ffffff', '#000000', '#33ff00',
];

class _Swatches extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onPick;
  const _Swatches({required this.selected, required this.onPick});
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Wrap(spacing: 6, runSpacing: 6, children: [
      for (final c in _swatches)
        InkWell(
          onTap: () => onPick(c),
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: hex(c),
              border: Border.all(color: c == selected ? p.accent : p.line, width: c == selected ? 2 : 1),
            ),
          ),
        ),
    ]);
  }
}

Future<String?> pickColor(BuildContext context, String current) {
  final ctrl = TextEditingController(text: current);
  var sel = current;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        content: SizedBox(
          width: 300,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _Swatches(selected: sel, onPick: (c) => set(() {
                  sel = c;
                  ctrl.text = c;
                })),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(labelText: 'hex  #rrggbb'),
              onChanged: (v) => set(() => sel = v.trim()),
            ),
          ]),
        ),
        actions: [
          FilledButton(
            onPressed: () {
              final v = ctrl.text.trim().toLowerCase();
              Navigator.pop(ctx, RegExp(r'^#[0-9a-f]{6}$').hasMatch(v) ? v : null);
            },
            child: const Text('apply'),
          ),
        ],
      ),
    ),
  );
}
