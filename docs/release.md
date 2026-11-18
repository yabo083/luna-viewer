# 发布

## Android APK（GitHub Releases）

`.github/workflows/release.yml` 在推 `v*` tag 时构建并上传 APK。

签名是唯一需要自己配的部分：

1. 生成本地 keystore：`keytool -genkeypair -v -keystore release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias chatluna`
2. 转 base64：`base64 -w0 release.jks > keystore.b64`
3. 在仓库 Secrets 配四项：`KEYSTORE_B64`、`KEYSTORE_PASSWORD`、`KEY_ALIAS`、`KEY_PASSWORD`
4. 本地 `android/key.properties`（不入库）：

```properties
storeFile=../release.jks
storePassword=...
keyAlias=chatluna
keyPassword=...
```

工作流里在 build 前解出 keystore、写 `key.properties` 即可；没有 secrets 时只会产出 debug 签名包，仅适合内测。

标签格式：`v0.1.0`。版本号的两处来源必须一致——`pubspec.yaml` 的 `version:` 与 `lib/core/update/update_checker.dart` 的 `appVersion`。

## 更新检查

App 每天最多查一次 `https://api.github.com/repos/<owner>/repo/releases/latest`，比数字段；有新版本时弹 SnackBar 打开 release 页。仓库地址可被 `--dart-define=GH_REPO=owner/repo` 覆盖。

## 配套 npm 包

`packages/chatluna-plugin-media-bridge/` 是纯 ESM 单文件插件：

```bash
cd packages/chatluna-plugin-media-bridge
npm publish --access public
```

实例侧改 `chatluna.yml` 的 entry 为包名（或继续用 `file://` 指向本地副本），重启生效。

## iOS

Windows 上无法构建；需要 macOS + Xcode。工程已生成（`ios/`），Bundle id 与显示名已配，图标资源同 Android。
