/// 消息渲染的纯逻辑：不依赖 Flutter，可直接单测。
library;

import '../../core/model/models.dart';

/// 纯函数结果的有界缓存：键是不可变输入（正文），值只依赖键。
///
/// 用途是「同一条消息重建一次不重算」：`ListView` 回收/主题切换/父级 setState
/// 都会让气泡重新 build，而 `CommandHelp.parse`、`Notice.parse`、占位判定
/// 都只依赖正文。命中后按最近使用顺序移到末尾，超限丢最旧一项。
///
/// 页面销毁不影响正确性，只影响下一次是否重新计算；因此调用方可以在
/// 切后台时 [clear] 它来压低 Dart 堆。
class MemoCache<T> {
  MemoCache({this.capacity = 200}) : assert(capacity > 0);

  final int capacity;
  final Map<String, T> _values = <String, T>{};

  int get length => _values.length;

  T value(String key, T Function() compute) {
    if (_values.containsKey(key)) {
      final hit = _values.remove(key) as T;
      _values[key] = hit;
      return hit;
    }
    final computed = compute();
    _values[key] = computed;
    if (_values.length > capacity) _values.remove(_values.keys.first);
    return computed;
  }

  void clear() => _values.clear();
}

/// 占位文案的标签：长短词在前（`视频消息` 先于 `视频`），否则捕获组只会拿到前缀。
const String _placeholderLabels =
    '视频消息|视频|语音消息|语音|音频|图片|照片|截图|文件|动画表情|表情|贴图|贴纸|引用|卡片|小程序|未知消息';

/// 正文占位文案：插件把消息里的每个元素按顺序写成一枚占位（中文标点/方括号形式）。
/// 捕获组 1 是方括号里的标签，用来判断这一枚该放哪种媒体。
final RegExp _mediaPlaceholder = RegExp('\\[\\s*($_placeholderLabels)\\s*\\]');

/// 占位文案周围的中英标点与空白：剥掉它们才能判断「除了占位什么都没有」。
final RegExp _placeholderPunctuation = RegExp(
  r'[\s\.,，。、;;；:：!！?？~～·•\-—_|*（）()【】\[\]]+',
);

/// 正文是否只是媒体占位文案（`[图片]`、`[图片][视频]`、`（[截图]）`）。
///
/// 消息带媒体且正文只是占位时，气泡里不再重复这段文字——媒体块已经表达完了。
/// 只要还剩任何实义字符（含英文占位 `[image]`、`<img src>` 这类标签）就返回 false，
/// 宁可多显示一行文本，也不能把用户真写的话吞掉。
bool isPlaceholderOnly(String text) {
  if (!_mediaPlaceholder.hasMatch(text)) return false;
  final rest = text.replaceAll(_mediaPlaceholder, '').replaceAll(_placeholderPunctuation, '');
  return rest.isEmpty;
}

/// 正文里是否至少有一枚媒体占位（顺序混排的入口判定）。
bool hasMediaPlaceholder(String text) => _mediaPlaceholder.hasMatch(text);

/// 一段渲染序列：要么是正文文字，要么是某个媒体附件。
sealed class ContentSegment {
  const ContentSegment();
}

/// 正文切片。首尾空白在切分时已经去掉，段与段之间的间距由排版给。
final class TextSegment extends ContentSegment {
  const TextSegment(this.text);

  final String text;
}

/// 指向 `media[i]` 的媒体段。下标保留原始位置，调用方按需整块渲染。
final class MediaSegment extends ContentSegment {
  const MediaSegment(this.mediaIndex);

  final int mediaIndex;
}

/// 占位标签 → 媒体类型；`[表情]`/`[引用]`/`[卡片]` 这类没有附件，原位保留成文本。
String? _kindOfPlaceholder(String label) => switch (label) {
  '图片' || '照片' || '截图' => 'image',
  '视频' || '视频消息' => 'video',
  '语音' || '语音消息' || '音频' => 'audio',
  '文件' => 'file',
  _ => null,
};

/// 取下一条该类型的未用媒体；类型不匹配时退而取任意一条未用的（插件顺序偶有错位）。
/// 全都用完了返回 -1，占位只能留成文本。
int _takeMedia(List<PlatformMedia> media, List<bool> used, String kind) {
  for (var i = 0; i < media.length; i++) {
    if (!used[i] && media[i].kind == kind) return i;
  }
  for (var i = 0; i < media.length; i++) {
    if (!used[i]) return i;
  }
  return -1;
}

/// 把正文与附件交错成渲染序列：`[图片]` 原位换成图片，`[视频]`/`[语音]`/`[文件]` 同理。
///
/// 插件按元素顺序写占位、附件列表同序，因此「文字—图—文字」能按占位位置还原。
/// 匹配不到的占位（`[表情]`/`[引用]` 或附件已用尽）原位留成文本：宁可多显示一行，
/// 也不能把用户真写的话或消息里的一枚元素吞掉。剩余附件按原顺序追加到末尾。
///
/// 正文没有占位时返回单个文本段（正文为空则只有附件段），调用方据此保持旧布局。
List<ContentSegment> interleaveContent(String body, List<PlatformMedia> media) {
  final segments = <ContentSegment>[];
  final used = List<bool>.filled(media.length, false);
  var cursor = 0;

  void addText(String raw) {
    if (raw.isEmpty) return;
    // 相邻文本并成一段：没有媒体插在中间时，段落流与原来的整段正文一字不差。
    final last = segments.isEmpty ? null : segments.last;
    if (last is TextSegment) {
      segments[segments.length - 1] = TextSegment(last.text + raw);
      return;
    }
    segments.add(TextSegment(raw));
  }

  for (final match in _mediaPlaceholder.allMatches(body)) {
    addText(body.substring(cursor, match.start));
    cursor = match.end;
    final kind = _kindOfPlaceholder(match.group(1)!);
    final index = kind == null ? -1 : _takeMedia(media, used, kind);
    if (index < 0) {
      addText(match.group(0)!);
      continue;
    }
    used[index] = true;
    segments.add(MediaSegment(index));
  }
  addText(body.substring(cursor));

  for (var i = 0; i < media.length; i++) {
    if (!used[i]) segments.add(MediaSegment(i));
  }
  // 段与段之间由排版给间距：文本段收掉贴着媒体的空白，纯空白段直接丢。
  final result = <ContentSegment>[];
  for (final segment in segments) {
    switch (segment) {
      case MediaSegment():
        result.add(segment);
      case TextSegment(:final text):
        final trimmed = text.trim();
        if (trimmed.isEmpty) continue;
        result.add(trimmed == text ? segment : TextSegment(trimmed));
    }
  }
  return result;
}
