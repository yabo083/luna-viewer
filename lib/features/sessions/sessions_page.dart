import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/capability/sessions_repository.dart';
import '../../core/capability/traffic_repository.dart';
import '../../core/capability/traffic_stream.dart';
import '../../core/model/models.dart';
import '../../core/store/connection_store.dart';
import '../../core/transport/api_client.dart';
import '../../core/transport/state_socket.dart';
import '../../core/update/update_checker.dart';
import '../chat/assistant_avatar.dart';
import '../chat/chat_chrome.dart';
import '../chat/chat_page.dart';
import '../traffic/traffic_page.dart';

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
  final TextEditingController _search = TextEditingController();

  /// 仅流量会话的原料：归一会话键 → 该会话最新的一条流量记录。
  /// `/api/sessions` 里没有的会话靠它合成一行；已加载的会话永远优先。
  final Map<String, TrafficEntry> _seeds = {};

  /// 列表页自己也订阅一次旁路流：新会话的第一条消息不用等下拉刷新就能出现。
  TrafficStream? _trafficStream;
  StreamSubscription<TrafficEntry>? _trafficSub;

  /// 种子表上限：服务端是内存环形缓冲，这里只留最近活跃的一批。
  static const _seedLimit = 200;

  bool _searching = false;
  BotProfile? _bot;
  bool _loading = true;
  String? _error;
  String? _cursor;
  bool _showDevInfo = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _startTrafficWatch();
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
    _trafficSub?.cancel();
    _trafficStream?.dispose();
    _search.dispose();
    _api.close();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 两条路并行：`/api/sessions` 给已加载会话，`/api/traffic` 给「有消息但还没加载」的会话。
      // 后者自己吞错返回空表，所以先 await 前者：ApiFailure 原样抛给下面的分支。
      final listing = _repo.list();
      final snapshot = _trafficSnapshot();
      final page = await listing;
      final traffic = await snapshot;
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _cursor = page.nextCursor;
        _seeds
          ..clear()
          ..addAll(_groupSeeds(traffic));
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
    // WS 取头像可能被网络抢先失败，刷新时补一次。
    if (_bot == null) _loadBot();
  }

  /// 一次拉 200 条旁路记录（服务端是内存环形缓冲，200 条覆盖最近的活跃会话）。
  /// 端点不可用（旧实例）时返回空表：列表退化成纯 `/api/sessions`，不报错。
  Future<List<TrafficEntry>> _trafficSnapshot() async {
    try {
      return await TrafficRepository(_api).list(limit: 200);
    } catch (_) {
      return const [];
    }
  }

  /// 按归一会话键分组，每组只留最后一条（标题与时间都取它）。
  static Map<String, TrafficEntry> _groupSeeds(List<TrafficEntry> entries) {
    final seeds = <String, TrafficEntry>{};
    for (final entry in entries) {
      final key = trafficConversationKey(entry);
      if (key.isEmpty) continue;
      final prev = seeds[key];
      if (prev == null || entry.time.isAfter(prev.time)) seeds[key] = entry;
    }
    return seeds;
  }

  /// 仅流量会话：`/api/sessions` 里没有、但有入站消息的会话。
  /// 已经被某个已加载会话覆盖的种子直接丢掉——同一会话不能出现两行：
  /// 归一键相同（新插件）或频道 id 出现在该会话标题里（旧插件）都算覆盖。
  List<SessionSummary> get _derivedSessions {
    final loaded = {for (final item in _items) normalizeConversationKey(item.id)};
    final loadedIds = {
      for (final item in _items) ...candidateIdsOf(item.title),
    };
    final derived = <SessionSummary>[];
    for (final entry in _seeds.values) {
      final key = trafficConversationKey(entry);
      if (key.isEmpty || loaded.contains(key)) continue;
      if (_coveredByTitle(loadedIds, entry)) continue;
      derived.add(
        SessionSummary(
          // 用 `route:` 前缀：详情页原样归一回来，就能和流量条目对上同一把键。
          id: 'route:$key',
          title: entry.channelLabel,
          createdAt: entry.time,
          origin: 'satori',
          engine: '',
          running: false,
          trafficOnly: true,
        ),
      );
    }
    derived.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return derived;
  }

  /// 频道 / 群号出现在某个已加载会话的标题里：那是同一个会话（旧插件没有会话键）。
  static bool _coveredByTitle(Set<String> ids, TrafficEntry entry) {
    if (ids.isEmpty) return false;
    for (final value in <String?>[entry.channelId, entry.guildId]) {
      if (value == null || value.isEmpty) continue;
      if (ids.contains(value.toLowerCase())) return true;
    }
    return false;
  }

  /// 列表页也订阅旁路流：会话还没被 ChatLuna 加载时，第一条消息就能让这一行出现。
  /// 平时它在，打开详情页会额外再开一条（列表不能因为跳转而停止更新）；
  /// 断线退避与 404 退化都在 [TrafficStream] 内部，这里只收消息。
  void _startTrafficWatch() {
    final token = widget.connection.token;
    if (token.isEmpty) return;
    final stream = TrafficStream(widget.connection.base, token);
    _trafficStream = stream;
    _trafficSub = stream.entries.listen(_onTrafficEntry, onError: (Object _) {});
  }

  void _onTrafficEntry(TrafficEntry entry) {
    if (!mounted) return;
    final key = trafficConversationKey(entry);
    if (key.isEmpty) return;
    // 已加载的会话本来就在列表里：标题与顺序归服务端，不再种种子。
    if (_items.any((item) => normalizeConversationKey(item.id) == key)) return;
    if (_coveredByTitle({for (final item in _items) ...candidateIdsOf(item.title)}, entry)) {
      return;
    }
    final prev = _seeds[key];
    if (prev != null && !entry.time.isAfter(prev.time)) return;
    setState(() {
      _seeds[key] = entry;
      if (_seeds.length > _seedLimit) {
        final oldest = _seeds.entries.reduce(
          (a, b) => a.value.time.isBefore(b.value.time) ? a : b,
        );
        _seeds.remove(oldest.key);
      }
    });
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

  /// 标题（紧凑名与原始名）、引擎、模型都要能搜到；不区分大小写。
  bool _matches(SessionSummary session, String query) {
    final needle = query.toLowerCase();
    final title = parseSessionTitle(session.title);
    final fields = <String>[
      session.title,
      title.label,
      title.tail ?? '',
      title.compact,
      session.engine,
      session.model?.toString() ?? '',
    ];
    return fields.any((field) => field.toLowerCase().contains(needle));
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
      case 'traffic':
        if (!mounted) return;
        await Navigator.of(context).push(
          CupertinoPageRoute<void>(
            builder: (_) => TrafficPage(
              repo: TrafficRepository(_api),
              onUnauthorized: widget.onDisconnect,
            ),
          ),
        );
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
              const _SheetSectionLabel('记录'),
              ListTile(
                leading: const Icon(Icons.receipt_long_outlined),
                title: const Text('消息记录'),
                subtitle: const Text('指令等未进入会话的入站消息'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(context, 'traffic'),
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

  Future<void> _open(SessionSummary session) async {
    // 先把历史取回来再推路由：详情页第一帧就有内容，不会出现「空白/残影」再加载的过程。
    // 仅流量会话不在服务端，取历史只会拿到 404：交给详情页自己判「仅实时」模式。
    Transcript? initial;
    if (!session.trafficOnly) {
      try {
        initial = await _repo.transcript(session.id);
      } on ApiFailure catch (e) {
        // 404 说明会话已不在服务端（还没加载 / 已卸载）：详情页会退化成仅实时模式，
        // 这里不该弹一条错误。
        if (e.code != 'NOT_FOUND' && e.status != 404) _toast('${e.code}：${e.message}');
      }
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
          showDeveloperInfo: _showDevInfo,
        ),
      ),
    );
    await _refresh();
  }

  Future<void> _actions(SessionSummary session) async {
    if (session.trafficOnly) {
      _toast('该会话尚未被 ChatLuna 加载，只能查看实时消息。');
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
        // 标题槽在「会话」与搜索框之间横切切换。AppBar 高度只由 toolbarHeight 决定，
        // 两种标题内容都压在 40dp 以内，所以进出搜索不会改变 AppBar 尺寸。
        title: AnimatedSwitcher(
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
          child: _searching ? _searchField() : const Text('会话', key: ValueKey('title')),
        ),
        actions: _appBarActions(),
      ),
      // 列表直接交给 body：搜索态不再插入额外一行，切换前后位置完全一致。
      body: RefreshIndicator(onRefresh: _refresh, child: _content()),
    );
  }

  List<Widget> _appBarActions() {
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

  /// 列表页看到的全集：已加载会话在前（服务端顺序），仅流量会话按最后消息时间倒序接在后面。
  List<SessionSummary> get _visible => [..._items, ..._derivedSessions];

  Widget _content() {
    final sessions = _visible;
    if (_loading && sessions.isEmpty) return const Center(child: CircularProgressIndicator());
    if (sessions.isEmpty) {
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
    if (query.isNotEmpty) {
      final matches = sessions.where((item) => _matches(item, query)).toList();
      if (matches.isEmpty) {
        return _StatusView(
          icon: Icons.search_off,
          title: '没有匹配的会话',
          message: '换个关键词，或清空搜索查看全部会话',
          action: OutlinedButton.icon(
            onPressed: _clearSearch,
            icon: const Icon(Icons.backspace_outlined, size: 18),
            label: const Text('清空搜索'),
          ),
        );
      }
      // 搜索要覆盖全部会话，所以和普通视图一样继续翻页。
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
        children: [
          for (final session in matches) _tile(session),
          SizedBox(height: 72 + MediaQuery.paddingOf(context).bottom),
        ],
      );
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      children: [
        for (final row in _rows()) row,
        SizedBox(height: 72 + MediaQuery.paddingOf(context).bottom),
      ],
    );
  }

  /// 分组顺序：运行中 → 其他已加载（服务端时间序）→ 仅流量会话（最后消息时间倒序）。
  /// 全集本身已经是这个顺序，这里只按 `running` 切两段，不再重排。
  List<Widget> _rows() {
    final sessions = _visible;
    final active = sessions.where((item) => item.running).toList();
    final rest = sessions.where((item) => !item.running).toList();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
    return [
      if (active.isNotEmpty) ...[
        _SectionHeader(label: '运行中会话', count: active.length, highlighted: true, topPadding: 8),
        for (final session in active) _tile(session),
      ],
      if (rest.isNotEmpty) ...[
        _SectionHeader(
          label: active.isEmpty ? '全部活跃会话' : '其他会话',
          count: rest.length,
          topPadding: active.isEmpty ? 8 : 12,
        ),
        for (final session in rest) _tile(session),
      ],
    ];
  }

  Widget _tile(SessionSummary session) => _SessionTile(
    session: session,
    avatarUrl: _bot?.avatar,
    onTap: () => _open(session),
    onLongPress: () => _actions(session),
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

/// 会话行：运行中的左侧留 2px 色条，标题最多两行，时间用更弱的一级字重。
class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.avatarUrl,
    required this.onTap,
    required this.onLongPress,
  });

  static const _runningDot = Color(0xFF22C55E);

  final SessionSummary session;
  final String? avatarUrl;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final detail = [
      session.origin,
      if (session.engine.isNotEmpty) session.engine,
      if (session.model != null) session.model!.toString(),
      // 仅流量会话：服务端还没加载它，只有实时消息可看。
      if (session.trafficOnly) '未加载',
    ].join(' · ');
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
                AssistantAvatar(size: 36, imageUrl: avatarUrl),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        parseSessionTitle(session.title).compact,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          height: 1.25,
                          fontWeight: session.running ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 92,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Flexible(
                        child: Text(
                          _relativeTime(session.createdAt),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.fade,
                          textAlign: TextAlign.end,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                      if (session.running) ...[
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
                ),
              ],
            ),
          ),
        ),
        if (session.running)
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
