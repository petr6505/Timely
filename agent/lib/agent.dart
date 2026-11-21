import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:timely_core/timely_core.dart';

import 'probe.dart';

const _tick = Duration(seconds: 2);
const _syncEvery = Duration(minutes: 15);
// retry sooner while offline; nothing is lost, it all stays on disk until uploaded
const _retryEvery = Duration(minutes: 2);
// a longer gap between two ticks means the machine was asleep
const _maxGap = Duration(seconds: 10);

/// Samples the probe every two seconds, records usage into day files and
/// uploads them. Talks to the GUI app through a few files in [dir].
class Agent {
  final Directory dir;
  final Probe probe;
  final void Function(String) log;
  final Recorder _rec;

  Agent(this.dir, this.probe, this.log) : _rec = Recorder(dir);

  File _file(String name) => File('${dir.path}${Platform.pathSeparator}$name');

  late int _idleLimitMs = _savedIdleMinutes() * 60000;
  DateTime _lastTick = DateTime.now();
  DateTime _lastFlush = DateTime.now();
  DateTime _lastSync = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastSyncOk = 0;
  bool _wasLocked = false;
  bool _syncing = false;
  String? _error;
  TimelyApi? _api;
  String? _apiToken;

  int _savedIdleMinutes() {
    try {
      return jsonDecode(_file('agent-settings.json').readAsStringSync())['idleMinutes'] as int;
    } catch (_) {
      return 3;
    }
  }

  Future<void> run() async {
    _writeStatus();
    unawaited(sync());
    while (true) {
      await Future<void>.delayed(_tick);
      try {
        await _sample();
        _housekeeping();
      } catch (e, st) {
        // e.g. a full disk; keep going, the next tick may work again
        log('tick failed: $e\n$st');
      }
    }
  }

  Future<void> _sample() async {
    final now = DateTime.now();
    final from = _lastTick;
    _lastTick = now;
    final gap = now.difference(from);
    if (gap > _maxGap || gap <= Duration.zero) return;
    try {
      final focus = await probe.focus();
      final playing = await probe.playing();
      final locked = focus?.locked ?? false;
      if (focus != null && !locked && focus.id.isNotEmpty) {
        // watching a video counts even though the mouse doesn't move
        final focusedIsPlaying = playing.any((m) =>
            m.id.toLowerCase() == focus.id.toLowerCase() || mergeKey(m.name) == mergeKey(focus.name));
        if (focus.idleMs < _idleLimitMs || focusedIsPlaying) _rec.add(from, now, focus.id, focus.name);
      }
      for (final m in playing) {
        _rec.add(from, now, m.id, m.name, media: true);
      }
      if (_wasLocked && !locked) _rec.unlock(now);
      _wasLocked = locked;
    } catch (e) {
      _setError('probe: $e');
    }
  }

  void _housekeeping() {
    final now = DateTime.now();
    if (now.difference(_lastFlush) >= const Duration(minutes: 1)) {
      _lastFlush = now;
      _rec.flush();
      _writeStatus();
    }
    // the app asks for an immediate sync by creating this file
    final syncNow = _file('sync-now');
    var requested = false;
    if (syncNow.existsSync()) {
      requested = true;
      try {
        syncNow.deleteSync();
      } catch (_) {}
    }
    if (requested || now.difference(_lastSync) >= (_error == null ? _syncEvery : _retryEvery)) {
      _lastSync = now;
      unawaited(sync());
    }
  }

  Future<void> sync() async {
    if (_syncing) return;
    _syncing = true;
    try {
      final creds = DesktopPaths.readCredentials();
      if (creds == null) {
        _setError('not signed in');
        return;
      }
      if (_apiToken != creds.token) {
        _api = TimelyApi.of(creds);
        _apiToken = creds.token;
      }
      final api = _api!;
      _rec.flush();
      // today goes back to pending with the next sample
      for (final day in _rec.pendingUpload.toList()..sort()) {
        await api.putChunk(day, _rec.bytesFor(day));
        _rec.markUploaded(day);
      }
      final (settings, _) = await api.getSettings();
      final idle = TimelySettings.fromJson(settings).idleMinutes;
      _idleLimitMs = idle * 60000;
      _file('agent-settings.json').writeAsStringSync(jsonEncode({'idleMinutes': idle}));
      _rec.prune();
      _lastSyncOk = DateTime.now().millisecondsSinceEpoch;
      _setError(null);
    } on ApiException catch (e) {
      _setError(e.unauthorized ? 'signed out on server' : e.message);
    } catch (e) {
      _setError('offline');
    } finally {
      _syncing = false;
      _writeStatus();
    }
  }

  void _setError(String? e) {
    if (e != null && e != _error) log(e);
    _error = e;
  }

  void _writeStatus() {
    try {
      _file('agent-status.json').writeAsStringSync(jsonEncode({
        'heartbeat': DateTime.now().millisecondsSinceEpoch,
        'lastSync': _lastSyncOk,
        'focusSource': probe.source,
        'error': ?_error,
        'pid': pid,
      }));
    } catch (_) {}
  }

  Future<void> stop() async {
    _rec.flush();
    _writeStatus();
    await probe.close();
  }
}
