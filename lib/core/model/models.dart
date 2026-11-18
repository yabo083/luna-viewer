/// 领域模型：与服务端 JSON 解耦。后端字段变化只改本文件的 fromJson。
library;

import 'dart:convert';

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
  ChatMessage({
    required this.id,
    required this.role,
    required this.blocks,
    this.form = '',
  });

  final String id;
  final String role;
  final List<ChatBlock> blocks;

  /// 服务端标记的消息形态：`notice` 是引擎/插件注入的内部消息（wake、turn 装配），不是用户发言。
  final String form;

  bool get isUser => role == 'user';
  bool get isNotice => form == 'notice';

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
      form: (json['form'] as String?) ?? '',
    );
  }

  /// 角色引擎把正文包在 `<message>…</message>` 里；图片是 `<img src="…">`；`<status/>` 是状态栏，不展示。
  /// 输出是 markdown：`<img>` 已转成 `![](url)`，其余标签剥掉（`<br>` 保留）。
  late final String bodyMarkdown = _bodyMarkdown();

  String _bodyMarkdown() {
    var raw = _collectText();
    // 多数回合的答复是通过 `reply` 工具发出的，assistant 自身没有 text 块。
    if (raw.trim().isEmpty) raw = _replyContent();
    if (raw.trim().isEmpty) return '';
    final parts = RegExp(r'<message>([\s\S]*?)</message>').allMatches(raw).map((m) => m.group(1) ?? '').toList();
    var body = parts.isEmpty ? raw : parts.join('\n');
    body = body.replaceAllMapped(
      RegExp(r'''<img[^>]*src\s*=\s*["']([^"']+)["'][^>]*>''', caseSensitive: false),
      (m) => '\n![](${m.group(1)})\n',
    );
    body = body.replaceAll(RegExp(r'<status[\s\S]*?(/>|</status>)'), '');
    body = body.replaceAll(RegExp(r'</(turn|status|message|mood|bond|state)>'), '');
    body = body.replaceAll(RegExp(r'<(?!br\s*/?>)(/?[a-zA-Z][^>]*)>'), '');
    return body.trim();
  }

  /// 模型的思考过程（reasoning 块），UI 折叠展示。
  late final String reasoningText = _reasoningText();

  String _reasoningText() {
    final buffer = StringBuffer();
    for (final block in blocks) {
      if (block.type != 'reasoning') continue;
      final text = block.data['text'];
      if (text is String && text.trim().isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n\n');
        buffer.write(text);
      }
    }
    return buffer.toString().trim();
  }

  /// 一次消息里真正做了事的工具调用（`reply`/`finish` 是发言工具，不算），
  /// 并按 `toolCallId` 关联同一条消息里的 `tool-result`。
  late final List<ToolCallInfo> toolCalls = _toolCalls();

  List<ToolCallInfo> _toolCalls() {
    final outputs = <String, String>{};
    for (final block in blocks) {
      if (block.type != 'tool-result') continue;
      final id = block.data['toolCallId'];
      if (id is String) outputs[id] = _toolOutputText(block.data['output']);
    }
    return [
      for (final block in blocks)
        if (block.type == 'tool-call')
          if (block.data['toolName'] case final String name when name != 'reply' && name != 'finish')
            ToolCallInfo(
              name,
              block.data['input'],
              output: outputs[(block.data['toolCallId'] as String?) ?? ''] ?? '',
            ),
    ];
  }

  static String _toolOutputText(Object? output) {
    if (output == null) return '';
    if (output is String) return output;
    if (output is Map) {
      final value = output['value'];
      if (value is List) {
        final parts = [
          for (final item in value)
            if (item is Map && item['type'] == 'text' && item['text'] is String) item['text'] as String,
        ];
        if (parts.isNotEmpty) return parts.join('\n');
      }
    }
    return ToolCallInfo._pretty(output);
  }

  int get toolCallCount => toolCalls.length;

  /// 正文是否真的含 markdown 语法。纯散文消息直接走 Text，省掉整棵 markdown widget 的构建。
  late final bool hasMarkup = _hasMarkup(bodyMarkdown);

  static bool _hasMarkup(String text) {
    if (text.isEmpty) return false;
    return RegExp(r'(^|\n)\s{0,3}(#{1,6}\s|[-*+]\s|\d+[.)]\s|>\s|\|)'
            r'|```'
            r'|`[^`\n]+`'
            r'|\*\*|__'
            r'|!\['
            r'|\[[^\]]+\]\([^)]+\)')
        .hasMatch(text);
  }

  String _replyContent() {
    for (final block in blocks.reversed) {
      if (block.type != 'tool-call') continue;
      if (block.data['toolName'] != 'reply') continue;
      final input = block.data['input'];
      if (input is Map) {
        final content = input['content'];
        if (content is String && content.trim().isNotEmpty) return content;
      }
    }
    return '';
  }

  String _collectText() {
    final buffer = StringBuffer();
    void walk(List<ChatBlock> list) {
      for (final block in list) {
        if (block.type == 'text') {
          buffer.write(block.text ?? '');
        } else if (block.type == 'envelope') {
          final nested = block.data['content'];
          if (nested is List) {
            walk([
              for (final item in nested)
                if (item is Map) ChatBlock((item['type'] as String?) ?? 'unknown', item.cast<String, Object?>()),
            ]);
          }
        }
      }
    }

    walk(blocks);
    return buffer.toString();
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

class ToolCallInfo {
  const ToolCallInfo(this.name, this.input, {this.output = ''});

  final String name;
  final Object? input;

  /// 对应的 `tool-result.output`，展开时显示；空串表示没有结果块。
  final String output;

  String get prettyInput => _pretty(input);

  static String _pretty(Object? value) {
    if (value == null) return '';
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return value.toString();
    }
  }
}

class CompactResult {
  const CompactResult(this.before, this.after);

  final int before;
  final int after;

  @override
  String toString() => '$before → $after';
}

class ForkResult {
  const ForkResult(this.sessionId, this.length);

  final String sessionId;
  final int length;
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
