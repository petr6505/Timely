import 'package:dbus/dbus.dart';

import 'probe.dart';

/// GNOME on Wayland: focus via the timely-focus shell extension,
/// media via MPRIS, idle via the extension (Mutter idle monitor fallback).
class LinuxProbe extends Probe {
  final DBusClient _bus = DBusClient.session();
  bool _extOk = false;

  @override
  String get source => _extOk ? 'gnome-extension' : 'none';

  @override
  Future<FocusInfo?> focus() async {
    try {
      final r = await _bus.callMethod(
        destination: 'dev.timely.Focus',
        path: DBusObjectPath('/dev/timely/Focus'),
        interface: 'dev.timely.Focus',
        name: 'Get',
        replySignature: DBusSignature('ssub'),
      );
      _extOk = true;
      final v = r.values;
      var id = v[0].asString();
      if (id.endsWith('.desktop')) id = id.substring(0, id.length - 8);
      return FocusInfo(id, v[1].asString(), v[2].asUint32(), v[3].asBoolean());
    } catch (_) {
      _extOk = false;
      return null;
    }
  }

  /// Idle time without the extension (screen-time can't be attributed, but
  /// we still know whether the user is present).
  Future<int?> idleFallback() async {
    try {
      final r = await _bus.callMethod(
        destination: 'org.gnome.Mutter.IdleMonitor',
        path: DBusObjectPath('/org/gnome/Mutter/IdleMonitor/Core'),
        interface: 'org.gnome.Mutter.IdleMonitor',
        name: 'GetIdletime',
        replySignature: DBusSignature('t'),
      );
      return r.values.first.asUint64();
    } catch (_) {
      return null;
    }
  }

  final Map<String, MediaApp> _identity = {};

  @override
  Future<List<MediaApp>> playing() async {
    final out = <MediaApp>[];
    List<String> names;
    try {
      names = (await _bus.listNames()).where((n) => n.startsWith('org.mpris.MediaPlayer2.')).toList();
    } catch (_) {
      return out;
    }
    for (final n in names) {
      try {
        final status = await DBusRemoteObject(_bus, name: n, path: DBusObjectPath('/org/mpris/MediaPlayer2'))
            .getProperty('org.mpris.MediaPlayer2.Player', 'PlaybackStatus', signature: DBusSignature('s'));
        if (status.asString() != 'Playing') continue;
        out.add(_identity[n] ??= await _ident(n));
      } catch (_) {}
    }
    return out;
  }

  Future<MediaApp> _ident(String busName) async {
    Future<String?> prop(String p) async {
      try {
        return (await DBusRemoteObject(_bus, name: busName, path: DBusObjectPath('/org/mpris/MediaPlayer2'))
                .getProperty('org.mpris.MediaPlayer2', p, signature: DBusSignature('s')))
            .asString();
      } catch (_) {
        return null;
      }
    }

    final entry = await prop('DesktopEntry');
    final identity = await prop('Identity');
    // "org.mpris.MediaPlayer2.firefox.instance_1_23" -> "firefox"
    final short = busName.substring('org.mpris.MediaPlayer2.'.length).split('.').first;
    final id = entry ?? short;
    return MediaApp(id, identity ?? id);
  }

  @override
  Future<void> close() => _bus.close();
}
