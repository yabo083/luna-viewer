import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/capability/sessions_repository.dart';
import '../../core/model/models.dart';
import '../../core/store/connection_store.dart';
import '../../core/transport/api_client.dart';
import '../../core/transport/state_socket.dart';
import '../../core/update/update_checker.dart';
import '../chat/assistant_avatar.dart';
import '../chat/chat_page.dart';

class SessionsPage extends StatefulWidget {
  const SessionsPage({
    super.key,
    required this.connection,
    required this.themeMode,
    required this.onThemeChanged,
    required this.onDisconnect,
  });

  final Connection connection;
  final ValueNotifier<ThemeMode> themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final Future<void> Function() onDisconnect;

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  late final ApiClient _api = ApiClient(base: widget.connection.base, token: widget.connection.token);
  late final SessionsRepository _repo = SessionsRepository(_api);
  final List<SessionSummary> _items = [];
  BotProfile? _bot;
  bool _loading = true;
  String? _error;
  String? _cursor;

  @override
  void initState() {
    super.initState();
    _refresh();
    _checkUpdate();
    _loadBot();
  }

  Future<void> _loadBot() async {
    final profile = await StateSocket(
      base: widget.connection.base,
      token: widget.connection.token,
    ).fetch('adapters.bots');
    final bot = BotProfile.pick(profile);
    if (bot != null && mounted) setState(() => _bot = bot);
  }

  Future<void> _checkUpdate() async {
    // 每天最多查一次 GitHub，避免每次进前台都打 API。
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt('update.checkedAt') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - last < const Duration(hours: 24).inMilliseconds) return;
    await prefs.setInt('update.checkedAt', now);
    final update = await UpdateChecker.check();
    if (update == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('新版本 ${update.version} 可用'),
        action: SnackBarAction(
          label: '查看',
          onPressed: () => launchUrl(update.url, mode: LaunchMode.externalApplication),
        ),
      ),
    );
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

  Future<void> _openSettings() async {
    final mode = widget.themeMode.value;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.brightness_6_outlined),
              title: const Text('主题'),
              subtitle: Text(switch (mode) {
                ThemeMode.light => '浅色',
                ThemeMode.dark => '深色',
                ThemeMode.system => '跟随系统',
              }),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pop(context, 'theme'),
            ),
            ListTile(
              leading: const Icon(Icons.system_update_alt),
              title: const Text('检查更新'),
              onTap: () => Navigator.pop(context, 'update'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('复制诊断信息'),
              subtitle: const Text('版本 / 地址 / 机器人'),
              onTap: () => Navigator.pop(context, 'diag'),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('关于'),
              subtitle: Text('版本 $appVersion'),
              onTap: () => Navigator.pop(context, 'about'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.link_off),
              title: const Text('断开连接'),
              onTap: () => Navigator.pop(context, 'disconnect'),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    switch (picked) {
      case 'theme':
        await _pickTheme();
      case 'update':
        final update = await UpdateChecker.check();
        if (!mounted) return;
        if (update == null) {
          _toast('已是最新版本（$appVersion）');
        } else {
          await launchUrl(update.url, mode: LaunchMode.externalApplication);
        }
      case 'diag':
        final text = [
          'ChatLuna Mobile $appVersion',
          'base ${widget.connection.base}',
          'bot ${_bot?.name ?? '-'} (${_bot?.platform ?? '-'}:${_bot?.selfId ?? '-'})',
        ].join('\n');
        await Clipboard.setData(ClipboardData(text: text));
        _toast('已复制');
      case 'about':
        if (!mounted) return;
        showAboutDialog(
          context: context,
          applicationName: 'ChatLuna',
          applicationVersion: appVersion,
          applicationLegalese: '连接到自托管的 ChatLuna v2 实例',
        );
      case 'disconnect':
        await _confirmDisconnect();
    }
  }

  Future<void> _pickTheme() async {
    final mode = widget.themeMode.value;
    final picked = await showDialog<ThemeMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('主题'),
        children: [
          RadioListTile<ThemeMode>(
            value: ThemeMode.system,
            groupValue: mode,
            title: const Text('跟随系统'),
            onChanged: (value) => Navigator.pop(context, value),
          ),
          RadioListTile<ThemeMode>(
            value: ThemeMode.light,
            groupValue: mode,
            title: const Text('浅色'),
            onChanged: (value) => Navigator.pop(context, value),
          ),
          RadioListTile<ThemeMode>(
            value: ThemeMode.dark,
            groupValue: mode,
            title: const Text('深色'),
            onChanged: (value) => Navigator.pop(context, value),
          ),
        ],
      ),
    );
    if (picked != null) widget.onThemeChanged(picked);
  }

  Future<void> _confirmDisconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('断开连接？'),
        content: const Text('会清除本机保存的 token，需要重新输入才能连接。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('断开')),
        ],
      ),
    );
    if (confirmed == true) {
      await HapticFeedback.mediumImpact();
      await widget.onDisconnect();
    }
  }

  Future<void> _open(SessionSummary session) async {
    // 先把历史取回来再推路由：详情页第一帧就有内容，不会出现「空白/残影」再加载的过程。
    Transcript? initial;
    try {
      initial = await _repo.transcript(session.id);
    } on ApiFailure catch (e) {
      _toast('${e.code}：${e.message}');
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      // 三键导航栏没有系统边缘手势；用 Cupertino 路由把「左缘右滑返回」做进 App。
      CupertinoPageRoute<void>(
        builder: (_) => ChatPage(
          repo: _repo,
          base: widget.connection.base,
          headers: _api.authHeaders,
          avatarUrl: _bot?.avatar,
          botName: _bot?.name,
          initial: initial,
          session: session,
        ),
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
      await HapticFeedback.mediumImpact();
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
          IconButton(onPressed: _openSettings, icon: const Icon(Icons.tune), tooltip: '设置'),
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
            : _items.isEmpty
            ? ListView(
                padding: const EdgeInsets.fromLTRB(32, 96, 32, 32),
                children: [
                  Icon(Icons.bolt_outlined, size: 40, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(height: 12),
                  Text('实例当前没有活跃会话', textAlign: TextAlign.center, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Text(
                    'ChatLuna 只把已加载的会话列出来。在聊天软件里发一条消息，或等下一次主动唤醒后再下拉刷新。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  Center(child: OutlinedButton(onPressed: _refresh, child: const Text('刷新'))),
                ],
              )
            : ListView(
                children: [
                  for (final row in _rows(context)) row,
                  SizedBox(height: 72 + MediaQuery.paddingOf(context).bottom),
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
      _SectionHeader(label: active.isEmpty ? '全部活跃会话' : '其他会话', count: rest.length),
      for (final session in rest) _tile(session),
    ];
  }

  Widget _tile(SessionSummary session) => ListTile(
    leading: AssistantAvatar(size: 36, imageUrl: _bot?.avatar),
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
        : Text(
            _relativeTime(session.createdAt),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
  );
}

String _relativeTime(DateTime time) {
  final now = DateTime.now();
  final day = DateTime(time.year, time.month, time.day);
  final today = DateTime(now.year, now.month, now.day);
  final hm = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  if (day == today) return '今天 $hm';
  if (today.difference(day).inDays == 1) return '昨天 $hm';
  return '${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} $hm';
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
