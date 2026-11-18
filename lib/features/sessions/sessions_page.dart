import 'package:flutter/material.dart';

import '../../core/capability/sessions_repository.dart';
import '../../core/model/models.dart';
import '../../core/store/connection_store.dart';
import '../../core/transport/api_client.dart';
import '../chat/chat_page.dart';

class SessionsPage extends StatefulWidget {
  const SessionsPage({super.key, required this.connection, required this.onDisconnect});

  final Connection connection;
  final Future<void> Function() onDisconnect;

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  late final ApiClient _api = ApiClient(base: widget.connection.base, token: widget.connection.token);
  late final SessionsRepository _repo = SessionsRepository(_api);
  final List<SessionSummary> _items = [];
  bool _loading = true;
  String? _error;
  String? _cursor;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _repo.list();
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _cursor = page.nextCursor;
      });
    } on ApiFailure catch (e) {
      if (e.isUnauthorized) {
        await widget.onDisconnect();
        return;
      }
      if (mounted) setState(() => _error = '${e.code}：${e.message}');
    } catch (e) {
      if (mounted) setState(() => _error = '加载失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_cursor == null || _loading) return;
    try {
      final page = await _repo.list(cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _cursor = page.nextCursor;
      });
    } on ApiFailure catch (e) {
      _toast('${e.code}：${e.message}');
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _open(SessionSummary session) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(repo: _repo, base: widget.connection.base, session: session),
      ),
    );
    await _refresh();
  }

  Future<void> _actions(SessionSummary session) async {
    if (!session.writable) {
      _toast('平台会话（${session.origin}）由聊天软件管理，这里只能查看。');
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'rename') {
      final controller = TextEditingController(text: session.title);
      final title = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('重命名'),
          content: TextField(controller: controller, autofocus: true),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('保存')),
          ],
        ),
      );
      if (title == null || title.isEmpty) return;
      try {
        await _repo.rename(session.id, title);
        await _refresh();
      } on ApiFailure catch (e) {
        _toast('改名失败 ${e.code}');
      }
    } else if (action == 'delete') {
      try {
        await _repo.delete(session.id);
        await _refresh();
      } on ApiFailure catch (e) {
        _toast('删除失败 ${e.code}');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('会话'),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh), tooltip: '刷新'),
          IconButton(onPressed: widget.onDisconnect, icon: const Icon(Icons.link_off), tooltip: '断开'),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _loading && _items.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : _error != null && _items.isEmpty
            ? ListView(
                children: [
                  const SizedBox(height: 120),
                  Center(child: Text(_error!, style: TextStyle(color: theme.colorScheme.error))),
                  const SizedBox(height: 12),
                  Center(child: FilledButton(onPressed: _refresh, child: const Text('重试'))),
                ],
              )
            : ListView(
                children: [
                  for (final row in _rows(context)) row,
                  const SizedBox(height: 72),
                ],
              ),
      ),
    );
  }

  List<Widget> _rows(BuildContext context) {
    final active = _items.where((item) => item.running).toList();
    final rest = _items.where((item) => !item.running).toList();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
    return [
      if (active.isNotEmpty) ...[
        _SectionHeader(label: '运行中会话', count: active.length),
        for (final session in active) _tile(session),
      ],
      _SectionHeader(label: active.isEmpty ? '全部会话' : '其他会话', count: rest.length),
      for (final session in rest) _tile(session),
    ];
  }

  Widget _tile(SessionSummary session) => ListTile(
    onTap: () => _open(session),
    onLongPress: () => _actions(session),
    title: Text(session.title, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      [
        session.origin,
        if (session.engine.isNotEmpty) session.engine,
        if (session.model != null) session.model!.toString(),
      ].join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: session.running
        ? const SizedBox(
            width: 10,
            height: 10,
            child: DecoratedBox(
              decoration: BoxDecoration(color: Color(0xFF4ADE80), shape: BoxShape.circle),
            ),
          )
        : null,
  );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Row(
        children: [
          Text(label, style: theme.textTheme.labelLarge),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
