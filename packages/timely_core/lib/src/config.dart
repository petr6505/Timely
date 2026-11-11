import 'dart:convert';
import 'dart:io';

import 'api.dart';

/// Desktop config shared by the GUI app and the background agent.
/// Linux:   $XDG_CONFIG_HOME/timely (default ~/.config/timely)
/// Windows: %APPDATA%\Timely
class DesktopPaths {
  static Directory get configDir {
    if (Platform.isWindows) return Directory('${Platform.environment['APPDATA']}\\Timely');
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    return Directory('${xdg ?? '${Platform.environment['HOME']}/.config'}/timely');
  }

  static Directory get dataDir {
    if (Platform.isWindows) return Directory('${Platform.environment['LOCALAPPDATA']}\\Timely');
    final xdg = Platform.environment['XDG_DATA_HOME'];
    return Directory('${xdg ?? '${Platform.environment['HOME']}/.local/share'}/timely');
  }

  static File get credentialsFile => File('${configDir.path}${Platform.pathSeparator}credentials.json');

  static Credentials? readCredentials() {
    try {
      final f = credentialsFile;
      if (!f.existsSync()) return null;
      return Credentials.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static void writeCredentials(Credentials? c) {
    final f = credentialsFile;
    if (c == null) {
      if (f.existsSync()) f.deleteSync();
      return;
    }
    configDir.createSync(recursive: true);
    if (!Platform.isWindows) {
      // create with 0600 before writing the secret
      f.writeAsStringSync('');
      Process.runSync('chmod', ['600', f.path]);
    }
    f.writeAsStringSync(jsonEncode(c.toJson()));
  }
}
