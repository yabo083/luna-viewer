import 'package:chatluna_mobile/core/model/models.dart';
import 'package:chatluna_mobile/features/chat/timeline.dart';
import 'package:flutter_test/flutter_test.dart';

/// 时间线的可读序列：`d` = 日期分隔条，`m:<id>` = 平台消息，`n:<id>` = 框架块。
List<String> _labels(List<TimelineItem> items) => [
  for (final item in items)
    switch (item) {
      DayDividerItem() => 'd',
      NoticeItem(:final notice) => 'n:${notice.id}',
      MessageItem(:final message) => 'm:${message.id}',
    },
];

PlatformMessage _msg(String id, DateTime time, {String content = '', bool outbound = false}) =>
    PlatformMessage(
      id: id,
      time: time,
      outbound: outbound,
      userId: outbound ? '' : 'u1',
      content: content,
    );

void main() {
  group('mergeTimeline', () {
    test('同一时刻：平台消息在前，框架块按取回顺序排在后面', () {
      final at = DateTime(2026, 11, 18, 9);
      final messages = [_msg('m1', at, content: '早上好')];
      final notices = [
        TimelineNotice(id: 'n1', text: '[skills update] 已载入', time: at),
        TimelineNotice(id: 'n2', text: '[memory] 记下了', time: at),
      ];

      final items = mergeTimeline(messages, notices);
      expect(_labels(items), ['d', 'm:m1', 'n:n1', 'n:n2']);

      // 同样的输入永远同样的顺序：列表重建不会让框架块前后乱跳。
      expect(_labels(mergeTimeline(messages, notices)), _labels(items));
    });

    test('没有时戳的框架块贴住相邻平台消息（前一条 +1ms / 后一条 −1ms）', () {
      final first = DateTime(2026, 11, 18, 9);
      final second = first.add(const Duration(minutes: 5));
      final items = mergeTimeline(
        [_msg('m1', first), _msg('m2', second)],
        [
          // 前面没有平台消息：落在最早一条之前。
          const TimelineNotice(id: 'lead', text: '[memory] 开局'),
          // 后面没有平台消息：落在已排好的最后一项之后。
          TimelineNotice(
            id: 'tail',
            text: '[tool update] 收尾',
            time: second.add(const Duration(minutes: 5)),
          ),
          const TimelineNotice(id: 'after', text: '[memory] 之后'),
        ],
      );

      // `lead` 与 `after` 没有时戳，但仍落在正确的相邻位置，不再沉到列表底部。
      expect(_labels(items), ['d', 'n:lead', 'm:m1', 'm:m2', 'n:tail', 'n:after']);
    });

    test('框架块穿插后分组重置，翻页后相对位置不变', () {
      final start = DateTime(2026, 11, 17, 23, 58);
      final messages = [
        _msg('a', start, content: '睡了'),
        _msg('b', start.add(const Duration(minutes: 2)), content: '还在'),
        _msg('c', start.add(const Duration(minutes: 6)), content: '醒了'),
      ];
      final notice = TimelineNotice(
        id: 'n1',
        text: '[tool update] 检索记忆',
        time: start.add(const Duration(minutes: 3)),
      );

      final items = mergeTimeline(messages, [notice]);
      final byId = {
        for (final item in items.whereType<MessageItem>()) item.message.id: item.showHeader,
      };
      // 跨天插分隔条，并让 `b` 重新显示头像；框架块再打断一次，`c` 也重新显示。
      expect(_labels(items), ['d', 'm:a', 'd', 'm:b', 'n:n1', 'm:c']);
      expect(byId, {'a': true, 'b': true, 'c': true});

      // 没有框架块时 `b → c` 只差 4 分钟，属于同一组：分组确实是框架块打断的。
      expect(
        mergeTimeline(messages, const []).whereType<MessageItem>().last.showHeader,
        isFalse,
      );

      // 翻页只往前追加更早的消息：已经定锚的框架块与邻居的相对顺序不变。
      final paged = mergeTimeline(
        [
          for (var i = 3; i >= 1; i--)
            _msg('e$i', start.subtract(Duration(minutes: i * 5))),
          ...messages,
        ],
        [notice],
      );
      final labels = _labels(paged);
      final at = labels.indexOf('n:n1');
      expect(labels.sublist(at - 1, at + 2), ['m:b', 'n:n1', 'm:c']);
    });
  });
}
