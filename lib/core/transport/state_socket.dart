/// WebUI 的 state 通道：`ws(s)://<base>/api/webui/socket`。
/// 首帧 `auth`，随后 `sub {id,key,params}`；服务端回 `state {id,value}`。
/// 这里只实现「取一次快照」：连接 → auth → sub → 等首个 state → 关闭。
library;

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../model/models.dart';

class StateSocket {
  StateSocket({required this.base, required this.token});

  final Uri base;
  final String token;

  static const _timeout = Duration(seconds: 10);

  Uri get _uri {
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return base.replace(scheme: scheme, path: '/api/webui/socket');
  }

  /// 取一个 state 键的快照；超时或鉴权失败返回 null。
  Future<Object?> fetch(String key, {Map<String, Object?>? params}) async {
    final channel = WebSocketChannel.connect(_uri);
    final completer = Completer<Object?>();
    final id = 'sub-${DateTime.now().microsecondsSinceEpoch}';
    late final StreamSubscription<dynamic> sub;
    final timer = Timer(_timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });

    void finish(Object? value) {
      if (completer.isCompleted) return;
      completer.complete(value);
    }

    try {
      await channel.ready.timeout(_timeout);
      channel.sink.add(jsonEncode({'type': 'auth', 'credential': token}));
      channel.sink.add(jsonEncode({
        'type': 'sub',
        'id': id,
        'key': key,
        'params': ?params,
      }));
      sub = channel.stream.listen(
        (dynamic raw) {
          final Object? decoded;
          try {
            decoded = jsonDecode(raw as String);
          } catch (_) {
            return;
          }
          if (decoded is! Map) return;
          switch (decoded['type']) {
            case 'state':
              if (decoded['id'] == id) finish(decoded['value']);
            case 'unauthorized':
              finish(null);
          }
        },
        onError: (Object _) => finish(null),
        onDone: () => finish(null),
      );
      final value = await completer.future;
      await sub.cancel();
      return value;
    } on TimeoutException {
      return null;
    } on ApiFailure {
      rethrow;
    } catch (_) {
      return null;
    } finally {
      timer.cancel();
      await channel.sink.close();
    }
  }
}

class BotProfile {
  const BotProfile({required this.platform, required this.selfId, required this.name, this.avatar});

  final String platform;
  final String selfId;
  final String name;
  final String? avatar;

  /// 从 `adapters.bots` 的 state 里挑一个在线的 bot。
  static BotProfile? pick(Object? value) {
    if (value is! Map) return null;
    final bots = value['bots'];
    if (bots is! List) return null;
    Map<String, Object?>? chosen;
    for (final item in bots) {
      if (item is! Map) continue;
      if (_platformOf(item) == 'web') continue;
      final online = item['status'] == 1 || item['status'] == 'online';
      if (chosen == null || online) chosen = item.cast<String, Object?>();
      if (online) break;
    }
    if (chosen == null) return null;
    final user = chosen['user'];
    final name = user is Map ? (user['name'] as String?) ?? (user['nick'] as String?) : null;
    final avatar = user is Map ? user['avatar'] as String? : null;
    return BotProfile(
      platform: _platformOf(chosen) ?? '',
      selfId: (chosen['selfId'] as String?) ?? '',
      name: name ?? 'ChatLuna',
      avatar: (avatar == null || avatar.isEmpty) ? null : avatar,
    );
  }

  static String? _platformOf(Map<dynamic, dynamic> bot) => bot['platform'] as String?;
}
