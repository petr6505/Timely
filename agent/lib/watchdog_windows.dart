import 'dart:io';

const taskName = 'Timely agent';

/// Registers (or refreshes) a scheduled task that starts the agent every
/// 5 minutes. Only one agent can hold the lock, so extra starts exit right
/// away. This brings the agent back after a crash, and starts it after login
/// even when the Run key doesn't (e.g. it was turned off under Startup apps).
///
/// The task is defined in XML because schtasks' defaults would not start it
/// on battery and would even stop the agent when a laptop gets unplugged.
Future<void> registerWatchdog(Directory dir, void Function(String) log) async {
  final exe = Platform.resolvedExecutable;
  if (!exe.toLowerCase().endsWith('timely-agent.exe')) return; // dart run, tests
  final xml = File('${dir.path}\\watchdog-task.xml');
  // schtasks wants UTF-16 with a byte order mark
  final units = _taskXml(exe).codeUnits;
  xml.writeAsBytesSync([0xff, 0xfe, for (final u in units) ...[u & 0xff, u >> 8]]);
  // detached, because schtasks is a console program and would flash a window
  final p = await Process.start('schtasks', ['/create', '/f', '/tn', taskName, '/xml', xml.path],
      mode: ProcessStartMode.detachedWithStdio);
  final out = await Future.wait([p.stdout, p.stderr].map((s) => s.transform(systemEncoding.decoder).join()));
  log('schtasks: ${out.join(' ').trim()}');
}

String _taskXml(String exe) {
  final command = exe.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  return '''<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Keeps the Timely screen time agent running.</Description>
  </RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Repetition><Interval>PT5M</Interval></Repetition>
    </TimeTrigger>
  </Triggers>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <StartWhenAvailable>true</StartWhenAvailable>
    <Hidden>true</Hidden>
  </Settings>
  <Actions>
    <Exec><Command>$command</Command></Exec>
  </Actions>
</Task>
''';
}
