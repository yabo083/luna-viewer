import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/design/app_tokens.dart';
import 'core/store/connection_store.dart';
import 'features/connect/connect_page.dart';
import 'features/sessions/sessions_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 解码后的位图是 PSS 里最大的一块「可控」内存：ImageCache 默认允许
  // 100MB / 1000 张，长会话滚一遍就把整段历史缩略图全留在内存里（退页也不还）。
  // 48MB / 80 张 = 当前屏 + 前后一两屏；配合各处的 `cacheWidth`，
  // 长会话的峰值由「字节上限」决定，而不是由图片数量决定。
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = 80;
  imageCache.maximumSizeBytes = 48 << 20;
  final store = ConnectionStore();
  final connection = await store.load();
  final prefs = await SharedPreferences.getInstance();
  final mode = switch (prefs.getString('theme.mode')) {
    'light' => ThemeMode.light,
    'system' => ThemeMode.system,
    _ => ThemeMode.dark,
  };
  runApp(ChatLunaApp(store: store, initial: connection, themeMode: mode));
}

class ChatLunaApp extends StatefulWidget {
  const ChatLunaApp({super.key, required this.store, required this.themeMode, this.initial});

  final ConnectionStore store;
  final Connection? initial;
  final ThemeMode themeMode;

  @override
  State<ChatLunaApp> createState() => _ChatLunaAppState();
}

class _ChatLunaAppState extends State<ChatLunaApp> with WidgetsBindingObserver {
  Connection? _connection;
  late final ValueNotifier<ThemeMode> _themeMode = ValueNotifier(widget.themeMode);

  /// 切后台后 60s 才丢解码位图：短时间的 HOME/切到别的 App 不清缓存，
  /// 回来时头像与气泡图片仍在，不会「重新下载 + 重新解码」闪一遍。
  Timer? _backgroundTrim;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connection = widget.initial;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backgroundTrim?.cancel();
    _themeMode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _backgroundTrim?.cancel();
      _backgroundTrim = null;
      return;
    }
    if (state != AppLifecycleState.paused) return;
    _backgroundTrim ??= Timer(const Duration(seconds: 60), () {
      _backgroundTrim = null;
      // 真后台超过 60s：屏幕不可见，清掉 LRU 里的解码位图；正在显示的
      // Widget 仍持有自己的 ImageInfo，所以回来第一帧不会变空。
      PaintingBinding.instance.imageCache.clear();
    });
  }

  @override
  void didHaveMemoryPressure() {
    // 系统已经在回收：解码位图是最大的一块可控内存，直接交还。
    PaintingBinding.instance.imageCache.clear();
  }

  Future<void> _setTheme(ThemeMode mode) async {
    _themeMode.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme.mode', switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
      ThemeMode.dark => 'dark',
    });
  }

  ThemeData _theme(Brightness brightness) {
    final colors = AppColors.of(brightness);
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF5B8DEF),
      brightness: brightness,
      surface: colors.canvas,
      surfaceContainerLowest: colors.canvas,
      surfaceContainerLow: colors.surfaceL1,
      surfaceContainer: colors.surfaceL2,
      surfaceContainerHigh: colors.surfaceL3,
      onSurface: colors.textPrimary,
      onSurfaceVariant: colors.textSecondary,
      outline: colors.borderSubtle,
      outlineVariant: colors.borderDivider,
      primary: colors.accent,
      onPrimary: const Color(0xFFFFFFFF),
      primaryContainer: colors.bubbleOutBg,
      onPrimaryContainer: colors.bubbleOutText,
      error: colors.statusError,
    );
    TextStyle type(double size, double height, FontWeight weight,
            {double spacing = 0, bool tabular = false}) =>
        TextStyle(
          fontSize: size,
          height: height / size,
          fontWeight: weight,
          letterSpacing: spacing,
          color: colors.textPrimary,
          fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
        );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: colors.canvas,
      extensions: [colors],
      textTheme: TextTheme(
        titleMedium: type(16, 22, FontWeight.w600, spacing: -0.2),
        bodyMedium: type(14, 21, FontWeight.w400, spacing: 0.1),
        bodySmall: type(12, 16, FontWeight.w400, spacing: 0.2)
            .copyWith(color: colors.textSecondary),
        labelSmall: type(11, 14, FontWeight.w500, spacing: 0.3, tabular: true)
            .copyWith(color: colors.textSecondary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.tile),
          borderSide: BorderSide(color: colors.borderSubtle),
        ),
        isDense: true,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surfaceL2,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _themeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'Luna Viewer',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: mode,
        home: _connection == null
            ? ConnectPage(
                store: widget.store,
                onConnected: (connection) => setState(() => _connection = connection),
              )
            : SessionsPage(
                connection: _connection!,
                themeMode: _themeMode,
                onThemeChanged: _setTheme,
                onDisconnect: () async {
                  await widget.store.clear();
                  setState(() => _connection = null);
                },
              ),
      ),
    );
  }
}
