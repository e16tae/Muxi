# Muxi — Claude Code Guidelines

Muxi is a tmux-focused mobile terminal app. iOS first (SwiftUI), Android later (Jetpack Compose). SSH via libssh2, tmux control mode (`tmux -CC`), per-pane native rendering.

## Build Commands

```bash
# Regenerate Xcode project (required after project.yml changes)
cd ios && xcodegen generate

# Run iOS app + unit tests
xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' \
  CODE_SIGNING_ALLOWED=NO

# Run core C library tests (via SPM)
swift test --package-path ios/MuxiCore

# Build core C library standalone
cmake -B core/build -S core && cmake --build core/build
```

## Quick Rules

- Use `@MainActor @Observable` for ViewModels — NOT `ObservableObject`/`@Published`
- Use `shellEscaped()` for all user input passed to SSH commands — never interpolate raw strings
- Use `line.withCString { ptr in ... }` when passing Swift strings to C parsers — pointer must not escape scope
- Use `extractString<T>` for C fixed-size char arrays → Swift String conversion
- Use Swift Testing (`@Suite`, `@Test`, `#expect`) for model/unit tests; XCTest only for UI or host-app tests
- Use SwiftData for server persistence, Keychain for secrets — never store passwords in SwiftData
- Prefix C functions: `vt_` for VT parser, `tmux_` for tmux protocol

## Architecture

4-layer stack — each layer only talks to the one below:

```
UI (SwiftUI Views)  →  App (ViewModels, Services)  →  Bridge (Swift↔C)  →  Core (C parsers)
```

- **UI**: SwiftUI views, adaptive layout (phone/tablet/split)
- **App**: `@Observable` ViewModels, `ConnectionManager`, `SSHService`, `TmuxControlService`
- **Bridge**: Swift wrappers around C APIs, `MuxiCore` SPM package
- **Core**: `vt_parser` (VT100/xterm), `tmux_protocol` (control mode parser) — pure C11, no platform deps

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for full details.

## Detailed Guidelines

| Topic | Guide |
|-------|-------|
| Swift style | [docs/guides/swift-style.md](docs/guides/swift-style.md) |
| C style | [docs/guides/c-style.md](docs/guides/c-style.md) |
| Testing | [docs/guides/testing.md](docs/guides/testing.md) |
| Git workflow | [docs/guides/git-workflow.md](docs/guides/git-workflow.md) |
| Architecture | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Development setup | [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) |
| Release process | [docs/RELEASE.md](docs/RELEASE.md) |

## Architecture Decisions

- **tmux control mode** (`-CC`): Structured output instead of raw terminal escape parsing for session management
- **Metal rendering**: GPU-accelerated glyph atlas for smooth terminal scrolling on mobile
- **Cross-platform C core**: VT parser and tmux protocol parser are pure C for reuse on Android (via JNI)
- **SwiftData over Core Data**: Modern persistence with `@Model` macros, better Swift integration
- **SPM for C integration**: `MuxiCore` package wraps C sources with proper module maps

## Security

- All SSH commands must use `shellEscaped()` — command injection is the #1 risk
- Never log passwords or private keys, even at debug level
- Keychain is the only acceptable storage for secrets — enforce via code review
