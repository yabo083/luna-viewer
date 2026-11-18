import 'package:material_ui/material_ui.dart';

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
      setState(() => _error = '${e.code}：${e.message}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_cursor == null || _loading) return;
    try {
      final page = await _repo.list(cursor: _cursor);
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
      MaterialPageRoute<void>(builder: (_) => ChatPage(repo: _repo, session: session)),
    );
    await _refresh();
  }

  Future<void> _create() async {
    final input = await showDialog<_NewSession>(
      context: context,
      builder: (_) => _NewSessionDialog(repo: _repo),
    );
    if (input == null) return;
    try {
      final session = await _repo.create(
        title: input.title,
        engine: input.engine,
        model: input.model,
      );
      await _refresh();
      if (mounted) await _open(session);
    } on ApiFailure catch (e) {
      _toast('新建失败 ${e.code}：${e.message}');
    }
  }

  Future<void> _actions(SessionSummary session) async {
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
      if (title != null && title.isNotEmpty) {
        try {
          await _repo.rename(session.id, title);
          await _refresh();
        } on ApiFailure catch (e) {
          _toast('改名失败 ${e.code}');
        }
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
      floatingActionButton: FloatingActionButton(
        onPressed: _create,
        tooltip: '新建会话',
        child: const Icon(Icons.add_comment_outlined),
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
            : ListView.separated(
                itemCount: _items.length + 1,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  if (index == _items.length) {
                    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
                    return const SizedBox(height: 64);
                  }
                  final session = _items[index];
                  return ListTile(
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
                              decoration: BoxDecoration(
                                color: Color(0xFF4ADE80),
                                shape: BoxShape.circle,
                              ),
                            ),
                          )
                        : null,
                  );
                },
              ),
      ),
    );
  }
}

class _NewSession {
  const _NewSession({this.title, this.engine, this.model});

  final String? title;
  final String? engine;
  final ModelRef? model;
}

class _NewSessionDialog extends StatefulWidget {
  const _NewSessionDialog({required this.repo});

  final SessionsRepository repo;

  @override
  State<_NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends State<_NewSessionDialog> {
  final _title = TextEditingController();
  List<EngineOption> _engines = const [];
  List<ModelOption> _models = const [];
  String? _engine;
  ModelOption? _model;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([widget.repo.engines(), widget.repo.models()]);
      if (!mounted) return;
      setState(() {
        _engines = results[0] as List<EngineOption>;
        _models = results[1] as List<ModelOption>;
        _engine = _engines.where((e) => e.id != 'off').map((e) => e.id).firstOrNull;
        _loading = false;
      });
    } on ApiFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '${e.code}：${e.message}';
      });
    }
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建会话'),
      content: SizedBox(
        width: 360,
        child: _loading
            ? const SizedBox(height: 96, child: Center(child: CircularProgressIndicator()))
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: _title,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: '标题（可留空）'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _engine,
                    decoration: const InputDecoration(labelText: '引擎'),
                    items: [
                      for (final e in _engines)
                        if (e.id != 'off') DropdownMenuItem(value: e.id, child: Text(e.label)),
                    ],
                    onChanged: (value) => setState(() => _engine = value),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<ModelOption>(
                    initialValue: _model,
                    decoration: const InputDecoration(labelText: '模型（默认跟随规则）'),
                    isExpanded: true,
                    items: [
                      for (final m in _models)
                        DropdownMenuItem(
                          value: m,
                          child: Text('${m.provider} / ${m.name}', overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (value) => setState(() => _model = value),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                ],
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: _loading
              ? null
              : () => Navigator.pop(
                  context,
                  _NewSession(
                    title: _title.text.trim(),
                    engine: _engine,
                    model: _model?.ref,
                  ),
                ),
          child: const Text('创建'),
        ),
      ],
    );
  }
}
