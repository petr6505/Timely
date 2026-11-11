import 'package:flutter/material.dart';

import 'native.dart';
import 'screens/auth.dart';
import 'screens/home.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets/common.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  NativeBridge.init(args);
  final state = AppState();
  await state.init();
  runApp(TimelyApp(state: state));
}

class TimelyApp extends StatefulWidget {
  final AppState state;
  const TimelyApp({super.key, required this.state});
  @override
  State<TimelyApp> createState() => _TimelyAppState();
}

class _TimelyAppState extends State<TimelyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) widget.state.refresh(pushLocal: true);
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      child: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final p = Palette(widget.state.settings);
          return PaletteScope(
            palette: p,
            child: MaterialApp(
              title: 'Timely',
              debugShowCheckedModeBanner: false,
              theme: buildTheme(p),
              home: widget.state.signedIn ? const HomeScreen() : const AuthScreen(),
            ),
          );
        },
      ),
    );
  }
}
