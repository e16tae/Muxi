# Muxi

> A tmux-focused mobile terminal app with native pane rendering

[![iOS Tests](https://github.com/e16tae/Muxi/actions/workflows/test-ios.yml/badge.svg)](https://github.com/e16tae/Muxi/actions/workflows/test-ios.yml)
[![Core Tests](https://github.com/e16tae/Muxi/actions/workflows/test-core.yml/badge.svg)](https://github.com/e16tae/Muxi/actions/workflows/test-core.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org)
[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-green.svg)](https://developer.apple.com/ios/)

## What is Muxi?

Muxi connects to remote servers via SSH and uses **tmux control mode** (`tmux -CC`) to render each tmux pane as a native iOS view. Instead of emulating a single terminal screen, Muxi understands tmux's window/pane structure and renders them with native UI controls, adaptive layouts, and GPU-accelerated terminal output.

## Features

- **tmux control mode** — Structured session/window/pane management via `tmux -CC`
- **Native pane rendering** — Each tmux pane is a dedicated SwiftUI view
- **Metal GPU rendering** — Glyph atlas-based terminal rendering for smooth scrolling
- **VT100/xterm parser** — Cross-platform C parser for terminal escape sequences
- **Adaptive layout** — Automatic pane arrangement for phone, tablet, and split screen
- **Extended keyboard** — Ctrl, Alt, arrow keys, and common shortcuts
- **Quick actions** — One-tap tmux commands (new window, split, detach)
- **Server management** — SwiftData persistence with Keychain-secured credentials
- **Auto-reconnect** — Automatic SSH reconnection with exponential backoff
- **Error handling** — Non-intrusive banners and reconnection overlays

## Requirements

| Requirement | Version |
|-------------|---------|
| iOS | 17.0+ |
| Xcode | 15.0+ |
| tmux (on server) | 1.8+ (control mode) |
| XcodeGen | 2.35+ |

## Getting Started

```bash
# Clone the repository
git clone https://github.com/e16tae/Muxi.git
cd Muxi

# Generate Xcode project
cd ios && xcodegen generate

# Open in Xcode
open Muxi.xcodeproj
```

Build and run on an iOS Simulator or device. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for full setup instructions.

## Architecture

```
┌──────────────────────────────────────┐
│   UI Layer (SwiftUI)                 │  Views, keyboard, adaptive layout
├──────────────────────────────────────┤
│   App Layer (Swift)                  │  ViewModels, services, connection mgmt
├──────────────────────────────────────┤
│   Bridge Layer (Swift ↔ C)           │  MuxiCore SPM package
├──────────────────────────────────────┤
│   Core Layer (C11)                   │  vt_parser, tmux_protocol
└──────────────────────────────────────┘
```

Each layer only communicates with the one directly below it. The Core layer is pure C with no platform dependencies, designed for reuse on Android via JNI.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full architecture deep dive.

## Roadmap

| Version | Focus | Status |
|---------|-------|--------|
| **v0.1** | MVP — terminal rendering, tmux control, server management | Current |
| **v0.2** | Real SSH (libssh2), font bundling, theme settings | Planned |
| **v0.3** | iPad multitasking, keyboard shortcuts, iCloud sync | Planned |
| **v1.0** | Stable release, accessibility, localization | Future |
| **v2.0** | Android version (Jetpack Compose + shared C core) | Future |

## Contributing

Contributions are welcome! Please read our [Contributing Guide](CONTRIBUTING.md) and [Code of Conduct](CODE_OF_CONDUCT.md) before submitting a pull request.

## License

Muxi is released under the [MIT License](LICENSE).
