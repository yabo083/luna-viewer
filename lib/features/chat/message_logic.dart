/// 消息渲染的纯逻辑：不依赖 Flutter，可直接单测。
library;

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

/// 正文占位文案：插件在「没有文字、只有媒体」时写的就是这些（中文标点/方括号形式）。
final RegExp _mediaPlaceholder = RegExp(
  r'\[\s*(?:图片|照片|截图|视频|视频消息|语音|语音消息|音频|文件|表情|动画表情|贴图|贴纸|引用|卡片|小程序|未知消息)\s*\]',
);

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
