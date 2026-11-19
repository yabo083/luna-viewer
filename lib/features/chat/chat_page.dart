import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/capability/platform_repository.dart';
import '../../core/capability/platform_stream.dart';
import '../../core/capability/sessions_repository.dart';
import '../../core/design/app_tokens.dart';
import '../../core/model/models.dart';
import 'assistant_avatar.dart';
import 'chat_chrome.dart';
import 'message_view.dart';
import 'timeline.dart';
import 'turn_clock.dart';

/// 实时生成的唯一状态来源：`/live` 只提供「是否在跑、跑到哪一步」，
/// 消息本体一律来自插件（`platform/messages` + `platform/stream`）。
/// - `idle`：没有生成，列表首格不占位；信息栏只留一盏「待机」静灯；
/// - `thinking`：在跑但还没有正文（reasoning / 工具阶段）；
/// - `replying`：正文 delta 已到。
enum LiveState {
  idle,
  thinking,
  replying;

  /// 有生成在跑（思考或回复）：中止按钮与信息栏读它。
  bool get generating => this != LiveState.idle;

  /// 信息栏状态灯：待机灰点、思考中主色呼吸、回复中主色静止。
  StatusLight get statusLight => switch (this) {
    LiveState.idle => StatusLight.idle,
    LiveState.thinking => StatusLight.thinking,
    LiveState.replying => StatusLight.replying,
  };
}

/// 信息栏状态灯的唯一判定：
/// - `/live` 给了阶段就按阶段显示（思考/回复优先级最高）；
/// - `/live` 还没出声，但本轮计时表已开表、或入站消息后 6s 无帧 → 乐观的「思考中」；
/// - 再退到「轮询中」，最后才是「待机」。
/// 中止按钮不看这里（它只认计时表与 [LiveState]），乐观亮灯不会放开 Stop。
StatusLight statusLightFor({
  required LiveState live,
  required bool optimisticThinking,
  required bool polling,
}) {
  if (live != LiveState.idle) return live.statusLight;
  if (optimisticThinking) return StatusLight.thinking;
  if (polling) return StatusLight.polling;
  return StatusLight.idle;
}

/// 会话详情：消息**只来自插件**，`/api/sessions*` 只提供已加载会话的状态与操作。
/// v0.1.0 不在 App 里发消息——平台会话的输入仍由聊天软件承担。
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.repo,
    required this.platform,
    required this.base,
    required this.headers,
    required this.conversationKey,
    required this.title,
    required this.origin,
    this.session,
    this.avatarUrl,
    this.botName,
    this.showDeveloperInfo = false,
    this.onAuthExpired,
  });

  /// 已加载会话的操作入口（中止/压缩/分叉/换模型）；不是消息来源。
  final SessionsRepository repo;

  /// 消息真源。
  final PlatformRepository platform;
  final Uri base;
  final Map<String, String> headers;

  /// 插件侧会话键（原样透传，带 `route:` 前缀也能用）。
  /// 请求 `/api/platform/messages` 必须用它——插件按自己存的原键查表；
  /// 与实时帧比较时才归一化，两者不要混用。
  final String conversationKey;

  /// 展示名：插件给的会话名，或已加载会话的标题。
  final String title;

  /// 平台名（`qq` 等），只用于详情面板。
  final String origin;

  /// 非空 = 该会话同时出现在 `/api/sessions`：保留状态胶囊与会话级操作。
  final SessionSummary? session;

  /// **bot 自己的头像**：`dir=out` 的气泡与信息栏用它。
  /// 对方/群的头像不走这里——`dir=in` 用该条消息自带的 `avatar`，会话列表行用 `conversation.avatar`。
  final String? avatarUrl;
  final String? botName;

  /// 设置里的「显示平台/引擎/性能信息」，由会话列表页传入。
  final bool showDeveloperInfo;

  /// 凭证失效（401）且用户确认重新连接时调用：由根节点清 token 并回连接页。
  /// 为 null 时只在页内提示，不再重试。
  final Future<void> Function()? onAuthExpired;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  /// 一页的消息条数；向上滚动时按「更早一页」继续取。
  static const _pageSize = 50;

  /// 状态轮询间隔：未加载时探测「agent 被认领了没」，`/live` 断开时兜底读 running。
  /// 3s 跟得上「QQ 里发一条消息 → 服务端建会话 → agent 加载」，又不至于变成高频请求。
  static const _pollInterval = Duration(seconds: 3);

  /// 探测页只看第一页：新会话由服务端按最近活动排在最前，一页足够。
  static const int _pollPageSize = 50;

  /// `/live` 掉线后的重连间隔：轮询先顶上，流晚一点接回来。
  static const _liveRetryDelay = Duration(seconds: 9);

  final _scroll = ScrollController();

  /// 会话是否已被 ChatLuna 加载：进入详情时可能还没加载（QQ 里刚发第一条消息），
  /// 之后的轮询会把它补上。`widget.session` 只是进入时的快照。
  SessionSummary? _session;

  /// 已加载的消息，时间升序（最新在末尾；倒序列表把它按 index 反过来渲染）。
  List<PlatformMessage> _messages = const [];

  /// [PlatformMessage] 列表的版本号：每次换列表都 `+1`，时间线按它判断要不要重算。
  /// 只换列表内容、不换对象（如脚注时间戳）时不递增也不影响时间线结构。
  int _messagesRev = 0;

  /// 已入列的消息 id：分页、实时帧、重载三条路都靠它去重。
  final Set<String> _ids = {};

  /// 已确认连续的最早时间：翻页游标用它，而不是 `_messages.first.time`。
  /// 实时流会补发比当前最早一条更早的消息，用数组首元素会让游标倒退、反复取同一段。
  DateTime? _earliest;

  /// 框架消息（wake/memory/工具摘要等）：只对已加载会话从 `/api/sessions/:id/messages`
  /// 与 `/events` 取。平台消息里没有这些，所以单独一条时间线，渲染成居中单卡片。
  /// 列表按时间升序维护（[orderNotices]），渲染时与平台消息合并排序。
  List<TimelineNotice> _framework = const [];
  final Set<String> _frameworkIds = {};

  /// [TimelineNotice] 列表的版本号（见 [_messagesRev]）。
  int _frameworkRev = 0;

  /// 时间线的记忆化结果：`build()` 不再全量合并排序（300 条时是每帧 O(n log n)）。
  /// 流式 tick 只更新 `_streamingText`，不进 `build`，因此这里不会失效。
  List<TimelineItem>? _items;
  int _itemsMessagesRev = -1;
  int _itemsFrameworkRev = -1;

  /// 框架块上限：长开页面只留最近的，避免无限增长。
  static const int _frameworkCap = 400;

  StreamSubscription<SessionEvent>? _eventsSub;
  bool _eventsStarted = false;
  Timer? _eventsRetry;
  /// `/events` 断线退避 1→2→4→8→30s（401 时停表）。
  int _eventsBackoff = 1;
  /// `/events` 空闲判死：服务端连 `: ping` 都不发时，订阅会永远挂着。
  Timer? _eventsIdleTimer;
  static const _eventsIdle = Duration(seconds: 20);
  bool _frameworkStarted = false;

  /// `truncated` 帧触发的全量重取合并：短时间多帧只重取一次。
  Timer? _truncatedRefresh;

  /// `/events` 的续传游标（`<sessionId>:<n>`）：订阅时只补日志 head 之后的帧。
  /// 不带它会把整段历史重放一遍，上一轮的 mark 会被当成这一轮的起点。
  String? _eventsSince;

  /// 订阅开始的本地时刻：重放的历史帧按它的时间戳丢掉，不能把旧 mark 当成本轮。
  DateTime? _eventsOpenedAt;

  /// 会话日志是否已经取过（成败都算）：`/events` 等它决定从哪儿接。
  bool _transcriptLoaded = false;

  /// 框架消息折叠状态表：折叠键 → 是否展开。
  final Map<String, bool> _noticeOpen = {};

  /// 时间线项的 Widget 缓存：同一条消息在后续 setState 里复用同一个实例，
  /// `ListView` 因此跳过整棵 markdown 重建（滚动之外的主要开销）。
  /// 上限 [ _itemCacheCap ] 条，按最近使用淘汰：长开大群时不再无限保留整棵 markdown。
  final Map<String, Widget> _itemCache = {};
  static const int _itemCacheCap = 200;

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;

  /// 流式正文：`/live` 的 text delta 只进 buffer，最多每 90ms 刷进 notifier；
  /// 列表里的流式气泡单独监听，不随每个 delta 重建整页。
  final StringBuffer _streaming = StringBuffer();
  final ValueNotifier<String> _streamingText = ValueNotifier<String>('');
  static const _streamFlushInterval = Duration(milliseconds: 90);
  Timer? _flushTimer;

  StreamSubscription<LiveEvent>? _liveSub;
  Timer? _snapshotTimer;
  /// `/live` 每帧重置的空闲计时器：首帧之后半死（不再出帧也不 FIN）时主动判死重连。
  Timer? _liveIdleTimer;
  static const _liveIdle = Duration(seconds: 20);
  bool _liveStarted = false;
  DateTime? _liveDownAt;

  /// 401 之后所有后台表都必须停：继续重试不会恢复，只会一直打服务端。
  bool _authFailed = false;

  /// 状态轮询表：未加载时探测会话，`/live` 掉线时兜底读 running。
  /// 页面不可见（App 后台 / 被别的路由盖住）或已加载且流在线时停表。
  Timer? _pollTimer;
  Timer? _liveRetryTimer;
  bool _pollInFlight = false;
  bool _foreground = true;

  /// `/live` 不在线：状态来自轮询，信息栏显示「轮询中」。
  bool _polling = false;

  /// 首个 snapshot 是否已到：权威帧之前，`session.running` 只是乐观值。
  bool _snapshotSeen = false;

  PlatformStream? _stream;
  StreamSubscription<PlatformEvent>? _streamSub;

  LiveState _live = LiveState.idle;

  /// 乐观的「思考中」：入站消息后 6s 没有 `/live` 帧时先亮灯，探测/真实帧到达再回落。
  /// 只影响状态灯，不改 [_live]——中止按钮的可用性判定不跟着变。
  bool _optimisticThinking = false;

  /// `/live` 是否已经对当前这一段给出「没在生成」的结论（无 attempt 的快照、settled、
  /// 轮询读到 running=false）。计时表在跑但它为真时，状态灯按「停了」回落。
  bool _liveSettled = true;

  /// 服务端已把会话卸载（`/live`、`/events`、`/messages` 回 404）：本页就地降级成
  /// 「未加载」，不再自动重连或重登。要恢复只能返回列表重新打开（重新查一次加载态）。
  bool _sessionGone = false;

  /// 中止请求在途：按钮暂时置灰，避免连点发出两次 cancel。
  bool _cancelling = false;

  /// 本轮是否在跑：由 [TurnClock] 的收表状态驱动，不依赖 `/live` 有没有出帧。
  bool _turnActive = false;

  /// 整轮 + 分阶段计时：起点是 turn_start（`/events` 入队 mark 与首个 active snapshot 取更早），
  /// 终点是「生成已停 + 最后一条 bot 外发落库」，取更晚者。结束后冻结 2s，
  /// 再弱化成常驻的「上一轮 1m04s」。
  /// 只有信息栏里那一枚小字监听它，列表与页面不随 tick 重建。
  final TurnClock _clock = TurnClock();

  /// 外发落库后确认一次 `running`：投递到 settle 之间还差 1–2s，不能用 settled 当终点。
  Timer? _runningCheck;

  /// 本轮骨架气泡：turn_start 插到列表末尾，结束/中止后按情况移除。
  /// 插入与移除才 `setState`，秒级读数由骨架内部的 `ValueListenableBuilder` 刷新。
  _SkeletonPhase _skeleton = _SkeletonPhase.none;
  bool _skeletonAborted = false;

  /// 中止后「重新发送」用的原文：这一轮触发时最后一条入站消息。
  String? _skeletonResend;
  Timer? _skeletonHold;
  Timer? _skeletonFade;

  /// 本轮里是否已经有 bot 外发消息落库：有就说明真实气泡已经在了，骨架可直接撤。
  bool _outboundInRound = false;

  /// 本轮新落库的外发消息 id（按到达顺序）：脚注只盖在本轮的最后一颗气泡上，
  /// 不能回头改写上一轮那条——否则会算出 0.0s 这种假读数。
  final List<String> _roundOutboundIds = <String>[];

  /// 骨架当前对应的轮次号（[TurnClockView.round]）：换轮才清空本轮的外发标记。
  int _skeletonRound = -1;

  /// 一次「turn」可能由多个 attempt/round 组成（异步工具会让引擎开新的一轮）：
  /// 脚注要按 turn 汇总，而不是按我们自己的 round 切。
  final List<String> _turnOutboundIds = <String>[];

  /// 在跑的工具调用：`callId → 阶段名`。`tool-result` 按 callId 精确配对，
  /// 同名工具重试或与前一步的「思考」并存时不会关错段。
  final Map<String, String> _openToolCalls = <String, String>{};

  /// 没有 callId 的老帧：按先进先出配对。
  final List<String> _openToolNames = <String>[];

  /// 平台流先到消息说明这一轮要开始了：`/live` 若在这之后一帧不发（手机切网后常见的
  /// 半死连接），就用服务端的 `running` 兜底——只看服务端怎么说，不猜阶段。
  Timer? _probeDelay;
  Timer? _probeTimer;
  Timer? _probeDeadline;
  DateTime? _probeStartedAt;

  /// 最近一次收到 `/live` 帧（含 snapshot）：探测用它判断流是不是真的在说话。
  DateTime? _lastLiveAt;

  static const _probeDelaySpan = Duration(seconds: 6);
  static const _probeInterval = Duration(seconds: 3);
  static const _probeSpan = Duration(seconds: 45);

  /// 打开页面前几秒收到的是平台流回放的历史消息，不参与本轮起止判断。
  static const _replayWindow = Duration(seconds: 3);

  bool _awayFromBottom = false;
  final ValueNotifier<int> _unseen = ValueNotifier<int>(0);

  /// 会话当前模型；切换成功后立即反映到信息栏与详情。
  ModelRef? _model;

  /// bot 身份（名字 + 头像）：列表页取过就原样带上；没带上（WS 慢/失败）时
  /// 详情页自己从同一份缓存补一次，取不到头像就交给 `AssistantAvatar` 渐变占位。
  String? _botName;
  String? _botAvatar;

  /// 首屏时间与首个网络/实时事件的耗时，开发者信息里显示。
  late final DateTime _t0;
  int? _netMs;
  int? _liveMs;

  /// 首帧真正上屏的耗时（debug 头部显示）：点击到可见反馈的一部分。
  int? _paintMs;

  @override
  void initState() {
    super.initState();
    _t0 = DateTime.now();
    _session = widget.session;
    _model = _session?.model;
    // 列表页已经取过 bot 身份：优先用它的缓存，避免详情页再开一次 WS。
    _botName = widget.botName ?? BotIdentity.profileFor(widget.base)?.name;
    _botAvatar = absoluteResourceUrl(
      widget.base,
      widget.avatarUrl ?? BotIdentity.avatarFor(widget.base),
    );
    // 列表页的 running 只做乐观值：首个 snapshot 到达后一律以服务端为准。
    _live = (_session?.running ?? false) ? LiveState.thinking : LiveState.idle;
    // 打开页面时已经在跑：本轮从打开这一刻开始计时，之后的事件只接受更早的起点。
    if (_live.generating) _clock.start();
    // 骨架气泡的插入/移除只在这条通知里判断；秒级读数由骨架自己监听同一个 notifier。
    _clock.view.addListener(_onClockTick);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addObserver(this);
    _load();
    // 首帧先画出来再连实时流：SSE 握手与首个 snapshot 会和首屏排版抢时间。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 首帧上屏时间：点击 → 可见反馈的本地耗时，debug 头部显示。
      _paintMs ??= _since();
      // 未加载的会话没有 agent：`/live` 只会 404，不连；先起 3s 探测表，
      // agent 一被加载就接上 `/live` 与操作菜单。
      if (_loaded) {
        _startLive();
        // 增量事件同样放到首帧之后：它只补充中间块，不能拖慢首屏。
        _startEvents();
      }
      _startStream();
      _ensurePolling();
      // 列表页取头像还没回来（或失败）：详情页自己补一次，成功前用渐变占位。
      if (_botName == null || _botAvatar == null) unawaited(_loadBotIdentity());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // `ModalRoute.of` 依赖路由状态：被别的路由盖住（含弹层、左缘右滑返回）时
    // isCurrent 变化会重走进来，据此停表 / 重新起表，不需要全局 RouteObserver。
    _ensurePolling();
    // 被别的路由盖住：兜底探测也停（没有屏幕可看）。
    if (!_routeVisible) _stopProbe();
    // 重新露出来时立刻把 `/live` 接回来：轮询只是兜底，别让它长期替代真实阶段。
    if (_loaded && _polling && !_liveStarted) _startLive();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      // 回前台按真实墙钟重算：后台那段也算进本轮（用户离开 3 秒但实际过了 30 秒）。
      _clock.resume();
      _ensurePolling();
      // 回前台立刻补一拍，不等下一个 3s；`/live` 掉了也在这里接回来。
      if (_pollTimer != null) unawaited(_pollTick());
      // 后台被显式掐断的三路流在这里按需重建。三个 `_start*` 都有「已启动」闸门，
      // 所以 inactive→resumed 这类没经过 paused 的切换不会叠出第二条订阅。
      if (_loaded) {
        _startLive();
        _startEvents();
      }
      _startStream();
    } else {
      // 切后台：没有屏幕可看，定时器不该继续空转，时钟本身不停。
      _clock.suspend();
      _stopProbe();
      _stopPolling();
      // paused 时三路 SSE 必须断开：后台广播帧会持续唤醒主 isolate 解析 JSON。
      if (state == AppLifecycleState.paused) _pauseStreams();
    }
  }

  /// 切后台：显式断开 `/live`、`/events`、平台流，并把启动闸门复位。
  /// 只置空订阅不够——不复位闸门，回前台的重建会被「已启动」判断直接跳过。
  void _pauseStreams() {
    _liveSub?.cancel();
    _liveSub = null;
    _liveStarted = false;
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
    _liveRetryTimer?.cancel();
    _liveRetryTimer = null;
    _eventsSub?.cancel();
    _eventsSub = null;
    _eventsStarted = false;
    _eventsRetry?.cancel();
    _eventsRetry = null;
    _eventsIdleTimer?.cancel();
    _eventsIdleTimer = null;
    _truncatedRefresh?.cancel();
    _truncatedRefresh = null;
    _runningCheck?.cancel();
    _runningCheck = null;
    _liveIdleTimer?.cancel();
    _liveIdleTimer = null;
    _streamSub?.cancel();
    _streamSub = null;
    _stream?.dispose();
    _stream = null;
    // 流断了，后台也不该再排重连/补帧：回来时由 resumed 分支重建。
    _flushTimer?.cancel();
    _flushTimer = null;
    _streaming.clear();
    _streamingText.value = '';
    // 后台没有屏幕可看：把这一页的 Widget/解析缓存放掉。
    // 历史消息本身不删，回前台按需重建（当前屏的几颗气泡）。
    // 解码位图**不在这里清**：切一次后台就清会让回前台的头像/图片全部重新解码
    // （甚至重新下载），是「头像反复加载」的直接诱因。整进程的清理交给
    // `main.dart` 的 60s 后台计时器与内存压力回调。
    _itemCache.clear();
    MessageView.clearCaches();
    clearNoticeKeys();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock.view.removeListener(_onClockTick);
    _clock.dispose();
    _runningCheck?.cancel();
    _skeletonHold?.cancel();
    _skeletonFade?.cancel();
    _stopProbe();
    _pollTimer?.cancel();
    _liveRetryTimer?.cancel();
    _scroll.removeListener(_onScroll);
    _flushTimer?.cancel();
    _streamingText.dispose();
    _unseen.dispose();
    _liveSub?.cancel();
    _liveIdleTimer?.cancel();
    _eventsSub?.cancel();
    _eventsRetry?.cancel();
    _eventsIdleTimer?.cancel();
    _truncatedRefresh?.cancel();
    _streamSub?.cancel();
    _stream?.dispose();
    _snapshotTimer?.cancel();
    _itemCache.clear();
    // 这一页的正文解析结果与对齐键随页面释放（进程级缓存，退出详情页不该常驻）。
    MessageView.clearCaches();
    clearNoticeKeys();
    _scroll.dispose();
    super.dispose();
  }

  int _since() => DateTime.now().difference(_t0).inMilliseconds;

  bool get _loaded => _session != null;

  /// 详情页是否在最前：被别的路由盖住时不算可见（不探测、不轮询）。
  bool get _routeVisible => ModalRoute.of(context)?.isCurrent ?? true;

  // ------------------------------------------------------------ 加载状态轮询

  /// 轮询表的唯一开关：
  /// - 未加载 → 每 3s 探一次 `/api/sessions`，一旦命中就接 `/live` 并停表；
  /// - 已加载但 `/live` 掉线 → 每 3s 兜底读 `running`；
  /// - 页面不可见（App 后台 / 被别的路由盖住）→ 停表；
  /// - 已加载且流在线 → 停表。
  void _ensurePolling() {
    final needed =
        !_authFailed &&
        !_sessionGone &&
        _foreground &&
        _routeVisible &&
        (!_loaded || _polling);
    if (needed) {
      _pollTimer ??= Timer.periodic(
        _pollInterval,
        (_) => unawaited(_pollTick()),
      );
    } else {
      _stopPolling();
    }
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _pollTick() async {
    if (!mounted || _pollInFlight) return;
    if (!_foreground || !_routeVisible) {
      _stopPolling();
      return;
    }
    _pollInFlight = true;
    try {
      final match = await _lookupSession();
      if (!mounted) return;
      if (!_loaded) {
        // 404 降级后不再自动重挂：服务端的 `/api/sessions` 可能还会短暂列出它，
        // 重挂只会再撞一次 404，来回刷提示。
        if (match != null && !_sessionGone) _attach(match);
        return;
      }
      // 已加载、`/live` 不在线：只能从 `running` 判断有没有在生成，
      // 分不清思考/回复，所以按「思考中」展示——用户至少知道 bot 在干活。
      if (_polling) {
        final running = match?.running ?? false;
        // 轮询读到 running=false 才是这一轮真正停了：投递之后的那 1–2s 也还在本轮里。
        if (!running) _clock.stopped();
        _setLive(running ? LiveState.thinking : LiveState.idle);
      }
    } on ApiFailure catch (e) {
      // 凭证失效不会自己恢复：停表并提示重新连接；其余网络抖动等下一拍。
      if (e.isUnauthorized) {
        _handleAuthFailure();
      }
    } catch (_) {
      // 坏字段/未预期异常同样只算这一拍失败，不能逃进 Zone。
    } finally {
      _pollInFlight = false;
      if (mounted) _ensurePolling();
    }
  }

  /// 列表第一页里按归一化会话键找这条会话：未加载时确认它是否已被 agent 认领，
  /// 兜底时读它的 `running`。
  Future<SessionSummary?> _lookupSession() async {
    final page = await widget.repo.list(limit: _pollPageSize);
    final key = normalizeConversationKey(widget.conversationKey);
    for (final item in page.items) {
      if (normalizeConversationKey(item.id) == key) return item;
    }
    return null;
  }

  // -------------------------------------------------------------- 生成兜底探测

  /// 这条会话有新消息进来：给 `/live` [_probeDelaySpan] 证明自己还活着。
  /// 一帧都没有就开一段兜底轮询——服务端说在跑就亮「思考中」，说没跑就回待机。
  /// 这样即使流是半死的，状态灯与中止按钮也不会永远停在待机。
  void _armRoundProbe() {
    if (!_foreground || !_routeVisible) return;
    final armedAt = DateTime.now();
    _probeDelay?.cancel();
    _probeDelay = Timer(_probeDelaySpan, () {
      _probeDelay = null;
      final last = _lastLiveAt;
      if (!mounted || (last != null && last.isAfter(armedAt))) return;
      // 6s 一帧都没有：先亮「思考中」（乐观），探测读到 running=false 再回落。
      // 等首个 HTTP 返回才亮灯，网络差时会白白空着十几秒。
      _markOptimisticThinking();
      _startProbe();
    });
  }

  /// 计时表/入站消息已经说明这一轮在跑，但 `/live` 还没发话：状态灯先亮「思考中」。
  void _markOptimisticThinking() {
    if (_live != LiveState.idle || _optimisticThinking || !mounted) return;
    setState(() => _optimisticThinking = true);
  }

  void _startProbe() {
    _probeTimer?.cancel();
    _probeDeadline?.cancel();
    _probeStartedAt = DateTime.now();
    _probeTimer = Timer.periodic(
      _probeInterval,
      (_) => unawaited(_probeTick()),
    );
    _probeDeadline = Timer(_probeSpan, _stopProbe);
    unawaited(_probeTick());
  }

  void _stopProbe() {
    _probeDelay?.cancel();
    _probeDelay = null;
    _probeTimer?.cancel();
    _probeTimer = null;
    _probeDeadline?.cancel();
    _probeDeadline = null;
    _probeStartedAt = null;
  }

  /// 兜底读一次 `running`：`/live` 一旦恢复出帧就立刻让位（帧能分思考/回复，比它细）。
  Future<void> _probeTick() async {
    if (!mounted || !_foreground || !_routeVisible) {
      _stopProbe();
      return;
    }
    final startedAt = _probeStartedAt;
    final last = _lastLiveAt;
    if (startedAt != null && last != null && last.isAfter(startedAt)) {
      _stopProbe();
      return;
    }
    if (_pollInFlight) return;
    _pollInFlight = true;
    try {
      final match = await _lookupSession();
      if (!mounted) return;
      // 流已掉线：3s 轮询接管状态，这里不用插手。
      if (_polling || !_liveStarted) {
        _stopProbe();
        return;
      }
      // `running` 只能分出「在跑 / 没跑」，所以报「思考中」；恢复出帧后由帧细化。
      // 已经有正文在流时保持现状：不要把「回复中」降级成「思考中」。
      final running = match?.running ?? false;
      if (!running) {
        _clock.stopped();
        _setLive(LiveState.idle);
      } else if (_streaming.isEmpty) {
        _setLive(LiveState.thinking);
      }
    } on ApiFailure catch (e) {
      if (e.isUnauthorized) {
        _handleAuthFailure();
      }
      // 兜底也是尽力而为：网络抖动等下一拍。
    } catch (_) {
      // 同上：单拍失败不影响消息流。
    } finally {
      _pollInFlight = false;
    }
  }

  /// 探测命中：会话刚被 agent 认领，补上信息栏、操作菜单、`/live`、框架块与事件流。
  void _attach(SessionSummary session) {
    if (!mounted) return;
    setState(() {
      _session = session;
      _model = session.model;
    });
    // 服务端说在跑：先挂乐观的「思考中」，首个 snapshot 会纠正。
    if (session.running) _setLive(LiveState.thinking);
    // 已加载：探测表该收了（`/live` 在线后不会再打开）。
    _ensurePolling();
    unawaited(_loadFramework());
    _startLive();
    _startEvents();
  }

  /// `/live` 不掉线时，状态灯的第四种「轮询中」由这里接管。
  StatusLight get _statusLight => statusLightFor(
    live: _live,
    optimisticThinking: _optimisticThinking || _clockActiveForLight,
    polling: _polling,
  );

  /// 本轮计时表已开表（读数非空且未收表），而 `/live` 还没有说「停了」：
  /// 状态灯据此先亮「思考中」，不再等迟到十几秒的首个 active 快照。
  bool get _clockActiveForLight {
    final view = _clock.view.value;
    return view != null && !view.finished && !_liveSettled;
  }

  /// 列表页没拿到 bot 身份时补一次：`adapters.bots` 全进程只取一次（见 [BotIdentity]）。
  Future<void> _loadBotIdentity() async {
    final token = _bearer;
    if (token == null || token.isEmpty) return;
    await BotIdentity.load(base: widget.base, token: token);
    if (!mounted) return;
    final bot = BotIdentity.profileFor(widget.base);
    if (bot == null) return;
    setState(() {
      _botName = bot.name;
      _botAvatar = absoluteResourceUrl(
        widget.base,
        BotIdentity.avatarFor(widget.base),
      );
    });
    // 消息头像按消息 id 缓存了 Widget：身份更新后丢一次，右侧气泡才会换上真实头像。
    _itemCache.clear();
  }

  /// 401：停掉轮询、探测与三路流，只提示一次「重新连接」。
  /// 继续按原节奏重试只会永远 401（token 被轮换 / 设备被踢），并且耗电。
  void _handleAuthFailure() {
    if (_authFailed) return;
    _authFailed = true;
    _stopPolling();
    _stopProbe();
    _liveStarted = false;
    _liveSub?.cancel();
    _liveSub = null;
    _liveIdleTimer?.cancel();
    _liveIdleTimer = null;
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
    _liveRetryTimer?.cancel();
    _liveRetryTimer = null;
    _eventsStarted = false;
    _eventsSub?.cancel();
    _eventsSub = null;
    _eventsRetry?.cancel();
    _eventsRetry = null;
    _eventsIdleTimer?.cancel();
    _eventsIdleTimer = null;
    _truncatedRefresh?.cancel();
    _truncatedRefresh = null;
    _streamSub?.cancel();
    _streamSub = null;
    _stream?.dispose();
    _stream = null;
    if (mounted) _setLive(LiveState.idle);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('登录已失效'),
        content: const Text('实例的访问 token 已失效。重新连接并输入新的 token 后才能继续。'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              // 详情页是压栈路由：先回到列表，再由根节点清凭证切到连接页。
              Navigator.of(context).popUntil((route) => route.isFirst);
              unawaited(widget.onAuthExpired?.call() ?? Future<void>.value());
            },
            child: const Text('重新连接'),
          ),
        ],
      ),
    );
  }

  /// 服务端把会话卸载了（`/live`、`/events`、`/messages` 都回 404 `NOT_FOUND`）：
  /// 就地降级成「未加载」——收起信息栏状态灯与中止/菜单、清掉实时流与计时，
  /// 只提示一次。不重连、不重登：404 不会自己恢复，继续退避只会反复撞同一个错。
  /// 也不重启 3s 探测：服务端在这段时间里仍可能把会话列在 `/api/sessions`，
  /// 重挂只会再撞一次 404。返回列表重新打开会重新问一次加载态。
  void _handleSessionUnloaded() {
    if (!mounted || _session == null) return;
    _sessionGone = true;
    _liveStarted = false;
    _liveSub?.cancel();
    _liveSub = null;
    _liveIdleTimer?.cancel();
    _liveIdleTimer = null;
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
    _liveRetryTimer?.cancel();
    _liveRetryTimer = null;
    _eventsStarted = false;
    _eventsSub?.cancel();
    _eventsSub = null;
    _eventsRetry?.cancel();
    _eventsRetry = null;
    _eventsIdleTimer?.cancel();
    _eventsIdleTimer = null;
    _truncatedRefresh?.cancel();
    _truncatedRefresh = null;
    _runningCheck?.cancel();
    _runningCheck = null;
    _stopProbe();
    _stopPolling();
    _flushTimer?.cancel();
    _flushTimer = null;
    _streaming.clear();
    _streamingText.value = '';
    // 会话已经不在服务端：本轮不可能再有投递，计时表按「停止」收尾。
    _clock.stopped();
    _snapshotSeen = false;
    _polling = false;
    _optimisticThinking = false;
    _liveSettled = true;
    _live = LiveState.idle;
    setState(() => _session = null);
    _toast('会话已在服务端卸载');
  }

  /// 错误页/HTML 正文不进 UI：只给稳定的短文案，原正文留在 ApiFailure 里供调试。
  static String _displayFailure(ApiFailure failure) {
    final message = failure.message;
    final looksLikePage =
        message.contains('<') || message.contains('\n') || message.length > 160;
    if (looksLikePage) {
      final status = failure.status == null ? '' : '（HTTP ${failure.status}）';
      return '${failure.code}：服务器返回了错误$status';
    }
    return '${failure.code}：$message';
  }

  // ---------------------------------------------------------------- 消息加载

  /// 最新一页（首次进入、重载、失败重试共用）。已经通过实时流进来的更新消息不会被丢掉。
  Future<void> _load() async {
    try {
      final page = await widget.platform.messages(
        widget.conversationKey,
        limit: _pageSize,
      );
      if (!mounted) return;
      _netMs ??= _since();
      setState(() {
        _loading = false;
        _error = null;
        _mergeNewest(page);
        _hasMore = page.hasMore;
      });
    } on ApiFailure catch (e) {
      if (!mounted) return;
      if (e.isUnauthorized) {
        _handleAuthFailure();
        return;
      }
      setState(() {
        _loading = false;
        _error = _displayFailure(e);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败，请稍后重试';
      });
    } finally {
      // 首页结果出来后再补框架块：这样日志里的平台消息能给框架条目当时间锚点。
      unawaited(_loadFramework());
    }
  }

  /// 用最新一页对齐：页内的消息以服务端为准，页外更新的（流式期间刚到的）保留在后面。
  void _mergeNewest(PlatformMessagePage page) {
    // 页内也可能重复给同一条（服务端拼接两段）：按 id 只留第一条。
    final pageIds = <String>{};
    final items = <PlatformMessage>[
      for (final message in page.items)
        if (pageIds.add(message.id)) message,
    ];
    final newest = items.isEmpty ? null : items.last.time;
    final newer = <PlatformMessage>[
      for (final message in _messages)
        if (!pageIds.contains(message.id) &&
            (newest == null || message.time.isAfter(newest)))
          message,
    ];
    _setMessages([...items, ...newer]);
    _earliest = items.isEmpty ? null : items.first.time;
    _ids
      ..clear()
      ..addAll(pageIds)
      ..addAll(newer.map((message) => message.id));
  }

  // -------------------------------------------------------------- 框架消息

  /// 已加载会话才有日志：额外拉一次 `/api/sessions/:id/messages`，只收框架消息
  /// （wake / memory / 工具摘要等），渲染成居中单卡片插回时间线。
  /// 未加载的会话没有日志可拉，直接不显示框架块。
  Future<void> _loadFramework({bool force = false}) async {
    final session = _session;
    if (_authFailed || session == null) return;
    if (_frameworkStarted && !force) return;
    _frameworkStarted = true;
    try {
      final transcript = await widget.repo.transcript(session.id);
      if (!mounted) return;
      // 不带游标订阅：`/messages` 的 `length` 不是日志 `n`（实测 167 vs 380），
      // 拿它当 Last-Event-ID 会让服务端卡在空窗口里什么都不发。
      // 历史重放由 [_onSessionEvent] 按帧时间过滤；强制重载时把过滤基准也前移，
      // 否则重新打开游标后重放的历史 mark 会被当成本轮。
      _eventsSince = null;
      if (force) _eventsOpenedAt = DateTime.now();
      final log = transcript.messages;
      // 平台消息正文 → 时间：日志里的平台消息有时没时戳，框架块也要靠它定锚。
      final platformTimes = <String, DateTime>{};
      for (final message in _messages) {
        final key = noticeKey(message.content);
        if (key.isNotEmpty) platformTimes.putIfAbsent(key, () => message.time);
      }
      // 日志每一行可用的时间：平台消息没给时戳时，用已加载消息的正文对齐补上。
      final at = List<DateTime?>.filled(log.length, null);
      for (var i = 0; i < log.length; i++) {
        final message = log[i];
        if (message.isFramework) continue;
        at[i] =
            message.time ??
            platformTimes[noticeKey(message.bodyMarkdown.trim())];
      }
      // 反向扫一遍：每条日志后面第一条平台消息的时间，给「前面还没有消息」的框架块当锚点。
      final following = List<DateTime?>.filled(log.length, null);
      DateTime? upcoming;
      for (var i = log.length - 1; i >= 0; i--) {
        following[i] = upcoming;
        upcoming = at[i] ?? upcoming;
      }
      // 日志顺序就是聊天顺序：框架块没有时戳时，夹在前后两条平台消息之间（±1ms）。
      final entries = <TimelineNotice>[];
      DateTime? previous;
      for (var i = 0; i < log.length; i++) {
        final message = log[i];
        final text = message.bodyMarkdown.trim();
        if (text.isEmpty) continue;
        if (message.isFramework) {
          entries.add(
            _notice(
              message.id,
              text,
              message.time ?? _anchor(previous, following[i]),
            ),
          );
        } else {
          previous = at[i] ?? previous;
        }
      }
      setState(() {
        // 保留日志返回之前就通过 `/events` 进来的条目：同一 id 以日志为准。
        final ids = {for (final entry in entries) entry.id};
        final tail = [
          for (final entry in _framework)
            if (!ids.contains(entry.id)) entry,
        ];
        _setFramework(orderNotices([...entries, ...tail]));
        _frameworkIds
          ..clear()
          ..addAll(_framework.map((entry) => entry.id));
      });
    } on ApiFailure catch (e) {
      // 框架块只是补充：拿不到就只显示平台消息，不弹错；401 仍要收敛。
      if (e.isUnauthorized) {
        _handleAuthFailure();
      } else if (e.isNotFound) {
        // `/api/sessions/:id/messages` 404：会话在服务端已被卸载，别再伪装成已加载。
        _handleSessionUnloaded();
      }
    } catch (_) {
      // 坏字段同样只影响框架块，不影响平台消息。
    } finally {
      // 有没有日志都要接 `/events`：没拿到 head 就退回全量重放（只影响罕见的失败路径）。
      _transcriptLoaded = true;
      if (mounted) _startEvents();
    }
  }

  /// 框架块没有时戳时的锚点：贴在前一条平台消息之后 1ms，但不越过后一条；
  /// 前面没消息就贴在后一条之前 1ms。锚点是一个固定时间，翻页重排也不会漂。
  static DateTime? _anchor(DateTime? previous, DateTime? following) {
    if (previous == null) return following?.subtract(anchorTick);
    final after = previous.add(anchorTick);
    // 两条平台消息挨得太近（同秒）时退回前一条的时间：同刻排序是「平台消息在前」，顺序仍对。
    return following == null || after.isBefore(following) ? after : previous;
  }

  static TimelineNotice _notice(String id, String text, DateTime? time) =>
      TimelineNotice(
        // 服务端 id 优先：日志与 `/events` 同一条消息靠它去重。
        id: id.isNotEmpty ? id : 'framework-${noticeKey(text).hashCode}',
        text: text,
        time: time,
      );

  /// 增量框架块没有时戳时的锚点：最近一条平台消息之后 1ms（一条消息都没有才用本机时钟）。
  DateTime _afterLatest() {
    final last = _messages.isEmpty ? null : _messages.last.time;
    return last?.add(anchorTick) ?? DateTime.now();
  }

  /// `/events` 增量：mark 驱动计时，消息只收框架类。平台 `stream` 才是消息本体。
  /// 等日志 head 到手再订阅：不带游标的重放会让上一轮的 mark 变成这一轮的起点。
  void _startEvents() {
    final session = _session;
    if (_authFailed || _eventsStarted || session == null || !_transcriptLoaded) {
      return;
    }
    _eventsStarted = true;
    _eventsOpenedAt = DateTime.now();
    _touchEventsIdle();
    _eventsSub = widget.repo
        .events(session.id, since: _eventsSince)
        .listen(
          (event) {
            if (!mounted) return;
            _touchEventsIdle();
            // 收到帧就说明链路健康：下一次断线从 1s 重新退避。
            _eventsBackoff = 1;
            // 续传游标：任何一帧都推进它，断线重连不会把上一轮的 mark 再放一遍。
            final id = event.id;
            if (id != null && id.isNotEmpty) _eventsSince = id;
            // 单帧坏数据（解析缺口、服务端新形状）不能打断整条流，否则计时会永远没有阶段。
            try {
              _onSessionEvent(event);
            } catch (_) {}
          },
          onError: (Object error) {
            _eventsSub = null;
            _eventsIdleTimer?.cancel();
            _eventsIdleTimer = null;
            if (error is ApiFailure) {
              if (error.isUnauthorized) {
                _handleAuthFailure();
                return;
              }
              // 会话日志都 404 了：会话已被卸载，退避重连没有意义。
              if (error.isNotFound) {
                _handleSessionUnloaded();
                return;
              }
            }
            _restartEvents();
          },
          onDone: () {
            _eventsSub = null;
            _eventsIdleTimer?.cancel();
            _eventsIdleTimer = null;
            _restartEvents();
          },
          cancelOnError: true,
        );
  }

  /// `/events` 空闲判死：连接还在、但一行都不来（也不 FIN）时主动 cancel 走退避。
  /// 20s 比服务端 15s 心跳多留一档余量；每收到一帧就重置。
  void _touchEventsIdle() {
    _eventsIdleTimer?.cancel();
    _eventsIdleTimer = Timer(_eventsIdle, () {
      _eventsIdleTimer = null;
      if (!mounted || !_eventsStarted) return;
      _eventsSub?.cancel();
      _eventsSub = null;
      _eventsStarted = false;
      _restartEvents();
    });
  }

  /// 事件流断了按 1→2→4→8→30s 退避重来（`/events` 是长连接，切网/半死对它无解）：
  /// 游标是最后收到的帧 id，重放只补断口之后的条目。
  void _restartEvents() {
    if (!mounted || _authFailed || _eventsRetry != null) return;
    final seconds = _eventsBackoff;
    _eventsBackoff = seconds >= 8 ? 30 : seconds * 2;
    _eventsRetry = Timer(Duration(seconds: seconds), () {
      _eventsRetry = null;
      if (!mounted || _authFailed) return;
      _eventsStarted = false;
      _startEvents();
    });
  }

  void _onSessionEvent(SessionEvent event) {
    // 增量窗口失效：本地增量不可信，重取全量；重放过滤基准同步前移，
    // 否则服务端补发的历史 mark 会被当成本轮的起点。
    if (event.truncated) {
      _eventsSince = null;
      _eventsOpenedAt = DateTime.now();
      _truncatedRefresh ??= Timer(const Duration(milliseconds: 300), () {
        _truncatedRefresh = null;
        if (mounted && !_authFailed) unawaited(_loadFramework(force: true));
      });
      return;
    }
    // mark：轮次与阶段的权威打点（`agent/input-enqueued` / `engine/activity` / …）。
    final mark = event.name;
    if (mark != null) {
      // 重放的历史 mark：按帧时间丢掉，免得上一轮的 enqueued/prompt 把表重新拉起来。
      final openedAt = _eventsOpenedAt;
      final at = event.time;
      if (openedAt != null &&
          at != null &&
          at.isBefore(openedAt.subtract(const Duration(seconds: 5)))) {
        return;
      }
      _onMark(mark, event.data ?? const <String, Object?>{}, event.time);
      return;
    }
    final message = event.message;
    if (message == null) return;
    // `tool-result` 落库只说明模型拿到了返回值；异步工具（draw）的产物还在路上。
    // 阶段不在这里关：等模型下一步真的开始（reasoning / prompt / text）再关，
    // 这样 draw 的耗时覆盖到「图片生成完、模型接着说话」为止。
    if (!message.isFramework) return;
    final text = message.bodyMarkdown.trim();
    if (text.isEmpty) return;
    final id = message.id.isNotEmpty
        ? message.id
        : 'framework-${noticeKey(text).hashCode}';
    if (!_frameworkIds.add(id)) return;
    // 服务端没给时戳时用「最近一条平台消息 + 1ms」，而不是本机时钟：
    // 它早于这一轮的回复，设备时钟偏快也不会让框架块越过回复落到底部。
    final time = message.time ?? _afterLatest();
    setState(() {
      // 按时间插进框架列表，而不是无条件追加：补发的旧条目不会跑到最新。
      // 渲染时由 `mergeTimeline` 与平台消息合并，落在视口上方的不动滚动位置。
      final next = orderNotices([
        ..._framework,
        TimelineNotice(id: id, text: text, time: time),
      ]);
      _setFramework(
        next.length > _frameworkCap
            ? next.sublist(next.length - _frameworkCap)
            : next,
      );
    });
  }

  /// 更早一页：游标是最早一条的时间，服务端返回它之前的一页。
  Future<void> _loadEarlier() async {
    if (_loadingMore || !_hasMore || _messages.isEmpty) return;
    _loadingMore = true;
    try {
      final page = await widget.platform.messages(
        widget.conversationKey,
        limit: _pageSize,
        before: _earliest ?? _messages.first.time,
      );
      if (!mounted) return;
      // 时间相同的两条可能同时落在两页里，id 去重后只留一条。
      final fresh = [
        for (final message in page.items)
          if (_ids.add(message.id)) message,
      ];
      setState(() {
        _setMessages([...fresh, ..._messages]);
        // 游标跟着服务端这一页的最早一条走，不受实时补发的旧消息影响。
        if (page.items.isNotEmpty) _earliest = page.items.first.time;
        // 服务端说没有了，或这一页没有新东西（游标没生效）就停手，避免空转。
        _hasMore = page.hasMore && fresh.isNotEmpty;
      });
    } on ApiFailure catch (e) {
      if (e.isUnauthorized) {
        _handleAuthFailure();
      } else if (mounted) {
        _toast('加载更早的消息失败 ${_displayFailure(e)}');
      }
    } catch (_) {
      if (mounted) _toast('加载更早的消息失败');
    } finally {
      _loadingMore = false;
    }
  }

  // ---------------------------------------------------------------- 实时流

  /// 插件实时流：服务端不做订阅过滤，这里按会话键丢弃别的会话。
  /// 详情页只拿到 `ApiClient.authHeaders`，从同一个头里取回 token 自建客户端。
  void _startStream() {
    // 回前台会重走这里；已有订阅就不再开第二条（PlatformStream 自己不带幂等）。
    if (_authFailed || _streamSub != null) return;
    final token = _bearer;
    if (token == null || token.isEmpty) return;
    final stream = PlatformStream(widget.base, token);
    _stream = stream;
    _streamSub = stream.events.listen(
      _onPlatformEvent,
      // 断线退避在 PlatformStream 内部；401 会以错误送上来，这里停掉整页重试。
      onError: (Object error) {
        _streamSub = null;
        if (error is ApiFailure && error.isUnauthorized) {
          _handleAuthFailure();
        }
      },
    );
  }

  void _onPlatformEvent(PlatformEvent event) {
    if (!mounted) return;
    // 两边都归一：插件帧可能是 `route:r-x:user:y`，构造参数可能是原键。
    if (normalizeConversationKey(event.key) !=
        normalizeConversationKey(widget.conversationKey)) {
      return;
    }
    final message = event.message;
    // 分页/重载/重连回放都会送到同一条：id 是唯一去重键。
    if (!_ids.add(message.id)) return;
    // 有人在这条会话里说话 = 这一轮可能要开始了：给 `/live` 一次证明自己的机会。
    // bot 的发言落成气泡 = 这一轮结束，兜底探测可以收工。
    // 页面刚打开时平台流会回放最近几条：那是历史，不参与本轮的起止判断。
    if (_since() > _replayWindow.inMilliseconds) {
      if (message.outbound) {
        _stopProbe();
        _setLive(LiveState.idle);
        // 顺序要紧：先记下「本轮已有外发」，再收表——收表会同步触发骨架撤场判断。
        _outboundInRound = true;
        _roundOutboundIds.add(message.id);
        _turnOutboundIds.add(message.id);
        _clock.delivered();
        _verifyTurnEnd();
        // bot 的第一条气泡上屏 = 这一轮的活动结束，骨架立刻让位（不再等 hold）。
        if (_skeleton == _SkeletonPhase.running ||
            _skeleton == _SkeletonPhase.holding) {
          _removeSkeleton();
        }
      } else {
        _armRoundProbe();
      }
    }
    var atEnd = false;
    setState(() {
      atEnd = _insertMessage(message);
      // 机器人的发言已落成真实气泡：流式预览让位，避免同一段文字出现两次。
      if (message.outbound && _streaming.isNotEmpty) {
        _flushTimer?.cancel();
        _flushTimer = null;
        _streaming.clear();
        _streamingText.value = '';
      }
    });
    // 补发的旧消息落在中间，不跟随、不涨未读。
    if (!atEnd) return;
    if (_nearBottom) {
      _scrollToLatest();
    } else {
      _unseen.value += 1;
    }
  }

  /// 实时帧按时间入列，返回是否追加到了最新一条（决定要不要跟随/计未读）。
  /// 插件会把时间戳回退的消息插到中间（适配器补发/重试），所以不能无条件追加到尾部。
  bool _insertMessage(PlatformMessage message) {
    final last = _messages.isEmpty ? null : _messages.last;
    if (last == null || !message.time.isBefore(last.time)) {
      _setMessages([..._messages, message]);
      return true;
    }
    final next = [..._messages];
    final index = next.indexWhere(
      (existing) => existing.time.isAfter(message.time),
    );
    next.insert(index < 0 ? next.length : index, message);
    _setMessages(next);
    return false;
  }

  String? get _bearer {
    final raw =
        widget.headers['authorization'] ?? widget.headers['Authorization'];
    if (raw == null) return null;
    const prefix = 'bearer ';
    final value = raw.trim();
    return value.toLowerCase().startsWith(prefix)
        ? value.substring(prefix.length).trim()
        : value;
  }

  // ---------------------------------------------------------------- 生成状态

  /// `/live` 只对已加载会话有意义（未加载的会话没有 agent，只会 404）。
  void _startLive() {
    final session = _session;
    if (_authFailed || _liveStarted || session == null || !mounted) return;
    // 主题切换等重建会重走 `_ensurePolling` 的即时重连：给退避表一个最小间隔，
    // 不要每次重建都绕过 9s 直接打服务端。
    final downAt = _liveDownAt;
    if (_liveRetryTimer != null &&
        downAt != null &&
        DateTime.now().difference(downAt) < _liveRetryDelay) {
      return;
    }
    _liveStarted = true;
    // 新连接=新握手：重连后的第一个 snapshot 必须重新等，否则看门狗从此失效。
    _snapshotSeen = false;
    _liveRetryTimer?.cancel();
    _liveRetryTimer = null;
    // 8s 连首个 snapshot 都没到：这条流不可信（手机切网 / 待机后常见的半死连接）。
    // 退回 3s 轮询兜底并安排重连，绝不挂着一条永远不说话的流——那会让状态灯永远停在
    // 「待机」、中止按钮永远点不了，而服务端其实已经在生成。
    _snapshotTimer?.cancel();
    _snapshotTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || _snapshotSeen) return;
      _liveDown();
    });
    // 首帧之外的看门狗：每帧都重置；生成中途流半死（不再出帧、也不 FIN）时判死重连。
    _touchLiveIdle();
    _liveSub?.cancel();
    _liveSub = widget.repo
        .live(session.id)
        .listen(
          (event) {
            if (!mounted) return;
            _lastLiveAt = DateTime.now();
            _touchLiveIdle();
            // 流在说话：兜底探测立刻让位。
            if (_probeStartedAt != null || _probeDelay != null) _stopProbe();
            _liveMs ??= _since();
            switch (event.kind) {
              case LiveEventKind.snapshot:
                // 权威帧：带 attempt 才在跑；没有 attempt 就立刻回到 idle 并清掉残留文本。
                _snapshotSeen = true;
                _snapshotTimer?.cancel();
                _flushTimer?.cancel();
                _flushTimer = null;
                _streaming.clear();
                // 流已接上：轮询兜底退场，信息栏回到真实阶段。
                if (_polling) {
                  setState(() => _polling = false);
                  _ensurePolling();
                }
                for (final part in event.parts) {
                  if (part['type'] == 'text' && part['delta'] is String) {
                    _streaming.write(part['delta'] as String);
                  }
                }
                _flushStreaming();
                // 起点：首个 active snapshot（比平台消息更早、更准）。
                // 空 attempt 的权威快照 = 这一轮已经停了，交给终点判定等最后的投递。
                if (event.active) {
                  _clock.start();
                } else {
                  _clock.stopped();
                }
                // 快照里有正文就是「回复中」，否则还在思考/工具阶段。
                _setLive(
                  event.active
                      ? (_streaming.isEmpty
                            ? LiveState.thinking
                            : LiveState.replying)
                      : LiveState.idle,
                );
                _followIfAtBottom();
              case LiveEventKind.delta:
                _snapshotTimer?.cancel();
                // 正文到了：模型已经回到说话，任何在跑的工具到此为止。
                _closeOpenTools();
                _clock.endPhase(thinkingPhase);
                _clock.phase(replyPhase);
                _setLive(LiveState.replying);
                _streaming.write(event.delta ?? '');
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
                _closeOpenTools();
                _clock.phase(thinkingPhase);
                if (_streaming.isEmpty) _setLive(LiveState.thinking);
              case LiveEventKind.tool:
                _snapshotTimer?.cancel();
                // 模型开始吐工具参数：这次调用的阶段从这里开表，思考让位。
                // 收表点不是 `tool-result`，而是模型下一步真的开始（见 [_closeOpenTools]）。
                _clock.endPhase(thinkingPhase);
                final tool = event.toolName;
                final name = (tool == null || tool.isEmpty) ? 'tool' : tool;
                _clock.phase(name, tool: true);
                final callId = event.toolCallId;
                if (callId != null && callId.isNotEmpty) {
                  _openToolCalls[callId] = normalizeTurnPhase(name);
                } else {
                  _openToolNames.add(normalizeTurnPhase(name));
                }
                if (_streaming.isEmpty) _setLive(LiveState.thinking);
              case LiveEventKind.settled:
                // 收尾时立刻 flush，避免最后一段 delta 卡在定时器里被丢掉。
                // 落库的那条由 `platform/stream` 送来，这里不重取历史。
                // 一次 attempt 结束只收阶段，**不是**整轮终点：投递与后续 step 还可能在跑。
                _snapshotTimer?.cancel();
                // 转后台不在这里猜：同步工具也是先 settle 再执行，客户端无从判断。
                // 真正的后台任务完成时，服务端自己会发 `[background …]` 中间块。
                _clock.attemptSettled();
                _flushTimer?.cancel();
                _flushTimer = null;
                _flushStreaming();
                _streaming.clear();
                _streamingText.value = '';
                if (_awayFromBottom) _unseen.value += 1;
                _setLive(LiveState.idle);
              case LiveEventKind.lagged:
                _flushTimer?.cancel();
                _flushTimer = null;
                _flushStreaming();
                _streaming.clear();
                _streamingText.value = '';
                _setLive(LiveState.idle);
            }
          },
          onError: (Object error) {
            if (!mounted) return;
            // 401 不重连：token 不会自己恢复，交给页面提示重新连接。
            if (error is ApiFailure) {
              if (error.isUnauthorized) {
                _handleAuthFailure();
                return;
              }
              // 404 = 服务端把这个会话的 agent 卸了：再连也只会一直 404。
              if (error.isNotFound) {
                _handleSessionUnloaded();
                return;
              }
            }
            // `/live` 断了就没法知道具体阶段：退回 3s 轮询读 running，
            // 信息栏显示「轮询中」，消息仍由平台流补上。
            _liveDown();
          },
          onDone: () {
            if (!mounted) return;
            _liveDown();
          },
          cancelOnError: true,
        );
  }

  /// 空闲判死：20s 没有 `/live` 帧就主动结束当前订阅，走 9s 退避重连。
  /// 20s 比服务端 15s 心跳多留一档余量；注释心跳在 ApiClient 里也会触发帧级判活。
  void _touchLiveIdle() {
    _liveIdleTimer?.cancel();
    _liveIdleTimer = Timer(_liveIdle, () {
      _liveIdleTimer = null;
      if (!mounted || !_liveStarted) return;
      _liveDown();
    });
  }

  /// `/live` 掉线：轮询接管状态，9s 后再试一次流。
  /// 轮询的停止条件与探测共用一张表：页面不可见、或流重新接上（snapshot）即停。
  void _liveDown() {
    _liveStarted = false;
    _liveDownAt = DateTime.now();
    _stopProbe();
    _liveIdleTimer?.cancel();
    _liveIdleTimer = null;
    // 先掐掉旧连接：半死连接可能还在吐帧，不能让它和新连接同时改状态。
    _liveSub?.cancel();
    _liveSub = null;
    _snapshotTimer?.cancel();
    _flushTimer?.cancel();
    _flushTimer = null;
    _streaming.clear();
    _streamingText.value = '';
    if (!_polling) setState(() => _polling = true);
    _setLive(LiveState.idle);
    _scheduleLiveRetry();
    _ensurePolling();
  }

  void _scheduleLiveRetry() {
    if (_liveRetryTimer != null) return;
    _liveRetryTimer = Timer(_liveRetryDelay, () {
      _liveRetryTimer = null;
      // 不可见就交回轮询：露出/回前台时 `_ensurePolling` 与这里的那次重连会补上。
      if (!mounted || !_foreground || !_routeVisible || !_loaded) return;
      _startLive();
    });
  }

  /// 唯一的写入口：相同状态不触发重建。本轮计时由 turn_start/终点事件单独驱动，
  /// 这里只在「有生成在跑」时保证表已经走起来（`running=true` 也是一种起点）。
  /// `/live` 的任何结论（阶段帧、settled、无 attempt 的快照）都盖掉乐观亮灯。
  void _setLive(LiveState next) {
    final wasOptimistic = _optimisticThinking;
    final settled = next == LiveState.idle;
    final settledChanged = _liveSettled != settled;
    _optimisticThinking = false;
    _liveSettled = settled;
    if (_live != next) {
      if (next.generating) _clock.start();
      setState(() => _live = next);
    } else if ((wasOptimistic || settledChanged) && mounted) {
      // `_live` 没变，但状态灯从乐观的「思考中」回到了真实状态，需要重画。
      setState(() {});
    }
  }

  // ---------------------------------------------------------------- 本轮计时

  /// bot 外发落库后确认一次 `running`：投递与 settle 之间实测差 1–2s，
  /// 只用 `chat/delivered` 当终点会早收表。400ms 合并同一条回复的多条消息。
  void _verifyTurnEnd() {
    _runningCheck?.cancel();
    _runningCheck = Timer(const Duration(milliseconds: 400), () async {
      _runningCheck = null;
      if (!mounted || !_clock.running) return;
      try {
        final match = await _lookupSession();
        if (!mounted) return;
        if (match != null && !match.running) _clock.stopped();
      } on ApiFailure catch (e) {
        // 尽力而为：下一次外发或轮询还会再问；401 仍要停表。
        if (e.isUnauthorized) _handleAuthFailure();
      } catch (_) {
        // 读状态失败不影响已落库的消息。
      }
    });
  }

  /// `/events` 的 mark：轮次与阶段的权威打点。
  ///
  /// 实例实际会发的（2026-11 实测）：`agent/input-enqueued`、`prompt`、`request/context`、
  /// `engine/activity{type:'stage',label:prepare|generate|deliver|settle}`、`chat/delivered`。
  /// `tool-before` / `tool-after` / `chatluna/tool-*` 目前没有，但按同一套规则接住：
  /// 服务端将来补上不用改客户端。
  void _onMark(String name, Map<String, Object?> data, DateTime? at) {
    final tail = name.split('/').last.toLowerCase();
    // 信号自带的落库时间：比本机收到早多少，起点就往前回填多少（上限 3s，挡时钟偏差）。
    final lead = turnStartLead(at, DateTime.now());
    // 入队只是「有消息等着跑」，不一定马上开轮（`target:"next-turn"` 要等定时/唤醒）。
    // 计时起点交给真正开跑的 `agent/input-admitted` / `engine/activity` / `prompt`。
    if (tail == 'input-enqueued') {
      if (data['wakeup'] == false) return;
      _armRoundProbe();
      return;
    }
    // 工具打点（实例暂未使用）。
    final toolish =
        tail == 'tool-before' || tail == 'tool-start' || tail == 'tool-call';
    final toolDone =
        tail == 'tool-after' || tail == 'tool-end' || tail == 'tool-result';
    if (toolish || toolDone) {
      final raw = data['tool'] ?? data['toolName'] ?? data['name'];
      if (toolish) {
        _clock.start(lead: lead);
        _clock.phase(
          raw is String && raw.isNotEmpty ? raw : 'tool',
          tool: true,
        );
      } else {
        _clock.phaseFinished();
      }
      return;
    }
    switch (name) {
      case 'prompt':
        // 每个 step 开始都会打一条：新的 step = 上一步的工具真的走完了。
        _clock.start(lead: lead);
        _closeOpenTools();
        _clock.phase(thinkingPhase);
      case 'engine/activity':
        if (data['type'] != 'stage') return;
        switch (data['label']) {
          case 'prepare' || 'generate':
            _clock.start(lead: lead);
            _closeOpenTools();
            _clock.phase(thinkingPhase);
          case 'deliver':
            _closeOpenTools();
            _clock.phase(replyPhase);
          case 'settle':
            // 引擎这一轮收尾 = running=false 的最早证据；投递那条由 `chat/delivered` 补。
            _clock.stopped();
        }
      case 'chat/delivered':
        _clock.delivered();
        _verifyTurnEnd();
      case 'agent/input-admitted' || 'request/context':
        // 输入被 agent 收下 / 请求已装配：这一轮真的开跑了（也是中止冻结的解锁点）。
        // 开表后立刻挂「思考」：`engine/activity prepare` 可能先于解锁到达、被冻结点掉。
        _clock.start(lead: lead, force: true);
        _closeOpenTools();
        _clock.phase(thinkingPhase);
    }
  }

  // ---------------------------------------------------------------- 骨架气泡

  /// 模型回到「下一步」：所有在跑的工具到此收表。
  /// 工具自己的 `tool-result` 只是把返回值交给模型，异步工具（draw）的产物还在路上——
  /// 真正的生命周期终点是下一个 step 开始（`prompt` / reasoning / 正文）。
  void _closeOpenTools() {
    for (final name in _openToolCalls.values.toList(growable: false)) {
      _clock.finishTool(name);
    }
    for (final name in _openToolNames.toList(growable: false)) {
      _clock.finishTool(name);
    }
    _openToolCalls.clear();
    _openToolNames.clear();
  }

  /// 计时通知：只在「开轮 / 收表」两个转折上动列表，tick 本身不触发页面重建。
  void _onClockTick() {
    final view = _clock.view.value;
    if (!mounted) return;
    final active = view != null && !view.finished;
    if (active != _turnActive) setState(() => _turnActive = active);
    if (view == null) return;
    if (!view.finished) {
      // 新的一轮：用轮次序号判断，不能靠「读数还很小」（会漏判/误判）。
      if (view.round != _skeletonRound) {
        _skeletonRound = view.round;
        _outboundInRound = false;
        _roundOutboundIds.clear();
        _openToolCalls.clear();
        _openToolNames.clear();
        // 计时表已开表说明这一轮真的在跑：`/live` 还没发话也先亮「思考中」。
        // 每个轮次只清一次——settle 之后 `_setLive(idle)` 会把它收掉，
        // tick 不能反复点灯，否则投递等待期里状态灯会一直闪回「思考中」。
        _liveSettled = false;
      }
      // 本轮已经出过真实气泡：不再补骨架（等 running=false 收表即可）。
      if (_skeleton == _SkeletonPhase.none && !_outboundInRound) _startSkeleton();
      return;
    }
    // 收表：乐观亮灯到此为止，状态灯回到真实状态（之后由 `/live` 的 idle 维持）。
    final wasOptimistic = _optimisticThinking;
    final settledChanged = !_liveSettled;
    _optimisticThinking = false;
    _liveSettled = true;
    if ((wasOptimistic || settledChanged) && mounted) setState(() {});
    // 脚注直接用本地钟 `view.total` 盖印：它覆盖网络往返与用户真实等待的整段，
    // 不再回拉全量日志用引擎 timing 校正（那一步的收益远小于反序列化开销）。
    if (_stampTurnEnd(view)) setState(() {});
    if (_skeleton == _SkeletonPhase.running) _endSkeleton(view);
  }

  void _startSkeleton() {
    _skeletonHold?.cancel();
    _skeletonFade?.cancel();
    _skeletonHold = null;
    _skeletonFade = null;
    _skeletonAborted = false;
    _outboundInRound = false;
    _roundOutboundIds.clear();
    _skeletonResend = _lastInboundText();
    setState(() => _skeleton = _SkeletonPhase.running);
    // 只在插入时滚一次；之后不因 tick 滚动。
    if (_nearBottom) _scrollToLatest();
  }

  void _endSkeleton(TurnClockView view) {
    if (_skeletonAborted) {
      // 中止：保留可操作态（已中止 + 重新发送），不自动消失。
      setState(() => _skeleton = _SkeletonPhase.holding);
      return;
    }
    if (_outboundInRound) {
      _removeSkeleton();
      return;
    }
    setState(() => _skeleton = _SkeletonPhase.holding);
    // 总时长已写进气泡脚注：骨架只停 0.5s 让眼睛跟上，不长期占位。
    _skeletonHold = Timer(const Duration(milliseconds: 500), _fadeSkeleton);
  }

  /// 本轮最后一颗 out 气泡的脚注：`turnStartedAt`/`turnEndedAt` 是本地推算，服务端没有。
  /// 只写本轮新落库的消息（[_roundOutboundIds]）：改写上一轮那条会得出 0.0s 的假读数。
  bool _stampTurnEnd(TurnClockView view) {
    if (_turnOutboundIds.isEmpty) return false;
    if (view.total < const Duration(milliseconds: 200)) return false;
    final end = DateTime.now();
    final start = end.subtract(view.total);
    var changed = false;
    // 一次 turn 里的所有外发气泡都盖同一个总时长：多消息、多 attempt 都一致。
    for (final id in _turnOutboundIds) {
      for (var i = _messages.length - 1; i >= 0; i--) {
        final message = _messages[i];
        if (message.id != id) continue;
        if (message.turnEndedAt == null) {
          message.turnEndedAt = end;
          message.turnStartedAt = start;
          // 缓存键含脚注：丢掉这条消息的旧 Widget，脚注才会出现在气泡右下。
          _itemCache.removeWhere((key, _) => key.startsWith('m:${message.id}:'));
          changed = true;
        }
        break;
      }
    }
    if (changed) _turnOutboundIds.clear();
    return changed;
  }

  String? _lastInboundText() {
    for (var i = _messages.length - 1; i >= 0; i--) {
      final message = _messages[i];
      if (message.outbound) continue;
      final text = message.content.trim();
      return text.isEmpty ? null : text;
    }
    return null;
  }

  void _fadeSkeleton() {
    _skeletonHold?.cancel();
    _skeletonHold = null;
    if (!mounted || _skeleton != _SkeletonPhase.holding) return;
    setState(() => _skeleton = _SkeletonPhase.fading);
    _skeletonFade = Timer(const Duration(milliseconds: 180), _removeSkeleton);
  }

  void _removeSkeleton() {
    _skeletonHold?.cancel();
    _skeletonHold = null;
    _skeletonFade?.cancel();
    _skeletonFade = null;
    if (!mounted || _skeleton == _SkeletonPhase.none) return;
    setState(() => _skeleton = _SkeletonPhase.none);
  }

  /// 中止后的「重新发送」：把这一轮的触发原文重新交给 agent。
  Future<void> _resend() async {
    final session = _session;
    final text = _skeletonResend;
    if (session == null || text == null || _cancelling) return;
    setState(() => _cancelling = true);
    try {
      await widget.repo.steer(session.id, text);
      if (!mounted) return;
      _skeletonAborted = false;
      _removeSkeleton();
    } on ApiFailure catch (e) {
      if (e.isUnauthorized) {
        _handleAuthFailure();
      } else if (mounted) {
        _toast('重新发送失败 ${_displayFailure(e)}');
      }
    } catch (_) {
      if (mounted) _toast('重新发送失败');
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
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

  // ---------------------------------------------------------------- 滚动

  /// 滚到最早一条时自动取更早一页（倒序列表里 maxScrollExtent 是最早那条）。
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final away = position.pixels > 400;
    if (away != _awayFromBottom) setState(() => _awayFromBottom = away);
    if (position.pixels < position.maxScrollExtent - 320) return;
    _loadEarlier();
  }

  void _jumpToLatest() {
    _unseen.value = 0;
    _scrollToLatest();
  }

  /// 倒序列表：offset 0 就是最新一条。
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

  // ---------------------------------------------------------------- 会话操作

  /// 中止本轮生成：失败必须让用户看见原因（code + message），成功立刻回待机。
  /// 状态灯与按钮都由 [_live] 驱动，所以成功后先把本地状态收干净，不等服务端的 settled。
  Future<void> _cancel() async {
    final session = _session;
    if (session == null || _cancelling) return;
    setState(() => _cancelling = true);
    try {
      await widget.repo.cancel(session.id);
      if (!mounted) return;
      // 中止的这一轮保留骨架：显示「已中止 12.4s」+ 重新发送，而不是让用户滚回去找。
      if (_skeleton == _SkeletonPhase.running) _skeletonAborted = true;
      // 先冻结读数再清状态：否则骨架上的数字会一直涨到服务端 settled 才停。
      _clock.freeze();
      _flushTimer?.cancel();
      _flushTimer = null;
      _streaming.clear();
      _streamingText.value = '';
      _setLive(LiveState.idle);
    } on ApiFailure catch (e) {
      if (e.isUnauthorized) {
        _handleAuthFailure();
      } else {
        _toast('取消失败 ${_displayFailure(e)}');
      }
    } catch (_) {
      _toast('取消失败');
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  Future<void> _compact() async {
    final session = _session;
    if (session == null) return;
    try {
      final result = await widget.repo.compact(session.id);
      _toast('已压缩：${result ?? '完成'}');
    } on ApiFailure catch (e) {
      if (e.isUnauthorized) {
        _handleAuthFailure();
      } else {
        _toast('压缩失败 ${_displayFailure(e)}');
      }
    } catch (_) {
      _toast('压缩失败');
    }
  }

  Future<void> _fork() async {
    final session = _session;
    if (session == null) return;
    try {
      final child = await widget.repo.fork(session.id);
      _toast('已分叉：${child.sessionId}（${child.length} 条）');
    } on ApiFailure catch (e) {
      if (e.isUnauthorized) {
        _handleAuthFailure();
      } else {
        _toast('分叉失败 ${_displayFailure(e)}');
      }
    } catch (_) {
      _toast('分叉失败');
    }
  }

  /// 切换过模型后，标题详情与信息栏都用最新的 `model`。
  SessionSummary get _summary {
    final session = _session;
    if (session == null) {
      // 未加载：只为详情面板拼一份，origin 是平台名，没有引擎与模型。
      return SessionSummary(
        id: widget.conversationKey,
        title: widget.title,
        createdAt: _messages.isEmpty
            ? DateTime.fromMillisecondsSinceEpoch(0)
            : _messages.first.time,
        origin: widget.origin,
        running: false,
        engine: '',
      );
    }
    if (_model == session.model) return session;
    return SessionSummary(
      id: session.id,
      title: session.title,
      createdAt: session.createdAt,
      origin: session.origin,
      running: session.running,
      engine: session.engine,
      model: _model,
    );
  }

  Future<void> _pickModel() async {
    final session = _session;
    if (session == null) return;
    final picked = await showModalBottomSheet<ModelRef>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ModelPickerSheet(
        repo: widget.repo,
        sessionId: session.id,
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
      'msg ${_messages.length}',
      if (_framework.isNotEmpty) 'fw ${_framework.length}',
    ];
  }

  /// 换消息列表的唯一入口：顺带推进版本号，时间线只在这时重算。
  void _setMessages(List<PlatformMessage> next) {
    _messages = next;
    _messagesRev += 1;
  }

  /// 换框架块列表的唯一入口（同上）。
  void _setFramework(List<TimelineNotice> next) {
    _framework = next;
    _frameworkRev += 1;
  }

  /// 时间线：平台消息 + 框架块合并成一条（规则见 [mergeTimeline]）。
  /// 框架块的锚点在加载时就已经定下，所以这里只做排序与分组，翻页后位置不漂。
  ///
  /// 结果按两个列表的版本号记忆化：`build()` 每帧都会走这里，300 条时
  /// 原来每帧都要建索引 Map、排序、生成三个新列表；现在只有消息/框架块
  /// 真正变化时才重算一次。流式正文走 `ValueNotifier`，不会让 `build` 进来。
  List<TimelineItem> _timeline() {
    final cached = _items;
    if (cached != null &&
        _itemsMessagesRev == _messagesRev &&
        _itemsFrameworkRev == _frameworkRev) {
      return cached;
    }
    final items = mergeTimeline(_messages, _framework);
    _items = items;
    _itemsMessagesRev = _messagesRev;
    _itemsFrameworkRev = _frameworkRev;
    return items;
  }

  /// 日期分隔条的标签：今天 / 昨天 / `YYYY-MM-DD`。
  /// 在时间线项第一次构建时算好（随后进 Widget 缓存），不随每帧读系统时钟。
  static String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    return switch (diff) {
      0 => '今天',
      1 => '昨天',
      _ =>
        '${day.year}-${day.month.toString().padLeft(2, '0')}-'
            '${day.day.toString().padLeft(2, '0')}',
    };
  }

  /// 时间线上的一项 → Widget。缓存键包含渲染所需的全部可变输入（id / 是否显示头部），
  /// 因此同一个实例可以安全复用；状态（折叠、图片解码）都在子 widget 自己的 State 里。
  Widget _itemWidget(TimelineItem item) {
    final (cacheKey, build) = switch (item) {
      DayDividerItem(:final day) => (
        'd:${day.toIso8601String()}',
        // 标签在缓存未命中时算一次：日期条不随每帧重建去读系统时钟。
        () => _DayDivider(label: _dayLabel(day)),
      ),
      NoticeItem(:final notice) => (
        'n:${notice.id}',
        () => FrameworkNoticeCard(
          foldKey: notice.id,
          text: notice.text,
          open: _noticeOpen,
        ),
      ),
      MessageItem(:final message, :final showHeader) => (
        'm:${message.id}:$showHeader:${message.turnEndedAt?.millisecondsSinceEpoch ?? 0}',
        () => MessageView(
          key: ValueKey(message.id),
          message: message.view,
          base: widget.base,
          headers: widget.headers,
          noticeOpen: _noticeOpen,
          media: message.media,
          avatarUrl: message.outbound
              ? _botAvatar
              : absoluteResourceUrl(widget.base, message.avatar),
          senderName: message.outbound ? _botName : message.userName,
          time: message.time,
          // 骨架撤掉后总时长留在这条气泡的右下角（本地观测，重开页面就没有了）。
          // 与 `HH:mm` 并排时加单位，避免把 9.4s 读成时钟。
          footnote: switch (message.turnStartedAt) {
            final start? when message.turnEndedAt != null =>
              '用时 ${formatElapsed(message.turnEndedAt!.difference(start))}',
            _ => null,
          },
          showHeader: showHeader,
        ),
      ),
    };
    return _cachedItem(cacheKey, build);
  }

  /// 有上限的最近使用缓存：命中后挪到队尾，超限淘汰最久没用的那一项。
  Widget _cachedItem(String key, Widget Function() build) {
    final cached = _itemCache.remove(key);
    if (cached != null) {
      _itemCache[key] = cached;
      return cached;
    }
    final widget = build();
    _itemCache[key] = widget;
    if (_itemCache.length > _itemCacheCap) {
      _itemCache.remove(_itemCache.keys.first);
    }
    return widget;
  }

  /// 列表末格：骨架气泡（灰条占位 + 描边上的计时标签 + 中止后的重新发送）。
  /// 只有标签自己监听 [_clock]，tick 不动列表、不重建页面。
  Widget _skeletonBubble() => _SkeletonBubble(
    clock: _clock.view,
    aborted: _skeletonAborted,
    fading: _skeleton == _SkeletonPhase.fading,
    canResend: _skeletonResend != null,
    onResend: _resend,
    onShowPhases: _showTurnPhases,
    avatarUrl: _botAvatar,
  );

  /// 打开本轮阶段明细：读的是点下去那一刻的读数，不是列表构建时的旧值。
  void _showTurnPhases() {
    final view = _clock.view.value;
    if (view == null || !mounted) return;
    unawaited(showTurnPhases(context, view));
  }

  /// 列表首格：流式正文。只有这一格监听 delta，整页不随 token 重建。
  /// 阶段与耗时由末尾的骨架气泡承担，这里不再画「思考中」胶囊。
  Widget _liveSlot(ThemeData theme) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (_live.generating)
          ValueListenableBuilder<String>(
            valueListenable: _streamingText,
            builder: (context, text, _) => text.isEmpty
                ? const SizedBox.shrink()
                : Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      margin: const EdgeInsets.only(top: 6),
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width * 0.86 - 36,
                      ),
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(16),
                          topRight: Radius.circular(4),
                          bottomLeft: Radius.circular(16),
                          bottomRight: Radius.circular(16),
                        ),
                      ),
                      child: SelectableText(
                        text,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.5,
                          color: theme.colorScheme.onPrimary,
                        ),
                      ),
                    ),
                  ),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final messages = _messages;
    final items = _timeline();
    final slot = _live.generating ? 1 : 0;
    final skeleton = _skeleton == _SkeletonPhase.none ? 0 : 1;
    return Scaffold(
      appBar: AppBar(
        title: ChatTitle(
          title: widget.title,
          onTap: () => showSessionDetails(context, _summary),
        ),
        actions: [
          // 会话级操作只对已加载会话开放：未加载的会话在服务端没有日志与 agent。
          if (_loaded) ...[
            IconButton(
              // 只有本轮真的在跑（计时器未收表，或 `/live` 说在生成）才可点；
              // 空闲时置灰，按下去也不会发生任何事。
              onPressed: (_turnActive || _live.generating) && !_cancelling
                  ? _cancel
                  : null,
              icon: const Icon(Icons.stop_circle_outlined),
              tooltip: '中止当前生成',
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'compact') _compact();
                if (value == 'fork') _fork();
                if (value == 'reload') {
                  _load();
                  unawaited(_loadFramework(force: true));
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'compact', child: Text('压缩上下文')),
                PopupMenuItem(value: 'fork', child: Text('分叉到新会话')),
                PopupMenuItem(value: 'reload', child: Text('重新载入')),
              ],
            ),
          ],
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
          // 已加载：`/live` 驱动状态灯与阶段；未加载：一条静态的「bot · 平台 · 未加载」，
          // 不留空白。两个分支都能在会话被 agent 认领后由 3s 探测自动切换。
          if (_loaded)
            ChatInfoBar(
              session: _summary,
              light: _statusLight,
              botName: _botName,
              avatarUrl: _botAvatar,
              debugMetrics: _debugMetrics(),
              showDeveloperInfo: widget.showDeveloperInfo,
              onModelTap: _pickModel,
              turnClock: _clock.view,
              onTurnPhases: (view) => unawaited(showTurnPhases(context, view)),
            )
          else
            ChatUnloadedBar(
              botName: _botName,
              avatarUrl: _botAvatar,
              origin: widget.origin,
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null && messages.isEmpty
                ? _StatusView(
                    icon: Icons.cloud_off_outlined,
                    title: '加载失败',
                    message: _error!,
                    error: true,
                    actionLabel: '重试',
                    onAction: _load,
                  )
                : items.isEmpty && _live == LiveState.idle
                ? const _StatusView(
                    icon: Icons.chat_bubble_outline,
                    title: '还没有消息',
                    message: '插件还没有这个会话的消息',
                  )
                : ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    padding: EdgeInsets.fromLTRB(
                      12,
                      12,
                      12,
                      24 + MediaQuery.paddingOf(context).bottom,
                    ),
                    cacheExtent: 600,
                    itemCount: items.length + slot + skeleton,
                    itemBuilder: (context, index) {
                      // 反向列表：index 0 是最新（屏幕最下方）。
                      if (skeleton == 1) {
                        if (index == 0) return _skeletonBubble();
                        index -= 1;
                      }
                      if (slot == 1) {
                        if (index == 0) return _liveSlot(theme);
                        index -= 1;
                      }
                      // 反向列表：index 0 是最新，取数据尾部。
                      return _itemWidget(items[items.length - 1 - index]);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 空态/错误态共用的居中状态：圆底座图标、标题、说明与可选动作。
/// 样式对齐规格 B.6；只在本文件内复用，不改会话列表页的实现。
class _StatusView extends StatelessWidget {
  const _StatusView({
    required this.icon,
    required this.title,
    required this.message,
    this.error = false,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;

  /// 错误态：图标换成 `statusError`。
  final bool error;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final actionLabel = this.actionLabel;
    final onAction = this.onAction;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.surfaceL2,
              ),
              child: Icon(
                icon,
                size: 28,
                color: error ? colors.statusError : colors.textTertiary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  height: 1.4,
                  color: colors.textSecondary,
                ),
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(actionLabel),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Radii.tile),
                  ),
                  textStyle: theme.textTheme.labelMedium?.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 骨架气泡：bot 侧、窄一点的占位气泡。两条灰条解释「在生成」，
/// 边框上的标签给出整轮与当前阶段的实时读数（等宽数字，只有标签自己重建）。
class _SkeletonBubble extends StatelessWidget {
  const _SkeletonBubble({
    required this.clock,
    required this.aborted,
    required this.fading,
    required this.canResend,
    this.onResend,
    this.onShowPhases,
    this.avatarUrl,
  });

  final ValueListenable<TurnClockView?> clock;

  /// 本轮被中止：标签换成「已中止 12.4s」，并保留「重新发送」。
  final bool aborted;

  /// 正在淡出：高度收到 0、透明度归零，随后由页面从列表里移除。
  final bool fading;

  final bool canResend;
  final VoidCallback? onResend;
  final VoidCallback? onShowPhases;
  final String? avatarUrl;

  static const double _avatarSize = 28;
  static const double _avatarGap = 8;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final screen = MediaQuery.sizeOf(context).width;
    final width = screen * 0.62;
    return AnimatedSize(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: AnimatedOpacity(
        opacity: fading ? 0 : 1,
        duration: const Duration(milliseconds: 160),
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: width,
                          padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
                          decoration: BoxDecoration(
                            color: colors.skeletonBg,
                            border: Border.all(
                              color: colors.skeletonBorder,
                              width: 1,
                            ),
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(16),
                              topRight: Radius.circular(4),
                              bottomLeft: Radius.circular(16),
                              bottomRight: Radius.circular(16),
                            ),
                          ),
                          child: const _SkeletonBars(),
                        ),
                        Positioned(
                          top: -8,
                          left: 12,
                          child: TurnClockLabel(
                            clock: clock,
                            aborted: aborted,
                            onTap: onShowPhases,
                          ),
                        ),
                      ],
                    ),
                    if (aborted && canResend)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: TextButton.icon(
                          onPressed: onResend,
                          icon: const Icon(Icons.refresh, size: 14),
                          // 走的是 `POST /steer`（把原文追加进会话继续跑），不是平台的「发送消息」。
                          label: const Text('重发这条'),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 28),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            foregroundColor: colors.statusWarning,
                            textStyle: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: _avatarGap),
              AssistantAvatar(size: _avatarSize, imageUrl: avatarUrl),
            ],
          ),
        ),
      ),
    );
  }
}

/// 骨架灰条：横向流光在两条灰条上穿过，读起来是「正在生成」而不是一张静态占位。
/// 动画只在骨架挂载期间跑，骨架撤场即随 State 销毁。
class _SkeletonBars extends StatefulWidget {
  const _SkeletonBars();

  @override
  State<_SkeletonBars> createState() => _SkeletonBarsState();
}

class _SkeletonBarsState extends State<_SkeletonBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final base = colors.shimmerBase;
    final highlight = colors.shimmerLit;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final head = _controller.value * 1.6 - 0.3;
        double at(double stop) => stop.clamp(0.0, 1.0);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _bar(base, highlight, head, at, widthFactor: 1.0),
            const SizedBox(height: 8),
            _bar(base, highlight, head, at, widthFactor: 0.60),
          ],
        );
      },
    );
  }

  Widget _bar(
    Color base,
    Color highlight,
    double head,
    double Function(double) at, {
    required double widthFactor,
  }) => FractionallySizedBox(
    alignment: Alignment.centerLeft,
    widthFactor: widthFactor,
    child: Container(
      height: 8,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        gradient: LinearGradient(
          colors: [base, highlight, base],
          stops: [at(head - 0.35), at(head), at(head + 0.35)],
        ),
      ),
    ),
  );
}

/// 骨架气泡的生命周期：显示中 → 冻结（等投递 / 已中止）→ 淡出。
enum _SkeletonPhase { none, running, holding, fading }

/// 日期分隔条：今天 / 昨天 / `YYYY-MM-DD`，弱化居中。
/// [label] 由时间线层预算好：分隔条不读系统时钟，避免每帧对每个分隔条做一次日期差。
class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.x12),
      child: Row(
        children: [
          Expanded(child: Divider(height: 1, color: colors.borderDivider)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.x8),
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.textTertiary,
              ),
            ),
          ),
          Expanded(child: Divider(height: 1, color: colors.borderDivider)),
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

  static String _keyOf(String provider, String model) =>
      '$provider\u0000$model';

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
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
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
                  prefixIcon: Icon(
                    Icons.search,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
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
                  fillColor: scheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
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
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
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
                    final message = error is ApiFailure
                        ? '${error.code}：${error.message}'
                        : '$error';
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
                  final grouped =
                      snapshot.data ?? const <String, List<ModelOption>>{};
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
  List<_PickRow> _rowsFor(
    Map<String, List<ModelOption>> grouped,
    String query,
  ) {
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
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(20),
      ),
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
        current != null &&
        current.provider == provider &&
        current.model == option.id;
    final saving = _pending == _keyOf(provider, option.id);
    final name = option.name?.trim();
    final title = name == null || name.isEmpty
        ? shortModelLabel(ModelRef(provider, option.id))
        : name;
    final subtitle = option.id == title || option.label == option.id
        ? null
        : option.id;
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
      minVerticalPadding: 2,
      contentPadding: const EdgeInsets.only(left: 4, right: 16),
      minLeadingWidth: 22,
      enabled: _pending == null,
      leading: SizedBox(
        width: 22,
        child: selected
            ? Icon(Icons.check, size: 18, color: scheme.primary)
            : null,
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
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
