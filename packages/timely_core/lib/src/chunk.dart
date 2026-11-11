import 'dart:convert';
import 'dart:io' show gzip;

/// One app as known by a device: platform id (package name, desktop id, exe)
/// and a human display name.
class AppRef {
  final String id;
  final String name;
  const AppRef(this.id, this.name);
}

/// A continuous interval of usage. [start] is seconds since local midnight.
class Session {
  final int app; // index into DayChunk.apps
  int start;
  int dur;
  Session(this.app, this.start, this.dur);
  int get end => start + dur;
}

/// Compact per-device, per-day record.
///
/// Wire format (JSON, then gzip):
/// ```
/// {"v":1, "d":"2026-11-09", "z":60,
///  "a":[["org.mozilla.firefox","Firefox"], ...],   // app dictionary
///  "f":[app, startDelta, dur, ...],                  // focused sessions (screen time)
///  "m":[app, startDelta, dur, ...],                  // media playback sessions
///  "u":42}                                           // unlocks
/// ```
/// startDelta is the start minus the previous session's start (first is
/// relative to midnight), so the numbers stay small and gzip well.
/// Rolled-up (old) days use "hf"/"hm": [app, hour, seconds, ...] instead.
class DayChunk {
  final String day;
  final int tzOffsetMin;
  final List<AppRef> apps;
  final List<Session> focused;
  final List<Session> media;
  int unlocks;

  /// Present only for hourly rollups: app -> 24 buckets of seconds.
  final Map<int, List<int>>? hourlyFocused;
  final Map<int, List<int>>? hourlyMedia;

  DayChunk({
    required this.day,
    required this.tzOffsetMin,
    List<AppRef>? apps,
    List<Session>? focused,
    List<Session>? media,
    this.unlocks = 0,
    this.hourlyFocused,
    this.hourlyMedia,
  })  : apps = apps ?? [],
        focused = focused ?? [],
        media = media ?? [];

  bool get isRollup => hourlyFocused != null;

  int appIndex(String id, String name) {
    for (var i = 0; i < apps.length; i++) {
      if (apps[i].id == id) return i;
    }
    apps.add(AppRef(id, name));
    return apps.length - 1;
  }

  static List<int> _flat(List<Session> s) {
    final sorted = [...s]..sort((a, b) => a.start.compareTo(b.start));
    final out = <int>[];
    var prev = 0;
    for (final x in sorted) {
      out..add(x.app)..add(x.start - prev)..add(x.dur);
      prev = x.start;
    }
    return out;
  }

  static List<Session> _unflat(List<dynamic>? f) {
    final out = <Session>[];
    if (f == null) return out;
    var start = 0;
    for (var i = 0; i + 2 < f.length; i += 3) {
      start += (f[i + 1] as num).toInt();
      out.add(Session((f[i] as num).toInt(), start, (f[i + 2] as num).toInt()));
    }
    return out;
  }

  static Map<int, List<int>> _unhourly(List<dynamic>? f) {
    final out = <int, List<int>>{};
    if (f == null) return out;
    for (var i = 0; i + 2 < f.length; i += 3) {
      final app = (f[i] as num).toInt();
      final hour = (f[i + 1] as num).toInt().clamp(0, 23);
      (out[app] ??= List.filled(24, 0))[hour] += (f[i + 2] as num).toInt();
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'd': day,
        'z': tzOffsetMin,
        'a': [for (final a in apps) [a.id, a.name]],
        'f': _flat(focused),
        if (media.isNotEmpty) 'm': _flat(media),
        if (unlocks > 0) 'u': unlocks,
      };

  factory DayChunk.fromJson(Map<String, dynamic> j) {
    final hf = j['hf'] as List?;
    return DayChunk(
      day: j['d'] as String,
      tzOffsetMin: (j['z'] as num?)?.toInt() ?? 0,
      apps: [for (final a in (j['a'] as List? ?? const [])) AppRef(a[0] as String, a[1] as String)],
      focused: _unflat(j['f'] as List?),
      media: _unflat(j['m'] as List?),
      unlocks: (j['u'] as num?)?.toInt() ?? 0,
      hourlyFocused: hf == null ? null : _unhourly(hf),
      hourlyMedia: hf == null ? null : _unhourly(j['hm'] as List?),
    );
  }

  List<int> encode() => gzip.encode(utf8.encode(jsonEncode(toJson())));

  static DayChunk decode(List<int> bytes) =>
      DayChunk.fromJson(jsonDecode(utf8.decode(gzip.decode(bytes))) as Map<String, dynamic>);

  /// Seconds per hour of day for one app (works for both full and rollup).
  List<int> hourly(int app, {bool media = false}) {
    final roll = media ? hourlyMedia : hourlyFocused;
    if (roll != null) return roll[app] ?? List.filled(24, 0);
    final out = List.filled(24, 0);
    for (final s in (media ? this.media : focused)) {
      if (s.app != app) continue;
      var t = s.start;
      var rem = s.dur;
      while (rem > 0) {
        final h = t ~/ 3600;
        if (h > 23) break;
        final take = rem < (h + 1) * 3600 - t ? rem : (h + 1) * 3600 - t;
        out[h] += take;
        t += take;
        rem -= take;
      }
    }
    return out;
  }
}

String dayKey(DateTime local) =>
    '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
