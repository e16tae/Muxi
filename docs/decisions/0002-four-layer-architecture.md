# ADR-0002: 4-layer architecture with cross-platform C11 core

## Status

Accepted

## Date

2026-02-28

## Context

Muxi targets iOS first with Android planned. Terminal parsing (VT100/xterm) and tmux protocol parsing are CPU-intensive and platform-independent logic. The architecture must enable code sharing between platforms while keeping platform-specific UI separate.

## Decision

Adopt a 4-layer stack where each layer only communicates with the one directly below:

```
UI (SwiftUI)  →  App (ViewModels, Services)  →  Bridge (Swift↔C)  →  Core (C11)
```

- **Core**: Pure C11, no platform dependencies, no allocation in hot paths. Modules: `vt_parser`, `tmux_protocol`.
- **Bridge**: SPM package (`MuxiCore`) wrapping C headers with module maps.
- **App**: `@Observable` ViewModels, `actor`-based services, business logic.
- **UI**: SwiftUI views, adaptive layout.

Android will share the Core layer via JNI, replacing UI/App/Bridge with Kotlin/Compose equivalents.

## Alternatives Considered

### Swift-only stack

Write VT parser and tmux parser in pure Swift. No C code, no FFI complexity.

Rejected because:
- Cannot be reused on Android without rewriting in Kotlin
- Swift's overhead for byte-level parsing (bounds checks, ARC) is measurable at terminal throughput rates
- C11 compiles on any platform with a C compiler — maximal portability

### C++ core

Use C++ instead of C11 for the shared core.

Rejected because:
- C++ FFI from Swift requires Objective-C++ bridging — more complexity
- JNI bridging for C++ is more complex than for C
- VT parser and tmux protocol parser don't benefit from C++ abstractions (classes, templates)
- C11 produces smaller binaries

## Consequences

- (+) Core parsers reusable on Android via JNI with zero rewrite
- (+) Clear dependency direction — no circular dependencies possible
- (+) Each layer testable independently (C via CMake/CTest, Swift via SPM/XCTest)
- (-) FFI boundary requires careful pointer management (`withCString` scope, `extractString<T>`)
- (-) Two build systems (CMake for standalone C, SPM for iOS integration)
