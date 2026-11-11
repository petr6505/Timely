import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:timely_core/timely_core.dart';

import '../theme.dart';
import 'common.dart';

/// Stacked columns (one per day or hour), each split by category.
class StackedBars extends StatefulWidget {
  final List<Map<String, int>> columns;
  final List<String> labels; // full label per column (tooltip)
  final List<String> axisLabels; // sparse x labels ('' = none)
  final List<String> order; // category draw order
  final Color Function(String cat) colorOf;
  final double height;
  const StackedBars({
    super.key,
    required this.columns,
    required this.labels,
    required this.axisLabels,
    required this.order,
    required this.colorOf,
    this.height = 160,
  });
  @override
  State<StackedBars> createState() => _StackedBarsState();
}

class _StackedBarsState extends State<StackedBars> {
  int? sel;

  void _pick(Offset pos, double width) {
    final n = widget.columns.length;
    if (n == 0) return;
    final i = (pos.dx / width * n).floor().clamp(0, n - 1);
    setState(() => sel = i);
  }

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final s = sel;
    final caption = s == null
        ? ' '
        : '${widget.labels[s]}  ${fmtDur(widget.columns[s].values.fold(0, (a, b) => a + b))}';
    return LayoutBuilder(builder: (context, c) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Mono(caption, size: 11, color: p.muted),
        const SizedBox(height: 6),
        MouseRegion(
          onHover: (e) => _pick(e.localPosition, c.maxWidth),
          onExit: (_) => setState(() => sel = null),
          child: GestureDetector(
            onTapDown: (e) => _pick(e.localPosition, c.maxWidth),
            onHorizontalDragUpdate: (e) => _pick(e.localPosition, c.maxWidth),
            child: CustomPaint(
              size: Size(c.maxWidth, widget.height),
              painter: _BarsPainter(widget, p, sel),
            ),
          ),
        ),
      ]);
    });
  }
}

class _BarsPainter extends CustomPainter {
  final StackedBars w;
  final Palette p;
  final int? sel;
  _BarsPainter(this.w, this.p, this.sel);

  @override
  void paint(Canvas canvas, Size size) {
    const labelH = 18.0;
    final chartH = size.height - labelH;
    final n = w.columns.length;
    if (n == 0) return;
    final totals = [for (final c in w.columns) c.values.fold(0, (a, b) => a + b)];
    final maxV = totals.fold(0, math.max);
    // gridline step in hours
    final maxH = maxV / 3600;
    final step = maxH <= 1 ? 0.25 : maxH <= 3 ? 1.0 : maxH <= 8 ? 2.0 : 4.0;
    final top = math.max(step, (maxH / step).ceil() * step) * 3600;
    final grid = Paint()..color = p.line..strokeWidth = 1;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var g = step; g * 3600 <= top + 1; g += step) {
      final y = chartH - (g * 3600 / top) * chartH;
      _dashed(canvas, Offset(0, y), Offset(size.width, y), grid);
      tp.text = TextSpan(
          text: g < 1 ? '${(g * 60).round()}m' : '${g.toStringAsFixed(0)}h',
          style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 9, color: p.muted));
      tp.layout();
      tp.paint(canvas, Offset(size.width - tp.width, y - tp.height - 1));
    }
    canvas.drawLine(Offset(0, chartH), Offset(size.width, chartH), grid);

    final slot = size.width / n;
    final barW = math.max(1.5, math.min(slot * 0.62, 28.0));
    for (var i = 0; i < n; i++) {
      final x = i * slot + (slot - barW) / 2;
      var y = chartH;
      for (final cat in w.order) {
        final v = w.columns[i][cat] ?? 0;
        if (v <= 0) continue;
        final h = v / top * chartH;
        var col = w.colorOf(cat);
        if (sel != null && sel != i) col = col.withValues(alpha: 0.45);
        canvas.drawRect(Rect.fromLTWH(x, y - h, barW, h), Paint()..color = col);
        y -= h;
      }
      final lab = w.axisLabels[i];
      if (lab.isNotEmpty) {
        tp.text = TextSpan(
            text: lab,
            style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 9, color: sel == i ? p.fg : p.muted));
        tp.layout();
        tp.paint(canvas, Offset((x + barW / 2 - tp.width / 2).clamp(0, size.width - tp.width), chartH + 4));
      }
    }
  }

  void _dashed(Canvas c, Offset a, Offset b, Paint paint) {
    const dash = 2.0, gap = 4.0;
    var x = a.dx;
    while (x < b.dx) {
      c.drawLine(Offset(x, a.dy), Offset(math.min(x + dash, b.dx), a.dy), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => true;
}

/// Weekday x hour heatmap.
class Heatmap extends StatelessWidget {
  final List<List<int>> heat;
  const Heatmap(this.heat, {super.key});
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final maxV = heat.expand((r) => r).fold(0, math.max);
    const days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
    return LayoutBuilder(builder: (context, c) {
      const labelW = 34.0;
      if (!c.maxWidth.isFinite || c.maxWidth <= labelW) return const SizedBox.shrink();
      final cell = (c.maxWidth - labelW) / 24;
      return Column(children: [
        for (var d = 0; d < 7; d++)
          Row(children: [
            SizedBox(width: labelW, child: Mono(days[d], size: 9, color: p.muted)),
            for (var h = 0; h < 24; h++)
              Tooltip(
                message: '${days[d]} ${h.toString().padLeft(2, '0')}:00  ${fmtDur(heat[d][h])}',
                child: Container(
                  width: cell,
                  height: math.min(cell, 18),
                  margin: EdgeInsets.zero,
                  decoration: BoxDecoration(
                    color: maxV == 0 || heat[d][h] == 0
                        ? p.surface
                        : p.accent.withValues(alpha: 0.12 + 0.88 * math.sqrt(heat[d][h] / maxV)),
                    border: Border.all(color: p.bg, width: 1),
                  ),
                ),
              ),
          ]),
        Row(children: [
          const SizedBox(width: labelW),
          for (var h = 0; h < 24; h++)
            SizedBox(width: cell, child: Mono(h % 6 == 0 ? '$h' : '', size: 9, color: p.muted)),
        ]),
      ]);
    });
  }
}

/// 100% horizontal split by category.
class SplitBar extends StatelessWidget {
  final List<(String, int, Color)> parts;
  const SplitBar(this.parts, {super.key});
  @override
  Widget build(BuildContext context) {
    final total = parts.fold(0, (a, b) => a + b.$2);
    if (total == 0) return const SizedBox(height: 8);
    return SizedBox(
      height: 8,
      child: Row(children: [
        for (final x in parts)
          if (x.$2 > 0) Expanded(flex: math.max(1, (x.$2 * 1000 / total).round()), child: Container(color: x.$3)),
      ]),
    );
  }
}

/// Thin proportional bar used in lists.
class Meter extends StatelessWidget {
  final double frac;
  final Color color;
  const Meter(this.frac, this.color, {super.key});
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Container(
      height: 2,
      color: p.surface,
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(widthFactor: frac.clamp(0, 1), child: Container(color: color)),
    );
  }
}

Color catColor(TimelySettings s, String cat) => hex(s.category(cat).color);
