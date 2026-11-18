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

    if (message.isNotice) {
      return _ExpandableNotice(text: body);
    }

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
          child: SelectableText(
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
    final name = url.startsWith('/') ? url.substring(1) : url;
    // 相对路径是 agent 工作区（data/chatluna/agents-work）里的文件，由 companion 插件以 Bearer 提供。
    return base.replace(path: '/api/workspace', queryParameters: {'path': name});
  }
}

class _ChatImage extends StatelessWidget {
  const _ChatImage({required this.url, required this.resolve, required this.headers});

  final String url;
  final Uri Function(String) resolve;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final uri = resolve(url);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: GestureDetector(
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => Dialog.fullscreen(
            backgroundColor: Colors.black,
            child: Stack(
              children: [
                Positioned.fill(
                  child: InteractiveViewer(
                    child: Image.network(uri.toString(), fit: BoxFit.contain, headers: headers),
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
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280, maxHeight: 360),
            child: Image.network(
              uri.toString(),
              headers: headers,
              cacheWidth: 560,
              fit: BoxFit.cover,
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : Container(
                      width: 200,
                      height: 140,
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: const Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
              errorBuilder: (context, error, stack) => Container(
                width: 200,
                height: 120,
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
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 引擎注入的内部消息（如 `[memory update]`）：默认收成两行，点开看全文。
class _ExpandableNotice extends StatefulWidget {
  const _ExpandableNotice({required this.text});

  final String text;

  @override
  State<_ExpandableNotice> createState() => _ExpandableNoticeState();
}

class _ExpandableNoticeState extends State<_ExpandableNotice> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
      height: 1.4,
    );
    return InkWell(
      onTap: () => setState(() => _open = !_open),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: Text(
                widget.text,
                textAlign: TextAlign.center,
                maxLines: _open ? null : 2,
                overflow: _open ? TextOverflow.clip : TextOverflow.ellipsis,
                style: style,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              _open ? Icons.expand_less : Icons.expand_more,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
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
