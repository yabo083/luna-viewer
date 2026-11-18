import 'package:flutter/material.dart';

import '../../core/model/models.dart';
import '../../core/store/connection_store.dart';
import '../../core/transport/api_client.dart';

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key, required this.store, required this.onConnected});

  final ConnectionStore store;
  final ValueChanged<Connection> onConnected;

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _base = TextEditingController();
  final _token = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.store.lastBase().then((uri) {
      if (uri != null && mounted && _base.text.isEmpty) {
        _base.text = '${uri.host}:${uri.port}';
      }
    });
  }

  @override
  void dispose() {
    _base.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final base = normalizeBase(_base.text);
    final token = _token.text.trim();
    if (base == null) {
      setState(() => _error = '地址格式不对，例如 192.168.0.107:5028');
      return;
    }
    if (token.isEmpty) {
      setState(() => _error = '需要实例 token（WebUI 的 ?token= 或 data/auth.json）');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final health = await ApiClient.health(base);
      final api = ApiClient(base: base, token: token);
      try {
        await api.getJson('/api/auth/session');
      } finally {
        api.close();
      }
      await widget.store.save(Connection(base: base, token: token));
      if (!mounted) return;
      widget.onConnected(Connection(base: base, token: token));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已连接 ${health.name} ${health.version}')),
      );
    } on ApiFailure catch (e) {
      setState(() => _error = _describe(e));
    } catch (e) {
      setState(() => _error = '连接失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _describe(ApiFailure e) => switch (e.code) {
    'UNAUTHORIZED' => 'token 不对（服务端返回 401）',
    'NETWORK' => '连不上：${e.message}',
    'TIMEOUT' => '连接超时，检查地址与网络',
    _ => '${e.code}：${e.message}',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('ChatLuna', style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 4),
                  Text(
                    '连接到你自己的实例',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _base,
                    autofocus: true,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '实例地址',
                      hintText: '192.168.0.107:5028 或 https://bot.example.com',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _token,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '访问 token',
                      hintText: '实例 token 或登录得到的 session',
                    ),
                    onSubmitted: (_) => _busy ? null : _connect(),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _connect,
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('连接'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
