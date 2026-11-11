/// Default categories and heuristics for auto-categorising apps.
class CategoryDef {
  final String id;
  final String name;
  final String color; // #rrggbb
  const CategoryDef(this.id, this.name, this.color);
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'color': color};
  factory CategoryDef.fromJson(Map<String, dynamic> j) =>
      CategoryDef(j['id'] as String, j['name'] as String, j['color'] as String);
}

const defaultCategories = <CategoryDef>[
  CategoryDef('social', 'social', '#e5735c'),
  CategoryDef('communication', 'communication', '#d9a441'),
  CategoryDef('entertainment', 'entertainment', '#c2569a'),
  CategoryDef('music', 'music', '#8f7ad6'),
  CategoryDef('productivity', 'productivity', '#5aa7d8'),
  CategoryDef('development', 'development', '#4fb99f'),
  CategoryDef('browsing', 'browsing', '#8fb35a'),
  CategoryDef('games', 'games', '#d6635f'),
  CategoryDef('navigation', 'navigation', '#c9a87a'),
  CategoryDef('system', 'system', '#6f747a'),
  CategoryDef('other', 'other', '#9a8f80'),
];

const _rules = <String, List<String>>{
  'social': ['instagram', 'facebook', 'tiktok', 'musically', 'twitter', 'xcorp', 'reddit', 'snapchat', 'pinterest',
    'linkedin', 'threads', 'mastodon', 'bluesky', 'tumblr', 'bereal'],
  'communication': ['whatsapp', 'telegram', 'signal', 'messenger', 'messages', 'mms', 'discord', 'slack', 'teams',
    'zoom', 'skype', 'beeper', 'incallui', 'call', 'gmail', 'mail', 'outlook', 'thunderbird', 'dialer', 'phone', 'contacts', 'viber', 'element'],
  'entertainment': ['youtube', 'netflix', 'twitch', 'primevideo', 'disney', 'hbo', 'max', 'vlc', 'mpv', 'plex',
    'jellyfin', 'kodi', 'video', 'stremio', 'crunchyroll'],
  'music': ['spotify', 'music', 'soundcloud', 'deezer', 'tidal', 'rhythmbox', 'podcast', 'audible', 'pocketcasts'],
  'productivity': ['docs', 'sheets', 'slides', 'office', 'word', 'excel', 'powerpoint', 'libreoffice', 'notion',
    'obsidian', 'claude', 'chatgpt', 'openai', 'gemini', 'perplexity', 'copilot', 'calendar', 'keep', 'notes', 'todoist', 'evernote', 'drive', 'onenote', 'pdf', 'reader', 'calculator'],
  'development': ['code', 'vscode', 'terminal', 'konsole', 'ptyxis', 'kitty', 'alacritty', 'wezterm', 'idea',
    'jetbrains', 'androidstudio', 'studio', 'pycharm', 'clion', 'webstorm', 'rider', 'devenv', 'cmd', 'powershell',
    'windowsterminal', 'neovim', 'vim', 'emacs', 'github', 'git', 'postman', 'docker', 'cursor', 'zed', 'sublime'],
  'browsing': ['firefox', 'chrome', 'chromium', 'brave', 'edge', 'opera', 'vivaldi', 'browser', 'sbrowser', 'safari',
    'librewolf', 'epiphany', 'duckduckgo', 'tor'],
  'games': ['steam', 'game', 'lutris', 'heroic', 'epicgames', 'minecraft', 'roblox', 'supercell', 'riot',
    'battle.net', 'xbox', 'playgames'],
  'navigation': ['androidauto', 'android auto', 'projection.gearhead', 'waze', 'maps', 'osmand', 'organicmaps',
    'citymapper', 'moovit', 'uber', 'bolt'],
  'system': ['launcher', 'launch', 'settings', 'systemui', 'nautilus', 'files', 'explorer', 'gnome', 'packageinstaller',
    'camera', 'gallery', 'photos', 'clock', 'taskmgr', 'controlpanel', 'oneui', 'home'],
};

String guessCategory(String appId, String name) {
  final hay = '${appId.toLowerCase()} ${name.toLowerCase()}';
  // music before entertainment so "YouTube Music" -> music
  for (final cat in ['music', 'social', 'communication', 'entertainment', 'games', 'navigation', 'development',
    'browsing', 'productivity', 'system']) {
    for (final kw in _rules[cat]!) {
      if (hay.contains(kw)) return cat;
    }
  }
  return 'other';
}

const _builtinAliases = <String, String>{
  'googlechrome': 'chrome',
  'chromium': 'chrome',
  'firefoxwebbrowser': 'firefox',
  'mozillafirefox': 'firefox',
  'visualstudiocode': 'vscode',
  'code': 'vscode',
  'microsoftedge': 'edge',
  'spotifymusic': 'spotify',
  'telegramdesktop': 'telegram',
  'discordapp': 'discord',
  'whatsappmessenger': 'whatsapp',
};

/// Key under which the same app is merged across devices.
String mergeKey(String name, [Map<String, String> userAliases = const {}]) {
  var k = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (k.isEmpty) k = name.toLowerCase();
  k = userAliases[k] ?? _builtinAliases[k] ?? k;
  return userAliases[k] ?? k;
}
