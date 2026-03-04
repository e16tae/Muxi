# tmux Install Detection Design

## Goal

Detect tmux availability after SSH connect. If tmux is not installed or the version is too old, show `TmuxInstallGuideView` with a retry option. No auto-install.

## Approach

In `ConnectionManager.connect()`, run `tmux -V` before `tmux list-sessions`. Parse the output to extract the version. If tmux is missing or below the minimum version (1.8), throw a `TmuxError`. ContentView catches the error and presents the existing `TmuxInstallGuideView` as a sheet.

## Flow

```
SSH connect
  → execCommand("tmux -V")
  → Parse output: "tmux X.Y"
  → Version ≥ 1.8? → proceed to list-sessions (normal flow)
  → Version < 1.8? → throw TmuxError.versionTooOld("X.Y")
  → Empty / parse failure? → throw TmuxError.notInstalled
  → ContentView catches TmuxError → show TmuxInstallGuideView sheet
  → User installs tmux externally → taps "Retry" → connectToServer() again
```

## Files

- Create: `ios/Muxi/Models/TmuxError.swift` — `TmuxError` enum with `notInstalled` and `versionTooOld`
- Modify: `ios/Muxi/Services/ConnectionManager.swift` — add `tmux -V` check in `connect()`, add `validateTmuxVersion()` private method
- Modify: `ios/Muxi/App/ContentView.swift` — catch `TmuxError`, show `TmuxInstallGuideView` sheet with retry

## TmuxError

```swift
enum TmuxError: Error, LocalizedError {
    case notInstalled
    case versionTooOld(detected: String)
}
```

Maps to existing `TmuxInstallGuideView.Reason`:
- `.notInstalled` → `.notInstalled`
- `.versionTooOld(detected:)` → `.versionTooOld(detected:)`

## Version Parsing

`tmux -V` outputs: `"tmux 3.4\n"` or `"tmux 3.3a\n"` (letter suffix possible).

Parse strategy:
1. Trim whitespace, check for "tmux " prefix
2. Extract version string after "tmux "
3. Split on "." to get major.minor (ignore letter suffixes like "3.3a" → 3.3)
4. Compare against minimum version 1.8
5. Empty output or parse failure → `.notInstalled`

## Error Handling Edge Cases

- `execCommand("tmux -V")` throws (non-zero exit, channel error) → treat as `.notInstalled`
- Output contains unexpected format → treat as `.notInstalled`
- Version string has letter suffix ("3.3a") → strip non-numeric suffix, parse numeric part

## ContentView Integration

- Add `@State private var tmuxError: TmuxError?` and `@State private var showTmuxGuide = false`
- In `connectToServer()` catch block, check for `TmuxError` specifically
- Present `TmuxInstallGuideView` as `.sheet(isPresented: $showTmuxGuide)`
- Sheet includes existing install guide content + "Retry" button that dismisses and calls `connectToServer()` again

## Out of Scope

- Auto-install tmux via SSH
- SSH terminal mode without tmux
- sudo password handling
- OS detection for package manager selection
