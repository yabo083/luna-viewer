import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/capability/sessions_repository.dart';
import '../../core/model/models.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.repo, required this.session});

  final SessionsRepository repo;
  final SessionSummary session;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
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
    _input.dispose();
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
    _poll = Timer.periodic(const Duration(milliseconds: 1200), (timer) async {
      if (!mounted || ticks++ > 60) {
        timer.cancel();
        return;
      }
      await _load();
      final last = _messages.isEmpty ? null : _messages.last;
      if (last != null && !last.isUser) {
        timer.cancel();
        setState(() => _running = false);
      }
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

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _running) return;
    setState(() {
      _messages.add(ChatMessage(id: 'local-${DateTime.now().microsecondsSinceEpoch}', role: 'user', blocks: [
        ChatBlock('text', {'text': text}),
      ]));
      _running = true;
      _streaming.clear();
      _input.clear();
    });
    _scrollToEnd();
    try {
      await widget.repo.send(widget.session.id, text);
      if (!_liveOk) _startPolling();
    } on ApiFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = '发送失败 ${e.code}：${e.message}';
      });
    }
  }

  Future<void> _cancel() async {
    try {
      await widget.repo.cancel(widget.session.id);
    } on ApiFailure catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('取消失败 ${e.code}')));
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _streaming.clear();
    });
  }

  Future<void> _compact() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await widget.repo.compact(widget.session.id);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('已压缩：${result ?? '完成'}')));
      await _load();
    } on ApiFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('压缩失败 ${e.code}：${e.message}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final writable = widget.session.writable;
    final canWrite = writable && !_running;
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
              if (value == 'reload') _load();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'compact', child: Text('压缩上下文')),
              PopupMenuItem(value: 'reload', child: Text('重新载入')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (!writable)
            Container(
              width: double.infinity,
              color: theme.colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '这个会话来自 ${widget.session.origin}，只能查看，不能从 App 发消息。',
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (!_liveOk)
            Container(
              width: double.infinity,
              color: theme.colorScheme.errorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('实时流不可用，改用轮询。', style: theme.textTheme.bodySmall),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null && _messages.isEmpty
                ? Center(child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                    itemCount: _messages.length + (_streaming.isEmpty ? 0 : 1),
                    itemBuilder: (context, index) {
                      if (index == _messages.length) {
                        return _Bubble(text: _streaming.toString(), isUser: false, streaming: true);
                      }
                      final message = _messages[index];
                      final text = message.displayText;
                      if (text.isEmpty) return const SizedBox.shrink();
                      return _Bubble(text: text, isUser: message.isUser);
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: writable,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => canWrite ? _send() : null,
                      decoration: InputDecoration(
                        hintText: writable ? (_running ? '生成中…' : '说点什么') : '只读会话',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: canWrite ? _send : null,
                    icon: const Icon(Icons.arrow_upward),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.text, required this.isUser, this.streaming = false});

  final String text;
  final bool isUser;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isUser ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: SelectableText(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
        ),
      ),
    );
  }
}
