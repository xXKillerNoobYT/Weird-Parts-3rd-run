# Dev setup (Cursor / VS Code + Flutter)

Local-first Flutter app lives in `app/`. Spec and phases: `roadmap.md`, `docs/superpowers/`.

## Prerequisites

1. **Flutter SDK** — this machine typically uses `C:\Users\weird\flutter`.
   - Add `C:\Users\weird\flutter\bin` to your user `PATH`, or rely on `.vscode/settings.json` (`dart.flutterSdkPath`).
2. **Windows Developer Mode** (required for `flutter run -d windows` when plugins use symlinks):
   - Settings → System → For developers → **Developer Mode** → On
   - Without it, Windows builds often fail creating plugin symlink junctions.
3. Open this **repo root** in Cursor/VS Code (not only `app/`) so launch configs and rules apply.

Recommended extensions: Dart + Flutter (see `.vscode/extensions.json`).

## Debug (F5)

1. Open the workspace root.
2. Install recommended extensions if prompted.
3. Pick a launch config (Run and Debug):
   - **wired_parts (Windows)** — primary desktop target
   - **wired_parts (Chrome)** — quick UI iteration (not a v1 ship target); enable once with `cd app && flutter create . --platforms=web` if `app/web` is missing
   - profile / release variants for Windows when needed
4. Press **F5** (or Start Debugging).

First Windows run may take a while (CMake / NuGet). If symlink errors appear, enable Developer Mode and retry.

## CLI

```powershell
# PATH for this shell if Flutter is not on PATH yet
$env:Path = "C:\Users\weird\flutter\bin;" + $env:Path

cd app
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

### Drift codegen

After changing tables/DAOs under `app/lib/data/`:

```powershell
cd app
dart run build_runner build --delete-conflicting-outputs
```

Or run the **drift: build_runner** / **drift: build_runner watch** tasks from the Command Palette → *Tasks: Run Task*.

### Useful tasks

| Task | Purpose |
|------|---------|
| `flutter: analyze` | Static analysis / problem finding |
| `flutter: test` | Unit / widget tests |
| `drift: build_runner` | Regenerate `*.g.dart` |
| `flutter: pub get` | Refresh packages |

## Cursor project rules

- `.cursor/rules/wired-parts-foundation.mdc` — always-on scope (local-first, PIN, don’t overbuild end-goal)
- `.cursor/rules/flutter-dart.mdc` — when editing `app/**/*.dart`

## Problem finding

- Analyzer: Problems panel + `flutter analyze` (stricter options in `app/analysis_options.yaml`)
- Tests: `flutter test` or the `flutter: test` task
- Debug: breakpoints in Dart sources under `app/lib/` (not hand-edited `*.g.dart`)
