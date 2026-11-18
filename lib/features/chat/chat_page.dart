import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/capability/sessions_repository.dart';
import '../../core/capability/traffic_repository.dart';
import '../../core/capability/traffic_stream.dart';
import '../../core/model/models.dart';
import 'chat_chrome.dart';
import 'message_view.dart';

/// 实时流的唯一状态来源：UI 只读它，不再散落一堆 bool。
/// - `idle`：没有生成，列表首格不占位；信息栏只留一盏「待机」静灯；
/// - `thinking`：在跑但还没有正文（reasoning / 工具阶段），信息栏圆点呼吸、消息区胶囊带三点呼吸；
/// - `replying`：正文 delta 已到，胶囊保持静态；
/// - `failed`：SSE 断开，退回轮询。
enum LiveState {
  idle,
  thinking,
  replying,
  failed;

  /// 有生成在跑（思考或回复）：中止按钮与信息栏读它。
  bool get generating => this == LiveState.thinking || this == LiveState.replying;

  /// 列表首格是否需要状态胶囊：待机不占位（待机灯常驻在信息栏，不进消息列表）。
  bool get hasCapsule => this != LiveState.idle;

  /// 胶囊文案：信息栏常驻状态灯与消息区占位共用，`idle` 也有（「待机」）。
  String get capsuleLabel => statusLight.label;

  /// 信息栏状态灯：待机灰点、思考中主色呼吸、回复中主色静止、轮询中 warning 静止。
  StatusLight get statusLight => switch (this) {
    LiveState.idle => StatusLight.idle,
    LiveState.thinking => StatusLight.thinking,
    LiveState.replying => StatusLight.replying,
    LiveState.failed => StatusLight.polling,
  };
}

/// 会话详情：只读历史 + 实时流 + 会话级操作（中止 / 压缩 / 分叉 / 重新载入）。
/// v0.1.0 不在 App 里发消息——平台会话的输入仍由聊天软件承担。
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.repo,
    required this.base,
    required this.headers,
    required this.session,
    this.avatarUrl,
    this.botName,
    this.initial,
    this.showDeveloperInfo = false,
  });

  final SessionsRepository repo;
  final Uri base;
  final Map<String, String> headers;
  final SessionSummary session;
  final String? avatarUrl;
  final String? botName;

  /// 列表页预先取回的历史：有值时第一帧直接有内容。
  final Transcript? initial;

  /// 设置里的「显示平台/引擎/性能信息」，由会话列表页传入。
  final bool showDeveloperInfo;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _scroll = ScrollController();
  /// 全量历史；渲染只用 `_windowStart` 之后的一段，避免一次排版上百条 markdown。
  List<ChatMessage> _all = const [];
  int _windowStart = 0;
  static const _initialWindow = 12;

  /// 框架消息折叠状态：消息 id → 是否展开（缺省折叠）。
  /// 放页面级：`ListView.builder` 滚出视口就销毁元素，状态放 widget 里会丢。
  final Map<String, bool> _noticeOpen = {};

  /// 流式正文：SSE `text` delta 只进 buffer（reasoning/tool 不进），最多每 90ms 刷进 notifier；
  /// 列表里的流式气泡单独监听，不随每个 delta 重建整页。buffer 为空即「还没有正文」。
  final StringBuffer _streaming = StringBuffer();
  final ValueNotifier<String> _streamingText = ValueNotifier<String>('');
  static const _streamFlushInterval = Duration(milliseconds: 90);
  Timer? _flushTimer;

  StreamSubscription<LiveEvent>? _liveSub;
  StreamSubscription<SessionEvent>? _eventsSub;
  Timer? _poll;
  Timer? _snapshotTimer;
  Timer? _eventsRetry;
  bool _eventsStarted = false;
  int _eventsBackoff = 1;
  String? _lastEventId;
  bool _loading = true;

  /// 首个 snapshot 是否已到：权威帧之前，`session.running` 只是乐观值。
  bool _snapshotSeen = false;

  /// 仅实时模式：服务端没有这个会话的日志（`/messages` 404，通常是 ChatLuna 还没加载它）。
  /// 此时不显示错误页、不重试历史，页面内容全部来自旁路流量流。
  bool _liveOnly = false;

  /// 是否有「真实气泡」来源（历史日志 + `/events`）：有的话普通入站消息不必再补一张。
  /// 必须从第一帧就按 summary 定：仅流量会话没有历史，而 SSE 首连的回放帧通常
  /// **先于** 404 到达，那时若还按「有历史」过滤，14 条回放会被整批丢掉且不会再重放。
  bool _hasHistory = false;

  /// `/live` 只开一次；仅实时会话先不开，等历史真的取到再补上。
  bool _liveStarted = false;

  LiveState _live = LiveState.idle;
  String? _error;

  bool _awayFromBottom = false;
  final ValueNotifier<int> _unseen = ValueNotifier<int>(0);

  /// 旁路流量：指令层吃掉的消息（`chatluna xxx` 之类）不进会话日志，由
  /// `/api/traffic/stream` 在页面打开期间实时补成框架卡片。
  /// 它**不进** `_all`：既不参与日志流的 id 去重，也不被同标题合并吞掉。
  final List<_TrafficItem> _traffic = [];
  StreamSubscription<TrafficEntry>? _trafficSub;
  TrafficStream? _trafficStream;

  /// 标题里的候选 id（openid / 群号 / 频道号）：旧插件没有会话键时靠它命中。
  Set<String> _trafficIds = const {};

  /// 已判定过的旁路消息去重键（服务端重连会重放最近 20 条）。
  final Set<String> _trafficSeen = {};

  /// 回显窗口：同一内容在 3s 内已经进了 `_all`（指令被服务端回显到日志）就不再画卡。
  static const _echoWindow = Duration(seconds: 3);

  /// 列表里最多留这么多旁路卡片，更早的靠「消息记录」页翻。
  static const _trafficMax = 100;

  /// 去重集上限：重放/轮询会重复送 id，旧 id 可以淘汰。
  static const _trafficSeenMax = 400;

  /// 最近落进 `_all` 的正文 + 本地到达时间：旁路卡片据此判断「指令已被回显」。
  final List<({String body, DateTime at})> _recentBodies = [];

  /// 会话当前模型；切换成功后立即反映到信息栏与详情。
  ModelRef? _model;

  late final DateTime _t0;
  int? _netMs;
  int? _paintMs;
  int? _liveMs;

  /// 首屏自适应扩窗：一屏都没坐满时反向列表没有可滚动距离，手势翻不出历史。
  /// 首次布局后自动往前补页，最多连扩 [_autoFillSteps] 次（长会话不在首帧一次拉满）。
  static const _autoFillSteps = 6;

  /// 列表至少要有这么多可滚动距离才算「能滚」，否则算没坐满一屏。
  static const _minScrollExtent = 120.0;
  bool _autoFillDone = false;
  int _autoFillCount = 0;

  @override
  void initState() {
    super.initState();
    _t0 = DateTime.now();
    _model = widget.session.model;
    // 列表页的 running 只做乐观值：首个 snapshot 到达后一律以服务端为准。
    // 还没见到正文，先按「思考中」显示（快照/正文一到立刻细分）。
    _live = widget.session.running ? LiveState.thinking : LiveState.idle;
    // 仅流量会话的开局就按「没有历史」处理：它不在 `/api/sessions` 里，`/events` 不会来，
    // 入站消息只能靠旁路流补（见 [_hasHistory]）。
    _hasHistory = !widget.session.trafficOnly;
    _scroll.addListener(_onScroll);
    final initial = widget.initial;
    if (initial != null) {
      _all = initial.messages;
      _windowStart = _all.length > _initialWindow ? _all.length - _initialWindow : 0;
      _loading = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _paintMs = _since());
        _autoFillViewport();
      });
    } else {
      _load();
    }
    // 首帧先画出来再连实时流：SSE 握手与首个 snapshot 会和首屏排版抢时间。
    // 仅流量会话没有 agent，`/live` 只会 404：等 `_load` 失败或成功后再决定要不要开。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.session.trafficOnly) _startLive();
      _startTraffic();
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _flushTimer?.cancel();
    _streamingText.dispose();
    _unseen.dispose();
    _liveSub?.cancel();
    _eventsSub?.cancel();
    _trafficSub?.cancel();
    _trafficStream?.dispose();
    _poll?.cancel();
    _snapshotTimer?.cancel();
    _eventsRetry?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  int _since() => DateTime.now().difference(_t0).inMilliseconds;

  Future<void> _load() async {
    // 仅实时模式：会话不在服务端，历史永远 404。轮询/收尾回调都会走到这里，
    // 一次都不该再打网络。
    if (_liveOnly) return;
    // 已知 id：重取后多出来的才算「刚进日志」，用来撤掉被回显的旁路卡片。
    final known = {for (final message in _all) message.id};
    try {
      final transcript = await widget.repo.transcript(widget.session.id);
      if (!mounted) return;
      _netMs = _since();
      // 历史拿到了：普通入站消息从这一刻起由日志/`events` 负责，旁路只补指令。
      _hasHistory = true;
      // 合成会话也可能已经被加载了（列表还没刷新）：历史一拿到就按正常页面跑。
      _startLive();
      setState(() {
        final keepWindow = _all.isNotEmpty;
        _all = transcript.messages;
        // 重取不清 `_traffic`；只把这一批里已被真实消息回显的卡片撤掉。
        _dropEchoedTraffic([
          for (final message in _all)
            if (!known.contains(message.id)) message,
        ]);
        if (!keepWindow) {
          _windowStart = _all.length > _initialWindow ? _all.length - _initialWindow : 0;
          _autoFillDone = false;
          _autoFillCount = 0;
        } else {
          // 重取后历史可能变短（cut / truncated），窗口光标不能越过末尾。
          _windowStart = math.min(_windowStart, math.max(0, _all.length - 1));
        }
        _loading = false;
        _error = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _paintMs = _since());
        _autoFillViewport();
      });
    } on ApiFailure catch (e) {
      if (!mounted) return;
      if (e.code == 'NOT_FOUND' || e.status == 404) {
        // 会话还没被 ChatLuna 加载：不显示错误页，空历史 + 旁路实时流就是全部内容。
        setState(() {
          _liveOnly = true;
          _hasHistory = false;
          _loading = false;
          _error = null;
        });
        // 首连的回放帧可能早于这次 404 到达，被「有历史就不补入站」的门禁丢掉：
        // 重开一条旁路流让服务端再放一遍最近 20 条，这次全部放行。
        // 已经渲染过的条目由 `_trafficSeen` 挡住，不会重复。
        _restartTraffic();
        return;
      }
      setState(() {
        _loading = false;
        _error = '${e.code}：${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  /// 首屏没坐满一屏时（反向列表 `maxScrollExtent` 太小），手势无处可滚，历史翻不出来：
  /// 布局后自动往前补一页，扩完在新一帧再检查，最多连扩 [_autoFillSteps] 次。
  /// 能滚了（`maxScrollExtent >= _minScrollExtent`）、窗口已到顶、或用户已经手动滚动过就停。
  /// 反向列表 offset 0 就是最新一条，往前补页不会把视野带走，无需额外回滚。
  void _autoFillViewport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _autoFillDone) return;
      // 列表还没挂上（加载中、空会话）：等 `_load` 完成后会再来一次，不在这里空转。
      if (!_scroll.hasClients) return;
      if (_scroll.position.maxScrollExtent >= _minScrollExtent ||
          _windowStart == 0 ||
          _autoFillCount >= _autoFillSteps) {
        _autoFillDone = true;
        return;
      }
      _autoFillCount += 1;
      setState(() => _windowStart = math.max(0, _windowStart - _initialWindow));
      _autoFillViewport();
    });
  }

  void _startLive() {
    if (_liveStarted || _liveOnly || !mounted) return;
    _liveStarted = true;
    // 8s 内既没有 snapshot 也没有任何事件：乐观的 running 收回去，空闲会话绝不播动画。
    _snapshotTimer?.cancel();
    _snapshotTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || _snapshotSeen) return;
      _setLive(LiveState.idle);
      // 实时流指望不上时，日志流照样能补上别人发的新消息。
      _ensureEvents();
    });
    _liveSub = widget.repo.live(widget.session.id).listen(
      (event) {
        if (!mounted) return;
        _liveMs ??= _since();
        switch (event.kind) {
          case LiveEventKind.snapshot:
            // 权威帧：带 attempt 才在跑；没有 attempt 就立刻回到 idle 并清掉残留文本。
            _snapshotSeen = true;
            _snapshotTimer?.cancel();
            _flushTimer?.cancel();
            _flushTimer = null;
            _streaming.clear();
            for (final part in event.parts) {
              if (part['type'] == 'text' && part['delta'] is String) {
                _streaming.write(part['delta'] as String);
              }
            }
            _flushStreaming();
            // 快照里有正文就是「回复中」，否则还在思考/工具阶段。
            _setLive(
              event.active
                  ? (_streaming.isEmpty ? LiveState.thinking : LiveState.replying)
                  : LiveState.idle,
            );
            _ensureEvents();
            _followIfAtBottom();
          case LiveEventKind.delta:
            _snapshotTimer?.cancel();
            _setLive(LiveState.replying);
            _streaming.write(event.delta ?? '');
            if (_awayFromBottom) _unseen.value += 1;
            // 首个 delta 直接出字（从「思考中」切到「回复中」），之后才按 90ms 合并。
            if (_streamingText.value.isEmpty) {
              _flushStreaming();
            } else {
              _scheduleStreamFlush();
            }
            _followIfAtBottom();
          case LiveEventKind.reasoning:
            // 只有思考、没有正文：停在「思考中」；正文一到就转「回复中」。
            _snapshotTimer?.cancel();
            if (_streaming.isEmpty) _setLive(LiveState.thinking);
          case LiveEventKind.tool:
            _snapshotTimer?.cancel();
            if (_streaming.isEmpty) _setLive(LiveState.thinking);
          case LiveEventKind.settled:
            // 收尾时立刻 flush，避免最后一段 delta 卡在定时器里被丢掉。
            _snapshotTimer?.cancel();
            _flushTimer?.cancel();
            _flushTimer = null;
            _flushStreaming();
            _streaming.clear();
            _streamingText.value = '';
            if (_awayFromBottom) _unseen.value += 1;
            _setLive(LiveState.idle);
            _load();
          case LiveEventKind.lagged:
            _flushTimer?.cancel();
            _flushTimer = null;
            _flushStreaming();
            _load();
        }
      },
      onError: (Object error) {
        if (!mounted) return;
        _snapshotTimer?.cancel();
        // SSE 断了不等于在跑：切到 failed，由「轮询中」胶囊 + 定时重载兜底。
        _setLive(LiveState.failed);
        _ensureEvents();
        _startPolling();
      },
      onDone: () {
        if (!mounted || _live == LiveState.failed) return;
        _snapshotTimer?.cancel();
        _setLive(LiveState.failed);
        _ensureEvents();
        _startPolling();
      },
      cancelOnError: true,
    );
  }

  /// 唯一的写入口：相同状态不触发重建。
  void _setLive(LiveState next) {
    if (_live == next) return;
    setState(() => _live = next);
  }

  /// 日志流（别人/自己发的新消息）在拿到首个 snapshot 后才打开：
  /// 它和 `/live` 分工不同——live 是流式增量，events 是落库结果。
  void _ensureEvents() {
    if (_eventsStarted || !mounted) return;
    _eventsStarted = true;
    _openEvents();
  }

  void _openEvents() {
    if (!mounted) return;
    _eventsSub?.cancel();
    _eventsSub = widget.repo.events(widget.session.id, since: _lastEventId).listen(
      (event) {
        if (!mounted) return;
        _eventsBackoff = 1;
        if (event.truncated) {
          // 增量窗口失效：本地增量不可信，重取全量；旧消息先留着，别闪空。
          _lastEventId = null;
          _load();
          return;
        }
        _lastEventId = event.id ?? _lastEventId;
        final message = event.message;
        if (message != null) _appendMessage(message);
      },
      onError: (Object error) => _retryEvents(),
      onDone: _retryEvents,
      cancelOnError: true,
    );
  }

  /// 断线退避 1→2→4→8→16→30s，收到任意帧后回到 1s；已加载的消息一律不清空。
  void _retryEvents() {
    if (!mounted) return;
    _eventsRetry?.cancel();
    final seconds = _eventsBackoff;
    _eventsBackoff = seconds >= 15 ? 30 : seconds * 2;
    _eventsRetry = Timer(Duration(seconds: seconds), _openEvents);
  }

  /// 日志顺序追加；同 id 跳过，避免和 settled 后的全量重取重复。
  void _appendMessage(ChatMessage message) {
    if (_all.any((m) => m.id == message.id)) return;
    setState(() {
      _all = [..._all, message];
      // 窗口大小保持不变：新增的一条是最新消息，仍在可视窗口里。
      if (_windowStart > 0) {
        _windowStart = math.min(_windowStart + 1, math.max(0, _all.length - 1));
      }
      _noteBody(message);
      _dropEchoedTraffic([message]);
    });
    if (_nearBottom) {
      _scrollToLatest();
    } else {
      _unseen.value += 1;
    }
  }

  /// 旁路流：服务端会话键（归一后）就是会话 id，标题里没有 id 的会话也能命中，
  /// 所以只要有 token 就订阅（只在页面打开期间，关闭即断开一条连接）。
  /// 详情页只拿到 `ApiClient.authHeaders`，从同一个头里取回 token 自建客户端。
  void _startTraffic() {
    final token = _bearer;
    if (token == null || token.isEmpty) return;
    _trafficIds = candidateIdsOf(widget.session.title);
    final stream = TrafficStream(widget.base, token);
    _trafficStream = stream;
    _trafficSub = stream.entries.listen(
      _onTraffic,
      // 断线退避与 404 退化都在 TrafficStream 内部：这里只收消息，不把页面拖垮。
      onError: (Object _) {},
    );
  }

  /// 重开旁路流：只为一件事——让服务端再回放一遍最近 20 条。
  /// 仅在某批回放被门禁丢掉后需要（见 `_load` 的 404 分支）；已经画过的条目由
  /// `_trafficSeen` 挡住，重放不会产生重复。
  void _restartTraffic() {
    _trafficSub?.cancel();
    _trafficSub = null;
    _trafficStream?.dispose();
    _trafficStream = null;
    _startTraffic();
  }

  String? get _bearer {
    final raw = widget.headers['authorization'] ?? widget.headers['Authorization'];
    if (raw == null) return null;
    const prefix = 'bearer ';
    final value = raw.trim();
    return value.toLowerCase().startsWith(prefix)
        ? value.substring(prefix.length).trim()
        : value;
  }

  /// 服务端不做会话过滤：会话键（归一后与会话 id 相等）或标题 id 命中才入列，
  /// 任一命中即可（见 [matchesTraffic]）。
  void _onTraffic(TrafficEntry entry) {
    if (!mounted) return;
    if (!matchesTraffic(_trafficIds, entry, widget.session.id)) return;
    // 正文为空（纯状态帧之类）没法画成一条消息。
    if (entry.display.trim().isEmpty) return;
    // 出站是 bot 自己发出的回复：会话日志可能还没落，直接补一条气泡。
    // 入站只有指令形态才补框架卡；普通消息在 `/events` 里有真实气泡，不重画。
    // 没有历史来源时（仅流量会话）普通入站消息也得补，否则页面什么都不显示。
    if (!entry.outbound && _hasHistory && !isCommandish(entry.display)) return;
    final key = '${entry.dir}\u0000${entry.dedupeKey}';
    // 服务端重连会重放最近 20 条：同一个 id 只画一次。
    if (!_trafficSeen.add(key)) return;
    if (_trafficSeen.length > _trafficSeenMax) _trafficSeen.remove(_trafficSeen.first);
    // 指令回显：正文 3s 内已经作为真实消息进了日志，就不再画第二遍。
    if (_echoed(entry.display)) return;
    // 开局回放的 20 条里，页面打开之前的普通消息多半已在历史里，同样不画。
    if (_replayed(entry)) return;
    setState(() {
      _traffic.add(_TrafficItem(entry, DateTime.now()));
      if (_traffic.length > _trafficMax) {
        _traffic.removeRange(0, _traffic.length - _trafficMax);
      }
    });
    if (_nearBottom) {
      _scrollToLatest();
    } else {
      _unseen.value += 1;
    }
  }

  /// 旁路合成消息，按方向与形态分三种：
  /// - `out`：bot 已发出的回复 → 普通 assistant 消息（`form: message`，不画框架卡）；
  /// - `in` 指令 → 框架卡。首行放命令本身（框架卡片标题取首行），
  ///   `[指令]` 只留在正文里当来源标记，标题因此就是命令而不是「[指令] cmd」；
  /// - `in` 普通消息（只会出现在仅实时会话）→ 用户气泡：没有日志流时它是唯一的气泡来源。
  ChatMessage _trafficMessage(TrafficEntry entry) {
    if (entry.outbound) {
      return ChatMessage.synthetic(
        id: 'traffic-out-${entry.dedupeKey}',
        form: 'message',
        text: entry.display,
        role: 'assistant',
        framework: false,
      );
    }
    if (isCommandish(entry.display)) {
      return ChatMessage.synthetic(
        id: 'traffic-in-${entry.dedupeKey}',
        form: 'traffic',
        text: '${entry.display}\n[指令]',
      );
    }
    return ChatMessage.synthetic(
      id: 'traffic-in-${entry.dedupeKey}',
      form: 'message',
      text: entry.display,
      role: 'user',
      framework: false,
    );
  }

  /// 回显去重（反方向）：真实消息在旁路卡片之后 3s 内落进日志，卡片让位给真实消息。
  /// 会改 `_traffic`，只在 `setState` 里调用。
  void _dropEchoedTraffic(List<ChatMessage> arrived) {
    if (_traffic.isEmpty || arrived.isEmpty) return;
    final now = DateTime.now();
    final bodies = [
      for (final message in arrived) _squeeze(message.bodyMarkdown),
    ]..removeWhere((body) => body.isEmpty);
    if (bodies.isEmpty) return;
    for (var i = _traffic.length - 1; i >= 0; i--) {
      final item = _traffic[i];
      if (now.difference(item.at) > _echoWindow) continue;
      final text = _squeeze(item.entry.display);
      if (text.isEmpty) continue;
      if (bodies.any((body) => body.contains(text))) _traffic.removeAt(i);
    }
  }

  /// 3s 内同内容已经进了 `_all`（`/events` 或重取）：这张卡是重复的。
  bool _echoed(String display) {
    final text = _squeeze(display);
    if (text.isEmpty) return false;
    final now = DateTime.now();
    _recentBodies.removeWhere((item) => now.difference(item.at) > _echoWindow);
    return _recentBodies.any((item) => item.body.contains(text));
  }

  /// 页面打开之前就有的消息：正文已在历史里就不补卡（连接开局的重放会带上它们）。
  bool _replayed(TrafficEntry entry) {
    if (!entry.time.isBefore(_t0)) return false;
    final text = _squeeze(entry.display);
    if (text.isEmpty) return false;
    return _all.any((message) => _squeeze(message.bodyMarkdown).contains(text));
  }

  /// 记录刚进日志的正文，给 [_echoed] 判回显；窗口外的旧条目顺手淘汰。
  void _noteBody(ChatMessage message) {
    final body = _squeeze(message.bodyMarkdown);
    if (body.isEmpty) return;
    final now = DateTime.now();
    _recentBodies
      ..removeWhere((item) => now.difference(item.at) > _echoWindow)
      ..add((body: body, at: now));
    if (_recentBodies.length > 40) {
      _recentBodies.removeRange(0, _recentBodies.length - 40);
    }
  }

  static final RegExp _spaces = RegExp(r'\s+');

  /// 比较用：压掉空白差异，避免换行/多空格让同一条对不上。
  static String _squeeze(String raw) => raw.replaceAll(_spaces, ' ').trim();

  /// 渲染列表：相邻且同标题的框架消息合并成一条虚拟消息（`id = 'a|b|c'`），
  /// 其余消息原样一行一条。合并只发生在渲染层，`_all` 本身不动；
  /// `/events` 追加后由下一次 build 重算，最后一条同标题的新消息自然并进同一块。
  List<_RenderRow> _renderRows() {
    final rows = <_RenderRow>[];
    var i = 0;
    while (i < _all.length) {
      final message = _all[i];
      final key = _mergeKey(message);
      final end = key == null ? i + 1 : _mergeEnd(i, key);
      if (end == i + 1) {
        rows.add(_RenderRow(message, srcEnd: end));
      } else {
        rows.add(
          _RenderRow(_mergeNotice(_all.sublist(i, end)), noticeCount: end - i, srcEnd: end),
        );
      }
      i = end;
    }
    // 旁路卡片接在真实消息之后：倒序列表里它们落在最底部（最新）。
    // 它们是页面侧合成消息、不进 `_all`，所以不参与上面的同标题合并，也不进 `/events` 的 id 去重。
    final traffic = [..._traffic]..sort((a, b) => a.entry.time.compareTo(b.entry.time));
    for (final item in traffic) {
      // 普通入站消息在正常会话里由 `/events` 画真实气泡，只有仅实时会话才需要兜底。
      if (!item.entry.outbound && !_liveOnly && !isCommandish(item.entry.display)) continue;
      // `srcEnd` 取 `_all.length + 1`：窗口换算里永远算可见（历史为空时也能命中）。
      rows.add(_RenderRow(_trafficMessage(item.entry), srcEnd: _all.length + 1));
    }
    return rows;
  }

  /// 合并键：只有**带结构标签**（`[memory update]` 这类）的框架消息才归组，其余一律返回 null。
  /// 用标签当键：`[memory update]` 与 `[memory update] Memory lines…` 属同一类型。
  /// 无标签的框架消息不能拿标题当前 24 字当键——`chatluna …` 这类短消息标题都等于首行开头，
  /// 会把内容完全不同的两条误并成一张卡。
  /// 旁路指令卡（`form: 'traffic'`，`[指令] …`）是逐条用户输入，同样不参与合并。
  static String? _mergeKey(ChatMessage message) {
    if (!message.isFramework) return null;
    if (message.form == 'traffic') return null;
    final body = message.bodyMarkdown;
    if (body.trim().isEmpty) return null;
    final tag = Notice.parse(body).tag;
    if (tag.isEmpty) return null;
    return Notice.key(tag);
  }

  /// 从 [start] 起连续同键框架消息的结束下标（不含）。
  int _mergeEnd(int start, String key) {
    var end = start + 1;
    while (end < _all.length && _mergeKey(_all[end]) == key) {
      end += 1;
    }
    return end;
  }

  /// 合并块：`id` 用 `first|second|…` 当折叠状态的键，正文用单个空行拼接；
  /// 第一条保留原文（结构头交给 `Notice.parse` 渲染成标题），其余去掉各自的结构标题行，
  /// 避免展开后同一行 `[memory update]` 反复出现。
  ChatMessage _mergeNotice(List<ChatMessage> group) {
    final parts = <String>[
      group.first.bodyMarkdown.trim(),
      for (final message in group.skip(1))
        Notice.parse(message.bodyMarkdown).lines.join('\n').trim(),
    ];
    final text = parts.where((part) => part.isNotEmpty).join('\n\n');
    return ChatMessage(
      id: [for (final message in group) message.id].join('|'),
      role: 'assistant',
      blocks: [ChatBlock('text', {'text': text})],
      form: 'notice',
      isFramework: true,
    );
  }

  void _scheduleStreamFlush() {
    _flushTimer ??= Timer(_streamFlushInterval, () {
      _flushTimer = null;
      _flushStreaming();
    });
  }

  void _flushStreaming() {
    final text = _streaming.toString();
    if (_streamingText.value != text) _streamingText.value = text;
  }

  /// SSE 断开后的兜底：每 1.2s 重取一次历史，最多 40 拍；已加载的消息一律不清空。
  /// 仅实时会话没有历史可取，不轮询。
  void _startPolling() {
    if (_liveOnly) return;
    _poll?.cancel();
    var ticks = 0;
    _poll = Timer.periodic(const Duration(milliseconds: 1200), (timer) async {
      if (!mounted || ticks++ > 40) {
        timer.cancel();
        return;
      }
      await _load();
    });
  }

  /// 滚到历史尽头时自动往前扩一页（倒序列表里 maxScrollExtent 是最早那条）。
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    // 位置一旦离开 0，说明用户（或尾部跟随）已经把列表滚开：首屏自动补页就此停手。
    if (position.pixels != 0) _autoFillDone = true;
    final away = position.pixels > 400;
    if (away != _awayFromBottom) setState(() => _awayFromBottom = away);
    if (_windowStart == 0) return;
    if (position.pixels < position.maxScrollExtent - 320) return;
    setState(() => _windowStart = (_windowStart - _initialWindow).clamp(0, _all.length));
  }

  void _jumpToLatest() {
    _unseen.value = 0;
    _scrollToLatest();
  }

  /// 倒序列表：offset 0 就是最新一条，不需要「跳到末尾」的动画。
  bool get _nearBottom => !_scroll.hasClients || _scroll.offset < 160;

  void _followIfAtBottom() {
    if (_nearBottom) _scrollToLatest();
  }

  void _scrollToLatest() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(0);
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _cancel() async {
    try {
      await widget.repo.cancel(widget.session.id);
      if (!mounted) return;
      _flushTimer?.cancel();
      _flushTimer = null;
      _streaming.clear();
      _streamingText.value = '';
      _setLive(LiveState.idle);
    } on ApiFailure catch (e) {
      _toast('取消失败 ${e.code}：${e.message}');
    }
  }

  Future<void> _compact() async {
    try {
      final result = await widget.repo.compact(widget.session.id);
      _toast('已压缩：${result ?? '完成'}');
      await _load();
    } on ApiFailure catch (e) {
      _toast('压缩失败 ${e.code}：${e.message}');
    }
  }

  Future<void> _fork() async {
    try {
      final child = await widget.repo.fork(widget.session.id);
      _toast('已分叉：${child.sessionId}（${child.length} 条）');
    } on ApiFailure catch (e) {
      _toast('分叉失败 ${e.code}：${e.message}');
    }
  }

  /// 切换过模型后，标题详情与信息栏都用最新的 `model`。
  SessionSummary get _summary => _model == widget.session.model
      ? widget.session
      : SessionSummary(
          id: widget.session.id,
          title: widget.session.title,
          createdAt: widget.session.createdAt,
          origin: widget.session.origin,
          running: widget.session.running,
          engine: widget.session.engine,
          model: _model,
          trafficOnly: widget.session.trafficOnly,
        );

  Future<void> _pickModel() async {
    final picked = await showModalBottomSheet<ModelRef>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ModelPickerSheet(
        repo: widget.repo,
        sessionId: widget.session.id,
        current: _model,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _model = picked);
    _toast('模型已切换到 ${shortModelLabel(picked)}');
  }

  List<String> _debugMetrics() {
    if (!kDebugMode) return const [];
    return [
      if (_netMs != null) 'net ${_netMs}ms',
      if (_paintMs != null) 'paint ${_paintMs}ms',
      if (_liveMs != null) 'live ${_liveMs}ms',
      if (_trafficStream != null) 'traffic ${_traffic.length}',
    ];
  }

  /// 列表首格：状态胶囊 + 流式正文。只有这一格监听 delta，整页不随 token 重建。
  /// 轮询中（failed）只留胶囊：buffer 里那半句正文已不可信，等重新载入的历史为准。
  Widget _liveSlot(ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _LiveCapsule(state: _live),
        if (_live.generating)
          ValueListenableBuilder<String>(
            valueListenable: _streamingText,
            builder: (context, text, _) => text.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: SelectableText(
                      text,
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
                    ),
                  ),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 渲染行：相邻同标题的框架消息已合并成块。`_windowStart` 仍是 `_all` 里的下标，
    // 换算到块：窗口起点落在某个块内部就整块显示（该块最早已可见）。
    final rows = _renderRows();
    final firstVisible = rows.indexWhere((row) => row.srcEnd > _windowStart);
    final visible = firstVisible < 0 ? 0 : rows.length - firstVisible;
    final generating = _live.generating;
    // 没有 agent 的会话（仅实时）：中止、压缩、分叉都无从谈起，菜单整个收起来。
    final agentless = _liveOnly || widget.session.trafficOnly;
    // 状态胶囊只在 thinking/replying/failed 时占位：待机会话的列表里绝不出现动画行。
    final slot = _live.hasCapsule ? 1 : 0;
    return Scaffold(
      appBar: AppBar(
        title: ChatTitle(
          title: _summary.title,
          onTap: () => showSessionDetails(context, _summary),
        ),
        actions: [
          if (!agentless)
            IconButton(
              onPressed: generating ? _cancel : null,
              icon: const Icon(Icons.stop_circle_outlined),
              tooltip: '中止当前生成',
            ),
          if (!agentless)
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'compact') _compact();
                if (value == 'fork') _fork();
                if (value == 'reload') _load();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'compact', child: Text('压缩上下文')),
                PopupMenuItem(value: 'fork', child: Text('分叉到新会话')),
                PopupMenuItem(value: 'reload', child: Text('重新载入')),
              ],
            ),
        ],
      ),
      floatingActionButton: AnimatedScale(
        scale: _awayFromBottom ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: FloatingActionButton.small(
          onPressed: _jumpToLatest,
          tooltip: '回到最新',
          child: ValueListenableBuilder<int>(
            valueListenable: _unseen,
            builder: (context, unseen, _) => Badge(
              isLabelVisible: unseen > 0,
              label: Text('$unseen'),
              child: const Icon(Icons.arrow_downward),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          ChatInfoBar(
            session: _summary,
            light: _live.statusLight,
            botName: widget.botName,
            avatarUrl: widget.avatarUrl,
            debugMetrics: _debugMetrics(),
            showDeveloperInfo: widget.showDeveloperInfo,
            // 仅实时会话在服务端不存在，切模型只会 404：不给入口。
            onModelTap: agentless ? null : _pickModel,
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null && _all.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                        const SizedBox(height: 12),
                        FilledButton(onPressed: _load, child: const Text('重试')),
                      ],
                    ),
                  )
                : _all.isEmpty && _traffic.isEmpty && _live == LiveState.idle
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        _liveOnly ? '该会话尚未加载历史，只显示实时消息' : '这个会话还没有消息',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    padding: EdgeInsets.fromLTRB(
                      16,
                      12,
                      16,
                      24 + MediaQuery.paddingOf(context).bottom,
                    ),
                    cacheExtent: 200,
                    itemCount: visible + slot + (firstVisible > 0 ? 1 : 0),
                    itemBuilder: (context, index) {
                      var cursor = index;
                      if (slot == 1) {
                        if (cursor == 0) return _liveSlot(theme);
                        cursor -= 1;
                      }
                      if (cursor < visible) {
                        final row = rows[rows.length - 1 - cursor];
                        return MessageView(
                          message: row.message,
                          noticeCount: row.noticeCount,
                          base: widget.base,
                          headers: widget.headers,
                          noticeOpen: _noticeOpen,
                          avatarUrl: widget.avatarUrl,
                        );
                      }
                      // 反向列表的末端 = 最早一条；进入视口即由 _onScroll 自动扩窗。
                      return const SizedBox(height: 32);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 一条已入列表的旁路消息 + 本地到达时间：回显去重要用「3s 内」，服务端时间是消息时间。
class _TrafficItem {
  const _TrafficItem(this.entry, this.at);

  final TrafficEntry entry;
  final DateTime at;
}

/// 渲染行：一行对应列表里的一个 `MessageView`。框架块可能是多条相邻同标题消息合并成的
/// 一条虚拟消息（`noticeCount` 是条数），[srcEnd] 是它在 `_all` 里的结束下标，窗口换算用。
class _RenderRow {
  const _RenderRow(this.message, {required this.srcEnd, this.noticeCount = 1});

  final ChatMessage message;

  /// 合并进这一块的框架消息条数；1 表示没有合并。
  final int noticeCount;

  /// 这一行最后一条消息在 `_all` 里的下标 + 1。
  final int srcEnd;
}

/// 实时状态胶囊：待机不出现（待机灯在信息栏）；「思考中」挂三点呼吸，
/// 「回复中」「轮询中」保持静态。动画随胶囊一起挂载/销毁——正文流入时不再有动画和长文本抢注意力。
class _LiveCapsule extends StatelessWidget {
  const _LiveCapsule({required this.state});

  final LiveState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 「待机」只属于信息栏的常驻灯，消息列表里不画这一行。
    if (!state.hasCapsule) return const SizedBox.shrink();
    final label = state.capsuleLabel;
    final thinking = state == LiveState.thinking;
    final failed = state == LiveState.failed;
    final accent = failed ? scheme.error : scheme.primary;
    return Container(
      padding: EdgeInsets.fromLTRB(10, 4, thinking ? 6 : 10, 4),
      decoration: BoxDecoration(
        color: failed
            ? scheme.errorContainer.withValues(alpha: 0.3)
            : scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 11,
              height: 1.2,
              letterSpacing: 0.2,
              color: accent,
            ),
          ),
          if (thinking) _ThinkingDots(color: accent),
        ],
      ),
    );
  }
}

/// 三个错峰呼吸的圆点：只在「思考中」里挂载。
class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots({required this.color});

  final Color color;

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 3,
        children: [
          for (var i = 0; i < 3; i++)
            Opacity(
              opacity:
                  0.25 +
                  0.75 *
                      (0.5 +
                          0.5 *
                              math.sin(
                                2 * math.pi * (_controller.value - i * 0.18),
                              )),
              child: Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
              ),
            ),
        ],
      ),
    );
  }
}

/// 模型选择弹层：按 provider 分组，选中即 POST 切换；失败留在弹层里给出原因。
class _ModelPickerSheet extends StatefulWidget {
  const _ModelPickerSheet({
    required this.repo,
    required this.sessionId,
    this.current,
  });

  final SessionsRepository repo;
  final String sessionId;
  final ModelRef? current;

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  late Future<Map<String, List<ModelOption>>> _future = widget.repo.models();
  final _search = TextEditingController();
  String? _pending;
  String? _error;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _retry() {
    setState(() {
      _error = null;
      _future = widget.repo.models();
    });
  }

  Future<void> _select(String provider, ModelOption option) async {
    if (_pending != null) return;
    final key = _keyOf(provider, option.id);
    setState(() {
      _pending = key;
      _error = null;
    });
    final picked = ModelRef(provider, option.id);
    try {
      await widget.repo.setModel(widget.sessionId, picked);
      if (!mounted) return;
      Navigator.of(context).pop(picked);
    } on ApiFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _pending = null;
        _error = '切换失败 ${e.code}：${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pending = null;
        _error = '切换失败：$e';
      });
    }
  }

  static String _keyOf(String provider, String model) => '$provider\u0000$model';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final query = _search.text.trim().toLowerCase();
    return SafeArea(
      top: false,
      // 键盘弹出时把弹层抬到键盘之上；高度上限 70% 屏高。
      minimum: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('选择模型', style: theme.textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                style: theme.textTheme.bodyMedium,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '搜索模型',
                  hintStyle: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  prefixIcon: Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
                  prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清空',
                          onPressed: () {
                            _search.clear();
                            setState(() {});
                          },
                          icon: const Icon(Icons.close, size: 16),
                        ),
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
            Flexible(
              child: FutureBuilder<Map<String, List<ModelOption>>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const SizedBox(
                      height: 160,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snapshot.hasError) {
                    final error = snapshot.error;
                    final message =
                        error is ApiFailure ? '${error.code}：${error.message}' : '$error';
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '模型列表加载失败：$message',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _retry,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('重试'),
                          ),
                        ],
                      ),
                    );
                  }
                  final grouped = snapshot.data ?? const <String, List<ModelOption>>{};
                  final rows = _rowsFor(grouped, query);
                  if (rows.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      child: Text(
                        query.isEmpty ? '实例没有可用模型' : '没有匹配的模型',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: rows.length,
                    itemBuilder: (context, index) => switch (rows[index]) {
                      _ProviderRow row => _providerHeader(row),
                      _OptionRow row => _tile(row.provider, row.option),
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 弹层是「分组头 + 模型行」的扁平序列，交给 `ListView.builder` 按需构建。
  /// 搜索只过滤模型行；分组头跟着存活的分组走，计数是过滤后的数量。
  List<_PickRow> _rowsFor(Map<String, List<ModelOption>> grouped, String query) {
    final rows = <_PickRow>[];
    for (final entry in grouped.entries) {
      final models = query.isEmpty
          ? entry.value
          : entry.value
                .where(
                  (option) =>
                      option.id.toLowerCase().contains(query) ||
                      option.label.toLowerCase().contains(query),
                )
                .toList();
      if (models.isEmpty) continue;
      rows.add(_ProviderRow(entry.key, models.length));
      for (final option in models) {
        rows.add(_OptionRow(entry.key, option));
      }
    }
    return rows;
  }

  /// 分组头：小号 written 标题 + 计数胶囊（与列表页 `_SectionHeader` 同风格）；
  /// 当前生效的 provider 在行尾多一枚「当前」胶囊。
  Widget _providerHeader(_ProviderRow row) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = widget.current?.provider == row.provider;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Text(
            row.provider,
            style: theme.textTheme.labelSmall?.copyWith(
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          _pill(
            '${row.count}',
            fill: scheme.surfaceContainerHighest,
            foreground: scheme.onSurfaceVariant,
          ),
          if (active) ...[
            const Spacer(),
            _pill(
              '当前',
              fill: scheme.primary.withValues(alpha: 0.12),
              foreground: scheme.primary,
            ),
          ],
        ],
      ),
    );
  }

  Widget _pill(String label, {required Color fill, required Color foreground}) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(20)),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          height: 1.4,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
      ),
    );
  }

  /// 模型行约 48dp：左侧勾选当前模型，标题是短名，副标题只在有独立 name 时出现。
  Widget _tile(String provider, ModelOption option) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = widget.current;
    final selected =
        current != null && current.provider == provider && current.model == option.id;
    final saving = _pending == _keyOf(provider, option.id);
    final name = option.name?.trim();
    final title = name == null || name.isEmpty
        ? shortModelLabel(ModelRef(provider, option.id))
        : name;
    final subtitle = option.id == title || option.label == option.id ? null : option.id;
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
      minVerticalPadding: 2,
      contentPadding: const EdgeInsets.only(left: 4, right: 16),
      minLeadingWidth: 22,
      enabled: _pending == null,
      leading: SizedBox(
        width: 22,
        child: selected ? Icon(Icons.check, size: 18, color: scheme.primary) : null,
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
      trailing: saving
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      onTap: _pending == null ? () => _select(provider, option) : null,
    );
  }
}

/// 模型弹层的一行：provider 分组头或一个模型。
sealed class _PickRow {
  const _PickRow();
}

class _ProviderRow extends _PickRow {
  const _ProviderRow(this.provider, this.count);

  final String provider;
  final int count;
}

class _OptionRow extends _PickRow {
  const _OptionRow(this.provider, this.option);

  final String provider;
  final ModelOption option;
}
