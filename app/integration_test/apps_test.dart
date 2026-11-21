// Renaming apps and linking the same app from different devices.
// Creates its own account on a local backend (npx wrangler dev). Run it with
// throwaway XDG dirs so it doesn't sign this machine out of the real account:
//
// XDG_CONFIG_HOME=$(mktemp -d) XDG_DATA_HOME=$(mktemp -d) \
//   flutter test integration_test/apps_test.dart -d linux --dart-define=SERVER=http://localhost:8787
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timely/main.dart';
import 'package:timely/state.dart';
import 'package:timely_core/timely_core.dart';

const server = String.fromEnvironment('SERVER', defaultValue: 'http://localhost:8787');
const shotDir = String.fromEnvironment('SHOT_DIR');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final key = GlobalKey();

  Future<void> wait(WidgetTester t, double s) async {
    final end = DateTime.now().add(Duration(milliseconds: (s * 1000).round()));
    while (DateTime.now().isBefore(end)) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await t.pump();
    }
  }

  Future<void> shot(WidgetTester t, String name) async {
    if (shotDir.isEmpty) return;
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await t.runAsync(() async {
      final png = await (await boundary.toImage()).toByteData(format: ui.ImageByteFormat.png);
      Directory(shotDir).createSync(recursive: true);
      File('$shotDir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  Future<void> tap(WidgetTester t, Finder f) async {
    await t.ensureVisible(f.first);
    await t.pump();
    await t.tap(f.first);
    await wait(t, 0.6);
  }

  List<int> chunk(String id, String name, int secs) {
    final c = DayChunk(day: dayKey(DateTime.now()), tzOffsetMin: DateTime.now().timeZoneOffset.inMinutes);
    c.focused.add(Session(c.appIndex(id, name), 3600, secs));
    return c.encode();
  }

  testWidgets('rename and link apps', (t) async {
    expect(Platform.environment['XDG_CONFIG_HOME'], isNotNull, reason: 'run with throwaway XDG dirs, see top of file');
    final today = dayKey(DateTime.now());
    final email = 'apps-${DateTime.now().millisecondsSinceEpoch}@test.dev';
    late String code;
    await t.runAsync(() async {
      final phone = await TimelyApi(server).register(email, 'password123', 'phone', 'android');
      await TimelyApi.of(phone).putChunk(today, chunk('com.brave.browser', 'Brave', 3600));
      final laptop = await TimelyApi(server).login(email, 'password123', 'laptop', 'windows');
      await TimelyApi.of(laptop).putChunk(today, chunk('brave', 'Brave Web Browser', 1800));
      code = (await TimelyApi.of(phone).createPair()).code;
    });

    final st = AppState();
    await t.runAsync(() async {
      await st.init();
      await st.redeem(server, code);
    });
    await t.pumpWidget(RepaintBoundary(key: key, child: TimelyApp(state: st)));
    await wait(t, 2);
    await tap(t, find.text('day'));
    expect(find.text('Brave'), findsOneWidget);
    expect(find.text('Brave Web Browser'), findsOneWidget);

    // link the laptop's browser into the phone's
    await tap(t, find.text('Brave Web Browser'));
    await tap(t, find.text('link with… ⇄'));
    await t.enterText(find.widgetWithText(TextField, 'search'), 'bra');
    await wait(t, 0.3);
    await shot(t, 'link-dialog');
    await tap(t, find.descendant(of: find.byType(AlertDialog), matching: find.text('Brave')));
    expect(find.text('Brave Web Browser'), findsNothing);
    expect(find.text('linked: Brave Web Browser'), findsOneWidget);
    expect(find.text('1h 30m'), findsWidgets);
    expect(find.text('laptop · Brave Web Browser'), findsOneWidget);
    await shot(t, 'linked');

    // rename it
    await tap(t, find.text('rename ✎'));
    await t.enterText(find.byType(TextField), 'Brave browser');
    await tap(t, find.widgetWithText(FilledButton, 'save'));
    expect(find.text('Brave browser'), findsOneWidget);
    await shot(t, 'renamed');

    // both changes reach the server, so every device sees them
    await wait(t, 2);
    final (remote, _) = (await t.runAsync(() => st.api.getSettings()))!;
    final synced = TimelySettings.fromJson(remote);
    expect(synced.links, {'bravewebbrowser': 'brave'});
    expect(synced.appNames, {'brave': 'Brave browser'});

    await tap(t, find.text('unlink ✕'));
    expect(find.text('Brave Web Browser'), findsOneWidget);
    expect(st.settings.links, isEmpty);

    await t.runAsync(() => st.api.deleteAccount('password123'));
  });
}
