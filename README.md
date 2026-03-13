# Muxi

> A tmux-focused mobile terminal app with native pane rendering

[![Core Tests](https://github.com/e16tae/Muxi/actions/workflows/test-core.yml/badge.svg)](https://github.com/e16tae/Muxi/actions/workflows/test-core.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org)
[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-green.svg)](https://developer.apple.com/ios/)

## What is Muxi?

Muxi connects to remote servers via SSH and uses **tmux control mode** (`tmux -CC`) to render each tmux pane as a native iOS view. Instead of emulating a single terminal screen, Muxi understands tmux's window/pane structure and renders them with native UI controls, adaptive layouts, and GPU-accelerated terminal output.

## Features

- **Real SSH connections** — libssh2 with password and key authentication
- **tmux control mode** — Structured session/window/pane management via `tmux -CC`
- **Session management** — Auto-attach, session switching, create/rename/delete
- **Window & pane management** — Multi-window support with split panes
- **Native pane rendering** — Each tmux pane is a dedicated SwiftUI view
- **Metal GPU rendering** — Retina glyph atlas for sharp text at device scale factor
- **Cursor styles** — Block, underline, bar cursors with blink support (DECSCUSR)
- **VT100/xterm parser** — Cross-platform C parser for terminal escape sequences
- **Korean & CJK input** — Native non-ASCII input via `send-keys -l`
- **Clipboard paste** — Long-press paste with proper tmux escaping
- **Adaptive layout** — Automatic pane arrangement for phone, tablet, and split screen
- **Extended keyboard** — Ctrl, Alt, arrow keys, and common shortcuts
- **Quick actions** — One-tap tmux commands (new window, split, detach)
- **Server management** — SwiftData persistence with Keychain-secured credentials
- **Auto-reconnect** — Automatic SSH reconnection with exponential backoff
- **App lifecycle** — Background detach, foreground reconnect

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

# First-time setup: download fonts + build OpenSSL + libssh2
./scripts/build-all.sh

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

## Contributing

Contributions are welcome! Please read our [Contributing Guide](CONTRIBUTING.md) and [Code of Conduct](CODE_OF_CONDUCT.md) before submitting a pull request.

## License

Muxi is released under the [MIT License](LICENSE).
