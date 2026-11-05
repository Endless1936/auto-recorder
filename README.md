<h1 align="center"><img src="Assets/AppIcon.png" alt="Auto Recorder 图标" width="48" align="absmiddle"> Auto Recorder</h1>

## 🤖 让 Agent 帮你安装

复制这段给 **Codex 或能操作本机的 Agent**：

```text
请帮我安装 Auto Recorder 官方最新稳定版：
https://github.com/Endless1936/auto-recorder/releases/latest

先检查这台 Mac 是 Apple Silicon 且运行 macOS 15+，不满足就说明并停止。
从官方 Release 下载对应 DMG，核对安装包对应的 SHA256 和应用签名。
安装到 /Applications；无权限则用 ~/Applications。
已有安装先确认属于本项目，最新版检查后直接打开。
更新前让我退出应用，保留录屏、工程和设置。
本应用已签名但未公证，遇到“仍要打开”或录屏／麦克风授权时引导我确认。
不关闭安全检查、不移除隔离属性，也不安装开发环境。
完成后告知版本和路径；没有操作本机的能力时请如实说明。
```

## 🎬 为演示而录制

Auto Recorder 是一款本地 Mac 录屏工具，适合制作 AI 工具演示、软件教程和产品展示。录制时跟随操作自动放大，完成后可以简单剪切并调整取景。

## ✨ 功能亮点

- 🖥️ **灵活录制** — 录制整个屏幕、单个窗口或选定区域，记住上次确认的选区。
- 🎯 **自动聚焦** — 点击时放大，跟随鼠标移动；静止后平滑回到全景。
- ✂️ **轻量编辑** — 在时间轴中分割、裁剪、删除和重排片段，调整放大曲线与取景位置。
- 🎙️ **声音由你选择** — 独立控制电脑音频和麦克风，录制中可从菜单栏暂停或继续。
- 📁 **保留可编辑工程** — 原片和工程保存在本地文件夹，可以随时打开继续编辑，再导出视频。
- 🎞️ **画质选择** — 支持 HEVC、ProRes 422，以及 30 或 60 fps。

## 🚀 开始使用

1. 选择录制范围和音源，按下“开始录制”。
2. 完成演示后停止录制，在编辑器中调整片段与取景。
3. 导出视频，或保留工程以便下次继续编辑。

## 🍎 手动安装

适用 Apple Silicon（M1 及更新芯片）和 macOS 15 或更高版本，界面为中文。

下载 [Auto Recorder 2.4.3](https://github.com/Endless1936/auto-recorder/releases/download/v2.4.3/Auto-Recorder-v2.4.3-macos-arm64.dmg)，打开后将 App 拖入“应用程序”。首次打开若被拦截，前往“系统设置 → 隐私与安全性 → 仍要打开”，再按提示授权录屏。

📖 [使用说明](docs/USAGE.md) · [开发与贡献](CONTRIBUTING.md) · [GPL-3.0-only](LICENSE) · [English](README.en.md)
