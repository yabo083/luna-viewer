/// 能力层：平台消息真源（伴侣插件 `/api/platform/*`）。
///
/// App 的会话与消息只认这里：会话列表来自 [conversations]，历史来自 [messages]，
/// 增量来自 `PlatformStream`。`/api/sessions*` 只补充「已加载会话」的状态与操作
/// （模型、压缩、分叉、中止），不再提供任何消息。
library;

import '../model/models.dart';
import '../transport/api_client.dart';

/// 归一：去掉 `route:` 前缀与 `:user:` / `:lane:` 段。
/// 插件会话键是 `r-<hash>`，App 会话 id 是 `route:r-<hash>:user:<id>`：
/// 两边归一后同一个群 / 私聊才相等，列表合并与详情流过滤都用这一条规则。
String normalizeConversationKey(String value) {
  final trimmed = value.trim();
  final key = trimmed.startsWith(_routePrefix) ? trimmed.substring(_routePrefix.length) : trimmed;
  final cut = key.indexOf(_suffixMarker);
  return cut > 0 ? key.substring(0, cut) : key;
}

const String _routePrefix = 'route:';
final RegExp _suffixMarker = RegExp(r':(user|lane):');

class PlatformRepository {
  PlatformRepository(this.api);

  final ApiClient api;

  /// 插件侧的会话全表，按最后消息倒序（服务端顺序直接可用）。
  Future<List<PlatformConversation>> conversations() async {
    final json = await api.getJson('/api/platform/conversations');
    if (json is! Map) throw ApiFailure('INTERNAL', '平台会话返回体异常');
    try {
      final items = <PlatformConversation>[];
      final raw = json['items'];
      if (raw is! List) return items;
      for (final item in raw) {
        final conversation = PlatformConversation.fromJson(item);
        if (conversation != null) items.add(conversation);
      }
      return items;
    } on ApiFailure {
      rethrow;
    } catch (_) {
      // 字段漂移（`count:"12"` 等）收敛成 ApiFailure：页面只认识它。
      throw ApiFailure('INTERNAL', '平台会话返回体字段异常');
    }
  }

  /// 一个会话的消息页，时间升序。
  ///
  /// [before] 是游标：取该时间之前（更早）的一页，调用方传当前最早一条的 [PlatformMessage.time]。
  /// 服务端按毫秒时间戳比较，所以游标也发毫秒数。
  Future<PlatformMessagePage> messages(
    String key, {
    int limit = 50,
    DateTime? before,
  }) async {
    final json = await api.getJson('/api/platform/messages', query: {
      'key': key,
      'limit': '$limit',
      if (before != null) 'before': '${before.millisecondsSinceEpoch}',
    });
    if (json is! Map) throw ApiFailure('INTERNAL', '平台消息返回体异常');
    try {
      final raw = json['items'];
      final items = <PlatformMessage>[
        if (raw is List)
          for (final item in raw) ?PlatformMessage.fromJson(item),
      ];
      // 契约是升序；万一服务端换了顺序，分页游标与倒序渲染都会错位，这里先兜住。
      items.sort((a, b) => a.time.compareTo(b.time));
      return PlatformMessagePage(items, _asBool(json['hasMore']));
    } on ApiFailure {
      rethrow;
    } catch (_) {
      throw ApiFailure('INTERNAL', '平台消息返回体字段异常');
    }
  }

  /// `hasMore` 接受 bool、数字与字符串（`1` / `"true"` / `"1"`）：
  /// 只认 `== true` 会让翻页在字段漂移时提前结束。
  static bool _asBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final text = value.trim().toLowerCase();
      return text == 'true' || text == '1' || text == 'yes';
    }
    return false;
  }
}
