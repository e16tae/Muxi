# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-03-01

### Added

- **Terminal rendering**: Metal GPU-accelerated terminal view with glyph atlas
- **VT100/xterm parser**: Cross-platform C parser for terminal escape sequences
- **tmux control mode**: Protocol parser for `tmux -CC` structured output
- **Server management**: Add, edit, delete servers with SwiftData persistence
- **Keychain integration**: Secure credential storage for passwords and SSH keys
- **Session management**: List, attach, detach tmux sessions
- **Adaptive layout**: Automatic pane arrangement for different screen sizes
- **Extended keyboard**: Ctrl, Alt, arrow keys, and common terminal shortcuts
- **Quick actions**: One-tap tmux commands (new window, split pane, detach)
- **Auto-reconnect**: SSH reconnection with exponential backoff
- **Error handling**: Non-intrusive error banners and reconnection overlays
- **Catppuccin Mocha theme**: Default terminal color scheme
- **Comprehensive test suite**: 133 tests across app and core layers

[0.1.0]: https://github.com/e16tae/Muxi/releases/tag/v0.1.0
