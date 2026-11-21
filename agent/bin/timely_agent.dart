import 'dart:async';
import 'dart:io';

import 'package:timely_agent/agent.dart';
import 'package:timely_agent/probe.dart';
import 'package:timely_agent/probe_linux.dart';
import 'package:timely_agent/probe_windows.dart';
import 'package:timely_agent/watchdog_windows.dart';
import 'package:timely_core/timely_core.dart';

// The agent runs in the background, so anything worth reading goes to agent.log.
late final File _logFile;

void log(String msg) {
  final line = '${DateTime.now().toIso8601String()} $msg\n';
  try {
    if (_logFile.existsSync() && _logFile.lengthSync() > 512 * 1024) {
      _logFile.renameSync('${_logFile.path}.old');
    }
    _logFile.writeAsStringSync(line, mode: FileMode.append);
  } catch (_) {}
  // the windowless Windows build has no stderr at all, and writing to it fails
  // asynchronously, past any try/catch
  if (_hasTerminal) stderr.write(line);
}

final bool _hasTerminal = () {
  try {
    return stderr.hasTerminal;
  } catch (_) {
    return false;
  }
}();

Future<void> main(List<String> args) async {
  final dir = DesktopPaths.dataDir..createSync(recursive: true);
  _logFile = File('${dir.path}${Platform.pathSeparator}agent.log');

  // only one agent per user: the app and the login autostart may both start one
  final lock = File('${dir.path}${Platform.pathSeparator}agent.lock').openSync(mode: FileMode.append);
  try {
    lock.lockSync(FileLock.exclusive);
  } catch (_) {
    if (args.contains('--once')) await printOnce();
    exit(0);
  }

  if (args.contains('--once')) {
    await printOnce();
    exit(0);
  }

  await runZonedGuarded(() async {
    final agent = Agent(dir, Platform.isWindows ? WindowsProbe() : LinuxProbe(), log);
    log('started, pid $pid');
    if (Platform.isWindows) unawaited(registerWatchdog(dir, log));
    Future<void> stop(ProcessSignal s) async {
      log('stopping ($s)');
      await agent.stop();
      exit(0);
    }

    for (final s in [ProcessSignal.sigint, if (!Platform.isWindows) ProcessSignal.sigterm]) {
      try {
        s.watch().listen(stop, onError: (_) {});
      } catch (_) {}
    }
    await agent.run();
  }, (e, st) {
    log('error: $e\n$st');
  });
}

Future<void> printOnce() async {
  final Probe probe = Platform.isWindows ? WindowsProbe() : LinuxProbe();
  final f = await probe.focus();
  log('focus: ${f?.id} "${f?.name}" idle=${f?.idleMs}ms locked=${f?.locked} source=${probe.source}');
  log('playing: ${(await probe.playing()).map((m) => '${m.id} "${m.name}"').join(', ')}');
  await probe.close();
}
