// Sign out from settings, then sign back in with email + password.
// flutter test integration_test/signin_test.dart -d linux \
//   --dart-define=SERVER=https://... --dart-define=EMAIL=... --dart-define=PASSWORD=...
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timely/main.dart';
import 'package:timely/state.dart';
import 'package:timely_core/timely_core.dart';

const email = String.fromEnvironment('EMAIL');
const password = String.fromEnvironment('PASSWORD');
const server = String.fromEnvironment('SERVER');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> wait(WidgetTester t, double s) async {
    final end = DateTime.now().add(Duration(milliseconds: (s * 1000).round()));
    while (DateTime.now().isBefore(end)) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await t.pump();
    }
  }

  testWidgets('sign out, wrong password, sign in', (t) async {
    final state = AppState();
    await t.runAsync(state.init);
    if (!state.signedIn) {
      await t.runAsync(() => state.login(server, email, password));
    }
    expect(state.signedIn, isTrue);
    final oldId = state.creds!.deviceId;
    final oldToken = state.creds!.token;
    await t.pumpWidget(TimelyApp(state: state));
    await wait(t, 2);

    // sign out via settings
    await t.tap(find.text('settings'));
    await wait(t, 0.5);
    final signOut = find.text('sign out this device');
    await t.ensureVisible(signOut);
    await t.pump();
    await t.tap(signOut);
    await wait(t, 0.5);
    await t.tap(find.widgetWithText(FilledButton, 'sign out'));
    await wait(t, 3);
    expect(state.signedIn, isFalse);
    expect(DesktopPaths.readCredentials(), isNull, reason: 'agent credentials removed');
    expect(find.text('screen time, everywhere.'), findsOneWidget);

    // wrong password is rejected with a message
    await t.tap(find.text('sign in'));
    await wait(t, 0.3);
    await t.enterText(find.widgetWithText(TextField, 'server'), server);
    await t.enterText(find.widgetWithText(TextField, 'email'), email);
    await t.enterText(find.widgetWithText(TextField, 'password'), 'definitely-wrong');
    await t.tap(find.widgetWithText(FilledButton, 'sign in'));
    await wait(t, 4);
    expect(find.text('wrong email or password'), findsOneWidget);
    expect(state.signedIn, isFalse);

    // correct password (the desktop test harness doesn't re-deliver enterText to an
    // already-focused field, so set it through the controller like a paste would)
    t.widget<TextField>(find.widgetWithText(TextField, 'password')).controller!.text = password;
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, 'sign in'));
    final end = DateTime.now().add(const Duration(seconds: 40));
    while (!(state.signedIn && state.lastRefresh != null) && DateTime.now().isBefore(end)) {
      await wait(t, 0.3);
    }
    expect(state.signedIn, isTrue);
    expect(state.creds!.deviceId, oldId, reason: 'same computer keeps its device and history');
    expect(state.creds!.token, isNot(oldToken), reason: 'fresh token issued');
    expect(DesktopPaths.readCredentials()?.token, state.creds!.token, reason: 'agent gets new token');
    expect(state.chunks.isNotEmpty, isTrue, reason: 'history visible after sign-in');
    await wait(t, 1);
  });
}
