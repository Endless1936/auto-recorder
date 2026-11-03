# Auto Recorder

[中文](README.md) · English

[Download latest](https://github.com/Endless1936/auto-recorder/releases/latest) · [All releases](https://github.com/Endless1936/auto-recorder/releases)

A native Mac screen recorder with automatic cursor-following zoom and lightweight editing. Record locally, adjust the framing, cut out unwanted parts, and export. The current app interface is in Chinese.

## Requirements

- **Apple Silicon Mac (M-series), macOS 15 or later.** Intel Macs are not currently supported.
- No developer tools or additional runtime are needed to use a downloaded app.

## Install

1. Open this repository's [Releases](https://github.com/Endless1936/auto-recorder/releases) and download the `macos-arm64.dmg` asset. GitHub's **Source code** archives contain source files, not an installed app.
2. Open the disk image and drag **Auto Recorder.app** onto **Applications**.
3. Eject the disk image and open Auto Recorder from Applications.

If a release also provides a ZIP, extract it and move **Auto Recorder.app** into Applications yourself. Opening an app in Downloads does not install it in Applications.

This release is **Developer ID signed and intentionally not Apple-notarized**. Users do not need a developer account or keychain configuration. If macOS blocks the first launch, confirm the download came from this project's Release, try opening the app once, then go to **System Settings → Privacy & Security → Open Anyway** and confirm **Open**. Allowing the app to run is separate from granting screen-recording permission. See Apple's [Open Anyway instructions](https://support.apple.com/en-us/102445). Notarization is an optional maintainer step, not a requirement for using this release; each release states its signing status.

On first use, allow **Screen & System Audio Recording**. Microphone access is requested separately when enabled. macOS may also ask for access to the chosen save folder. Restart the app if macOS requests it.

To update, quit Auto Recorder and replace the app in Applications. Recording projects are stored separately and are not removed by replacing the app. To uninstall, quit and move the app to Trash; remove your recording projects separately if desired.

## What it does

- Records an entire screen, a window, or a selected region, with independent system-audio and microphone switches.
- Pauses, resumes, and stops from the menu bar. Shortcuts: **⌘⇧R** to start/stop and **⌘⇧P** to pause/resume.
- Saves each recording in a dated folder containing the original `.mov` and editable `project.json`.
- Splits, trims, deletes, and reorders clips on one timeline, with Undo.
- Edits zoom timing, magnification, and movement using curve points and a draggable framing overlay; supports multiple nodes and group selection.
- Exports HEVC or ProRes 422 at the recorded dimensions, with 30/60 fps recording options.

Keep the original video and `project.json` together. You can move or rename the complete project folder and reopen it later. Edits save automatically; **Export Video** creates the finished video.

This is a recorder with simple cuts and framing controls. It has no effects, transitions, music, or multitrack editing. The cursor is part of the original video and cannot be edited independently. Zooming crops the source image; it does not add detail.

Recordings, audio, and project files stay on your Mac. The app has no upload service or telemetry.

## Build from source

Use an Apple Silicon Mac running macOS 15 or later. Install Apple's Command Line Tools if needed:

```sh
xcode-select --install
CODE_SIGN_IDENTITY=- bash build.sh
```

The result is `dist/Auto Recorder.app`. This uses a local ad-hoc signature; it does not inherit the publisher's signature or macOS permissions.

Install your build with:

```sh
bash install.sh
# Or install only for your user:
INSTALL_DIR="$HOME/Applications" bash install.sh
```

Quit the installed app before replacing it. The installer does not use `sudo` or bypass macOS security checks.

Source lives in `Sources/`, test code in `Tests/`, and generated apps and packages in ignored output directories. See [CONTRIBUTING.md](CONTRIBUTING.md) for checks and [release instructions](docs/RELEASING.md) for Developer ID signing, packaging, and optional Apple notarization. CI builds are development builds, not public releases.

## License

[GNU GPL version 3 only](LICENSE) (`GPL-3.0-only`). When redistributing the app, retain the license and provide the matching complete source as required by the GPL. Release downloads include a matching source archive.

The mint cursor-and-trail icon in `Assets/` was generated with AI and selected for this project; its generation prompt is recorded in [Assets/README.md](Assets/README.md).
