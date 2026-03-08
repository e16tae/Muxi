# Remaining Polish Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Complete design token migration for remaining views and resolve build config issues.

**Architecture:** Replace all remaining hardcoded colors, fonts, spacing, and radii with `MuxiTokens` semantic tokens. Fix font bundling reference. All changes are UI-layer only.

**Tech Stack:** SwiftUI, MuxiTokens design system, XcodeGen

---

### Task 1: Migrate SessionRowView to design tokens

**Files:**
- Modify: `ios/Muxi/Views/SessionList/SessionRowView.swift`

**Step 1: Replace hardcoded values with tokens**

```swift
struct SessionRowView: View {
    let session: TmuxSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: MuxiTokens.Spacing.xs) {
                Text(session.name)
                    .font(MuxiTokens.Typography.title)
                    .foregroundStyle(MuxiTokens.Colors.textPrimary)
                HStack(spacing: MuxiTokens.Spacing.sm) {
                    Text(session.id)
                        .font(MuxiTokens.Typography.caption)
                        .foregroundStyle(MuxiTokens.Colors.textSecondary)
                    if !session.windows.isEmpty {
                        Text("\(session.windows.count) window\(session.windows.count == 1 ? "" : "s")")
                            .font(MuxiTokens.Typography.caption)
                            .foregroundStyle(MuxiTokens.Colors.textSecondary)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(MuxiTokens.Typography.caption)
                .foregroundStyle(MuxiTokens.Colors.textTertiary)
        }
        .padding(.vertical, MuxiTokens.Spacing.xs)
    }
}
```

Changes:
- `spacing: 4` → `MuxiTokens.Spacing.xs`
- `spacing: 8` → `MuxiTokens.Spacing.sm`
- `.font(.headline)` → `MuxiTokens.Typography.title`
- `.font(.caption)` → `MuxiTokens.Typography.caption`
- `.foregroundStyle(.secondary)` → `MuxiTokens.Colors.textSecondary`
- `.foregroundStyle(.tertiary)` → `MuxiTokens.Colors.textTertiary`
- Add `.foregroundStyle(MuxiTokens.Colors.textPrimary)` on session name
- `.padding(.vertical, 4)` → `MuxiTokens.Spacing.xs`

**Step 2: Build and verify**

Run: `cd ios && xcodebuild build -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E 'BUILD|error:'`
Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add ios/Muxi/Views/SessionList/SessionRowView.swift
git commit -m "refactor: migrate SessionRowView to design tokens"
```

---

### Task 2: Migrate SessionListView to design tokens

**Files:**
- Modify: `ios/Muxi/Views/SessionList/SessionListView.swift`

**Step 1: Add warm dark List background and row backgrounds**

Apply same pattern as ServerListView: `.scrollContentBackground(.hidden)`, `.background(surfaceBase)`, `.listRowBackground(surfaceDefault)`.

```swift
List {
    ForEach(viewModel.sessions) { session in
        Button {
            Task { await viewModel.attachSession(session) }
        } label: {
            SessionRowView(session: session)
        }
        .listRowBackground(MuxiTokens.Colors.surfaceDefault)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await viewModel.deleteSession(session) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
.scrollContentBackground(.hidden)
.background(MuxiTokens.Colors.surfaceBase)
.refreshable {
    await viewModel.refreshSessions()
}
```

**Step 2: Build and verify**

Run: `cd ios && xcodebuild build -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E 'BUILD|error:'`
Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add ios/Muxi/Views/SessionList/SessionListView.swift
git commit -m "refactor: migrate SessionListView to design tokens"
```

---

### Task 3: Migrate ContentView connecting overlay to design tokens

**Files:**
- Modify: `ios/Muxi/App/ContentView.swift` (lines 138-162)

**Step 1: Replace hardcoded overlay values**

```swift
@ViewBuilder
private var connectingOverlay: some View {
    ZStack {
        Color.black.opacity(0.3)
            .ignoresSafeArea()

        VStack(spacing: MuxiTokens.Spacing.lg) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting...")
                .font(MuxiTokens.Typography.title)
                .foregroundStyle(MuxiTokens.Colors.textSecondary)

            Button("Cancel") {
                connectionManager.disconnect()
                selectedServer = nil
            }
            .buttonStyle(.bordered)
        }
        .padding(MuxiTokens.Spacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: MuxiTokens.Radius.lg, style: .continuous)
                .fill(MuxiTokens.Colors.surfaceElevated)
        )
    }
}
```

Changes:
- `spacing: 16` → `MuxiTokens.Spacing.lg`
- `.font(.headline)` → `MuxiTokens.Typography.title`
- `.foregroundStyle(.secondary)` → `MuxiTokens.Colors.textSecondary`
- `.padding(32)` → `MuxiTokens.Spacing.xxl`
- `cornerRadius: 16` → `MuxiTokens.Radius.lg`
- `.fill(.regularMaterial)` → `.fill(MuxiTokens.Colors.surfaceElevated)` (consistent with design system, no system materials)

**Step 2: Build and verify**

Run: `cd ios && xcodebuild build -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E 'BUILD|error:'`
Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add ios/Muxi/App/ContentView.swift
git commit -m "refactor: migrate ContentView connecting overlay to design tokens"
```

---

### Task 4: Remove phantom font reference from project.yml

**Files:**
- Modify: `ios/project.yml` (lines 52-53)

**Step 1: Remove UIAppFonts entry**

The `Fonts/SarasaMonoSC-NF-Regular.ttf` is declared but the file doesn't exist in `ios/Muxi/Resources/Fonts/` (only a LICENSE file is there). Remove the reference to prevent build warnings. Re-add when font files are actually bundled.

```yaml
# Remove these lines:
#        UIAppFonts:
#          - Fonts/SarasaMonoSC-NF-Regular.ttf
```

**Step 2: Regenerate Xcode project**

Run: `cd ios && xcodegen generate`

**Step 3: Build and verify**

Run: `xcodebuild build -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E 'BUILD|error:'`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add ios/project.yml
git commit -m "fix: remove phantom UIAppFonts reference (font not yet bundled)"
```

---

### Task 5: Update memory — mark completed items

After all tasks pass, update `MEMORY.md`:
- Remove completed items from "Remaining Work" section
- Add SessionListView/SessionRowView to migrated views list
- Add ContentView overlay to migrated list
- Note font bundling status

---

## Status of Previously Listed "Remaining Work"

| Item | Actual Status |
|------|---------------|
| SessionListView migration | **Task 1-2 above** |
| ContentView overlay migration | **Task 3 above** |
| `print()` → `os.Logger` | Already complete (0 print calls remain) |
| Connection timeout | Already implemented (SO_SNDTIMEO/SO_RCVTIMEO) |
| `poll()`/`select()` | Already implemented (50ms poll, not 10ms sleep) |
| Font bundling | **Task 4: remove phantom ref** (font files needed later) |
| Additional themes | Already done (5 themes: Catppuccin, Tokyo Night, Dracula, Nord, Solarized Dark) |
| libssh2 SHA-256 hash | Deferred (build script TODO) |
| Android version | Future |
| iCloud sync | Future |
