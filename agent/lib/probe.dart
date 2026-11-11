/// What the platform reports right now.
class FocusInfo {
  final String id; // stable app id (desktop id / exe name)
  final String name; // display name
  final int idleMs;
  final bool locked;
  const FocusInfo(this.id, this.name, this.idleMs, this.locked);
}

class MediaApp {
  final String id;
  final String name;
  const MediaApp(this.id, this.name);
}

abstract class Probe {
  /// null = focus source unavailable (e.g. GNOME extension not enabled)
  Future<FocusInfo?> focus();
  Future<List<MediaApp>> playing();
  String get source;
  Future<void> close() async {}
}
