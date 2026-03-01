# Muxi - tmux-focused Mobile Terminal App

## Product Overview

| Item | Detail |
|---|---|
| **Name** | Muxi |
| **Concept** | tmux-centric mobile terminal with native pane rendering via tmux control mode |
| **Target Users** | Developers who use tmux daily |
| **Key Differentiator** | tmux panes rendered as native iOS views via `tmux -CC` (control mode) |
| **Platform** | iOS first (SwiftUI), Android later (Jetpack Compose) |
| **Connection** | SSH (libssh2) |
| **Price** | Free |
| **Min iOS Version** | iOS 17+ |
| **Min tmux Version** | tmux 1.8+ (control mode support) |

## Architecture

```
┌──────────────────────────────────┐
│   UI Layer (SwiftUI)             │  ← Platform-specific
│   - Server list, session list    │
│   - Native pane views            │
│   - Extended keyboard            │
├──────────────────────────────────┤
│   App Layer (Swift)              │  ← Business logic
│   - ServerManager                │
│   - SessionManager               │
│   - ConnectionManager            │
│   - SSH auto-reconnect           │
├──────────────────────────────────┤
│   Bridge Layer (Swift ↔ C)       │  ← C interop
│   - libssh2 Swift wrapper        │
│   - VT parser Swift bindings     │
├──────────────────────────────────┤
│   Core Layer (C/C++)             │  ← Shared across iOS/Android
│   - VT Parser                    │
│   - SSH (libssh2)                │
│   - tmux control mode parser     │
└──────────────────────────────────┘
```

### Design Principles
- iOS-first development, always considering Android compatibility
- Core logic in C/C++ for cross-platform sharing
- Clean separation between platform-specific UI and shared core
- MVVM pattern for UI layer
- Swift-C bridging layer for type-safe interop

## Data Models

### Storage Strategy
| Data | Storage | Reason |
|---|---|---|
| Server metadata (host, port, name) | SwiftData | Structured data, queryable, supports migration |
| Passwords | Keychain | Encrypted secret storage |
| SSH private keys + metadata | Keychain | Encrypted secret storage, metadata co-located with key |
| App settings (theme, font) | UserDefaults | Simple key-value preferences |

```swift
// --- Persistence (SwiftData) ---

@Model
class Server {
    @Attribute(.unique) var id: UUID
    var name: String
    var host: String
    var port: UInt16          // default: 22
    var username: String
    var authMethod: AuthMethod
    var agentForwarding: Bool // supplementary toggle, not an auth type
    // password/key stored in Keychain, referenced by id
}

enum AuthMethod: Codable {
    case password             // actual password in Keychain keyed by server.id
    case key(keyId: UUID)     // SSH key in Keychain keyed by keyId
}

struct SSHKey: Identifiable, Codable {
    let id: UUID
    var name: String
    var type: KeyType
    // Both metadata (name, type) and private key data stored in Keychain as a single item.
    // SSHKey struct is a view model materialized from Keychain query results.
    // This avoids dual-store sync issues between SwiftData and Keychain.
}

enum KeyType: String, Codable {
    case ed25519
    case rsa
}

// --- Runtime (not persisted) ---

struct TmuxSession: Identifiable {
    let id: String            // tmux session id ($0, $1, ...)
    var name: String
    var windows: [TmuxWindow]
    var createdAt: Date
    var lastActivity: Date
}

struct TmuxWindow: Identifiable {
    let id: String            // tmux window id (@0, @1, ...)
    var name: String
    var panes: [TmuxPane]
    var layout: String        // tmux layout string
}

struct TmuxPane: Identifiable {
    let id: String            // tmux pane id (%0, %1, ...)
    var isActive: Bool
    var size: PaneSize
}

struct PaneSize {
    var columns: Int
    var rows: Int
}
```

## Screen Composition & Navigation

### Navigation Flow
```
Server List → Connect (SSH) → tmux Session List → Attach → Terminal View
```

### 1. Server List (Home)
- Registered server card list
- Each card: server name, host, connection status indicator
- Swipe: edit/delete
- `+` button: add new server
- Tap → SSH connect and navigate to tmux session list

### 2. Server Edit
- Server name, host, port, username
- Auth method: Password / SSH Key
- Agent Forwarding: toggle (supplementary option)
- SSH key management (import/generate Ed25519/RSA)

### 3. tmux Session List
- **Query phase**: SSH exec channel runs `tmux list-sessions -F` to get session list (before entering control mode)
- Each item: session name, window count, last activity time
- Selection shows layout preview (iPad: right side / iPhone: bottom sheet)
- Swipe: rename / delete (kill-session via SSH exec)
- `+` button: create new session (via SSH exec `tmux new-session -d`)
- `Attach` tap → enters control mode via `tmux -CC attach -t <session>` → navigate to terminal view

### 4. Terminal View
- Each tmux pane rendered as an independent native terminal view
- Bottom: extended keyboard bar (Ctrl, Alt, Esc, Tab, ←↑↓→)
- Bottom-right floating button: tmux quick action menu
- **iPhone**: current pane fullscreen, tab bar for pane switching
- **iPad**: panes arranged as native split views matching tmux layout

### 5. tmux Quick Action Menu (Overlay)
- Opens on floating button tap
- Commands sent directly through tmux control mode connection (no key sequence injection needed)
- Categorized commands:
  - **Pane**: horizontal split, vertical split, close, navigate
  - **Window**: new, rename, move, close
  - **Session**: switch, detach, new session

## Technical Implementation

### tmux Control Mode (`tmux -CC`)

This is the core technical foundation of Muxi. tmux control mode provides a structured protocol over the SSH connection.

**How it works:**
```
App sends:    tmux -CC attach -t session_name
tmux outputs: structured messages (not terminal escape sequences)

%begin 1234567890 1 0
%end 1234567890 1 0
%output %0 Hello from pane 0\n
%output %1 Output in pane 1\n
%layout-change @0 abcd,80x24,0,0{40x24,0,0,0,39x24,41,0,1}
%session-changed $0 my-session
%window-add @1
```

**Key protocol messages:**
| Message | Purpose |
|---|---|
| `%output %<pane_id> <data>` | Output for a specific pane |
| `%layout-change @<window_id> <layout>` | Pane layout changed |
| `%window-add @<id>` | New window created |
| `%window-close @<id>` | Window closed |
| `%session-changed $<id> <name>` | Active session changed |
| `%begin`/`%end` | Command response boundaries |

**Sending commands:** The app writes tmux commands directly to the control mode connection:
```
split-window -h
new-window -n "build"
select-pane -t %2
```

**Per-pane rendering:** Each `%output %<pane_id>` message is routed to the corresponding native terminal view. Each pane has its own VT parser instance and buffer.

### Terminal Emulation (Per-Pane)
| Component | Technology |
|---|---|
| VT Parser | C state machine (xterm-256color + true color), one instance per pane |
| Rendering | Metal-based GPU accelerated character rendering |
| Buffer | Circular buffer per pane, configurable scrollback lines |
| Encoding | UTF-8 (Korean, emoji, CJK fullwidth character support) |

### Network
| Component | Technology |
|---|---|
| SSH | libssh2 (C library, iOS cross-compiled) |
| Authentication | Password, Ed25519/RSA keys |
| Agent Forwarding | Supported as supplementary option |
| Key Storage | iOS Keychain Services |

### SSH Auto-Reconnect
Since Mosh is not used, the app implements its own reconnection logic:

1. **Detect disconnect** — SSH keepalive timeout or socket error
2. **Notify user** — Brief "Reconnecting..." overlay (tmux session is safe on server)
3. **Auto-reconnect** — Retry SSH connection with exponential backoff
4. **Auto-reattach** — `tmux -CC attach -t <session>` to resume
5. **Restore state** — Pane layout and content restored via tmux control mode

tmux sessions persist on the server regardless of SSH connection state, so no work is lost.

### Error Handling & Edge Cases
| Scenario | Handling |
|---|---|
| SSH connection failure | Retry with exponential backoff, show error after N attempts |
| tmux not installed on server | Detect on first connect, show install guide |
| tmux version < 1.8 | Detect on connect, show version requirement message |
| Network transition (WiFi → LTE) | SSH drops → auto-reconnect → auto-reattach |
| Server unreachable | Show offline status in server list |
| Keychain access denied | Prompt user for Keychain permission |
| tmux session killed externally | Handle `%session-changed` / `%exit` messages gracefully |
| SSH key has passphrase | Prompt user for passphrase, cache in memory for session duration |
| Control mode connection interrupted | Graceful fallback → auto-reconnect → re-enter control mode |

### Platform Considerations (iOS ↔ Android)
| Area | iOS | Android (Future) |
|---|---|---|
| UI Framework | SwiftUI | Jetpack Compose |
| GPU Rendering | Metal | Vulkan / OpenGL ES |
| Key Storage | Keychain | Android Keystore |
| Background | Background Tasks (limited) | Foreground Service (flexible) |
| Navigation | NavigationStack (push) | Back button + NavHost |
| C Interop | Swift-C bridging header | JNI / NDK |

## Themes & Fonts

### Bundled Themes (10)
| Theme | Description | Character |
|---|---|---|
| **Catppuccin Mocha** | Warm pastel dark | Currently most popular |
| **Dracula** | Purple/pink/cyan dark | Classic popular |
| **Nord** | Arctic blue-grey | Calm, easy on eyes |
| **Gruvbox Dark** | Retro amber/orange | Vim community favorite |
| **Tokyo Night** | Navy + blue/purple | Modern rising star |
| **Solarized Dark** | Precision 16-color palette | Long-standing standard |
| **One Dark** | Atom editor based | High contrast dark |
| **Rose Pine** | Warm rose/pine tones | Soft dark |
| **Everforest** | Nature green palette | Long session use |
| **Kanagawa** | Japanese traditional colors | Unique aesthetic |

**Default theme:** Catppuccin Mocha

### Bundled Fonts (Korean + Nerd Font support)
| Font | Korean | Nerd Font | Size (approx) | Notes |
|---|---|---|---|---|
| **Sarasa Gothic Mono** | Native | NF version | ~15-30MB | Iosevka + Source Han Sans. Best CJK coverage |
| **D2Coding** | Native | Powerline | ~5MB | Made by Naver. Korean developer standard |
| **Maple Mono CN** | Native | NF built-in | ~15-25MB | Rounded corners, ligatures, CJK included |

**Default font:** Sarasa Gothic Mono NF

**Font size consideration:** Full CJK fonts are large. Mitigation strategies:
- Bundle only the default font (Sarasa Gothic Mono NF) in the app
- Additional fonts available as on-demand downloads (iOS On-Demand Resources)
- This keeps initial app download size reasonable (~30-50MB total)

## MVP Scope (v0.1)

1. **Server Management** — Register/edit/delete servers, Keychain storage
2. **SSH Connection** — libssh2 based, password + SSH key + Agent Forwarding
3. **SSH Auto-Reconnect** — Disconnect detection, auto-reconnect, auto-reattach
4. **Terminal Emulator** — True Color, GPU (Metal) rendering, UTF-8, per-pane
5. **tmux Control Mode** — `tmux -CC` parser, per-pane output routing
6. **Extended Keyboard** — Ctrl, Alt, Esc, Tab, arrow keys
7. **tmux Session Management** — Session list, create, delete, attach/detach
8. **tmux Quick Action Menu** — Pane/window/session controls via control mode
9. **Adaptive Layout** — iPhone (tab per pane), iPad (native split views)
10. **Themes** — 10 preset themes
11. **Fonts** — 1 bundled (Sarasa Gothic Mono NF), 2 downloadable

## Roadmap

### v0.2 — Improvements
- Theme/font custom settings UI
- tmux session preview (capture-pane snapshots)
- External keyboard support and key mapping
- Additional downloadable fonts

### v0.3 — Expansion
- Android version (Jetpack Compose + shared C/C++ core via JNI)
- iCloud sync for server data (SwiftData + CloudKit)

## Dependencies & Licenses

| Dependency | Purpose | License |
|---|---|---|
| libssh2 | SSH protocol | BSD-3-Clause |
| Sarasa Gothic | Bundled font | SIL Open Font License |
| D2Coding | Downloadable font | SIL Open Font License |
| Maple Mono | Downloadable font | SIL Open Font License |

## Project Structure (Cross-Platform)

```
muxi/
├── core/                                  # Pure C — shared across iOS/Android
│   ├── vt_parser/
│   │   ├── include/vt_parser.h
│   │   └── vt_parser.c
│   ├── tmux_protocol/
│   │   ├── include/tmux_protocol.h
│   │   └── tmux_protocol.c
│   ├── ssh/
│   │   └── (libssh2 wrapper — future)
│   ├── CMakeLists.txt                     # Android NDK build
│   └── tests/                             # C unit tests (platform-independent)
│
├── ios/                                   # iOS-specific
│   ├── project.yml                        # XcodeGen spec
│   ├── Muxi.xcodeproj                     # Generated
│   ├── Muxi/
│   │   ├── App/
│   │   │   └── MuxiApp.swift
│   │   ├── Views/
│   │   │   ├── ServerList/
│   │   │   ├── ServerEdit/
│   │   │   ├── SessionList/
│   │   │   ├── Terminal/
│   │   │   │   ├── TerminalView.swift        # Single pane terminal view
│   │   │   │   ├── PaneContainerView.swift   # Multi-pane layout (adaptive)
│   │   │   │   └── ExtendedKeyboardView.swift
│   │   │   └── QuickAction/
│   │   ├── ViewModels/
│   │   │   ├── ServerListViewModel.swift
│   │   │   ├── SessionListViewModel.swift
│   │   │   └── TerminalViewModel.swift
│   │   ├── Models/
│   │   │   ├── Server.swift
│   │   │   ├── TmuxSession.swift
│   │   │   ├── TmuxWindow.swift
│   │   │   └── TmuxPane.swift
│   │   ├── Services/
│   │   │   ├── SSHService.swift
│   │   │   ├── TmuxControlService.swift      # tmux -CC protocol handler
│   │   │   ├── ConnectionManager.swift       # Auto-reconnect logic
│   │   │   ├── KeychainService.swift         # Password & SSH key storage
│   │   │   └── ServerStore.swift             # SwiftData persistence
│   │   ├── Terminal/
│   │   │   ├── TerminalRenderer.swift        # Metal renderer
│   │   │   ├── TerminalBuffer.swift          # Per-pane circular buffer
│   │   │   └── InputHandler.swift
│   │   └── Resources/
│   │       ├── Themes/                       # Theme JSON files
│   │       └── Fonts/                        # Bundled font (Sarasa)
│   ├── MuxiCore/                             # SPM package — wraps core/ for iOS
│   │   ├── Package.swift                     # References ../../core/ sources
│   │   └── Sources/MuxiCore/MuxiCore.swift   # Swift re-exports
│   └── MuxiTests/
│
├── android/                               # Future Android project
│   ├── app/
│   │   └── src/main/
│   │       ├── java/ or kotlin/
│   │       └── jni/                       # JNI bindings to core/
│   ├── build.gradle
│   └── CMakeLists.txt                     # References ../../core/
│
└── docs/
    └── plans/
```

**Key design decision:** The `core/` directory contains pure C code with zero platform dependencies. iOS's `MuxiCore` SPM package references `core/` via relative paths. Android's `CMakeLists.txt` does the same. This ensures a single source of truth for the terminal emulator and protocol parser.
