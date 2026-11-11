import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  bool get unauthorized => status == 401;
  @override
  String toString() => message;
}

class Credentials {
  final String server;
  final String token;
  final String deviceId;
  const Credentials(this.server, this.token, this.deviceId);
  Map<String, dynamic> toJson() => {'server': server, 'token': token, 'deviceId': deviceId};
  static Credentials? fromJson(Map<String, dynamic>? j) {
    if (j == null || j['token'] == null) return null;
    return Credentials(j['server'] as String, j['token'] as String, j['deviceId'] as String);
  }
}

class RemoteDevice {
  final String id, name, platform;
  final int createdAt, lastSeen;
  RemoteDevice(this.id, this.name, this.platform, this.createdAt, this.lastSeen);
  factory RemoteDevice.fromJson(Map<String, dynamic> j) => RemoteDevice(
      j['id'] as String, j['name'] as String, j['platform'] as String,
      (j['createdAt'] as num).toInt(), (j['lastSeen'] as num).toInt());
}

class RemoteChunk {
  final String deviceId, day;
  final int kind, updatedAt;
  final List<int> data;
  RemoteChunk(this.deviceId, this.day, this.kind, this.updatedAt, this.data);
}

class PairInfo {
  final String code, link, appLink;
  final DateTime expiresAt;
  PairInfo(this.code, this.link, this.appLink, this.expiresAt);
}

/// Normalises a user-typed server address. HTTPS is enforced except for local dev.
String normalizeServer(String s) {
  var x = s.trim();
  if (x.endsWith('/')) x = x.substring(0, x.length - 1);
  if (!x.startsWith('http://') && !x.startsWith('https://')) x = 'https://$x';
  final u = Uri.parse(x);
  final local = u.host == 'localhost' || u.host == '127.0.0.1' || u.host == '10.0.2.2';
  if (u.scheme != 'https' && !local) throw ApiException(0, 'server must use https');
  return x;
}

class TimelyApi {
  final String server;
  final String? token;
  final http.Client _c;
  TimelyApi(this.server, {this.token, http.Client? client}) : _c = client ?? http.Client();

  factory TimelyApi.of(Credentials c) => TimelyApi(c.server, token: c.token);

  Map<String, String> get _h => {
        'content-type': 'application/json',
        if (token != null) 'authorization': 'Bearer $token',
      };

  Future<dynamic> _send(String method, String path, {Object? json, List<int>? bytes}) async {
    final req = http.Request(method, Uri.parse('$server$path'));
    req.headers.addAll(_h);
    if (json != null) req.body = jsonEncode(json);
    if (bytes != null) {
      req.headers['content-type'] = 'application/octet-stream';
      req.bodyBytes = bytes;
    }
    final res = await http.Response.fromStream(await _c.send(req).timeout(const Duration(seconds: 30)));
    dynamic body;
    try {
      body = jsonDecode(res.body);
    } catch (_) {
      body = null;
    }
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, (body is Map ? body['error'] : null)?.toString() ?? 'HTTP ${res.statusCode}');
    }
    return body;
  }

  Future<Credentials> _auth(String path, Map<String, dynamic> body) async {
    final r = await _send('POST', path, json: body) as Map<String, dynamic>;
    return Credentials(server, r['token'] as String, r['deviceId'] as String);
  }

  Future<Credentials> register(String email, String password, String deviceName, String platform) =>
      _auth('/v1/register', {'email': email, 'password': password, 'deviceName': deviceName, 'platform': platform});

  Future<Credentials> login(String email, String password, String deviceName, String platform) =>
      _auth('/v1/login', {'email': email, 'password': password, 'deviceName': deviceName, 'platform': platform});

  Future<Credentials> redeem(String code, String deviceName, String platform) =>
      _auth('/v1/pair/redeem', {'code': code, 'deviceName': deviceName, 'platform': platform});

  Future<PairInfo> createPair() async {
    final r = await _send('POST', '/v1/pair/create') as Map<String, dynamic>;
    return PairInfo(r['code'] as String, r['link'] as String, r['appLink'] as String,
        DateTime.fromMillisecondsSinceEpoch((r['expiresAt'] as num).toInt()));
  }

  Future<(List<RemoteDevice>, String)> devices() async {
    final r = await _send('GET', '/v1/devices') as Map<String, dynamic>;
    return ([for (final d in r['devices'] as List) RemoteDevice.fromJson(d as Map<String, dynamic>)], r['self'] as String);
  }

  Future<void> renameDevice(String id, String name) => _send('PATCH', '/v1/devices/$id', json: {'name': name});
  Future<void> removeDevice(String id, {bool purge = false}) =>
      _send('DELETE', '/v1/devices/$id${purge ? '?purge=1' : ''}');

  Future<void> putChunk(String day, List<int> gz) => _send('PUT', '/v1/chunks/$day', bytes: gz);

  /// Returns chunks changed after [since] (ms). Pages until complete.
  Future<List<RemoteChunk>> chunksSince(int since) async {
    final out = <RemoteChunk>[];
    var cursor = since;
    while (true) {
      final r = await _send('GET', '/v1/chunks?since=$cursor') as Map<String, dynamic>;
      for (final c in r['chunks'] as List) {
        final m = c as Map<String, dynamic>;
        final rc = RemoteChunk(m['deviceId'] as String, m['day'] as String, (m['kind'] as num).toInt(),
            (m['updatedAt'] as num).toInt(), base64Decode(m['data'] as String));
        out.add(rc);
        if (rc.updatedAt > cursor) cursor = rc.updatedAt;
      }
      if (r['more'] != true) break;
    }
    return out;
  }

  Future<(Map<String, dynamic>?, int)> getSettings() async {
    final r = await _send('GET', '/v1/settings') as Map<String, dynamic>;
    return (r['data'] as Map<String, dynamic>?, (r['updatedAt'] as num).toInt());
  }

  Future<int> putSettings(Map<String, dynamic> data) async {
    final r = await _send('PUT', '/v1/settings', json: {'data': data}) as Map<String, dynamic>;
    return (r['updatedAt'] as num).toInt();
  }

  Future<void> logout() => _send('POST', '/v1/logout');
  Future<void> deleteAccount(String password) => _send('POST', '/v1/account/delete', json: {'password': password});
}
