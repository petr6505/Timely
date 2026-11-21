import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'probe.dart';

/// Windows: foreground window -> process exe; idle via GetLastInputInfo;
/// background audio via Core Audio session state.
class WindowsProbe extends Probe {
  final Map<String, String> _names = {};

  @override
  String get source => 'win32';

  @override
  Future<FocusInfo?> focus() async {
    final idle = _idleMs();
    final hwnd = GetForegroundWindow();
    if (hwnd == 0) return FocusInfo('', '', idle, true);
    var pid = _pidOf(hwnd);
    var path = _exePath(pid);
    // UWP apps are hosted by ApplicationFrameHost; find the real child process.
    if (path != null && path.toLowerCase().endsWith('applicationframehost.exe')) {
      final child = _uwpChild(hwnd, pid);
      if (child != null) path = _exePath(child) ?? path;
    }
    if (path == null) return FocusInfo('', '', idle, false);
    final exe = path.split('\\').last;
    final id = _appId(exe);
    final locked = id == 'lockapp' || id == 'logonui';
    return FocusInfo(id, _names[path] ??= _displayName(path, exe), idle, locked);
  }

  int _idleMs() {
    final lii = calloc<LASTINPUTINFO>()..ref.cbSize = sizeOf<LASTINPUTINFO>();
    try {
      if (GetLastInputInfo(lii) == 0) return 0;
      return (GetTickCount() - lii.ref.dwTime) & 0xffffffff;
    } finally {
      calloc.free(lii);
    }
  }

  int _pidOf(int hwnd) {
    final p = calloc<Uint32>();
    try {
      GetWindowThreadProcessId(hwnd, p);
      return p.value;
    } finally {
      calloc.free(p);
    }
  }

  static int _enumParentPid = 0;
  static int _enumFound = 0;
  static int _enumProc(int hwnd, int lParam) {
    final p = calloc<Uint32>();
    GetWindowThreadProcessId(hwnd, p);
    final pid = p.value;
    calloc.free(p);
    if (pid != _enumParentPid) {
      _enumFound = pid;
      return 0;
    }
    return 1;
  }

  int? _uwpChild(int hwnd, int parentPid) {
    _enumParentPid = parentPid;
    _enumFound = 0;
    final cb = NativeCallable<WNDENUMPROC>.isolateLocal(_enumProc, exceptionalReturn: 0);
    EnumChildWindows(hwnd, cb.nativeFunction, 0);
    cb.close();
    return _enumFound == 0 ? null : _enumFound;
  }

  String? _exePath(int pid) {
    if (pid == 0) return null;
    final h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (h == 0) return null;
    final buf = wsalloc(1024);
    final len = calloc<Uint32>()..value = 1024;
    try {
      if (QueryFullProcessImageName(h, 0, buf, len) == 0) return null;
      return buf.toDartString(length: len.value);
    } finally {
      CloseHandle(h);
      free(buf);
      calloc.free(len);
    }
  }

  /// FileDescription from the exe's version resource, e.g. "Google Chrome".
  String _displayName(String path, String exe) => using((arena) {
        final fallback = exe.replaceFirst(RegExp(r'\.exe$', caseSensitive: false), '');
        final file = path.toNativeUtf16(allocator: arena);
        final size = GetFileVersionInfoSize(file, nullptr);
        if (size == 0) return fallback;
        final data = arena<Uint8>(size).cast<Void>();
        if (GetFileVersionInfo(file, 0, size, data) == 0) return fallback;

        final value = arena<Pointer>();
        final len = arena<Uint32>();
        var lang = '040904b0';
        if (VerQueryValue(data, r'\VarFileInfo\Translation'.toNativeUtf16(allocator: arena), value, len) != 0 &&
            len.value >= 4) {
          final w = value.value.cast<Uint16>();
          lang = w[0].toRadixString(16).padLeft(4, '0') + w[1].toRadixString(16).padLeft(4, '0');
        }
        final query = '\\StringFileInfo\\$lang\\FileDescription'.toNativeUtf16(allocator: arena);
        if (VerQueryValue(data, query, value, len) != 0 && len.value > 1) {
          final name = value.value.cast<Utf16>().toDartString().trim();
          if (name.isNotEmpty) return name;
        }
        return fallback;
      });

  static String _appId(String exe) {
    final lower = exe.toLowerCase();
    return lower.endsWith('.exe') ? lower.substring(0, lower.length - 4) : lower;
  }

  @override
  Future<List<MediaApp>> playing() async {
    // COM objects are created and released within this one synchronous call.
    // They are detached from the win32 package's finalizers, which would
    // otherwise release them a second time, possibly from another thread.
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    final owned = <IUnknown>[];
    T own<T extends IUnknown>(T o) {
      o.detach();
      owned.add(o);
      return o;
    }

    Pointer<COMObject> out() => calloc<COMObject>();
    final apps = <MediaApp>[];
    final count = calloc<Int32>();
    final state = calloc<Int32>();
    final pid = calloc<Uint32>();
    try {
      final devices = own(MMDeviceEnumerator.createInstance());
      final pDevice = out();
      if (devices.getDefaultAudioEndpoint(0 /* eRender */, 1 /* eMultimedia */, pDevice.cast()) != S_OK) {
        free(pDevice);
        return apps;
      }
      final device = own(IMMDevice(pDevice));
      final pManager = out();
      final iid = convertToIID(IID_IAudioSessionManager2);
      final hr = device.activate(iid, CLSCTX_ALL, nullptr, pManager.cast());
      free(iid);
      if (hr != S_OK) {
        free(pManager);
        return apps;
      }
      final manager = own(IAudioSessionManager2(pManager));
      final pSessions = out();
      if (manager.getSessionEnumerator(pSessions.cast()) != S_OK) {
        free(pSessions);
        return apps;
      }
      final sessions = own(IAudioSessionEnumerator(pSessions));
      sessions.getCount(count);
      final seen = <String>{};
      for (var i = 0; i < count.value; i++) {
        final pSession = out();
        if (sessions.getSession(i, pSession.cast()) != S_OK) {
          free(pSession);
          continue;
        }
        final session = own(IAudioSessionControl2.from(own(IAudioSessionControl(pSession))));
        session.getState(state);
        if (state.value != 1 /* AudioSessionStateActive */) continue;
        if (session.isSystemSoundsSession() == S_OK) continue;
        session.getProcessId(pid);
        final path = _exePath(pid.value);
        if (path == null) continue;
        final exe = path.split('\\').last;
        final id = _appId(exe);
        if (seen.add(id)) apps.add(MediaApp(id, _names[path] ??= _displayName(path, exe)));
      }
    } catch (_) {
      // no audio device, audio service restarting, ...
    } finally {
      for (final o in owned.reversed) {
        o.release();
        free(o.ptr);
      }
      calloc.free(count);
      calloc.free(state);
      calloc.free(pid);
    }
    return apps;
  }
}
