# C Style Guide

## General

- C11 standard, no platform-specific dependencies
- All core code must compile on macOS (clang) and Linux (gcc)
- Designed for reuse on Android via JNI

## Naming

| Element | Convention | Example |
|---------|-----------|---------|
| Functions | `module_action_noun` | `vt_parser_feed()`, `tmux_parse_line()` |
| Types | `ModuleName` | `VTParser`, `TmuxCommand` |
| Enums | `MODULE_ENUM_VALUE` | `VT_STATE_GROUND`, `TMUX_CMD_OUTPUT` |
| Constants | `MODULE_CONSTANT` | `VT_MAX_PARAMS`, `TMUX_MAX_LINE_LENGTH` |
| Macros | `MODULE_MACRO` | `VT_DEFAULT_COLS` |

### Prefix Rules

| Module | Prefix |
|--------|--------|
| VT parser | `vt_` / `VT_` |
| tmux protocol | `tmux_` / `TMUX_` |

## Memory Management

- No `malloc`/`free` in hot paths — use stack or pre-allocated buffers
- Document ownership in function comments when returning pointers
- Use fixed-size buffers where possible (e.g., `char line[TMUX_MAX_LINE_LENGTH]`)

## Header Organization

```c
#ifndef MUXI_MODULE_H
#define MUXI_MODULE_H

#include <stdint.h>
#include <stdbool.h>

// Types
typedef struct { ... } ModuleState;

// Lifecycle
ModuleState* module_create(void);
void module_destroy(ModuleState* state);

// Operations
void module_process(ModuleState* state, const char* data, int32_t length);

#endif // MUXI_MODULE_H
```

## Function Design

- Keep functions under 50 lines where practical
- Use early returns for error conditions
- Document parameters and return values for public API functions

```c
/**
 * Feed raw terminal data to the VT parser.
 *
 * @param parser  Parser instance (must not be NULL)
 * @param data    Raw byte data to parse
 * @param length  Number of bytes in data
 */
void vt_parser_feed(VTParser* parser, const char* data, int32_t length);
```

## Error Handling

- Return error codes (negative values) or bool for failable operations
- Use `enum` for error codes, not raw integers
- Never use `assert()` for runtime errors — only for invariant checks in debug

## Testing

- Test files: `test_module.c`
- Use simple assertion macros or the project's test framework
- Test edge cases: empty input, max-length buffers, malformed data

## File Structure

```
core/
  include/
    vt_parser.h
    tmux_protocol.h
  src/
    vt_parser.c
    tmux_protocol.c
  tests/
    test_vt_parser.c
    test_tmux_protocol.c
  CMakeLists.txt
```
