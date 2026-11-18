/// 应用元信息与更新检查。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

const appVersion = '0.1.0';

/// 开源后把默认值换成实际仓库；构建时也可 `--dart-define=GH_REPO=owner/repo` 覆盖。
const releaseRepo = String.fromEnvironment(
  'GH_REPO',
  defaultValue: 'yabo083/chatluna-mobile',
);

class UpdateInfo {
  const UpdateInfo({required this.version, required this.url});

  final String version;
  final Uri url;
}

class UpdateChecker {
  static const _timeout = Duration(seconds: 8);

  /// 查 GitHub Releases 最新 tag；失败（无网络、无 release、限流）返回 null，不打扰用户。
  static Future<UpdateInfo?> check({String current = appVersion}) async {
    final client = http.Client();
    try {
      final res = await client
          .get(
            Uri.parse('https://api.github.com/repos/$releaseRepo/releases/latest'),
            headers: {'accept': 'application/vnd.github+json'},
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final json = jsonDecode(res.body);
      if (json is! Map) return null;
      final tag = json['tag_name'];
      final html = json['html_url'];
      if (tag is! String || html is! String) return null;
      if (!isNewer(tag, current)) return null;
      return UpdateInfo(version: tag, url: Uri.parse(html));
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 只比数字段；`v0.2.0` 与 `0.2.0` 等价，预发布后缀忽略。
  static bool isNewer(String candidate, String current) {
    List<int> parse(String value) {
      final clean = value.replaceFirst(RegExp(r'^[vV]'), '').split('-').first;
      return [
        for (final part in clean.split('.'))
          int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0,
      ];
    }

    final a = parse(candidate);
    final b = parse(current);
    for (var i = 0; i < 3; i++) {
      final left = i < a.length ? a[i] : 0;
      final right = i < b.length ? b[i] : 0;
      if (left != right) return left > right;
    }
    return false;
  }
}
