import 'chunk.dart';
import 'categories.dart';
import 'settings.dart';

class Filter {
  final Set<String> devices; // empty = all
  final String fromDay; // inclusive YYYY-MM-DD
  final String toDay; // inclusive
  final Set<String> categories; // empty = all
  const Filter({this.devices = const {}, required this.fromDay, required this.toDay, this.categories = const {}});
}

class DeviceUse {
  int focus = 0;
  int media = 0;
  /// App ids this device used for the merged app (e.g. package names).
  final Set<String> ids = {};
  /// Names the app has on this device.
  final Set<String> names = {};
}

class AppStat {
  final String key;
  String name;
  final String category;
  int focus = 0;
  int media = 0;
  final Map<String, DeviceUse> perDevice = {};
  /// Base key -> name of every app counted under this one. More than one
  /// entry means the user linked apps together.
  final Map<String, String> members = {};
  AppStat(this.key, this.name, this.category);
}

class DayStat {
  final String day;
  final Map<String, int> byCategory = {};
  int media = 0;
  DayStat(this.day);
  int get focus => byCategory.values.fold(0, (a, b) => a + b);
}

class Summary {
  int focus = 0;
  int media = 0;
  int unlocks = 0;
  final Map<String, AppStat> apps = {};
  final Map<String, int> categories = {};
  final Map<String, int> devices = {};
  final List<DayStat> days = [];
  /// weekday (0=Mon) x hour seconds
  final List<List<int>> heat = List.generate(7, (_) => List.filled(24, 0));
  final List<int> hours = List.filled(24, 0);
  final Map<String, List<int>> hourByCategory = {};

  /// Apps by screen time; listening time breaks ties so audio-only apps still show up.
  List<AppStat> get sortedApps => apps.values.toList()
    ..sort((a, b) => b.focus != a.focus ? b.focus.compareTo(a.focus) : b.media.compareTo(a.media));
  int get dayCount => days.isEmpty ? 1 : days.length;
}

List<String> daysBetween(String from, String to) {
  final out = <String>[];
  var d = DateTime.parse(from);
  final end = DateTime.parse(to);
  while (!d.isAfter(end)) {
    out.add(dayKey(d));
    d = DateTime(d.year, d.month, d.day + 1);
  }
  return out;
}

/// chunks: deviceId -> day -> chunk
Summary summarize(Map<String, Map<String, DayChunk>> chunks, TimelySettings s, Filter f) {
  final sum = Summary();
  final dayStats = {for (final d in daysBetween(f.fromDay, f.toDay)) d: DayStat(d)};
  sum.days.addAll(dayStats.values);

  // a linked app can be guessed differently on each device, so the first guess sticks
  final catOf = <String, String>{};

  chunks.forEach((deviceId, byDay) {
    if (s.hiddenDevices.contains(deviceId)) return;
    if (f.devices.isNotEmpty && !f.devices.contains(deviceId)) return;
    byDay.forEach((day, c) {
      final ds = dayStats[day];
      if (ds == null) return;
      final weekday = DateTime.parse(day).weekday - 1;
      sum.unlocks += c.unlocks;
      for (var i = 0; i < c.apps.length; i++) {
        final ref = c.apps[i];
        final base = baseKey(ref.name);
        final key = s.links[base] ?? base;
        final cat = catOf[key] ??= s.categoryOf(key, ref.id, ref.name);
        if (f.categories.isNotEmpty && !f.categories.contains(cat)) continue;
        final hf = c.hourly(i);
        final hm = c.hourly(i, media: true);
        final focus = hf.fold(0, (a, b) => a + b);
        final media = hm.fold(0, (a, b) => a + b);
        if (focus == 0 && media == 0) continue;
        final st = sum.apps.putIfAbsent(key, () => AppStat(key, ref.name, cat));
        final old = st.members[base];
        if (old == null || ref.name.length < old.length) st.members[base] = ref.name;
        st.focus += focus;
        st.media += media;
        final du = st.perDevice.putIfAbsent(deviceId, DeviceUse.new);
        du.focus += focus;
        du.media += media;
        du.ids.add(ref.id);
        du.names.add(ref.name);
        sum.focus += focus;
        sum.media += media;
        sum.categories[cat] = (sum.categories[cat] ?? 0) + focus;
        sum.devices[deviceId] = (sum.devices[deviceId] ?? 0) + focus;
        ds.byCategory[cat] = (ds.byCategory[cat] ?? 0) + focus;
        ds.media += media;
        final hc = sum.hourByCategory.putIfAbsent(cat, () => List.filled(24, 0));
        for (var h = 0; h < 24; h++) {
          hc[h] += hf[h];
          sum.hours[h] += hf[h];
          sum.heat[weekday][h] += hf[h];
        }
      }
    });
  });
  for (final a in sum.apps.values) {
    a.name = s.appNames[a.key] ?? a.members[a.key] ?? a.members.values.reduce((x, y) => y.length < x.length ? y : x);
  }
  return sum;
}

/// Every app in [chunks] (key -> name), for picking an app to link with.
Map<String, String> knownApps(Map<String, Map<String, DayChunk>> chunks, TimelySettings s) {
  final out = <String, String>{};
  for (final byDay in chunks.values) {
    for (final c in byDay.values) {
      for (final ref in c.apps) {
        final key = mergeKey(ref.name, s.links);
        final old = out[key];
        if (old == null || ref.name.length < old.length) out[key] = ref.name;
      }
    }
  }
  return out..updateAll((k, v) => s.appNames[k] ?? v);
}

String fmtDur(int secs, {bool short = false}) {
  if (secs < 60) return secs == 0 ? '0m' : '<1m';
  final h = secs ~/ 3600;
  final m = (secs % 3600) ~/ 60;
  if (h == 0) return '${m}m';
  return short || m == 0 ? '${h}h${m == 0 ? '' : ' ${m}m'}' : '${h}h ${m}m';
}
