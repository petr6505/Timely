import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timely_core/timely_core.dart';

import 'native.dart';

class AppState extends ChangeNotifier {
  late SharedPreferences _prefs;
  late Directory _cacheDir;

  Credentials? creds;
  TimelySettings settings = TimelySettings();
  int _settingsUpdatedAt = 0;
  bool _settingsDirty = false;
  Timer? _settingsTimer;
  Timer? _poll;

  List<RemoteDevice> devices = [];
  final Map<String, Map<String, DayChunk>> chunks = {};
  int _cursor = 0;

  bool syncing = false;
  String? syncError;
  DateTime? lastRefresh;

  bool get signedIn => creds != null;
  TimelyApi get api => TimelyApi.of(creds!);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _cacheDir = Directory('${(await getApplicationSupportDirectory()).path}/cache');
    _cacheDir.createSync(recursive: true);

    if (Platform.isAndroid) {
      final c = _prefs.getString('creds');
      creds = c == null ? null : Credentials.fromJson(jsonDecode(c) as Map<String, dynamic>);
    } else {
      creds = DesktopPaths.readCredentials();
    }
    final s = _prefs.getString('settings');
    if (s != null) settings = TimelySettings.fromJson(jsonDecode(s) as Map<String, dynamic>);
    _settingsUpdatedAt = _prefs.getInt('settingsUpdatedAt') ?? 0;
    final d = _prefs.getString('devices');
    if (d != null) {
      devices = [for (final x in jsonDecode(d) as List) RemoteDevice.fromJson(x as Map<String, dynamic>)];
    }
    _cursor = _prefs.getInt('cursor') ?? 0;
    _loadCache();
    await _mergeLocal();
    if (signedIn) {
      unawaited(NativeBridge.configure(creds!));
      _startPolling();
      unawaited(refresh());
    }
  }

  void _loadCache() {
    chunks.clear();
    for (final dev in _cacheDir.listSync().whereType<Directory>()) {
      final id = dev.uri.pathSegments.where((s) => s.isNotEmpty).last;
      for (final f in dev.listSync().whereType<File>()) {
        try {
          final day = f.uri.pathSegments.last.split('.').first;
          (chunks[id] ??= {})[day] = DayChunk.decode(f.readAsBytesSync());
        } catch (_) {}
      }
    }
  }

  void _storeChunk(RemoteChunk rc) {
    final dir = Directory('${_cacheDir.path}/${rc.deviceId}')..createSync(recursive: true);
    File('${dir.path}/${rc.day}.gz').writeAsBytesSync(rc.data);
    (chunks[rc.deviceId] ??= {})[rc.day] = DayChunk.decode(rc.data);
  }

  Future<void> _signedIn(Credentials c) async {
    creds = c;
    if (Platform.isAndroid) await _prefs.setString('creds', jsonEncode(c.toJson()));
    await NativeBridge.configure(c);
    _startPolling();
    notifyListeners();
    // upload this device's history first so the dashboard isn't empty
    await refresh(pushLocal: true);
  }

  Future<void> register(String server, String email, String pw) async {
    final a = TimelyApi(normalizeServer(server));
    await _signedIn(await a.register(email, pw, await NativeBridge.deviceName(), NativeBridge.platform));
    _settingsDirty = true; // seed account with this device's settings
    await _pushSettings();
  }

  Future<void> login(String server, String email, String pw) async {
    final a = TimelyApi(normalizeServer(server));
    await _signedIn(await a.login(email, pw, await NativeBridge.deviceName(), NativeBridge.platform));
  }

  Future<void> redeem(String server, String code) async {
    final a = TimelyApi(normalizeServer(server));
    await _signedIn(await a.redeem(code, await NativeBridge.deviceName(), NativeBridge.platform));
  }

  /// Parses timely://pair?s=...&c=... or https://server/p/CODE
  static (String, String)? parsePairLink(String raw) {
    final u = Uri.tryParse(raw.trim());
    if (u == null) return null;
    if (u.scheme == 'timely' && u.queryParameters['s'] != null && u.queryParameters['c'] != null) {
      return (u.queryParameters['s']!, u.queryParameters['c']!);
    }
    if ((u.scheme == 'https' || u.scheme == 'http') && u.pathSegments.length == 2 && u.pathSegments[0] == 'p') {
      return (u.origin, u.pathSegments[1]);
    }
    return null;
  }

  Future<void> signOut({bool remote = true}) async {
    if (remote && creds != null) {
      try {
        await api.logout();
      } catch (_) {}
    }
    _poll?.cancel();
    creds = null;
    await NativeBridge.clear();
    await _prefs.remove('creds');
    await _prefs.remove('cursor');
    await _prefs.remove('devices');
    _cursor = 0;
    devices = [];
    chunks.clear();
    lastRefresh = null;
    syncError = null;
    if (_cacheDir.existsSync()) _cacheDir.deleteSync(recursive: true);
    _cacheDir.createSync(recursive: true);
    notifyListeners();
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(minutes: 15), (_) => refresh());
  }

  Future<void> refresh({bool pushLocal = false}) async {
    if (!signedIn || syncing) return;
    syncing = true;
    notifyListeners();
    try {
      if (pushLocal) await NativeBridge.syncNow();
      final (devs, _) = await api.devices();
      devices = devs;
      await _prefs.setString('devices', jsonEncode([
        for (final d in devs)
          {'id': d.id, 'name': d.name, 'platform': d.platform, 'createdAt': d.createdAt, 'lastSeen': d.lastSeen}
      ]));
      // small overlap guards against writes committed in the same millisecond
      final got = await api.chunksSince(_cursor > 60000 ? _cursor - 60000 : 0);
      for (final c in got) {
        _storeChunk(c);
        if (c.updatedAt > _cursor) _cursor = c.updatedAt;
      }
      await _prefs.setInt('cursor', _cursor);
      await _pullSettings();
      syncError = null;
      lastRefresh = DateTime.now();
    } on ApiException catch (e) {
      syncError = e.message;
      if (e.unauthorized) await signOut(remote: false);
    } catch (e) {
      syncError = 'offline';
    } finally {
      await _mergeLocal();
      syncing = false;
      notifyListeners();
    }
  }

  /// Overlay this device's locally captured days. They are always at least as
  /// fresh as the server copy, and cover days still waiting to be uploaded.
  Future<void> _mergeLocal() async {
    final id = creds?.deviceId;
    if (id == null) return;
    try {
      final local = await NativeBridge.localChunks();
      final mine = chunks[id] ??= {};
      local.forEach((day, bytes) {
        try {
          mine[day] = DayChunk.decode(bytes);
        } catch (_) {}
      });
    } catch (_) {}
  }

  Future<void> _pullSettings() async {
    if (_settingsDirty) return _pushSettings();
    final (data, updatedAt) = await api.getSettings();
    if (data != null && updatedAt > _settingsUpdatedAt) {
      settings = TimelySettings.fromJson(data);
      _settingsUpdatedAt = updatedAt;
      await _saveSettingsLocal();
    }
  }

  Future<void> _pushSettings() async {
    if (!signedIn) return;
    try {
      _settingsUpdatedAt = await api.putSettings(settings.toJson());
      _settingsDirty = false;
      await _saveSettingsLocal();
    } catch (_) {
      // stays dirty; retried on next refresh
    }
  }

  Future<void> _saveSettingsLocal() async {
    await _prefs.setString('settings', jsonEncode(settings.toJson()));
    await _prefs.setInt('settingsUpdatedAt', _settingsUpdatedAt);
  }

  /// Mutate settings, apply instantly, sync to all devices shortly after.
  void updateSettings(void Function(TimelySettings s) fn) {
    fn(settings);
    _settingsDirty = true;
    unawaited(_saveSettingsLocal());
    notifyListeners();
    _settingsTimer?.cancel();
    _settingsTimer = Timer(const Duration(milliseconds: 800), _pushSettings);
  }

  /// Devices that were removed from the account but still have history here.
  List<RemovedDevice> get removedDevices {
    if (devices.isEmpty) return const []; // device list not loaded yet
    final known = {for (final d in devices) d.id};
    final out = <RemovedDevice>[];
    chunks.forEach((id, byDay) {
      if (known.contains(id) || byDay.isEmpty) return;
      final days = byDay.keys.toList()..sort();
      var focus = 0;
      for (final c in byDay.values) {
        for (var i = 0; i < c.apps.length; i++) {
          focus += c.hourly(i).fold(0, (a, b) => a + b);
        }
      }
      out.add(RemovedDevice(id, days.first, days.last, focus));
    });
    return out..sort((a, b) => b.lastDay.compareTo(a.lastDay));
  }

  void setDeviceHidden(String id, bool hidden) =>
      updateSettings((s) => hidden ? s.hiddenDevices.add(id) : s.hiddenDevices.remove(id));

  /// Permanently deletes the history of a removed device from the server.
  Future<void> deleteDeviceHistory(String id) async {
    await api.removeDevice(id, purge: true);
    chunks.remove(id);
    final d = Directory('${_cacheDir.path}/$id');
    if (d.existsSync()) d.deleteSync(recursive: true);
    if (settings.hiddenDevices.contains(id)) setDeviceHidden(id, false);
    notifyListeners();
  }

  String deviceName(String id) =>
      devices.where((d) => d.id == id).map((d) => d.name).firstOrNull ?? 'removed device';

  Future<void> renameDevice(String id, String name) async {
    await api.renameDevice(id, name);
    await refresh();
  }

  Future<void> removeDevice(String id, {required bool purge}) async {
    await api.removeDevice(id, purge: purge);
    if (purge) {
      chunks.remove(id);
      final d = Directory('${_cacheDir.path}/$id');
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
    if (id == creds?.deviceId) return signOut(remote: false);
    await refresh();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _settingsTimer?.cancel();
    super.dispose();
  }
}

class RemovedDevice {
  final String id;
  final String firstDay;
  final String lastDay;
  final int focus;
  const RemovedDevice(this.id, this.firstDay, this.lastDay, this.focus);
}
