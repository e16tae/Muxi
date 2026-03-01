# Architecture

Muxi uses a 4-layer architecture designed for cross-platform code sharing between iOS and Android.

## Layer Overview

```
┌──────────────────────────────────────────────────────────────┐
│                    UI Layer (SwiftUI)                         │
│  ServerListView, SessionListView, TerminalView,              │
│  ExtendedKeyboardView, PaneContainerView, QuickActionView    │
├──────────────────────────────────────────────────────────────┤
│                    App Layer (Swift)                          │
│  SessionListViewModel, ConnectionManager,                    │
│  SSHService, TmuxControlService, KeychainService             │
├──────────────────────────────────────────────────────────────┤
│                Bridge Layer (Swift ↔ C)                       │
│  MuxiCore SPM package — module maps + Swift wrappers         │
├──────────────────────────────────────────────────────────────┤
│                    Core Layer (C11)                           │
│  vt_parser (VT100/xterm), tmux_protocol (control mode)       │
└──────────────────────────────────────────────────────────────┘
```

## Layers in Detail

### UI Layer — `ios/Muxi/Views/`

Platform-specific SwiftUI views. Responsible for layout, user interaction, and visual presentation.

- **ServerList**: Server browsing and management
- **SessionList**: tmux session listing and selection
- **Terminal**: `TerminalView` wraps Metal rendering, `PaneContainerView` manages multi-pane layout
- **Common**: Shared UI components (`ErrorBannerView`, `ReconnectingOverlay`)
- **QuickAction**: One-tap tmux command buttons
- **ExtendedKeyboard**: Ctrl/Alt/arrow keys overlay

### App Layer — `ios/Muxi/ViewModels/` + `ios/Muxi/Services/`

Business logic, state management, and service coordination.

| Component | Responsibility |
|-----------|---------------|
| `SessionListViewModel` | Manages session list state, tmux session CRUD |
| `ConnectionManager` | SSH lifecycle, auto-reconnect with exponential backoff |
| `SSHService` | SSH connection abstraction (libssh2 wrapper planned) |
| `TmuxControlService` | Sends tmux commands, interprets control mode responses |
| `KeychainService` | Secure credential storage via iOS Keychain |

All ViewModels use `@MainActor @Observable` (iOS 17+). Services are injected via initializer.

### Bridge Layer — `ios/MuxiCore/`

SPM package that wraps the C core for use in Swift. Contains:

- Module maps exposing C headers to Swift
- Swift-friendly wrapper functions
- `extractString<T>` helper for C fixed-size char arrays

### Core Layer — `core/`

Pure C11 libraries with no platform dependencies. Designed for reuse on Android via JNI and on any platform with a C compiler.

| Library | Purpose | Prefix |
|---------|---------|--------|
| `vt_parser` | VT100/xterm escape sequence parser | `vt_` |
| `tmux_protocol` | tmux control mode output parser | `tmux_` |

Built with CMake for standalone testing and included in SPM via `MuxiCore`.

## Data Flow

### SSH Connection Flow

```
User taps server → ConnectionManager.connect()
  → SSHService.connect(host, port, credentials)
    → libssh2 session + channel
  → SSHService.execute("tmux -CC new -A -s muxi")
  → TmuxControlService starts parsing control mode output
    → tmux_protocol parser (C) extracts structured events
  → SessionListViewModel updates session/window/pane state
  → UI re-renders
```

### Terminal Rendering Flow

```
SSH channel receives data
  → vt_parser (C) processes escape sequences
  → TerminalBuffer updates cell grid
  → TerminalRenderer (Metal) renders glyph atlas
  → TerminalView displays via MTKView
```

### Input Flow

```
User types on keyboard / extended keyboard
  → InputHandler translates to terminal sequences
  → SSHService.send() writes to SSH channel
  → Remote tmux processes input
  → Output flows back via rendering pipeline
```

## Cross-Platform Strategy

```
                iOS (Swift/SwiftUI)        Android (Kotlin/Compose)
                       │                           │
                   Swift ↔ C                   JNI ↔ C
                       │                           │
                       └───────── C Core ──────────┘
                            vt_parser
                          tmux_protocol
```

The C core is intentionally minimal and dependency-free:
- No memory allocation in hot paths (caller provides buffers)
- No platform-specific includes
- C11 standard only
- Tested via SPM (Swift) and CMake (standalone)

## Directory Structure

```
Muxi/
├── core/                    # Cross-platform C libraries
│   ├── vt_parser/           # VT100/xterm parser
│   ├── tmux_protocol/       # tmux control mode parser
│   └── CMakeLists.txt       # Standalone C build
├── ios/                     # iOS application
│   ├── Muxi/                # App source code
│   │   ├── App/             # App entry point, ContentView
│   │   ├── Models/          # Data models (Server, Theme, TmuxModels)
│   │   ├── Resources/       # Themes (JSON), assets
│   │   ├── Services/        # SSH, tmux, Keychain services
│   │   ├── Terminal/        # Buffer, renderer, input handler, shaders
│   │   ├── ViewModels/      # @Observable view models
│   │   └── Views/           # SwiftUI views by feature
│   ├── MuxiCore/            # SPM package wrapping C core
│   ├── MuxiTests/           # Unit and integration tests
│   └── project.yml          # XcodeGen project definition
└── docs/                    # Documentation
```

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| tmux control mode over raw PTY | Structured output enables native pane management |
| Metal over CoreText | GPU rendering needed for smooth 60fps terminal scrolling |
| C11 over C++ for core | Simpler FFI, easier JNI bridging, smaller binary |
| SwiftData over Core Data | Modern API, `@Model` macros, better Swift integration |
| `@Observable` over `ObservableObject` | iOS 17+ only — simpler, more performant observation |
| XcodeGen over manual project | Avoids `.xcodeproj` merge conflicts in version control |
