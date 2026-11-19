/// 凭证与端点的持久化：token 进系统保险箱，base 进 SharedPreferences。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../model/models.dart';

class Connection {
  const Connection({required this.base, required this.token});

  final Uri base;
  final String token;

  Connection copyWith({Uri? base, String? token}) =>
      Connection(base: base ?? this.base, token: token ?? this.token);
}

class ConnectionStore {
  static const _tokenKey = 'chatluna.token';
  static const _baseKey = 'chatluna.base';
  static const _labelKey = 'chatluna.label';

  final _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(),
    // 不要 userPresence：未录入生物识别或首次解锁前读取会让钥匙串直接失败，
    // 用户每次启动都要重贴 token。`first_unlock_this_device` 已保证锁屏时读不到。
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  Future<Connection?> load() async {
    final base = (await SharedPreferences.getInstance()).getString(_baseKey);
    String? token;
    try {
      token = await _secure.read(key: _tokenKey);
    } catch (_) {
      // Keystore 不可用或旧版本写入的数据解不开：当作未连接，走登录页，不要在这里抛。
      token = null;
    }
    if (base == null || token == null || token.isEmpty) return null;
    final uri = Uri.tryParse(base);
    if (uri == null) return null;
    return Connection(base: uri, token: token);
  }

  Future<void> save(Connection connection) async {
    await _secure.write(key: _tokenKey, value: connection.token);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseKey, connection.base.toString());
  }

  /// 上次连接的地址，用于登录页预填。
  Future<Uri?> lastBase() async {
    final value = (await SharedPreferences.getInstance()).getString(_baseKey);
    return value == null ? null : Uri.tryParse(value);
  }

  Future<String?> label() async =>
      (await SharedPreferences.getInstance()).getString(_labelKey);

  Future<void> saveLabel(String label) async =>
      (await SharedPreferences.getInstance()).setString(_labelKey, label);

  Future<void> clear() async {
    await _secure.delete(key: _tokenKey);
    await (await SharedPreferences.getInstance()).remove(_baseKey);
  }
}

/// 把用户输入的 `192.168.0.107:5028` / `bot.example.com` / `http://…` 归一成 Uri。
/// 规则：显式 scheme 优先；否则局域网/裸主机名走 http:5028，公网域名走 https:443。
/// 全角标点、带 `%` 的主机名等非法输入一律拒绝——它们会在 socket 层抛 FormatException。
Uri? normalizeBase(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;
  // 先挡非法字符：中文输入法/误触产生的全角标点会让 Uri 把主机名解析成意想不到的东西。
  if (!RegExp(r'^[A-Za-z0-9.:/_\-\[\]]+$').hasMatch(text)) return null;
  final hasScheme = text.contains('://');
  final uri = Uri.tryParse(hasScheme ? text : 'http://$text');
  if (uri == null || uri.host.isEmpty) return null;
  final host = uri.host;
  final validHost =
      RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(host) ||
      (host.startsWith('[') && host.endsWith(']'));
  if (!validHost) return null;
  final scheme = hasScheme ? uri.scheme : (_isLanHost(host) ? 'http' : 'https');
  final port = uri.hasPort ? uri.port : (scheme == 'https' ? 443 : 5028);
  return Uri(scheme: scheme, host: host, port: port);
}

bool _isLanHost(String host) {
  if (host == 'localhost' || host.endsWith('.local')) return true;
  final parts = host.split('.');
  if (parts.length == 4 && parts.every((part) => int.tryParse(part) != null)) {
    final a = int.parse(parts[0]);
    final b = int.parse(parts[1]);
    return a == 10 ||
        a == 127 ||
        (a == 192 && b == 168) ||
        (a == 172 && b >= 16 && b <= 31);
  }
  return !host.contains('.');
}

ApiFailure asFailure(Object error) => error is ApiFailure
    ? error
    : ApiFailure('INTERNAL', error.toString());
