import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/capability/platform_repository.dart';
import '../../core/capability/platform_stream.dart';
import '../../core/capability/sessions_repository.dart';
import '../../core/design/app_tokens.dart';
import '../../core/model/models.dart';
import '../../core/store/connection_store.dart';
import '../../core/transport/api_client.dart';
import '../../core/transport/state_socket.dart';
import '../../core/update/update_checker.dart';
import '../chat/assistant_avatar.dart';
import '../chat/chat_chrome.dart';
import '../chat/chat_page.dart';
import '../chat/message_view.dart';
import 'session_logic.dart';

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

class _SessionsPageState extends State<SessionsPage> with WidgetsBindingObserver {
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

  /// 401 之后停掉后台表与流，只提示一次「重新连接」。
  bool _authFailed = false;

  /// 列表页是否在栈顶：被详情页盖住时为 false（那时不该再订阅平台流）。
  bool _routeVisible = true;

  /// 已加载表最近一次对齐时间。
  DateTime? _loadedSyncedAt;

  /// 帧驱动的补表间隔：15s 起，连续两拍没有任何变化就翻倍到 60s。
  /// 旧实现是「每帧最多 5s 一次」，静置列表仍每 5s 新建一条 `/api/sessions`
  /// 短 TCP（复测 §7.4 的「偶发第 2 条连接」）。
  Duration _loadedSyncGap = _loadedSyncMinGap;
  static const Duration _loadedSyncMinGap = Duration(seconds: 15);
  static const Duration _loadedSyncMaxGap = Duration(seconds: 60);
  bool _loadedSyncing = false;

  /// 活跃/归档切分的时间基准：挂载时取一次，列表开着期间不随重建漂移。
  late final DateTime _mountedAt;

  /// 主列表滚动控制器：只负责「到底了再补一页」，替代 build 里的 postFrame 回调。
  final ScrollController _scroll = ScrollController();
  bool _loadMoreQueued = false;

  /// 行/分组结果的缓存：`_rows` 要遍历会话并按运行中+时间排序，`_partition` 再切两段。
  /// 会话表或已加载表变了才失效（见 [_invalidateRows]），其余重建直接复用。
  List<SessionRow>? _rowsCache;
  (List<SessionRow>, List<SessionRow>)? _partitionCache;

  /// 前台且在栈顶才算可见：被详情页盖住时断掉平台流（详情页自己订阅了一条）。
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    _mountedAt = DateTime.now();
    _scroll.addListener(_onScroll);
    // 同实例取过一次就直接用，不等 WS 再回一遍；换实例后缓存自动作废。
    _bot = BotIdentity.profileFor(widget.connection.base);
    _botAvatar = BotIdentity.avatarFor(widget.connection.base);
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    // 平台流的启动交给 `didChangeDependencies`（要按路由可见性判断），
    // 它在首帧前一定会跑一次。
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    // `ModalRoute.of` 依赖当前路由的 isCurrent：被详情页盖住 / 返回时都会重走进来。
    _routeVisible = ModalRoute.of(context)?.isCurrent ?? true;
    _ensureStream();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _ensureStream();
    } else {
      // 列表页也订阅实时流：后台广播帧会持续唤醒 isolate 解析 JSON，和详情页一样断流。
      _pauseStream();
      // 排着的「2s 后补一次会话表」也不该在后台发出去。
      _syncTimer?.cancel();
      _syncTimer = null;
    }
  }

  /// 只在「前台 + 栈顶」订阅平台流：
  /// - 被详情页盖住时列表不需要实时帧（详情页自己订阅了一条），多一条常驻连接
  ///   就是服务端与手机各多一份开销——实测详情页 3 条里的第三条就是它；
  /// - 回到列表时重建流，`PlatformStream` 会重放每个会话最近几条，行状态随之补齐
  ///   （`_open` 返回时还会补一次会话表元数据）。
  void _ensureStream() {
    if (!_foreground || !_routeVisible || _authFailed) {
      _pauseStream();
      return;
    }
    _startStream();
  }

  void _pauseStream() {
    _streamSub?.cancel();
    _streamSub = null;
    _stream?.dispose();
    _stream = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncTimer?.cancel();
    _streamSub?.cancel();
    _stream?.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
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
        _invalidateRows();
      });
      // 全量对齐之后算一次「刚同步过」，避免紧接着的流帧再补一遍会话表。
      _syncedAt = DateTime.now();
      _loadedSyncedAt = DateTime.now();
      _loadedSyncGap = _loadedSyncMinGap;
    } on ApiFailure catch (e) {
      if (e.isUnauthorized) {
        _handleAuthFailure();
        return;
      }
      if (mounted) setState(() => _error = _displayFailure(e));
    } catch (_) {
      if (mounted) setState(() => _error = '加载失败，请稍后重试');
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
      setState(() {
        _conversations
          ..clear()
          ..addAll(conversations);
        _invalidateRows();
      });
    } on ApiFailure catch (e) {
      // 列表已经有内容：这一拍补齐失败就等下一页/下拉刷新，不弹错；401 例外。
      if (e.isUnauthorized) _handleAuthFailure();
    } catch (_) {
      // 坏字段只影响这一拍。
    } finally {
      _syncing = false;
    }
  }

  /// `/api/sessions` 对齐：QQ 里发一条消息 → 服务端建会话 → agent 认领，
  /// 认领后行上才有 `session`（绿点、状态、操作菜单、进详情的 `/live`）。
  ///
  /// **只在真的需要时请求**：调用方用 [needed] 判断这一拍有没有可能改变列表
  /// （行还没挂 `session`、行在跑、对方刚发来消息）。机器人回复且状态早已静止的
  /// 帧不发请求，空闲列表因此没有任何轮询。
  ///
  /// 限流：最快 [_loadedSyncMinGap] 一次；连续两拍没有任何行变化就 2× 退避到
  /// [_loadedSyncMaxGap]，一有变化立刻回到 15s。[force] 只给「用户刚返回列表」
  /// 这种一次性动作，不参与退避。
  void _syncLoaded({bool force = false, bool needed = true}) {
    if (!force && !needed) return;
    if (_loadedSyncing) return;
    final now = DateTime.now();
    final last = _loadedSyncedAt;
    if (!force && last != null && now.difference(last) < _loadedSyncGap) return;
    _loadedSyncedAt = now;
    _loadedSyncing = true;
    unawaited(_reloadLoaded().then((changed) {
      if (changed) {
        _loadedSyncGap = _loadedSyncMinGap;
      } else if (_loadedSyncGap < _loadedSyncMaxGap) {
        _loadedSyncGap = _loadedSyncGap * 2;
      }
    }).whenComplete(() => _loadedSyncing = false));
  }

  /// 重取第一页并与手上的表合并；返回「是否有行发生了变化」。
  Future<bool> _reloadLoaded() async {
    final before = _loadedSignature();
    try {
      final page = await _repo.list();
      if (!mounted) return false;
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
        _invalidateRows();
      });
      return _loadedSignature() != before;
    } on ApiFailure catch (e) {
      // 列表已经有内容：这一拍对齐失败就等下一次流帧或下拉刷新；401 例外。
      if (e.isUnauthorized) _handleAuthFailure();
    } catch (_) {
      // 坏字段只影响这一拍。
    }
    return false;
  }

  /// 这个（归一化后的）会话键挂到的已加载会话；没有就是 null。
  SessionSummary? _sessionFor(String normalizedKey) {
    for (final session in _loaded) {
      if (normalizeConversationKey(session.id) == normalizedKey) return session;
    }
    return null;
  }

  /// 行状态的指纹：有哪些已加载会话 + 各自是否在跑。用它判断补表有没有带来变化。
  String _loadedSignature() {
    final items = [
      for (final session in _loaded) '${session.id}:${session.running ? 1 : 0}',
    ]..sort();
    return items.join(',');
  }

  /// 列表页也订阅实时流：新消息让对应行自己更新，不用下拉刷新。
  void _startStream() {
    if (_authFailed || _streamSub != null) return;
    // 后台或被详情页盖住时不连：详情页自己有一条，列表不需要第二条常驻连接。
    if (!_foreground || !_routeVisible) return;
    final token = widget.connection.token;
    if (token.isEmpty) return;
    final stream = PlatformStream(widget.connection.base, token);
    _stream = stream;
    // 断线退避在 PlatformStream 内部；401 会以错误送上来。
    _streamSub = stream.events.listen(_onBeat, onError: (Object error) {
      _streamSub = null;
      if (error is ApiFailure && error.isUnauthorized) _handleAuthFailure();
    });
  }

  /// 401：停表、停流，只提示一次。凭证不会自己恢复，继续重试只会一直打服务端。
  void _handleAuthFailure() {
    if (_authFailed) return;
    _authFailed = true;
    _syncTimer?.cancel();
    _syncTimer = null;
    _streamSub?.cancel();
    _streamSub = null;
    _stream?.dispose();
    _stream = null;
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('登录已失效'),
        content: const Text('实例的访问 token 已失效。重新连接并输入新的 token 后才能继续。'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              unawaited(widget.onDisconnect());
            },
            child: const Text('重新连接'),
          ),
        ],
      ),
    );
  }

  /// 错误页/HTML 正文不进 UI：只给稳定的短文案。
  static String _displayFailure(ApiFailure failure) {
    final message = failure.message;
    final looksLikePage =
        message.contains('<') || message.contains('\n') || message.length > 160;
    if (looksLikePage) {
      final status = failure.status == null ? '' : '（HTTP ${failure.status}）';
      return '${failure.code}：服务器返回了错误$status';
    }
    return '${failure.code}：$message';
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
    _invalidateRows();
    // 已有会话的新消息：不每帧补表（旧实现是 5s 一次，静置列表也在轮询）。
    // 只有「这一条可能改变行的状态」时才问：
    // - 还没被 agent 认领（`session == null`，等绿点/状态/进详情的能力）；
    // - 行在跑，这条可能就是这一轮的最后一条（`running` 要跟着变 false）；
    // - 对方刚发来消息，agent 可能刚刚被叫醒（我们手上还是 running=false）。
    // 其余情况一个请求都不发：空闲列表零轮询。
    final session = _sessionFor(key);
    _syncLoaded(needed: session == null || session.running || !message.outbound);
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
        _invalidateRows();
      });
      // 游标没前进又没有新行：服务端不会再给东西了，停手——否则每次重建都会空转一次请求。
      if (fresh.isEmpty && _cursor == requested) _cursor = null;
    } on ApiFailure catch (e) {
      // 静默停手：这是后台补齐，不该在列表上反复弹错（也避免每次重建都重试）。
      if (e.isUnauthorized) _handleAuthFailure();
      _cursor = null;
    } catch (_) {
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
  bool _matches(SessionRow row, String query) {
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

  Future<void> _open(SessionRow row) async {
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
          // 详情页拿到 401 时先退回列表，再由根节点清凭证切到连接页。
          onAuthExpired: widget.onDisconnect,
        ),
      ),
    );
    if (!mounted) return;
    // 详情页自己订阅了实时流；回来只补一次会话表元数据（计数/最后一条），不整页刷新。
    // 已加载表也顺手对齐：详情页里会话可能刚被 agent 认领，行上要跟着有绿点与状态。
    unawaited(_syncConversations());
    _syncLoaded(force: true);
  }

  Future<void> _actions(SessionRow row) async {
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
              title: const Text('从本地移除'),
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
      } catch (_) {
        _toast('改名失败');
      }
    } else if (action == 'delete') {
      await HapticFeedback.mediumImpact();
      try {
        await _repo.delete(session.id);
        await _refresh();
        _toast('已从本地移除；平台历史未删除，刷新后可能重新出现');
      } on ApiFailure catch (e) {
        _toast('移除失败 ${e.code}');
      } catch (_) {
        _toast('移除失败');
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
  List<SessionRow> get _rows {
    final cached = _rowsCache;
    if (cached != null) return cached;
    final loadedByKey = <String, SessionSummary>{};
    for (final session in _loaded) {
      final key = normalizeConversationKey(session.id);
      if (key.isEmpty) continue;
      loadedByKey.putIfAbsent(key, () => session);
    }
    final rows = <SessionRow>[];
    for (final conversation in _conversations) {
      final key = conversation.key.trim();
      if (key.isEmpty) continue;
      final session = loadedByKey.remove(normalizeConversationKey(key));
      final last = conversation.last;
      rows.add(
        SessionRow(
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
        SessionRow(
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
    _rowsCache = rows;
    return rows;
  }

  /// 会话表/已加载表变了：行与分组都要重算。其余重建（搜索输入、主题、流帧合并）
  /// 直接复用缓存，不再每次 build 遍历 + 排序 + 切两段。
  void _invalidateRows() {
    _rowsCache = null;
    _partitionCache = null;
  }

  /// 一次遍历把行分成「活跃」与「归档」：运行中或最后一条消息在 [activeWindow] 内算活跃。
  /// 时间基准是挂载快照，列表开着期间不会因为流帧重建而漂移。
  (List<SessionRow>, List<SessionRow>) _partition() {
    final cached = _partitionCache;
    if (cached != null) return cached;
    return _partitionCache = partitionSessions(_rows, now: _mountedAt);
  }

  /// 滚动到底附近补一页已加载会话（搜索要覆盖全部会话，所以搜索时由 build 侧踢一脚）。
  void _onScroll() {
    if (_archiveOpen || !_scroll.hasClients) return;
    if (_scroll.position.extentAfter > 480) return;
    if (_cursor == null || _loadingMore) return;
    unawaited(_loadMore());
  }

  /// 排一帧补页（同一时刻只排一次）：搜索态结果不足一屏时使用。
  void _kickLoadMore() {
    if (_loadMoreQueued || _cursor == null) return;
    _loadMoreQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadMoreQueued = false;
      if (!mounted) return;
      unawaited(_loadMore());
    });
  }

  Widget _content() {
    if (_archiveOpen) return _archiveContent();
    final (rows, archived) = _partition();
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
          actionLabel: '重试',
          actionIcon: Icons.refresh,
          filled: true,
          onAction: _refresh,
        );
      }
      // 主列表没有活跃会话，但归档里还有：给出明确的归档入口，而不是「暂无会话」。
      if (archived.isNotEmpty) {
        return _StatusView(
          icon: Icons.inbox_outlined,
          title: '最近 ${activeWindow.inDays} 天没有活跃会话',
          message: '更早的 ${archived.length} 个会话已收进归档',
          actionLabel: '查看归档 · ${archived.length}',
          actionIcon: Icons.inventory_2_outlined,
          onAction: _openArchive,
        );
      }
      return _StatusView(
        icon: Icons.forum_outlined,
        title: '暂无活跃会话',
        message: '去聊天软件发一条消息，再回来刷新',
        actionLabel: '刷新',
        actionIcon: Icons.refresh,
        onAction: _refresh,
      );
    }
    final query = _search.text.trim();
    final shown = query.isEmpty ? rows : rows.where((row) => _matches(row, query)).toList();
    if (shown.isEmpty) {
      return _StatusView(
        icon: Icons.search_off,
        title: '没有匹配的会话',
        message: '换个关键词，或清空搜索查看全部活跃会话',
        actionLabel: '清空搜索',
        actionIcon: Icons.backspace_outlined,
        onAction: _clearSearch,
      );
    }
    // 已加载会话是分页取的：搜索态结果不足一屏时排一帧补页（滚动补页见 [_onScroll]）。
    if (query.isNotEmpty) _kickLoadMore();
    // 全集已经按「运行中 → 时间」排好，这里只切两段。
    final active = [
      for (final row in shown)
        if (row.running) row,
    ];
    final rest = [
      for (final row in shown)
        if (!row.running) row,
    ];
    // 时间标签一次算好传给每行：滚动时不会为每一行重新读设备时钟。
    final now = DateTime.now();
    final entries = <_SessionEntry>[
      if (active.isNotEmpty) ...[
        _HeaderEntry('运行中会话', active.length, highlighted: true, topPadding: 8),
        for (final row in active) _RowEntry(row),
      ],
      if (rest.isNotEmpty) ...[
        _HeaderEntry(
          active.isEmpty ? '全部会话' : '其他会话',
          rest.length,
          topPadding: active.isEmpty ? 8 : 12,
        ),
        for (final row in rest) _RowEntry(row),
      ],
      // 归档入口固定在列表底部：弱化一行，与「运行中/其他」的分组头区分开。
      if (archived.isNotEmpty) _ArchiveEntryRow(archived.length),
      _GapEntry(72 + MediaQuery.paddingOf(context).bottom),
    ];
    // 只按可见范围构建：会话数 50+ 时首帧与每次刷新不再一次性搭出全部行
    // （头像解码、时间格式、Material/InkWell 都在 itemBuilder 里发生）。
    return ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 4),
      itemCount: entries.length,
      itemBuilder: (context, index) => switch (entries[index]) {
        _HeaderEntry(:final label, :final count, :final highlighted, :final topPadding) =>
          _SectionHeader(
            label: label,
            count: count,
            highlighted: highlighted,
            topPadding: topPadding,
          ),
        _RowEntry(:final row) => _tile(row, now),
        _ArchiveEntryRow(:final count) => _ArchiveEntry(count: count, onTap: _openArchive),
        _GapEntry(:final height) => SizedBox(height: height),
      },
    );
  }

  /// 归档子视图：列表样式完全复用会话行，只少了搜索与分组。
  Widget _archiveContent() {
    final (_, rows) = _partition();
    if (rows.isEmpty) {
      return _StatusView(
        icon: Icons.inventory_2_outlined,
        title: '归档是空的',
        message: '超过 ${activeWindow.inDays} 天没有新消息的会话会出现在这里',
        actionLabel: '返回会话',
        actionIcon: Icons.arrow_back,
        onAction: _closeArchive,
      );
    }
    final now = DateTime.now();
    final entries = <_SessionEntry>[
      _HeaderEntry('归档会话', rows.length, topPadding: 8),
      for (final row in rows) _RowEntry(row),
      _GapEntry(72 + MediaQuery.paddingOf(context).bottom),
    ];
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 4),
      itemCount: entries.length,
      itemBuilder: (context, index) => switch (entries[index]) {
        _HeaderEntry(:final label, :final count, :final highlighted, :final topPadding) =>
          _SectionHeader(
            label: label,
            count: count,
            highlighted: highlighted,
            topPadding: topPadding,
          ),
        _RowEntry(:final row) => _tile(row, now),
        _ArchiveEntryRow(:final count) => _ArchiveEntry(count: count, onTap: _openArchive),
        _GapEntry(:final height) => SizedBox(height: height),
      },
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

  Widget _tile(SessionRow row, DateTime now) => _SessionTile(
    // 固定 key：实时帧引起的重排只移动元素，不会把手指下的 InkWell 重建掉。
    key: ValueKey(row.key),
    row: row,
    now: now,
    // 会话头像只代表对方/群：插件给 `conversation.avatar` 就用它（相对路径补成绝对地址），
    // 缺了由 `_SessionTile` 按会话形态退回首字/图标占位——**不回退 bot 头像**
    // （那是助手自己，会把会话认错）。
    avatarUrl: absoluteResourceUrl(widget.connection.base, row.conversation?.avatar),
    onTap: () => _open(row),
    onLongPress: () => _actions(row),
  );
}

String _relativeTime(DateTime time, DateTime now) {
  final day = DateTime(time.year, time.month, time.day);
  final today = DateTime(now.year, now.month, now.day);
  final hm = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  if (day == today) return '今天 $hm';
  if (today.difference(day).inDays == 1) return '昨天 $hm';
  return '${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} $hm';
}

/// 虚拟化列表的一项：分组头 / 会话行 / 归档入口 / 底部留白。
/// 只描述「是什么」，对应的 Widget 由 `ListView.builder` 按可见性构建。
sealed class _SessionEntry {
  const _SessionEntry();
}

class _HeaderEntry extends _SessionEntry {
  const _HeaderEntry(
    this.label,
    this.count, {
    this.highlighted = false,
    this.topPadding = 8,
  });

  final String label;
  final int count;
  final bool highlighted;
  final double topPadding;
}

class _RowEntry extends _SessionEntry {
  const _RowEntry(this.row);

  final SessionRow row;
}

class _ArchiveEntryRow extends _SessionEntry {
  const _ArchiveEntryRow(this.count);

  final int count;
}

class _GapEntry extends _SessionEntry {
  const _GapEntry(this.height);

  final double height;
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
      padding: EdgeInsets.fromLTRB(20, topPadding, 20, 8),
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
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.tile),
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

/// 会话行：8dp 外边距的独立卡片；运行中时铺 `surface_l1`，左缘一条 `statusRunning` 竖条。
/// 右侧是最后消息时间、运行灯（未加载不画）与未读计数。
class _SessionTile extends StatelessWidget {
  const _SessionTile({
    super.key,
    required this.row,
    required this.now,
    required this.avatarUrl,
    required this.onTap,
    required this.onLongPress,
  });

  final SessionRow row;

  /// 时间标签的基准：列表一次算好传给每行，滚动时不会逐行读设备时钟。
  final DateTime now;

  /// 会话头像（`conversation.avatar`）：null 或加载失败时按 [row] 的形态退回首字/图标占位。
  final String? avatarUrl;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final subtitle = row.subtitle ?? row.fallbackSubtitle;
    final showTime = row.time.millisecondsSinceEpoch > 0;
    final previewStyle = TextStyle(
      fontSize: 12,
      height: 16 / 12,
      letterSpacing: 0.2,
      color: colors.textSecondary,
    );
    final captionStyle = TextStyle(
      fontSize: 11,
      height: 14 / 11,
      letterSpacing: 0.3,
      fontWeight: FontWeight.w500,
      fontFeatures: const [FontFeature.tabularFigures()],
      color: colors.textTertiary,
    );
    return Padding(
      // 卡片之间留出 8/2 的外边距：列表背景上是一行行独立卡片，而不是无缝长条。
      padding: const EdgeInsets.symmetric(horizontal: Space.x8, vertical: Space.x2),
      child: Material(
        // 运行中的行浮一层 surface_l1；普通行透明，与画布融为一体。
        color: row.running ? colors.surfaceL1 : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.tile),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              highlightColor: colors.surfaceL3,
              splashColor: colors.surfaceL3,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.x12, vertical: 10),
                child: Row(
                  children: [
                    ConversationAvatar(
                      size: 40,
                      imageUrl: avatarUrl,
                      title: row.title,
                      isGroup: row.isGroup,
                    ),
                    const SizedBox(width: Space.x8),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            row.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                              color: colors.textPrimary,
                            ),
                          ),
                          if (row.unloaded) ...[
                            const SizedBox(height: Space.x4),
                            Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '未加载',
                                    style: TextStyle(color: colors.textTertiary),
                                  ),
                                  if (subtitle != null && subtitle.isNotEmpty)
                                    TextSpan(text: ' · $subtitle'),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: previewStyle,
                            ),
                          ] else if (subtitle != null && subtitle.isNotEmpty) ...[
                            const SizedBox(height: Space.x4),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: previewStyle,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: Space.x12),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (showTime)
                              Text(
                                _relativeTime(row.time, now),
                                maxLines: 1,
                                softWrap: false,
                                textAlign: TextAlign.end,
                                style: captionStyle,
                              ),
                            // 未加载的会话不可能在跑：不画状态点，避免一个假绿点。
                            if (row.running && !row.unloaded) ...[
                              const SizedBox(width: 6),
                              Tooltip(
                                message: '运行中',
                                child: Container(
                                  width: 16,
                                  height: 16,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: colors.statusRunning.withValues(alpha: 0.16),
                                  ),
                                  child: Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: colors.statusRunning,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (row.count > 0) ...[
                          const SizedBox(height: Space.x4),
                          Container(
                            height: 18,
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: colors.surfaceL3,
                              borderRadius: BorderRadius.circular(Radii.pill),
                            ),
                            child: Text(
                              '${row.count}',
                              style: captionStyle.copyWith(color: colors.textSecondary),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
            // 竖条与右侧运行灯同色：都取 statusRunning，不再和主色打架。
            if (row.running)
              Positioned(
                left: 0,
                top: 18,
                bottom: 18,
                child: Container(
                  width: 3,
                  decoration: BoxDecoration(
                    color: colors.statusRunning,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 空/错误共用的居中状态：56dp 圆底座、一句原因、一个 36dp 动作，垂直居中且可下拉刷新。
class _StatusView extends StatelessWidget {
  const _StatusView({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.actionIcon,
    required this.onAction,
    this.tinted = false,
    this.filled = false,
  });

  final IconData icon;
  final String title;
  final String message;

  /// 动作按钮：36dp 高、8dp 圆角、16dp 图标，错误态用 tonal 实心以突出重试。
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback onAction;

  /// 错误态：图标换成 statusError，动作按钮用 tonal 变体。
  final bool tinted;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final textStyle = const TextStyle(fontSize: 13, fontWeight: FontWeight.w500);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.tile));
    const padding = EdgeInsets.symmetric(horizontal: Space.x16);
    final iconWidget = Icon(actionIcon, size: 16);
    final label = Text(actionLabel);
    final action = filled
        ? FilledButton.tonalIcon(
            onPressed: onAction,
            icon: iconWidget,
            label: label,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 36),
              padding: padding,
              shape: shape,
              textStyle: textStyle,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          )
        : OutlinedButton.icon(
            onPressed: onAction,
            icon: iconWidget,
            label: label,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 36),
              padding: padding,
              shape: shape,
              textStyle: textStyle,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          );
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: Space.x20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colors.surfaceL2,
                      ),
                      child: Icon(
                        icon,
                        size: 28,
                        color: tinted ? colors.statusError : colors.textTertiary,
                      ),
                    ),
                    const SizedBox(height: Space.x16),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        height: 22 / 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: Space.x8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 300),
                      child: Text(
                        message,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          letterSpacing: 0.2,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(height: Space.x20),
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
