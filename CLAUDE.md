# Muxi — Claude Code Guidelines

Muxi is a tmux-focused mobile terminal app. iOS first (SwiftUI), Android later (Jetpack Compose). SSH via libssh2, tmux control mode (`tmux -CC`), per-pane native rendering.

## Build Commands

```bash
# First-time setup: download fonts + build OpenSSL + libssh2
./scripts/build-all.sh

# Regenerate Xcode project (required after project.yml changes)
cd ios && xcodegen generate

# Run iOS app + unit tests
xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'

# Run core C library tests (via SPM)
swift test --package-path ios/MuxiCore

# Build core C library standalone
cmake -B core/build -S core && cmake --build core/build
```

## Quick Rules

- Use `@MainActor @Observable` for ViewModels — NOT `ObservableObject`/`@Published`
- Use `shellEscaped()` for all user input passed to SSH commands — never interpolate raw strings
- Use `tmuxQuoted()` for tmux `set-buffer` strings — NOT `shellEscaped()` (tmux parser ≠ shell)
- Use `send-keys -l` for non-ASCII input (Korean, CJK) — hex encoding causes mojibake
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
| Design system | [docs/guides/design-system.md](docs/guides/design-system.md) |
| Architecture | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Development setup | [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) |
| Release process | [docs/RELEASE.md](docs/RELEASE.md) |

## Architecture Decisions (ADR)

Recorded in `docs/decisions/`. Each ADR captures one decision with context, alternatives, and consequences.

| ADR | Decision |
|-----|----------|
| [0001](docs/decisions/0001-tmux-control-mode.md) | tmux control mode (`-CC`) for structured session management |
| [0002](docs/decisions/0002-four-layer-architecture.md) | 4-layer architecture with cross-platform C11 core |
| [0003](docs/decisions/0003-metal-gpu-rendering.md) | Metal GPU rendering with Retina glyph atlas |
| [0004](docs/decisions/0004-swiftdata-keychain-storage.md) | SwiftData for persistence, Keychain for secrets |
| [0005](docs/decisions/0005-sarasa-term-k-font.md) | Sarasa Term K Nerd Font (build pipeline + Korean optimization) |
| [0006](docs/decisions/0006-semantic-token-design-system.md) | Semantic token design system (MuxiTokens) |
| [0007](docs/decisions/0007-switch-client-session-switching.md) | In-place session switching via switch-client |
| [0008](docs/decisions/0008-window-pane-state-machine.md) | Window/Pane state machine with strong-typed IDs |

## Workflow — Phase Reference

| Phase | Read | Write/Update |
|-------|------|-------------|
| Context init | CLAUDE.md, ARCHITECTURE.md | — |
| Issue analysis | docs/decisions/ | — |
| Design | docs/decisions/, docs/guides/ | docs/specs/YYYY-MM-DD-\<topic\>-design.md |
| Development | docs/guides/, ARCHITECTURE.md | Source code |
| Review | docs/guides/git-workflow.md | — |
| Test | docs/guides/testing.md | Test code |
| Merge/Update | CHANGELOG.md, ARCHITECTURE.md | ADR (if new decision), guides (if convention changed) |
| Release | docs/RELEASE.md | CHANGELOG.md, project.yml version |

## Document Governance

### Spec/Plan paths
- Design specs: `docs/specs/YYYY-MM-DD-<topic>-design.md`
- Implementation plans: `docs/specs/YYYY-MM-DD-<topic>-plan.md`

### On design phase entry
1. `Glob docs/decisions/` — verify no existing ADR conflicts with proposed approach
2. Create `docs/specs/YYYY-MM-DD-<topic>-design.md`
3. If major architectural decision: draft ADR in `docs/decisions/NNNN-<topic>.md` with Status: Proposed

### On implementation complete
1. Check `ARCHITECTURE.md` — if data flow, layer, or component changed → update
2. If new ADR was drafted → set Status: Accepted
3. If convention changed → update relevant `docs/guides/` file
4. Update `CHANGELOG.md` (Added/Changed/Fixed/Removed)

### On release
1. Follow `docs/RELEASE.md` checklist
2. Verify `CHANGELOG.md` has current version section
3. Verify `ARCHITECTURE.md` reflects current state

### ADR rules
- One decision = one file
- Template: `docs/decisions/_template.md`
- Numbering: sequential 4-digit (0001, 0002, ...)
- Immutable after Accepted — never edit content, only Status field
- To reverse a decision: create new ADR with Status: Accepted, update old ADR Status: `Superseded by ADR-NNNN`

### Document lifecycle

| Directory | Lifecycle | Mutable | Deletable | Trigger |
|-----------|-----------|---------|-----------|---------|
| `docs/decisions/` | Permanent | Status only | Never | Major design decision |
| `docs/guides/` | Permanent | Yes | Never | Convention change |
| `docs/specs/` | Temporary | Yes | After implementation + ADR extraction | Feature design |
| Root docs (`ARCHITECTURE.md`, etc.) | Permanent | Yes | Never | Structural change |

## Security

- SSH commands must use `shellEscaped()` — command injection is the #1 risk
- tmux commands (e.g. `set-buffer`) must use `tmuxQuoted()` — different parser, different escaping
- Never log passwords or private keys, even at debug level
- Keychain is the only acceptable storage for secrets — enforce via code review
