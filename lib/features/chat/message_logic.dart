/// 消息渲染的纯逻辑：不依赖 Flutter，可直接单测。
library;

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
