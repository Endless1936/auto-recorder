# Contributing

Use an Apple Silicon Mac with macOS 15 or later and Apple's Command Line Tools. The UI currently uses Chinese. Keep changes focused on screen recording, simple cuts, and editable framing.

## Build and check

```sh
CODE_SIGN_IDENTITY=- bash build.sh
APP="dist/Auto Recorder.app/Contents/MacOS/AutoRecorder"
"$APP" --geometry-test
"$APP" --permission-test
"$APP" --project-test "$(mktemp -d "${TMPDIR:-/tmp}/auto-recorder-project.XXXXXX")"
"$APP" --pause-test "$(mktemp -d "${TMPDIR:-/tmp}/auto-recorder-pause.XXXXXX")"
```

Use fresh test directories. These checks create synthetic media; they do not require permission to capture the screen or microphone. Hardware capture, audio preview, and native UI checks need a real logged-in desktop and the relevant macOS permissions, and are separate from CI.

For a change, run the checks that exercise its behavior. For recording or editor changes, also verify the affected flow in the app. Protect the original recording, keep project-folder portability, and check that preview and export agree after edits.

## Pull requests

- Explain the problem, the resulting behavior, and what you tested.
- Keep generated apps, installers, recordings, local reports, credentials, and personal paths out of commits.
- Add or update a regression check when fixing behavior that can be tested meaningfully.
- For visual changes, include a screenshot without private recording content.

Contributions are distributed under this project's [GPL-3.0-only license](LICENSE). Only contribute material you have the right to license under those terms. No contributor license agreement is required.

## Releases

See [docs/RELEASING.md](docs/RELEASING.md). Public packages need their matching source archive and license. A successful CI build is not a notarized release or proof of installation on another Mac.
