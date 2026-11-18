import 'package:material_ui/material_ui.dart';

import 'core/store/connection_store.dart';
import 'features/connect/connect_page.dart';
import 'features/sessions/sessions_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = ConnectionStore();
  final connection = await store.load();
  runApp(ChatLunaApp(store: store, initial: connection));
}

class ChatLunaApp extends StatefulWidget {
  const ChatLunaApp({super.key, required this.store, this.initial});

  final ConnectionStore store;
  final Connection? initial;

  @override
  State<ChatLunaApp> createState() => _ChatLunaAppState();
}

class _ChatLunaAppState extends State<ChatLunaApp> {
  Connection? _connection;

  @override
  void initState() {
    super.initState();
    _connection = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF5B8DEF),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'ChatLuna',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF0B0D10),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      home: _connection == null
          ? ConnectPage(
              store: widget.store,
              onConnected: (connection) => setState(() => _connection = connection),
            )
          : SessionsPage(
              connection: _connection!,
              onDisconnect: () async {
                await widget.store.clear();
                setState(() => _connection = null);
              },
            ),
    );
  }
}
