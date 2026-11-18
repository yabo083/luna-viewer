import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/capability/traffic_repository.dart';
import '../../core/model/models.dart';

/// 消息记录：实例收到的全部入站消息。
/// 指令（如 `chatluna-菜单`）在服务端指令层被吃掉，不进会话日志，只有在会话列表里
/// 永远看不到的那批消息才需要这一页。
class TrafficPage extends StatefulWidget {
  const TrafficPage({super.key, required this.repo, this.onUnauthorized});

  final TrafficRepository repo;

  /// token 失效时交给上层（断开连接、回连接页）。
  final Future<void> Function()? onUnauthorized;

  @override
  State<TrafficPage> createState() => _TrafficPageState();
}

class _TrafficPageState extends State<TrafficPage> {
  final List<TrafficEntry> _items = [];
  final Set<String> _platforms = {};
  final TextEditingController _channel = TextEditingController();
  String? _platform;
  String? _appliedChannel;
  Timer? _debounce;
  int _request = 0;
  bool _loading = true;
  String? _error;

  /// 分组展开状态：键是 `平台 + 频道`。刷新时保留用户手动收起/展开的选择。
  final Map<String, bool> _expanded = {};
  List<_TrafficGroup> _groups = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _channel.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // 筛选/刷新会并发发请求，只认最后一次的返回，避免旧结果盖掉新筛选。
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.repo.list(platform: _platform, channelId: _appliedChannel);
      if (!mounted || request != _request) return;
      setState(() {
        _items
          ..clear()
          ..addAll(items);
        _platforms.addAll(items.map((item) => item.platform).where((p) => p.isNotEmpty));
        if (_platform != null) _platforms.add(_platform!);
        _syncGroups(_items);
      });
    } on ApiFailure catch (e) {
      if (!mounted || request != _request) return;
      if (e.isUnauthorized) {
        await widget.onUnauthorized?.call();
        return;
      }
      setState(() => _error = '${e.code}：${e.message}');
      if (_items.isNotEmpty) _toast('刷新失败：${e.code}');
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() => _error = '加载失败：$e');
      if (_items.isNotEmpty) _toast('刷新失败');
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  void _selectPlatform(String? value) {
    if (value == _platform) return;
    setState(() {
      _platform = value;
      // 下拉的 value 必须在 items 里，否则重建时断言失败。
      if (value != null) _platforms.add(value);
    });
    _load();
  }

  void _applyChannel(String raw) {
    _debounce?.cancel();
    final next = raw.trim();
    if (next == (_appliedChannel ?? '')) return;
    _appliedChannel = next.isEmpty ? null : next;
    _load();
  }

  void _onChannelChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _applyChannel(value));
  }

  void _clearChannel() {
    _debounce?.cancel();
    _channel.clear();
    _applyChannel('');
  }

  Future<void> _copy(TrafficEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.copyText));
    if (!mounted) return;
    _toast('已复制整条消息');
  }

  void _toggleGroup(String key, bool expanded) {
    // 显式写回反值，这样手动收起的第一组不会再被默认展开覆盖。
    setState(() => _expanded[key] = !expanded);
  }

  /// 按「平台 + 频道」重建分组。
  /// 「默认展开第一组」由渲染时决定（`_expanded[key] ?? index == 0`），
  /// 这里只清掉已经消失的分组的显式状态，保留用户手动收起/展开的选择。
  void _syncGroups(List<TrafficEntry> items) {
    final buckets = <String, List<TrafficEntry>>{};
    for (final entry in items) {
      buckets.putIfAbsent(entry.conversationKey, () => []).add(entry);
    }
    final groups = <_TrafficGroup>[];
    for (final bucket in buckets.entries) {
      final entries = bucket.value..sort((a, b) => b.time.compareTo(a.time));
      groups.add(
        _TrafficGroup(
          key: bucket.key,
          platform: entries.first.platform,
          label: entries.first.channelLabel,
          entries: entries,
        ),
      );
    }
    // 最近活跃的会话排在最前，第一组就是默认展开的那组。
    groups.sort((a, b) => b.lastTime.compareTo(a.lastTime));
    final keys = {for (final group in groups) group.key};
    _expanded.removeWhere((key, _) => !keys.contains(key));
    _groups = groups;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('消息记录'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh), tooltip: '刷新'),
        ],
      ),
      body: Column(
        children: [
          _filters(theme),
          Expanded(
            child: RefreshIndicator(onRefresh: _load, child: _body()),
          ),
        ],
      ),
    );
  }

  Widget _filters(ThemeData theme) {
    final scheme = theme.colorScheme;
    final platforms = _platforms.toList()..sort();
    final fill = scheme.surfaceContainerHighest.withValues(alpha: 0.6);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 38),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(10)),
            child: PopupMenuButton<String>(
              tooltip: '平台筛选',
              onSelected: (value) => _selectPlatform(value.isEmpty ? null : value),
              itemBuilder: (context) => [
                const PopupMenuItem<String>(value: '', child: Text('全部平台')),
                for (final platform in platforms)
                  PopupMenuItem<String>(value: platform, child: Text(platform)),
              ],
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_platform ?? '全部平台', style: theme.textTheme.bodyMedium),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_drop_down, size: 18),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _channel,
              builder: (context, value, _) => TextField(
                controller: _channel,
                textInputAction: TextInputAction.search,
                style: theme.textTheme.bodyMedium,
                onChanged: _onChannelChanged,
                onSubmitted: _applyChannel,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '频道 id',
                  filled: true,
                  fillColor: fill,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  prefixIconConstraints: const BoxConstraints(minWidth: 34),
                  suffixIcon: value.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          tooltip: '清除',
                          onPressed: _clearChannel,
                        ),
                  suffixIconConstraints: const BoxConstraints(minWidth: 34),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _groups.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_groups.isEmpty) {
      final failed = _error != null;
      final filtered = _platform != null || _appliedChannel != null;
      return _StatusView(
        icon: failed
            ? Icons.cloud_off_outlined
            : filtered
            ? Icons.filter_alt_off_outlined
            : Icons.inbox_outlined,
        title: failed ? '加载失败' : (filtered ? '没有匹配的消息' : '暂无消息'),
        message: failed ? _error! : '这里记录进入机器人但未进入会话的消息（指令等）',
        tinted: failed,
        action: OutlinedButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('刷新'),
        ),
      );
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
      children: [
        for (var i = 0; i < _groups.length; i++) ..._groupSection(_groups[i], i),
      ],
    );
  }

  List<Widget> _groupSection(_TrafficGroup group, int index) {
    // 排序后的第一组（最近活跃）默认展开；显式状态优先，手动收起后能记住。
    final expanded = _expanded[group.key] ?? index == 0;
    return [
      _GroupHeader(
        label: group.label,
        platform: group.platform,
        count: group.entries.length,
        time: _stamp(group.lastTime),
        expanded: expanded,
        onTap: () => _toggleGroup(group.key, expanded),
      ),
      if (expanded) ..._groupRows(group),
    ];
  }

  /// 组内保持时间倒序；跨天时插一条弱日期分隔，避免只靠 `时:分:秒` 分不清哪天。
  List<Widget> _groupRows(_TrafficGroup group) {
    final rows = <Widget>[];
    String? day;
    for (final entry in group.entries) {
      final label = _dayLabel(entry.time);
      if (label != day) {
        day = label;
        rows.add(_DayHeader(label: label));
      }
      rows.add(_TrafficTile(entry: entry, onTap: () => _copy(entry), showMeta: false));
    }
    return rows;
  }
}

/// 一个「平台 + 频道」会话分组，组内消息按时间倒序。
class _TrafficGroup {
  const _TrafficGroup({
    required this.key,
    required this.platform,
    required this.label,
    required this.entries,
  });

  final String key;
  final String platform;
  final String label;
  final List<TrafficEntry> entries;

  DateTime get lastTime => entries.first.time;
}

/// 分组头：`群聊/私聊 · 尾 6 位`、平台、条数胶囊、最后时间，点一下展开/收起。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.label,
    required this.platform,
    required this.count,
    required this.time,
    required this.expanded,
    required this.onTap,
  });

  final String label;
  final String platform;
  final int count;
  final String time;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 2),
      child: Material(
        color: expanded
            ? scheme.primaryContainer.withValues(alpha: 0.28)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: expanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: label,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                        ),
                        // 同尾号可能出现在不同平台，平台跟着组头走才不会认错会话。
                        if (platform.isNotEmpty)
                          TextSpan(
                            text: '  $platform',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                            ),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(
                    color: expanded
                        ? scheme.primary.withValues(alpha: 0.14)
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$count',
                    style: theme.textTheme.labelSmall?.copyWith(
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                      color: expanded ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  time,
                  maxLines: 1,
                  softWrap: false,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _two(int value) => value.toString().padLeft(2, '0');

String _hms(DateTime time) => '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';

String _dayLabel(DateTime time) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(time.year, time.month, time.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return '今天';
  if (diff == 1) return '昨天';
  if (time.year == now.year) return '${_two(time.month)}-${_two(time.day)}';
  return '${time.year}-${_two(time.month)}-${_two(time.day)}';
}

/// 分组头的最后时间：今天只给 `时:分:秒`，更早的带上日期。
String _stamp(DateTime time) {
  final label = _dayLabel(time);
  return label == '今天' ? _hms(time) : '$label ${_hms(time)}';
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
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

class _TrafficTile extends StatelessWidget {
  const _TrafficTile({required this.entry, required this.onTap, this.showMeta = true});

  final TrafficEntry entry;
  final VoidCallback onTap;

  /// 分组内已有平台与频道，行内就不再重复这一行。
  final bool showMeta;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final meta = [
      entry.platform,
      entry.channelLabel,
    ].where((part) => part.isNotEmpty).join(' · ');
    final content = entry.display;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 64,
              child: Text(
                _hms(entry.time),
                maxLines: 1,
                softWrap: false,
                style: theme.textTheme.labelSmall?.copyWith(
                  height: showMeta ? 1.6 : 1.3,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showMeta)
                    Text(
                      meta.isEmpty ? '未知来源' : meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        height: 1.6,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  Text(
                    content.isEmpty ? '（空消息）' : content,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      height: 1.35,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 空/错误共用的居中状态：可下拉刷新，所以底座是 ListView。
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
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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
