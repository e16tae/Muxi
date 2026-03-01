# Development Setup

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| macOS | 14+ (Sonoma) | — |
| Xcode | 15.0+ | Mac App Store |
| XcodeGen | 2.35+ | `brew install xcodegen` |
| CMake | 3.20+ | `brew install cmake` (optional, for standalone C builds) |
| Swift | 5.9+ | Included with Xcode |

## Clone & Build

```bash
# Clone
git clone https://github.com/e16tae/Muxi.git
cd Muxi

# Generate Xcode project
cd ios && xcodegen generate

# Open in Xcode
open Muxi.xcodeproj
```

Select an iOS Simulator (iPhone 15 or later recommended) and press **Cmd+R** to build and run.

## Running Tests

### iOS App Tests

```bash
xcodebuild test \
  -project ios/Muxi.xcodeproj \
  -scheme Muxi \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' \
  CODE_SIGNING_ALLOWED=NO
```

### Core C Library Tests (via SPM)

```bash
swift test --package-path ios/MuxiCore
```

### Standalone C Build (optional)

```bash
cmake -B core/build -S core
cmake --build core/build
```

## Project Structure

```
Muxi/
├── core/           # Cross-platform C libraries (vt_parser, tmux_protocol)
├── ios/            # iOS application
│   ├── Muxi/      # App source
│   ├── MuxiCore/  # SPM package wrapping C core
│   ├── MuxiTests/ # Tests
│   └── project.yml # XcodeGen definition
└── docs/           # Documentation
```

## XcodeGen

The Xcode project file (`ios/Muxi.xcodeproj`) is generated from `ios/project.yml` and is git-ignored. You must regenerate it after:

- Cloning the repo
- Adding/removing source files
- Changing build settings

```bash
cd ios && xcodegen generate
```

## Adding Source Files

1. Create the `.swift` or `.c`/`.h` file in the appropriate directory
2. Run `cd ios && xcodegen generate` to update the project
3. The file will be automatically included based on `project.yml` source paths

## C Core Development

The C core lives in `core/` and is included in the iOS build via the `MuxiCore` SPM package (`ios/MuxiCore/`).

### Adding a New C Module

1. Create `core/your_module/` with source and `include/` directories
2. Add the module to `core/CMakeLists.txt`
3. Add the module to `ios/MuxiCore/Package.swift`
4. Run `xcodegen generate`

### C Conventions

- C11 standard, no platform-specific headers
- Function prefix matches module name (`vt_`, `tmux_`)
- Caller provides buffers — no internal allocation in hot paths
- See [docs/guides/c-style.md](guides/c-style.md) for full style guide

## Troubleshooting

### "No such module 'MuxiCore'"

Run `xcodegen generate` in the `ios/` directory. The Xcode project must be regenerated.

### Tests fail with signing errors

Add `CODE_SIGNING_ALLOWED=NO` to your `xcodebuild` command. This is already included in the CI workflow.

### Simulator not found

Check available simulators with:

```bash
xcrun simctl list devices available
```

Use a simulator that matches your Xcode version.

### C header changes not reflected

Clean the build folder (**Cmd+Shift+K** in Xcode) and rebuild. SPM may cache old headers.
