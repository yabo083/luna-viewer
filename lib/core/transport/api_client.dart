/// 传输层：唯一知道协议细节的地方。
/// - 统一 Bearer、幂等键、超时、错误码映射
/// - SSE 解析（event/id/data，忽略 `: ping` 注释）
/// - 不自动登录、不重试 GET
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../model/models.dart';

class SseEvent {
  const SseEvent(this.event, this.data, this.id);

  final String event;
  final Map<String, Object?>? data;
  final String? id;
}

class ApiClient {
  ApiClient({required this.base, this.token, http.Client? client})
    : _client = client ?? http.Client();

  final Uri base;
  final String? token;
  final http.Client _client;
  final _random = Random.secure();

  static const _timeout = Duration(seconds: 15);

  /// SSE 空闲判死：20s 内没有任何一行（含 `: ping` 心跳）就认为链路半死。
  /// 取 20s 而不是 15s：契约允许首帧 20s，统一用一个更长一档的阈值既能容纳首帧，
  /// 也远大于服务端 15s 心跳。交给 `Stream.timeout` 抛 ApiFailure，上层既有退避负责重连。
  static const _sseIdle = Duration(seconds: 20);

  /// 错误响应体读取上限时间：反代把 502 错误页分块发出后不收尾时，
  /// 不能让 `sse()` 永久挂在 `bytesToString()` 上（连重连都排不上）。
  static const _errorBodyTimeout = Duration(milliseconds: 1500);

  /// 单帧上限：坏服务端/半截帧不能把 100MB 一次塞进内存再 JSON 解码。
  static const _maxFrameBytes = 4 * 1024 * 1024;

  Map<String, String> get _headers => {
    'accept': 'application/json',
    if (token != null && token!.isNotEmpty) 'authorization': 'Bearer $token',
  };

  /// 供 `Image.network` 之类需要直连资源的组件复用（工作区图片走 Bearer）。
  Map<String, String> get authHeaders => {..._headers};

  Uri _uri(String path, [Map<String, String>? query]) {
    final p = path.startsWith('/') ? path.substring(1) : path;
    final uri = base.resolve(p);
    return query == null || query.isEmpty ? uri : uri.replace(queryParameters: {...uri.queryParameters, ...query});
  }

  String newIdempotencyKey() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// 公开端点（/api/health）：不进缓存、不带凭证。
  static Future<Health> health(Uri base, {Duration timeout = const Duration(seconds: 4)}) async {
    final client = http.Client();
    try {
      final res = await client.get(base.resolve('api/health')).timeout(timeout);
      if (res.statusCode != 200) {
        throw ApiFailure('NETWORK', 'health ${res.statusCode}', status: res.statusCode);
      }
      final json = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
      if (json is! Map) throw ApiFailure('NETWORK', 'unexpected health payload');
      return Health(
        json['ok'] == true,
        (json['name'] as String?) ?? '',
        (json['version'] as String?) ?? '',
      );
    } on ApiFailure {
      rethrow;
    } on TimeoutException {
      throw ApiFailure('TIMEOUT', '连接超时');
    } on SocketException catch (e) {
      throw ApiFailure('NETWORK', e.message);
    } on FormatException catch (e) {
      throw ApiFailure('NETWORK', '地址无效：${e.message}');
    } on http.ClientException catch (e) {
      throw ApiFailure('NETWORK', e.message);
    } finally {
      client.close();
    }
  }

  Future<Object?> getJson(String path, {Map<String, String>? query}) =>
      _send(() => _client.get(_uri(path, query), headers: _headers));

  Future<Object?> postJson(String path, Object? body, {String? idempotencyKey}) => _send(
    () => _client.post(
      _uri(path),
      headers: {
        ..._headers,
        'content-type': 'application/json',
        'idempotency-key': ?idempotencyKey,
      },
      body: jsonEncode(body ?? const <String, Object?>{}),
    ),
  );

  Future<Object?> deleteJson(String path) =>
      _send(() => _client.delete(_uri(path), headers: _headers));

  Future<Object?> action(String name, Object? input) => _send(
    () => _client.post(
      _uri('/api/action/${Uri.encodeComponent(name)}'),
      headers: {
        ..._headers,
        'content-type': 'application/json',
        'idempotency-key': newIdempotencyKey(),
      },
      body: jsonEncode(input ?? const <String, Object?>{}),
    ),
  );

  /// [includeComments] 为真时把服务端心跳（`: ping` 注释行）也作为
  /// `event: comment` 的帧发出来：需要感知「连接还活着」的调用方（如旁路流量流）
  /// 靠它判断链路健康，默认丢弃，`/live`、`/events` 不受影响。
  Stream<SseEvent> sse(
    String path, {
    Map<String, String>? query,
    String? lastEventId,
    bool includeComments = false,
  }) async* {
    final request = http.Request('GET', _uri(path, query))
      ..headers.addAll({
        ..._headers,
        'accept': 'text/event-stream',
        'last-event-id': ?lastEventId,
      });
    final response = await _client.send(request).timeout(const Duration(seconds: 20));
    if (response.statusCode >= 400) {
      // 401/403 不必等 body：凭证失效要立刻收敛，body 卡住会把 UNAUTHORIZED
      // 拖成 TIMEOUT，页面就会当成网络抖动继续重试。
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw _failureOf(response.statusCode, '');
      }
      // 错误页的 body 也可能半死：超时按网络错误处理，让上层退避重连。
      final String text;
      try {
        final bytes = await response.stream
            .toBytes()
            .timeout(_errorBodyTimeout);
        text = utf8.decode(bytes, allowMalformed: true);
      } on TimeoutException {
        throw ApiFailure(
          'TIMEOUT',
          '读取错误响应超时（HTTP ${response.statusCode}）',
          status: response.statusCode,
        );
      }
      throw _failureOf(response.statusCode, text);
    }
    String? event;
    String? id;
    final data = StringBuffer();
    // 任何一行都重置空闲计时（注释心跳也算）：15s 一行都没有才算链路死了。
    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(
          _sseIdle,
          onTimeout: (sink) {
            sink.addError(ApiFailure('TIMEOUT', 'SSE 空闲超时'));
            sink.close();
          },
        );
    await for (final line in lines) {
      if (line.isEmpty) {
        final payload = data.toString();
        if (payload.isNotEmpty) {
          Object? decoded;
          try {
            decoded = jsonDecode(payload);
          } catch (_) {
            decoded = null;
          }
          yield SseEvent(
            event ?? 'message',
            decoded is Map ? decoded.cast<String, Object?>() : null,
            id,
          );
        }
        event = null;
        data.clear();
        continue;
      }
      if (line.startsWith(':')) {
        // 注释行就是心跳（`: ping`）：默认丢掉，需要探活的调用方收下这一帧。
        if (includeComments) yield const SseEvent('comment', null, null);
        continue;
      }
      final colon = line.indexOf(':');
      final field = colon == -1 ? line : line.substring(0, colon);
      var value = colon == -1 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'event':
          event = value;
        case 'id':
          id = value;
        case 'data':
          if (data.isNotEmpty) data.write('\n');
          if (data.length + value.length > _maxFrameBytes) {
            throw ApiFailure('INTERNAL', 'SSE 帧过大');
          }
          data.write(value);
      }
    }
  }

  Future<Object?> _send(Future<http.Response> Function() run) async {
    try {
      final res = await run().timeout(_timeout);
      // 固定按 UTF-8 解码：`http.Response.body` 在缺 charset 时会退回 latin1，
      // 中文标题/正文会变成乱码（反代与原服务端都可能不给 charset）。
      final text = utf8.decode(res.bodyBytes, allowMalformed: true);
      if (res.statusCode >= 400) throw _failureOf(res.statusCode, text);
      if (res.statusCode == 204 || text.isEmpty) return null;
      return jsonDecode(text);
    } on ApiFailure {
      rethrow;
    } on TimeoutException {
      throw ApiFailure('TIMEOUT', '请求超时');
    } on SocketException catch (e) {
      throw ApiFailure('NETWORK', e.message);
    } on http.ClientException catch (e) {
      throw ApiFailure('NETWORK', e.message);
    } on FormatException catch (e) {
      throw ApiFailure('INTERNAL', '返回体不是合法 JSON: ${e.message}');
    } catch (e) {
      throw ApiFailure('INTERNAL', e.toString());
    }
  }

  ApiFailure _failureOf(int status, String body) {
    Object? decoded;
    try {
      decoded = body.isEmpty ? null : jsonDecode(body);
    } catch (_) {
      decoded = null;
    }
    if (decoded is Map) {
      final code = decoded['code'];
      final message = decoded['message'];
      return ApiFailure(
        code is String ? code : _codeOf(status),
        message is String ? message : body,
        status: status,
        details: decoded['details'] is Map ? (decoded['details'] as Map).cast<String, Object?>() : null,
      );
    }
    return ApiFailure(_codeOf(status), body.isEmpty ? 'HTTP $status' : body, status: status);
  }

  String _codeOf(int status) => switch (status) {
    400 => 'INVALID_ARGUMENT',
    401 => 'UNAUTHORIZED',
    403 => 'FORBIDDEN',
    404 => 'NOT_FOUND',
    409 => 'CONFLICT',
    429 => 'RATE_LIMITED',
    >= 500 => 'INTERNAL',
    _ => 'UNKNOWN',
  };

  void close() => _client.close();
}
