import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/model/models.dart';
import 'assistant_avatar.dart';

/// 一条消息的渲染（bot 视角）：`dir=out` 是机器人自己的发言 → **右侧主色气泡**；
/// `dir=in` 是其他人 → **左侧中性气泡**。两侧都走 markdown 与富媒体（图片缩略 + 全屏）。
/// 框架消息不参与左右布局，仍是居中的单卡片。
///
/// 头像槽左右各留一份：`showHeader` 为 false 时留空占位，连续消息因此保持缩进对齐。
///
/// 媒体（[PlatformMessage.media]）在气泡里单独成块：图片走缩略图/网格，视频/音频/文件走一行胶囊。
/// 正文只剩占位文案（`[图片]`）时不再重复显示——媒体本身已经把这层信息表达完了。
class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.message,
    required this.base,
    required this.headers,
    required this.noticeOpen,
    this.noticeCount = 1,
    this.media = const <PlatformMedia>[],
    this.avatarUrl,
    this.senderName,
    this.time,
    this.footnote,
    this.showHeader = true,
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

  /// 平台消息的媒体附件。空列表 = 纯文本，渲染路径与以前完全一致。
  final List<PlatformMedia> media;

  /// 发送者头像：bot 用自己的，其他人用平台消息带的；缺失时画首字母圆头像。
  final String? avatarUrl;

  /// 发送者展示名：`out` 传 bot 名，`in` 传平台给的 `userName`；null 表示不知道，不画名字行。
  final String? senderName;

  /// 消息时间：气泡右下角显示 `HH:mm`；null 隐藏，不影响布局。
  final DateTime? time;

  /// 气泡脚注（小号 muted，跟在时间后面）：本页观测到的这一轮生成耗时 `1m04s`。
  /// 服务端没有这个字段，只有本机看到的那条 out 气泡会有。
  final String? footnote;

  /// 同一发送者 5 分钟内的连续消息里只有第一条为 true：头像与名字只出现一次。
  final bool showHeader;

  static const double _avatarSize = 28;
  static const double _avatarGap = 8;
  static const double _maxWidthRatio = 0.86;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final body = message.bodyMarkdown;
    final reasoning = message.reasoningText;
    if (body.isEmpty && reasoning.isEmpty && message.toolCalls.isEmpty && media.isEmpty) {
      return const SizedBox.shrink();
    }

    // 有媒体时，正文只剩 `[图片]` 这类占位就是重复信息：媒体块已经把它表达完了。
    final showBody = body.isNotEmpty && !(media.isNotEmpty && _placeholderOnly(body));

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

    // bot 自己的发言在右（主色底），其他人发言在左（中性底）。
    final outbound = !message.isUser;
    final foreground = outbound ? scheme.onPrimary : scheme.onSurface;
    final mutedForeground = outbound
        ? scheme.onPrimary.withValues(alpha: 0.72)
        : scheme.onSurfaceVariant.withValues(alpha: 0.75);

    // bot 把 `chatluna` 的帮助清单发成一整段文本：排版成卡片，其余正文一律走原路径。
    final help = showBody ? CommandHelp.parse(body) : null;

    final content = <Widget>[
      if (reasoning.isNotEmpty)
        _Foldable(
          key: ValueKey('reasoning-${message.id}'),
          icon: Icons.psychology_outlined,
          title: '思考过程',
          child: SelectableText(
            reasoning,
            style: theme.textTheme.bodySmall?.copyWith(height: 1.5, color: mutedForeground),
          ),
        ),
      if (help != null)
        _CommandHelpCard(
          key: ValueKey('command-help-${message.id}'),
          help: help,
          foreground: foreground,
          muted: mutedForeground,
          commandColor: outbound ? foreground : scheme.primary,
        )
      else if (showBody)
        // 纯散文直接 Text：markdown 树构建是首帧的主要开销，只有真含语法时才付这笔钱。
        message.hasMarkup
            ? _Markdown(data: body, base: base, headers: headers, foreground: foreground)
            : SelectableText(
                body,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.5, color: foreground),
              ),
      if (media.isNotEmpty)
        _MediaBlock(
          key: ValueKey('media-${message.id}'),
          media: media,
          base: base,
          headers: headers,
          foreground: foreground,
          muted: mutedForeground,
        ),
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
    ];

    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * _maxWidthRatio - (_avatarSize + _avatarGap),
      ),
      margin: EdgeInsets.only(top: showHeader ? 2 : 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 7),
      decoration: BoxDecoration(
        color: outbound ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(outbound ? 16 : 4),
          topRight: Radius.circular(outbound ? 4 : 16),
          bottomLeft: const Radius.circular(16),
          bottomRight: const Radius.circular(16),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...content,
          if (time != null || footnote != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  [
                    if (time != null) _hourMinute(time!),
                    ?footnote,
                  ].join(' · '),
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    height: 1.2,
                    color: mutedForeground,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    final name = senderName?.trim();
    final header = showHeader && name != null && name.isNotEmpty
        ? Padding(
            padding: EdgeInsets.only(bottom: 3, left: outbound ? 0 : 3, right: outbound ? 3 : 0),
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 11,
                height: 1.2,
                color: scheme.onSurfaceVariant,
              ),
            ),
          )
        : null;

    final avatar = showHeader
        ? SizedBox.square(
            dimension: _avatarSize,
            child: outbound
                ? AssistantAvatar(size: _avatarSize, imageUrl: avatarUrl)
                : _HumanAvatar(size: _avatarSize, name: name, imageUrl: avatarUrl),
          )
        : const SizedBox(width: _avatarSize, height: _avatarSize);

    final aligned = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: outbound ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [?header, bubble],
    );

    return Padding(
      // 分组之间 16，同一发送者的连续消息之间 8。
      padding: EdgeInsets.only(top: showHeader ? 16 : 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: outbound ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: outbound
            ? [
                Flexible(child: aligned),
                const SizedBox(width: _avatarGap),
                avatar,
              ]
            : [
                avatar,
                const SizedBox(width: _avatarGap),
                Flexible(child: aligned),
              ],
      ),
    );
  }
}

String _hourMinute(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

/// 人类发送者的头像：有真实头像就加载，失败或缺失时用名字首字母的圆头像。
class _HumanAvatar extends StatelessWidget {
  const _HumanAvatar({required this.size, this.name, this.imageUrl});

  final double size;
  final String? name;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = imageUrl;
    final initial = _initialOfName(name);
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.secondaryContainer),
      child: initial.isEmpty
          ? Icon(Icons.person_outline, size: size * 0.55, color: scheme.onSecondaryContainer)
          : Text(
              initial,
              style: TextStyle(
                fontSize: size * 0.42,
                height: 1,
                fontWeight: FontWeight.w600,
                color: scheme.onSecondaryContainer,
              ),
            ),
    );
    if (url == null || url.trim().isEmpty) return fallback;
    return SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: Image.network(
          url,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => fallback,
        ),
      ),
    );
  }
}

/// 名字首字：去掉首尾空白，按 rune 取，避免把一个代理对切成两半。
String _initialOfName(String? name) {
  final trimmed = name?.trim() ?? '';
  if (trimmed.isEmpty) return '';
  return String.fromCharCode(trimmed.runes.first).toUpperCase();
}

/// 会话头像：只代表**对方/群**，会话列表的每一行都用它。
/// 回退链：`conversation.avatar` → 会话名首字 → 群组/人形图标。
/// **绝不回退 bot 头像**：bot 是助手自己，拿它代表对方/群会让人认错会话。
class ConversationAvatar extends StatelessWidget {
  const ConversationAvatar({
    super.key,
    required this.title,
    this.imageUrl,
    this.isGroup = false,
    this.size = 36,
  });

  /// 会话展示名：首字占位用它。
  final String title;

  /// 插件给的会话头像（群头像 / 对方头像）；null 或空串走占位。
  final String? imageUrl;

  /// 群聊用群组色与群组图标，私聊用中性色与人形图标。
  final bool isGroup;

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = isGroup ? scheme.tertiaryContainer : scheme.secondaryContainer;
    final onBackground = isGroup ? scheme.onTertiaryContainer : scheme.onSecondaryContainer;
    final initial = _initialOfName(title);
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: background),
      child: initial.isEmpty
          ? Icon(
              isGroup ? Icons.groups_outlined : Icons.person_outline,
              size: size * 0.55,
              color: onBackground,
            )
          : Text(
              initial,
              style: TextStyle(
                fontSize: size * 0.42,
                height: 1,
                fontWeight: FontWeight.w600,
                color: onBackground,
              ),
            ),
    );
    final url = imageUrl?.trim() ?? '';
    if (url.isEmpty) return fallback;
    return SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: Image.network(url, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback),
      ),
    );
  }
}

class _Markdown extends StatelessWidget {
  const _Markdown({
    required this.data,
    required this.base,
    required this.headers,
    this.foreground,
  });

  final String data;
  final Uri base;
  final Map<String, String> headers;

  /// 气泡前景色：主色底上文字要跟着气泡走，不能再用主题的正文色。
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = foreground;
    final textStyle = (theme.textTheme.bodyMedium?.copyWith(height: 1.55, color: color)) ??
        TextStyle(fontSize: 15, height: 1.55, color: color);
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
                theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.45,
                  color: color,
                ) ??
                TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.45, color: color),
            decoration: BoxDecoration(
              color: color?.withValues(alpha: 0.12) ?? scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          LinkConfig(
            style: TextStyle(
              color: color ?? scheme.primary,
              decoration: TextDecoration.underline,
              decorationColor: color ?? scheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Uri _resolve(String url) => _resolveAsset(base, url);
}

/// `chatluna` 指令帮助卡片：bot 把子命令清单发成一整段文本时，按行排版成「命令 + 说明」。
/// 顶部是弱化的开场行（[CommandHelp.intro]），下面每行一条命令，行距 6。
///
/// 超过 [visibleRows] 条先折起来，末行可点「展开全部 N 条」（再点收起）。
/// 折叠状态是本地 state：卡片在气泡里，滚动重建（`ListView.builder` 销毁离屏元素）后回到折叠，
/// 与框架消息的页面级 [MessageView.noticeOpen] 不同——帮助卡一眼看完就该折叠，不该被记住。
class _CommandHelpCard extends StatefulWidget {
  const _CommandHelpCard({
    super.key,
    required this.help,
    required this.foreground,
    required this.muted,
    required this.commandColor,
  });

  final CommandHelp help;

  /// 气泡前景色：右侧主色底与左侧中性底都用它，卡片里不引出第二种正文色。
  final Color foreground;

  /// 弱化色：开场行与折叠按钮用它，跟着气泡的 muted 走。
  final Color muted;

  /// 命令色：等宽主色；右侧主色气泡上主色不可读，调用方改传气泡前景色。
  final Color commandColor;

  /// 折叠阈值：一次最多铺 8 行——帮助清单动辄十几条，全铺开会顶掉半屏对话。
  static const int visibleRows = 8;

  @override
  State<_CommandHelpCard> createState() => _CommandHelpCardState();
}

class _CommandHelpCardState extends State<_CommandHelpCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = widget.help.items;
    final folded = !_expanded && items.length > _CommandHelpCard.visibleRows;
    final shown = folded ? items.take(_CommandHelpCard.visibleRows) : items;
    final intro = widget.help.intro;
    // 卡片底色只借一点前景色，右侧主色底与左侧中性底都成立；描边把卡片从气泡底上分出来。
    final fill = widget.foreground;
    return Container(
      // 卡片自己再夹一道：气泡本身已是 86% 宽，这里不额外撑宽，两侧都只占内容宽度。
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * MessageView._maxWidthRatio),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: fill.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: fill.withValues(alpha: 0.14)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: [
          if (intro.isNotEmpty)
            Text(
              intro,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.4, color: widget.muted),
            ),
          for (final item in shown)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.command,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                    color: widget.commandColor,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.desc,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      height: 1.35,
                      color: widget.foreground,
                    ),
                  ),
                ),
              ],
            ),
          if (folded || _expanded)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    _expanded ? '收起' : '展开全部 ${items.length} 条',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: widget.muted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 富媒体地址解析，markdown 图片与平台消息媒体共用同一套规则：
/// 绝对 `http(s)` / `data:` / `base64:` 原样使用；`/files/` 是实例静态附件（不需要 Bearer）；
/// 其余相对路径是 agent 工作区（data/chatluna/agents-work）里的文件，由 companion 插件以 Bearer 提供。
Uri _resolveAsset(Uri base, String url) {
  if (url.startsWith('http://') || url.startsWith('https://')) {
    return Uri.parse(url);
  }
  if (url.startsWith('data:')) {
    // `Uri.parse` 会校验 data URI 的 base64 载荷：坏载荷直接抛 `FormatException`，
    // 一条画不出来的图不该把整条消息炸掉。退回不透明 URI，交给占位（「无法解码」）兜住。
    return Uri.tryParse(url) ?? Uri(scheme: 'data', path: 'invalid');
  }
  // `base64://` 的载荷在调用处已经归一成 `data:`；万一漏进来，只当它是一个不透明 URI。
  if (url.startsWith('base64:')) return Uri(scheme: 'base64', path: url);
  // 实例内绝对路径：静态附件与插件自带路由（`/api/platform/media/...`）。
  if (url.startsWith('/files/') || url.startsWith('/api/')) return base.resolve(url.substring(1));
  final name = url.startsWith('/') ? url.substring(1) : url;
  return base.replace(path: '/api/workspace', queryParameters: {'path': name});
}

/// 图片请求要不要带实例的 Bearer：只有解回本实例的 `/files` 与工作区需要。
/// 插件给的外部图床不能收到我们的 token。
bool _needsAuth(Uri base, Uri uri) =>
    uri.host == base.host &&
    uri.port == base.port &&
    (uri.path.startsWith('/files/') || uri.path.startsWith('/api/'));

/// 媒体图片的取头：先把源归一成真实地址（`base64://` → `data:`），再决定要不要带 Bearer。
Map<String, String> _authHeadersFor(Uri base, String raw, Map<String, String> headers) {
  final uri = _resolveAsset(base, _ChatImage._normalizeSource(raw));
  return _needsAuth(base, uri) ? headers : const <String, String>{};
}

/// 正文占位文案：插件在「没有文字、只有媒体」时写的就是这些。
final RegExp _mediaPlaceholder = RegExp(
  r'\[\s*(?:图片|照片|截图|视频|视频消息|语音|语音消息|音频|文件|表情|动画表情|贴图|贴纸|引用|卡片|小程序|未知消息)\s*\]',
);
final RegExp _placeholderPunctuation = RegExp(r'[\s\.,，。、;;；:：!！?？~～\-—_|*（）()【】\[\]]+');

/// 去掉占位文案与标点后什么都不剩 = 正文本来只是媒体的旁白，跳过它。
bool _placeholderOnly(String text) {
  if (!_mediaPlaceholder.hasMatch(text)) return false;
  final rest = text.replaceAll(_mediaPlaceholder, '').replaceAll(_placeholderPunctuation, '');
  return rest.isEmpty;
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

  /// 重试前重新挂一次测量：上一次失败的那条 stream 已经死了，不清掉 `_measured`
  /// 就不会重新解析；尺寸先留着，重试期间不跳版。
  void _remeasure() {
    _detach();
    _measured = null;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    final uri = widget.resolve(source);
    final bytes = _bytes;
    // 声明了 data URI 却解不出来：直接给占位，别让 Image.network 抛 unsupported scheme。
    final broken = source.startsWith('data:') && bytes == null;

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
    final double width = broken ? 200 : size.width;
    final double height = broken ? 120 : size.height;
    final image = _ImageSource(source: source, uri: uri, headers: widget.headers, bytes: bytes);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: GestureDetector(
        onTap: broken
            ? null
            : () => showDialog<void>(
                context: context,
                builder: (_) => _ImageViewer(images: [image], initialIndex: 0),
              ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          // 显式尺寸：WidgetSpan 的高度约束不可靠，这里不再依赖父级 maxHeight。
          child: SizedBox(
            width: width,
            height: height,
            // 取图/失败/重试都交给同一个壳：点占位就 evict + 换 key 重来。
            child: _RetryableImage(
              source: image,
              width: width,
              height: height,
              cacheWidth: _cacheWidth(context),
              onAttempt: _remeasure,
            ),
          ),
        ),
      ),
    );
  }
}

/// 媒体图片的取源结果：`base64://` / `data:` 解成内存字节，其余按 URL 解析。
/// base64 只在源列表变化时解一次（每次 build 重建 Uint8List 会让 ImageCache 全部落空）。
class _ImageSource {
  const _ImageSource({required this.source, required this.uri, required this.headers, this.bytes});

  factory _ImageSource.of(String raw, {required Uri base, required Map<String, String> headers}) {
    final source = _ChatImage._normalizeSource(raw);
    return _ImageSource(
      source: source,
      uri: _resolveAsset(base, source),
      // 外部图床不该收到实例 token：只有解回本实例 `/files` 与工作区时才带头。
      headers: _authHeadersFor(base, source, headers),
      bytes: _ChatImage._inlineBytes(source),
    );
  }

  final String source;
  final Uri uri;
  final Map<String, String> headers;
  final Uint8List? bytes;

  /// 声明了 data URI 却解不出来：直接给占位，别让 `Image.network` 抛 unsupported scheme。
  bool get broken => source.startsWith('data:') && bytes == null;
}

/// 一张图（网络或内存）的取图壳：失败先自动重试一次，之后停在「点击重试」。
/// 单图缩略、网格格子、全屏查看三处共用，重试行为因此完全一致。
///
/// 重试要两件事一起做，缺一不可：
///   1. `evict()` 掉这份 provider（连 `ResizeImage` 那层包装一起）——失败的请求可能还挂在
///      `ImageCache` 的 pending/live 表里，不踢掉的话下一次解析拿到的还是同一份失败；
///   2. 给 `Image` 换一个 key（`ValueKey('$url#$attempt')`）——同一个 key 的 `_ImageState`
///      会把上一次的 `_lastException` 一直留着，换 key 才会重新解析 provider。
class _RetryableImage extends StatefulWidget {
  const _RetryableImage({
    required this.source,
    this.width,
    this.height,
    this.cacheWidth,
    this.fit = BoxFit.cover,
    this.compact = false,
    this.onDark = false,
    this.onAttempt,
  });

  final _ImageSource source;

  /// 展示尺寸：缩略图与网格格子给死；全屏查看不给，由父级撑开。
  final double? width;
  final double? height;

  /// 解码宽度：与 `Image.network(cacheWidth:)` 解到同一份缓存。
  final int? cacheWidth;

  final BoxFit fit;

  /// 网格格子只有几十像素宽：文案缩成两行小字，整块随格子等比缩小。
  final bool compact;

  /// 全屏查看是黑底：占位、转圈与文案都不跟主题的中性色走。
  final bool onDark;

  /// 每次开始新一次尝试（含自动重试）时回调：单图缩略要重新测量解码尺寸。
  final VoidCallback? onAttempt;

  @override
  State<_RetryableImage> createState() => _RetryableImageState();
}

class _RetryableImageState extends State<_RetryableImage> {
  /// 首次失败后隔 2s 自动再试一次：慢网下第一发常常正好卡在超时上，隔一下再发多半就通；
  /// 再失败就停住，等人点。只自动试一次，不会无限重连。
  static const Duration _autoRetryDelay = Duration(seconds: 2);

  /// 第几次尝试：既进 `Image` 的 key，也记着自动重试用掉没有。
  int _attempt = 0;

  /// 自动重试只挂一次；`errorBuilder` 每次重建都会被调用，得挡住重复挂表。
  bool _autoRetryUsed = false;
  Timer? _timer;

  ImageProvider get _baseProvider => widget.source.bytes != null
      ? MemoryImage(widget.source.bytes!)
      : NetworkImage(widget.source.uri.toString(), headers: widget.source.headers);

  /// `Image` 的 key：换 key 等于换一个 `_ImageState`，它才会重新解析 provider。
  /// 内存图的源可能是一整段 base64，key 里只放字节对象的身份，别把几 MB 塞进去。
  ValueKey<String> get _imageKey {
    final source = widget.source;
    final tag = source.bytes != null
        ? 'bytes:${identityHashCode(source.bytes)}'
        : source.uri.toString();
    return ValueKey<String>('$tag#$_attempt');
  }

  @override
  void didUpdateWidget(covariant _RetryableImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.source != widget.source.source) {
      _timer?.cancel();
      _timer = null;
      _autoRetryUsed = false;
      _attempt = 0;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 失败之后挂上自动重试。从 `errorBuilder` 里调用，所以这里不能 setState。
  void _afterFailure() {
    // 内存图解码失败是定局（字节就是那样），隔 2s 再来一次不会变好，直接留给手动重试。
    if (widget.source.bytes != null || _autoRetryUsed) return;
    _autoRetryUsed = true;
    _timer = Timer(_autoRetryDelay, _retry);
  }

  /// 手动/自动重试：先 evict 掉这份失败的缓存与 pending 请求，再换 key 重建 `Image`。
  Future<void> _retry() async {
    _timer?.cancel();
    _timer = null;
    if (!mounted) return;
    final base = _baseProvider;
    await base.evict();
    final cacheWidth = widget.cacheWidth;
    if (cacheWidth != null) {
      // 展示时用的就是 `ResizeImage` 包过的 key，这份也要踢。
      await ResizeImage(base, width: cacheWidth).evict();
    }
    if (!mounted) return;
    // 缓存清干净了才能让外面重新解析：先 evict 再回调，别让它又挂到那份失败的 completer 上。
    widget.onAttempt?.call();
    setState(() => _attempt++);
  }

  @override
  Widget build(BuildContext context) {
    // data:/base64: 声明成图片却解不出来：没有网络请求可重试，只报解码失败。
    if (widget.source.broken) {
      return _notice(context, label: '无法解码', icon: Icons.broken_image_outlined);
    }

    final bytes = widget.source.bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        key: _imageKey,
        width: widget.width,
        height: widget.height,
        cacheWidth: widget.cacheWidth,
        fit: widget.fit,
        frameBuilder: _frame,
        errorBuilder: (context, _, _) => _failure(context),
      );
    }
    return Image.network(
      widget.source.uri.toString(),
      key: _imageKey,
      headers: widget.source.headers,
      width: widget.width,
      height: widget.height,
      cacheWidth: widget.cacheWidth,
      fit: widget.fit,
      frameBuilder: _frame,
      errorBuilder: (context, _, _) => _failure(context),
    );
  }

  /// 还没解出第一帧就自己画转圈：`loadingBuilder` 的 progress 在收到第一段字节之前是 null，
  /// 光靠它，慢网下这一段是空白，重试时也看不出「正在重试」。
  Widget _frame(BuildContext context, Widget child, int? frame, bool wasSynchronouslyLoaded) {
    if (frame != null || wasSynchronouslyLoaded) return child;
    return Container(
      width: widget.width,
      height: widget.height,
      alignment: Alignment.center,
      color: _background(context),
      child: SizedBox.square(
        dimension: widget.compact ? 16 : 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: widget.onDark ? Colors.white70 : null,
        ),
      ),
    );
  }

  Widget _failure(BuildContext context) {
    _afterFailure();
    return _notice(
      context,
      label: widget.compact ? '图片加载失败\n点击重试' : '图片加载失败 · 点击重试',
      icon: Icons.refresh,
      onTap: _retry,
    );
  }

  Color _background(BuildContext context) =>
      widget.onDark ? Colors.black : Theme.of(context).colorScheme.surfaceContainerHighest;

  /// 占位：图标 + 一行字。给了 `onTap` 才是可点的重试态（没给就是「无法解码」）。
  Widget _notice(
    BuildContext context, {
    required String label,
    required IconData icon,
    VoidCallback? onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final color = onTap == null
        ? (widget.onDark ? Colors.white70 : scheme.onSurfaceVariant)
        : (widget.onDark ? Colors.white : scheme.primary);
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: widget.compact ? 18 : 22, color: color),
        const SizedBox(height: 4),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: widget.compact ? 10 : 12, height: 1.25, color: color),
        ),
      ],
    );
    final box = Container(
      width: widget.width,
      height: widget.height,
      // 全屏查看没有固定尺寸：给一块够点的热区，别只剩两行字。
      constraints: widget.width == null || widget.height == null
          ? const BoxConstraints(minWidth: 132, minHeight: 96)
          : null,
      color: _background(context),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(6),
      // 格子可能只有几十像素宽：整块等比缩小，不换行、不溢出。
      child: FittedBox(fit: BoxFit.scaleDown, child: content),
    );
    if (onTap == null) return box;
    return GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: box);
  }
}

/// 一条消息的媒体区：图片先成组（单张缩略 / 多张网格），视频/音频/文件按原顺序排成胶囊。
/// 颜色跟随气泡前景，右侧主色底与左侧中性底都能读。
class _MediaBlock extends StatelessWidget {
  const _MediaBlock({
    super.key,
    required this.media,
    required this.base,
    required this.headers,
    required this.foreground,
    required this.muted,
  });

  final List<PlatformMedia> media;
  final Uri base;
  final Map<String, String> headers;
  final Color foreground;
  final Color muted;

  static const double _gap = 6;

  @override
  Widget build(BuildContext context) {
    // `storage://<id>` 引用在日志侧只给 ref；它能通过 `/files/<id>` 取到像素，所以按图片渲染。
    String? imageUrlOf(PlatformMedia item) {
      if (!item.isImage) return null;
      if (item.url != null && item.url!.isNotEmpty) return item.url;
      var ref = item.ref;
      if (ref == null || ref.isEmpty) return null;
      // 日志侧引用形如 `storage://<id>`，实例按 id 暴露在 `/files/<id>`。
      if (ref.startsWith('storage://')) ref = ref.substring('storage://'.length);
      return '/files/${Uri.encodeComponent(ref)}';
    }

    final imageUrls = [
      for (final item in media) ?imageUrlOf(item),
    ];
    final rest = [
      for (final item in media)
        if (imageUrlOf(item) == null) item,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (imageUrls.length == 1)
          _ChatImage(
            url: imageUrls.first,
            resolve: (url) => _resolveAsset(base, url),
            headers: _authHeadersFor(base, imageUrls.first, headers),
          )
        else if (imageUrls.length > 1)
          _ImageGrid(urls: imageUrls, base: base, headers: headers),
        for (var i = 0; i < rest.length; i++) ...[
          if (i > 0) const SizedBox(height: _gap),
          _MediaPill(item: rest[i], base: base, foreground: foreground, muted: muted),
        ],
      ],
    );
  }
}

/// 多张图片：**2 列网格**，格子间距 6，格子按可用宽度均分、最大 168（平板上一格不至于半屏）。
/// 每格上边圆角 12；非末行下边收 4，上下两格拼起来像一整块，末行下边再回到 12。
/// 点任意一格进全屏，PageView 从这一张开始左右滑动，多图点击因此对得上号。
class _ImageGrid extends StatefulWidget {
  const _ImageGrid({required this.urls, required this.base, required this.headers});

  final List<String> urls;
  final Uri base;
  final Map<String, String> headers;

  @override
  State<_ImageGrid> createState() => _ImageGridState();
}

class _ImageGridState extends State<_ImageGrid> {
  static const double _gap = 6;
  static const double _maxCell = 168;
  static const int _columns = 2;
  static const double _fallbackWidth = _maxCell * _columns + _gap;

  late List<_ImageSource> _sources = _decode();

  @override
  void didUpdateWidget(covariant _ImageGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameUrls(oldWidget.urls, widget.urls)) _sources = _decode();
  }

  List<_ImageSource> _decode() => [
    for (final url in widget.urls)
      _ImageSource.of(url, base: widget.base, headers: widget.headers),
  ];

  static bool _sameUrls(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final available = constraints.maxWidth.isFinite && constraints.maxWidth > 0
              ? constraints.maxWidth
              : _fallbackWidth;
          final side = math.min((available - _gap) / _columns, _maxCell);
          final rows = <Widget>[];
          for (var start = 0; start < _sources.length; start += _columns) {
            final end = math.min(start + _columns, _sources.length);
            rows.add(
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = start; i < end; i++) ...[
                    if (i > start) const SizedBox(width: _gap),
                    _cell(context, i, side, lastRow: end == _sources.length),
                  ],
                ],
              ),
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const SizedBox(height: _gap),
                rows[i],
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _cell(BuildContext context, int index, double side, {required bool lastRow}) {
    return GestureDetector(
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => _ImageViewer(images: _sources, initialIndex: index),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.vertical(
          top: const Radius.circular(12),
          bottom: Radius.circular(lastRow ? 12 : 4),
        ),
        // 格子里的图同样走重试壳：按格子宽度解码，失败后点一下就重来。
        child: SizedBox.square(
          dimension: side,
          child: _RetryableImage(
            source: _sources[index],
            width: side,
            height: side,
            cacheWidth: (side * MediaQuery.devicePixelRatioOf(context)).round(),
            compact: true,
          ),
        ),
      ),
    );
  }
}

/// 全屏查看：多图左右滑动、双指缩放；单张图也走这里（只有一个 page 的 pager），
/// 因此缩略图与网格共用一个查看器，行为一致。
class _ImageViewer extends StatefulWidget {
  const _ImageViewer({required this.images, required this.initialIndex});

  final List<_ImageSource> images;
  final int initialIndex;

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  late final PageController _controller = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final images = widget.images;
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(
            child: PageView.builder(
              controller: _controller,
              itemCount: images.length,
              onPageChanged: (index) => setState(() => _index = index),
              itemBuilder: (context, index) =>
                  InteractiveViewer(child: Center(child: _page(images[index]))),
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
          if (images.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    child: Text(
                      '${_index + 1} / ${images.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 全屏页与缩略图/格子走同一个重试壳：失败也能点一下重来，不靠退回消息列表。
  Widget _page(_ImageSource image) =>
      _RetryableImage(source: image, fit: BoxFit.contain, onDark: true);
}

/// 视频 / 音频 / 文件 / 只有 ref 的附件：一行胶囊（图标 + 名称）。
/// 点：能交给系统的地址（外部 `http(s)`、实例静态附件 `/files/`）就地打开，
/// 其余（工作区文件要 Bearer、data/base64 载荷、只有 ref）复制链接；长按总是复制。
/// 只有 ref 时胶囊用描边而不是填充，视觉上区分「打不开，只能复制」。
class _MediaPill extends StatelessWidget {
  const _MediaPill({
    required this.item,
    required this.base,
    required this.foreground,
    required this.muted,
  });

  final PlatformMedia item;
  final Uri base;
  final Color foreground;
  final Color muted;

  static const double _radius = 18;

  IconData get _icon => switch (item.kind) {
    'video' => Icons.play_circle_outline,
    'audio' => Icons.graphic_eq,
    'image' => Icons.image_outlined,
    _ => Icons.insert_drive_file_outlined,
  };

  /// 能直接交给系统浏览器/播放器的地址：外部 `http(s)` 与实例静态附件 `/files/`。
  /// 工作区文件要带 Bearer，系统拿不到 token，只能复制。
  Uri? get _openable {
    final url = item.url;
    if (url == null || url.startsWith('data:') || url.startsWith('base64:')) return null;
    final uri = _resolveAsset(base, url);
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri.path == '/api/workspace' ? null : uri;
  }

  /// 复制内容：优先真实地址（相对路径先解成实例地址）；data/base64 载荷太长没有复制意义，
  /// 退回引用或文件名。
  String get _copyText {
    final url = item.url;
    if (url != null && !url.startsWith('data:') && !url.startsWith('base64:')) {
      return _resolveAsset(base, url).toString();
    }
    return item.ref ?? item.label;
  }

  Future<void> _activate(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = _openable;
    if (uri != null) {
      try {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
      } on Exception {
        // 没有可用的外部处理程序：退回复制，别让点击变成没反馈。
      }
    }
    await _copy(messenger);
  }

  Future<void> _copy(ScaffoldMessengerState messenger) async {
    await Clipboard.setData(ClipboardData(text: _copyText));
    messenger.showSnackBar(const SnackBar(content: Text('已复制链接')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final refOnly = item.url == null;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => _activate(context),
        onLongPress: () => _copy(ScaffoldMessenger.of(context)),
        borderRadius: BorderRadius.circular(_radius),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
          decoration: BoxDecoration(
            color: refOnly ? null : foreground.withValues(alpha: 0.14),
            border: refOnly ? Border.all(color: foreground.withValues(alpha: 0.3)) : null,
            borderRadius: BorderRadius.circular(_radius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_icon, size: 16, color: foreground),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(color: foreground),
                ),
              ),
              const SizedBox(width: 6),
              Icon(refOnly ? Icons.content_copy : Icons.open_in_new, size: 13, color: muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// 框架消息卡片：详情页把日志里的 wake / memory / 工具摘要插回时间线时用它。
/// 与 [MessageView] 内部的框架分支是同一张卡，这里只负责暴露出去。
class FrameworkNoticeCard extends StatelessWidget {
  const FrameworkNoticeCard({
    super.key,
    required this.foldKey,
    required this.text,
    required this.open,
    this.count = 1,
  });

  /// 折叠状态的键：消息 id。
  final String foldKey;
  final String text;

  /// 页面级 `Map<String, bool>`：折叠键 → 是否展开；缺省即折叠。
  final Map<String, bool> open;
  final int count;

  @override
  Widget build(BuildContext context) =>
      _FrameworkNotice(foldKey: foldKey, text: text, open: open, count: count);
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
  const Notice(this.title, this.lines, {this.tag = ''});

  /// 标题：首行以 `[xxx]` 开头时是 `[xxx]` + 紧随其后的一小段文字；
  /// 首行没有结构头时取前 24 字做预览标题。
  final String title;

  /// 正文行：`[xxx]` 结构头不进正文；`[xxx] 尾巴` 只去掉 `[xxx]`、尾巴留在正文首行，
  /// 避免标题与第一行预览重复。`---` 分隔线只做视觉标记；
  /// 没有结构头的首行只当标题预览，展开时正文仍保留它。
  final List<String> lines;

  /// 结构标签（`[xxx]` 含方括号）；首行不是结构头时为空串。
  /// 合并分组用它当类型：`[memory update]` 与 `[memory update] Memory lines…` 属同一类型。
  final String tag;

  /// 无结构头时标题取的字符数。
  static const _titleChars = 24;

  /// 结构头之后标题补充的字数：够认人，又不挤爆卡片头。
  static const _tagTailChars = 18;

  static final _bracketHead = RegExp(r'^(\[[^\]]+\])\s*(.*)$');
  static final _rule = RegExp(r'^(-{3,}|\*{3,}|_{3,})$');
  static final _url = RegExp(r'^https?://\S+$');
  static final _space = RegExp(r'\s+');

  /// 归一化合并键：忽略大小写与空白差异，`[Memory Update]` 与 `[memory update]` 同组。
  /// 页面层用它把结构标签（或标题）变成比较用的键；只有带标签的框架消息才参与合并。
  static String key(String title) => title.toLowerCase().replaceAll(_space, '');

  /// 结构化解析：首行 `[xxx]`（可带尾巴）抽成标题，否则取首行前 24 字；其余行是正文。
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
    final head = _bracketHead.firstMatch(first);
    if (head != null) {
      final tag = head.group(1)!;
      final tail = head.group(2)!.trim();
      // `[memory update]`：整行就是结构头，标题即标签，正文从第二行起。
      if (tail.isEmpty) return Notice(tag, _trimTrailing(rest.sublist(1)), tag: tag);
      // `[memory update] Memory lines not shown…`：标题 = 标签 + 一小段尾巴，
      // 正文首行只保留尾巴（去掉 `[tag]` 前缀），预览里不再重复标签。
      return Notice(
        '$tag ${_clipTail(tail)}',
        _trimTrailing([tail, ...rest.sublist(1)]),
        tag: tag,
      );
    }
    return Notice(_clip(first), rest);
  }

  static String _clip(String text) =>
      text.length <= _titleChars ? text : '${text.substring(0, _titleChars)}…';

  /// 标签后的尾巴按词截断（不留半个词）；尾巴本身很短时原样保留。
  static String _clipTail(String text) {
    if (text.length <= _tagTailChars) return text;
    final cut = text.substring(0, _tagTailChars);
    final space = cut.lastIndexOf(' ');
    return '${(space >= 6 ? cut.substring(0, space) : cut).trimRight()}…';
  }

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
