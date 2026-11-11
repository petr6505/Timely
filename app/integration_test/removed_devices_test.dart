// History of a removed device can be hidden from the statistics or deleted.
// Needs an account that has history from a device that was removed:
// flutter test integration_test/removed_devices_test.dart -d linux \
//   --dart-define=SERVER=... --dart-define=PAIR_CODE=XXXX-XXXX
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timely/main.dart';
import 'package:timely/state.dart';
import 'package:timely_core/timely_core.dart';

const server = String.fromEnvironment('SERVER');
const pairCode = String.fromEnvironment('PAIR_CODE');
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
      File('$shotDir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  int total(AppState st) {
    final today = dayKey(DateTime.now());
    return summarize(st.chunks, st.settings, Filter(fromDay: today, toDay: today)).focus;
  }

  testWidgets('hide and delete history of a removed device', (t) async {
    final st = AppState();
    await t.runAsync(() async {
      await st.init();
      if (st.signedIn) await st.signOut(remote: false);
      await st.redeem(server, pairCode);
    });
    await t.pumpWidget(RepaintBoundary(key: key, child: TimelyApp(state: st)));
    await wait(t, 1);

    expect(st.removedDevices, hasLength(1));
    final old = st.removedDevices.single;
    final before = total(st);
    expect(before, greaterThanOrEqualTo(old.focus));

    await t.tap(find.text('devices').first); // nav link
    await wait(t, 1);
    final hide = find.widgetWithText(TextButton, 'hide');
    await t.ensureVisible(hide);
    await t.pump();
    expect(find.text('removed device'), findsOneWidget);
    await shot(t, 'removed-1');

    // hide: excluded from statistics, synced as a setting
    await t.tap(hide);
    await wait(t, 3);
    expect(st.settings.hiddenDevices, contains(old.id));
    expect(total(st), before - old.focus);
    expect(find.text('removed device (hidden)'), findsOneWidget);
    final (remote, _) = (await t.runAsync(() => st.api.getSettings()))!;
    expect(TimelySettings.fromJson(remote).hiddenDevices, contains(old.id));

    // show again
    await t.tap(find.widgetWithText(TextButton, 'show'));
    await wait(t, 1);
    expect(total(st), before);

    // delete: gone locally and on the server
    await t.tap(find.widgetWithText(TextButton, 'delete'));
    await wait(t, 0.5);
    await t.tap(find.widgetWithText(FilledButton, 'delete'));
    await wait(t, 3);
    expect(st.removedDevices, isEmpty);
    expect(find.text('removed devices'), findsNothing);
    final remaining = (await t.runAsync(() => st.api.chunksSince(0)))!;
    expect(remaining.where((c) => c.deviceId == old.id), isEmpty);
    await shot(t, 'removed-2');
  });
}
