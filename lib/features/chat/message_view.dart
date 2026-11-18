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
    this.avatarUrl,
  });

  final ChatMessage message;
  final Uri base;

  /// 工作区图片需要 Bearer 才能取，`Image.network` 直连时复用同一份头。
  final Map<String, String> headers;
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
      return _FrameworkNotice(text: body);
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

/// 框架/系统消息（`form != message` 或 `source.kind == plugin`）：不属于对话左右任一方，
/// 居中收成一行胶囊标题，点开看全文。旧的 `form: notice` 也走这一条路径。
class _FrameworkNotice extends StatefulWidget {
  const _FrameworkNotice({required this.text});

  final String text;

  @override
  State<_FrameworkNotice> createState() => _FrameworkNoticeState();
}

class _FrameworkNoticeState extends State<_FrameworkNotice> {
  bool _open = false;

  /// 标题取首个非空行：wake / turn 装配这类长文本不该整段顶在列表里。
  String get _title {
    for (final line in widget.text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return '系统消息';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      height: 1.35,
    );
    return Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.86),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => setState(() => _open = !_open),
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.fromLTRB(10, 5, 8, 5),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.subdirectory_arrow_right,
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      _open ? Icons.expand_less : Icons.expand_more,
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            if (_open)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: SelectableText(
                  widget.text,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
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
