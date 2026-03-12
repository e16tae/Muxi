#ifndef VT_PARSER_H
#define VT_PARSER_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

// Attribute bit flags
#define VT_ATTR_BOLD          0x01
#define VT_ATTR_UNDERLINE     0x02
#define VT_ATTR_ITALIC        0x04
#define VT_ATTR_INVERSE       0x08
#define VT_ATTR_STRIKETHROUGH 0x10

// Cell in the terminal buffer
typedef struct {
    uint32_t character;    // Unicode codepoint
    uint8_t  fg_color;     // ANSI 0-255 foreground (when fg_is_rgb == 0)
    uint8_t  bg_color;     // ANSI 0-255 background (when bg_is_rgb == 0)
    uint8_t  fg_r, fg_g, fg_b;  // RGB foreground
    uint8_t  bg_r, bg_g, bg_b;  // RGB background
    uint8_t  fg_is_rgb;    // 1 if using RGB fg
    uint8_t  bg_is_rgb;    // 1 if using RGB bg
    uint8_t  fg_has_color; // 1 if fg_color was explicitly set (distinguishes ANSI 0 from default)
    uint8_t  bg_has_color; // 1 if bg_color was explicitly set
    uint8_t  attrs;        // VT_ATTR_BOLD | VT_ATTR_UNDERLINE | ...
    uint8_t  width;        // 1 for normal, 2 for wide (CJK)
} VTCell;

// Parser state machine states
typedef enum {
    VT_STATE_GROUND = 0,
    VT_STATE_ESCAPE,
    VT_STATE_CSI_ENTRY,
    VT_STATE_CSI_PARAM,
    VT_STATE_OSC,
    VT_STATE_OSC_ST,
    VT_STATE_DCS,
    VT_STATE_DCS_ST,
} VTState;

// Parser instance (one per pane)
typedef struct {
    VTCell  *buffer;       // rows * cols cells
    int32_t  cols;
    int32_t  rows;
    int32_t  cursor_row;
    int32_t  cursor_col;
    VTState  state;
    VTCell   current_attrs; // current color/attribute state

    // CSI parameter accumulation
    int32_t  csi_params[16];
    int32_t  csi_param_count;
    int32_t  csi_private;   // '?' prefix

    // Scroll region
    int32_t  scroll_top;
    int32_t  scroll_bottom;

    // Cursor state
    int32_t  cursor_visible; // 1 = visible (default), 0 = hidden (DECTCEM)
    int32_t  cursor_style;   // DECSCUSR: 0=blinking block, 1=blinking block,
                             // 2=steady block, 3=blinking underline,
                             // 4=steady underline, 5=blinking bar, 6=steady bar

    // CSI intermediate byte (e.g. SP in "CSI Ps SP q")
    int32_t  csi_intermediate;

    // UTF-8 accumulation
    uint8_t  utf8_buf[4];
    int32_t  utf8_len;
    int32_t  utf8_expected;
} VTParserState;

// Initialize parser with given dimensions
void vt_parser_init(VTParserState *parser, int32_t cols, int32_t rows);

// Free parser resources
void vt_parser_destroy(VTParserState *parser);

// Feed data into the parser
void vt_parser_feed(VTParserState *parser, const char *data, int32_t len);

// Resize the terminal
void vt_parser_resize(VTParserState *parser, int32_t cols, int32_t rows);

// Get a line as plain text (for debugging). Returns chars written.
int32_t vt_parser_get_line(const VTParserState *parser, int32_t row, char *buf, int32_t buf_size);

// Get a specific cell
void vt_parser_get_cell(const VTParserState *parser, int32_t row, int32_t col, VTCell *out);

// Set the cursor position (clamped to grid bounds)
void vt_parser_set_cursor(VTParserState *parser, int32_t row, int32_t col);

#endif
