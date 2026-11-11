import 'package:flutter/material.dart';

import '../state.dart';
import '../theme.dart';

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);
  static AppState of(BuildContext c) => c.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

class PaletteScope extends InheritedWidget {
  final Palette palette;
  const PaletteScope({super.key, required this.palette, required super.child});
  static Palette of(BuildContext c) => c.dependOnInheritedWidgetOfExactType<PaletteScope>()!.palette;
  @override
  bool updateShouldNotify(PaletteScope old) => true;
}

/// Lowercase section label followed by a hairline.
class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionLabel(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 12),
      child: Row(children: [
        Text(text, style: TextStyle(color: p.muted, fontSize: 11, letterSpacing: 1.5)),
        const SizedBox(width: 12),
        Expanded(child: Container(height: 1, color: p.line)),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ]),
    );
  }
}

/// Text toggle: `[ label ]` style chip.
class Tog extends StatelessWidget {
  final String label;
  final bool on;
  final VoidCallback onTap;
  final Color? dot;
  const Tog(this.label, {super.key, required this.on, required this.onTap, this.dot});
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(border: Border.all(color: on ? p.accent : p.line)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (dot != null) ...[
            Container(width: 7, height: 7, color: on ? dot : dot!.withValues(alpha: 0.35)),
            const SizedBox(width: 7),
          ],
          Text(label, style: TextStyle(fontSize: 12, color: on ? p.fg : p.muted)),
        ]),
      ),
    );
  }
}

class Mono extends StatelessWidget {
  final String text;
  final double size;
  final Color? color;
  final FontWeight? weight;
  /// Labels get truncated with an ellipsis; set [wrap] for sentences.
  final bool wrap;
  const Mono(this.text, {super.key, this.size = 13, this.color, this.weight, this.wrap = false});

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(fontSize: size, color: color, fontWeight: weight),
        overflow: wrap ? null : TextOverflow.ellipsis,
        softWrap: wrap,
      );
}

void toast(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));

/// Centered column with max width, used by every screen.
class TPage extends StatelessWidget {
  final List<Widget> children;
  final Future<void> Function()? onRefresh;
  const TPage({super.key, required this.children, this.onRefresh});
  @override
  Widget build(BuildContext context) {
    final list = ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ),
      ],
    );
    return onRefresh == null ? list : RefreshIndicator(onRefresh: onRefresh!, child: list);
  }
}
