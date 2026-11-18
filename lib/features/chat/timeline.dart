import '../../core/model/models.dart';

/// 框架块与平台消息的「同一条」窗口：正文压空白后相同、时间相差 3s 内的算同一条。
const Duration _noticeDedupeWindow = Duration(seconds: 3);

/// 分组窗口：同一发送者 5 分钟内的连续消息共用一次头像与名字。
const Duration _groupWindow = Duration(minutes: 5);

/// 没有时戳的框架块与相邻平台消息的最小间隔：贴在前一条之后 / 后一条之前 1ms。
const Duration anchorTick = Duration(milliseconds: 1);

final RegExp _spaces = RegExp(r'\s+');

/// 正文对齐键：压掉所有空白（换行/缩进不影响「同一条」判定）。
String noticeKey(String text) => text.replaceAll(_spaces, '');

/// 时间线上的一条框架消息：正文、折叠键与对齐用的时间。
class TimelineNotice {
  const TimelineNotice({required this.id, required this.text, this.time});

  /// 折叠键（服务端消息 id，或正文压空白后的哈希）。
  final String id;
  final String text;

  /// 时间锚点。空表示服务端没给时戳，加载时也没找到可参照的平台消息，
  /// 由 [mergeTimeline] 兜底（排在时间线末尾）。
  final DateTime? time;
}

/// 时间线上的一项。日期分隔条没有时间（它本身就是「哪一天」）。
sealed class TimelineItem {
  const TimelineItem();
}

class DayDividerItem extends TimelineItem {
  const DayDividerItem(this.day);

  final DateTime day;
}

class NoticeItem extends TimelineItem {
  const NoticeItem(this.notice);

  final TimelineNotice notice;
}

class MessageItem extends TimelineItem {
  const MessageItem(this.message, {required this.showHeader});

  final PlatformMessage message;

  /// 同一发送者 5 分钟内的连续消息里只有第一条为 true。
  final bool showHeader;
}

/// 按时间给框架块定序（时间升序，没有时间的留在末尾），同一时刻保持原有顺序。
/// 列表页用它维护 `_framework`：增量条目插进去之后仍然是「日志顺序」，
/// [mergeTimeline] 的同刻先后才有意义。
List<TimelineNotice> orderNotices(List<TimelineNotice> notices) {
  final rows = [for (var i = 0; i < notices.length; i++) (at: notices[i].time, order: i)];
  rows.sort((a, b) {
    final byTime = _compareTimes(a.at, b.at);
    return byTime != 0 ? byTime : a.order - b.order;
  });
  return [for (final row in rows) notices[row.order]];
}

/// 把平台消息与框架块合成一条时间线（纯函数：同样的输入永远同样的输出）。
///
/// 规则：
/// 1. **定锚**：有时间的用自带时间；没有的挂到「其后第一条平台消息 − 1ms」，
///    其后也没有平台消息时挂到「之前最近一条 + 1ms」。锚点一旦存入 [TimelineNotice]
///    就不再变——翻页（只往前追加更早的消息）不会让框架块在相邻消息之间漂移。
/// 2. **排序**：时间升序；同一时刻平台消息在前、框架块在后（框架块不抢头像组）。
/// 3. **分组**：跨天插日期分隔条；框架块打断 5 分钟分组，其后的人重新显示头像与名字。
List<TimelineItem> mergeTimeline(
  List<PlatformMessage> messages,
  List<TimelineNotice> notices,
) {
  if (messages.isEmpty && notices.isEmpty) return const [];

  // 平台正文索引：与平台消息同文、时间落在窗口内的框架块不再画第二遍。
  final index = <String, List<DateTime>>{};
  for (final message in messages) {
    final key = noticeKey(message.content);
    if (key.isEmpty) continue;
    (index[key] ??= <DateTime>[]).add(message.time);
  }
  final kept = <TimelineNotice>[
    for (final notice in notices)
      if (!_isDuplicate(index, notice)) notice,
  ];

  final rows = <_Row>[
    for (var i = 0; i < messages.length; i++) _Row.message(messages[i], i),
    for (final placed in _place(kept, messages))
      _Row.notice(placed.notice, placed.at, placed.order),
  ];
  rows.sort(_Row.compare);

  final items = <TimelineItem>[];
  DateTime? day;
  var lastSender = '';
  DateTime? lastTime;

  for (final row in rows) {
    final at = row.at;
    if (at != null) {
      final date = DateTime(at.year, at.month, at.day);
      // 跨天：分隔条本身重置分组，后一条重新显示头像与名字。
      if (day == null || !_sameDay(day, date)) {
        day = date;
        lastSender = '';
        lastTime = null;
        items.add(DayDividerItem(date));
      }
    }
    final message = row.message;
    if (message == null) {
      items.add(NoticeItem(row.notice!));
      // 框架块打断分组：后面的人重新显示头像与名字。
      lastSender = '';
      lastTime = null;
      continue;
    }
    final sender = message.outbound
        ? 'bot'
        : 'user:${message.userId.isNotEmpty ? message.userId : (message.userName ?? '')}';
    final previous = lastTime;
    final showHeader =
        sender != lastSender ||
        previous == null ||
        message.time.difference(previous).abs() > _groupWindow;
    items.add(MessageItem(message, showHeader: showHeader));
    lastSender = sender;
    lastTime = message.time;
  }
  return items;
}

/// 给没有时戳的框架块找时间：顺着列表顺序走，每条都贴在前一条之后的空位。
/// 返回的 `at` 只有「一条平台消息都没有、自己也没有时间」时才是 null。
List<({TimelineNotice notice, DateTime? at, int order})> _place(
  List<TimelineNotice> notices,
  List<PlatformMessage> messages,
) {
  final placed = <({TimelineNotice notice, DateTime? at, int order})>[];
  DateTime? last;
  for (var i = 0; i < notices.length; i++) {
    final notice = notices[i];
    final at = notice.time ?? _freeSlot(last, messages);
    placed.add((notice: notice, at: at, order: i));
    if (at != null) last = at;
  }
  return placed;
}

/// 没有时戳的框架块在时间轴上的空位：其后第一条平台消息 − 1ms；
/// 后面再没有平台消息时排到已安排的最后一项之后（+1ms）。
DateTime? _freeSlot(DateTime? last, List<PlatformMessage> messages) {
  if (messages.isEmpty) return last?.add(anchorTick);
  for (final message in messages) {
    if (last != null && !message.time.isAfter(last)) continue;
    final before = message.time.subtract(anchorTick);
    // 两条平台消息挨得太近时贴在前一条之后，顺序仍然是日志顺序。
    return last == null || before.isAfter(last) ? before : last.add(anchorTick);
  }
  return last?.add(anchorTick);
}

bool _isDuplicate(Map<String, List<DateTime>> index, TimelineNotice notice) {
  final times = index[noticeKey(notice.text)];
  if (times == null) return false;
  final at = notice.time;
  // 没有时间戳就没法对齐：正文相同按重复处理，宁少不重。
  if (at == null) return true;
  for (final time in times) {
    if (time.difference(at).abs() <= _noticeDedupeWindow) return true;
  }
  return false;
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 合并排序用的一行：平台消息与框架块混在一起，只能靠 `at` + 类型 + 原始序号比较。
class _Row {
  const _Row._({this.message, this.notice, this.at, required this.order});

  factory _Row.message(PlatformMessage message, int order) =>
      _Row._(message: message, at: message.time, order: order);

  factory _Row.notice(TimelineNotice notice, DateTime? at, int order) =>
      _Row._(notice: notice, at: at, order: order);

  final PlatformMessage? message;
  final TimelineNotice? notice;
  final DateTime? at;
  final int order;

  /// 同一时刻平台消息（0）排在框架块（1）前面。
  int get kind => message != null ? 0 : 1;

  static int compare(_Row a, _Row b) {
    final byTime = _compareTimes(a.at, b.at);
    if (byTime != 0) return byTime;
    final byKind = a.kind - b.kind;
    return byKind != 0 ? byKind : a.order - b.order;
  }
}

/// 时间升序，没有时间的排在末尾。
int _compareTimes(DateTime? a, DateTime? b) {
  if (a != null && b != null) return a.compareTo(b);
  if (a != null) return -1;
  if (b != null) return 1;
  return 0;
}
