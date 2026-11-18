import 'dart:async';

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
  });

  final SessionsRepository repo;
  final Uri base;
  final Map<String, String> headers;
  final SessionSummary session;
  final String? avatarUrl;
  final String? botName;

  /// 列表页预先取回的历史：有值时第一帧直接有内容。
  final Transcript? initial;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _scroll = ScrollController();
  /// 全量历史；渲染只用 `_windowStart` 之后的一段，避免一次排版上百条 markdown。
  List<ChatMessage> _all = const [];
  int _windowStart = 0;
  static const _initialWindow = 12;

  final StringBuffer _streaming = StringBuffer();
  StreamSubscription<LiveEvent>? _live;
  Timer? _poll;
  bool _loading = true;
  bool _liveOk = true;
  bool _running = false;
  String? _error;

  bool _awayFromBottom = false;
  int _unseen = 0;

  late final DateTime _t0;
  int? _netMs;
  int? _paintMs;
  int? _liveMs;

  @override
  void initState() {
    super.initState();
    _t0 = DateTime.now();
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
            setState(() {
              _running = true;
              _streaming.clear();
              for (final part in event.parts) {
                if (part['type'] == 'text' && part['delta'] is String) {
                  _streaming.write(part['delta'] as String);
                }
              }
            });
            _followIfAtBottom();
          case LiveEventKind.delta:
            setState(() {
              _running = true;
              _streaming.write(event.delta ?? '');
              if (_awayFromBottom) _unseen += 1;
            });
            _followIfAtBottom();
          case LiveEventKind.tool:
            setState(() => _running = true);
          case LiveEventKind.settled:
            setState(() {
              _running = false;
              _streaming.clear();
              if (_awayFromBottom) _unseen += 1;
            });
            _load();
          case LiveEventKind.lagged:
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
    setState(() => _unseen = 0);
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
      setState(() {
        _running = false;
        _streaming.clear();
      });
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
    final streaming = _streaming.isEmpty ? 0 : 1;
    return Scaffold(
      appBar: AppBar(
        title: ChatTitle(
          title: widget.session.title,
          onTap: () => showSessionDetails(context, widget.session),
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
          child: Badge(
            isLabelVisible: _unseen > 0,
            label: Text('$_unseen'),
            child: const Icon(Icons.arrow_downward),
          ),
        ),
      ),
      body: Column(
        children: [
          ChatInfoBar(
            session: widget.session,
            running: _running,
            liveOk: _liveOk,
            botName: widget.botName,
            avatarUrl: widget.avatarUrl,
            debugMetrics: _debugMetrics(),
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
                : _all.isEmpty && _streaming.isEmpty
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
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: SelectableText(
                              _streaming.toString(),
                              style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
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
