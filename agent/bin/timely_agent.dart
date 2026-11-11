import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:timely_agent/probe.dart';
import 'package:timely_agent/probe_linux.dart';
import 'package:timely_agent/probe_windows.dart';
import 'package:timely_core/timely_core.dart';

const tick = Duration(seconds: 2);
const uploadEvery = Duration(minutes: 15);
const retryOffline = Duration(minutes: 2); // data stays on disk until an upload succeeds
const maxGap = Duration(seconds: 10); // larger gaps = suspend/hibernate, not counted

Future<void> main(List<String> args) async {
  final dataDir = DesktopPaths.dataDir..createSync(recursive: true);
  final sep = Platform.pathSeparator;

  // single instance
  final lock = File('${dataDir.path}${sep}agent.lock').openSync(mode: FileMode.write);
  try {
    lock.lockSync(FileLock.exclusive);
  } catch (_) {
    stderr.writeln('timely-agent already running');
    exit(0);
  }

  final once = args.contains('--once'); // debug: print one probe and exit
  final Probe probe = Platform.isWindows ? WindowsProbe() : LinuxProbe();
  if (once) {
    final f = await probe.focus();
    print('focus: ${f?.id} "${f?.name}" idle=${f?.idleMs}ms locked=${f?.locked} source=${probe.source}');
    print('playing: ${(await probe.playing()).map((m) => '${m.id} "${m.name}"').join(', ')}');
    exit(0);
  }

  final rec = Recorder(dataDir);
  final statusFile = File('${dataDir.path}${sep}agent-status.json');
  final syncNowFile = File('${dataDir.path}${sep}sync-now');
  final settingsFile = File('${dataDir.path}${sep}agent-settings.json');
  var idleLimitMs = 3 * 60 * 1000;
  try {
    idleLimitMs = (jsonDecode(settingsFile.readAsStringSync())['idleMinutes'] as int) * 60000;
  } catch (_) {}

  var last = DateTime.now();
  var lastFlush = last;
  var lastUpload = DateTime.fromMillisecondsSinceEpoch(0);
  var wasLocked = false;
  var lastSync = 0;
  String? error;
  var uploading = false;

  void writeStatus() {
    try {
      statusFile.writeAsStringSync(jsonEncode({
        'heartbeat': DateTime.now().millisecondsSinceEpoch,
        'lastSync': lastSync,
        'focusSource': probe.source,
        'error': ?error,
        'pid': pid,
      }));
    } catch (_) {}
  }

  Future<void> upload() async {
    if (uploading) return;
    uploading = true;
    try {
      final creds = DesktopPaths.readCredentials();
      if (creds == null) {
        error = 'not signed in';
        return;
      }
      rec.flush();
      final api = TimelyApi.of(creds);
      final today = dayKey(DateTime.now());
      for (final day in rec.pendingUpload.toList()..sort()) {
        await api.putChunk(day, rec.bytesFor(day));
        // keep today pending so later ticks keep updating it
        if (day != today) rec.markUploaded(day);
      }
      rec.markUploaded(today);
      // also proves the server is reachable when there was nothing to upload
      final (s, _) = await api.getSettings();
      final mins = TimelySettings.fromJson(s).idleMinutes;
      idleLimitMs = mins * 60000;
      settingsFile.writeAsStringSync(jsonEncode({'idleMinutes': mins}));
      rec.prune();
      lastSync = DateTime.now().millisecondsSinceEpoch;
      error = null;
    } on ApiException catch (e) {
      error = e.unauthorized ? 'signed out on server' : e.message;
    } catch (e) {
      error = 'offline';
    } finally {
      uploading = false;
      writeStatus();
    }
  }

  Future<void> shutdown() async {
    rec.flush();
    writeStatus();
    await probe.close();
    exit(0);
  }

  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => shutdown());
  }
  ProcessSignal.sigint.watch().listen((_) => shutdown());

  writeStatus();
  unawaited(upload());

  while (true) {
    await Future<void>.delayed(tick);
    final now = DateTime.now();
    final gap = now.difference(last);
    try {
      final f = await probe.focus();
      final playing = await probe.playing();
      if (gap <= maxGap && gap > Duration.zero) {
        final locked = f?.locked ?? false;
        if (f != null && !locked && f.id.isNotEmpty) {
          final focusedPlaying = playing.any((m) =>
              m.id.toLowerCase() == f.id.toLowerCase() || mergeKey(m.name) == mergeKey(f.name));
          if (f.idleMs < idleLimitMs || focusedPlaying) rec.add(last, now, f.id, f.name);
        }
        for (final m in playing) {
          rec.add(last, now, m.id, m.name, media: true);
        }
        if (wasLocked && !locked) rec.unlock(now);
        wasLocked = locked;
      }
    } catch (e) {
      error = 'probe: $e';
    }
    last = now;

    if (now.difference(lastFlush) >= const Duration(minutes: 1)) {
      rec.flush();
      writeStatus();
      lastFlush = now;
    }
    final syncRequested = syncNowFile.existsSync();
    if (syncRequested) {
      try {
        syncNowFile.deleteSync();
      } catch (_) {}
    }
    final interval = error == null ? uploadEvery : retryOffline;
    if (syncRequested || now.difference(lastUpload) >= interval) {
      lastUpload = now;
      unawaited(upload());
    }
  }
}
