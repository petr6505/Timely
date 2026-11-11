import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:timely_core/timely_core.dart';

/// Platform glue: Android method channel, desktop agent management.
class NativeBridge {
  static const _ch = MethodChannel('timely/native');
  static void Function(String link)? onLink;

  static String? _argLink;

  static void init(List<String> args) {
    _argLink = args.where((a) => a.startsWith('timely://')).firstOrNull;
    if (!Platform.isAndroid) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'link') onLink?.call(call.arguments as String);
    });
  }

  static String get platform => Platform.isAndroid ? 'android' : Platform.isWindows ? 'windows' : 'linux';

  static Future<String> deviceName() async {
    if (Platform.isAndroid) return (await _ch.invokeMethod<String>('deviceName')) ?? 'android';
    return Platform.localHostname;
  }

  static Future<String?> initialLink() async =>
      Platform.isAndroid ? await _ch.invokeMethod<String>('initialLink') : _argLink;

  /// Hand credentials to the background collector.
  static Future<void> configure(Credentials c) async {
    if (Platform.isAndroid) {
      await _ch.invokeMethod('configure', c.toJson());
    } else {
      DesktopPaths.writeCredentials(c);
      await DesktopAgent.ensureRunning();
    }
  }

  static Future<void> clear() async {
    if (Platform.isAndroid) {
      await _ch.invokeMethod('clear');
    } else {
      DesktopPaths.writeCredentials(null);
    }
  }

  static Future<CollectorStatus> status() async {
    if (Platform.isAndroid) {
      final m = (await _ch.invokeMapMethod<String, dynamic>('status'))!;
      return CollectorStatus(
        checks: {
          'usage access': m['usageAccess'] == true,
          'media tracking (notification access)': m['mediaAccess'] == true,
          'battery unrestricted': m['batteryUnrestricted'] == true,
        },
        lastSync: (m['lastSync'] as num?)?.toInt() ?? 0,
        error: m['lastError'] as String?,
        pending: (m['pending'] as num?)?.toInt() ?? 0,
      );
    }
    return DesktopAgent.status();
  }

  static Future<void> fix(String check) async {
    if (!Platform.isAndroid) {
      await DesktopAgent.ensureRunning();
      return;
    }
    switch (check) {
      case 'usage access':
        await _ch.invokeMethod('openUsageAccess');
      case 'media tracking (notification access)':
        await _ch.invokeMethod('openMediaAccess');
      case 'battery unrestricted':
        await _ch.invokeMethod('openBattery');
    }
  }

  /// This device's own locally captured days (day -> gzip chunk), including
  /// days not uploaded yet. Lets the dashboard show local data while offline.
  static Future<Map<String, List<int>>> localChunks({int days = 400}) async {
    if (Platform.isAndroid) {
      final m = await _ch.invokeMapMethod<String, Uint8List>('localChunks', {'days': days});
      return {...?m};
    }
    final dir = Directory('${DesktopPaths.dataDir.path}${Platform.pathSeparator}days');
    if (!dir.existsSync()) return {};
    final cutoff = dayKey(DateTime.now().subtract(Duration(days: days)));
    final out = <String, List<int>>{};
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (!name.endsWith('.json.gz')) continue;
      final day = name.split('.').first;
      if (day.compareTo(cutoff) < 0) continue;
      try {
        out[day] = f.readAsBytesSync();
      } catch (_) {}
    }
    return out;
  }

  static Future<String?> syncNow() async {
    if (Platform.isAndroid) return _ch.invokeMethod<String>('syncNow');
    // agent watches this file and uploads immediately
    final f = File('${DesktopPaths.dataDir.path}${Platform.pathSeparator}sync-now');
    DesktopPaths.dataDir.createSync(recursive: true);
    f.writeAsStringSync('${DateTime.now().millisecondsSinceEpoch}');
    return null;
  }
}

class CollectorStatus {
  final Map<String, bool> checks;
  final int lastSync;
  final String? error;
  final int pending; // days captured locally but not uploaded yet
  CollectorStatus({required this.checks, required this.lastSync, this.error, this.pending = 0});
  bool get ok => checks.values.every((v) => v);
}

/// Controls the desktop background agent (timely-agent).
class DesktopAgent {
  static const gnomeExtension = 'timely-focus@timely.dev';

  static String? _agentBinary() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final name = Platform.isWindows ? 'timely-agent.exe' : 'timely-agent';
    for (final p in [
      '$exeDir${Platform.pathSeparator}$name',
      if (!Platform.isWindows) '/usr/bin/timely-agent',
      if (!Platform.isWindows) '/usr/lib/timely/timely-agent',
    ]) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  static Map<String, dynamic> _readJson(String name) {
    try {
      final f = File('${DesktopPaths.dataDir.path}${Platform.pathSeparator}$name');
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }

  static Future<CollectorStatus> status() async {
    final agent = _readJson('agent-status.json');
    final heartbeat = (agent['heartbeat'] as num?)?.toInt() ?? 0;
    final alive = DateTime.now().millisecondsSinceEpoch - heartbeat < 120000;

    // today is always pending while the agent runs, so only count earlier days
    final today = dayKey(DateTime.now());
    final pending = ((_readJson('state.json')['pending'] as List?) ?? const []).where((d) => d != today).length;

    return CollectorStatus(
      checks: {
        'background agent running': alive,
        if (Platform.isLinux) 'gnome focus extension active': agent['focusSource'] != 'none',
      },
      lastSync: (agent['lastSync'] as num?)?.toInt() ?? 0,
      error: agent['error'] as String?,
      pending: pending,
    );
  }

  static Future<void> ensureRunning() async {
    if (Platform.isLinux) {
      // packaged install: systemd user unit + gnome extension
      await _run('gnome-extensions', ['enable', gnomeExtension]);
      final r = await _run('systemctl', ['--user', 'enable', '--now', 'timely-agent.service']);
      if (r == 0) return;
      final bin = _agentBinary();
      if (bin != null) await Process.start(bin, [], mode: ProcessStartMode.detached);
    } else if (Platform.isWindows) {
      final bin = _agentBinary();
      if (bin == null) return;
      await _run('reg', ['add', r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run', '/v', 'TimelyAgent', '/t',
        'REG_SZ', '/d', '"$bin"', '/f']);
      final st = await status();
      if (st.checks['background agent running'] != true) {
        await Process.start(bin, [], mode: ProcessStartMode.detached);
      }
    }
  }

  static Future<int> _run(String cmd, List<String> args) async {
    try {
      return (await Process.run(cmd, args)).exitCode;
    } catch (_) {
      return -1;
    }
  }
}
