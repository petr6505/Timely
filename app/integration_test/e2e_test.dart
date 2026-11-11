// End-to-end UI test against a real backend.
// flutter test integration_test/e2e_test.dart -d linux \
//   --dart-define=PAIR_CODE=XXXX-XXXX --dart-define=SHOT_DIR=/tmp/shots
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timely/main.dart';
import 'package:timely/state.dart';
import 'package:timely_core/timely_core.dart';

const pairCode = String.fromEnvironment('PAIR_CODE');
const shotDir = String.fromEnvironment('SHOT_DIR', defaultValue: '/tmp/timely-shots');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final key = GlobalKey();

  Future<void> wait(WidgetTester t, double seconds) async {
    final end = DateTime.now().add(Duration(milliseconds: (seconds * 1000).round()));
    while (DateTime.now().isBefore(end)) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await t.pump();
    }
  }

  Future<void> waitFor(WidgetTester t, bool Function() cond, {double timeout = 40}) async {
    final end = DateTime.now().add(Duration(seconds: timeout.round()));
    while (!cond()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting');
      await wait(t, 0.3);
    }
    await wait(t, 0.5);
  }

  Future<void> shot(WidgetTester t, String name) async {
    await t.pump();
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await t.runAsync(() async {
      final img = await boundary.toImage(pixelRatio: 1);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      Directory(shotDir).createSync(recursive: true);
      File('$shotDir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  Future<void> tapText(WidgetTester t, String text) async {
    final f = find.text(text).first;
    await t.ensureVisible(f);
    await t.pump();
    await t.tap(f);
    await wait(t, 0.6);
  }

  testWidgets('pair, browse every screen, sync settings', (t) async {
    expect(pairCode, isNotEmpty, reason: 'pass --dart-define=PAIR_CODE');
    final state = AppState();
    await t.runAsync(() async {
      await state.init();
      if (state.signedIn) await state.signOut(remote: false);
    });
    await t.pumpWidget(RepaintBoundary(key: key, child: TimelyApp(state: state)));
    await wait(t, 1);
    await shot(t, '01-auth');

    // ---- pair with one-time code ----
    expect(find.text('add this device'), findsOneWidget);
    await t.enterText(find.widgetWithText(TextField, 'pairing code or link'), pairCode);
    await t.tap(find.widgetWithText(FilledButton, 'pair'));
    await waitFor(t, () => state.signedIn && !state.syncing && state.lastRefresh != null);
    expect(state.syncError, isNull);
    expect(state.devices.any((d) => d.platform == 'android'), isTrue, reason: 'phone visible to laptop');
    await shot(t, '02-dash-7d');

    // ---- dashboard interactions ----
    await tapText(t, '30d');
    await shot(t, '03-dash-30d');
    await tapText(t, 'day');
    await shot(t, '04-dash-day');
    await tapText(t, '7d');
    final phone = state.devices.firstWhere((d) => d.platform == 'android');
    await tapText(t, phone.name);
    await shot(t, '05-dash-phone-only');
    await tapText(t, 'all devices');
    // expand the top app to show the per-device submenu
    final chevron = find.byIcon(Icons.expand_more).first;
    await t.ensureVisible(chevron);
    await t.pump();
    await t.tap(chevron);
    await wait(t, 0.5);
    expect(find.textContaining('category:'), findsOneWidget);
    await shot(t, '06-dash-app-expanded');

    // ---- devices ----
    await tapText(t, 'devices');
    expect(find.text(phone.name), findsWidgets);
    await shot(t, '07-devices');
    await tapText(t, '+ add device');
    await waitFor(t, () => find.text('copy link').evaluate().isNotEmpty);
    expect(find.textContaining('single use'), findsOneWidget);
    await shot(t, '08-pair-dialog');
    await t.tap(find.widgetWithText(FilledButton, 'done'));
    await wait(t, 1);

    // ---- settings: theme preset syncs to server ----
    await tapText(t, 'settings');
    await shot(t, '09-settings');
    await tapText(t, 'amber');
    await wait(t, 3); // debounced push
    final (remote, _) = (await t.runAsync(() => state.api.getSettings()))!;
    expect(TimelySettings.fromJson(remote).accent, TimelySettings.presets['amber']![2]);
    expect(TimelySettings.fromJson(remote).fg, TimelySettings.presets['amber']![1]);

    // ---- settings: category colour edit syncs ----
    await tapText(t, 'navigation');
    await t.tap(find.byWidgetPredicate((w) =>
        w is Container && w.decoration is BoxDecoration &&
        (w.decoration! as BoxDecoration).color == const Color(0xFF7CC4FF)).first);
    await wait(t, 0.3);
    await t.tap(find.widgetWithText(FilledButton, 'save'));
    await wait(t, 3);
    final (remote2, _) = (await t.runAsync(() => state.api.getSettings()))!;
    expect(TimelySettings.fromJson(remote2).category('navigation').color, '#7cc4ff');
    await shot(t, '10-settings-amber');

    await tapText(t, 'dash');
    await shot(t, '11-dash-amber');
  });
}
