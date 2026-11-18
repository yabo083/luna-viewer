import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// 没有工具帧时的兜底阶段名：模型在跑（reasoning、等首字、拼 prompt）。
const String thinkingPhase = '思考';

/// 正文 delta 的阶段名。实例里的回复正文也走 `reply` 工具，两者同名归一。
const String replyPhase = 'reply';

/// 展开面板里最多列几条已完成的阶段：够解释「刚才在干什么」，又不刷屏。
const int _phaseHistory = 3;

/// 名字统一到信息栏里能读的一个短词。
///
/// 规则（按实例实测的帧形态）：
/// - `/live` 的 `reasoning` → `思考`；`text` → `reply`；`tool-input` 取 `toolName`；
/// - `/events` 的 `prompt` / `engine/activity{label:generate}` 也归 `思考`；
/// - 去掉 `chatluna` / `tool` 前缀与 `:` `/` `.` 分隔，只留尾段，统一小写；
/// - 认不出的工具名原样保留（截断到 16 字符，避免把信息栏撑破）。
String normalizeTurnPhase(String raw) {
  var name = raw.trim().toLowerCase();
  if (name.isEmpty) return thinkingPhase;
  final tail = name.split(RegExp(r'[/:.]+')).where((part) => part.isNotEmpty);
  if (tail.isNotEmpty) name = tail.last;
  if (name.startsWith('tool-') &&
      !name.startsWith('tool-before') &&
      !name.startsWith('tool-after')) {
    name = name.substring('tool-'.length);
  }
  if (name.startsWith('tools-')) name = name.substring('tools-'.length);
  return switch (name) {
    '' => thinkingPhase,
    'reasoning' ||
    'think' ||
    'thinking' ||
    'prompt' ||
    'generate' ||
    'prepare' => thinkingPhase,
    'text' ||
    'assistant' ||
    'assistant-stream' ||
    'send' ||
    'message' ||
    'reply-tool' => replyPhase,
    _ => name.length > 16 ? name.substring(0, 16) : name,
  };
}

/// 已经结束的一个阶段：名称 + 实际耗时。
@immutable
class TurnPhaseRecord {
  const TurnPhaseRecord(this.name, this.elapsed);

  final String name;
  final Duration elapsed;
}

/// 本轮耗时：`3.2s`（不足一分钟）/ `1m04s` / `1h04m`。
String formatElapsed(Duration elapsed) {
  final ms = elapsed.isNegative ? 0 : elapsed.inMilliseconds;
  if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
  final seconds = ms ~/ 1000;
  if (seconds < 3600) {
    return '${seconds ~/ 60}m${(seconds % 60).toString().padLeft(2, '0')}s';
  }
  final minutes = seconds ~/ 60;
  return '${minutes ~/ 60}h${(minutes % 60).toString().padLeft(2, '0')}m';
}

/// 骨架气泡边框上的读数：整轮总时长在前，当前阶段与它的实时耗时在后。
/// - 进行中且有阶段：`1m04s · draw 12.3s`
/// - 阶段间隙（例如工具结果与下一步之间）：只显示 `1m04s`
/// - 中止：`已中止 12.4s`
String turnLineLabel(TurnClockView view, {bool aborted = false}) {
  final total = formatElapsed(view.total);
  if (aborted) return '已中止 $total';
  final phases = view.active.isNotEmpty
      ? [
          for (final phase in view.active.take(2))
            '${phase.name} ${formatElapsed(phase.elapsed)}',
        ]
      : [
          if (view.phase != null)
            '${view.phase} ${formatElapsed(view.phaseElapsed ?? Duration.zero)}',
        ];
  if (phases.isEmpty) return total;
  // 并行的第三阶段起收成 `+1`，避免把边框标签撑破。
  final extra = view.active.length > 2 ? ' +${view.active.length - 2}' : '';
  return '$total · ${phases.join(' · ')}$extra';
}

/// 阶段直方的一段：名称、耗时、占整轮的比例。
@immutable
class PhaseShare {
  const PhaseShare({
    required this.name,
    required this.elapsed,
    required this.share,
  });

  final String name;
  final Duration elapsed;

  /// 占整轮的比例（0–1）。阶段可以并行，所以各段之和可以超过 1。
  final double share;
}

/// 阶段直方：最近完成的几段各自占整轮多少，用于明细里的比例条。
List<PhaseShare> phaseHistogram(List<TurnPhaseRecord> phases, Duration total) {
  final round = total.inMilliseconds;
  return [
    for (final phase in phases)
      PhaseShare(
        name: phase.name,
        elapsed: phase.elapsed,
        share: round <= 0
            ? 0
            : (phase.elapsed.inMilliseconds / round).clamp(0.0, 1.0),
      ),
  ];
}

/// 同类阶段的聚合：`draw ×2 51.4s`。展开时再用 [PhaseGroup.spans] 按行列出各次，
/// 不让同名阶段在明细里串成一长排。
@immutable
class PhaseGroup {
  const PhaseGroup({
    required this.name,
    required this.total,
    required this.spans,
  });

  final String name;
  final Duration total;

  /// 每一次的耗时，按发生顺序。
  final List<Duration> spans;

  int get count => spans.length;
}

/// 按阶段名聚合，顺序取首次出现；同名阶段的耗时直接相加（并行阶段本来就不互斥）。
List<PhaseGroup> aggregatePhases(List<TurnPhaseRecord> phases) {
  final order = <String>[];
  final spans = <String, List<Duration>>{};
  for (final phase in phases) {
    final list = spans[phase.name];
    if (list == null) {
      order.add(phase.name);
      spans[phase.name] = <Duration>[phase.elapsed];
    } else {
      list.add(phase.elapsed);
    }
  }
  return [
    for (final name in order)
      PhaseGroup(
        name: name,
        total: spans[name]!.fold(Duration.zero, (sum, span) => sum + span),
        spans: List<Duration>.unmodifiable(spans[name]!),
      ),
  ];
}

/// 聚合行的文案：`draw ×2 51.4s`；只出现一次时省略 `×1`。
String phaseGroupLabel(PhaseGroup group) => group.count > 1
    ? '${group.name} ×${group.count} ${formatElapsed(group.total)}'
    : '${group.name} ${formatElapsed(group.total)}';

/// 骨架气泡要画的一帧：整轮总耗时 + 当前阶段 + 最近完成的阶段。
@immutable
class TurnClockView {
  const TurnClockView({
    required this.total,
    this.round = 0,
    this.phase,
    this.phaseElapsed,
    this.active = const [],
    this.recent = const [],
    this.finished = false,
    this.previous = false,
  });

  /// 整轮已耗时；[finished] 之后是冻结的最终值。
  final Duration total;

  /// 轮次序号：每开一次新表加一。页面用它判断「这是新的一轮」，
  /// 而不是靠「读数还很小」这种会漏判的启发式。
  final int round;

  /// 此刻仍在跑的全部阶段（按进入顺序）。折叠态取前两条。
  final List<TurnPhaseRecord> active;

  /// 当前正在进行的阶段名：折叠态只显示它（并行阶段里最近开始的那个）。
  final String? phase;

  /// 当前阶段的实时耗时。
  final Duration? phaseElapsed;

  /// 最近完成的阶段，最新在前。
  final List<TurnPhaseRecord> recent;

  /// 本轮已收表（停止 + 投递都到齐）：读数不再走。
  final bool finished;

  /// 收表后又过了冻结期。骨架气泡不用它，状态灯语义里留作「上一轮」。
  final bool previous;
}

/// 进行中 + 已完成的阶段表。所有时间都是「距本轮开始」的单调时长。
///
/// 阶段**可以并行**（`draw` 与 `reply` 可能同时在跑，`reply` 还可能重试），所以这里是
/// 一张表而不是一个栈：每个阶段各自计时，各阶段耗时之和允许超过整轮。
class TurnPhaseLog {
  final LinkedHashMap<String, Duration> _active =
      LinkedHashMap<String, Duration>();
  final List<TurnPhaseRecord> _done = <TurnPhaseRecord>[];

  /// 折叠态显示的阶段：最近进入/续期的那个。
  String? get current => _active.isEmpty ? null : _active.keys.last;

  bool get isEmpty => _active.isEmpty;

  Duration? startOf(String name) => _active[name];

  /// 进入阶段：已在跑的同名阶段沿用原起点（重试不重新计时），并重新成为「当前」。
  void enter(Duration now, String name) {
    final start = _active.remove(name);
    _active[name] = start ?? now;
  }

  /// 结束阶段：`[start, now)` 记入历史，超出上限的丢最旧的。
  /// 短于 50ms 的瞬间切换（工具结果与 settle 同刻）不进历史，避免刷出一串 0.0s。
  void leave(Duration now, String name) {
    final start = _active.remove(name);
    if (start == null) return;
    final end = now < start ? start : now;
    final elapsed = end - start;
    if (elapsed < const Duration(milliseconds: 50)) return;
    _done.add(TurnPhaseRecord(name, elapsed));
    if (_done.length > _phaseHistory) _done.removeAt(0);
  }

  /// 结束最近一个仍在进行的阶段：`tool-result` 消息不带阶段名，只能按「后开先关」配对。
  void leaveLatest(Duration now) {
    final name = current;
    if (name != null) leave(now, name);
  }

  void leaveAll(Duration now) {
    for (final name in _active.keys.toList(growable: false)) {
      leave(now, name);
    }
  }

  void clear() {
    _active.clear();
    _done.clear();
  }

  /// 最近的阶段，最新在前。
  List<TurnPhaseRecord> get recent =>
      List<TurnPhaseRecord>.unmodifiable(_done.reversed);

  /// 此刻仍在跑的阶段（按进入顺序）：折叠态一次显示两条，并行时名字不会来回跳。
  List<TurnPhaseRecord> activeAt(Duration now) => [
    for (final entry in _active.entries)
      TurnPhaseRecord(
        entry.key,
        now < entry.value ? Duration.zero : now - entry.value,
      ),
  ];
}

/// 本轮终点：生成已停 + 最后一条 bot 外发已落库，取更晚的那个。
///
/// - 生成还在跑 → null（投递只是这一轮里的一条消息，不是终点）；
/// - 已停但投递还没到 → 等 [grace]，超时按停止时刻收尾（空回复、投递失败也要收表）；
/// - 都到齐 → `max(stoppedAt, deliveredAt)`：停表之后再落库的 1–2s 也算进本轮。
Duration? resolveTurnEnd({
  required Duration? stoppedAt,
  required Duration? deliveredAt,
  required Duration now,
  required Duration grace,
}) {
  if (stoppedAt == null) return null;
  if (deliveredAt == null) {
    return now - stoppedAt >= grace ? stoppedAt : null;
  }
  return deliveredAt > stoppedAt ? deliveredAt : stoppedAt;
}

/// 信号比本地收到早多久（mark 自带落库时间）。
///
/// 设备与服务端时钟可能差很多：超过 [maxLead] 一律按 0 处理——宁可晚几百毫秒，
/// 也不能把上一轮的旧时间算进这一轮。
Duration turnStartLead(
  DateTime? serverTime,
  DateTime now, {
  Duration maxLead = const Duration(seconds: 3),
}) {
  if (serverTime == null) return Duration.zero;
  final delta = now.difference(serverTime);
  if (delta <= Duration.zero || delta > maxLead) return Duration.zero;
  return delta;
}

/// 整轮 + 分阶段计时器。
///
/// - 起点：[start]（mark / active snapshot / `running`）可重复调用，只接受更早的起点；
/// - 阶段：[phase] / [endPhase] / [phaseFinished] 维护 [TurnPhaseLog]；
/// - 终点：[stopped]（生成停）+ [delivered]（最后一条外发落库）都到齐才收表；
/// - 时钟是单调的 [Stopwatch]，页面切后台不停表：只停 tick，回前台按真实墙钟重算。
class TurnClock {
  TurnClock({
    Duration Function()? now,
    this.tickInterval = const Duration(milliseconds: 100),
    this.hold = const Duration(seconds: 2),
    this.deliveryGrace = const Duration(seconds: 3),
  }) : _now = now ?? _stopwatchNow();

  /// 只有这一枚小字监听它，页面和列表不随 tick 重建。
  final ValueNotifier<TurnClockView?> view = ValueNotifier<TurnClockView?>(
    null,
  );

  /// 阶段计时精确到 0.1s，100ms 的 tick 让读数连续跳动，不是每 0.2s 跳一格。
  final Duration tickInterval;

  /// 结束后冻结时长：够看清一眼，又不至于一直占着信息栏。
  final Duration hold;

  /// 生成停了但外发还没落库时的等待上限（空回复、投递失败也要收表）。
  final Duration deliveryGrace;

  final Duration Function() _now;
  final TurnPhaseLog _phases = TurnPhaseLog();

  Duration? _start;
  Duration? _stopAt;
  Duration? _deliveredAt;
  Duration? _end;
  bool _previous = false;
  bool _frozen = false;
  int _round = 0;
  Timer? _tick;
  Timer? _holdTimer;

  /// 本轮是否在走表（已开始且未收表）。
  bool get running => _start != null && _end == null;

  /// 本轮开始。[lead] 是信号比本地收到早的那点时间（见 [turnStartLead]）。
  /// 已经开始的一轮只接受更早的起点，不重置——同一步里 reasoning 与 tool 帧会反复报到。
  void start({Duration lead = Duration.zero, bool force = false}) {
    // 中止后定格：只有明确的新一轮（`input-enqueued`，force）能重开表。
    if (_frozen && !force) return;
    // 刚收表的一轮：迟到的 mark（settled 之后的 delivered、下一轮的 admitted）不能重开一个 0.0s 的轮次。
    if (!force &&
        !running &&
        _end != null &&
        _now() - _end! < const Duration(seconds: 1)) {
      return;
    }
    _frozen = false;
    final candidate = _now() - (lead.isNegative ? Duration.zero : lead);
    if (running) {
      final current = _start!;
      if (candidate < current) _start = candidate;
      _publish();
      return;
    }
    _holdTimer?.cancel();
    _holdTimer = null;
    _round++;
    _start = candidate;
    _stopAt = null;
    _deliveredAt = null;
    _end = null;
    _previous = false;
    _phases.clear();
    _publish();
    _startTick();
  }

  /// 某个阶段有活动：开始计时，或把已经停下的表重新打开（有新帧 = 这一轮还在跑，
  /// 上一轮的冻结读数就此让位）。
  void phase(String name) {
    if (_frozen) return;
    if (!running) start();
    _stopAt = null;
    _phases.enter(_now(), normalizeTurnPhase(name));
    _publish();
  }

  void endPhase(String name) {
    if (_end != null) return;
    _phases.leave(_now(), normalizeTurnPhase(name));
    _publish();
  }

  /// `tool-result` 落库：关掉最近一个还在跑的阶段（帧里没有 callId，按后开先关配对），
  /// 返回被关掉的阶段名——调用方据此决定要不要接着开「思考」（reply 之后就该收尾了）。
  String? phaseFinished() {
    if (_end != null) return null;
    final name = _phases.current;
    _phases.leaveLatest(_now());
    _publish();
    return name;
  }

  /// 这一次尝试结束了（`agent/assistant-settled`）：阶段收尾，但**不是**整轮终点——
  /// 投递与后续 step 还可能在跑。
  void attemptSettled() {
    if (_end != null) return;
    _phases.leaveAll(_now());
    _publish();
  }

  /// 用户中止：立即冻结读数（停表 + 关阶段），骨架保留「已中止 Ns」，
  /// 之后到齐的 `settled` / `delivered` 不再让数字继续涨。
  void freeze() {
    if (!running) return;
    _frozen = true;
    final now = _now();
    _end = now;
    _stopAt = now;
    _phases.leaveAll(now);
    _stopTick();
    _holdTimer?.cancel();
    _holdTimer = null;
    _publish();
  }

  /// `running=false`：`engine/activity settle`、无 attempt 的快照、轮询读到的 false。
  void stopped() {
    if (!running) return;
    _stopAt ??= _now();
    _maybeFinish();
    _publish();
  }

  /// bot 的最后一条外发落库（`chat/delivered` mark / 平台流里的 `dir=out`）。
  /// 同一轮多条时取最后一条的时刻。
  void delivered() {
    if (_frozen || _start == null) return;
    final now = _now();
    if (_deliveredAt == null || now > _deliveredAt!) _deliveredAt = now;
    if (_end != null) {
      // 冻结期间又落库一条：这一轮其实还没完，把终点往后推。
      if (!_previous && now > _end!) {
        _end = now;
        _publish();
      }
      return;
    }
    _maybeFinish();
    _publish();
  }

  /// 切后台：只停 tick（没有屏幕可看），时钟本身不停。
  void suspend() => _stopTick();

  /// 回前台：按真实墙钟重算一次再接着 tick。
  void resume() {
    _publish();
    if (running) _startTick();
  }

  /// 页面销毁：定时器与 notifier 都必须停，否则页面关掉后还在空转。
  void dispose() {
    _stopTick();
    _holdTimer?.cancel();
    _holdTimer = null;
    view.dispose();
  }

  void _maybeFinish() {
    final start = _start;
    if (start == null || _end != null) return;
    final end = resolveTurnEnd(
      stoppedAt: _stopAt,
      deliveredAt: _deliveredAt,
      now: _now(),
      grace: deliveryGrace,
    );
    if (end == null) return;
    _end = end;
    _phases.leaveAll(end);
    _stopTick();
    _publish();
    _holdTimer?.cancel();
    _holdTimer = Timer(hold, () {
      _holdTimer = null;
      _previous = true;
      _publish();
    });
  }

  void _startTick() {
    _tick ??= Timer.periodic(tickInterval, (_) {
      // 停了但没有外发：过了等待期就在这里收表（空回复、投递失败）。
      _maybeFinish();
      _publish();
    });
  }

  void _stopTick() {
    _tick?.cancel();
    _tick = null;
  }

  void _publish() {
    final start = _start;
    if (start == null) {
      if (view.value != null) view.value = null;
      return;
    }
    final now = _end ?? _now();
    final current = _end == null ? _phases.current : null;
    final phaseStart = current == null ? null : _phases.startOf(current);
    view.value = TurnClockView(
      total: now < start ? Duration.zero : now - start,
      round: _round,
      phase: current,
      phaseElapsed: phaseStart == null ? null : now - phaseStart,
      active: _end == null ? _phases.activeAt(now) : const [],
      recent: _phases.recent,
      finished: _end != null,
      previous: _previous,
    );
  }

  static Duration Function() _stopwatchNow() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }
}
