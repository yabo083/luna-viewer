import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/capability/sessions_repository.dart';
import '../../core/model/models.dart';
import 'chat_chrome.dart';
import 'message_view.dart';

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

  /// 流式正文：SSE delta 只进 buffer，最多每 90ms 刷进 notifier；
  /// 列表里的流式气泡单独监听，不随每个 delta 重建整页。
  final StringBuffer _streaming = StringBuffer();
  final ValueNotifier<String> _streamingText = ValueNotifier<String>('');
  static const _streamFlushInterval = Duration(milliseconds: 90);
  Timer? _flushTimer;

  StreamSubscription<LiveEvent>? _live;
  Timer? _poll;
  bool _loading = true;
  bool _liveOk = true;
  bool _running = false;
  String? _error;

  bool _awayFromBottom = false;
  final ValueNotifier<int> _unseen = ValueNotifier<int>(0);

  /// 会话当前模型；切换成功后立即反映到信息栏与详情。
  ModelRef? _model;

  late final DateTime _t0;
  int? _netMs;
  int? _paintMs;
  int? _liveMs;

  @override
  void initState() {
    super.initState();
    _t0 = DateTime.now();
    _model = widget.session.model;
    _running = widget.session.running;
    _scroll.addListener(_onScroll);
    final initial = widget.initial;
    if (initial != null) {
      _all = initial.messages;
      _windowStart = _all.length > _initialWindow ? _all.length - _initialWindow : 0;
      _loading = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _paintMs = _since());
      });
    } else {
      _load();
    }
    // 首帧先画出来再连实时流：SSE 握手与首个 snapshot 会和首屏排版抢时间。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startLive();
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _flushTimer?.cancel();
    _streamingText.dispose();
    _unseen.dispose();
    _live?.cancel();
    _poll?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  int _since() => DateTime.now().difference(_t0).inMilliseconds;

  Future<void> _load() async {
    try {
      final transcript = await widget.repo.transcript(widget.session.id);
      if (!mounted) return;
      _netMs = _since();
      setState(() {
        final keepWindow = _all.isNotEmpty;
        _all = transcript.messages;
        if (!keepWindow) {
          _windowStart = _all.length > _initialWindow ? _all.length - _initialWindow : 0;
        }
        _loading = false;
        _error = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _paintMs = _since());
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
    }
  }

  void _startLive() {
    _live = widget.repo.live(widget.session.id).listen(
      (event) {
        if (!mounted) return;
        _liveMs ??= _since();
        switch (event.kind) {
          case LiveEventKind.snapshot:
            _flushTimer?.cancel();
            _flushTimer = null;
            _streaming.clear();
            for (final part in event.parts) {
              if (part['type'] == 'text' && part['delta'] is String) {
                _streaming.write(part['delta'] as String);
              }
            }
            _flushStreaming();
            if (!_running) setState(() => _running = true);
            _followIfAtBottom();
          case LiveEventKind.delta:
            if (!_running) setState(() => _running = true);
            _streaming.write(event.delta ?? '');
            if (_awayFromBottom) _unseen.value += 1;
            // 首个 delta 直接出字（替换打字指示器），之后才按 90ms 合并。
            if (_streamingText.value.isEmpty) {
              _flushStreaming();
            } else {
              _scheduleStreamFlush();
            }
            _followIfAtBottom();
          case LiveEventKind.tool:
            if (!_running) setState(() => _running = true);
          case LiveEventKind.settled:
            // 收尾时立刻 flush，避免最后一段 delta 卡在定时器里被丢掉。
            _flushTimer?.cancel();
            _flushTimer = null;
            _flushStreaming();
            _streaming.clear();
            _streamingText.value = '';
            if (_awayFromBottom) _unseen.value += 1;
            if (_running) setState(() => _running = false);
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
        setState(() => _liveOk = false);
        if (_running) _startPolling();
      },
      cancelOnError: true,
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

  void _startPolling() {
    _poll?.cancel();
    var ticks = 0;
    _poll = Timer.periodic(const Duration(milliseconds: 1500), (timer) async {
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
      setState(() => _running = false);
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
        );

  Future<void> _pickModel() async {
    final picked = await showModalBottomSheet<ModelRef>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
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
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = _all.length - _windowStart;
    final streaming = _running ? 1 : 0;
    return Scaffold(
      appBar: AppBar(
        title: ChatTitle(
          title: _summary.title,
          onTap: () => showSessionDetails(context, _summary),
        ),
        actions: [
          IconButton(
            onPressed: _running ? _cancel : null,
            icon: const Icon(Icons.stop_circle_outlined),
            tooltip: '中止当前生成',
          ),
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
            running: _running,
            liveOk: _liveOk,
            botName: widget.botName,
            avatarUrl: widget.avatarUrl,
            debugMetrics: _debugMetrics(),
            showDeveloperInfo: widget.showDeveloperInfo,
            onModelTap: _pickModel,
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
                : _all.isEmpty && !_running
                ? Center(
                    child: Text(
                      '这个会话还没有消息',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
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
                    itemCount: visible + streaming + (_windowStart > 0 ? 1 : 0),
                    itemBuilder: (context, index) {
                      var cursor = index;
                      if (streaming == 1) {
                        if (cursor == 0) {
                          // 只有这一格监听 delta；整页不随 token 重建。
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: ValueListenableBuilder<String>(
                              valueListenable: _streamingText,
                              builder: (context, text, _) => text.isEmpty
                                  ? const _TypingIndicator()
                                  : SelectableText(
                                      text,
                                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
                                    ),
                            ),
                          );
                        }
                        cursor -= 1;
                      }
                      if (cursor < visible) {
                        final message = _all[_all.length - 1 - cursor];
                        return MessageView(
                          message: message,
                          base: widget.base,
                          headers: widget.headers,
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

/// 运行时还没收到首个 delta：三个错峰呼吸的圆点，占 reverse 列表的第 0 项。
class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator> with SingleTickerProviderStateMixin {
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
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Align(
      alignment: Alignment.centerLeft,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2.5, vertical: 4),
                child: Opacity(
                  opacity:
                      0.25 +
                      0.75 *
                          (0.5 +
                              0.5 *
                                  math.sin(
                                    2 * math.pi * (_controller.value - i * 0.18),
                                  )),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                ),
              ),
          ],
        ),
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
  String? _pending;
  String? _error;

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
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.72),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Text('选择模型', style: theme.textTheme.titleMedium),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
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
                  final entries =
                      grouped.entries.where((entry) => entry.value.isNotEmpty).toList();
                  if (entries.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                      child: Text(
                        '实例没有可用模型',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  return ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 8),
                    children: [
                      for (final entry in entries) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                          child: Text(
                            entry.key,
                            style: theme.textTheme.labelSmall?.copyWith(
                              letterSpacing: 1,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        for (final option in entry.value) _tile(entry.key, option),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(String provider, ModelOption option) {
    final theme = Theme.of(context);
    final current = widget.current;
    final selected =
        current != null && current.provider == provider && current.model == option.id;
    final saving = _pending == _keyOf(provider, option.id);
    return ListTile(
      dense: true,
      enabled: _pending == null,
      title: Text(option.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: option.label == option.id
          ? null
          : Text(option.id, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: saving
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : selected
          ? Icon(Icons.check, size: 20, color: theme.colorScheme.primary)
          : null,
      onTap: _pending == null ? () => _select(provider, option) : null,
    );
  }
}
