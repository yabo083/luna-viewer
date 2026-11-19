import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/design/app_tokens.dart';
import '../../core/model/models.dart';
import '../../core/transport/state_socket.dart';
import 'assistant_avatar.dart';
import 'turn_clock.dart';

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

/// 信息栏常驻状态灯：四种状态共用同一枚胶囊（[_PillSurface]，24dp 高、999 圆角），
/// 只有圆点颜色与底色档位随状态变化，呼吸动画只在 [StatusLight.thinking] 时挂载。
enum StatusLight {
  /// 待机：`textTertiary` 静态点 + 中性底色，文字 `textSecondary` —— 安静但不消失。
  idle('待机'),

  /// 思考中：`accent@12%` 底 + `accent@30%` 描边，主色圆点 1100ms 呼吸。
  thinking('思考中'),

  /// 回复中：与思考中同一块底与描边，主色静态实心圆点，不抢正文的注意力。
  replying('回复中'),

  /// 轮询中：`/live` 掉线，3s 轮询接管；`statusError@12%` 底 + 静态错误色点。
  polling('轮询中');

  const StatusLight(this.label);

  final String label;
}

/// 会话信息栏：一行可横向滚动的轻量 pills，不再用整条灰底色块。
class ChatInfoBar extends StatelessWidget {
  const ChatInfoBar({
    super.key,
    required this.session,
    required this.light,
    this.botName,
    this.avatarUrl,
    this.debugMetrics = const [],
    this.showDeveloperInfo = false,
    this.onModelTap,
    this.turnClock,
    this.onTurnPhases,
  });

  final SessionSummary session;

  /// 常驻状态灯：待机也留一盏静灯，用户随时能确认会话没有卡住。
  final StatusLight light;

  final String? botName;
  final String? avatarUrl;
  final List<String> debugMetrics;

  /// 开发者信息（平台 / 引擎 / 计时）默认隐藏，由设置里的开关打开。
  /// 轮询状态不在这里：它由常驻状态灯始终显示。
  final bool showDeveloperInfo;
  final VoidCallback? onModelTap;

  /// 本轮计时表（骨架同一个 notifier）：有读数时信息栏多一枚可点的耗时胶囊，
  /// 骨架撤场后仍能从信息栏翻看本轮/上一轮的阶段明细。
  final ValueListenable<TurnClockView?>? turnClock;
  final ValueChanged<TurnClockView>? onTurnPhases;

  @override
  Widget build(BuildContext context) {
    final model = session.model;
    final name = botName?.trim();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(Space.x16, Space.x4, Space.x16, Space.x8),
      child: Row(
        spacing: _PillSurface.gap,
        children: [
          if (name != null && name.isNotEmpty)
            _InfoPill(
              label: name,
              leading: AssistantAvatar(
                size: _PillSurface.contentHeight,
                imageUrl: avatarUrl,
              ),
            ),
          if (showDeveloperInfo) ...[
            if (session.origin.isNotEmpty) _InfoPill(label: session.origin),
            if (session.engine.isNotEmpty) _InfoPill(label: session.engine),
          ],
          if (model != null)
            _InfoPill(
              label: shortModelLabel(model),
              onTap: onModelTap ?? () => showSessionDetails(context, session),
            )
          else if (onModelTap != null)
            _InfoPill(
              label: '模型',
              icon: Icons.memory_outlined,
              onTap: onModelTap,
            ),
          _StatusPill(light: light),
          if (turnClock case final clock? when clock.value != null)
            _TurnPill(clock: clock, onTap: onTurnPhases),
          if (showDeveloperInfo)
            for (final metric in debugMetrics) _InfoPill(label: metric),
        ],
      ),
    );
  }
}

/// 未加载会话的轻量信息栏：`bot 名 · 平台 · 未加载`。
/// 这里刻意没有动画与状态灯语义——服务端还没有这个会话的 agent，
/// 任何「思考中 / 回复中」都是假的；等它被加载后由 [ChatInfoBar] 接管。
class ChatUnloadedBar extends StatelessWidget {
  const ChatUnloadedBar({super.key, this.botName, this.avatarUrl, this.origin = ''});

  final String? botName;
  final String? avatarUrl;

  /// 平台名（`qq` 等）：插件会话键自带的平台，不依赖 `/api/sessions`。
  final String origin;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final name = botName?.trim() ?? '';
    final platform = origin.trim();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(Space.x16, Space.x4, Space.x16, Space.x8),
      child: Row(
        spacing: _PillSurface.gap,
        children: [
          if (name.isNotEmpty)
            _InfoPill(
              label: name,
              leading: AssistantAvatar(
                size: _PillSurface.contentHeight,
                imageUrl: avatarUrl,
              ),
            ),
          if (platform.isNotEmpty) _InfoPill(label: platform),
          _PillSurface(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: _PillSurface.gap,
              children: [
                _Dot(color: colors.textTertiary),
                Text(
                  '未加载',
                  maxLines: 1,
                  style: _pillLabelStyle(context, colors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// bot 身份（名字 + 头像）：`adapters.bots` 取一次就够，会话列表页与详情页共用同一次请求。
/// 取不到时保持空——头像由 `AssistantAvatar` 渐变占位，名字那一枚胶囊不画。
class BotIdentity {
  BotIdentity._();

  static Uri? _base;
  static BotProfile? _profile;
  static String? _avatar;
  static Future<void>? _pending;

  /// 该实例已缓存的 bot 身份；换实例（地址不同）后不复用旧身份。
  static BotProfile? profileFor(Uri base) => _base == base ? _profile : null;

  /// 该实例的 bot 头像，已补成绝对地址（`user.avatar` 可能是相对路径）。
  static String? avatarFor(Uri base) => _base == base ? _avatar : null;

  /// 取一次身份并缓存：并发调用共享同一次 WS 请求，失败后下一次再试。
  static Future<void> load({required Uri base, required String token}) {
    if (_base != base) {
      _base = base;
      _profile = null;
      _avatar = null;
      _pending = null;
    }
    final pending = _pending;
    if (pending != null) return pending;
    if (_profile != null) return Future<void>.value();
    final future = _fetch(base, token);
    _pending = future;
    return future.whenComplete(() => _pending = null);
  }

  static Future<void> _fetch(Uri base, String token) async {
    try {
      final value = await StateSocket(base: base, token: token).fetch('adapters.bots');
      // 期间换了实例：这次结果作废，别把旧实例的身份写进新缓存。
      if (_base != base) return;
      final bot = BotProfile.pick(value);
      if (bot == null) return;
      _profile = bot;
      _avatar = absoluteResourceUrl(base, bot.avatar) ?? _avatar;
    } catch (_) {
      // 取不到身份只是少一枚头像/名字：保持占位，等下一次 load 再试。
    }
  }
}

/// 模型只显示最后一段（`provider/model`、`provider:model` 都取尾段）。
String shortModelLabel(ModelRef ref) {
  final name = ref.model.trim();
  var cut = name.lastIndexOf('/');
  final colon = name.lastIndexOf(':');
  if (colon > cut) cut = colon;
  if (cut < 0 || cut >= name.length - 1) return name.isEmpty ? '模型' : name;
  return name.substring(cut + 1);
}

/// 胶囊底色档位：只决定底色，尺寸/字号/内边距全部由 [_PillSurface] 固定。
enum _PillTone {
  /// 中性：模型名、开发者信息、待机状态灯。
  neutral,

  /// 主色态：思考中 / 回复中。
  accent,

  /// 警示：轮询中。
  alert,
}

/// 胶囊内文字：统一走主题的 `labelSmall`（11sp / 行高 14 / 字距 0.3 / 等宽数字），
/// 只由调用方给定颜色。
TextStyle _pillLabelStyle(BuildContext context, Color color) {
  final base = Theme.of(context).textTheme.labelSmall ?? const TextStyle();
  return base.copyWith(color: color);
}

/// 信息栏里不带状态的胶囊：bot 名（可带头像）、平台/引擎/计时、模型。
class _InfoPill extends StatelessWidget {
  const _InfoPill({
    required this.label,
    this.icon,
    this.leading,
    this.onTap,
  });

  final String label;
  final IconData? icon;
  final Widget? leading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return _PillSurface(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: _PillSurface.gap,
        children: [
          ?leading,
          if (icon case final iconData?)
            Icon(iconData, size: 13, color: colors.textSecondary),
          Text(
            label,
            maxLines: 1,
            style: _pillLabelStyle(context, colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// 常驻状态灯：与模型胶囊同款底座 + 圆点 + 文案。
/// 底色档位、圆点与文字颜色随状态变化；只有「思考中」挂呼吸动画，其余状态是静态圆点。
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.light});

  final StatusLight light;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final (Color dot, Color foreground, _PillTone tone) = switch (light) {
      StatusLight.idle => (
        colors.textTertiary,
        colors.textSecondary,
        _PillTone.neutral,
      ),
      StatusLight.thinking || StatusLight.replying => (
        colors.accent,
        colors.accent,
        _PillTone.accent,
      ),
      StatusLight.polling => (
        colors.statusError,
        colors.statusError,
        _PillTone.alert,
      ),
    };
    return Semantics(
      label: '状态：${light.label}',
      excludeSemantics: true,
      child: _PillSurface(
        tone: tone,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: _PillSurface.gap,
          children: [
            if (light == StatusLight.thinking)
              _PulseDot(color: dot)
            else
              _Dot(color: dot),
            Text(
              light.label,
              maxLines: 1,
              style: _pillLabelStyle(context, foreground),
            ),
          ],
        ),
      ),
    );
  }
}

/// 信息栏里的本轮耗时胶囊：读数由计时表自己刷新，整页不随 tick 重建。
/// 点开就是阶段明细——骨架撤场后仍能回看这一轮花在了哪些阶段。
class _TurnPill extends StatelessWidget {
  const _TurnPill({required this.clock, this.onTap});

  final ValueListenable<TurnClockView?> clock;
  final ValueChanged<TurnClockView>? onTap;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TurnClockView?>(
      valueListenable: clock,
      builder: (context, view, _) => view == null
          ? const SizedBox.shrink()
          : _InfoPill(
              label: turnLineLabel(view),
              icon: Icons.timer_outlined,
              onTap: onTap == null ? null : () => onTap!(view),
            ),
    );
  }
}

/// 骨架气泡骑缝上的计时标签：视觉尺寸与位置都不变（11sp 等宽数字、贴边压描边），
/// 命中区按 Material 的最小触控高度向气泡内部扩——点开本轮的阶段明细。
class TurnClockLabel extends StatelessWidget {
  const TurnClockLabel({
    super.key,
    required this.clock,
    this.aborted = false,
    this.onTap,
  });

  /// 标签顶端比气泡边框高 8dp，命中区落在气泡内的部分仍有 44dp。
  static const double tapHeight = 52;

  final ValueListenable<TurnClockView?> clock;

  /// 本轮被中止：标签换成「已中止 12.4s」。
  final bool aborted;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final style = theme.textTheme.labelSmall?.copyWith(
      fontSize: 11,
      height: 1.2,
      fontWeight: FontWeight.w600,
      color: colors.accent,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onTap!();
            },
      child: SizedBox(
        height: tapHeight,
        child: Align(
          alignment: Alignment.topLeft,
          // 只留标签自己的宽度：整条气泡宽的透明热区会把别处的点击也吃掉。
          widthFactor: 1,
          child: Container(
            // 标签底色取聊天区底色，才能把 1px 描边压断。
            color: theme.scaffoldBackgroundColor,
            // 固定最小宽度：`9.9s→10.0s` 或阶段名切换时不挤动骑缝位置。
            constraints: const BoxConstraints(minWidth: 96),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: ValueListenableBuilder<TurnClockView?>(
              valueListenable: clock,
              builder: (context, view, _) => Semantics(
                button: onTap != null,
                label: view == null
                    ? '阶段明细'
                    : '阶段明细 ${turnLineLabel(view, aborted: aborted)}',
                excludeSemantics: true,
                child: Text(
                  view == null
                      ? ''
                      : turnLineLabel(view, aborted: aborted),
                  maxLines: 1,
                  style: style,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 阶段明细：本轮总耗时 + 最近完成的几段。阶段可以并行（draw 与 reply 同时跑），
/// 所以各自耗时之和可以超过整轮——这里只解释「刚才在干什么」。
Future<void> showTurnPhases(BuildContext context, TurnClockView view) {
  return _showChromeSheet<void>(
    context,
    (context) => _TurnPhasesSheet(view: view),
  );
}

class _TurnPhasesSheet extends StatelessWidget {
  const _TurnPhasesSheet({required this.view});

  final TurnClockView view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final mono = theme.textTheme.bodyMedium?.copyWith(
      color: colors.textPrimary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return _SheetFrame(
      title: '本轮 ${formatElapsed(view.total)}',
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Space.x16, 0, Space.x16, Space.x16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              view.phase == null ? '已完成' : '当前 ${view.phase}',
              style: theme.textTheme.labelSmall?.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: Space.x8),
            if (view.recent.isEmpty)
              Text(
                '还没有完成的阶段',
                style: theme.textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
              )
            else
              for (final group in aggregatePhases(view.recent))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.x8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(group.name, style: mono)),
                          Text(phaseGroupLabel(group), style: mono),
                        ],
                      ),
                      if (group.count > 1)
                        Text(
                          group.spans.map(formatElapsed).join(' · '),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
            const SizedBox(height: Space.x8),
            Text(
              '阶段可能并行：各自耗时之和可以超过整轮。',
              style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

/// 静态圆点：待机 / 回复中 / 轮询中的指示灯，不持有 ticker。
class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 6,
      height: 6,
      child: DecoratedBox(
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

/// 呼吸圆点：只在「思考中」挂载，胶囊销毁动画即停。
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

  late final Animation<double> _opacity = Tween<double>(begin: 0.35, end: 1).animate(
    CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _opacity, child: _Dot(color: widget.color));
  }
}

/// 信息栏所有胶囊的唯一底座：固定 24dp 高、999 圆角、内边距 8/4、1px `borderSubtle` 描边，
/// 底色只由 [_PillTone] 决定。模型胶囊、开发者信息胶囊、状态灯都走这里，
/// 所以并排不会出现两套尺寸。
class _PillSurface extends StatelessWidget {
  const _PillSurface({
    required this.child,
    this.tone = _PillTone.neutral,
    this.onTap,
  });

  /// 胶囊总高（含上下各 4dp 内边距）。
  static const double height = 24;

  /// 内容可用高度 = [height] − 上下内边距，头像/图标按它对齐。
  static const double contentHeight = height - Space.x4 * 2;

  /// 圆角：完整胶囊形。
  static const double radius = Radii.pill;

  /// 圆点/图标/头像与文字之间的间距。
  static const double gap = Space.x4;

  static const EdgeInsets padding =
      EdgeInsets.symmetric(horizontal: Space.x8, vertical: Space.x4);

  final Widget child;
  final _PillTone tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final (Color fill, Color border) = switch (tone) {
      _PillTone.neutral => (colors.surfaceL2, colors.borderSubtle),
      _PillTone.accent => (
        colors.accent.withValues(alpha: 0.12),
        colors.accent.withValues(alpha: 0.30),
      ),
      _PillTone.alert => (
        colors.statusError.withValues(alpha: 0.12),
        colors.statusError.withValues(alpha: 0.30),
      ),
    };
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(color: border, width: 1),
    );
    return Material(
      color: fill,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        customBorder: shape,
        child: SizedBox(
          height: height,
          child: Padding(
            padding: padding,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 完整原名 + ID / 平台 / 引擎 / 模型，每行右侧一键复制（值文本可选中）。
Future<void> showSessionDetails(BuildContext context, SessionSummary session) {
  return _showChromeSheet<void>(
    context,
    (context) => _SessionDetailsSheet(session: session),
  );
}

class _SessionDetailsSheet extends StatelessWidget {
  const _SessionDetailsSheet({required this.session});

  final SessionSummary session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final model = session.model;
    final valueStyle = theme.textTheme.bodyMedium?.copyWith(
      color: colors.textPrimary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return _SheetFrame(
      title: '会话详情',
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: Space.x12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.x16, 0, Space.x16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '完整名称',
                    style: theme.textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                  ),
                  const SizedBox(height: Space.x4),
                  SelectableText(session.title, style: valueStyle),
                ],
              ),
            ),
            const SizedBox(height: Space.x12),
            Divider(height: 1, thickness: 1, color: colors.borderDivider),
            _CopyRow(label: '会话 ID', value: session.id),
            _CopyRow(label: '平台', value: session.origin),
            if (session.engine.isNotEmpty) _CopyRow(label: '引擎', value: session.engine),
            if (model != null) _CopyRow(label: '模型', value: model.toString()),
          ],
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
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.x16, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              widget.label,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
          ),
          Expanded(
            child: SelectableText(
              widget.value,
              maxLines: 2,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.textPrimary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: Space.x8),
          SizedBox(
            width: 32,
            height: 32,
            child: IconButton(
              onPressed: _copy,
              padding: EdgeInsets.zero,
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              tooltip: _copied ? '已复制' : '复制',
              icon: Icon(
                _copied ? Icons.check : Icons.copy_rounded,
                size: 16,
                color: _copied ? colors.statusRunning : colors.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 弹层统一外框：`surfaceL2` 底、16dp 顶部圆角，拖拽手柄与标题栏由 [_SheetFrame] 画。
Future<T?> _showChromeSheet<T>(BuildContext context, WidgetBuilder builder) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.colors.surfaceL2,
    clipBehavior: Clip.antiAlias,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
    ),
    builder: builder,
  );
}

/// 弹层头部：32×4 拖拽手柄（上下各 8）+ 标题栏（16,4,8,12）+ 32×32 关闭按钮。
class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.x8),
            child: Center(
              child: Container(
                width: 32,
                height: Radii.bar,
                decoration: BoxDecoration(
                  color: colors.borderSubtle,
                  borderRadius: BorderRadius.circular(Radii.bar / 2),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.x16, Space.x4, Space.x8, Space.x12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(color: colors.textPrimary),
                  ),
                ),
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    tooltip: '关闭',
                    icon: Icon(Icons.close, size: 18, color: colors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          Flexible(child: child),
        ],
      ),
    );
  }
}
