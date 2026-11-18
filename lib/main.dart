import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/store/connection_store.dart';
import 'features/connect/connect_page.dart';
import 'features/sessions/sessions_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

class _ChatLunaAppState extends State<ChatLunaApp> {
  Connection? _connection;
  late final ValueNotifier<ThemeMode> _themeMode = ValueNotifier(widget.themeMode);

  @override
  void initState() {
    super.initState();
    _connection = widget.initial;
  }

  @override
  void dispose() {
    _themeMode.dispose();
    super.dispose();
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
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF5B8DEF), brightness: brightness);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: brightness == Brightness.dark ? const Color(0xFF0B0D10) : null,
      inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), isDense: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _themeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'ChatLuna',
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
