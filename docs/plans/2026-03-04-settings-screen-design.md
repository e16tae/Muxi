# Settings Screen Design

## Goal

Add a Settings hub screen with font size control. Replace the direct gear → ThemeSettingsView link with gear → SettingsView → sections.

## Approach: SettingsView Hub

Create a new `SettingsView` as the settings entry point. Reuse the existing `ThemeSettingsView` as a sub-screen. Add font size control directly in the hub.

## SettingsView Structure

```
SettingsView (List)
  Section "Appearance"
  ├─ NavigationLink "Theme" → ThemeSettingsView (existing)
  └─ Font Size: Stepper (10–24pt, default 14pt, step 2pt)
      Current size displayed as "14pt"

  Section "About"
  └─ App version (from Bundle.main)
```

## Font Size Management

Extend `ThemeManager` with a `fontSize: CGFloat` property:
- Persisted via UserDefaults key `"terminalFontSize"`
- Default: 14pt
- Range: 10–24pt (2pt increments)
- On change: triggers terminal re-render with new font

## Affected Components

| Component | Change |
|-----------|--------|
| TerminalRenderer | Font created with dynamic size instead of hardcoded 14 |
| TerminalSessionView | `terminalCellSize()` uses dynamic font size |
| TerminalView | `makeUIView` creates font with dynamic size |
| ContentView | Gear icon links to SettingsView instead of ThemeSettingsView |

Currently all three components hardcode `UIFont(name: ..., size: 14)`. Replace with `themeManager.fontSize`.

## Files

- Create: `ios/Muxi/Views/Settings/SettingsView.swift` — settings hub
- Modify: `ios/Muxi/Services/ThemeManager.swift` — add `fontSize` property
- Modify: `ios/Muxi/App/ContentView.swift` — gear → SettingsView
- Modify: `ios/Muxi/Views/Terminal/TerminalView.swift` — dynamic font size
- Modify: `ios/Muxi/Views/Terminal/TerminalSessionView.swift` — dynamic cell size
- Modify: `ios/Muxi/Terminal/TerminalRenderer.swift` — dynamic font size

## Out of Scope

- Keyboard settings (Feature 8)
- Connection timeout settings
- tmux history-limit configuration
- Font family selection
