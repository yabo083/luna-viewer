import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  final _tokenFocus = FocusNode();
  bool _busy = false;
  bool _tokenVisible = false;
  String? _baseError;
  String? _tokenError;

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
    _tokenFocus.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final base = normalizeBase(_base.text);
    final token = _token.text.trim();
    if (base == null) {
      setState(() {
        _baseError = '地址格式不对，例如 192.168.0.107:5028';
        _tokenError = null;
      });
      return;
    }
    if (token.isEmpty) {
      setState(() {
        _baseError = null;
        _tokenError = '需要实例 token（WebUI 的 ?token= 或 data/auth.json）';
      });
      _tokenFocus.requestFocus();
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _baseError = null;
      _tokenError = null;
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
      if (mounted) {
        setState(() => _showFailure(e));
        if (_tokenError != null) _tokenFocus.requestFocus();
      }
    } catch (e) {
      if (mounted) setState(() => _baseError = '连接失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 401 是 token 的问题，超时/网络属于地址；错误挂在出问题的那个字段下面。
  void _showFailure(ApiFailure e) {
    if (e.code == 'UNAUTHORIZED') {
      _tokenError = _describe(e);
      _baseError = null;
    } else {
      _baseError = _describe(e);
      _tokenError = null;
    }
  }

  String _describe(ApiFailure e) => switch (e.code) {
    'UNAUTHORIZED' => 'token 不对（服务端返回 401）',
    'NETWORK' => '连不上：${e.message}',
    'TIMEOUT' => '连接超时，检查地址与网络',
    _ => '${e.code}：${e.message}',
  };

  Future<void> _pasteInto(TextEditingController controller) async {
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    } on PlatformException {
      text = null;
    }
    if (!mounted) return;
    if (text == null || text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('剪贴板里没有文本')));
      return;
    }
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() {
      _baseError = null;
      _tokenError = null;
    });
    await HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.asset(
                          'assets/brand_icon.png',
                          width: 44,
                          height: 44,
                          filterQuality: FilterQuality.medium,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'ChatLuna',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '连接到你自己的实例',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _base,
                    autofocus: true,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    onSubmitted: (_) => _tokenFocus.requestFocus(),
                    onChanged: (_) {
                      if (_baseError != null) setState(() => _baseError = null);
                    },
                    decoration: InputDecoration(
                      labelText: '实例地址',
                      hintText: '192.168.0.107:5028',
                      errorText: _baseError,
                      errorMaxLines: 2,
                      prefixIcon: const Icon(Icons.dns_outlined),
                      suffixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                      suffixIcon: _FieldAction(
                        icon: Icons.content_paste,
                        tooltip: '粘贴地址',
                        onPressed: _busy ? null : () => _pasteInto(_base),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _token,
                    focusNode: _tokenFocus,
                    obscureText: !_tokenVisible,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _busy ? null : _connect(),
                    onChanged: (_) {
                      if (_tokenError != null) setState(() => _tokenError = null);
                    },
                    decoration: InputDecoration(
                      labelText: '访问 token',
                      hintText: '实例 token 或 session',
                      errorText: _tokenError,
                      errorMaxLines: 2,
                      prefixIcon: const Icon(Icons.key_outlined),
                      suffixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _FieldAction(
                            icon: _tokenVisible
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            tooltip: _tokenVisible ? '隐藏 token' : '显示 token',
                            onPressed: () => setState(() => _tokenVisible = !_tokenVisible),
                          ),
                          _FieldAction(
                            icon: Icons.content_paste,
                            tooltip: '粘贴 token',
                            onPressed: _busy ? null : () => _pasteInto(_token),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _connect,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 160),
                      child: _busy
                          ? Row(
                              key: const ValueKey('busy'),
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                const Text('连接中…'),
                              ],
                            )
                          : const Text('连接', key: ValueKey('idle')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 输入框尾部的小图标按钮：40px 热区，带 tooltip。
class _FieldAction extends StatelessWidget {
  const _FieldAction({required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }
}
