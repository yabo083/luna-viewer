/// 对抗性用例：纯逻辑层（模型清洗 / 时间 / 归一键 / 时间线）。
///
/// 与传输层无关，全部可离线跑。带「待修」的失败用例对应
/// `docs/adversarial-review.md` 里的待修项。
library;

import 'package:chatluna_mobile/core/capability/platform_repository.dart';
import 'package:chatluna_mobile/core/model/models.dart';
import 'package:chatluna_mobile/features/chat/timeline.dart';
import 'package:flutter_test/flutter_test.dart';

PlatformMessage _msg(
  String id,
  DateTime time, {
  String content = '',
  bool outbound = false,
  String userId = 'u1',
}) => PlatformMessage(
  id: id,
  time: time,
  outbound: outbound,
  userId: userId,
  content: content,
);

void main() {
  group('正文清洗：普通消息里的 <...> 被当成标签剥掉', () {
    test('待修：平台消息里的比较/泛型文本被吞（用户看到的内容与发出的不一致）', () {
      final message = PlatformMessage.fromJson({
        'id': 'm1',
        'time': 1763000000000,
        'dir': 'in',
        'content': 'if (a<b && c>d) 用 vector<int> 试试',
      });
      expect(
        message!.view.bodyMarkdown,
        'if (a<b && c>d) 用 vector<int> 试试',
        reason: '正文清洗只应针对框架/引擎包裹的 XML，不能改写用户原话',
      );
    });

    test('待修：会话日志里的同一句也被吞', () {
      final message = ChatMessage.fromJson({
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'if (a<b && c>d) 用 vector<int> 试试'},
        ],
      });
      expect(message.bodyMarkdown, 'if (a<b && c>d) 用 vector<int> 试试');
    });

    test('HTML 风格消息同样被静默删除（无法与真实标签区分，属同一缺陷）', () {
      final message = PlatformMessage.fromJson({
        'id': 'm2',
        'time': 1763000000000,
        'dir': 'in',
        'content': '记得写 <div> 和 </div> 来分栏',
      });
      // 记录现状：标签被剥掉后只剩残句。
      expect(message!.view.bodyMarkdown, isNot(contains('<div>')));
    });
  });

  group('坏字段：单块坏数据不能炸掉整条消息', () {
    test('待修：text 块里的 text 不是字符串时 bodyMarkdown 抛 TypeError', () {
      final message = ChatMessage.fromJson({
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 42},
          {'type': 'text', 'text': '正常的一段'},
        ],
      });
      expect(() => message.bodyMarkdown, returnsNormally);
    });

    test('未知块类型被忽略而不是抛错', () {
      final message = ChatMessage.fromJson({
        'role': 'assistant',
        'content': [
          {'type': 'mystery', 'x': 1},
          {'type': 'text', 'text': '正文在'},
        ],
      });
      expect(message.bodyMarkdown, '正文在');
    });
  });

  group('时间：服务端 ISO 串被当成 UTC，直接用于本地展示', () {
    test('待修：带 Z 的时间保留 UTC，日期分隔与 HH:mm 会偏一个时区', () {
      final message = PlatformMessage.fromJson({
        'id': 'm3',
        'time': '2026-11-19T23:30:00.000Z',
        'dir': 'in',
        'content': 'hi',
      });
      expect(message!.time.isUtc, isFalse, reason: '展示前应统一 toLocal()');
      expect(message.time.millisecondsSinceEpoch, 1795131000000);
    });

    test('毫秒/秒数字都归一到毫秒（对照组）', () {
      final ms = PlatformMessage.fromJson({
        'id': 'm4',
        'time': 1763000000000,
        'dir': 'in',
        'content': 'a',
      });
      final s = PlatformMessage.fromJson({
        'id': 'm5',
        'time': 1763000000,
        'dir': 'in',
        'content': 'b',
      });
      expect(ms!.time.millisecondsSinceEpoch, 1763000000000);
      expect(s!.time.millisecondsSinceEpoch, 1763000000000);
    });
  });

  group('时间线：乱序 / 重复 / 空会话', () {
    final t0 = DateTime(2026, 11, 19, 12);

    test('乱序消息按时间升序合并，日期分隔只出现一次', () {
      final items = mergeTimeline([
        _msg('c', t0.add(const Duration(minutes: 2)), content: '3'),
        _msg('a', t0, content: '1'),
        _msg('b', t0.add(const Duration(minutes: 1)), content: '2'),
      ], []);
      final texts = [
        for (final item in items)
          if (item is MessageItem) item.message.content,
      ];
      expect(texts, ['1', '2', '3']);
      expect(items.whereType<DayDividerItem>(), hasLength(1));
    });

    test('同一条消息重复给两次时时间线出现两次（UI 前一层按 id 去重）', () {
      final items = mergeTimeline([
        _msg('a', t0, content: 'x'),
        _msg('a', t0, content: 'x'),
      ], []);
      expect(items.whereType<MessageItem>(), hasLength(2));
    });

    test('空会话：没有消息也没有框架块时返回空时间线', () {
      expect(mergeTimeline(const [], const []), isEmpty);
    });

    test('只有框架块时也能定序（无平台消息锚点）', () {
      final items = mergeTimeline(const [], [
        TimelineNotice(id: 'n1', text: 'wake', time: t0),
        TimelineNotice(id: 'n2', text: 'memory', time: t0.subtract(const Duration(minutes: 1))),
      ]);
      final order = [
        for (final item in items)
          if (item is NoticeItem) item.notice.text,
      ];
      expect(order, ['memory', 'wake']);
    });
  });

  group('会话键归一（列表合并与详情流过滤共用）', () {
    test('route: 前缀与 user/lane 段都剥掉', () {
      expect(normalizeConversationKey('route:r-abc:user:123'), 'r-abc');
      expect(normalizeConversationKey('route:r-abc:lane:2'), 'r-abc');
      expect(normalizeConversationKey('  route:r-abc:user:123  '), 'r-abc');
      expect(normalizeConversationKey('r-abc'), 'r-abc');
    });

    test('不带前缀的 :user: 后缀也归一', () {
      expect(normalizeConversationKey('r-abc:user:123'), 'r-abc');
    });

    test('只有前缀没有内容时归一到空串（调用方需按空键放弃）', () {
      expect(normalizeConversationKey('route:'), '');
      expect(normalizeConversationKey('   '), '');
    });

    test('同一 route 的两个 lane 归一后相同：不同 lane 的消息会串台', () {
      // 记录现状：如果插件把 lane 当作独立会话，详情页过滤会把它们当成同一个。
      expect(
        normalizeConversationKey('route:r-abc:user:1'),
        normalizeConversationKey('route:r-abc:lane:2'),
      );
    });
  });

  group('长文本与媒体', () {
    test('100KB 纯文本不被截断', () {
      final text = '长' * 100000;
      final message = ChatMessage.fromJson({
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': text},
        ],
      });
      expect(message.bodyMarkdown.length, 100000);
    });

    test('全图片消息的列表预览用占位而不是空串', () {
      final message = PlatformMessage.fromJson({
        'id': 'm6',
        'time': 1763000000000,
        'dir': 'in',
        'content': '',
        'media': [
          {'kind': 'image', 'url': '/files/a.png'},
          {'kind': 'file', 'name': 'log.txt'},
        ],
      });
      expect(message!.preview, '[图片] [文件]');
    });

    test('media 不是数组 / 项不是对象时按空列表处理', () {
      final message = PlatformMessage.fromJson({
        'id': 'm7',
        'time': 1763000000000,
        'dir': 'in',
        'content': 'hi',
        'media': 'oops',
      });
      expect(message!.media, isEmpty);
    });

    test('absoluteResourceUrl：相对路径补实例地址，data/base64 原样', () {
      final base = Uri.parse('http://192.168.0.107:5028');
      expect(absoluteResourceUrl(base, '/files/a.png'), 'http://192.168.0.107:5028/files/a.png');
      expect(absoluteResourceUrl(base, '//cdn.example/x.png'), 'http://cdn.example/x.png');
      expect(absoluteResourceUrl(base, 'https://cdn.example/x.png'), 'https://cdn.example/x.png');
      expect(absoluteResourceUrl(base, 'data:image/png;base64,AA'), 'data:image/png;base64,AA');
      expect(absoluteResourceUrl(base, '   '), isNull);
    });

    test('storage:// 引用转 /files/<编码后的 id>，不会把 / 带进路径段', () {
      final message = ChatMessage.fromJson({
        'role': 'assistant',
        'content': [
          {
            'type': 'file',
            'mediaType': 'image/png',
            'data': {'type': 'reference', 'reference': 'storage://a/../../b.png'},
          },
        ],
      });
      final body = message.bodyMarkdown;
      expect(body, contains('/files/'));
      expect(body, isNot(contains('/../')));
    });
  });
}
