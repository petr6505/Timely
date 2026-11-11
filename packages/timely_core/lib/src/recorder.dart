import 'dart:convert';
import 'dart:io';

import 'chunk.dart';

/// Accumulates usage into per-day chunks on disk. Used by the desktop agents.
/// Callers report intervals; the recorder merges contiguous intervals into
/// sessions and splits them at local midnight.
class Recorder {
  final Directory dir;
  final Map<String, DayChunk> _days = {};
  final Set<String> _dirtyDisk = {};
  final Set<String> pendingUpload = {};
  static const mergeGap = 5; // seconds

  Recorder(this.dir) {
    Directory('${dir.path}/days').createSync(recursive: true);
    final st = File('${dir.path}/state.json');
    if (st.existsSync()) {
      try {
        final j = jsonDecode(st.readAsStringSync()) as Map<String, dynamic>;
        pendingUpload.addAll((j['pending'] as List? ?? const []).cast<String>());
      } catch (_) {}
    }
  }

  File _file(String day) => File('${dir.path}/days/$day.json.gz');

  DayChunk day(String key, {int? tz}) {
    final c = _days[key];
    if (c != null) return c;
    final f = _file(key);
    DayChunk chunk;
    if (f.existsSync()) {
      try {
        chunk = DayChunk.decode(f.readAsBytesSync());
      } catch (_) {
        chunk = DayChunk(day: key, tzOffsetMin: tz ?? 0);
      }
    } else {
      chunk = DayChunk(day: key, tzOffsetMin: tz ?? DateTime.now().timeZoneOffset.inMinutes);
    }
    // keep memory bounded: only the last few days stay cached
    if (_days.length > 4) {
      final oldest = (_days.keys.toList()..sort()).first;
      if (!_dirtyDisk.contains(oldest)) _days.remove(oldest);
    }
    return _days[key] = chunk;
  }

  static int _sod(DateTime t) => t.hour * 3600 + t.minute * 60 + t.second;

  /// Attribute [from, to) to app. [media] selects background playback track.
  void add(DateTime from, DateTime to, String id, String name, {bool media = false}) {
    var a = from;
    while (a.isBefore(to)) {
      final midnight = DateTime(a.year, a.month, a.day + 1);
      final b = to.isBefore(midnight) ? to : midnight;
      final key = dayKey(a);
      final c = day(key, tz: a.timeZoneOffset.inMinutes);
      final idx = c.appIndex(id, name);
      final start = _sod(a);
      final dur = b.difference(a).inSeconds;
      if (dur > 0) {
        final list = media ? c.media : c.focused;
        Session? last;
        if (media) {
          for (var i = list.length - 1; i >= 0; i--) {
            if (list[i].app == idx) { last = list[i]; break; }
          }
        } else if (list.isNotEmpty) {
          last = list.last;
        }
        if (last != null && last.app == idx && start >= last.start && start <= last.end + mergeGap) {
          final end = start + dur;
          if (end > last.end) last.dur = end - last.start;
        } else {
          list.add(Session(idx, start, dur));
        }
        _dirtyDisk.add(key);
        pendingUpload.add(key);
      }
      a = b;
    }
  }

  void unlock(DateTime t) {
    final key = dayKey(t);
    day(key).unlocks++;
    _dirtyDisk.add(key);
    pendingUpload.add(key);
  }

  void flush() {
    for (final key in _dirtyDisk) {
      final c = _days[key];
      if (c == null) continue;
      final f = _file(key);
      final tmp = File('${f.path}.tmp');
      tmp.writeAsBytesSync(c.encode(), flush: true);
      tmp.renameSync(f.path);
    }
    _dirtyDisk.clear();
    _saveState();
  }

  void _saveState() {
    File('${dir.path}/state.json').writeAsStringSync(jsonEncode({'pending': pendingUpload.toList()..sort()}));
  }

  List<int> bytesFor(String key) {
    final c = _days[key];
    if (c != null) return c.encode();
    final f = _file(key);
    return f.existsSync() ? f.readAsBytesSync() : day(key).encode();
  }

  void markUploaded(String key) {
    pendingUpload.remove(key);
    _saveState();
  }

  /// Delete local day files older than [keepDays] (they live on the server).
  void prune({int keepDays = 14}) {
    final cutoff = dayKey(DateTime.now().subtract(Duration(days: keepDays)));
    for (final f in Directory('${dir.path}/days').listSync()) {
      final name = f.uri.pathSegments.last;
      final key = name.split('.').first;
      if (key.compareTo(cutoff) < 0 && !pendingUpload.contains(key)) f.deleteSync();
    }
  }
}
