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
    return _parsing('会话列表', () {
      final items = <SessionSummary>[];
      for (final item in (json['items'] as List?) ?? const []) {
        if (item is Map) items.add(SessionSummary.fromJson(item.cast<String, Object?>()));
      }
      final next = json['nextCursor'];
      return Page(items, next is String ? next : null);
    });
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
    return _parsing('会话日志', () {
      final messages = <ChatMessage>[];
      for (final item in (json['messages'] as List?) ?? const []) {
        if (item is Map) messages.add(ChatMessage.fromJson(item.cast<String, Object?>()));
      }
      final breaks = <Map<String, Object?>>[];
      for (final item in (json['cacheBreaks'] as List?) ?? const []) {
        if (item is Map) breaks.add(item.cast<String, Object?>());
      }
      return Transcript(messages, (json['length'] as num?)?.toInt() ?? messages.length, breaks);
    });
  }

  /// 把解析期的 `TypeError`/`FormatException` 收敛成 `ApiFailure`：
  /// 页面只认识 ApiFailure，坏字段才不会以未捕获异常逃进 Zone / 轮询循环。
  /// 文案固定，不回显服务端正文（可能含 HTML / 敏感内容）。
  static T _parsing<T>(String what, T Function() parse) {
    try {
      return parse();
    } on ApiFailure {
      rethrow;
    } catch (_) {
      throw ApiFailure('INTERNAL', '$what返回体字段异常');
    }
  }

  /// 实例当前可用的聊天模型，按 provider 分组（`GET /api/models`）。
  Future<Map<String, List<ModelOption>>> models() async {
    final json = await api.getJson('/api/models');
    if (json is! Map) throw ApiFailure('INTERNAL', '模型列表返回体异常');
    return _parsing('模型列表', () {
      final grouped = <String, List<ModelOption>>{};
      final providers = json['providers'];
      if (providers is! List) return grouped;
      for (final item in providers) {
        if (item is! Map) continue;
        final provider = item['provider'];
        if (provider is! String || provider.isEmpty) continue;
        final rawModels = item['models'];
        final options = <ModelOption>[
          if (rawModels is List)
            for (final raw in rawModels) ?ModelOption.fromJson(raw),
        ];
        grouped[provider] = options;
      }
      return grouped;
    });
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
      // 单帧坏形状只丢这一帧：一条解析缺口不能把整条事件流（计时）打断。
      final SessionEvent? event;
      try {
        event = _sessionEvent(id, sse);
      } catch (_) {
        continue;
      }
      if (event != null) yield event;
    }
  }

  /// 帧形状（实测）：`{n,time,kind,seq,type}` + 载荷；消息在 `message`，mark 在 `name`/`data`。
  /// 帧自带 `n` 时优先用它生成 `sessionId:n`：服务端漏写 `id` 时 SSE 规范会沿用上一帧的
  /// `id`，直接拿它去重会把下一帧当成重复吞掉。`sse.id` 只在没有 `n` 时兜底。
  static SessionEvent? _sessionEvent(String sessionId, SseEvent sse) {
    final frame = sse.data;
    final n = frame?['n'];
    final seq = n is num ? n.toInt() : (n is String ? int.tryParse(n.trim()) : null);
    final id = seq != null ? '$sessionId:$seq' : sse.id;
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
        // `kind:"cut"`：历史被压缩的边界。它不是 mark，但带 `n`，
        // 必须让续传游标前进——否则重连会从旧位置重放，把上一轮的 mark 当成新轮。
        if (frame != null && frame['kind'] == 'cut' && id != null) {
          return SessionEvent.mark(
            'cut',
            const <String, Object?>{},
            id: id,
            time: _frameTime(frame['time']),
          );
        }
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

  /// mark 的 `time` 可能是数字毫秒、数字字符串或 ISO 串（旧数据/发版差异）。
  /// 解析不出来时返回 null：调用方会把它当成「没有时间」的帧，而不是用上一轮的起点。
  static DateTime? _frameTime(Object? raw) {
    if (raw is num) return DateTime.fromMillisecondsSinceEpoch(raw.toInt()).toLocal();
    if (raw is! String) return null;
    final text = raw.trim();
    if (text.isEmpty) return null;
    final epoch = int.tryParse(text);
    if (epoch != null) {
      final ms = epoch < 100000000000 ? epoch * 1000 : epoch;
      return DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    }
    return DateTime.tryParse(text)?.toLocal();
  }
}
