/// 领域模型：与服务端 JSON 解耦。后端字段变化只改本文件的 fromJson。
library;

class ApiFailure implements Exception {
  ApiFailure(this.code, this.message, {this.status, this.details});

  final String code;
  final String message;
  final int? status;
  final Map<String, Object?>? details;

  bool get isUnauthorized => code == 'UNAUTHORIZED' || status == 401;
  bool get isConflict => code == 'CONFLICT' || status == 409;
  bool get isNetwork => code == 'NETWORK';
  bool get isTimeout => code == 'TIMEOUT';

  @override
  String toString() => '$code: $message';
}

class ModelRef {
  const ModelRef(this.provider, this.model);

  final String provider;
  final String model;

  Map<String, Object?> toJson() => {'provider': provider, 'model': model};

  static ModelRef? fromJson(Object? json) {
    if (json is! Map) return null;
    final provider = json['provider'];
    final model = json['model'];
    if (provider is! String || model is! String) return null;
    return ModelRef(provider, model);
  }

  @override
  String toString() => '$provider:$model';
}

class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.origin,
    required this.running,
    required this.engine,
    this.model,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final String origin;
  final bool running;
  final String engine;
  final ModelRef? model;

  bool get writable => origin == 'web';

  factory SessionSummary.fromJson(Map<String, Object?> json) => SessionSummary(
    id: (json['id'] ?? json['sessionId'] ?? '') as String,
    title: (json['title'] as String?) ?? '(未命名)',
    createdAt: DateTime.fromMillisecondsSinceEpoch((json['createdAt'] as num?)?.toInt() ?? 0),
    origin: (json['origin'] as String?) ?? 'web',
    running: (json['running'] as bool?) ?? false,
    engine: (json['engine'] as String?) ?? '',
    model: ModelRef.fromJson(json['model']),
  );
}

class Page<T> {
  const Page(this.items, this.nextCursor);

  final List<T> items;
  final String? nextCursor;
}

class ChatBlock {
  const ChatBlock(this.type, this.data);

  final String type;
  final Map<String, Object?> data;

  String? get text => data['text'] as String?;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.blocks,
  });

  final String id;
  final String role;
  final List<ChatBlock> blocks;

  bool get isUser => role == 'user';

  factory ChatMessage.fromJson(Map<String, Object?> json) {
    final raw = json['content'];
    final blocks = <ChatBlock>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          blocks.add(ChatBlock((item['type'] as String?) ?? 'unknown', item.cast<String, Object?>()));
        }
      }
    } else if (raw is String) {
      blocks.add(ChatBlock('text', {'text': raw}));
    }
    return ChatMessage(
      id: (json['id'] as String?) ?? '',
      role: (json['role'] as String?) ?? 'assistant',
      blocks: blocks,
    );
  }

  /// 角色引擎会把正文包在 `<message>…</message>` 里，后面跟 `<status …/>` 之类的标记。
  /// 展示层只取正文，保留其余块原样跳过。
  String get displayText {
    final buffer = StringBuffer();
    for (final block in blocks) {
      if (block.type != 'text') continue;
      buffer.write(block.text ?? '');
    }
    final raw = buffer.toString();
    final match = RegExp(r'<message>([\s\S]*?)</message>').firstMatch(raw);
    final body = match?.group(1) ?? raw;
    return body.replaceAll(RegExp(r'<status[^>]*/>|<status[\s\S]*?</status>'), '').trim();
  }
}

class Transcript {
  const Transcript(this.messages, this.length, this.cacheBreaks);

  final List<ChatMessage> messages;
  final int length;
  final List<Map<String, Object?>> cacheBreaks;
}

class Health {
  const Health(this.ok, this.name, this.version);

  final bool ok;
  final String name;
  final String version;
}

class EngineOption {
  const EngineOption(this.id, this.label, this.presets);

  final String id;
  final String label;
  final List<PresetOption> presets;

  factory EngineOption.fromJson(Map<String, Object?> json) => EngineOption(
    (json['id'] as String?) ?? '',
    (json['label'] as String?) ?? (json['id'] as String?) ?? '',
    [
      for (final p in (json['presets'] as List?) ?? const [])
        if (p is Map)
          PresetOption((p['id'] as String?) ?? '', (p['name'] as String?) ?? (p['id'] as String?) ?? ''),
    ],
  );
}

class PresetOption {
  const PresetOption(this.id, this.name);

  final String id;
  final String name;
}

class ModelOption {
  const ModelOption(this.provider, this.model, this.name);

  final String provider;
  final String model;
  final String name;

  ModelRef get ref => ModelRef(provider, model);
}

/// `/api/sessions/:id/live` 的流事件。`part` 是 ChatPart 的原始 JSON。
class LiveEvent {
  const LiveEvent.snapshot(this.parts)
    : kind = LiveEventKind.snapshot,
      delta = null,
      toolName = null,
      reason = null;

  const LiveEvent.delta(this.delta, int index)
    : kind = LiveEventKind.delta,
      parts = const [],
      toolName = null,
      reason = null;

  const LiveEvent.tool(this.toolName)
    : kind = LiveEventKind.tool,
      parts = const [],
      delta = null,
      reason = null;

  const LiveEvent.settled(this.reason)
    : kind = LiveEventKind.settled,
      parts = const [],
      delta = null,
      toolName = null;

  const LiveEvent.lagged()
    : kind = LiveEventKind.lagged,
      parts = const [],
      delta = null,
      toolName = null,
      reason = null;

  final LiveEventKind kind;
  final List<Map<String, Object?>> parts;
  final String? delta;
  final String? toolName;
  final String? reason;

  static LiveEvent? fromSse(String event, Map<String, Object?>? data) {
    switch (event) {
      case 'snapshot':
        final attempt = data?['attempt'];
        final parts = <Map<String, Object?>>[];
        if (attempt is Map) {
          final raw = attempt['parts'];
          if (raw is List) {
            for (final p in raw) {
              if (p is Map) parts.add(p.cast<String, Object?>());
            }
          }
        }
        return LiveEvent.snapshot(parts);
      case 'agent/assistant-stream':
        final part = data?['part'];
        if (part is! Map) return null;
        final type = part['type'];
        if (type == 'text') {
          final delta = part['delta'];
          if (delta is String && delta.isNotEmpty) return LiveEvent.delta(delta, 0);
          return null;
        }
        if (type == 'tool-input') {
          final name = part['toolName'];
          return LiveEvent.tool(name is String ? name : 'tool');
        }
        return null;
      case 'agent/assistant-settled':
        final outcome = data?['outcome'];
        final reason = outcome is Map ? outcome['reason'] as String? : null;
        return LiveEvent.settled(reason);
      case 'lagged':
        return const LiveEvent.lagged();
      default:
        return null;
    }
  }
}

enum LiveEventKind { snapshot, delta, tool, settled, lagged }
