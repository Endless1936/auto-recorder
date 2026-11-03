# 发布

1. 更新 `Info.plist` 中的版本、构建号和 README 的手动下载链接。
2. 运行相关回归，验证下载、安装、授权、短录制和导出。
3. 保持 bundle identifier 和开发者签名身份稳定，构建并打包：

```sh
BUILD_MODE=release bash build.sh
bash scripts/package-release.sh
```

将 `dist/release/` 中的 DMG、对应源码包、校验和及发布说明一起附到 GitHub Release。GPL-3.0-only 发行须提供匹配的完整源码与许可证。

默认使用 Developer ID 签名、未公证。重新打包时使用新的空输出目录：

```sh
bash scripts/package-release.sh "dist/Auto Recorder.app" /你的新输出目录
```

需要 Apple 公证时，先在维护者钥匙串中配置凭据，再运行：

```sh
NOTARY_PROFILE=配置名称 bash scripts/package-release.sh
```

[Apple 公证文档](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

证书私钥、凭据、录屏和本机报告不得提交。发布并校验附件后，移除本地多余产物。
