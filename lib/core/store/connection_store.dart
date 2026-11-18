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
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      accessControlFlags: [AccessControlFlag.userPresence],
    ),
  );

  Future<Connection?> load() async {
    final base = (await SharedPreferences.getInstance()).getString(_baseKey);
    final token = await _secure.read(key: _tokenKey);
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
Uri? normalizeBase(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;
  final withScheme = text.contains('://') ? text : 'http://$text';
  final uri = Uri.tryParse(withScheme);
  if (uri == null || uri.host.isEmpty) return null;
  final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 5028);
  return Uri(scheme: uri.scheme, host: uri.host, port: port);
}

ApiFailure asFailure(Object error) => error is ApiFailure
    ? error
    : ApiFailure('INTERNAL', error.toString());
