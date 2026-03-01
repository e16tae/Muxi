# Testing Guide

## Frameworks

| Layer | Framework | When to use |
|-------|-----------|-------------|
| Models, ViewModels | Swift Testing (`@Suite`, `@Test`, `#expect`) | Unit tests for pure logic |
| Services, UI | XCTest | Tests requiring host app, UI, or async XCTest features |
| Core C | CTest / custom assertions | C parser and protocol tests |

## Swift Testing

```swift
import Testing

@Suite("TerminalBuffer")
struct TerminalBufferTests {
    @Test("writes character at cursor position")
    func writeCharacter() {
        var buffer = TerminalBuffer(cols: 80, rows: 24)
        buffer.write("A")
        #expect(buffer.charAt(row: 0, col: 0) == "A")
    }

    @Test("wraps line at column boundary")
    func lineWrap() {
        var buffer = TerminalBuffer(cols: 3, rows: 2)
        buffer.write("ABCD")
        #expect(buffer.charAt(row: 1, col: 0) == "D")
    }
}
```

### Key Patterns

- Use `@Suite("Name")` to group related tests
- Use `@Test("description")` with descriptive names
- Use `#expect(condition)` instead of `XCTAssert`
- Use `#expect(throws:)` for error testing

## XCTest (Services)

Use XCTest when you need:
- `@MainActor` test context for `@Observable` ViewModels
- Host app environment for SwiftData
- UI testing

```swift
import XCTest
@testable import Muxi

final class ConnectionManagerTests: XCTestCase {
    @MainActor
    func testConnectUpdatesState() async {
        let manager = ConnectionManager()
        await manager.connect(to: mockServer)
        XCTAssertEqual(manager.state, .connected)
    }
}
```

## Core C Tests

```c
#include "vt_parser.h"
#include <assert.h>
#include <string.h>

void test_parser_basic_text(void) {
    VTParser* parser = vt_parser_create(80, 24);
    vt_parser_feed(parser, "Hello", 5);
    // verify output buffer contains "Hello"
    vt_parser_destroy(parser);
}

int main(void) {
    test_parser_basic_text();
    printf("All tests passed\n");
    return 0;
}
```

## Running Tests

```bash
# iOS app + Swift tests
cd ios && xcodegen generate
xcodebuild test -project Muxi.xcodeproj -scheme Muxi \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' \
  CODE_SIGNING_ALLOWED=NO

# Core C tests via SPM
swift test --package-path ios/MuxiCore

# Core C tests via CMake
cmake -B core/build -S core
cmake --build core/build
cd core/build && ctest --output-on-failure
```

## Test Organization

```
ios/Muxi/Tests/
  Models/          # Swift Testing — model unit tests
  Services/        # XCTest — service integration tests
  ViewModels/      # XCTest — ViewModel tests (@MainActor)

core/tests/
  test_vt_parser.c
  test_tmux_protocol.c
```

## Coverage Goals

- Models and parsers: aim for high coverage (edge cases, error paths)
- ViewModels: test state transitions and business logic
- Views: test via previews and manual QA (no snapshot tests yet)
- Services: test with mock/stub dependencies

## Test Naming

- Describe the behavior, not the method: `"wraps line at column boundary"` not `"testWriteChar"`
- Group related tests in `@Suite` by component
