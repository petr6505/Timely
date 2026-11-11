import 'categories.dart';

/// User settings synced across all devices (last write wins).
class TimelySettings {
  String bg;
  String fg;
  String accent;
  String muted;
  List<CategoryDef> categories;
  Map<String, String> appCategory; // mergeKey -> category id
  Map<String, String> aliases; // mergeKey -> canonical mergeKey
  Set<String> removedCategories; // default categories the user deleted
  int idleMinutes;

  TimelySettings({
    this.bg = '#0f0f0e',
    this.fg = '#e8e4dc',
    this.accent = '#ffb000',
    this.muted = '#7c776f',
    List<CategoryDef>? categories,
    Map<String, String>? appCategory,
    Map<String, String>? aliases,
    Set<String>? removedCategories,
    this.idleMinutes = 3,
  })  : categories = categories ?? [...defaultCategories],
        appCategory = appCategory ?? {},
        aliases = aliases ?? {},
        removedCategories = removedCategories ?? {} {
    _addMissingDefaults();
  }

  /// Categories introduced in a later version show up for existing accounts too,
  /// unless the user deleted them. They go before "other", which stays last.
  void _addMissingDefaults() {
    for (final d in defaultCategories) {
      if (removedCategories.contains(d.id) || categories.any((c) => c.id == d.id)) continue;
      final other = categories.indexWhere((c) => c.id == 'other');
      categories.insert(other == -1 ? categories.length : other, d);
    }
  }

  static const presets = <String, List<String>>{
    // name: [bg, fg, accent, muted]
    'amber': ['#0f0f0e', '#ffb000', '#ffcc66', '#8a6a2a'],
    'ink': ['#0f0f0e', '#e8e4dc', '#ffb000', '#7c776f'],
    'phosphor': ['#0a0f0b', '#7dff9a', '#c6ffd2', '#3f7a4c'],
    'paper': ['#f4f1ea', '#1d1c1a', '#c25b2a', '#8a857c'],
    'ice': ['#0d1117', '#c9d4e3', '#7cc4ff', '#5c6b7e'],
  };

  void applyPreset(String name) {
    final p = presets[name];
    if (p == null) return;
    bg = p[0];
    fg = p[1];
    accent = p[2];
    muted = p[3];
  }

  String categoryOf(String key, String appId, String name) => appCategory[key] ?? guessCategory(appId, name);

  CategoryDef category(String id) =>
      categories.firstWhere((c) => c.id == id, orElse: () => categories.firstWhere((c) => c.id == 'other',
          orElse: () => const CategoryDef('other', 'other', '#9a8f80')));

  Map<String, dynamic> toJson() => {
        'bg': bg,
        'fg': fg,
        'accent': accent,
        'muted': muted,
        'categories': [for (final c in categories) c.toJson()],
        'appCategory': appCategory,
        'aliases': aliases,
        'removedCategories': removedCategories.toList(),
        'idleMinutes': idleMinutes,
      };

  factory TimelySettings.fromJson(Map<String, dynamic>? j) {
    if (j == null) return TimelySettings();
    final d = TimelySettings();
    String col(String k, String def) {
      final v = j[k];
      return v is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(v) ? v : def;
    }

    return TimelySettings(
      bg: col('bg', d.bg),
      fg: col('fg', d.fg),
      accent: col('accent', d.accent),
      muted: col('muted', d.muted),
      categories: j['categories'] is List
          ? [for (final c in j['categories'] as List) CategoryDef.fromJson(c as Map<String, dynamic>)]
          : null,
      appCategory: (j['appCategory'] as Map?)?.cast<String, String>(),
      aliases: (j['aliases'] as Map?)?.cast<String, String>(),
      removedCategories: (j['removedCategories'] as List?)?.cast<String>().toSet(),
      idleMinutes: (j['idleMinutes'] as num?)?.toInt() ?? d.idleMinutes,
    );
  }
}
