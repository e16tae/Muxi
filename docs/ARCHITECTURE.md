# Architecture

Muxi uses a 4-layer architecture designed for cross-platform code sharing between iOS and Android.

## Layer Overview

```
┌──────────────────────────────────────────────────────────────┐
│                    UI Layer (SwiftUI)                         │
│  ServerListView, TerminalSessionView, TerminalView,          │
│  ToolbarView, PlusMenuView, SessionPillsView,                │
│  WindowPanePillsView, ExtendedKeyboardView, PaneContainerView│
├──────────────────────────────────────────────────────────────┤
│                    App Layer (Swift)                          │
│  ConnectionManager, SSHService (libssh2 actor),              │
│  TmuxControlService, KeychainService,                        │
│  LastSessionStore, ThemeManager                               │
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
- **TerminalSession**: Main terminal view with toolbar, session/window/pane pills
- **Terminal**: `TerminalView` wraps Metal rendering, `PaneContainerView` manages multi-pane layout
- **Toolbar**: `ToolbarView`, `PlusMenuView` for session/window/pane creation
- **Navigation pills**: `SessionPillsView`, `WindowPanePillsView` for switching
- **Common**: Shared UI components (`ErrorBannerView`, `ReconnectingOverlay`)
- **QuickAction**: One-tap tmux command buttons
- **ExtendedKeyboard**: Ctrl/Alt/arrow keys overlay

### App Layer — `ios/Muxi/ViewModels/` + `ios/Muxi/Services/`

Business logic, state management, and service coordination.

| Component | Responsibility |
|-----------|---------------|
| `ConnectionManager` | SSH lifecycle, auto-reconnect, session/window/pane state, tmux command routing |
| `SSHService` | libssh2 actor — POSIX socket, session, channel management |
| `TmuxControlService` | Parses tmux control mode output, dispatches structured events |
| `KeychainService` | Secure credential storage via iOS Keychain |
| `LastSessionStore` | Persists last-used session per server (UserDefaults) |
| `ThemeManager` | Terminal color theme management |

All ViewModels use `@MainActor @Observable` (iOS 17+). SSHService is a Swift `actor`.

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
    → POSIX socket → libssh2 session + handshake + auth
  → SSHService.execCommand("tmux -V")  // version check
  → SSHService.execCommand("tmux list-sessions")
  → Auto-select session (last-used > first > create new)
  → SSHService.startShell() → PTY channel
  → "tmux -CC attach -t <session>"
  → TmuxControlService starts parsing control mode output
    → tmux_protocol parser (C) extracts structured events
  → ConnectionManager updates session/window/pane state
  → UI re-renders
```

### Window/Pane State Machine (ADR-0008)

`ConnectionManager.windowPaneState` tracks the layout lifecycle:

```
disconnect / session-switch → awaitingLayout

awaitingLayout ── first %layout-change ──→ active

active ── selectWindow / sessionWindowChanged ──→ switchingWindow
active ── mobileAutoZoom + unzoomed multi-pane ──→ autoZooming

switchingWindow ── matching %layout-change ──→ active
switchingWindow ── stale %layout-change ─────→ (ignored)

autoZooming ── zoomed %layout-change ───→ active
autoZooming ── timeout (2s) ────────────→ active (fallback)
```

Strong-typed IDs (`PaneID`, `WindowID`, `SessionID`) prevent accidental mixups at compile time.

### Terminal Rendering Flow

```
SSH channel receives data
  → TmuxControlService dispatches pane output
  → vt_parser (C) processes escape sequences
    → Including DECTCEM (cursor visibility), DECSCUSR (cursor shape)
  → TerminalBuffer updates cell grid + cursor state
  → TerminalRenderer (Metal) renders Retina glyph atlas
    → Rasterized at contentScaleFactor for sharp text
    → Cursor shape: block/underline/bar, hollow when unfocused
  → TerminalView displays via MTKView (on-demand redraw)
```

### Input Flow

```
User types on keyboard / extended keyboard
  → ASCII: send-keys -t %N <hex bytes>
  → Non-ASCII (Korean, CJK): send-keys -l -t %N "<literal text>"
  → Clipboard paste: set-buffer + paste-buffer (tmuxQuoted escaping)
  → Quick actions: tmux commands via control channel
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
│   │   ├── DesignSystem/    # MuxiTokens design system
│   │   ├── Models/          # Data models (Server, Theme, TmuxModels)
│   │   ├── Resources/       # Fonts, themes (JSON), assets
│   │   ├── Services/        # SSH, tmux, Keychain services
│   │   ├── Terminal/        # Buffer, renderer, input handler, shaders
│   │   ├── ViewModels/      # @Observable view models
│   │   └── Views/           # SwiftUI views by feature
│   ├── MuxiCore/            # SPM package wrapping C core
│   ├── MuxiTests/           # Unit and integration tests
│   └── project.yml          # XcodeGen project definition
├── scripts/                 # Build scripts (build-all.sh, build-openssl.sh, etc.)
├── vendor/                  # Built xcframeworks (gitignored)
└── docs/                    # Documentation
```

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| tmux control mode over raw PTY | Structured output enables native pane management |
| Metal over CoreText | GPU rendering needed for smooth 60fps terminal scrolling |
| Retina glyph atlas | Rasterize at device scale factor for sharp text on high-DPI |
| C11 over C++ for core | Simpler FFI, easier JNI bridging, smaller binary |
| SwiftData over Core Data | Modern API, `@Model` macros, better Swift integration |
| `@Observable` over `ObservableObject` | iOS 17+ only — simpler, more performant observation |
| XcodeGen over manual project | Avoids `.xcodeproj` merge conflicts in version control |
