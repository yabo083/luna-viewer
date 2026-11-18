/// 能力层：把端点包装成领域动词。UI 不出现路径与字段名。
/// v0.1.0 只做会话管理与查看；发消息/配置编辑留到后续版本。
library;

import '../model/models.dart';
import '../transport/api_client.dart';

class SessionsRepository {
  SessionsRepository(this.api);

  final ApiClient api;

  Future<Page<SessionSummary>> list({String? cursor, int limit = 50}) async {
    final json = await api.getJson('/api/sessions', query: {
      'limit': '$limit',
      'cursor': ?cursor,
    });
    if (json is! Map) throw ApiFailure('INTERNAL', '会话列表返回体异常');
    final items = <SessionSummary>[];
    for (final item in (json['items'] as List?) ?? const []) {
      if (item is Map) items.add(SessionSummary.fromJson(item.cast<String, Object?>()));
    }
    final next = json['nextCursor'];
    return Page(items, next is String ? next : null);
  }

  /// 只对 web 来源会话有效（服务端 renameWebSession 的约束）。
  Future<void> rename(String id, String title) =>
      api.postJson('/api/sessions/${Uri.encodeComponent(id)}/title', {'title': title});

  /// 只对 web 来源会话有效；平台会话返回 404。
  Future<void> delete(String id) =>
      api.deleteJson('/api/sessions/${Uri.encodeComponent(id)}');

  Future<Transcript> transcript(String id) async {
    final json = await api.getJson('/api/sessions/${Uri.encodeComponent(id)}/messages');
    if (json is! Map) throw ApiFailure('INTERNAL', '消息返回体异常');
    final messages = <ChatMessage>[];
    for (final item in (json['messages'] as List?) ?? const []) {
      if (item is Map) messages.add(ChatMessage.fromJson(item.cast<String, Object?>()));
    }
    final breaks = <Map<String, Object?>>[];
    for (final item in (json['cacheBreaks'] as List?) ?? const []) {
      if (item is Map) breaks.add(item.cast<String, Object?>());
    }
    return Transcript(messages, (json['length'] as num?)?.toInt() ?? messages.length, breaks);
  }

  /// 中止当前生成；对任何已加载的会话有效。
  Future<void> cancel(String id) =>
      api.postJson('/api/sessions/${Uri.encodeComponent(id)}/cancel', const {});

  Future<CompactResult?> compact(String id, {int? keep}) async {
    final json = await api.postJson(
      '/api/sessions/${Uri.encodeComponent(id)}/compact',
      {'keep': ?keep},
    );
    if (json is! Map) return null;
    return CompactResult(
      (json['before'] as num?)?.toInt() ?? 0,
      (json['after'] as num?)?.toInt() ?? 0,
    );
  }

  /// 从指定 boundary 分叉出一个新的 web 会话（服务端 createWebSession + fork）。
  Future<ForkResult> fork(String id, {int? boundary}) async {
    final json = await api.postJson(
      '/api/sessions/${Uri.encodeComponent(id)}/fork',
      {'boundary': ?boundary},
      idempotencyKey: api.newIdempotencyKey(),
    );
    if (json is! Map) throw ApiFailure('INTERNAL', '分叉返回体异常');
    return ForkResult(
      (json['sessionId'] as String?) ?? '',
      (json['length'] as num?)?.toInt() ?? 0,
    );
  }

  Stream<LiveEvent> live(String id) async* {
    await for (final sse in api.sse('/api/sessions/${Uri.encodeComponent(id)}/live')) {
      final event = LiveEvent.fromSse(sse.event, sse.data);
      if (event != null) yield event;
    }
  }
}
