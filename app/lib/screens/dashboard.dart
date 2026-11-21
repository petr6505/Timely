import 'dart:async';

import 'package:flutter/material.dart';
import 'package:timely_core/timely_core.dart';

import '../native.dart';
import '../widgets/app_row.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';

enum Range { day, week, month, quarter, year }

extension on Range {
  String get label => switch (this) {
    Range.day => 'day',
    Range.week => '7d',
    Range.month => '30d',
    Range.quarter => '90d',
    Range.year => '1y',
  };
  int get days => switch (this) {
    Range.day => 1,
    Range.week => 7,
    Range.month => 30,
    Range.quarter => 90,
    Range.year => 365,
  };
}

class DashboardScreen extends StatefulWidget {
  final VoidCallback onOpenSetup;
  const DashboardScreen({super.key, required this.onOpenSetup});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
const _wd = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

class _DashboardScreenState extends State<DashboardScreen> {
  Range range = Range.week;
  int offset = 0; // periods back
  final Set<String> devSel = {};
  final Set<String> catSel = {};
  final Set<String> expanded = {};
  bool allApps = false;
  CollectorStatus? status;
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _loadStatus();
    _statusTimer = Timer.periodic(const Duration(seconds: 30), (_) => _loadStatus());
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    try {
      final s = await NativeBridge.status();
      if (mounted) setState(() => status = s);
    } catch (_) {}
  }

  (DateTime, DateTime) get _span {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final end = DateTime(today.year, today.month, today.day - offset * range.days);
    final start = DateTime(end.year, end.month, end.day - range.days + 1);
    return (start, end);
  }

  String _fmtDay(DateTime d) => '${_wd[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final p = PaletteScope.of(context);
    final s = st.settings;
    final (start, end) = _span;
    final sum = summarize(
      st.chunks,
      s,
      Filter(devices: devSel, categories: catSel, fromDay: dayKey(start), toDay: dayKey(end)),
    );
    final cats = [...s.categories.map((c) => c.id)];
    Color col(String c) => catColor(s, c);

    final chart = _chartData(sum);

    final activeDays = sum.days.where((d) => d.focus > 0).length;
    final avg = activeDays == 0 ? 0 : sum.focus ~/ activeDays;
    final apps = sum.sortedApps;
    final maxApp = apps.isEmpty || apps.first.focus == 0 ? 1 : apps.first.focus;
    final shownApps = allApps ? apps : apps.take(15).toList();
    final presentDevices = st.devices.where((d) => st.chunks.containsKey(d.id)).toList();

    return TPage(
      onRefresh: () => st.refresh(pushLocal: true),
      children: [
        if (status != null && !status!.ok)
          InkWell(
            onTap: widget.onOpenSetup,
            child: Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(border: Border.all(color: p.accent)),
              child: Mono('! tracking on this device needs attention → devices', wrap: true, size: 12, color: p.accent),
            ),
          ),
        const SizedBox(height: 16),
        Row(
          children: [
            for (final r in Range.values) ...[
              Tog(
                r.label,
                on: range == r,
                onTap: () => setState(() {
                  range = r;
                  offset = 0;
                }),
              ),
              const SizedBox(width: 6),
            ],
            const Spacer(),
            IconButton(onPressed: () => setState(() => offset++), icon: const Icon(Icons.chevron_left)),
            IconButton(
              onPressed: offset == 0 ? null : () => setState(() => offset--),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        Mono(range == Range.day ? _fmtDay(end) : '${_fmtDay(start)} - ${_fmtDay(end)}', size: 11, color: p.muted),
        if (presentDevices.length > 1) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              Tog('all devices', on: devSel.isEmpty, onTap: () => setState(devSel.clear)),
              for (final d in presentDevices)
                Tog(
                  d.name,
                  on: devSel.contains(d.id),
                  onTap: () => setState(() {
                    devSel.contains(d.id) ? devSel.remove(d.id) : devSel.add(d.id);
                  }),
                ),
            ],
          ),
        ],
        const SizedBox(height: 28),
        Wrap(
          spacing: 36,
          runSpacing: 16,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            _Stat(fmtDur(sum.focus), 'screen time', big: true),
            if (range != Range.day) _Stat(fmtDur(avg), 'daily avg'),
            if (sum.media > 0) _Stat(fmtDur(sum.media), 'listening'),
            if (sum.unlocks > 0) _Stat('${sum.unlocks}', 'unlocks'),
          ],
        ),
        const SizedBox(height: 24),
        StackedBars(columns: chart.columns, labels: chart.labels, axisLabels: chart.axis, order: cats, colorOf: col),
        SectionLabel(
          'categories',
          trailing: catSel.isEmpty
              ? null
              : InkWell(
                  onTap: () => setState(catSel.clear),
                  child: Mono('clear', size: 11, color: p.accent),
                ),
        ),
        SplitBar([
          for (final c in cats)
            if ((sum.categories[c] ?? 0) > 0) (c, sum.categories[c]!, col(c)),
        ]),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final c in s.categories)
              if ((sum.categories[c.id] ?? 0) > 0 || catSel.contains(c.id))
                Tog(
                  '${c.name} ${fmtDur(sum.categories[c.id] ?? 0, short: true)}',
                  on: catSel.isEmpty || catSel.contains(c.id),
                  dot: col(c.id),
                  onTap: () => setState(() => catSel.contains(c.id) ? catSel.remove(c.id) : catSel.add(c.id)),
                ),
          ],
        ),
        if (range != Range.day) ...[const SectionLabel('when'), Heatmap(sum.heat)],
        if (sum.devices.length > 1) ...[
          const SectionLabel('devices'),
          for (final e in (sum.devices.entries.toList()..sort((a, b) => b.value.compareTo(a.value))))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: Mono(st.deviceName(e.key))),
                      Mono(fmtDur(e.value), color: p.muted),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Meter(e.value / (sum.focus == 0 ? 1 : sum.focus), p.accent),
                ],
              ),
            ),
        ],
        SectionLabel('apps', trailing: Mono('${apps.length}', size: 11, color: p.muted)),
        if (apps.isEmpty)
          Mono(
            st.chunks.isEmpty ? 'no data yet. the first sync happens within 15 minutes.' : 'nothing in this range.',
            color: p.muted,
            size: 12,
            wrap: true,
          ),
        for (final a in shownApps)
          AppRow(
            a,
            maxFocus: maxApp,
            open: expanded.contains(a.key),
            onToggle: () => setState(() => expanded.contains(a.key) ? expanded.remove(a.key) : expanded.add(a.key)),
            onLinked: (key) => setState(
              () => expanded
                ..remove(a.key)
                ..add(key),
            ),
          ),
        if (apps.length > 15)
          TextButton(
            onPressed: () => setState(() => allApps = !allApps),
            child: Text(allApps ? 'show less' : 'show all ${apps.length}'),
          ),
        const SizedBox(height: 24),
        Mono(
          st.lastRefresh == null
              ? (st.syncError ?? 'not synced yet')
              : 'synced ${_ago(st.lastRefresh!)}${st.syncError != null ? ' · ${st.syncError}' : ''}',
          size: 10,
          color: p.muted,
        ),
      ],
    );
  }

  /// One column per hour (day view), per week (year view) or per day.
  _Chart _chartData(Summary sum) {
    switch (range) {
      case Range.day:
        return _Chart(
          [
            for (var h = 0; h < 24; h++) {for (final e in sum.hourByCategory.entries) e.key: e.value[h]},
          ],
          [for (var h = 0; h < 24; h++) '${h.toString().padLeft(2, '0')}:00'],
          [for (var h = 0; h < 24; h++) h % 6 == 0 ? '$h' : ''],
        );
      case Range.year:
        final chart = _Chart([], [], []);
        for (var i = 0; i < sum.days.length; i += 7) {
          final week = sum.days.sublist(i, (i + 7).clamp(0, sum.days.length));
          final totals = <String, int>{};
          for (final d in week) {
            d.byCategory.forEach((k, v) => totals[k] = (totals[k] ?? 0) + v);
          }
          final first = DateTime.parse(week.first.day);
          chart.columns.add(totals);
          chart.labels.add('week of ${_fmtDay(first)}');
          chart.axis.add(first.day <= 7 ? _months[first.month - 1] : '');
        }
        return chart;
      case Range.week:
      case Range.month:
      case Range.quarter:
        final days = [for (final d in sum.days) DateTime.parse(d.day)];
        String axisLabel(int i) => switch (range) {
          Range.week => _wd[days[i].weekday - 1],
          Range.month => i % 5 == 0 ? '${days[i].day}' : '',
          _ => days[i].day == 1 || i == 0 ? _months[days[i].month - 1] : '',
        };
        return _Chart([for (final d in sum.days) d.byCategory], [for (final d in days) _fmtDay(d)], [
          for (var i = 0; i < days.length; i++) axisLabel(i),
        ]);
    }
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    return '${d.inHours}h ago';
  }
}

class _Chart {
  final List<Map<String, int>> columns;
  final List<String> labels;
  final List<String> axis;
  _Chart(this.columns, this.labels, this.axis);
}

class _Stat extends StatelessWidget {
  final String value, label;
  final bool big;
  const _Stat(this.value, this.label, {this.big = false});
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(fontSize: big ? 34 : 18, color: big ? p.accent : p.fg, height: 1.1),
        ),
        const SizedBox(height: 4),
        Mono(label, size: 10, color: p.muted),
      ],
    );
  }
}
