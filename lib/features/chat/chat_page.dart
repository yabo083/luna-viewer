import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/capability/platform_repository.dart';
import '../../core/capability/platform_stream.dart';
import '../../core/capability/sessions_repository.dart';
import '../../core/model/models.dart';
import 'chat_chrome.dart';
import 'message_view.dart';
import 'timeline.dart';

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

  /// 列表首格是否需要状态胶囊：待机不占位（待机灯常驻在信息栏，不进消息列表）。
  bool get hasCapsule => this != LiveState.idle;

  /// 胶囊文案：信息栏常驻状态灯与消息区占位共用。
  String get capsuleLabel => statusLight.label;

  /// 信息栏状态灯：待机灰点、思考中主色呼吸、回复中主色静止。
  StatusLight get statusLight => switch (this) {
    LiveState.idle => StatusLight.idle,
    LiveState.thinking => StatusLight.thinking,
    LiveState.replying => StatusLight.replying,
  };
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

  /// 已入列的消息 id：分页、实时帧、重载三条路都靠它去重。
  final Set<String> _ids = {};

  /// 框架消息（wake/memory/工具摘要等）：只对已加载会话从 `/api/sessions/:id/messages`
  /// 与 `/events` 取。平台消息里没有这些，所以单独一条时间线，渲染成居中单卡片。
  /// 列表按时间升序维护（[orderNotices]），渲染时与平台消息合并排序。
  List<TimelineNotice> _framework = const [];
  final Set<String> _frameworkIds = {};

  /// 框架块上限：长开页面只留最近的，避免无限增长。
  static const int _frameworkCap = 400;

  StreamSubscription<SessionEvent>? _eventsSub;
  bool _eventsStarted = false;
  bool _frameworkStarted = false;

  /// 框架消息折叠状态表：折叠键 → 是否展开。
  final Map<String, bool> _noticeOpen = {};

  /// 时间线项的 Widget 缓存：同一条消息在后续 setState 里复用同一个实例，
  /// `ListView` 因此跳过整棵 markdown 重建（滚动之外的主要开销）。
  final Map<String, Widget> _itemCache = {};

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
  bool _liveStarted = false;

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

  /// 中止请求在途：按钮暂时置灰，避免连点发出两次 cancel。
  bool _cancelling = false;

  /// 本轮生成计时：从本轮开始（首个 running 事件 / 首个 active snapshot）到 settled。
  /// `null` = 信息栏不显示计时；结束后冻结 [_clockHold] 再消失，让用户看到总耗时。
  /// 只有订阅它的那个小 Text 重建，列表与页面不随每秒 tick 刷新。
  final ValueNotifier<Duration?> _elapsed = ValueNotifier<Duration?>(null);
  Timer? _clockTick;
  Timer? _clockHoldTimer;
  DateTime? _roundStart;

  /// 结束后总耗时停留的时间：够看清一眼，又不至于一直占着信息栏。
  static const _clockHold = Duration(seconds: 2);

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
    // 打开页面时已经在跑：本轮从打开这一刻开始计时，之后的事件不重置起点。
    if (_live.generating) _clockStart();
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
      _ensurePolling();
      // 回前台接着算同一轮：后台的那段时间也是真实耗时。
      _clockResume();
      // 回前台立刻补一拍，不等下一个 3s；`/live` 掉了也在这里接回来。
      if (_pollTimer != null) unawaited(_pollTick());
      if (_loaded) _restartLive();
    } else {
      // 切后台停表：没有屏幕可看，定时器不该继续空转。
      _clockPause();
      _stopProbe();
      _stopPolling();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clockDispose();
    _stopProbe();
    _pollTimer?.cancel();
    _liveRetryTimer?.cancel();
    _scroll.removeListener(_onScroll);
    _flushTimer?.cancel();
    _streamingText.dispose();
    _unseen.dispose();
    _elapsed.dispose();
    _liveSub?.cancel();
    _eventsSub?.cancel();
    _streamSub?.cancel();
    _stream?.dispose();
    _snapshotTimer?.cancel();
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
    final needed = _foreground && _routeVisible && (!_loaded || _polling);
    if (needed) {
      _pollTimer ??= Timer.periodic(_pollInterval, (_) => unawaited(_pollTick()));
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
        if (match != null) _attach(match);
        return;
      }
      // 已加载、`/live` 不在线：只能从 `running` 判断有没有在生成，
      // 分不清思考/回复，所以按「思考中」展示——用户至少知道 bot 在干活。
      if (_polling) {
        final running = match?.running ?? false;
        _setLive(running ? LiveState.thinking : LiveState.idle);
      }
    } on ApiFailure {
      // 探测与兜底都是后台补齐：网络抖动等下一拍，不弹错、不影响消息流。
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
      _startProbe();
    });
  }

  void _startProbe() {
    _probeTimer?.cancel();
    _probeDeadline?.cancel();
    _probeStartedAt = DateTime.now();
    _probeTimer = Timer.periodic(_probeInterval, (_) => unawaited(_probeTick()));
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
        _setLive(LiveState.idle);
      } else if (_streaming.isEmpty) {
        _setLive(LiveState.thinking);
      }
    } on ApiFailure {
      // 兜底也是尽力而为：网络抖动等下一拍。
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
  StatusLight get _statusLight {
    // 有生成在跑就优先报实际阶段——这是 App 的核心信息，不能被兜底模式盖掉。
    if (_live != LiveState.idle) return _live.statusLight;
    return _polling ? StatusLight.polling : StatusLight.idle;
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
      _botAvatar = absoluteResourceUrl(widget.base, BotIdentity.avatarFor(widget.base));
    });
    // 消息头像按消息 id 缓存了 Widget：身份更新后丢一次，右侧气泡才会换上真实头像。
    _itemCache.clear();
  }

  // ---------------------------------------------------------------- 消息加载

  /// 最新一页（首次进入、重载、失败重试共用）。已经通过实时流进来的更新消息不会被丢掉。
  Future<void> _load() async {
    try {
      final page = await widget.platform.messages(widget.conversationKey, limit: _pageSize);
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
    } finally {
      // 首页结果出来后再补框架块：这样日志里的平台消息能给框架条目当时间锚点。
      unawaited(_loadFramework());
    }
  }

  /// 用最新一页对齐：页内的消息以服务端为准，页外更新的（流式期间刚到的）保留在后面。
  void _mergeNewest(PlatformMessagePage page) {
    final pageIds = {for (final message in page.items) message.id};
    final newest = page.items.isEmpty ? null : page.items.last.time;
    final newer = <PlatformMessage>[
      for (final message in _messages)
        if (!pageIds.contains(message.id) &&
            (newest == null || message.time.isAfter(newest)))
          message,
    ];
    _messages = [...page.items, ...newer];
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
    if (session == null) return;
    if (_frameworkStarted && !force) return;
    _frameworkStarted = true;
    try {
      final transcript = await widget.repo.transcript(session.id);
      if (!mounted) return;
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
        at[i] = message.time ?? platformTimes[noticeKey(message.bodyMarkdown.trim())];
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
          entries.add(_notice(message.id, text, message.time ?? _anchor(previous, following[i])));
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
        _framework = orderNotices([...entries, ...tail]);
        _frameworkIds
          ..clear()
          ..addAll(_framework.map((entry) => entry.id));
      });
    } on ApiFailure {
      // 框架块只是补充：拿不到就只显示平台消息，不弹错。
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

  static TimelineNotice _notice(String id, String text, DateTime? time) => TimelineNotice(
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

  /// `/events` 增量：只收框架类 entry。平台 `stream` 才是消息本体，两者互不影响。
  void _startEvents() {
    final session = _session;
    if (_eventsStarted || session == null) return;
    _eventsStarted = true;
    _eventsSub = widget.repo.events(session.id).listen(
      (event) {
        if (!mounted) return;
        // 增量窗口失效：框架块的本地增量不可信，重取一次日志。
        if (event.truncated) {
          unawaited(_loadFramework(force: true));
          return;
        }
        final message = event.message;
        if (message == null || !message.isFramework) return;
        final text = message.bodyMarkdown.trim();
        if (text.isEmpty) return;
        final id = message.id.isNotEmpty ? message.id : 'framework-${noticeKey(text).hashCode}';
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
          _framework = next.length > _frameworkCap
              ? next.sublist(next.length - _frameworkCap)
              : next;
        });
      },
      onError: (Object _) {},
      cancelOnError: true,
    );
  }

  /// 更早一页：游标是最早一条的时间，服务端返回它之前的一页。
  Future<void> _loadEarlier() async {
    if (_loadingMore || !_hasMore || _messages.isEmpty) return;
    _loadingMore = true;
    try {
      final page = await widget.platform.messages(
        widget.conversationKey,
        limit: _pageSize,
        before: _messages.first.time,
      );
      if (!mounted) return;
      // 时间相同的两条可能同时落在两页里，id 去重后只留一条。
      final fresh = [
        for (final message in page.items)
          if (_ids.add(message.id)) message,
      ];
      setState(() {
        _messages = [...fresh, ..._messages];
        // 服务端说没有了，或这一页没有新东西（游标没生效）就停手，避免空转。
        _hasMore = page.hasMore && fresh.isNotEmpty;
      });
    } on ApiFailure catch (e) {
      if (mounted) _toast('加载更早的消息失败 ${e.code}：${e.message}');
    } finally {
      _loadingMore = false;
    }
  }

  // ---------------------------------------------------------------- 实时流

  /// 插件实时流：服务端不做订阅过滤，这里按会话键丢弃别的会话。
  /// 详情页只拿到 `ApiClient.authHeaders`，从同一个头里取回 token 自建客户端。
  void _startStream() {
    final token = _bearer;
    if (token == null || token.isEmpty) return;
    final stream = PlatformStream(widget.base, token);
    _stream = stream;
    _streamSub = stream.events.listen(
      _onPlatformEvent,
      // 断线退避在 PlatformStream 内部：这里只收消息，不把页面拖垮。
      onError: (Object _) {},
    );
  }

  void _onPlatformEvent(PlatformEvent event) {
    if (!mounted) return;
    // 两边都归一：插件帧可能是 `route:r-x:user:y`，构造参数可能是原键。
    if (normalizeConversationKey(event.key) != normalizeConversationKey(widget.conversationKey)) {
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
      _messages = [..._messages, message];
      return true;
    }
    final next = [..._messages];
    final index = next.indexWhere((existing) => existing.time.isAfter(message.time));
    next.insert(index < 0 ? next.length : index, message);
    _messages = next;
    return false;
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

  // ---------------------------------------------------------------- 生成状态

  /// `/live` 只对已加载会话有意义（未加载的会话没有 agent，只会 404）。
  void _startLive() {
    final session = _session;
    if (_liveStarted || session == null || !mounted) return;
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
    _liveSub?.cancel();
    _liveSub = widget.repo.live(session.id).listen(
      (event) {
        if (!mounted) return;
        _lastLiveAt = DateTime.now();
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
            // 快照里有正文就是「回复中」，否则还在思考/工具阶段。
            _setLive(
              event.active
                  ? (_streaming.isEmpty ? LiveState.thinking : LiveState.replying)
                  : LiveState.idle,
            );
            _followIfAtBottom();
          case LiveEventKind.delta:
            _snapshotTimer?.cancel();
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
            if (_streaming.isEmpty) _setLive(LiveState.thinking);
          case LiveEventKind.tool:
            _snapshotTimer?.cancel();
            if (_streaming.isEmpty) _setLive(LiveState.thinking);
          case LiveEventKind.settled:
            // 收尾时立刻 flush，避免最后一段 delta 卡在定时器里被丢掉。
            // 落库的那条由 `platform/stream` 送来，这里不重取历史。
            _snapshotTimer?.cancel();
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
      onError: (Object _) {
        if (!mounted) return;
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

  /// 重建 `/live`：手机切网或长时间待机后，旧连接常常收不到 FIN，
  /// 客户端只看到「一直很安静」——重开一条拿新快照，比等心跳超时快也更确定。
  void _restartLive() {
    _liveSub?.cancel();
    _liveSub = null;
    _liveStarted = false;
    _startLive();
  }

  /// `/live` 掉线：轮询接管状态，9s 后再试一次流。
  /// 轮询的停止条件与探测共用一张表：页面不可见、或流重新接上（snapshot）即停。
  void _liveDown() {
    _liveStarted = false;
    _stopProbe();
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

  /// 唯一的写入口：相同状态不触发重建。本轮计时跟着状态一起进出。
  void _setLive(LiveState next) {
    if (_live == next) return;
    if (next.generating) {
      _clockStart();
    } else {
      _clockFinish();
    }
    setState(() => _live = next);
  }

  // ---------------------------------------------------------------- 本轮计时

  /// 本轮开始：首个 running 事件（poll 的 `running` / 乐观值）或首个 active snapshot。
  /// 重复调用不改起点——同一轮里思考 → 回复不该重新计时。
  void _clockStart() {
    if (_roundStart != null) return;
    _clockHoldTimer?.cancel();
    _clockHoldTimer = null;
    _roundStart = DateTime.now();
    _elapsed.value = Duration.zero;
    _startTicker();
  }

  void _startTicker() {
    _clockTick ??= Timer.periodic(const Duration(seconds: 1), (_) {
      final start = _roundStart;
      if (start == null) return;
      _elapsed.value = DateTime.now().difference(start);
    });
  }

  /// 本轮结束：停表、把总耗时冻在原地 [_clockHold]，然后消失。
  void _clockFinish() {
    final start = _roundStart;
    if (start == null) return;
    _roundStart = null;
    _clockTick?.cancel();
    _clockTick = null;
    _elapsed.value = DateTime.now().difference(start);
    _clockHoldTimer?.cancel();
    _clockHoldTimer = Timer(_clockHold, () {
      _clockHoldTimer = null;
      _elapsed.value = null;
    });
  }

  /// 页面不可见时停表：起点保留，回前台接着算同一轮的真实耗时。
  void _clockPause() {
    _clockTick?.cancel();
    _clockTick = null;
    final start = _roundStart;
    if (start != null) _elapsed.value = DateTime.now().difference(start);
  }

  /// 回前台：这一轮还在跑就接着走表，否则把冻结值留着等它自己消失。
  void _clockResume() {
    if (_roundStart == null) return;
    _startTicker();
    _elapsed.value = DateTime.now().difference(_roundStart!);
  }

  /// 销毁 / 收表：定时器与 notifier 都必须停，否则页面关掉后还在空转。
  void _clockDispose() {
    _clockTick?.cancel();
    _clockTick = null;
    _clockHoldTimer?.cancel();
    _clockHoldTimer = null;
    _roundStart = null;
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
      _flushTimer?.cancel();
      _flushTimer = null;
      _streaming.clear();
      _streamingText.value = '';
      _setLive(LiveState.idle);
    } on ApiFailure catch (e) {
      _toast('取消失败 ${e.code}：${e.message}');
    } catch (e) {
      _toast('取消失败：$e');
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
      _toast('压缩失败 ${e.code}：${e.message}');
    }
  }

  Future<void> _fork() async {
    final session = _session;
    if (session == null) return;
    try {
      final child = await widget.repo.fork(session.id);
      _toast('已分叉：${child.sessionId}（${child.length} 条）');
    } on ApiFailure catch (e) {
      _toast('分叉失败 ${e.code}：${e.message}');
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

  /// 时间线：平台消息 + 框架块合并成一条（规则见 [mergeTimeline]）。
  /// 框架块的锚点在加载时就已经定下，所以这里只做排序与分组，翻页后位置不漂。
  List<TimelineItem> _timeline() => mergeTimeline(_messages, _framework);

  /// 时间线上的一项 → Widget。缓存键包含渲染所需的全部可变输入（id / 是否显示头部），
  /// 因此同一个实例可以安全复用；状态（折叠、图片解码）都在子 widget 自己的 State 里。
  Widget _itemWidget(TimelineItem item) {
    final (cacheKey, build) = switch (item) {
      DayDividerItem(:final day) => (
        'd:${day.toIso8601String()}',
        () => _DayDivider(day: day),
      ),
      NoticeItem(:final notice) => (
        'n:${notice.id}',
        () => FrameworkNoticeCard(foldKey: notice.id, text: notice.text, open: _noticeOpen),
      ),
      MessageItem(:final message, :final showHeader) => (
        'm:${message.id}:$showHeader',
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
          showHeader: showHeader,
        ),
      ),
    };
    return _itemCache[cacheKey] ??= build();
  }

  /// 列表首格：状态胶囊 + 流式正文。只有这一格监听 delta，整页不随 token 重建。
  Widget _liveSlot(ThemeData theme) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _LiveCapsule(state: _live),
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
    final slot = _live.hasCapsule ? 1 : 0;
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
              // 生成中（思考或回复）就能按；请求在途时置灰，避免连点两次 cancel。
              onPressed: _live.generating && !_cancelling ? _cancel : null,
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
              elapsed: _elapsed,
              botName: _botName,
              avatarUrl: _botAvatar,
              debugMetrics: _debugMetrics(),
              showDeveloperInfo: widget.showDeveloperInfo,
              onModelTap: _pickModel,
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
                : items.isEmpty && _live == LiveState.idle
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        '插件还没有这个会话的消息',
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
                      12,
                      12,
                      12,
                      24 + MediaQuery.paddingOf(context).bottom,
                    ),
                    cacheExtent: 600,
                    itemCount: items.length + slot,
                    itemBuilder: (context, index) {
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

/// 日期分隔条：今天 / 昨天 / `YYYY-MM-DD`，弱化居中。
class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    final label = switch (diff) {
      0 => '今天',
      1 => '昨天',
      _ => '${day.year}-${day.month.toString().padLeft(2, '0')}-'
          '${day.day.toString().padLeft(2, '0')}',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 11,
              height: 1.2,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// 实时状态胶囊：「思考中」挂三点呼吸，「回复中」保持静态。
/// 动画随胶囊一起挂载/销毁——正文流入时不再有动画和长文本抢注意力。
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
    final accent = scheme.primary;
    return Container(
      padding: EdgeInsets.fromLTRB(10, 4, thinking ? 6 : 10, 4),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
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
