# Contributing

Use an Apple Silicon Mac, macOS 15+ and Apple's Command Line Tools. Keep changes focused on recording, simple cuts and editable framing.

## Build and check

```sh
CODE_SIGN_IDENTITY=- bash build.sh
APP="dist/Auto Recorder.app/Contents/MacOS/AutoRecorder"
"$APP" --geometry-test
"$APP" --permission-test
"$APP" --project-test "$(mktemp -d "${TMPDIR:-/tmp}/auto-recorder-project.XXXXXX")"
"$APP" --pause-test "$(mktemp -d "${TMPDIR:-/tmp}/auto-recorder-pause.XXXXXX")"
```

These checks use synthetic media. Hardware and UI checks need a logged-in desktop and the relevant permissions. Run the checks affected by your change; verify preview/export agreement and protect original recordings.

## Contributions

- Explain the change and validation.
- Keep generated files, credentials, personal paths and private recordings out of Git.
- Add a meaningful regression check for behavior fixes; use screenshots without private content for visual changes.
- Keep user-facing copy focused on actions, not implementation history or design trade-offs.
- The AI-generated icon's PNG is the editable source; ICNS contains native app sizes. Keep both when updating the icon.

Contributions use [GPL-3.0-only](LICENSE). See [release instructions](docs/RELEASING.md) for packaging.
