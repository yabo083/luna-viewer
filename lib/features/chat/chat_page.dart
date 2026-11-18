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

class _ChatPageState extends State<ChatPage> {
  /// 一页的消息条数；向上滚动时按「更早一页」继续取。
  static const _pageSize = 50;

  final _scroll = ScrollController();

  /// 已加载的消息，时间升序（最新在末尾；倒序列表把它按 index 反过来渲染）。
  List<PlatformMessage> _messages = const [];

  /// 已入列的消息 id：分页、实时帧、重载三条路都靠它去重。
  final Set<String> _ids = {};

  /// 框架消息（wake/memory/工具摘要等）：只对已加载会话从 `/api/sessions/:id/messages`
  /// 与 `/events` 取。平台消息里没有这些，所以单独一条时间线，渲染成居中单卡片。
  List<_FrameworkEntry> _framework = const [];
  final Set<String> _frameworkIds = {};

  /// 框架块上限：长开页面只留最近的，避免无限增长。
  static const int _frameworkCap = 400;

  /// 与平台消息对齐的时间窗：同一段正文在这个窗口内算同一条。
  static const Duration _dedupeWindow = Duration(seconds: 3);

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

  /// 首个 snapshot 是否已到：权威帧之前，`session.running` 只是乐观值。
  bool _snapshotSeen = false;

  PlatformStream? _stream;
  StreamSubscription<PlatformEvent>? _streamSub;

  LiveState _live = LiveState.idle;

  bool _awayFromBottom = false;
  final ValueNotifier<int> _unseen = ValueNotifier<int>(0);

  /// 会话当前模型；切换成功后立即反映到信息栏与详情。
  ModelRef? _model;

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
    _model = widget.session?.model;
    // 列表页的 running 只做乐观值：首个 snapshot 到达后一律以服务端为准。
    _live = (widget.session?.running ?? false) ? LiveState.thinking : LiveState.idle;
    _scroll.addListener(_onScroll);
    _load();
    // 首帧先画出来再连实时流：SSE 握手与首个 snapshot 会和首屏排版抢时间。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 首帧上屏时间：点击 → 可见反馈的本地耗时，debug 头部显示。
      _paintMs ??= _since();
      // 未加载的会话没有 agent：`/live` 只会 404，不连。
      if (widget.session != null) {
        _startLive();
        // 增量事件同样放到首帧之后：它只补充中间块，不能拖慢首屏。
        _startEvents();
      }
      _startStream();
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
    _streamSub?.cancel();
    _stream?.dispose();
    _snapshotTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  int _since() => DateTime.now().difference(_t0).inMilliseconds;

  bool get _loaded => widget.session != null;

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
    final session = widget.session;
    if (session == null) return;
    if (_frameworkStarted && !force) return;
    _frameworkStarted = true;
    try {
      final transcript = await widget.repo.transcript(session.id);
      if (!mounted) return;
      final entries = <_FrameworkEntry>[];
      // 日志里平台消息也在：它给后面的框架块当时间锚点（服务端没给时戳时仍能落在正确位置）。
      DateTime? anchor;
      for (final message in transcript.messages) {
        final text = message.bodyMarkdown.trim();
        if (text.isEmpty) continue;
        if (!message.isFramework) {
          anchor = _platformTimeOf(text) ?? anchor;
          continue;
        }
        entries.add(
          _FrameworkEntry(
            id: message.id.isNotEmpty ? message.id : 'framework-${_squeeze(text).hashCode}',
            text: text,
            time: message.time ?? anchor,
          ),
        );
      }
      setState(() {
        // 保留日志返回之前就通过 `/events` 进来的条目：同一 id 以日志为准。
        final ids = {for (final entry in entries) entry.id};
        final tail = [
          for (final entry in _framework)
            if (!ids.contains(entry.id)) entry,
        ];
        _framework = [...entries, ...tail];
        _frameworkIds
          ..clear()
          ..addAll(entries.map((entry) => entry.id))
          ..addAll(tail.map((entry) => entry.id));
      });
    } on ApiFailure {
      // 框架块只是补充：拿不到就只显示平台消息，不弹错。
    }
  }

  /// `/events` 增量：只收框架类 entry。平台 `stream` 才是消息本体，两者互不影响。
  void _startEvents() {
    final session = widget.session;
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
        final id = message.id.isNotEmpty ? message.id : 'framework-${_squeeze(text).hashCode}';
        if (!_frameworkIds.add(id)) return;
        final time = message.time ?? DateTime.now();
        // 指令类消息同时是平台发言（`chatluna …`）：已出现在气泡里的不再画第二遍。
        if (_duplicateOfPlatform(text, time)) return;
        setState(() {
          final next = [..._framework, _FrameworkEntry(id: id, text: text, time: time)];
          _framework = next.length > _frameworkCap
              ? next.sublist(next.length - _frameworkCap)
              : next;
        });
      },
      onError: (Object _) {},
      cancelOnError: true,
    );
  }

  /// 去重键：正文压掉所有空白（换行/缩进不影响「同一条」判定）。
  static String _squeeze(String text) => text.replaceAll(RegExp(r'\s+'), '');

  /// 平台消息的正文 → 时间；框架块在服务端没给时戳时用它当锚点。
  DateTime? _platformTimeOf(String text) {
    final key = _squeeze(text);
    if (key.isEmpty) return null;
    for (final message in _messages) {
      if (_squeeze(message.content) == key) return message.time;
    }
    return null;
  }

  /// 框架正文与平台消息「压空白后同文 + 时间相差 3s 内」= 同一条，不重复显示。
  bool _duplicateOfPlatform(String text, DateTime? at) {
    final key = _squeeze(text);
    if (key.isEmpty) return true;
    for (final message in _messages) {
      if (_squeeze(message.content) != key) continue;
      // 没有时间戳就没法对齐：正文相同按重复处理，宁少不重。
      if (at == null) return true;
      if (message.time.difference(at).abs() <= _dedupeWindow) return true;
    }
    return false;
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
    final session = widget.session;
    if (_liveStarted || session == null || !mounted) return;
    _liveStarted = true;
    // 8s 内既没有 snapshot 也没有任何事件：乐观的 running 收回去，空闲会话绝不播动画。
    _snapshotTimer?.cancel();
    _snapshotTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || _snapshotSeen) return;
      _setLive(LiveState.idle);
    });
    _liveSub = widget.repo.live(session.id).listen(
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
        // `/live` 断了就没法知道生成状态：回到待机，消息仍由平台流补上。
        _snapshotTimer?.cancel();
        _setLive(LiveState.idle);
      },
      onDone: () {
        if (!mounted) return;
        _snapshotTimer?.cancel();
        _setLive(LiveState.idle);
      },
      cancelOnError: true,
    );
  }

  /// 唯一的写入口：相同状态不触发重建。
  void _setLive(LiveState next) {
    if (_live == next) return;
    setState(() => _live = next);
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

  Future<void> _cancel() async {
    final session = widget.session;
    if (session == null) return;
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
    }
  }

  Future<void> _compact() async {
    final session = widget.session;
    if (session == null) return;
    try {
      final result = await widget.repo.compact(session.id);
      _toast('已压缩：${result ?? '完成'}');
    } on ApiFailure catch (e) {
      _toast('压缩失败 ${e.code}：${e.message}');
    }
  }

  Future<void> _fork() async {
    final session = widget.session;
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
    final session = widget.session;
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
    final session = widget.session;
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

  /// 分组窗口：同一发送者 5 分钟内的连续消息共用一次头像与名字。
  static const Duration _groupWindow = Duration(minutes: 5);

  /// 时间线：平台消息 + 框架块，按时间插好日期分隔条，并算出每条是否显示头像/名字。
  /// 分组键 = 发送者（`bot` / `user:<id>`）+ 5 分钟窗口；跨天、跨发送者都重新起组。
  List<_TimelineItem> _timeline() {
    final messages = _messages;
    if (messages.isEmpty && _framework.isEmpty) return const [];

    // 平台正文索引：框架块与它们对齐去重（正文压空白 + 3s 窗口）。
    final index = <String, List<DateTime>>{};
    for (final message in messages) {
      final key = _squeeze(message.content);
      if (key.isEmpty) continue;
      (index[key] ??= []).add(message.time);
    }
    final notices = <_FrameworkEntry>[
      for (final entry in _framework)
        if (!_isDuplicate(index, entry)) entry,
    ];

    final items = <_TimelineItem>[];
    DateTime? day;
    var lastSender = '';
    DateTime? lastTime;

    // 日期分隔条：跨天时顺带把分组状态清掉，后一条重新显示头像与名字。
    void separatorFor(DateTime? at) {
      if (at == null) return;
      final date = DateTime(at.year, at.month, at.day);
      if (day != null && _sameDay(day!, date)) return;
      day = date;
      lastSender = '';
      lastTime = null;
      items.add(_DayItem(date));
    }

    var next = 0;
    for (final message in messages) {
      // 落在这一条之前的框架块先插进去。
      while (next < notices.length) {
        final entry = notices[next];
        final at = entry.time;
        if (at == null || !at.isBefore(message.time)) break;
        separatorFor(at);
        items.add(_NoticeItem(entry));
        // 框架块打断分组：后面的人重新显示头像与名字。
        lastSender = '';
        lastTime = null;
        next += 1;
      }
      separatorFor(message.time);
      final sender = message.outbound
          ? 'bot'
          : 'user:${message.userId.isNotEmpty ? message.userId : (message.userName ?? '')}';
      final previous = lastTime;
      final showHeader = sender != lastSender ||
          previous == null ||
          message.time.difference(previous).abs() > _groupWindow;
      items.add(_MessageItem(message, showHeader: showHeader));
      lastSender = sender;
      lastTime = message.time;
    }
    // 剩下的框架块：没有时戳的排在日志尾部，按取回顺序。
    for (; next < notices.length; next++) {
      final entry = notices[next];
      separatorFor(entry.time);
      items.add(_NoticeItem(entry));
      lastSender = '';
      lastTime = null;
    }
    return items;
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// 时间线上的一项 → Widget。缓存键包含渲染所需的全部可变输入（id / 是否显示头部），
  /// 因此同一个实例可以安全复用；状态（折叠、图片解码）都在子 widget 自己的 State 里。
  Widget _itemWidget(_TimelineItem item) {
    final (cacheKey, build) = switch (item) {
      _DayItem(:final day) => (
        'd:${day.toIso8601String()}',
        () => _DayDivider(day: day),
      ),
      _NoticeItem(:final entry) => (
        'n:${entry.id}',
        () => FrameworkNoticeCard(foldKey: entry.id, text: entry.text, open: _noticeOpen),
      ),
      _MessageItem(:final message, :final showHeader) => (
        'm:${message.id}:$showHeader',
        () => MessageView(
          key: ValueKey(message.id),
          message: message.view,
          base: widget.base,
          headers: widget.headers,
          noticeOpen: _noticeOpen,
          media: message.media,
          avatarUrl: message.outbound ? widget.avatarUrl : message.avatar,
          senderName: message.outbound ? widget.botName : message.userName,
          time: message.time,
          showHeader: showHeader,
        ),
      ),
    };
    return _itemCache[cacheKey] ??= build();
  }

  static bool _isDuplicate(Map<String, List<DateTime>> index, _FrameworkEntry entry) {
    final times = index[_squeeze(entry.text)];
    if (times == null) return false;
    final at = entry.time;
    // 没有时间戳就没法对齐：正文相同按重复处理，宁少不重。
    if (at == null) return true;
    for (final time in times) {
      if (time.difference(at).abs() <= _dedupeWindow) return true;
    }
    return false;
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
              onPressed: _live.generating ? _cancel : null,
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
          // 状态胶囊只属于已加载会话：`/live` 驱动它，未加载时整条信息栏都不出现。
          if (_loaded)
            ChatInfoBar(
              session: _summary,
              light: _live.statusLight,
              botName: widget.botName,
              avatarUrl: widget.avatarUrl,
              debugMetrics: _debugMetrics(),
              showDeveloperInfo: widget.showDeveloperInfo,
              onModelTap: _pickModel,
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

/// 时间线上的一项。日期分隔条没有时间（它本身就是「哪一天」）。
sealed class _TimelineItem {
  const _TimelineItem();
}

class _DayItem extends _TimelineItem {
  const _DayItem(this.day);

  final DateTime day;
}

class _NoticeItem extends _TimelineItem {
  const _NoticeItem(this.entry);

  final _FrameworkEntry entry;
}

class _MessageItem extends _TimelineItem {
  const _MessageItem(this.message, {required this.showHeader});

  final PlatformMessage message;

  /// 同一发送者 5 分钟内的连续消息里只有第一条为 true。
  final bool showHeader;
}

/// 一条框架消息：正文、折叠键与对齐用的时间（可能为空）。
class _FrameworkEntry {
  const _FrameworkEntry({required this.id, required this.text, this.time});

  final String id;
  final String text;
  final DateTime? time;
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
