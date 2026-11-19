import '../../core/model/models.dart';

/// 活跃窗口：最后一条消息在 72 小时内的会话留在主列表，更早的收进「归档」。
const Duration activeWindow = Duration(days: 3);

/// 列表一行：插件会话（[conversation]）与它可能对应的已加载会话（[session]）。
/// 两者都有 = 已加载；只有 [conversation] = 插件有消息但 ChatLuna 还没加载它。
class SessionRow {
  const SessionRow({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.count,
    required this.time,
    this.conversation,
    this.session,
  });

  /// 插件侧的原始会话键：打开详情页时原样传给 `/api/platform/messages`（插件按它查表）。
  /// 与已加载会话、实时帧比较时再走 `normalizeConversationKey`，不要在这里先归一。
  final String key;

  /// 展示名：插件给的 title；已加载但插件里没有的会话用 App 侧的紧凑名。
  final String title;

  /// 最后一条消息的正文（压成一行）；没有消息时为 null。
  final String? subtitle;

  /// 插件统计的消息条数。
  final int count;

  /// 最后一条消息的时间；没有消息时退回已加载会话的创建时间。
  final DateTime time;
  final PlatformConversation? conversation;
  final SessionSummary? session;

  bool get running => session?.running ?? false;

  /// 插件里有这个会话，但 ChatLuna 还没加载它：预览要标「未加载」，且不画运行灯。
  bool get unloaded => conversation != null && session == null;

  /// 群聊还是私聊：插件判定（`conversation.kind`）。没有插件会话（只存在于 App 侧）时按私聊处理，
  /// 头像退回首字而不是群组图标。
  bool get isGroup => conversation?.kind == 'group';

  /// 没有最后一条消息时的副标题：已加载会话退回平台/引擎/模型，未加载就没有副标题。
  String? get fallbackSubtitle {
    final session = this.session;
    if (session == null) return null;
    return [
      session.origin,
      if (session.engine.isNotEmpty) session.engine,
      if (session.model != null) session.model!.toString(),
    ].join(' · ');
  }
}

/// 把会话行切成「活跃」与「归档」两段，顺序保持不变。
///
/// 时间基准由调用方传入 [now]（页面挂载时取一次快照），不在每次重建时读设备时钟；
/// 这样列表开着时不会因为某一帧到达而把临近边界的行突然踢进归档。
/// 运行中的会话无论多久以前都算活跃；恰好 72 小时算活跃。
(List<SessionRow>, List<SessionRow>) partitionSessions(
  List<SessionRow> rows, {
  required DateTime now,
  Duration window = activeWindow,
}) {
  final active = <SessionRow>[];
  final archived = <SessionRow>[];
  for (final row in rows) {
    if (row.running || now.difference(row.time) <= window) {
      active.add(row);
    } else {
      archived.add(row);
    }
  }
  return (active, archived);
}
