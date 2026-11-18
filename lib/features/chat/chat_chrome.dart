import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/model/models.dart';
import 'assistant_avatar.dart';

/// 会话名的紧凑解析结果：可读短名 + 用于区分的 id 尾号。
///
/// 规则（只认 `qq ` 前缀，其余平台原样保留）：
/// - `qq 私聊 <openid>` → 「私聊」+ openid 尾 6 位
/// - `qq <群号>/<频道>` → 「群聊」+ 标识符尾 6 位
/// - 其余（含非 qq 与无法识别的 qq 形态）→ 原名
class SessionTitle {
  const SessionTitle({required this.label, this.tail});

  final String label;
  final String? tail;

  String get compact => tail == null ? label : '$label · $tail';
}

const int _tailLength = 6;
const String _qqPrefix = 'qq ';

final RegExp _nonIdentifier = RegExp(r'[^0-9A-Za-z_-]');

SessionTitle parseSessionTitle(String raw) {
  final title = raw.trim();
  if (title.length <= _qqPrefix.length ||
      title.substring(0, _qqPrefix.length).toLowerCase() != _qqPrefix) {
    return SessionTitle(label: title.isEmpty ? raw : title);
  }
  final rest = title.substring(_qqPrefix.length).trim();
  if (rest.startsWith('私聊') || rest.startsWith('群聊')) {
    final isGroup = rest.startsWith('群聊');
    return SessionTitle(
      label: isGroup ? '群聊' : '私聊',
      tail: _tailOf(rest.substring(2).trim()),
    );
  }
  if (rest.contains('/')) {
    return SessionTitle(label: '群聊', tail: _tailOfPath(rest));
  }
  return SessionTitle(label: title);
}

/// `群号/频道` 里任一段都可能是中文名，倒着找第一个带标识符的段取尾号。
String? _tailOfPath(String path) {
  for (final segment in path.split('/').reversed) {
    final tail = _tailOf(segment);
    if (tail != null) return tail;
  }
  return null;
}

String? _tailOf(String raw) {
  final id = raw.replaceAll(_nonIdentifier, '');
  if (id.isEmpty) return null;
  return id.length <= _tailLength ? id : id.substring(id.length - _tailLength);
}

/// AppBar 标题：短名 + 展开箭头，点击露出完整原名与会话详情。
class ChatTitle extends StatelessWidget {
  const ChatTitle({super.key, required this.title, required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final parsed = parseSessionTitle(title);
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: '${parsed.compact}，点击查看完整名称',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: parsed.label),
                      if (parsed.tail != null)
                        TextSpan(
                          text: '  ${parsed.tail}',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            letterSpacing: 0.6,
                          ),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.expand_more,
                size: 18,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 会话信息栏：一行可横向滚动的轻量 pills，不再用整条灰底色块。
class ChatInfoBar extends StatelessWidget {
  const ChatInfoBar({
    super.key,
    required this.session,
    required this.running,
    required this.liveOk,
    this.botName,
    this.avatarUrl,
    this.debugMetrics = const [],
  });

  final SessionSummary session;
  final bool running;
  final bool liveOk;
  final String? botName;
  final String? avatarUrl;
  final List<String> debugMetrics;

  @override
  Widget build(BuildContext context) {
    final model = session.model;
    final name = botName?.trim();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 1, 16, 5),
      child: Row(
        spacing: 6,
        children: [
          if (name != null && name.isNotEmpty)
            _InfoPill(
              label: name,
              leading: AssistantAvatar(size: 16, imageUrl: avatarUrl),
            ),
          if (session.origin.isNotEmpty) _InfoPill(label: session.origin),
          if (session.engine.isNotEmpty) _InfoPill(label: session.engine),
          if (model != null)
            _InfoPill(
              label: _shortModel(model),
              onTap: () => showSessionDetails(context, session),
            ),
          if (running) const _RunningPill(),
          if (!liveOk)
            const _InfoPill(
              label: '轮询中',
              icon: Icons.cloud_off_outlined,
              tone: _PillTone.warning,
            ),
          for (final metric in debugMetrics)
            _InfoPill(label: metric, tone: _PillTone.muted),
        ],
      ),
    );
  }
}

/// 模型只显示最后一段（`provider/model`、`provider:model` 都取尾段），点开看全名。
String _shortModel(ModelRef ref) {
  final name = ref.model.trim();
  var cut = name.lastIndexOf('/');
  final colon = name.lastIndexOf(':');
  if (colon > cut) cut = colon;
  if (cut < 0 || cut >= name.length - 1) return name.isEmpty ? '模型' : name;
  return name.substring(cut + 1);
}

enum _PillTone { neutral, muted, warning }

class _InfoPill extends StatelessWidget {
  const _InfoPill({
    required this.label,
    this.icon,
    this.leading,
    this.onTap,
    this.tone = _PillTone.neutral,
  });

  final String label;
  final IconData? icon;
  final Widget? leading;
  final VoidCallback? onTap;
  final _PillTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (Color fill, Color foreground) = switch (tone) {
      _PillTone.neutral => (
        scheme.surfaceContainerHighest.withValues(alpha: 0.38),
        scheme.onSurfaceVariant,
      ),
      _PillTone.muted => (Colors.transparent, scheme.onSurfaceVariant.withValues(alpha: 0.6)),
      _PillTone.warning => (scheme.errorContainer.withValues(alpha: 0.3), scheme.error),
    };
    return _PillSurface(
      fill: fill,
      onTap: onTap,
      padding: EdgeInsets.fromLTRB(leading != null ? 3 : 9, 3, 9, 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 5)],
          if (icon != null) ...[Icon(icon, size: 13, color: foreground), const SizedBox(width: 4)],
          Text(
            label,
            maxLines: 1,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 11,
              height: 1.2,
              letterSpacing: 0.2,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}

/// 运行中：低饱和胶囊 + 呼吸圆点，不抢消息区的注意力。
class _RunningPill extends StatelessWidget {
  const _RunningPill();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _PillSurface(
      fill: scheme.primary.withValues(alpha: 0.15),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PulseDot(color: scheme.primary),
          const SizedBox(width: 5),
          Text(
            '运行中',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 11,
              height: 1.2,
              letterSpacing: 0.2,
              color: scheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.color});

  final Color color;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  late final Animation<double> _opacity = Tween<double>(begin: 0.28, end: 1).animate(
    CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SizedBox(
        width: 6,
        height: 6,
        child: DecoratedBox(
          decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class _PillSurface extends StatelessWidget {
  const _PillSurface({
    required this.child,
    required this.fill,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
  });

  final Widget child;
  final Color fill;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: fill,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// 完整原名 + ID / 平台 / 引擎 / 模型，每行点击即复制。
Future<void> showSessionDetails(BuildContext context, SessionSummary session) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _SessionDetailsSheet(session: session),
  );
}

class _SessionDetailsSheet extends StatelessWidget {
  const _SessionDetailsSheet({required this.session});

  final SessionSummary session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final model = session.model;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text('会话详情', style: theme.textTheme.titleMedium)),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    tooltip: '关闭',
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '完整名称',
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: SelectableText(
                  session.title,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                ),
              ),
              const SizedBox(height: 12),
              Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
              _CopyRow(label: '会话 ID', value: session.id),
              _CopyRow(label: '平台', value: session.origin),
              if (session.engine.isNotEmpty) _CopyRow(label: '引擎', value: session.engine),
              if (model != null) _CopyRow(label: '模型', value: model.toString()),
            ],
          ),
        ),
      ),
    );
  }
}

class _CopyRow extends StatefulWidget {
  const _CopyRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  State<_CopyRow> createState() => _CopyRowState();
}

class _CopyRowState extends State<_CopyRow> {
  Timer? _reset;
  bool _copied = false;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.value));
    if (!mounted) return;
    HapticFeedback.selectionClick();
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: _copy,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 64,
              child: Text(
                widget.label,
                style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: Text(
                widget.value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              _copied ? Icons.check : Icons.copy_rounded,
              size: 16,
              color: _copied
                  ? scheme.primary
                  : scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ],
        ),
      ),
    );
  }
}
