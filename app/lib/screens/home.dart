import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'dashboard.dart';
import 'devices.dart';
import 'settings.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int tab = 0;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final st = AppScope.of(context);
    Widget navItem(String label, int i) => InkWell(
          onTap: () => setState(() => tab = i),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Text(label,
                style: TextStyle(
                  fontSize: 12,
                  color: tab == i ? p.accent : p.muted,
                  decoration: tab == i ? TextDecoration.underline : null,
                  decorationColor: p.accent,
                )),
          ),
        );
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
                child: Row(children: [
                  Mono('timely', size: 16, color: p.accent, weight: FontWeight.w500),
                  const Spacer(),
                  navItem('dash', 0),
                  navItem('devices', 1),
                  navItem('settings', 2),
                  IconButton(
                    tooltip: 'sync now',
                    onPressed: st.syncing ? null : () => st.refresh(pushLocal: true),
                    icon: st.syncing
                        ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5, color: p.muted))
                        : Icon(Icons.sync, size: 16, color: st.syncError != null ? const Color(0xFFE5735C) : p.muted),
                  ),
                ]),
              ),
            ),
          ),
          Expanded(
            child: IndexedStack(index: tab, children: [
              DashboardScreen(onOpenSetup: () => setState(() => tab = 1)),
              const DevicesScreen(),
              const SettingsScreen(),
            ]),
          ),
        ]),
      ),
    );
  }
}
