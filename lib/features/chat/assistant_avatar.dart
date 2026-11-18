import 'package:flutter/material.dart';

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
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, scheme.tertiary],
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: url == null
          ? Icon(Icons.auto_awesome, size: size * 0.52, color: scheme.onPrimary)
          : Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  Icon(Icons.auto_awesome, size: size * 0.52, color: scheme.onPrimary),
            ),
    );
  }
}
