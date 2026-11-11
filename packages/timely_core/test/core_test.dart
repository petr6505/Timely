import 'dart:io';

import 'package:test/test.dart';
import 'package:timely_core/timely_core.dart';

void main() {
  test('chunk roundtrip + hourly', () {
    final c = DayChunk(day: '2026-11-09', tzOffsetMin: 60);
    final a = c.appIndex('firefox.desktop', 'Firefox');
    final b = c.appIndex('spotify.desktop', 'Spotify');
    c.focused.addAll([Session(a, 3500, 200), Session(b, 3700, 100)]);
    c.media.add(Session(b, 3000, 4000));
    c.unlocks = 3;
    final d = DayChunk.decode(c.encode());
    expect(d.apps.length, 2);
    expect(d.focused[1].start, 3700);
    expect(d.hourly(a), [100, 100, ...List.filled(22, 0)]);
    expect(d.hourly(b, media: true).fold(0, (x, y) => x + y), 4000);
    expect(d.unlocks, 3);
  });

  test('rollup format decodes', () {
    final d = DayChunk.fromJson({
      'v': 1, 'd': '2026-01-01', 'z': 0, 'a': [['x', 'X']], 'hf': [0, 1, 100, 0, 2, 50], 'hm': [],
    });
    expect(d.isRollup, true);
    expect(d.hourly(0)[1], 100);
  });

  test('recorder merges and splits at midnight', () {
    final dir = Directory.systemTemp.createTempSync('timely');
    final r = Recorder(dir);
    final t = DateTime(2026, 11, 9, 23, 59, 50);
    r.add(t, t.add(const Duration(seconds: 2)), 'a', 'A');
    r.add(t.add(const Duration(seconds: 2)), t.add(const Duration(seconds: 4)), 'a', 'A');
    r.add(t.add(const Duration(seconds: 4)), t.add(const Duration(seconds: 20)), 'a', 'A');
    r.flush();
    final d1 = r.day('2026-11-09');
    final d2 = r.day('2026-11-10');
    expect(d1.focused.length, 1);
    expect(d1.focused.first.dur, 10);
    expect(d2.focused.first.start, 0);
    expect(d2.focused.first.dur, 10);
    expect(r.pendingUpload, containsAll(['2026-11-09', '2026-11-10']));
    dir.deleteSync(recursive: true);
  });

  test('merge keys and categories', () {
    expect(mergeKey('Google Chrome'), 'chrome');
    expect(mergeKey('Spotify'), mergeKey('spotify'));
    expect(guessCategory('com.spotify.music', 'Spotify'), 'music');
    expect(guessCategory('com.instagram.android', 'Instagram'), 'social');
  });

  test('compression size estimate', () {
    final c = DayChunk(day: '2026-11-09', tzOffsetMin: 60);
    var t = 7 * 3600;
    for (var i = 0; i < 400; i++) {
      final app = c.appIndex('com.example.app${i % 25}', 'App ${i % 25}');
      final dur = 20 + (i * 37) % 600;
      c.focused.add(Session(app, t, dur));
      t += dur + 5;
    }
    final bytes = c.encode().length;
    print('400 sessions / 25 apps -> $bytes bytes');
    expect(bytes, lessThan(4000));
  });

  test('summarize merges apps across devices with per-device breakdown', () {
    final phone = DayChunk(day: '2026-11-09', tzOffsetMin: 60);
    final sp = phone.appIndex('com.spotify.music', 'Spotify');
    final ig = phone.appIndex('com.instagram.android', 'Instagram');
    phone.focused.addAll([Session(sp, 3600, 600), Session(ig, 7200, 1200)]);
    phone.media.add(Session(sp, 3600, 5400));
    final pc = DayChunk(day: '2026-11-09', tzOffsetMin: 60);
    final sp2 = pc.appIndex('spotify', 'Spotify');
    pc.focused.add(Session(sp2, 36000, 300));
    final s = TimelySettings();
    final sum = summarize({'phone': {'2026-11-09': phone}, 'pc': {'2026-11-09': pc}}, s,
        const Filter(fromDay: '2026-11-03', toDay: '2026-11-09'));
    expect(sum.focus, 2100);
    expect(sum.media, 5400);
    final spotify = sum.apps['spotify']!;
    expect(spotify.focus, 900);
    expect(spotify.perDevice['phone']!.focus, 600);
    expect(spotify.perDevice['phone']!.media, 5400);
    expect(spotify.perDevice['pc']!.focus, 300);
    expect(sum.categories['music'], 900);
    expect(sum.days.length, 7);
    // device filter
    final onlyPc = summarize({'phone': {'2026-11-09': phone}, 'pc': {'2026-11-09': pc}}, s,
        const Filter(devices: {'pc'}, fromDay: '2026-11-09', toDay: '2026-11-09'));
    expect(onlyPc.focus, 300);
    // user override of category
    s.appCategory['spotify'] = 'productivity';
    final o = summarize({'pc': {'2026-11-09': pc}}, s, const Filter(fromDay: '2026-11-09', toDay: '2026-11-09'));
    expect(o.categories['productivity'], 300);
  });
}
