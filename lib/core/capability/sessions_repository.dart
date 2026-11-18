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

  /// 实例当前可用的聊天模型，按 provider 分组（`GET /api/models`）。
  Future<Map<String, List<ModelOption>>> models() async {
    final json = await api.getJson('/api/models');
    if (json is! Map) throw ApiFailure('INTERNAL', '模型列表返回体异常');
    final grouped = <String, List<ModelOption>>{};
    for (final item in (json['providers'] as List?) ?? const []) {
      if (item is! Map) continue;
      final provider = item['provider'];
      if (provider is! String || provider.isEmpty) continue;
      final options = <ModelOption>[];
      for (final raw in (item['models'] as List?) ?? const []) {
        final option = ModelOption.fromJson(raw);
        if (option != null) options.add(option);
      }
      grouped[provider] = options;
    }
    return grouped;
  }

  /// 切换会话模型；服务端立即解析成 `provider:model` 并回写会话。
  Future<void> setModel(String id, ModelRef model) =>
      api.postJson('/api/sessions/${Uri.encodeComponent(id)}/model', model.toJson());

  /// 中止当前生成；对任何已加载的会话有效。
  Future<void> cancel(String id) =>
      api.postJson('/api/sessions/${Uri.encodeComponent(id)}/cancel', const {});

  /// 插话：把一条用户消息直接交给 agent（不经过平台适配器）。
  /// 中止后用「重新发送」重开一轮走这里——服务端按下一轮输入处理。
  Future<void> steer(String id, String text) => api.postJson(
    '/api/sessions/${Uri.encodeComponent(id)}/steer',
    {'text': text},
    idempotencyKey: api.newIdempotencyKey(),
  );

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

  /// 会话日志流：`message` 是新落库的消息（含别人发的），mark 是这一轮做了什么（计时用），
  /// `cut` 忽略；`truncated` 表示增量窗口失效，调用方需重取全量。
  /// [since] 是上次最后收到的 `id`，重连时作为 `Last-Event-ID` 续传。
  Stream<SessionEvent> events(String id, {String? since}) async* {
    await for (final sse in api.sse(
      '/api/sessions/${Uri.encodeComponent(id)}/events',
      lastEventId: since,
    )) {
      final event = _sessionEvent(id, sse);
      if (event != null) yield event;
    }
  }

  /// 帧形状（实测）：`{n,time,kind,seq,type}` + 载荷；消息在 `message`，mark 在 `name`/`data`。
  /// 服务端给帧 `id`，没有就用 `sessionId:n` 复现同一种形式，供 `Last-Event-ID` 续传。
  static SessionEvent? _sessionEvent(String sessionId, SseEvent sse) {
    final frame = sse.data;
    final n = frame?['n'];
    final id = sse.id ?? (n is num ? '$sessionId:${n.toInt()}' : null);
    switch (sse.event) {
      case 'truncated':
        return const SessionEvent.truncated();
      case 'message':
        // `message` 是当前形状；`data` 是早期服务端的包装，保留兼容。
        final entry = frame?['message'] ?? frame?['data'];
        if (entry is! Map) return null;
        final message = ChatMessage.fromJson(
          entry.cast<String, Object?>(),
          fallbackId: id,
        );
        if (message.id.isEmpty) return null;
        return SessionEvent.message(message, id);
      default:
        // `kind:"mark"`：帧名就是 mark 名（`prompt` / `engine/activity` / …），`cut` 不是 mark。
        if (frame == null || frame['kind'] != 'mark') return null;
        final name = frame['name'];
        if (name is! String || name.isEmpty) return null;
        final data = frame['data'];
        return SessionEvent.mark(
          name,
          data is Map ? data.cast<String, Object?>() : const <String, Object?>{},
          id: id,
          time: _frameTime(frame['time']),
        );
    }
  }

  static DateTime? _frameTime(Object? raw) =>
      raw is num ? DateTime.fromMillisecondsSinceEpoch(raw.toInt()) : null;
}
