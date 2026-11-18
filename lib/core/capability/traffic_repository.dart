/// 能力层：实例的入站消息旁路记录。
/// 纯指令消息（如 `chatluna-菜单`）在服务端指令层就被消费，不会落进会话日志；
/// 这个端点给出的是「进过机器人」的全部消息，用来在 App 里看见那些没进会话的。
library;

import '../model/models.dart';
import '../transport/api_client.dart';

/// 一条入站消息（`GET /api/traffic` 的一项）。
class TrafficEntry {
  const TrafficEntry({
    required this.id,
    required this.time,
    required this.platform,
    required this.selfId,
    required this.userId,
    required this.channelId,
    required this.guildId,
    required this.content,
  });

  final String id;
  final DateTime time;
  final String platform;
  final String selfId;
  final String userId;
  final String channelId;
  final String? guildId;
  final String content;

  static TrafficEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final raw = json['time'];
    final time = raw is num
        ? DateTime.fromMillisecondsSinceEpoch(raw.toInt())
        : DateTime.tryParse(raw?.toString() ?? '') ?? DateTime.now();
    return TrafficEntry(
      id: _text(json['id']),
      time: time,
      platform: _text(json['platform']),
      selfId: _text(json['selfId']),
      userId: _text(json['userId']),
      channelId: _text(json['channelId']),
      guildId: json['guildId'] == null ? null : _text(json['guildId']),
      content: _text(json['content']),
    );
  }

  /// 复制用的整条文本：身份全带上，便于拿去排查路由/频道。
  String get copyText {
    return '${time.year}-${_two(time.month)}-${_two(time.day)} '
        '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)} '
        '$platform channel=$channelId user=$userId'
        '${guildId == null || guildId!.isEmpty ? '' : ' guild=$guildId'}'
        '\n$content';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String _text(Object? value) => value is String ? value : '';
}

class TrafficRepository {
  TrafficRepository(this.api);

  final ApiClient api;

  /// 新 → 旧；[platform] / [channelId] 为空表示不过滤。
  Future<List<TrafficEntry>> list({
    int limit = 100,
    String? platform,
    String? channelId,
  }) async {
    final json = await api.getJson('/api/traffic', query: {
      'limit': '$limit',
      if (platform != null && platform.isNotEmpty) 'platform': platform,
      if (channelId != null && channelId.isNotEmpty) 'channelId': channelId,
    });
    if (json is! Map) throw ApiFailure('INTERNAL', '消息记录返回体异常');
    final items = <TrafficEntry>[];
    for (final item in (json['items'] as List?) ?? const []) {
      final entry = TrafficEntry.fromJson(item);
      if (entry != null) items.add(entry);
    }
    return items;
  }
}
