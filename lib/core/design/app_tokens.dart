import 'package:flutter/material.dart';

/// 设计 token：语义色、字阶、间距、圆角。
///
/// 取值来自 `docs/design-review.md`（A 节）。所有组件只允许引用这里的
/// 语义名，不要再散落十六进制常量或随手写 3/5/7 这类奇数间距。
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.canvas,
    required this.surfaceL1,
    required this.surfaceL2,
    required this.surfaceL3,
    required this.bubbleOutBg,
    required this.bubbleOutBorder,
    required this.bubbleOutText,
    required this.bubbleOutMuted,
    required this.bubbleInBg,
    required this.bubbleInBorder,
    required this.bubbleInText,
    required this.bubbleInMuted,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.borderSubtle,
    required this.borderDivider,
    required this.accent,
    required this.statusRunning,
    required this.statusWarning,
    required this.statusError,
    required this.skeletonBg,
    required this.skeletonBorder,
    required this.shimmerBase,
    required this.shimmerLit,
  });

  factory AppColors.of(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return dark ? _dark : _light;
  }

  final Color canvas;
  final Color surfaceL1;
  final Color surfaceL2;
  final Color surfaceL3;
  final Color bubbleOutBg;
  final Color bubbleOutBorder;
  final Color bubbleOutText;
  final Color bubbleOutMuted;
  final Color bubbleInBg;
  final Color bubbleInBorder;
  final Color bubbleInText;
  final Color bubbleInMuted;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color borderSubtle;
  final Color borderDivider;
  final Color accent;
  final Color statusRunning;
  final Color statusWarning;
  final Color statusError;
  final Color skeletonBg;
  final Color skeletonBorder;
  final Color shimmerBase;
  final Color shimmerLit;

  static const _dark = AppColors(
    canvas: Color(0xFF0B0D10),
    surfaceL1: Color(0xFF13161B),
    surfaceL2: Color(0xFF1A1E26),
    surfaceL3: Color(0xFF232833),
    bubbleOutBg: Color(0xFF182842),
    bubbleOutBorder: Color(0xFF22385C),
    bubbleOutText: Color(0xFFE2EDFC),
    bubbleOutMuted: Color(0xFF8BA2C4),
    bubbleInBg: Color(0xFF1A1E26),
    bubbleInBorder: Color(0xFF252B37),
    bubbleInText: Color(0xFFEDEDF0),
    bubbleInMuted: Color(0xFF8C93A0),
    textPrimary: Color(0xFFEDEDF0),
    textSecondary: Color(0xFF9198A6),
    textTertiary: Color(0xFF585F6D),
    borderSubtle: Color(0xFF222733),
    borderDivider: Color(0xFF181C24),
    accent: Color(0xFF5B8DEF),
    statusRunning: Color(0xFF22C55E),
    statusWarning: Color(0xFFF59E0B),
    statusError: Color(0xFFEF4444),
    skeletonBg: Color(0xFF131924),
    skeletonBorder: Color(0xFF223552),
    shimmerBase: Color(0xFF212836),
    shimmerLit: Color(0xFF333E53),
  );

  static const _light = AppColors(
    canvas: Color(0xFFF7F8FB),
    surfaceL1: Color(0xFFFFFFFF),
    surfaceL2: Color(0xFFEEF1F6),
    surfaceL3: Color(0xFFE3E7F0),
    bubbleOutBg: Color(0xFFD9E8FF),
    bubbleOutBorder: Color(0xFFB4CFF7),
    bubbleOutText: Color(0xFF0D254C),
    bubbleOutMuted: Color(0xFF4B6999),
    bubbleInBg: Color(0xFFFFFFFF),
    bubbleInBorder: Color(0xFFE2E6EF),
    bubbleInText: Color(0xFF14171D),
    bubbleInMuted: Color(0xFF636B78),
    textPrimary: Color(0xFF14171D),
    textSecondary: Color(0xFF565E6D),
    textTertiary: Color(0xFF8A93A2),
    borderSubtle: Color(0xFFE1E5ED),
    borderDivider: Color(0xFFEDF0F5),
    accent: Color(0xFF336EE2),
    statusRunning: Color(0xFF16A34A),
    statusWarning: Color(0xFFD97706),
    statusError: Color(0xFFDC2626),
    skeletonBg: Color(0xFFEFF4FD),
    skeletonBorder: Color(0xFFBDD5FA),
    shimmerBase: Color(0xFFDFE6F2),
    shimmerLit: Color(0xFFC6D2E6),
  );

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return AppColors(
      canvas: mix(canvas, other.canvas),
      surfaceL1: mix(surfaceL1, other.surfaceL1),
      surfaceL2: mix(surfaceL2, other.surfaceL2),
      surfaceL3: mix(surfaceL3, other.surfaceL3),
      bubbleOutBg: mix(bubbleOutBg, other.bubbleOutBg),
      bubbleOutBorder: mix(bubbleOutBorder, other.bubbleOutBorder),
      bubbleOutText: mix(bubbleOutText, other.bubbleOutText),
      bubbleOutMuted: mix(bubbleOutMuted, other.bubbleOutMuted),
      bubbleInBg: mix(bubbleInBg, other.bubbleInBg),
      bubbleInBorder: mix(bubbleInBorder, other.bubbleInBorder),
      bubbleInText: mix(bubbleInText, other.bubbleInText),
      bubbleInMuted: mix(bubbleInMuted, other.bubbleInMuted),
      textPrimary: mix(textPrimary, other.textPrimary),
      textSecondary: mix(textSecondary, other.textSecondary),
      textTertiary: mix(textTertiary, other.textTertiary),
      borderSubtle: mix(borderSubtle, other.borderSubtle),
      borderDivider: mix(borderDivider, other.borderDivider),
      accent: mix(accent, other.accent),
      statusRunning: mix(statusRunning, other.statusRunning),
      statusWarning: mix(statusWarning, other.statusWarning),
      statusError: mix(statusError, other.statusError),
      skeletonBg: mix(skeletonBg, other.skeletonBg),
      skeletonBorder: mix(skeletonBorder, other.skeletonBorder),
      shimmerBase: mix(shimmerBase, other.shimmerBase),
      shimmerLit: mix(shimmerLit, other.shimmerLit),
    );
  }
}

/// 4dp 网格间距（2 只用于微对齐）。
abstract final class Space {
  static const double x2 = 2;
  static const double x4 = 4;
  static const double x8 = 8;
  static const double x12 = 12;
  static const double x16 = 16;
  static const double x20 = 20;
}

/// 圆角阶梯。
abstract final class Radii {
  static const double pill = 999;
  static const double sheet = 16;
  static const double bubble = 16;
  static const double bubbleTail = 4;
  static const double card = 10;
  static const double tile = 8;
  static const double bar = 4;
}

/// 取当前主题的语义色。
extension AppColorsX on BuildContext {
  AppColors get colors =>
      Theme.of(this).extension<AppColors>() ?? AppColors.of(Theme.of(this).brightness);
}

/// 列表/气泡里图片的解码宽度：按显示的逻辑宽度 × 像素比，上限 `dp × dpr × 1.5`。
///
/// 解码内存按像素面积增长：按原图分辨率解一张 4000px 的照片就是 ~60MB，并且会
/// 常驻 `ImageCache`（退页也不释放）。1.5 倍只用来吸收圆形裁切/轻微缩放，
/// 再高的分辨率在手机屏上没有可见收益。
int imageDecodeWidthFor(BuildContext context, double logicalWidth) {
  final dpr = MediaQuery.devicePixelRatioOf(context);
  final needed = logicalWidth * dpr;
  final cap = logicalWidth * dpr * 1.5;
  return (needed <= cap ? needed : cap).ceil();
}

/// 头像在应用里的最大展示尺寸：列表行 40dp，气泡/顶栏 28–32dp。
const double kAvatarMaxDisplaySize = 40;

/// 头像的统一解码宽度：**固定**按最大展示尺寸算，不随所在位置变化。
///
/// 头像显示在 28/32/40dp 三种位置；如果各按自己的尺寸解码，同一个 URL 会在
/// `ImageCache` 里占三条 entry（@dpr3 是 84/96/120 px），LRU 压力凭空 ×3，
/// 而且从列表点进详情还要按新尺寸重新解码。统一到最大档位后一个 URL 只有一条，
/// 尺寸比像素略大的位置由 `BoxFit.cover` 缩放，肉眼无差。
int avatarDecodeWidthFor(BuildContext context) =>
    imageDecodeWidthFor(context, kAvatarMaxDisplaySize);
