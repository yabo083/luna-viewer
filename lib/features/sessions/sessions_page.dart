import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/capability/platform_repository.dart';
import '../../core/capability/platform_stream.dart';
import '../../core/capability/sessions_repository.dart';
import '../../core/model/models.dart';
import '../../core/store/connection_store.dart';
import '../../core/transport/api_client.dart';
import '../../core/transport/state_socket.dart';
import '../../core/update/update_checker.dart';
import '../chat/assistant_avatar.dart';
import '../chat/chat_chrome.dart';
import '../chat/chat_page.dart';
import '../chat/message_view.dart';

/// 活跃窗口：最后一条消息在 72 小时内的会话留在主列表，更早的收进「归档」。
/// 时间基准是设备当前时间，由列表每次重建时重新计算（收到新消息就自动回到主列表）。
const Duration activeWindow = Duration(days: 3);

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
  late final PlatformRepository _platform = PlatformRepository(_api);

  /// 插件侧的会话真源：列表的每一行都出自这里。
  final List<PlatformConversation> _conversations = [];

  /// `/api/sessions` 的已加载会话：只补充状态胶囊、模型与「运行中」排序，不是消息来源。
  final List<SessionSummary> _loaded = [];
  String? _cursor;
  bool _loadingMore = false;

  /// 实时流的帧：新会话出现、已有会话的计数/最后一条就地更新，不重排整页。
  PlatformStream? _stream;
  StreamSubscription<PlatformEvent>? _streamSub;
  bool _syncing = false;
  DateTime? _syncedAt;
  Timer? _syncTimer;

  final TextEditingController _search = TextEditingController();

  /// 归档子视图：主列表只放 72 小时内的会话，更早的点进这里看。
  bool _archiveOpen = false;

  /// 实时帧合并标志：一帧内的多帧只触发一次重建（重连回放会连发很多条）。
  bool _beatScheduled = false;

  bool _searching = false;
  BotProfile? _bot;

  /// bot 自己的头像（`adapters.bots.user.avatar`，已补成绝对地址）：
  /// 列表顶部与详情页共用，取不到时 `AssistantAvatar` 渐变占位。
  String? _botAvatar;
  bool _loading = true;
  String? _error;
  bool _showDevInfo = false;

  /// 已加载表最近一次对齐时间：流帧触发的 `/api/sessions` 补齐最多 5s 一次。
  DateTime? _loadedSyncedAt;

  @override
  void initState() {
    super.initState();
    // 同实例取过一次就直接用，不等 WS 再回一遍；换实例后缓存自动作废。
    _bot = BotIdentity.profileFor(widget.connection.base);
    _botAvatar = BotIdentity.avatarFor(widget.connection.base);
    _refresh();
    _startStream();
    _checkUpdate();
    _loadBot();
    _loadUiPrefs();
  }

  Future<void> _loadUiPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final value = prefs.getBool('ui.showDevInfo') ?? false;
    if (value != _showDevInfo) setState(() => _showDevInfo = value);
  }

  Future<void> _setShowDevInfo(bool value, StateSetter setSheetState) async {
    setSheetState(() => _showDevInfo = value);
    if (mounted) setState(() => _showDevInfo = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('ui.showDevInfo', value);
  }

  Future<void> _loadBot() async {
    final base = widget.connection.base;
    await BotIdentity.load(base: base, token: widget.connection.token);
    if (!mounted) return;
    final bot = BotIdentity.profileFor(base);
    if (bot == null) return;
    // 头像可能是相对路径（`/files/…`）：`Image.network` 只吃绝对地址，缓存里已是绝对地址。
    setState(() {
      _bot = bot;
      _botAvatar = BotIdentity.avatarFor(base);
    });
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
    _syncTimer?.cancel();
    _streamSub?.cancel();
    _stream?.dispose();
    _search.dispose();
    _api.close();
    super.dispose();
  }

  /// 下拉刷新 = 全量对齐：插件会话表 + 已加载会话表一起重取。
  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 已加载会话只是补充信息：这一层失败不该让列表空白（插件仍然是真源）。
      var loaded = const <SessionSummary>[];
      String? cursor;
      try {
        final page = await _repo.list();
        loaded = page.items;
        cursor = page.nextCursor;
      } on ApiFailure catch (e) {
        if (e.isUnauthorized) rethrow;
      }
      final conversations = await _platform.conversations();
      if (!mounted) return;
      setState(() {
        _loaded
          ..clear()
          ..addAll(loaded);
        _cursor = cursor;
        _conversations
          ..clear()
          ..addAll(conversations);
      });
      // 全量对齐之后算一次「刚同步过」，避免紧接着的流帧再补一遍会话表。
      _syncedAt = DateTime.now();
      _loadedSyncedAt = DateTime.now();
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
    // WS 取头像可能被网络抢先失败，刷新时补一次。
    if (_bot == null) _loadBot();
  }

  /// 只重取会话表（详情页返回、或流里冒出未知会话时）：不动已加载会话、不动滚动位置。
  /// 2 秒内只补一次：回放阶段可能连续冒出多个未知会话，逐帧重取会拖慢整个列表；
  /// 窗口内的请求排队到窗口末尾执行，新会话的第一条消息不会丢。
  Future<void> _syncConversations() async {
    if (_syncing) return;
    final now = DateTime.now();
    final last = _syncedAt;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      _syncTimer ??= Timer(const Duration(seconds: 2), () {
        _syncTimer = null;
        _syncConversations();
      });
      return;
    }
    _syncedAt = now;
    _syncing = true;
    try {
      final conversations = await _platform.conversations();
      if (!mounted) return;
      setState(() => _conversations
        ..clear()
        ..addAll(conversations));
    } on ApiFailure {
      // 列表已经有内容：这一拍补齐失败就等下一页/下拉刷新，不弹错。
    } finally {
      _syncing = false;
    }
  }

  /// `/api/sessions` 对齐：QQ 里发一条消息 → 服务端建会话 → agent 认领，
  /// 最多 5s 就能把 `session` 挂到对应行上（绿点、状态、操作菜单、进详情的 `/live`），
  /// 不用下拉刷新。只对齐第一页；分页拿到的旧行原样保留，游标不动。
  void _syncLoaded({bool force = false}) {
    final now = DateTime.now();
    final last = _loadedSyncedAt;
    if (!force && last != null && now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _loadedSyncedAt = now;
    unawaited(_reloadLoaded());
  }

  Future<void> _reloadLoaded() async {
    try {
      final page = await _repo.list();
      if (!mounted) return;
      final fresh = {for (final session in page.items) session.id};
      setState(() {
        final merged = <SessionSummary>[
          ...page.items,
          for (final session in _loaded)
            if (!fresh.contains(session.id)) session,
        ];
        _loaded
          ..clear()
          ..addAll(merged);
      });
    } on ApiFailure {
      // 列表已经有内容：这一拍对齐失败就等下一次流帧或下拉刷新。
    }
  }

  /// 列表页也订阅实时流：新消息让对应行自己更新，不用下拉刷新。
  void _startStream() {
    final token = widget.connection.token;
    if (token.isEmpty) return;
    final stream = PlatformStream(widget.connection.base, token);
    _stream = stream;
    // 断线退避在 PlatformStream 内部，这里只收帧。
    _streamSub = stream.events.listen(_onBeat, onError: (Object _) {});
  }

  void _onBeat(PlatformEvent event) {
    if (!mounted) return;
    final key = normalizeConversationKey(event.key);
    if (key.isEmpty) return;
    final index = _conversations.indexWhere(
      (conversation) => normalizeConversationKey(conversation.key) == key,
    );
    if (index < 0) {
      // 插件里还没有这个会话（第一条消息刚到）：补一次会话表拿标题等元数据。
      // 这是「新增一行」，不是重排整页——已加载的表与滚动位置都不动。
      _syncConversations();
      // 同一拍也问一次 `/api/sessions`：agent 往往就在这条消息之后被认领，
      // 行上得尽快有 `session`，用户点进去才有信息栏与状态流。
      _syncLoaded();
      return;
    }
    final current = _conversations[index];
    final last = current.last;
    final message = event.message;
    // 重连会回放各会话最近 5 条：比手上的最后一条更早就不改这一行。
    if (last != null && !message.time.isAfter(last.time)) return;
    _conversations[index] = current.copyWith(count: current.count + 1, last: message);
    // 已有会话的新消息同样可能刚把 agent 叫醒：顺手对齐一次已加载表（5s 一次）。
    _syncLoaded();
    // 同一帧内到多帧只重建一次：回放阶段连续 setState 会把手指下的点击也拖慢。
    if (_beatScheduled) return;
    _beatScheduled = true;
    scheduleMicrotask(() {
      _beatScheduled = false;
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadMore() async {
    if (_cursor == null || _loading || _loadingMore) return;
    final requested = _cursor;
    _loadingMore = true;
    try {
      final page = await _repo.list(cursor: requested);
      if (!mounted) return;
      final known = {for (final session in _loaded) session.id};
      final fresh = [
        for (final session in page.items)
          if (!known.contains(session.id)) session,
      ];
      setState(() {
        _loaded.addAll(fresh);
        _cursor = page.nextCursor;
      });
      // 游标没前进又没有新行：服务端不会再给东西了，停手——否则每次重建都会空转一次请求。
      if (fresh.isEmpty && _cursor == requested) _cursor = null;
    } on ApiFailure {
      // 静默停手：这是后台补齐，不该在列表上反复弹错（也避免每次重建都重试）。
      _cursor = null;
    } finally {
      _loadingMore = false;
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// 搜索框从标题位「拉出」：只替换 AppBar 内部内容，列表一行都不让。
  Future<void> _openSearch() async {
    await HapticFeedback.selectionClick();
    if (!mounted || _searching) return;
    setState(() => _searching = true);
  }

  void _exitSearch() {
    // 先收焦点再切换：输入框随动画离场时键盘已经开始收起，不会残留光标。
    FocusScope.of(context).unfocus();
    if (!_searching) return;
    setState(() {
      _searching = false;
      // 退出搜索就清空关键词，回到原来的分组视图。
      _search.clear();
    });
  }

  void _clearSearch() {
    _search.clear();
    setState(() {});
  }

  /// 会话名（插件名与原始 id）、平台、引擎、模型都要能搜到；不区分大小写。
  bool _matches(_SessionRow row, String query) {
    final needle = query.toLowerCase();
    final session = row.session;
    final parsed = parseSessionTitle(row.title);
    final fields = <String>[
      row.title,
      row.key,
      parsed.label,
      parsed.tail ?? '',
      parsed.compact,
      row.conversation?.platform ?? '',
      if (session != null) session.title,
      if (session != null) parseSessionTitle(session.title).compact,
      if (session != null) session.engine,
      if (session?.model case final model?) model.toString(),
    ];
    return fields.any((field) => field.isNotEmpty && field.toLowerCase().contains(needle));
  }

  Future<void> _openSettings() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => _settingsSheet(context, widget.themeMode.value),
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

  Widget _settingsSheet(BuildContext context, ThemeMode mode) {
    final scheme = Theme.of(context).colorScheme;
    return StatefulBuilder(
      builder: (context, setSheetState) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _SheetSectionLabel('外观'),
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
              const _SheetSectionLabel('更新'),
              ListTile(
                leading: const Icon(Icons.system_update_alt),
                title: const Text('检查更新'),
                subtitle: Text('当前 $appVersion'),
                onTap: () => Navigator.pop(context, 'update'),
              ),
              const _SheetSectionLabel('关于'),
              ListTile(
                leading: const Icon(Icons.copy_all_outlined),
                title: const Text('复制诊断信息'),
                subtitle: const Text('版本 / 地址 / 机器人'),
                onTap: () => Navigator.pop(context, 'diag'),
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('关于 ChatLuna'),
                onTap: () => Navigator.pop(context, 'about'),
              ),
              const _SheetSectionLabel('开发者'),
              SwitchListTile(
                secondary: const Icon(Icons.terminal_outlined),
                title: const Text('显示平台/引擎/性能信息'),
                subtitle: const Text('会话头部追加平台、引擎与 debug 计时'),
                value: _showDevInfo,
                onChanged: (value) => _setShowDevInfo(value, setSheetState),
              ),
              const _SheetSectionLabel('危险区'),
              ListTile(
                leading: Icon(Icons.link_off, color: scheme.error),
                title: Text('断开连接', style: TextStyle(color: scheme.error)),
                subtitle: const Text('清除本机保存的 token'),
                onTap: () => Navigator.pop(context, 'disconnect'),
              ),
            ],
          ),
        ),
      ),
    );
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

  Future<void> _open(_SessionRow row) async {
    if (!mounted) return;
    // 立即反馈：手感 + 同步推路由。任何网络请求都放到详情页首帧之后，
    // 点击与可见响应之间不留空白等待。
    unawaited(HapticFeedback.selectionClick());
    await Navigator.of(context).push(
      // 三键导航栏没有系统边缘手势；用 Cupertino 路由把「左缘右滑返回」做进 App。
      CupertinoPageRoute<void>(
        builder: (_) => ChatPage(
          repo: _repo,
          platform: _platform,
          base: widget.connection.base,
          headers: _api.authHeaders,
          // 原样传插件的会话键：`/api/platform/messages` 按它查表，归一化只用于流过滤。
          conversationKey: row.key,
          title: row.title,
          origin: row.conversation?.platform ?? row.session?.origin ?? '',
          session: row.session,
          avatarUrl: _botAvatar,
          botName: _bot?.name,
          showDeveloperInfo: _showDevInfo,
        ),
      ),
    );
    if (!mounted) return;
    // 详情页自己订阅了实时流；回来只补一次会话表元数据（计数/最后一条），不整页刷新。
    // 已加载表也顺手对齐：详情页里会话可能刚被 agent 认领，行上要跟着有绿点与状态。
    unawaited(_syncConversations());
    _syncLoaded(force: true);
  }

  Future<void> _actions(_SessionRow row) async {
    final session = row.session;
    if (session == null) {
      _toast('该会话尚未被 ChatLuna 加载，只能查看消息。');
      return;
    }
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
    return Scaffold(
      appBar: AppBar(
        leading: _archiveOpen
            ? IconButton(
                onPressed: _closeArchive,
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回会话',
              )
            // 列表顶部放 bot 自己的真实头像（`adapters.bots`）：这是「哪个实例在跑」的
            // 唯一身份标识；取不到时就是 AssistantAvatar 的渐变占位。
            : Tooltip(
                message: _bot?.name ?? 'ChatLuna',
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: AssistantAvatar(size: 28, imageUrl: _botAvatar),
                ),
              ),
        // 标题槽在「会话」与搜索框之间横切切换。AppBar 高度只由 toolbarHeight 决定，
        // 两种标题内容都压在 40dp 以内，所以进出搜索不会改变 AppBar 尺寸。
        title: _archiveOpen
            ? const Text('归档')
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.centerLeft,
                  children: [...previous, ?current],
                ),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SizeTransition(
                    sizeFactor: animation,
                    axis: Axis.horizontal,
                    axisAlignment: -1,
                    child: child,
                  ),
                ),
                child: _searching
                    ? _searchField()
                    : const Text('会话', key: ValueKey('title')),
              ),
        actions: _appBarActions(),
      ),
      // 列表直接交给 body：搜索态不再插入额外一行，切换前后位置完全一致。
      body: RefreshIndicator(onRefresh: _refresh, child: _content()),
    );
  }

  List<Widget> _appBarActions() {
    // 归档是只读的历史视图：没有搜索，只能刷新或返回。
    if (_archiveOpen) {
      return [
        IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh), tooltip: '刷新'),
      ];
    }
    if (_searching) {
      return [
        IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh), tooltip: '刷新'),
        IconButton(onPressed: _exitSearch, icon: const Icon(Icons.close), tooltip: '退出搜索'),
      ];
    }
    return [
      IconButton(onPressed: _openSearch, icon: const Icon(Icons.search), tooltip: '搜索'),
      IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh), tooltip: '刷新'),
      IconButton(onPressed: _openSettings, icon: const Icon(Icons.tune), tooltip: '设置'),
    ];
  }

  /// 无边框、透明填充的行内输入框：左侧搜索图标、右侧清除，都是 36dp 热区。
  Widget _searchField() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      key: const ValueKey('search'),
      height: 40,
      child: Row(
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: Icon(Icons.search, size: 20, color: scheme.onSurfaceVariant),
          ),
          Expanded(
            child: TextField(
              controller: _search,
              autofocus: true,
              textInputAction: TextInputAction.search,
              style: theme.textTheme.bodyLarge,
              cursorColor: scheme.primary,
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: Colors.transparent,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: '搜索会话名、引擎或模型',
                hintStyle: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => setState(() {}),
            ),
          ),
          if (_search.text.isNotEmpty)
            SizedBox(
              width: 36,
              height: 36,
              child: IconButton(
                onPressed: _clearSearch,
                padding: EdgeInsets.zero,
                iconSize: 18,
                tooltip: '清除',
                icon: const Icon(Icons.close),
              ),
            ),
        ],
      ),
    );
  }

  /// 列表全集：插件会话在前（每行可能挂着一份已加载会话），已加载但插件里没有的接在后面。
  /// 排序：运行中优先，其后按最后一条消息时间倒序。
  List<_SessionRow> get _rows {
    final loadedByKey = <String, SessionSummary>{};
    for (final session in _loaded) {
      final key = normalizeConversationKey(session.id);
      if (key.isEmpty) continue;
      loadedByKey.putIfAbsent(key, () => session);
    }
    final rows = <_SessionRow>[];
    for (final conversation in _conversations) {
      final key = conversation.key.trim();
      if (key.isEmpty) continue;
      final session = loadedByKey.remove(normalizeConversationKey(key));
      final last = conversation.last;
      rows.add(
        _SessionRow(
          // 原键给 `/api/platform/messages` 用；归一只用于和已加载会话、实时帧比较。
          key: key,
          title: conversation.title.isEmpty ? key : conversation.title,
          subtitle: last?.preview,
          count: conversation.count,
          time: last?.time ?? session?.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
          conversation: conversation,
          session: session,
        ),
      );
    }
    // 已加载但插件里没有的会话照旧列出（标题退回 App 侧的解析规则）。
    for (final session in loadedByKey.values) {
      rows.add(
        _SessionRow(
          key: normalizeConversationKey(session.id),
          title: parseSessionTitle(session.title).compact,
          subtitle: null,
          count: 0,
          time: session.createdAt,
          session: session,
        ),
      );
    }
    rows.sort((a, b) {
      if (a.running != b.running) return a.running ? -1 : 1;
      return b.time.compareTo(a.time);
    });
    return rows;
  }

  /// 一次遍历把行分成「活跃」与「归档」：运行中或最后一条消息在 [activeWindow] 内算活跃。
  /// 时间基准是设备当前时间，每次重建重新算——收到新消息就自动回到主列表。
  (List<_SessionRow>, List<_SessionRow>) _split() {
    final now = DateTime.now();
    final active = <_SessionRow>[];
    final archived = <_SessionRow>[];
    for (final row in _rows) {
      if (row.running || now.difference(row.time) <= activeWindow) {
        active.add(row);
      } else {
        archived.add(row);
      }
    }
    return (active, archived);
  }

  Widget _content() {
    if (_archiveOpen) return _archiveContent();
    final (rows, archived) = _split();
    if (_loading && rows.isEmpty && archived.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rows.isEmpty) {
      if (_error != null) {
        return _StatusView(
          icon: Icons.cloud_off_outlined,
          title: '加载失败',
          message: _error!,
          tinted: true,
          action: FilledButton.tonalIcon(
            onPressed: () => _refresh(),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
          ),
        );
      }
      // 主列表没有活跃会话，但归档里还有：给出明确的归档入口，而不是「暂无会话」。
      if (archived.isNotEmpty) {
        return _StatusView(
          icon: Icons.inbox_outlined,
          title: '最近 ${activeWindow.inDays} 天没有活跃会话',
          message: '更早的 ${archived.length} 个会话已收进归档',
          action: OutlinedButton.icon(
            onPressed: _openArchive,
            icon: const Icon(Icons.inventory_2_outlined, size: 18),
            label: Text('查看归档 · ${archived.length}'),
          ),
        );
      }
      return _StatusView(
        icon: Icons.forum_outlined,
        title: '暂无活跃会话',
        message: '去聊天软件发一条消息，再回来刷新',
        action: OutlinedButton.icon(
          onPressed: () => _refresh(),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('刷新'),
        ),
      );
    }
    final query = _search.text.trim();
    final shown = query.isEmpty ? rows : rows.where((row) => _matches(row, query)).toList();
    if (shown.isEmpty) {
      return _StatusView(
        icon: Icons.search_off,
        title: '没有匹配的会话',
        message: '换个关键词，或清空搜索查看全部活跃会话',
        action: OutlinedButton.icon(
          onPressed: _clearSearch,
          icon: const Icon(Icons.backspace_outlined, size: 18),
          label: const Text('清空搜索'),
        ),
      );
    }
    // 已加载会话是分页取的：列表走到末尾就补下一页，搜索要覆盖全部会话。
    if (_cursor != null) WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
    // 全集已经按「运行中 → 时间」排好，这里只切两段。
    final active = [
      for (final row in shown)
        if (row.running) row,
    ];
    final rest = [
      for (final row in shown)
        if (!row.running) row,
    ];
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      children: [
        if (active.isNotEmpty) ...[
          _SectionHeader(label: '运行中会话', count: active.length, highlighted: true, topPadding: 8),
          for (final row in active) _tile(row),
        ],
        if (rest.isNotEmpty) ...[
          _SectionHeader(
            label: active.isEmpty ? '全部会话' : '其他会话',
            count: rest.length,
            topPadding: active.isEmpty ? 8 : 12,
          ),
          for (final row in rest) _tile(row),
        ],
        // 归档入口固定在列表底部：弱化一行，与「运行中/其他」的分组头区分开。
        if (archived.isNotEmpty) _ArchiveEntry(count: archived.length, onTap: _openArchive),
        SizedBox(height: 72 + MediaQuery.paddingOf(context).bottom),
      ],
    );
  }

  /// 归档子视图：列表样式完全复用会话行，只少了搜索与分组。
  Widget _archiveContent() {
    final (_, rows) = _split();
    if (rows.isEmpty) {
      return _StatusView(
        icon: Icons.inventory_2_outlined,
        title: '归档是空的',
        message: '超过 ${activeWindow.inDays} 天没有新消息的会话会出现在这里',
        action: OutlinedButton.icon(
          onPressed: _closeArchive,
          icon: const Icon(Icons.arrow_back, size: 18),
          label: const Text('返回会话'),
        ),
      );
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      children: [
        _SectionHeader(label: '归档会话', count: rows.length, topPadding: 8),
        for (final row in rows) _tile(row),
        SizedBox(height: 72 + MediaQuery.paddingOf(context).bottom),
      ],
    );
  }

  void _openArchive() {
    FocusScope.of(context).unfocus();
    setState(() {
      _archiveOpen = true;
      _searching = false;
      _search.clear();
    });
  }

  void _closeArchive() {
    if (!_archiveOpen) return;
    setState(() => _archiveOpen = false);
  }

  Widget _tile(_SessionRow row) => _SessionTile(
    // 固定 key：实时帧引起的重排只移动元素，不会把手指下的 InkWell 重建掉。
    key: ValueKey(row.key),
    row: row,
    // 会话头像只代表对方/群：插件给 `conversation.avatar` 就用它（相对路径补成绝对地址），
    // 缺了由 `_SessionTile` 按会话形态退回首字/图标占位——**不回退 bot 头像**
    // （那是助手自己，会把会话认错）。
    avatarUrl: absoluteResourceUrl(widget.connection.base, row.conversation?.avatar),
    onTap: () => _open(row),
    onLongPress: () => _actions(row),
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

/// 列表一行：插件会话（[conversation]）与它可能对应的已加载会话（[session]）。
/// 两者都有 = 已加载；只有 [conversation] = 插件有消息但 ChatLuna 还没加载它。
class _SessionRow {
  const _SessionRow({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.count,
    required this.time,
    this.conversation,
    this.session,
  });

  /// 插件侧的原始会话键：打开详情页时原样传给 `/api/platform/messages`（插件按它查表）。
  /// 与已加载会话、实时帧比较时再走 `normalizeConversationKey`，不要在这里先归一。
  final String key;

  /// 展示名：插件给的 title；已加载但插件里没有的会话用 App 侧的紧凑名。
  final String title;

  /// 最后一条消息的正文（压成一行）；没有消息时为 null。
  final String? subtitle;

  /// 插件统计的消息条数。
  final int count;

  /// 最后一条消息的时间；没有消息时退回已加载会话的创建时间。
  final DateTime time;
  final PlatformConversation? conversation;
  final SessionSummary? session;

  bool get running => session?.running ?? false;

  /// 群聊还是私聊：插件判定（`conversation.kind`）。没有插件会话（只存在于 App 侧）时按私聊处理，
  /// 头像退回首字而不是群组图标。
  bool get isGroup => conversation?.kind == 'group';

  /// 没有最后一条消息时的副标题：已加载会话退回平台/引擎/模型，未加载就没有副标题。
  String? get fallbackSubtitle {
    final session = this.session;
    if (session == null) return null;
    return [
      session.origin,
      if (session.engine.isNotEmpty) session.engine,
      if (session.model != null) session.model!.toString(),
    ].join(' · ');
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.label,
    required this.count,
    this.highlighted = false,
    this.topPadding = 8,
  });

  final String label;
  final int count;
  final bool highlighted;
  final double topPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, topPadding, 12, 8),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              letterSpacing: 1.4,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(
              color: highlighted
                  ? scheme.primary.withValues(alpha: 0.12)
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '$count',
              style: theme.textTheme.labelSmall?.copyWith(
                height: 1.5,
                fontWeight: FontWeight.w600,
                color: highlighted ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 列表底部的归档入口：弱化的一行，和「运行中/其他」的分组头刻意做得不像。
class _ArchiveEntry extends StatelessWidget {
  const _ArchiveEntry({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              Icon(
                Icons.inventory_2_outlined,
                size: 18,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
              ),
              const SizedBox(width: 10),
              Text(
                '归档 · $count',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.9),
                ),
              ),
              const Spacer(),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 会话行：运行中的左侧留 2px 色条，标题最多两行，副标题是最后一条消息。
/// 右侧是最后消息时间与插件的消息计数。
class _SessionTile extends StatelessWidget {
  const _SessionTile({
    super.key,
    required this.row,
    required this.avatarUrl,
    required this.onTap,
    required this.onLongPress,
  });

  static const _runningDot = Color(0xFF22C55E);

  final _SessionRow row;

  /// 会话头像（`conversation.avatar`）：null 或加载失败时按 [row] 的形态退回首字/图标占位。
  final String? avatarUrl;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final subtitle = row.subtitle ?? row.fallbackSubtitle;
    final showTime = row.time.millisecondsSinceEpoch > 0;
    return Stack(
      children: [
        InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                ConversationAvatar(
                  size: 36,
                  imageUrl: avatarUrl,
                  title: row.title,
                  isGroup: row.isGroup,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          height: 1.25,
                          fontWeight: row.running ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                      if (subtitle != null && subtitle.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 88,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (showTime)
                            Flexible(
                              child: Text(
                                _relativeTime(row.time),
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.fade,
                                textAlign: TextAlign.end,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                                ),
                              ),
                            ),
                          if (row.running) ...[
                            const SizedBox(width: 6),
                            Tooltip(
                              message: '运行中',
                              child: Container(
                                width: 16,
                                height: 16,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _runningDot.withValues(alpha: 0.16),
                                ),
                                child: Container(
                                  width: 7,
                                  height: 7,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _runningDot,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (row.count > 0) ...[
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest.withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '${row.count}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              height: 1.4,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (row.running)
          Positioned(
            left: 0,
            top: 12,
            bottom: 12,
            child: Container(
              width: 2,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
      ],
    );
  }
}

/// 空/错误共用的居中状态：一个图标、一句原因、一个动作，垂直居中且可下拉刷新。
class _StatusView extends StatelessWidget {
  const _StatusView({
    required this.icon,
    required this.title,
    required this.message,
    required this.action,
    this.tinted = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget action;
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: tinted
                            ? scheme.errorContainer.withValues(alpha: 0.45)
                            : scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                      ),
                      child: Icon(
                        icon,
                        size: 26,
                        color: tinted ? scheme.onErrorContainer : scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 300),
                      child: Text(
                        message,
                        textAlign: TextAlign.center,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    action,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetSectionLabel extends StatelessWidget {
  const _SheetSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          letterSpacing: 1.4,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
