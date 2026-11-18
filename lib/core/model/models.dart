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

/// `/api/models` 里某个 provider 下的一个可选模型。
class ModelOption {
  const ModelOption(this.id, {this.name});

  final String id;
  final String? name;

  /// 展示名：有 `name` 用 `name`，否则退回模型 id。
  String get label {
    final trimmed = name?.trim();
    return trimmed == null || trimmed.isEmpty ? id : trimmed;
  }

  static ModelOption? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final name = json['name'];
    return ModelOption(id, name: name is String ? name : null);
  }
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
    this.isFramework = false,
  });

  final String id;
  final String role;
  final List<ChatBlock> blocks;

  /// 服务端标记的消息形态：`notice` 是引擎/插件注入的内部消息（wake、turn 装配），不是用户发言。
  final String form;

  /// 框架消息：`form` 不是 `message`（如 `notice`），或来源是插件（`source.kind == 'plugin'`）。
  /// 这类消息不属于对话双方，渲染成居中的弱化块。
  final bool isFramework;

  bool get isUser => role == 'user';

  factory ChatMessage.fromJson(Map<String, Object?> json, {String? fallbackId}) {
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
    final form = (json['form'] as String?) ?? '';
    final source = json['source'];
    final sourceKind = source is Map ? source['kind'] : null;
    final rawId = json['id'];
    return ChatMessage(
      id: rawId is String && rawId.isNotEmpty ? rawId : (fallbackId ?? ''),
      role: (json['role'] as String?) ?? 'assistant',
      blocks: blocks,
      form: form,
      isFramework: (form.isNotEmpty && form != 'message') || sourceKind == 'plugin',
    );
  }

  /// 角色引擎把正文包在 `<message>…</message>` 里；图片是 `<img src="…">`；`<status/>` 是状态栏，不展示。
  /// 输出是 markdown：`<img>` 已转成 `![](url)`，其余标签剥掉（`<br>` 保留）。
  late final String bodyMarkdown = _bodyMarkdown();

  String _bodyMarkdown() {
    var raw = _collectMarkdown();
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

  /// 图片块（satori `img`/`image`、平台归一化后的 `file`）按出现顺序转成 `![](src)`；
  /// `face`/`at`/`quote` 给可读占位。`src` 支持 `http(s)`、`data:`、`base64://` 与工作区相对路径。
  String _collectMarkdown() {
    final buffer = StringBuffer();

    void appendImage(String raw, {String? mediaType}) {
      final src = _normalizeImageSrc(raw, mediaType: mediaType);
      if (src.isEmpty) return;
      buffer.write('\n![]($src)\n');
    }

    void walk(List<ChatBlock> list) {
      for (final block in list) {
        if (block.type == 'text') {
          final text = block.text ?? _attrText(block.data);
          if (text != null) buffer.write(text);
        } else if (block.type == 'envelope') {
          final nested = block.data['content'];
          if (nested is String) {
            buffer.write(nested);
          } else if (nested is List) {
            walk(_blocksOf(nested));
          }
        } else if (block.type == 'img' ||
            block.type == 'image' ||
            block.type == 'mface' ||
            block.type == 'sticker') {
          final src = _stringAttr(block.data, 'src') ?? _stringAttr(block.data, 'url');
          if (src != null) appendImage(src, mediaType: _stringAttr(block.data, 'type'));
        } else if (block.type == 'file') {
          final mediaType = block.data['mediaType'];
          if (mediaType is! String || !mediaType.startsWith('image/')) continue;
          final src = _fileImageSrc(block.data, mediaType);
          if (src != null) appendImage(src, mediaType: mediaType);
        } else if (block.type == 'face' || block.type == 'emoji') {
          buffer.write('[表情]');
        } else if (block.type == 'at') {
          final name = _stringAttr(block.data, 'name') ?? _stringAttr(block.data, 'id');
          if (name != null) buffer.write('@$name ');
        } else if (block.type == 'quote') {
          buffer.write('[引用]');
        }
      }
    }

    walk(blocks);
    return buffer.toString();
  }

  static List<ChatBlock> _blocksOf(List<dynamic> raw) => [
    for (final item in raw)
      if (item is Map) ChatBlock((item['type'] as String?) ?? 'unknown', item.cast<String, Object?>()),
  ];

  /// 文本块的标准字段是 `text`；satori 元素的文本在 `attrs.content`。
  static String? _attrText(Map<String, Object?> data) {
    final attrs = data['attrs'];
    if (attrs is Map) {
      final content = attrs['content'];
      if (content is String) return content;
    }
    final content = data['content'];
    return content is String ? content : null;
  }

  /// 先看 satori 的 `attrs`，再看块自身的同名字段。
  static String? _stringAttr(Map<String, Object?> data, String key) {
    final attrs = data['attrs'];
    if (attrs is Map) {
      final value = attrs[key];
      if (value is String && value.isNotEmpty) return value;
    }
    final value = data[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  /// 平台图片在日志里是 `file` 块：`{mediaType, data:{type:'url'|'data'|'reference'}}`。
  static String? _fileImageSrc(Map<String, Object?> data, String mediaType) {
    final file = data['data'];
    if (file is! Map) return _stringAttr(data, 'url');
    final kind = file['type'];
    if (kind == 'url') {
      final url = file['url'];
      return url is String && url.isNotEmpty ? url : null;
    }
    if (kind == 'data') {
      final payload = file['data'];
      if (payload is! String || payload.isEmpty) return null;
      return payload.startsWith('data:') ? payload : 'data:$mediaType;base64,$payload';
    }
    if (kind == 'reference') {
      final reference = file['reference'];
      if (reference is! String || reference.isEmpty) return null;
      final name = reference.startsWith('storage://')
          ? reference.substring('storage://'.length)
          : reference;
      return '/files/${Uri.encodeComponent(name)}';
    }
    return null;
  }

  /// `base64://<payload>` 没有 mime，用元素声明的类型兜底为 `data:` URI。
  static String _normalizeImageSrc(String raw, {String? mediaType}) {
    final src = raw.trim();
    final marker = RegExp(r'^base64:(?://)?').firstMatch(src);
    if (marker == null) return src;
    final payload = src.substring(marker.end);
    final mime = mediaType != null && mediaType.startsWith('image/') ? mediaType : 'image/png';
    return 'data:$mime;base64,$payload';
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
  /// `active` 表示快照来自进行中的 attempt；为 false 时服务端没有在跑的生成。
  const LiveEvent.snapshot(this.parts, {this.active = false})
    : kind = LiveEventKind.snapshot,
      delta = null,
      toolName = null,
      reason = null;

  const LiveEvent.delta(this.delta, int index)
    : kind = LiveEventKind.delta,
      parts = const [],
      toolName = null,
      reason = null,
      active = true;

  const LiveEvent.tool(this.toolName)
    : kind = LiveEventKind.tool,
      parts = const [],
      delta = null,
      reason = null,
      active = true;

  const LiveEvent.settled(this.reason)
    : kind = LiveEventKind.settled,
      parts = const [],
      delta = null,
      toolName = null,
      active = false;

  const LiveEvent.lagged()
    : kind = LiveEventKind.lagged,
      parts = const [],
      delta = null,
      toolName = null,
      reason = null,
      active = false;

  final LiveEventKind kind;
  final List<Map<String, Object?>> parts;
  final String? delta;
  final String? toolName;
  final String? reason;

  /// 该事件是否代表「有生成在进行中」：snapshot 看有没有 attempt，delta/tool 恒为真。
  final bool active;

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
        return LiveEvent.snapshot(parts, active: attempt is Map);
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

/// `/api/sessions/:id/events` 的一个增量帧：落库的新消息，或增量窗口失效。
class SessionEvent {
  const SessionEvent.message(this.message, this.id) : truncated = false;

  const SessionEvent.truncated()
    : message = null,
      id = null,
      truncated = true;

  /// 新落库的消息；`truncated` 时为空。
  final ChatMessage? message;

  /// SSE 帧的 `id`（形如 `<sessionId>:<n>`），重连时作为 `Last-Event-ID` 续传。
  final String? id;

  /// 服务端的增量窗口已失效：本地增量不可信，调用方应重取 `/messages`。
  final bool truncated;
}
