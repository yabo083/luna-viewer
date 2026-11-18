import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../../core/model/models.dart';
import 'assistant_avatar.dart';

/// 一条消息的渲染：助手走「无气泡 + markdown + 思考折叠 + 工具计数」，
/// 用户走右侧浅色气泡。图片按 markdown `![]()` 出现，统一圆角并可点开全屏。
class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.message,
    required this.base,
    required this.headers,
    required this.noticeOpen,
    this.noticeCount = 1,
    this.avatarUrl,
  });

  final ChatMessage message;
  final Uri base;

  /// 工作区图片需要 Bearer 才能取，`Image.network` 直连时复用同一份头。
  final Map<String, String> headers;

  /// 页面级框架消息折叠状态：消息 id → 是否展开。
  /// 放在页面里，列表滚动重建（`ListView.builder` 销毁离屏元素）后仍然保留。
  final Map<String, bool> noticeOpen;

  /// 这一条虚拟消息里合并了几条框架消息（相邻同标题的合并块）；>1 时标题后缀显示 `· N 条`。
  final int noticeCount;
  final String? avatarUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = message.bodyMarkdown;
    final reasoning = message.reasoningText;
    if (body.isEmpty && reasoning.isEmpty && message.toolCalls.isEmpty) {
      return const SizedBox.shrink();
    }

    // 框架消息不参与左右布局：先短路，省掉整棵 markdown 构建。
    if (message.isFramework) {
      // 极端情况下服务端没给 id：用正文摘要当键，至少同一条消息的展开状态是稳定的。
      final foldKey = message.id.isNotEmpty ? message.id : 'framework-${body.hashCode}';
      return _FrameworkNotice(
        foldKey: foldKey,
        text: body,
        open: noticeOpen,
        count: noticeCount,
      );
    }

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (reasoning.isNotEmpty)
          _Foldable(
            key: ValueKey('reasoning-${message.id}'),
            icon: Icons.psychology_outlined,
            title: '思考过程',
            child: SelectableText(
              reasoning,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (body.isNotEmpty)
          // 纯散文直接 Text：markdown 树构建是首帧的主要开销，只有真含语法时才付这笔钱。
          message.hasMarkup
              ? _Markdown(data: body, base: base, headers: headers)
              : SelectableText(body, style: theme.textTheme.bodyMedium?.copyWith(height: 1.55)),
        if (message.toolCalls.isNotEmpty)
          _Foldable(
            key: ValueKey('tools-${message.id}'),
            icon: Icons.build_outlined,
            title: '工具调用 ×${message.toolCalls.length}',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final call in message.toolCalls) _ToolCallTile(call: call),
              ],
            ),
          ),
      ],
    );

    if (message.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.86),
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(16),
          ),
          child: message.hasMarkup
              ? _Markdown(data: body, base: base, headers: headers)
              : SelectableText(
                  body,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AssistantAvatar(size: 28, imageUrl: avatarUrl),
          const SizedBox(width: 10),
          Expanded(child: content),
        ],
      ),
    );
  }
}

class _Markdown extends StatelessWidget {
  const _Markdown({
    required this.data,
    required this.base,
    required this.headers,
  });

  final String data;
  final Uri base;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle = (theme.textTheme.bodyMedium?.copyWith(height: 1.55)) ??
        const TextStyle(fontSize: 15, height: 1.55);
    return MarkdownWidget(
      data: data,
      shrinkWrap: true,
      selectable: true,
      config: MarkdownConfig(
        configs: [
          PConfig(textStyle: textStyle),
          ImgConfig(
            builder: (url, _) => _ChatImage(url: url, resolve: _resolve, headers: headers),
          ),
          PreConfig(
            textStyle:
                theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.45) ??
                const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.45),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          LinkConfig(style: TextStyle(color: theme.colorScheme.primary)),
        ],
      ),
    );
  }

  Uri _resolve(String url) {
    if (url.startsWith('http://') || url.startsWith('https://') || url.startsWith('data:')) {
      return Uri.parse(url);
    }
    // storage 附件（`file` 块的 reference）由实例直接提供，不需要 Bearer。
    if (url.startsWith('/files/')) return base.resolve(url.substring(1));
    final name = url.startsWith('/') ? url.substring(1) : url;
    // 相对路径是 agent 工作区（data/chatluna/agents-work）里的文件，由 companion 插件以 Bearer 提供。
    return base.replace(path: '/api/workspace', queryParameters: {'path': name});
  }
}

class _ChatImage extends StatefulWidget {
  const _ChatImage({required this.url, required this.resolve, required this.headers});

  final String url;
  final Uri Function(String) resolve;
  final Map<String, String> headers;

  /// `data:image/...;base64,` 走内存解码；`Image.network` 不支持 data scheme。
  static Uint8List? _inlineBytes(String source) {
    if (!source.startsWith('data:')) return null;
    final marker = RegExp(r'^data:image/[^;,]+;base64,', caseSensitive: false).firstMatch(source);
    if (marker == null) return null;
    try {
      return base64Decode(source.substring(marker.end));
    } on FormatException {
      return null;
    }
  }

  /// `base64://<payload>` 没有 mime，按图片内容解码即可（mime 不参与 Flutter 解码）。
  static String _normalizeSource(String source) {
    if (!source.startsWith('base64:')) return source;
    final marker = RegExp(r'^base64:(?://)?').firstMatch(source);
    if (marker == null) return source;
    return 'data:image/png;base64,${source.substring(marker.end)}';
  }

  @override
  State<_ChatImage> createState() => _ChatImageState();
}

class _ChatImageState extends State<_ChatImage> {
  /// 缩略图上限：长图不再占满一屏。点开后的全屏查看不受这两个值限制。
  static const _maxWidth = 260.0;
  static const _maxHeight = 320.0;

  late String _source;
  Uint8List? _bytes;

  /// 解码得到的展示尺寸（已按比例收进上限）；null 表示还用着占位尺寸。
  Size? _size;
  ImageProvider? _measured;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  bool _inBuild = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(covariant _ChatImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _detach();
      _measured = null;
      _size = null;
      _prepare();
    }
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  /// base64 只在 url 变化时解一次：每次 build 重建 Uint8List 会让 ImageCache 全部落空。
  void _prepare() {
    _source = _ChatImage._normalizeSource(widget.url);
    _bytes = _ChatImage._inlineBytes(_source);
  }

  void _detach() {
    final listener = _listener;
    final stream = _stream;
    if (listener != null && stream != null) stream.removeListener(listener);
    _listener = null;
    _stream = null;
  }

  int _cacheWidth(BuildContext context) =>
      (_maxWidth * MediaQuery.devicePixelRatioOf(context)).round();

  /// markdown 的 `WidgetSpan` 给子节点的高度是无界的，`BoxConstraints.maxHeight` 会被忽略；
  /// 所以自己解码一次拿真实宽高，再给出确定的 `SizedBox` 尺寸。
  void _measure(BuildContext context, Uri uri) {
    final width = _cacheWidth(context);
    final provider = _bytes != null
        ? ResizeImage(MemoryImage(_bytes!), width: width)
        : ResizeImage(NetworkImage(uri.toString(), headers: widget.headers), width: width);
    if (provider == _measured) return;
    _detach();
    _measured = provider;
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener(
      (info, _) {
        final image = info.image;
        final natural = Size(image.width.toDouble(), image.height.toDouble());
        info.dispose();
        if (!mounted) return;
        final fitted = _fit(natural);
        if (fitted == _size) return;
        if (_inBuild) {
          // 解码命中缓存时回调是同步的：本帧直接按真实比例排，别在 build 期间 setState。
          _size = fitted;
        } else {
          setState(() => _size = fitted);
        }
      },
      onError: (error, stack) {},
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  /// 按比例收进 260 × 320：小图不放大，长图收到 320 高，`BoxFit.cover` 不再有裁切。
  static Size _fit(Size natural) {
    if (natural.width <= 0 || natural.height <= 0) {
      return const Size(_maxWidth, _maxHeight);
    }
    final scale = math.min(_maxWidth / natural.width, _maxHeight / natural.height);
    return scale < 1 ? natural * scale : natural;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final source = _source;
    final uri = widget.resolve(source);
    final bytes = _bytes;
    // 声明了 data URI 却解不出来：直接给占位，别让 Image.network 抛 unsupported scheme。
    final broken = source.startsWith('data:') && bytes == null;

    Widget placeholder({double width = 200, double height = 120}) => Container(
      width: width,
      height: height,
      color: theme.colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 4),
          Text('图片不可用', style: theme.textTheme.labelSmall),
        ],
      ),
    );

    var size = _size ?? const Size(_maxWidth, _maxHeight);
    if (!broken) {
      _inBuild = true;
      try {
        _measure(context, uri);
      } finally {
        _inBuild = false;
      }
      size = _size ?? size;
    }
    final cacheWidth = _cacheWidth(context);
    final double width = broken ? 200 : size.width;
    final double height = broken ? 120 : size.height;

    final Widget preview;
    if (broken) {
      preview = placeholder();
    } else if (bytes != null) {
      preview = Image.memory(
        bytes,
        width: width,
        height: height,
        cacheWidth: cacheWidth,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stack) => placeholder(width: width, height: height),
      );
    } else {
      preview = Image.network(
        uri.toString(),
        headers: widget.headers,
        width: width,
        height: height,
        cacheWidth: cacheWidth,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, progress) => progress == null
            ? child
            : Container(
                width: width,
                height: height,
                color: theme.colorScheme.surfaceContainerHighest,
                child: const Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
        errorBuilder: (context, error, stack) => placeholder(width: width, height: height),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: GestureDetector(
        onTap: broken
            ? null
            : () => showDialog<void>(
                context: context,
                builder: (_) => Dialog.fullscreen(
                  backgroundColor: Colors.black,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: InteractiveViewer(
                          child: bytes != null
                              ? Image.memory(bytes, fit: BoxFit.contain)
                              : Image.network(
                                  uri.toString(),
                                  fit: BoxFit.contain,
                                  headers: widget.headers,
                                ),
                        ),
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: IconButton.filledTonal(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          // 显式尺寸：WidgetSpan 的高度约束不可靠，这里不再依赖父级 maxHeight。
          child: SizedBox(width: width, height: height, child: preview),
        ),
      ),
    );
  }
}

/// 框架/系统消息（`form != message` 或 `source.kind == plugin`）：不属于对话左右任一方。
/// 整块是**一张卡片**：卡片内顶部一行头（图标 + 标题 + `· N 条 · N 行` + 右侧箭头）始终可见、
/// 整行可点；正文在同一张卡片里左对齐，按空行分段、裸 JSON/URL 等宽、默认折叠成 2 行预览。
/// 相邻同标题的多条框架消息由页面层合并成一条虚拟消息，此时 [count] > 1、后缀多一段 `· N 条`。
/// 展开状态按消息 id 存在页面级 map 里，列表滚动重建也不会丢。旧的 `form: notice` 也走这一条路径。
class _FrameworkNotice extends StatefulWidget {
  const _FrameworkNotice({
    required this.foldKey,
    required this.text,
    required this.open,
    this.count = 1,
  });

  /// 折叠状态的键：消息 id（合并块是 `${first.id}|${second.id}|…`）。
  final String foldKey;
  final String text;

  /// 合并进这一块的框架消息条数；>1 时标题后缀多一段 `· N 条`。
  final int count;

  /// 页面级 `Map<String, bool>`：折叠键 → 是否展开；缺省即折叠。
  final Map<String, bool> open;

  @override
  State<_FrameworkNotice> createState() => _FrameworkNoticeState();
}

class _FrameworkNoticeState extends State<_FrameworkNotice> {
  /// 折叠态只露 2 行预览；展开态最多排 200 行，更长的正文只提示剩余行数。
  static const _previewLines = 2;
  static const _maxOpenLines = 200;

  bool get _open => widget.open[widget.foldKey] ?? false;

  void _toggle() => setState(() => widget.open[widget.foldKey] = !_open);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final notice = Notice.parse(widget.text);
    final open = _open;
    final openLines = notice.lines.length > _maxOpenLines
        ? notice.lines.sublist(0, _maxOpenLines)
        : notice.lines;
    final hidden = notice.lines.length - openLines.length;
    final paragraphs = Notice.paragraphs(openLines);
    final titleStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      height: 1.35,
    );
    final metaStyle = titleStyle?.copyWith(
      fontSize: 10,
      color: scheme.onSurfaceVariant.withValues(alpha: 0.65),
    );
    // 后缀：合并块先报条数（`· 2 条`），再报正文行数（`· 6 行`）。
    final meta = [
      if (widget.count > 1) '· ${widget.count} 条',
      notice.meta,
    ].where((part) => part.isNotEmpty).join(' ');
    final preview = Notice.preview(notice.lines, _previewLines);
    final bodyStyle = _bodyStyle(theme);
    return Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.86),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          // 整块只有这一层卡片容器：头与正文共用同一张卡，不再有「居中胶囊 + 正文卡片」两层。
          child: Material(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 卡片内的左对齐头：整行可点切换展开；只有这一行自带内边距。
                InkWell(
                  onTap: _toggle,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
                    child: Row(
                      children: [
                        Icon(
                          Icons.subdirectory_arrow_right,
                          size: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            notice.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: titleStyle,
                          ),
                        ),
                        if (meta.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Text(meta, style: metaStyle),
                        ],
                        const SizedBox(width: 4),
                        Icon(
                          open ? Icons.expand_less : Icons.expand_more,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
                if (paragraphs.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                    child: open
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (var i = 0; i < paragraphs.length; i++)
                                Padding(
                                  // 段间距 8；末尾还有「未展开」提示时最后一段也让出间距。
                                  padding: EdgeInsets.only(
                                    bottom: i < paragraphs.length - 1 || hidden > 0 ? 8 : 0,
                                  ),
                                  child: _paragraph(paragraphs[i], theme),
                                ),
                              if (hidden > 0)
                                Text(
                                  '… 仅显示前 $_maxOpenLines 行，还有 $hidden 行未展开',
                                  style: titleStyle,
                                ),
                            ],
                          )
                        // 折叠态：2 行预览，灰一档；超过 2 行由 `Notice.preview` 补 `…`。
                        : Text(
                            preview,
                            maxLines: _previewLines,
                            overflow: TextOverflow.ellipsis,
                            style: bodyStyle.copyWith(
                              color: scheme.onSurfaceVariant.withValues(alpha: 0.72),
                            ),
                          ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  TextStyle _bodyStyle(ThemeData theme) =>
      theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        height: 1.5,
      ) ??
      TextStyle(fontSize: 12, height: 1.5, color: theme.colorScheme.onSurfaceVariant);

  TextStyle _monoStyle(ThemeData theme) =>
      theme.textTheme.labelSmall?.copyWith(
        fontFamily: 'monospace',
        fontSize: 11,
        height: 1.45,
        color: theme.colorScheme.onSurfaceVariant,
      ) ??
      const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.45);

  /// 一段正文：整段 JSON 解析后按缩进等宽排，整段裸链接也等宽，其余走小号正文。
  /// 段内换行原样保留：`[memory update]` 的 `- [ch-03 …]` 列表行各占一行。
  Widget _paragraph(String text, ThemeData theme) {
    final json = Notice.prettyJson(text);
    if (json != null) return SelectableText(json, style: _monoStyle(theme));
    if (Notice.isUrlList(text)) return SelectableText(text, style: _monoStyle(theme));
    return SelectableText(text, style: _bodyStyle(theme));
  }
}

/// 框架消息的文本解析：抽出结构标题，丢掉首行的 `---` 与尾部空行，剩余行按空行分段。
/// 公开给页面层：`ChatPage` 用 [parse]/[key] 判断相邻框架消息是否同一类型、能否合并成一块。
class Notice {
  const Notice(this.title, this.lines);

  /// 标题：首行是 `[xxx]` 就整行拿来当标题；否则取首行前 24 字做预览标题。
  final String title;

  /// 正文行：`[xxx]` 标题行不进正文；`---` 分隔线只做视觉标记。
  /// 没有结构头的首行只当标题预览，展开时正文仍保留它。
  final List<String> lines;

  /// 无结构头时标题取的字符数。
  static const _titleChars = 24;

  static final _bracketTitle = RegExp(r'^\[[^\]]+\]$');
  static final _rule = RegExp(r'^(-{3,}|\*{3,}|_{3,})$');
  static final _url = RegExp(r'^https?://\S+$');
  static final _space = RegExp(r'\s+');

  /// 合并分组键：标题忽略大小写与空白差异，`[Memory Update]` 与 `[memory update]` 同组。
  /// 页面层用它判断相邻两条框架消息是不是同一类型。
  static String key(String title) => title.toLowerCase().replaceAll(_space, '');

  /// 结构化解析：首行 `[xxx]` 整行当标题，否则取首行前 24 字；其余行是正文。
  static Notice parse(String raw) {
    final source = raw.split('\n');
    var start = 0;
    while (start < source.length) {
      final line = source[start].trim();
      // 前导空行与 `---` 之类的分隔线都不算正文，也不当标题。
      if (line.isEmpty || _rule.hasMatch(line)) {
        start += 1;
        continue;
      }
      break;
    }
    if (start >= source.length) return const Notice('系统消息', []);
    final first = source[start].trim();
    final rest = _trimTrailing(source.sublist(start));
    // `[memory update]` 这类首行是结构头：抽成标题并从正文去掉（长标题交给胶囊自身省略）。
    if (_bracketTitle.hasMatch(first)) {
      return Notice(first, _trimTrailing(rest.sublist(1)));
    }
    return Notice(_clip(first), rest);
  }

  static String _clip(String text) =>
      text.length <= _titleChars ? text : '${text.substring(0, _titleChars)}…';

  static List<String> _trimTrailing(List<String> lines) {
    var end = lines.length;
    while (end > 0 && lines[end - 1].trim().isEmpty) {
      end -= 1;
    }
    return lines.sublist(0, end);
  }

  /// 标题后缀：显示正文的有效行数（空行只做分段，不计入；合并块因此是各条之和）。
  String get meta {
    final count = lines.where((line) => line.trim().isNotEmpty).length;
    return count == 0 ? '' : '· $count 行';
  }

  /// 折叠态预览：前 [limit] 个非空行；还有更多非空行就补 `…`。
  static String preview(List<String> lines, int limit) {
    final buffer = StringBuffer();
    var used = 0;
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      if (used == limit) return '$buffer…';
      if (used > 0) buffer.write('\n');
      buffer.write(line.trimRight());
      used += 1;
    }
    return buffer.toString();
  }

  /// 空行分段，段内保留换行；段间 8px 由调用方补。
  static List<String> paragraphs(List<String> lines) {
    final out = <String>[];
    final buffer = StringBuffer();
    for (final line in lines) {
      if (line.trim().isEmpty) {
        if (buffer.isNotEmpty) {
          out.add(buffer.toString());
          buffer.clear();
        }
        continue;
      }
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(line.trimRight());
    }
    if (buffer.isNotEmpty) out.add(buffer.toString());
    return out;
  }

  /// 整段是 JSON：解析后按两空格缩进重排；解析失败（含 `[xxx]` 这类非 JSON 方括号）返回 null。
  static String? prettyJson(String text) {
    final trimmed = text.trim();
    final object = trimmed.startsWith('{') && trimmed.endsWith('}');
    final array = trimmed.startsWith('[') && trimmed.endsWith(']');
    if (!object && !array) return null;
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(trimmed));
    } on FormatException {
      return null;
    }
  }

  /// 整段是一行一个的裸链接。
  static bool isUrlList(String text) {
    final links = [
      for (final line in text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    return links.isNotEmpty && links.every(_url.hasMatch);
  }
}

class _ToolCallTile extends StatelessWidget {
  const _ToolCallTile({required this.call});

  final ToolCallInfo call;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final input = call.prettyInput;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.arrow_right_alt, size: 14, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                call.name,
                style: theme.textTheme.labelMedium?.copyWith(fontFamily: 'monospace'),
              ),
            ],
          ),
          if (input.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SelectableText(
                input,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.35,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (call.output.isNotEmpty) ...[
            const SizedBox(height: 6),
            Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
            const SizedBox(height: 6),
            Text(
              '结果',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 2),
            SelectableText(
              call.output,
              style: theme.textTheme.labelSmall?.copyWith(
                fontFamily: 'monospace',
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Foldable extends StatefulWidget {
  const _Foldable({super.key, required this.icon, required this.title, required this.child});

  final IconData icon;
  final String title;
  final Widget child;

  @override
  State<_Foldable> createState() => _FoldableState();
}

class _FoldableState extends State<_Foldable> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(widget.icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text(widget.title, style: theme.textTheme.labelMedium),
                  const Spacer(),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: widget.child,
            ),
        ],
      ),
    );
  }
}
