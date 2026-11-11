import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'probe.dart';

/// Windows: foreground window -> process exe; idle via GetLastInputInfo;
/// background audio via Core Audio session state.
class WindowsProbe extends Probe {
  final Map<String, String> _names = {};
  IAudioSessionManager2? _audio;

  WindowsProbe() {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  }

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
    final lower = exe.toLowerCase();
    final locked = lower == 'lockapp.exe' || lower == 'logonui.exe';
    final id = lower.endsWith('.exe') ? lower.substring(0, lower.length - 4) : lower;
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
  String _displayName(String path, String exe) {
    final fallback = exe.toLowerCase().endsWith('.exe') ? exe.substring(0, exe.length - 4) : exe;
    final p = path.toNativeUtf16();
    try {
      final size = GetFileVersionInfoSize(p, nullptr);
      if (size == 0) return fallback;
      final data = calloc<Uint8>(size);
      try {
        if (GetFileVersionInfo(p, 0, size, data.cast()) == 0) return fallback;
        final trans = calloc<Pointer>();
        final tlen = calloc<Uint32>();
        try {
          var lang = '040904b0';
          if (VerQueryValue(data.cast(), r'\VarFileInfo\Translation'.toNativeUtf16(), trans, tlen) != 0 &&
              tlen.value >= 4) {
            final w = trans.value.cast<Uint16>();
            lang = w[0].toRadixString(16).padLeft(4, '0') + w[1].toRadixString(16).padLeft(4, '0');
          }
          final q = '\\StringFileInfo\\$lang\\FileDescription'.toNativeUtf16();
          final out = calloc<Pointer>();
          final olen = calloc<Uint32>();
          try {
            if (VerQueryValue(data.cast(), q, out, olen) != 0 && olen.value > 1) {
              final s = out.value.cast<Utf16>().toDartString().trim();
              if (s.isNotEmpty) return s;
            }
          } finally {
            calloc.free(q);
            calloc.free(out);
            calloc.free(olen);
          }
        } finally {
          calloc.free(trans);
          calloc.free(tlen);
        }
      } finally {
        calloc.free(data);
      }
    } finally {
      calloc.free(p);
    }
    return fallback;
  }

  IAudioSessionManager2? _mgr() {
    if (_audio != null) return _audio;
    try {
      final en = MMDeviceEnumerator.createInstance();
      final pDev = calloc<COMObject>();
      if (en.getDefaultAudioEndpoint(0 /* eRender */, 1 /* eMultimedia */, pDev.cast()) != S_OK) return null;
      final dev = IMMDevice(pDev);
      final pMgr = calloc<COMObject>();
      final iid = convertToIID(IID_IAudioSessionManager2);
      final hr = dev.activate(iid, CLSCTX_ALL, nullptr, pMgr.cast());
      calloc.free(iid);
      if (hr != S_OK) return null;
      return _audio = IAudioSessionManager2(pMgr);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<MediaApp>> playing() async {
    final out = <MediaApp>[];
    final mgr = _mgr();
    if (mgr == null) return out;
    final pEnum = calloc<COMObject>();
    if (mgr.getSessionEnumerator(pEnum.cast()) != S_OK) {
      _audio = null; // default device may have changed
      return out;
    }
    final en = IAudioSessionEnumerator(pEnum);
    final count = calloc<Int32>();
    en.getCount(count);
    final seen = <String>{};
    for (var i = 0; i < count.value; i++) {
      final pCtl = calloc<COMObject>();
      if (en.getSession(i, pCtl.cast()) != S_OK) continue;
      final ctl = IAudioSessionControl2.from(IAudioSessionControl(pCtl));
      final state = calloc<Int32>();
      final pid = calloc<Uint32>();
      try {
        ctl.getState(state);
        if (state.value != 1 /* AudioSessionStateActive */) continue;
        if (ctl.isSystemSoundsSession() == S_OK) continue;
        ctl.getProcessId(pid);
        final path = _exePath(pid.value);
        if (path == null) continue;
        final exe = path.split('\\').last;
        final id = exe.toLowerCase().replaceAll(RegExp(r'\.exe$'), '');
        if (seen.add(id)) out.add(MediaApp(id, _names[path] ??= _displayName(path, exe)));
      } finally {
        calloc.free(state);
        calloc.free(pid);
        ctl.release();
      }
    }
    calloc.free(count);
    en.release();
    return out;
  }
}
