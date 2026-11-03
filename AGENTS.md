# Auto Recorder

Native Swift/AppKit/SwiftUI recorder for Apple Silicon and macOS 15+. Use project-relative paths; there are no third-party runtime dependencies.

- App code is in `Sources/`; executable regression fixtures are in `Tests/`.
- Keep the product focused on recording, simple cuts and editable camera motion. Preserve approved UI and original media/trace data.
- Keep bundle identifier `local.prototech.screenrecorder` and signing identity stable for existing users. Never reset system privacy permissions or disable Gatekeeper.
- Local build: `CODE_SIGN_IDENTITY=- bash build.sh`. Use a temporary output directory if `dist/` contains a signed release. See `CONTRIBUTING.md` for checks and `docs/RELEASING.md` for public signing/notarization.
- Run checks relevant to the change. UI, screen and microphone tests need a foreground desktop and explicit system authorization; do not run them silently in CI.
- Generated apps, recordings, local verification reports, credentials and private signing keys do not belong in Git. See `.gitignore`.
- Keep user-facing copy limited to actions and necessary recovery steps; omit implementation history and design trade-offs.
- After release assets are published and verified, remove redundant local build/release copies and reports. Keep installed apps and user recording projects.
- Install instructions for users belong in `README.md`, not here. Only install or publish when the user has asked for it.
- Contributions are licensed under GPL-3.0-only. Release binaries must be accompanied by matching complete source, license and build instructions.
