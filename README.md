<p align="center"><img src="Assets/AppIcon.png" width="96" alt="Auto Recorder icon"></p>

# Auto Recorder

[English](README.en.md)

[下载最新版](https://github.com/Endless1936/auto-recorder/releases/latest) · [全部版本](https://github.com/Endless1936/auto-recorder/releases)

免费开源的原生 Mac 录屏工具，适合操作演示和教程。录制后可以简单剪切，并调整自动放大和镜头移动；视频、声音和工程保存在本机，不上传到服务器。

**系统要求：Apple Silicon（M1 或更新）、macOS 15 及以上。当前不提供 Intel 版。界面为中文。**

## 下载与安装

普通用户无需 Xcode、Homebrew 或命令行工具。

1. 在本项目的 [GitHub Releases](https://github.com/Endless1936/auto-recorder/releases) 中下载 `Auto-Recorder-v版本号-macos-arm64.dmg`。
2. 打开 DMG，将 **Auto Recorder.app 拖到 Applications（应用程序）图标**。
3. 推出 DMG，再从“应用程序”打开 Auto Recorder。

应用不会自动把自己复制到“应用程序”。如果拿到的是预编译应用 ZIP，解压后将其中的 `Auto Recorder.app` 拖入“应用程序”即可。GitHub 自动生成的 **Source code (zip)** 是源码，需要编译，不是可安装应用。

本版本采用 **Developer ID 签名、未公证** 的发布方式。普通用户不需要开发者账号或钥匙串配置。

如果首次打开被 macOS 拦截，确认下载来自本项目的 Release 后：

1. 先尝试打开一次应用。
2. 进入 **系统设置 → 隐私与安全性**，找到 Auto Recorder，点击 **仍要打开**。
3. 在再次出现的提示中点击 **打开**，再按下文授予录屏等权限。

“允许运行”与“允许录屏”是两项独立确认；为该应用允许例外后，之后通常可以直接打开。具体步骤见 [Apple 官方说明](https://support.apple.com/en-us/102445)。无需关闭 Gatekeeper。每个发行版的签名状态会写在 `RELEASE-NOTES.md`，Apple 公证是维护者可选的发布方式。

### 首次授权

- 允许“屏幕与系统音频录制”，用于采集选中的画面和电脑声音。
- 开启麦克风时，才申请麦克风权限。
- 默认保存到桌面的 `Auto Recorder` 文件夹，系统可能询问桌面文件夹访问权限；保存位置可以更改。
- 如果系统要求退出并重新打开，请按系统提示操作。无需完整磁盘访问或辅助功能权限。

### 更新与卸载

更新前停止录制并退出应用，再用新版本替换“应用程序”中的旧版本。卸载时将应用移入废纸篓即可；录屏工程由你自行保留或删除。

## 能做什么

- 全屏、单窗口或选区录制，电脑声音与麦克风独立开关，录前可看实时电平。
- 菜单栏计时、暂停／继续和停止；支持 HEVC／ProRes、30／60 fps。
- 自动跟随操作放大，录后可调整倍率、时机、缓动和取景位置。
- 单条时间轴上的分割、裁首尾、删除、重排及撤销。
- 取景框、带方向的运动路径、多锚点曲线、吸附对齐和框选批量调整。

没有特效、转场、音效、多轨或外部素材拼接。鼠标已录入原片，不能单独换指针样式；数字放大也不会增加源画面细节。

## 工程与导出

每次录制自动新建“录屏 年-月-日 时.分.秒”文件夹，内含原片 `.mov` 和 `project.json`。JSON 保存鼠标轨迹、镜头参数与剪切排序，修改自动保存，不改写原片。

将整份文件夹一起移动、备份或分享，之后用“打开工程”继续编辑；请保留原片与参数文件。旧版原片和匹配的 `.cursor.json` 也可导入。

“返回录制”保留工程并回到录制面板；**“导出视频”才生成最终成片**，可以选择名称与位置。取消导出会保留原片、工程及已有目标文件。

曲线左右拖动调整时机，上下拖动调整倍率；中间点独立变化，两个 1× 全景端点保留。选中节点时 Delete 删除节点，选中时间轴素材时删除素材。开启取景辅助层可拖框、拖路径点和缩放四角；辅助层不进入导出画面。

| 快捷键 | 操作 |
| --- | --- |
| ⌘⇧R | 开始／停止录制 |
| ⌘⇧P | 暂停／继续录制 |
| 空格 | 编辑器播放／暂停 |
| B | 在播放头分割 |
| Delete | 删除当前选择 |
| ⌘Z | 撤销 |

## 从源码构建

需要 Apple Silicon Mac、macOS 15+ 和 Apple Command Line Tools：

```sh
xcode-select --install
CODE_SIGN_IDENTITY=- bash build.sh
bash install.sh
```

产物为 `dist/Auto Recorder.app`。本地临时签名不需要开发者账号；自行构建的版本不会继承维护者签名，系统可能要求重新授权。

`install.sh` 只负责复制已构建的应用，不自动编译、提权、关闭正在运行的应用或关闭系统安全设置。无权写入系统“应用程序”时可安装到个人目录：

```sh
INSTALL_DIR="$HOME/Applications" bash install.sh
```

贡献与回归检查见 [CONTRIBUTING.md](CONTRIBUTING.md)，签名、公证和发布见 [docs/RELEASING.md](docs/RELEASING.md)。

## 许可证与图标

本项目采用 **GPL-3.0-only**，完整条款见 [LICENSE](LICENSE)。发行修改后的二进制时，请按 GPL 提供对应源码和许可证。

图标由内置 image_gen 工具生成，采用深石墨底与薄荷绿“鼠标跟随”图案；PNG 与原生多尺寸 ICNS 在 `Assets/`。
