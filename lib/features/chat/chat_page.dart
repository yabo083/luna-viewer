import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/capability/sessions_repository.dart';
import '../../core/model/models.dart';
import 'message_view.dart';

/// 会话详情：只读历史 + 实时流 + 会话级操作（中止 / 压缩 / 分叉 / 重新载入）。
/// v0.1.0 不在 App 里发消息——平台会话的输入仍由聊天软件承担。
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.repo, required this.base, required this.session});

  final SessionsRepository repo;
  final Uri base;
  final SessionSummary session;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _scroll = ScrollController();
  final List<ChatMessage> _messages = [];
  final StringBuffer _streaming = StringBuffer();
  StreamSubscription<LiveEvent>? _live;
  Timer? _poll;
  bool _loading = true;
  bool _liveOk = true;
  bool _running = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _running = widget.session.running;
    _load();
    _startLive();
  }

  @override
  void dispose() {
    _live?.cancel();
    _poll?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final transcript = await widget.repo.transcript(widget.session.id);
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(transcript.messages);
        _loading = false;
        _error = null;
      });
      _scrollToEnd();
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
            _scrollToEnd();
          case LiveEventKind.delta:
            setState(() {
              _running = true;
              _streaming.write(event.delta ?? '');
            });
            _scrollToEnd();
          case LiveEventKind.tool:
            setState(() => _running = true);
          case LiveEventKind.settled:
            setState(() {
              _running = false;
              _streaming.clear();
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

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.session.title, maxLines: 1, overflow: TextOverflow.ellipsis),
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
      body: Column(
        children: [
          _Header(session: widget.session, running: _running, liveOk: _liveOk),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null && _messages.isEmpty
                ? Center(child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                    itemCount: _messages.length + (_streaming.isEmpty ? 0 : 1),
                    itemBuilder: (context, index) {
                      if (index == _messages.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: SelectableText(
                            _streaming.toString(),
                            style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
                          ),
                        );
                      }
                      return MessageView(message: _messages[index], base: widget.base);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.session, required this.running, required this.liveOk});

  final SessionSummary session;
  final bool running;
  final bool liveOk;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = [
      session.origin,
      if (session.engine.isNotEmpty) session.engine,
      if (session.model != null) session.model!.toString(),
      if (running) '生成中',
      if (!liveOk) '实时流不可用·轮询中',
    ];
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(parts.join(' · '), style: theme.textTheme.bodySmall),
    );
  }
}
