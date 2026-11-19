import 'package:flutter/material.dart';

import '../../core/design/app_tokens.dart';

/// 圆形头像的取图壳：统一解码宽度、首帧前露出占位、换 provider 时保留上一帧。
///
/// 三处头像（列表行 40dp、气泡 28dp、顶栏 32dp）都走同一个
/// [avatarDecodeWidthFor]，同一 URL 只占 `ImageCache` 一条 entry。
/// [placeholder] 垫在图片下面：第一帧到达之前、加载失败时看到的是它，
/// 不是白色/透明空窗，因此不会「闪一下再出来」。
class AvatarPhoto extends StatelessWidget {
  const AvatarPhoto({super.key, required this.url, required this.placeholder});

  final String url;

  /// 无图/加载中/加载失败时的占位（渐变底 + 图标或首字）。
  final Widget placeholder;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        placeholder,
        Image.network(
          url,
          fit: BoxFit.cover,
          // 统一一档解码宽度：换位置（列表 ↔ 气泡）命中同一条缓存。
          cacheWidth: avatarDecodeWidthFor(context),
          // provider 变化（刷新、重试）时保留上一帧，不闪回占位、不重播淡入。
          gaplessPlayback: true,
          // 第一帧之前不画任何东西，让下面的 placeholder 露出来。
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
              wasSynchronouslyLoaded || frame != null ? child : const SizedBox.shrink(),
          // 失败同样退回 placeholder：刷新/重连会重新解析同一个 provider。
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// 机器人头像占位：没有可用的远端头像时，用稳定的渐变+图标代表助手身份。
/// 若将来实例暴露 entity avatar，只需在 [imageUrl] 传入 URL 即可替换。
class AssistantAvatar extends StatelessWidget {
  const AssistantAvatar({super.key, this.size = 32, this.imageUrl});

  final double size;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = imageUrl;
    final fallback = Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, scheme.tertiary],
        ),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.auto_awesome, size: size * 0.52, color: scheme.onPrimary),
    );
    return SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: url == null ? fallback : AvatarPhoto(url: url, placeholder: fallback),
      ),
    );
  }
}
