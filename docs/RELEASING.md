# 发布到 GitHub Releases

普通安装见 [README](../README.md)。本文件面向维护者；脚本不会创建仓库或自动上传 GitHub。

## 本地准备

本项目当前按 **已签名、未公证** 的方式发布，首次打开由用户在 macOS 中允许该应用运行。公证不作为本次发布前置条件，普通用户无需配置开发者账号或钥匙串。

1. 更新 `Info.plist` 的版本号和构建号，运行相关回归。
2. 保持现有 bundle identifier 和 Developer ID 签名身份，避免让老用户重新识别为另一个应用。
3. 用 Developer ID、Hardened Runtime、麦克风 entitlement 和安全时间戳构建：

```sh
BUILD_MODE=release bash build.sh
bash scripts/package-release.sh
```

产物位于 `dist/release/`：ARM64 DMG、匹配版本的完整源码包、SHA256 校验和及发布说明。默认不设置 `NOTARY_PROFILE`，发布说明会明确标记 **UNNOTARIZED**，安装说明会引导用户完成首次“仍要打开”及录屏授权。

默认打包目录中若已有同名产物，脚本会停止。测试或重新打包时指定一个新的空输出目录：

```sh
bash scripts/package-release.sh "dist/Auto Recorder.app" /你的新输出目录
```

## Apple 公证（可选）

只有维护者选择公证时才需要本节配置。它可以减少用户首次打开的拦截步骤，不是本项目发布的必做项。维护者需要有效 Developer ID 证书和 Apple 开发者账号的公证凭据；将凭据存入维护者本机钥匙串，不要写到项目、脚本或聊天中：

```sh
xcrun notarytool store-credentials auto-recorder
NOTARY_PROFILE=auto-recorder bash scripts/package-release.sh
```

仅设置 `NOTARY_PROFILE` 才会上传 DMG 到 Apple。脚本等待 Apple 接受、装订公证票据并验证 Gatekeeper；任何步骤失败都停止，不把它标记为已公证。

官方要求：[Apple 公证指南](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。

## 发布内容

- 将 DMG、同版本 `source.tar.gz`、`SHA256SUMS.txt` 和 `RELEASE-NOTES.md` 一起附到 GitHub Release。
- 源码仓库提交 `Sources/`、`Tests/*.swift`、图标、许可证、说明和构建脚本；`dist/`、证书私钥、录屏和本机报告由 `.gitignore` 排除。
- GPL-3.0-only 的二进制发行必须同时提供对应完整源码及许可证。不要只上传 DMG，也不要把 GitHub 自动生成的 Source code ZIP 当作预编译应用。
- CI 只做临时签名构建与合成测试；不使用发布证书、不录制桌面、不申请麦克风权限。

首次公开发布前，在另一台支持的 Mac 或全新用户环境验证：从浏览器下载、拖入“应用程序”、Gatekeeper、首次授权、短录制和导出。本机测试不能替代这一步。Intel Mac 当前不在支持范围内。
