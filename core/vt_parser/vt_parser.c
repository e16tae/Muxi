#include "vt_parser.h"
#include <stdlib.h>
#include <string.h>

/* ---------- helpers ---------- */

static VTCell *cell_at(VTParserState *p, int32_t row, int32_t col) {
    if (!p->buffer) return NULL;
    if (row < 0 || row >= p->rows || col < 0 || col >= p->cols) return NULL;
    return &p->buffer[row * p->cols + col];
}

static void clear_row(VTParserState *p, int32_t row) {
    for (int32_t c = 0; c < p->cols; c++) {
        VTCell *cell = cell_at(p, row, c);
        if (cell) memset(cell, 0, sizeof(VTCell));
    }
}

static void scroll_up(VTParserState *p) {
    int32_t top = p->scroll_top;
    int32_t bot = p->scroll_bottom;
    if (top >= bot) return;
    memmove(&p->buffer[top * p->cols],
            &p->buffer[(top + 1) * p->cols],
            (size_t)(bot - top) * (size_t)p->cols * sizeof(VTCell));
    clear_row(p, bot);
}

static void scroll_down(VTParserState *p) {
    int32_t top = p->scroll_top;
    int32_t bot = p->scroll_bottom;
    if (top >= bot) return;
    memmove(&p->buffer[(top + 1) * p->cols],
            &p->buffer[top * p->cols],
            (size_t)(bot - top) * (size_t)p->cols * sizeof(VTCell));
    clear_row(p, top);
}

/* East Asian Width heuristic — returns 1 for wide (2-cell) characters. */
static int vt_is_wide_char(uint32_t cp) {
    /* CJK Radicals Supplement through CJK Unified Ideographs */
    if (cp >= 0x2E80 && cp <= 0x9FFF) return 1;
    /* CJK Compatibility Ideographs */
    if (cp >= 0xF900 && cp <= 0xFAFF) return 1;
    /* CJK Compatibility Forms */
    if (cp >= 0xFE30 && cp <= 0xFE4F) return 1;
    /* Hangul Syllables */
    if (cp >= 0xAC00 && cp <= 0xD7AF) return 1;
    /* Fullwidth Forms */
    if (cp >= 0xFF01 && cp <= 0xFF60) return 1;
    if (cp >= 0xFFE0 && cp <= 0xFFE6) return 1;
    /* CJK Unified Ideographs Extension B+ */
    if (cp >= 0x20000 && cp <= 0x2FA1F) return 1;
    return 0;
}

static void put_char(VTParserState *p, uint32_t ch) {
    int wide = vt_is_wide_char(ch);

    /* Wide character at last column cannot fit — wrap to next line,
       leaving the last column blank. */
    if (wide && p->cursor_col >= p->cols - 1 && p->cursor_col < p->cols) {
        VTCell *cell = cell_at(p, p->cursor_row, p->cursor_col);
        if (cell) memset(cell, 0, sizeof(VTCell));
        p->cursor_col = 0;
        p->cursor_row++;
        if (p->cursor_row > p->scroll_bottom) {
            p->cursor_row = p->scroll_bottom;
            scroll_up(p);
        }
    }

    if (p->cursor_col >= p->cols) {
        p->cursor_col = 0;
        p->cursor_row++;
        if (p->cursor_row > p->scroll_bottom) {
            p->cursor_row = p->scroll_bottom;
            scroll_up(p);
        }
    }

    VTCell *cell = cell_at(p, p->cursor_row, p->cursor_col);
    if (cell) {
        *cell = p->current_attrs;
        cell->character = ch;
        cell->width = wide ? 2 : 1;
    }
    p->cursor_col++;

    /* Wide character: set up the continuation cell (second half). */
    if (wide) {
        VTCell *cont = cell_at(p, p->cursor_row, p->cursor_col);
        if (cont) {
            *cont = p->current_attrs;
            cont->character = 0;
            cont->width = 0;  /* marks continuation cell */
        }
        p->cursor_col++;
    }
}

/* ---------- SGR (Select Graphic Rendition) ---------- */

static void handle_sgr(VTParserState *p) {
    if (p->csi_param_count == 0) {
        memset(&p->current_attrs, 0, sizeof(VTCell));
        return;
    }

    for (int32_t i = 0; i < p->csi_param_count; i++) {
        int32_t param = p->csi_params[i];

        if (param == 0) {
            memset(&p->current_attrs, 0, sizeof(VTCell));
        } else if (param == 1) {
            p->current_attrs.attrs |= VT_ATTR_BOLD;
        } else if (param == 3) {
            p->current_attrs.attrs |= VT_ATTR_ITALIC;
        } else if (param == 4) {
            p->current_attrs.attrs |= VT_ATTR_UNDERLINE;
        } else if (param == 7) {
            p->current_attrs.attrs |= VT_ATTR_INVERSE;
        } else if (param == 9) {
            p->current_attrs.attrs |= VT_ATTR_STRIKETHROUGH;
        } else if (param == 22) {
            p->current_attrs.attrs &= ~VT_ATTR_BOLD;
        } else if (param == 23) {
            p->current_attrs.attrs &= ~VT_ATTR_ITALIC;
        } else if (param == 24) {
            p->current_attrs.attrs &= ~VT_ATTR_UNDERLINE;
        } else if (param == 27) {
            p->current_attrs.attrs &= ~VT_ATTR_INVERSE;
        } else if (param == 29) {
            p->current_attrs.attrs &= ~VT_ATTR_STRIKETHROUGH;
        } else if (param >= 30 && param <= 37) {
            p->current_attrs.fg_color = (uint8_t)(param - 30);
            p->current_attrs.fg_is_rgb = 0;
            p->current_attrs.fg_has_color = 1;
        } else if (param == 39) {
            /* Default foreground */
            p->current_attrs.fg_color = 0;
            p->current_attrs.fg_is_rgb = 0;
            p->current_attrs.fg_has_color = 0;
        } else if (param >= 40 && param <= 47) {
            p->current_attrs.bg_color = (uint8_t)(param - 40);
            p->current_attrs.bg_is_rgb = 0;
            p->current_attrs.bg_has_color = 1;
        } else if (param == 49) {
            /* Default background */
            p->current_attrs.bg_color = 0;
            p->current_attrs.bg_is_rgb = 0;
            p->current_attrs.bg_has_color = 0;
        } else if (param >= 90 && param <= 97) {
            /* Bright foreground colors */
            p->current_attrs.fg_color = (uint8_t)(param - 90 + 8);
            p->current_attrs.fg_is_rgb = 0;
            p->current_attrs.fg_has_color = 1;
        } else if (param >= 100 && param <= 107) {
            /* Bright background colors */
            p->current_attrs.bg_color = (uint8_t)(param - 100 + 8);
            p->current_attrs.bg_is_rgb = 0;
            p->current_attrs.bg_has_color = 1;
        } else if (param == 38 && i + 4 < p->csi_param_count &&
                   p->csi_params[i + 1] == 2) {
            /* True color foreground: 38;2;r;g;b */
            p->current_attrs.fg_r = (uint8_t)p->csi_params[i + 2];
            p->current_attrs.fg_g = (uint8_t)p->csi_params[i + 3];
            p->current_attrs.fg_b = (uint8_t)p->csi_params[i + 4];
            p->current_attrs.fg_is_rgb = 1;
            p->current_attrs.fg_has_color = 1;
            i += 4;
        } else if (param == 48 && i + 4 < p->csi_param_count &&
                   p->csi_params[i + 1] == 2) {
            /* True color background: 48;2;r;g;b */
            p->current_attrs.bg_r = (uint8_t)p->csi_params[i + 2];
            p->current_attrs.bg_g = (uint8_t)p->csi_params[i + 3];
            p->current_attrs.bg_b = (uint8_t)p->csi_params[i + 4];
            p->current_attrs.bg_is_rgb = 1;
            p->current_attrs.bg_has_color = 1;
            i += 4;
        } else if (param == 38 && i + 2 < p->csi_param_count &&
                   p->csi_params[i + 1] == 5) {
            /* 256-color foreground: 38;5;n */
            p->current_attrs.fg_color = (uint8_t)p->csi_params[i + 2];
            p->current_attrs.fg_is_rgb = 0;
            p->current_attrs.fg_has_color = 1;
            i += 2;
        } else if (param == 48 && i + 2 < p->csi_param_count &&
                   p->csi_params[i + 1] == 5) {
            /* 256-color background: 48;5;n */
            p->current_attrs.bg_color = (uint8_t)p->csi_params[i + 2];
            p->current_attrs.bg_is_rgb = 0;
            p->current_attrs.bg_has_color = 1;
            i += 2;
        }
    }
}

/* ---------- CSI dispatch ---------- */

static void handle_csi(VTParserState *p, char cmd) {
    int32_t n = (p->csi_param_count > 0) ? p->csi_params[0] : 0;
    int32_t m = (p->csi_param_count > 1) ? p->csi_params[1] : 0;

    switch (cmd) {
    case 'A': /* Cursor Up */
        p->cursor_row -= (n > 0 ? n : 1);
        if (p->cursor_row < 0) p->cursor_row = 0;
        break;
    case 'B': /* Cursor Down */
        p->cursor_row += (n > 0 ? n : 1);
        if (p->cursor_row >= p->rows) p->cursor_row = p->rows - 1;
        break;
    case 'C': /* Cursor Forward */
        p->cursor_col += (n > 0 ? n : 1);
        if (p->cursor_col >= p->cols) p->cursor_col = p->cols - 1;
        break;
    case 'D': /* Cursor Back */
        p->cursor_col -= (n > 0 ? n : 1);
        if (p->cursor_col < 0) p->cursor_col = 0;
        break;
    case 'H': /* Cursor Position */
    case 'f':
        p->cursor_row = (n > 0 ? n - 1 : 0);
        p->cursor_col = (m > 0 ? m - 1 : 0);
        if (p->cursor_row >= p->rows) p->cursor_row = p->rows - 1;
        if (p->cursor_col >= p->cols) p->cursor_col = p->cols - 1;
        break;
    case 'J': /* Erase in Display */
        if (n == 0) {
            /* Erase from cursor to end of display */
            for (int32_t c = p->cursor_col; c < p->cols; c++) {
                VTCell *cell = cell_at(p, p->cursor_row, c);
                if (cell) memset(cell, 0, sizeof(VTCell));
            }
            for (int32_t r = p->cursor_row + 1; r < p->rows; r++) clear_row(p, r);
        } else if (n == 1) {
            /* Erase from start of display to cursor */
            for (int32_t r = 0; r < p->cursor_row; r++) clear_row(p, r);
            for (int32_t c = 0; c <= p->cursor_col; c++) {
                VTCell *cell = cell_at(p, p->cursor_row, c);
                if (cell) memset(cell, 0, sizeof(VTCell));
            }
        } else if (n == 2) {
            /* Erase entire display */
            for (int32_t r = 0; r < p->rows; r++) clear_row(p, r);
        }
        break;
    case 'K': /* Erase in Line */
        if (n == 0) {
            /* Erase from cursor to end of line */
            for (int32_t c = p->cursor_col; c < p->cols; c++) {
                VTCell *cell = cell_at(p, p->cursor_row, c);
                if (cell) memset(cell, 0, sizeof(VTCell));
            }
        } else if (n == 1) {
            /* Erase from start of line to cursor */
            for (int32_t c = 0; c <= p->cursor_col; c++) {
                VTCell *cell = cell_at(p, p->cursor_row, c);
                if (cell) memset(cell, 0, sizeof(VTCell));
            }
        } else if (n == 2) {
            /* Erase entire line */
            clear_row(p, p->cursor_row);
        }
        break;
    case 'L': { /* Insert Lines — insert n blank lines at cursor, scroll down */
        int32_t count = (n > 0) ? n : 1;
        int32_t saved_top = p->scroll_top;
        p->scroll_top = p->cursor_row;
        for (int32_t j = 0; j < count; j++) scroll_down(p);
        p->scroll_top = saved_top;
        break;
    }
    case 'M': { /* Delete Lines — delete n lines at cursor, scroll up */
        int32_t count = (n > 0) ? n : 1;
        int32_t saved_top = p->scroll_top;
        p->scroll_top = p->cursor_row;
        for (int32_t j = 0; j < count; j++) scroll_up(p);
        p->scroll_top = saved_top;
        break;
    }
    case 'S': { /* Scroll Up — scroll content up by n lines */
        int32_t count = (n > 0) ? n : 1;
        for (int32_t j = 0; j < count; j++) scroll_up(p);
        break;
    }
    case 'T': { /* Scroll Down — scroll content down by n lines */
        int32_t count = (n > 0) ? n : 1;
        for (int32_t j = 0; j < count; j++) scroll_down(p);
        break;
    }
    case 'm': /* SGR */
        handle_sgr(p);
        break;
    case 'r': /* Set Scroll Region (DECSTBM) */
        p->scroll_top = (n > 0 ? n - 1 : 0);
        p->scroll_bottom = (m > 0 ? m - 1 : p->rows - 1);
        if (p->scroll_top < 0) p->scroll_top = 0;
        if (p->scroll_bottom >= p->rows) p->scroll_bottom = p->rows - 1;
        if (p->scroll_top > p->scroll_bottom) {
            p->scroll_top = 0;
            p->scroll_bottom = p->rows - 1;
        }
        /* Per VT100 spec, DECSTBM moves cursor to home position */
        p->cursor_row = 0;
        p->cursor_col = 0;
        break;
    case 'h': /* Set Mode */
        if (p->csi_private == '?') {
            if (n == 25) p->cursor_visible = 1; /* DECTCEM: show cursor */
        }
        break;
    case 'l': /* Reset Mode */
        if (p->csi_private == '?') {
            if (n == 25) p->cursor_visible = 0; /* DECTCEM: hide cursor */
        }
        break;
    case 'q': /* DECSCUSR — Set Cursor Style (when intermediate is SP) */
        if (p->csi_intermediate == ' ') {
            if (n >= 0 && n <= 6) {
                p->cursor_style = n;
            }
        }
        break;
    default:
        break;
    }
}

/* ---------- UTF-8 decoding ---------- */

static int utf8_start_byte(uint8_t byte) {
    if ((byte & 0x80) == 0)    return 1;
    if ((byte & 0xE0) == 0xC0) return 2;
    if ((byte & 0xF0) == 0xE0) return 3;
    if ((byte & 0xF8) == 0xF0) return 4;
    return 0; /* invalid */
}

static uint32_t utf8_decode(const uint8_t *buf, int len) {
    if (len == 1) return buf[0];
    if (len == 2) return ((uint32_t)(buf[0] & 0x1F) << 6)  |
                          (uint32_t)(buf[1] & 0x3F);
    if (len == 3) return ((uint32_t)(buf[0] & 0x0F) << 12) |
                         ((uint32_t)(buf[1] & 0x3F) << 6)  |
                          (uint32_t)(buf[2] & 0x3F);
    if (len == 4) return ((uint32_t)(buf[0] & 0x07) << 18) |
                         ((uint32_t)(buf[1] & 0x3F) << 12) |
                         ((uint32_t)(buf[2] & 0x3F) << 6)  |
                          (uint32_t)(buf[3] & 0x3F);
    return 0xFFFD; /* replacement character */
}

/* ---------- Public API ---------- */

void vt_parser_init(VTParserState *parser, int32_t cols, int32_t rows) {
    if (!parser) return;
    memset(parser, 0, sizeof(VTParserState));

    if (cols <= 0 || rows <= 0) return;

    /* Two-stage overflow check: ensure cols * rows * sizeof(VTCell) fits in size_t */
    if ((size_t)rows > SIZE_MAX / sizeof(VTCell)) return;
    if ((size_t)cols > SIZE_MAX / ((size_t)rows * sizeof(VTCell))) return;

    parser->cols = cols;
    parser->rows = rows;
    parser->scroll_top = 0;
    parser->scroll_bottom = rows - 1;
    parser->cursor_visible = 1;
    parser->cursor_style = 0;
    parser->buffer = (VTCell *)calloc((size_t)cols * (size_t)rows, sizeof(VTCell));
    if (!parser->buffer) {
        parser->cols = 0;
        parser->rows = 0;
    }
}

void vt_parser_destroy(VTParserState *parser) {
    if (!parser) return;
    free(parser->buffer);
    parser->buffer = NULL;
}

void vt_parser_reset(VTParserState *parser) {
    if (!parser || !parser->buffer) return;
    int32_t cols = parser->cols;
    int32_t rows = parser->rows;
    VTCell *buffer = parser->buffer;
    memset(parser, 0, sizeof(VTParserState));
    parser->buffer = buffer;
    parser->cols = cols;
    parser->rows = rows;
    parser->scroll_top = 0;
    parser->scroll_bottom = rows - 1;
    parser->cursor_visible = 1;
    parser->cursor_style = 0;
    memset(buffer, 0, (size_t)cols * (size_t)rows * sizeof(VTCell));
}

void vt_parser_feed(VTParserState *parser, const char *data, int32_t len) {
    if (!parser || !data || len <= 0) return;

    for (int32_t i = 0; i < len; i++) {
        uint8_t ch = (uint8_t)data[i];

        /* UTF-8 continuation bytes */
        if (parser->utf8_expected > 0) {
            if ((ch & 0xC0) == 0x80) {
                parser->utf8_buf[parser->utf8_len++] = ch;
                parser->utf8_expected--;
                if (parser->utf8_expected == 0) {
                    uint32_t codepoint = utf8_decode(parser->utf8_buf, parser->utf8_len);
                    put_char(parser, codepoint);
                    parser->utf8_len = 0;
                }
            } else {
                /* Invalid continuation — reset and re-process */
                parser->utf8_expected = 0;
                parser->utf8_len = 0;
                i--; /* re-process this byte */
            }
            continue;
        }

        switch (parser->state) {
        case VT_STATE_GROUND:
            if (ch == 0x1B) {
                /* ESC */
                parser->state = VT_STATE_ESCAPE;
            } else if (ch == '\r') {
                parser->cursor_col = 0;
            } else if (ch == '\n') {
                parser->cursor_row++;
                if (parser->cursor_row > parser->scroll_bottom) {
                    parser->cursor_row = parser->scroll_bottom;
                    scroll_up(parser);
                }
            } else if (ch == '\t') {
                /* Tab: move to next 8-column stop */
                int32_t next_tab = ((parser->cursor_col / 8) + 1) * 8;
                if (next_tab >= parser->cols) next_tab = parser->cols - 1;
                parser->cursor_col = next_tab;
            } else if (ch == '\b') {
                /* Backspace */
                if (parser->cursor_col > 0) parser->cursor_col--;
            } else if (ch >= 0x20 && ch <= 0x7E) {
                /* Printable ASCII */
                put_char(parser, (uint32_t)ch);
            } else if (ch >= 0xC0) {
                /* UTF-8 start byte */
                int32_t expected = utf8_start_byte(ch);
                if (expected >= 2 && expected <= 4) {
                    parser->utf8_buf[0] = ch;
                    parser->utf8_len = 1;
                    parser->utf8_expected = expected - 1;
                }
            }
            break;

        case VT_STATE_ESCAPE:
            if (ch == '[') {
                parser->state = VT_STATE_CSI_ENTRY;
                parser->csi_param_count = 0;
                parser->csi_private = 0;
                parser->csi_intermediate = 0;
                memset(parser->csi_params, 0, sizeof(parser->csi_params));
            } else if (ch == ']') {
                parser->state = VT_STATE_OSC;
            } else if (ch == 'P') {
                parser->state = VT_STATE_DCS;
            } else {
                /* Unrecognized escape — back to ground */
                parser->state = VT_STATE_GROUND;
            }
            break;

        case VT_STATE_CSI_ENTRY:
            if (ch >= 0x3C && ch <= 0x3F) {
                /* Private parameter prefix: ? > = < */
                parser->csi_private = ch;
                parser->state = VT_STATE_CSI_PARAM;
            } else if (ch >= 0x20 && ch <= 0x2F) {
                /* Intermediate byte (e.g. SP for DECSCUSR) */
                parser->csi_intermediate = ch;
                parser->state = VT_STATE_CSI_PARAM;
            } else if (ch >= '0' && ch <= '9') {
                parser->csi_params[0] = ch - '0';
                parser->csi_param_count = 1;
                parser->state = VT_STATE_CSI_PARAM;
            } else if (ch == ';') {
                parser->csi_param_count = 2;
                parser->state = VT_STATE_CSI_PARAM;
            } else if (ch >= 0x40 && ch <= 0x7E) {
                /* Command with no parameters */
                handle_csi(parser, (char)ch);
                parser->state = VT_STATE_GROUND;
            } else {
                parser->state = VT_STATE_GROUND;
            }
            break;

        case VT_STATE_CSI_PARAM:
            if (ch >= '0' && ch <= '9') {
                if (parser->csi_param_count == 0) parser->csi_param_count = 1;
                int32_t idx = parser->csi_param_count - 1;
                if (idx >= 0 && idx < 16) {
                    int32_t val = parser->csi_params[idx] * 10 + (ch - '0');
                    if (val < 0 || val > 99999) val = 99999; /* clamp to prevent overflow */
                    parser->csi_params[idx] = val;
                }
            } else if (ch == ';') {
                if (parser->csi_param_count < 16) {
                    parser->csi_param_count++;
                }
            } else if (ch >= 0x40 && ch <= 0x7E) {
                /* CSI command character */
                handle_csi(parser, (char)ch);
                parser->state = VT_STATE_GROUND;
            } else if (ch >= 0x20 && ch <= 0x2F) {
                /* Intermediate byte (e.g. SP for DECSCUSR) */
                parser->csi_intermediate = ch;
            } else {
                /* Unexpected — abort CSI sequence */
                parser->state = VT_STATE_GROUND;
            }
            break;

        case VT_STATE_OSC:
            /* Skip until BEL (0x07) or ST (ESC \) */
            if (ch == 0x07) {
                parser->state = VT_STATE_GROUND;
            } else if (ch == 0x1B) {
                parser->state = VT_STATE_OSC_ST;
            }
            break;

        case VT_STATE_OSC_ST:
            if (ch == '\\') {
                /* Proper ST (ESC \) — consume the backslash */
                parser->state = VT_STATE_GROUND;
            } else {
                /* Not ST — treat the ESC as starting a new escape sequence */
                parser->state = VT_STATE_ESCAPE;
                i--; /* re-process this byte in ESCAPE state */
            }
            break;

        case VT_STATE_DCS:
            /* Skip until ST (ESC \) */
            if (ch == 0x1B) {
                parser->state = VT_STATE_DCS_ST;
            }
            break;

        case VT_STATE_DCS_ST:
            if (ch == '\\') {
                parser->state = VT_STATE_GROUND;
            } else {
                parser->state = VT_STATE_ESCAPE;
                i--; /* re-process this byte in ESCAPE state */
            }
            break;
        }
    }
}

void vt_parser_resize(VTParserState *parser, int32_t cols, int32_t rows) {
    if (!parser || cols <= 0 || rows <= 0) return;

    /* Two-stage overflow check: ensure cols * rows * sizeof(VTCell) fits in size_t */
    if ((size_t)rows > SIZE_MAX / sizeof(VTCell)) return;
    if ((size_t)cols > SIZE_MAX / ((size_t)rows * sizeof(VTCell))) return;

    VTCell *new_buffer = (VTCell *)calloc((size_t)cols * (size_t)rows, sizeof(VTCell));
    if (!new_buffer) return;

    /* Copy existing content, limited to the smaller of old/new dimensions */
    int32_t copy_rows = (rows < parser->rows) ? rows : parser->rows;
    int32_t copy_cols = (cols < parser->cols) ? cols : parser->cols;

    if (parser->buffer) {
        for (int32_t r = 0; r < copy_rows; r++) {
            for (int32_t c = 0; c < copy_cols; c++) {
                new_buffer[r * cols + c] = parser->buffer[r * parser->cols + c];
            }
        }
    }

    free(parser->buffer);
    parser->buffer = new_buffer;
    parser->cols = cols;
    parser->rows = rows;

    /* Clamp cursor */
    if (parser->cursor_row >= rows) parser->cursor_row = rows - 1;
    if (parser->cursor_col >= cols) parser->cursor_col = cols - 1;

    /* Reset scroll region to full screen */
    parser->scroll_top = 0;
    parser->scroll_bottom = rows - 1;
}

void vt_parser_set_cursor(VTParserState *parser, int32_t row, int32_t col) {
    if (!parser) return;
    if (row < 0) row = 0;
    if (col < 0) col = 0;
    if (row >= parser->rows) row = parser->rows - 1;
    if (col >= parser->cols) col = parser->cols - 1;
    parser->cursor_row = row;
    parser->cursor_col = col;
}

int32_t vt_parser_get_line(const VTParserState *parser, int32_t row, char *buf, int32_t buf_size) {
    if (!parser || !buf || buf_size <= 0 || row < 0 || row >= parser->rows) {
        if (buf && buf_size > 0) buf[0] = '\0';
        return 0;
    }

    /* Find the last non-null column to avoid trailing spaces but preserve
     * internal gaps (cursor-positioned content). */
    int32_t last_nonzero = -1;
    for (int32_t c = parser->cols - 1; c >= 0; c--) {
        const VTCell *cell = cell_at((VTParserState *)parser, row, c);
        if (cell && cell->character != 0) { last_nonzero = c; break; }
    }

    int32_t written = 0;
    for (int32_t c = 0; c <= last_nonzero && written < buf_size - 1; c++) {
        const VTCell *cell = cell_at((VTParserState *)parser, row, c);
        /* Skip continuation cells: the previous cell is wide (width==2)
           and this cell is its second half (width==0, character==0). */
        if (c > 0 && cell && cell->width == 0 && cell->character == 0) {
            const VTCell *prev = cell_at((VTParserState *)parser, row, c - 1);
            if (prev && prev->width == 2) continue;
        }
        /* Output space for null gaps (e.g. cursor-positioned content) */
        uint32_t cp = (cell && cell->character != 0) ? cell->character : ' ';
        if (cp < 0x80) {
            /* ASCII */
            buf[written++] = (char)cp;
        } else if (cp < 0x800 && written + 1 < buf_size - 1) {
            /* 2-byte UTF-8 */
            buf[written++] = (char)(0xC0 | (cp >> 6));
            buf[written++] = (char)(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000 && written + 2 < buf_size - 1) {
            /* 3-byte UTF-8 */
            buf[written++] = (char)(0xE0 | (cp >> 12));
            buf[written++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            buf[written++] = (char)(0x80 | (cp & 0x3F));
        } else if (cp < 0x110000 && written + 3 < buf_size - 1) {
            /* 4-byte UTF-8 */
            buf[written++] = (char)(0xF0 | (cp >> 18));
            buf[written++] = (char)(0x80 | ((cp >> 12) & 0x3F));
            buf[written++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            buf[written++] = (char)(0x80 | (cp & 0x3F));
        }
    }

    buf[written] = '\0';
    return written;
}

void vt_parser_get_cell(const VTParserState *parser, int32_t row, int32_t col, VTCell *out) {
    if (!parser || !out) return;
    const VTCell *cell = cell_at((VTParserState *)parser, row, col);
    if (cell) {
        *out = *cell;
    } else {
        memset(out, 0, sizeof(VTCell));
    }
}
