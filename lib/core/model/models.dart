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

  factory SessionSummary.fromJson(Map<String, Object?> json) {
    final rawId = json['id'] ?? json['sessionId'];
    final title = json['title'];
    final origin = json['origin'];
    final engine = json['engine'];
    return SessionSummary(
      // 展示/身份字段做类型容错；`createdAt`/`running` 是排序与状态的关键事实，
      // 漂移时由仓储层收敛成 ApiFailure，不能让错误类型静默变成「1970 / 未运行」。
      id: rawId is String ? rawId : '',
      title: title is String && title.isNotEmpty ? title : '(未命名)',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num?)?.toInt() ?? 0,
      ),
      origin: origin is String && origin.isNotEmpty ? origin : 'web',
      running: (json['running'] as bool?) ?? false,
      engine: engine is String ? engine : '',
      model: ModelRef.fromJson(json['model']),
    );
  }
}

class Page<T> {
  const Page(this.items, this.nextCursor);

  final List<T> items;
  final String? nextCursor;
}

/// `/api/platform/conversations` 的一项：伴侣插件维护的平台会话真源。
/// App 的列表与详情都只读它；`SessionSummary` 只在会话被 ChatLuna 加载后补充状态与操作。
class PlatformConversation {
  const PlatformConversation({
    required this.key,
    required this.platform,
    required this.selfId,
    required this.channelId,
    required this.guildId,
    required this.kind,
    required this.title,
    required this.count,
    required this.last,
    this.avatar,
  });

  /// 插件侧会话键：已加载会话的 id 归一化后与它相等（见 `normalizeConversationKey`）。
  final String key;
  final String platform;
  final String selfId;
  final String channelId;
  final String? guildId;

  /// 会话头像（群头像 / 对方头像）；缺失时列表退回会话名首字或形态图标，**不回退 bot 头像**。
  final String? avatar;

  /// 插件判定的会话形态（`group` / `private`），原样透传，只用于展示。
  final String kind;

  /// 插件给的展示名；为空时调用方退回 [key]。
  final String title;

  /// 插件统计的消息条数。
  final int count;

  /// 最后一条消息：还没有落消息的会话为 null。
  final PlatformMessage? last;

  /// 实时帧到达时只改这两项：插件是唯一知道新消息计数的地方，App 只在最后一页上推进。
  PlatformConversation copyWith({int? count, PlatformMessage? last}) => PlatformConversation(
    key: key,
    platform: platform,
    selfId: selfId,
    channelId: channelId,
    guildId: guildId,
    kind: kind,
    title: title,
    count: count ?? this.count,
    last: last ?? this.last,
    avatar: avatar,
  );

  static PlatformConversation? fromJson(Object? json) {
    if (json is! Map) return null;
    final key = _platformText(json['key']).trim();
    if (key.isEmpty) return null;
    return PlatformConversation(
      key: key,
      platform: _platformText(json['platform']),
      selfId: _platformText(json['selfId']),
      channelId: _platformText(json['channelId']),
      guildId: json['guildId'] == null ? null : _platformText(json['guildId']),
      kind: _platformText(json['kind']),
      title: _platformText(json['title']).trim(),
      count: (json['count'] as num?)?.toInt() ?? 0,
      last: PlatformMessage.fromJson(json['last']),
      avatar: _optionalText(json['avatar']),
    );
  }
}

/// 一条平台消息里的一个媒体附件：插件 `media` 数组的一项。
/// 四个字段都可缺省，UI 按「有没有 url / ref」决定画图片、胶囊还是占位 chip。
class PlatformMedia {
  const PlatformMedia({required this.kind, this.url, this.name, this.ref});

  /// `image` / `video` / `audio` / `file`：插件声明值已归一，未知值按 `file` 处理。
  final String kind;

  /// 可取用的地址：`http(s)://`、`data:`、`base64://` 或实例/工作区的相对路径；null 表示只有 [ref]。
  final String? url;

  /// 展示名：插件给的文件名/标题。
  final String? name;

  /// 只有引用没有地址时的本地标识（插件侧文件、`storage://` 引用等），UI 只能展示与复制。
  final String? ref;

  bool get isImage => kind == 'image';

  /// 展示名回退链：`name` → URL/引用末段 → 类型中文名。
  String get label {
    final given = name?.trim();
    if (given != null && given.isNotEmpty) return given;
    final tail = _tailOf(url ?? ref ?? '');
    return tail.isNotEmpty ? tail : kindLabel(kind);
  }

  /// 类型中文名：胶囊在拿不到文件名时用它。
  static String kindLabel(String kind) => switch (kind) {
    'image' => '图片',
    'video' => '视频',
    'audio' => '语音',
    'file' => '文件',
    _ => '附件',
  };

  static PlatformMedia? fromJson(Object? json) {
    if (json is! Map) return null;
    final url = _optionalText(json['url'] ?? json['src'] ?? json['href']);
    final ref = _optionalText(json['ref'] ?? json['reference']);
    final name = _optionalText(json['name'] ?? json['filename'] ?? json['fileName'] ?? json['title']);
    // 三样都没有的项没有可渲染的东西（半截帧/占位对象），直接丢。
    if (url == null && ref == null && name == null) return null;
    return PlatformMedia(
      kind: _kindOf(json['kind'] ?? json['type'] ?? json['mediaType'], url),
      url: url,
      name: name,
      ref: ref,
    );
  }

  /// 容错：`media` 缺失、为 null、不是数组、项不是对象时都当空列表。
  static List<PlatformMedia> listFrom(Object? raw) => [
    if (raw is List) for (final item in raw) ?fromJson(item),
  ];

  /// 类型归一：插件声明优先，缺失或无法识别时从地址猜（`data:image/`、视频扩展名）。
  static String _kindOf(Object? raw, String? url) {
    final text = _platformText(raw).trim().toLowerCase();
    if (text.startsWith('image/')) return 'image';
    if (text.startsWith('video/')) return 'video';
    if (text.startsWith('audio/')) return 'audio';
    switch (text) {
      case 'image' || 'img' || 'photo' || 'picture' || 'sticker':
        return 'image';
      case 'video':
        return 'video';
      case 'audio' || 'voice':
        return 'audio';
      case 'file' || 'document' || 'attachment':
        return 'file';
    }
    final src = url ?? '';
    if (src.startsWith('data:image/') || src.startsWith('base64:')) return 'image';
    if (src.startsWith('data:video/') ||
        RegExp(r'\.(mp4|mov|webm|m4v)(\?|$)', caseSensitive: false).hasMatch(src)) {
      return 'video';
    }
    if (src.startsWith('data:audio/') ||
        RegExp(r'\.(mp3|wav|ogg|m4a|silk|amr)(\?|$)', caseSensitive: false).hasMatch(src)) {
      return 'audio';
    }
    return 'file';
  }

  /// URL/引用末段当文件名：`data:` / `base64://` 的载荷没有名字，返回空串。
  static String _tailOf(String link) {
    if (link.isEmpty || link.startsWith('data:') || link.startsWith('base64:')) return '';
    final path = link.split('?').first.split('#').first;
    final tail = path.substring(path.lastIndexOf('/') + 1);
    try {
      return Uri.decodeComponent(tail).trim();
    } on ArgumentError {
      return tail.trim();
    }
  }
}

/// 一条平台消息：`/api/platform/messages` 的一项，也是 `platform/stream` 帧里的 `message`。
class PlatformMessage {
  PlatformMessage({
    required this.id,
    required this.time,
    required this.outbound,
    required this.userId,
    required this.content,
    this.userName,
    this.avatar,
    this.media = const <PlatformMedia>[],
  });

  final String id;
  final DateTime time;

  /// `dir == 'out'`：机器人自己发出的回复；否则是收到的消息。
  final bool outbound;
  final String userId;
  final String content;

  /// 发送者展示名（插件后续提供）；缺失时气泡只显示头像与正文。
  final String? userName;

  /// 发送者头像（插件后续提供）；缺失时用首字母圆头像。
  final String? avatar;

  /// 媒体附件（图片/视频/音频/文件）：与 [content] 分开渲染，**不**混进正文。
  /// 插件没给这项时是空列表，正文照旧。
  final List<PlatformMedia> media;

  /// 这一轮回复的起止（**本地推算**，只有本页观测到的那条 out 气泡会写）：
  /// 气泡脚注显示 `HH:mm · 1m04s`。服务端没有这两个字段，重开页面就不再有脚注——
  /// 它是本机看到的时间，不是服务端事实，所以也不参与去重与排序。
  DateTime? turnStartedAt;
  DateTime? turnEndedAt;

  /// 渲染模型：`out` 与 `in` 都用它，详情页按 `outbound` 决定左右与配色。
  /// 平台消息逐条都是发言，没有框架/指令形态，因此关掉指令启发式。
  late final ChatMessage view = ChatMessage(
    id: id,
    role: outbound ? 'assistant' : 'user',
    blocks: [ChatBlock('text', {'text': content})],
    form: 'message',
    detectCommands: false,
  );

  /// 逐条比较用的正文：多行折成一行，供列表副标题与去重日志使用。
  /// 没有正文但有媒体时用媒体类型拼一句（`[图片] [文件]`），列表行才不至于只剩时间。
  String get preview {
    final body = content.replaceAll(_platformSpaces, ' ').trim();
    if (body.isNotEmpty) return body;
    if (media.isEmpty) return '';
    return media.map((item) => '[${PlatformMedia.kindLabel(item.kind)}]').toSet().join(' ');
  }

  static PlatformMessage? fromJson(Object? json) {
    if (json is! Map) return null;
    final time = _platformTime(json['time']);
    final content = _platformText(json['content'] ?? json['text']);
    final rawId = _platformText(json['id']).trim();
    return PlatformMessage(
      // 缺 id 的旧数据（或半截帧）退回「时间 + 正文」，保证同一帧不会被画两遍。
      id: rawId.isNotEmpty ? rawId : '${time.millisecondsSinceEpoch}\u0000$content',
      time: time,
      outbound: _platformText(json['dir']) == 'out',
      userId: _platformText(json['userId']),
      content: content,
      userName: _optionalText(json['userName'] ?? json['user'] ?? json['nick']),
      avatar: _optionalText(json['avatar']),
      media: PlatformMedia.listFrom(json['media']),
    );
  }
}

/// `GET /api/platform/messages` 的一页：`items` 时间升序，`hasMore` 表示更早还有。
class PlatformMessagePage {
  const PlatformMessagePage(this.items, this.hasMore);

  final List<PlatformMessage> items;
  final bool hasMore;
}

final RegExp _platformSpaces = RegExp(r'\s+');

String _platformText(Object? value) => value is String ? value : '';

/// 可选展示字段：缺失/空串统一成 null，UI 才能用「有没有值」决定降级。
String? _optionalText(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 实例返回的资源地址归一：`/files/x.png`、`files/x.png`、`//host/x` 补成绝对地址；
/// `http(s)://`、`data:`、`base64:` 原样返回；空串返回 null。
/// bot / 会话头像都可能给相对路径，`Image.network` 只吃绝对地址，取不到就交给占位。
String? absoluteResourceUrl(Uri? base, String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return null;
  if (value.startsWith('data:') || value.startsWith('base64:')) return value;
  if (value.startsWith('//')) return base == null ? null : '${base.scheme}:$value';
  final uri = Uri.tryParse(value);
  if (uri == null) return null;
  if (uri.hasScheme) return value;
  return base?.resolveUri(uri).toString() ?? value;
}

/// 平台时间戳：毫秒（13 位）/ 秒（10 位）数字或 ISO 串都接受。
/// 统一转本地时区：服务端给 `...Z` 时，展示层直接读 `hour/minute` 才不会偏一个时区。
DateTime _platformTime(Object? raw) {
  if (raw is num) {
    final value = raw.toInt();
    return DateTime.fromMillisecondsSinceEpoch(
      value < 100000000000 ? value * 1000 : value,
    ).toLocal();
  }
  final text = raw?.toString().trim() ?? '';
  if (text.isEmpty) return DateTime.fromMillisecondsSinceEpoch(0);
  final epoch = int.tryParse(text);
  if (epoch != null) return _platformTime(epoch);
  return (DateTime.tryParse(text) ?? DateTime.fromMillisecondsSinceEpoch(0)).toLocal();
}

/// 可选时间：缺失或解析成 0 时返回 null，调用方据此降级（不画时间、按顺序兜底）。
DateTime? _optionalTime(Object? raw) {
  if (raw == null) return null;
  final time = _platformTime(raw);
  return time.millisecondsSinceEpoch <= 0 ? null : time;
}

class ChatBlock {
  const ChatBlock(this.type, this.data);

  final String type;
  final Map<String, Object?> data;

  /// 文本可缺省、也可能被服务端写成数字：非字符串时按「没有文本」处理，
  /// 不能让一条坏块把整条消息的渲染打断。
  String? get text {
    final value = data['text'];
    return value is String ? value : null;
  }
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.role,
    required this.blocks,
    this.form = '',
    bool isFramework = false,
    this.detectCommands = true,
    this.time,
    this.meta,
  }) : _declaredFramework = isFramework;

  final String id;
  final String role;
  final List<ChatBlock> blocks;

  /// 落库时间（服务端给了才非空）：框架块按它插入时间线并与平台消息对齐。
  final DateTime? time;

  /// 引擎元数据：`turn` / `step` / `usage` / `timing`（每个 block 的 startedAt/endedAt）。
  /// 这是轨迹视图的同源数据，用来给出权威的阶段耗时。
  final Map<String, Object?>? meta;

  /// 服务端标记的消息形态：`notice` 是引擎/插件注入的内部消息（wake、turn 装配），不是用户发言。
  final String form;

  /// 服务端/插件声明的框架消息：`form` 不是 `message`（如 `notice`），或来源是插件
  /// （`source.kind == 'plugin'`）。
  final bool _declaredFramework;

  /// 是否套用「指令文本」启发式（见 [isCommandMessage]）。只对会话日志成立：
  /// 平台消息（[PlatformMessage]）是逐条发言，`chatluna …` 也只是用户说的一句话。
  final bool detectCommands;

  /// 框架消息：不属于对话双方，渲染成居中的弱化块。
  /// 除服务端声明外，用户角色下的指令/帮助文本也并进来（见 [isCommandMessage]）。
  bool get isFramework => _declaredFramework || (detectCommands && isCommandMessage);

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
    final rawForm = json['form'];
    final form = rawForm is String ? rawForm : '';
    final source = json['source'];
    final sourceKind = source is Map ? source['kind'] : null;
    final rawId = json['id'];
    final rawRole = json['role'];
    return ChatMessage(
      id: rawId is String && rawId.isNotEmpty ? rawId : (fallbackId ?? ''),
      role: rawRole is String && rawRole.isNotEmpty ? rawRole : 'assistant',
      blocks: blocks,
      form: form,
      isFramework: (form.isNotEmpty && form != 'message') || sourceKind == 'plugin',
      time: _optionalTime(
        json['time'] ?? json['at'] ?? json['timestamp'] ?? json['createdAt'],
      ),
      // 引擎侧的权威计时（webui 轨迹视图同源）：`meta.timing = {startedAt, endedAt, blocks[]}`。
      meta: json['meta'] is Map
          ? (json['meta'] as Map).cast<String, Object?>()
          : null,
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
    final parts = _messageTagPattern.allMatches(raw).map((m) => m.group(1) ?? '').toList();
    var body = parts.isEmpty ? raw : parts.join('\n');
    body = body.replaceAllMapped(
      _imgTagPattern,
      (m) => '\n![](${m.group(1)})\n',
    );
    body = body.replaceAll(_statusTagPattern, '');
    // 只剥「明确的 HTML/平台标签」：标签名必须在白名单里，属性必须是 `name=value`
    // 形态。用户正文里的 `a<b && c>d`、`vector<int>`、`<T>` 因此原样保留；
    // `<div>` 这类真的是 HTML 的片段仍按旧行为清理。`<br>` 保留（markdown 换行）。
    body = body.replaceAll(_knownTagPattern, '');
    return body.trim();
  }

  /// 正文清洗用的三个正则只编译一次：每条消息第一次读 `bodyMarkdown` 都会用到。
  static final RegExp _messageTagPattern = RegExp(r'<message>([\s\S]*?)</message>');
  static final RegExp _imgTagPattern = RegExp(
    r'''<img[^>]*src\s*=\s*["']([^"']+)["'][^>]*>''',
    caseSensitive: false,
  );
  static final RegExp _statusTagPattern = RegExp(r'<status[\s\S]*?(/>|</status>)');

  /// 可识别的标签：HTML 常见标签 + 角色引擎的包裹标签（`message`/`status`/…）。
  /// 属性部分不接受 `&&`、`+` 之类正文符号，避免把比较表达式当成标签。
  static final RegExp _knownTagPattern = RegExp(
    r'</?(?:a|b|i|u|s|p|div|span|strong|em|small|big|font|center|hr|'
    r'html|head|body|meta|link|script|style|table|thead|tbody|tfoot|tr|td|th|'
    r'ul|ol|li|dl|dt|dd|blockquote|pre|code|img|section|article|header|footer|'
    r'turn|status|message|mood|bond|state)'
    r'(?:\s+[a-zA-Z_:][-a-zA-Z0-9_:]*'
    r'(?:\s*=\s*(?:"[^"]*"|\x27[^\x27]*\x27|[^\s>"\x27]+))?)*'
    r'\s*/?>',
    caseSensitive: false,
  );

  /// 指令类文本：只认用户角色（避免把模型正文里引用命令的帮助文字误判成指令）。
  /// - 首行（trim 后）以 `chatluna ` 开头：单条命令或单行说明；
  /// - 或 ≥ [_commandListLines] 个非空行都以 `chatluna ` 开头：`chatluna help` 之类的命令清单。
  /// 判定基于已清洗的 [bodyMarkdown]（XML 标签已剥掉），因此不会读到 `<turn>` 之类的噪声。
  late final bool isCommandMessage = _isCommandMessage();

  /// 命令前缀：插件命令空间，命令与参数之间必有一个空格。
  static const String _commandPrefix = 'chatluna ';

  /// 清单阈值：3 行以上同时以命令前缀开头就不再像人话，而是帮助列表。
  static const int _commandListLines = 3;

  bool _isCommandMessage() {
    if (role != 'user') return false;
    final body = bodyMarkdown;
    if (body.isEmpty) return false;
    final lines = [
      for (final line in body.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    if (lines.isEmpty) return false;
    if (lines.first.startsWith(_commandPrefix)) return true;
    var commands = 0;
    for (final line in lines) {
      if (line.startsWith(_commandPrefix)) commands += 1;
    }
    return commands >= _commandListLines;
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

  /// 语法探测只编译一次：每条消息在第一次访问 `hasMarkup` 时都会用到它。
  static final RegExp _markupPattern = RegExp(
    r'(^|\n)\s{0,3}(#{1,6}\s|[-*+]\s|\d+[.)]\s|>\s|\|)'
    r'|```'
    r'|`[^`\n]+`'
    r'|\*\*|__'
    r'|!\['
    r'|\[[^\]]+\]\([^)]+\)',
  );

  static bool _hasMarkup(String text) {
    if (text.isEmpty) return false;
    return _markupPattern.hasMatch(text);
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

/// `chatluna` 指令帮助里的一条子命令。
class CommandHelpItem {
  const CommandHelpItem({required this.command, required this.desc});

  /// 完整调用片段，例如 `chatluna archive`（中间空白已归一成一个空格）。
  final String command;

  /// 紧跟其后的说明，两端装饰（冒号、破折号、句点）已剥掉。
  final String desc;
}

/// bot 发来的 `chatluna` 指令帮助：把一大段文本拆成「开场一句 + 逐条命令」。
///
/// 插件把子命令清单连写成一整段——`指令：chatluna ChatLuna 主命令 可用的子指令有：
/// chatluna archive 归档当前会话 chatluna ban 封禁用户 …`——也可能按行排，
/// 两种形态都由 [parse] 归一。判定要求同时满足：
///   - 文本里出现 ≥ [_minItems] 段 `chatluna <子命令>`；
///   - 每段后面紧跟 ≥2 个字符的说明。
/// 只认**小写**子命令：`chatluna ChatLuna 主命令` 里的 `ChatLuna` 是命令名本身，
/// 把它当子命令会把开场白吃掉一条。普通句子里偶尔提到一次命令因此不会命中。
class CommandHelp {
  const CommandHelp._({required this.intro, required this.items});

  /// 第一条子命令之前的开场文字；空串表示文本以命令开头，卡片不画开场行。
  final String intro;

  /// 去重保序的子命令条目。
  final List<CommandHelpItem> items;

  /// 少于这么多条就不当帮助列表（人话里提一句命令很常见）。
  static const int _minItems = 3;

  /// 说明至少这么长才算「紧跟描述」：`chatluna help` 后面空着或只有一个标点的不算。
  static const int _minDescLength = 2;

  static final RegExp _commandPattern = RegExp(r'chatluna\s+[a-z][a-z0-9_-]*');

  /// 说明两端的装饰：冒号、逗号、句号、破折号、竖线、圆点、尖括号、斜杠。
  static final RegExp _descLead = RegExp(r'^[\s:：,，.。;；\-–—|/\\·•>»]+');
  static final RegExp _descTail = RegExp(r'[\s:：,，.。;；\-–—|/\\·•<«]+$');
  static final RegExp _spaces = RegExp(r'\s+');

  /// 不是帮助列表时返回 null；调用方据此决定走卡片还是普通正文。
  static CommandHelp? parse(String text) {
    if (text.isEmpty) return null;
    final matches = _commandPattern.allMatches(text).toList(growable: false);
    if (matches.length < _minItems) return null;
    final items = <CommandHelpItem>[];
    final seen = <String>{};
    for (var i = 0; i < matches.length; i++) {
      final match = matches[i];
      // 一段说明跑到下一条命令之前为止；最后一条跑到文本末尾。
      final end = i + 1 < matches.length ? matches[i + 1].start : text.length;
      final desc = _cleanDesc(text.substring(match.end, end));
      if (desc.length < _minDescLength) continue;
      final command = match.group(0)!.replaceAll(_spaces, ' ');
      if (!seen.add(command)) continue;
      items.add(CommandHelpItem(command: command, desc: desc));
    }
    if (items.length < _minItems) return null;
    return CommandHelp._(
      intro: _cleanIntro(text.substring(0, matches.first.start)),
      items: List<CommandHelpItem>.unmodifiable(items),
    );
  }

  /// 说明只取第一行有内容的那行：换行列表里一条命令占一行，下一行是别的段落。
  static String _cleanDesc(String raw) {
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final collapsed = trimmed.replaceAll(_spaces, ' ');
      final lead = collapsed.replaceFirst(_descLead, '');
      return lead.replaceFirst(_descTail, '').trim();
    }
    return '';
  }

  /// 开场行只归一空白，不动标点：`…可用的子指令有：` 读起来就是原样。
  static String _cleanIntro(String raw) => raw.replaceAll(_spaces, ' ').trim();
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
      toolCallId = null,
      reason = null;

  const LiveEvent.delta(this.delta, int index)
    : kind = LiveEventKind.delta,
      parts = const [],
      toolName = null,
      toolCallId = null,
      reason = null,
      active = true;

  const LiveEvent.tool(this.toolName, [this.toolCallId])
    : kind = LiveEventKind.tool,
      parts = const [],
      delta = null,
      reason = null,
      active = true;

  /// 思考阶段（`part.type == 'reasoning'`）：只用来区分「思考中」与「回复中」，正文不进 buffer。
  const LiveEvent.reasoning()
    : kind = LiveEventKind.reasoning,
      parts = const [],
      delta = null,
      toolName = null,
      toolCallId = null,
      reason = null,
      active = true;

  const LiveEvent.settled(this.reason)
    : kind = LiveEventKind.settled,
      parts = const [],
      delta = null,
      toolName = null,
      toolCallId = null,
      active = false;

  const LiveEvent.lagged()
    : kind = LiveEventKind.lagged,
      parts = const [],
      delta = null,
      toolName = null,
      toolCallId = null,
      reason = null,
      active = false;

  final LiveEventKind kind;
  final List<Map<String, Object?>> parts;
  final String? delta;
  final String? toolName;

  /// 工具调用 id：把 `tool-input` 帧与落库的 `tool-result` 一一配对（同名工具重试不会串段）。
  final String? toolCallId;
  final String? reason;

  /// 该事件是否代表「有生成在进行中」：snapshot 看有没有 attempt，delta/tool/reasoning 恒为真。
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
        if (type == 'reasoning') return const LiveEvent.reasoning();
        if (type == 'tool-input') {
          final name = part['toolName'];
          final callId = part['toolCallId'];
          return LiveEvent.tool(
            name is String ? name : 'tool',
            callId is String ? callId : null,
          );
        }
        return null;
      case 'agent/assistant-settled':
        final outcome = data?['outcome'];
        // 服务端字段漂移（数字/对象）时降级成 null，别让一条坏帧打断整条 `/live`。
        final reason = outcome is Map && outcome['reason'] is String
            ? outcome['reason'] as String
            : null;
        return LiveEvent.settled(reason);
      case 'lagged':
        return const LiveEvent.lagged();
      default:
        return null;
    }
  }
}

enum LiveEventKind { snapshot, delta, tool, reasoning, settled, lagged }

/// `/api/sessions/:id/events` 的一个增量帧：落库的新消息、mark，或增量窗口失效。
class SessionEvent {
  const SessionEvent.message(this.message, this.id)
    : truncated = false,
      name = null,
      data = null,
      time = null;

  const SessionEvent.truncated()
    : message = null,
      id = null,
      truncated = true,
      name = null,
      data = null,
      time = null;

  /// 日志里的 mark（`kind:"mark"`）：不是消息，而是「这一轮做了什么」的打点。
  /// 计时只读 `name` 与 `data`（`agent/input-enqueued` / `engine/activity` / `chat/delivered` …）。
  const SessionEvent.mark(this.name, this.data, {this.id, this.time})
    : message = null,
      truncated = false;

  /// 新落库的消息；mark 与 `truncated` 时为空。
  final ChatMessage? message;

  /// SSE 帧的 `id`（形如 `<sessionId>:<n>`），重连时作为 `Last-Event-ID` 续传。
  final String? id;

  /// 服务端的增量窗口已失效：本地增量不可信，调用方应重取 `/messages`。
  final bool truncated;

  /// mark 名（`prompt` / `engine/activity` / `chat/delivered` …）；消息帧为空。
  final String? name;

  /// mark 的 `data` 原样；消息帧为空。
  final Map<String, Object?>? data;

  /// 这条 entry 的落库时间（服务端 `time`）；没给时为空。
  final DateTime? time;
}
