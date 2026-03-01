# Swift Style Guide

## General

- Swift 5.9+, iOS 17+ minimum deployment target
- Follow [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/)
- No force unwraps (`!`) except in tests or `fatalError` for programmer errors

## Observable Pattern

Use `@MainActor @Observable` — **not** `ObservableObject` / `@Published`:

```swift
// Good
@MainActor @Observable
final class SessionListViewModel {
    var sessions: [Session] = []
    var isLoading = false
}

// Bad — legacy pattern
class SessionListViewModel: ObservableObject {
    @Published var sessions: [Session] = []
}
```

## Naming

| Element | Convention | Example |
|---------|-----------|---------|
| Types | UpperCamelCase | `TerminalBuffer`, `SSHService` |
| Methods/Properties | lowerCamelCase | `connectToServer()`, `isConnected` |
| Constants | lowerCamelCase | `let maxRetryCount = 5` |
| ViewModels | Suffix `ViewModel` | `SessionListViewModel` |
| Services | Suffix `Service` | `SSHService`, `TmuxControlService` |

## Access Control

- Default to `private` or `internal`
- Mark `public` only for SPM module boundaries
- Use `private(set)` for read-only external access

## Error Handling

- Define domain-specific error enums conforming to `LocalizedError`
- Provide `errorDescription` for user-facing messages
- Never silently swallow errors — log at minimum

```swift
enum SSHError: LocalizedError {
    case connectionFailed(String)
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let host):
            return "Failed to connect to \(host)"
        case .authenticationFailed:
            return "Authentication failed"
        }
    }
}
```

## Security

- **Always** use `shellEscaped()` for user input in SSH commands
- **Never** interpolate raw strings into shell commands
- **Never** log passwords or private keys

```swift
// Good
let command = "ls -la \(directory.shellEscaped())"

// Bad — command injection risk
let command = "ls -la \(directory)"
```

## C Interop

- Use `withCString` for passing Swift strings to C — pointer must not escape scope
- Use `extractString<T>` for C fixed-size char arrays to Swift String

```swift
// Good — pointer stays in scope
line.withCString { ptr in
    vt_parser_feed(parser, ptr, Int32(line.utf8.count))
}

// Bad — pointer may dangle
let ptr = line.withCString { $0 }
vt_parser_feed(parser, ptr, Int32(line.utf8.count))
```

## SwiftUI Views

- Prefer small, composable views
- Extract subviews when body exceeds ~30 lines
- Use `@Environment` for shared dependencies
- Use adaptive layout modifiers for phone/tablet support

## File Organization

```
Muxi/
  App/           # App entry point, ViewModels, services
  Models/        # SwiftData models, domain types
  Views/         # SwiftUI views
  Services/      # SSH, tmux, connection management
  Rendering/     # Metal renderer, glyph atlas, themes
  Extensions/    # Swift extensions, helpers
```
