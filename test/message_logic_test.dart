import 'package:chatluna_mobile/core/model/models.dart';
import 'package:chatluna_mobile/features/chat/message_logic.dart';
import 'package:flutter_test/flutter_test.dart';

/// 段序列压成字符串，断言一眼能看出顺序：`text:前文` / `media:0`。
List<String> describe(List<ContentSegment> segments) => [
  for (final segment in segments)
    switch (segment) {
      TextSegment(:final text) => 'text:$text',
      MediaSegment(:final mediaIndex) => 'media:$mediaIndex',
    },
];

PlatformMedia media(String kind, [String? url]) =>
    PlatformMedia(kind: kind, url: url ?? 'https://example.com/$kind');

void main() {
  group('isPlaceholderOnly', () {
    test('单个中文占位文案', () {
      expect(isPlaceholderOnly('[图片]'), isTrue);
      expect(isPlaceholderOnly('[图片] '), isTrue);
      expect(isPlaceholderOnly('  [截图]\n'), isTrue);
      expect(isPlaceholderOnly('[ 视频消息 ]'), isTrue);
    });

    test('多个占位文案与包裹标点', () {
      expect(isPlaceholderOnly('[图片][视频]'), isTrue);
      expect(isPlaceholderOnly('（[图片]）'), isTrue);
      expect(isPlaceholderOnly('[图片] · [文件]'), isTrue);
    });

    test('英文占位与内联标签不算占位：宁可多显示，也不吞掉正文', () {
      expect(isPlaceholderOnly('[image]'), isFalse);
      expect(isPlaceholderOnly('<img src="a.png">'), isFalse);
    });

    test('纯空白不算占位', () {
      expect(isPlaceholderOnly(''), isFalse);
      expect(isPlaceholderOnly('   '), isFalse);
      expect(isPlaceholderOnly('\n\t '), isFalse);
    });

    test('正常文本不算占位', () {
      expect(isPlaceholderOnly('这是一段正常的回复'), isFalse);
      expect(isPlaceholderOnly('[图片] 看这张'), isFalse);
      expect(isPlaceholderOnly('[文件] —— 见附件'), isFalse);
    });
  });

  group('MemoCache', () {
    test('同一个键只计算一次；命中后仍然返回同一个结果', () {
      final cache = MemoCache<List<int>>(capacity: 4);
      var calls = 0;
      List<int> compute() {
        calls += 1;
        return [calls];
      }

      expect(cache.value('a', compute), [1]);
      expect(cache.value('a', compute), [1]);
      expect(calls, 1);
      expect(cache.length, 1);
    });

    test('可缓存 null（解析失败的结果也要记住）', () {
      final cache = MemoCache<String?>(capacity: 4);
      var calls = 0;
      String? compute() {
        calls += 1;
        return null;
      }

      expect(cache.value('x', compute), isNull);
      expect(cache.value('x', compute), isNull);
      expect(calls, 1);
    });

    test('超过容量淘汰最久未用的一项', () {
      final cache = MemoCache<int>(capacity: 2);
      cache.value('a', () => 1);
      cache.value('b', () => 2);
      // 命中 a：b 变成最久未用。
      cache.value('a', () => 1);
      cache.value('c', () => 3);
      expect(cache.length, 2);
      expect(cache.value('a', () => 10), 1);
      expect(cache.value('b', () => 20), 20);
    });

    test('clear 之后重新计算', () {
      final cache = MemoCache<int>(capacity: 2);
      var calls = 0;
      int compute() => ++calls;
      cache.value('a', compute);
      cache.clear();
      expect(cache.value('a', compute), 2);
    });
  });

  group('interleaveContent', () {
    test('纯文 + 图 + 文：按占位位置切开', () {
      expect(
        describe(interleaveContent('前文[图片]后文', [media('image')])),
        ['text:前文', 'media:0', 'text:后文'],
      );
    });

    test('只有图：正文没有文字，只剩媒体段', () {
      expect(describe(interleaveContent('[图片]', [media('image')])), ['media:0']);
    });

    test('两图夹文：两个占位按顺序各取一张', () {
      expect(
        describe(interleaveContent('看图[图片][图片]完', [media('image'), media('image')])),
        ['text:看图', 'media:0', 'media:1', 'text:完'],
      );
    });

    test('kind 不匹配：优先取同类型，退而取未用的；没有附件的占位留成文本', () {
      // 第一个占位要图片：跳过前面的视频，取后面的图片；第二个占位再取剩下的视频。
      expect(
        describe(interleaveContent('[图片][视频]', [media('video'), media('image')])),
        ['media:1', 'media:0'],
      );
      // 类型对不上也照样取出：插件顺序偶有错位时不能把元素丢掉。
      expect(describe(interleaveContent('[图片]', [media('video')])), ['media:0']);
      // `[表情]` 没有附件可对应：原位留成文本，整句段落不被切断。
      expect(
        describe(interleaveContent('看[表情]笑', [media('image')])),
        ['text:看[表情]笑', 'media:0'],
      );
    });

    test('无占位符：单段文本，附件按原顺序追加在末尾', () {
      expect(
        describe(interleaveContent('纯文本', [media('image'), media('video')])),
        ['text:纯文本', 'media:0', 'media:1'],
      );
    });
  });
}
