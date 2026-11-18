/// 能力层：把端点包装成领域动词。UI 不出现路径与字段名。
library;

import 'dart:convert';

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

  Future<SessionSummary> create({
    String? title,
    String? presetId,
    String? engine,
    ModelRef? model,
  }) async {
    final json = await api.postJson(
      '/api/sessions',
      {
        if (title != null && title.isNotEmpty) 'title': title,
        if (presetId != null && presetId.isNotEmpty) 'presetId': presetId,
        if (engine != null && engine.isNotEmpty) 'engine': engine,
        if (model != null) 'model': model.toJson(),
      },
      idempotencyKey: api.newIdempotencyKey(),
    );
    if (json is! Map) throw ApiFailure('INTERNAL', '新建会话返回体异常');
    final map = json.cast<String, Object?>();
    return SessionSummary(
      id: (map['id'] as String?) ?? '',
      title: (map['title'] as String?) ?? '(未命名)',
      createdAt: DateTime.fromMillisecondsSinceEpoch((map['createdAt'] as num?)?.toInt() ?? 0),
      origin: 'web',
      running: false,
      engine: engine ?? '',
      model: model,
    );
  }

  Future<void> rename(String id, String title) =>
      api.postJson('/api/sessions/${Uri.encodeComponent(id)}/title', {'title': title});

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

  /// 202 已受理：正文通过 live 流到达，这里不等结果。
  Future<void> send(String id, String text) async {
    await api.postJson(
      '/api/sessions/${Uri.encodeComponent(id)}/messages',
      {'text': text},
      idempotencyKey: api.newIdempotencyKey(),
    );
  }

  Future<void> steer(String id, String text) =>
      api.postJson('/api/sessions/${Uri.encodeComponent(id)}/steer', {'text': text});

  Future<void> cancel(String id) =>
      api.postJson('/api/sessions/${Uri.encodeComponent(id)}/cancel', const {});

  Future<String?> compact(String id, {int? keep}) async {
    final json = await api.postJson(
      '/api/sessions/${Uri.encodeComponent(id)}/compact',
      {'keep': ?keep},
    );
    if (json is! Map) return null;
    final before = json['before'];
    final after = json['after'];
    return '$before → $after';
  }

  Future<void> setModel(String id, ModelRef model) => api.postJson(
    '/api/sessions/${Uri.encodeComponent(id)}/model',
    model.toJson(),
  );

  Stream<LiveEvent> live(String id) async* {
    await for (final sse in api.sse('/api/sessions/${Uri.encodeComponent(id)}/live')) {
      final event = LiveEvent.fromSse(sse.event, sse.data);
      if (event != null) yield event;
    }
  }

  Future<List<EngineOption>> engines() async {
    final json = await api.getJson('/api/engines');
    final items = json is Map ? json['items'] : json;
    final result = <EngineOption>[];
    if (items is List) {
      for (final item in items) {
        if (item is Map) result.add(EngineOption.fromJson(item.cast<String, Object?>()));
      }
    }
    return result;
  }

  Future<List<ModelOption>> models() async {
    final json = await api.getJson('/api/models');
    final providers = json is Map ? json['providers'] : null;
    final result = <ModelOption>[];
    if (providers is List) {
      for (final provider in providers) {
        if (provider is! Map) continue;
        final name = provider['provider'];
        if (name is! String) continue;
        for (final model in (provider['models'] as List?) ?? const []) {
          if (model is! Map) continue;
          final id = model['id'];
          if (id is! String) continue;
          result.add(ModelOption(name, id, (model['name'] as String?) ?? id));
        }
      }
    }
    return result;
  }
}

String prettyJson(Object? value) => const JsonEncoder.withIndent('  ').convert(value);
