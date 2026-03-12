#include "tmux_protocol.h"
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>

/* ================================================================
 * Internal helpers
 * ================================================================ */

/**
 * Safe string copy into a fixed-size buffer.  Always NUL-terminates.
 */
static void safe_copy(char *dst, size_t dst_size, const char *src, size_t len) {
    if (dst_size == 0) return;
    if (len >= dst_size)
        len = dst_size - 1;
    memcpy(dst, src, len);
    dst[len] = '\0';
}

/**
 * Copy a NUL-terminated string into a fixed-size buffer.
 */
static void safe_strcpy(char *dst, size_t dst_size, const char *src) {
    if (!src) { if (dst_size > 0) dst[0] = '\0'; return; }
    safe_copy(dst, dst_size, src, strlen(src));
}

/**
 * Skip past white-space, returning a pointer to the first non-space.
 */
static const char *skip_space(const char *p) {
    while (*p == ' ' || *p == '\t')
        ++p;
    return p;
}

/**
 * Advance past a word (run of non-space chars).  Returns pointer to the
 * first space (or NUL) after the word.
 */
static const char *skip_word(const char *p) {
    while (*p && *p != ' ' && *p != '\t')
        ++p;
    return p;
}

/**
 * Extract the next space-delimited token from *pos.
 * Writes it into buf (up to buf_size-1 chars + NUL).
 * Advances *pos past the token and any trailing space.
 * Returns 1 if a token was found, 0 if *pos is at end-of-string.
 */
static int next_token(const char **pos, char *buf, size_t buf_size) {
    const char *p = skip_space(*pos);
    if (*p == '\0') {
        buf[0] = '\0';
        return 0;
    }
    const char *end = skip_word(p);
    safe_copy(buf, buf_size, p, (size_t)(end - p));
    *pos = skip_space(end);
    return 1;
}

/**
 * Parse a 64-bit integer from a token.  Returns 0 on success, -1 on error.
 */
static int parse_int64(const char *s, int64_t *out) {
    if (!s || !*s)
        return -1;
    char *end;
    errno = 0;
    long long v = strtoll(s, &end, 10);
    if (errno != 0 || *end != '\0')
        return -1;
    *out = (int64_t)v;
    return 0;
}

/**
 * Parse a plain int from a token.  Returns 0 on success, -1 on error.
 */
static int parse_int(const char *s, int *out) {
    int64_t v;
    if (parse_int64(s, &v) != 0)
        return -1;
    if (v < INT32_MIN || v > INT32_MAX)
        return -1;
    *out = (int)v;
    return 0;
}

/* ================================================================
 * tmux_parse_line
 * ================================================================ */

/**
 * Parse %output %<pane_id> <escaped_data>
 */
static int parse_output(const char *rest, TmuxMessage *msg) {
    const char *p = skip_space(rest);
    if (*p == '\0')
        return TMUX_MSG_UNKNOWN;

    /* pane_id (starts with %) */
    const char *id_end = skip_word(p);
    safe_copy(msg->pane_id, TMUX_ID_MAX, p, (size_t)(id_end - p));

    /* Skip exactly one delimiter space between pane_id and data.
     * Using skip_space() here would swallow leading spaces that are
     * part of the actual output (e.g. a shell echoing a space character
     * produces "%output %0  " — delimiter + one data space). */
    p = id_end;
    if (*p == ' ') p++;
    msg->output_data = p;
    msg->output_len  = strlen(p);

    return TMUX_MSG_OUTPUT;
}

/**
 * Parse %layout-change @<window_id> <layout_string>
 */
static int parse_layout_change(const char *rest, TmuxMessage *msg) {
    const char *p = skip_space(rest);
    if (*p == '\0')
        return TMUX_MSG_UNKNOWN;

    /* window_id (starts with @) */
    const char *id_end = skip_word(p);
    safe_copy(msg->window_id, TMUX_ID_MAX, p, (size_t)(id_end - p));

    /* layout string -- first space-delimited token only.
     * tmux sends: %layout-change @id <layout> <visible_layout> [*]
     * We only need the first layout token for parsing. */
    p = skip_space(id_end);
    const char *layout_end = skip_word(p);
    msg->layout     = p;
    msg->layout_len = (size_t)(layout_end - p);

    return TMUX_MSG_LAYOUT_CHANGE;
}

/**
 * Parse %window-add @<id>
 */
static int parse_window_add(const char *rest, TmuxMessage *msg) {
    char tok[TMUX_ID_MAX];
    if (!next_token(&rest, tok, sizeof(tok)))
        return TMUX_MSG_UNKNOWN;
    safe_strcpy(msg->window_id, TMUX_ID_MAX, tok);
    return TMUX_MSG_WINDOW_ADD;
}

/**
 * Parse %window-close @<id>
 */
static int parse_window_close(const char *rest, TmuxMessage *msg) {
    char tok[TMUX_ID_MAX];
    if (!next_token(&rest, tok, sizeof(tok)))
        return TMUX_MSG_UNKNOWN;
    safe_strcpy(msg->window_id, TMUX_ID_MAX, tok);
    return TMUX_MSG_WINDOW_CLOSE;
}

/**
 * Parse %window-renamed @<id> <new_name>
 */
static int parse_window_renamed(const char *rest, TmuxMessage *msg) {
    char tok[TMUX_ID_MAX];
    if (!next_token(&rest, tok, sizeof(tok)))
        return TMUX_MSG_UNKNOWN;
    safe_strcpy(msg->window_id, TMUX_ID_MAX, tok);
    const char *p = skip_space(rest);
    safe_strcpy(msg->window_name, TMUX_NAME_MAX, p);
    return TMUX_MSG_WINDOW_RENAMED;
}

/**
 * Parse %unlinked-window-close @<id>
 */
static int parse_unlinked_window_close(const char *rest, TmuxMessage *msg) {
    char tok[TMUX_ID_MAX];
    if (!next_token(&rest, tok, sizeof(tok)))
        return TMUX_MSG_UNKNOWN;
    safe_strcpy(msg->window_id, TMUX_ID_MAX, tok);
    return TMUX_MSG_UNLINKED_WINDOW_CLOSE;
}

/**
 * Parse %session-changed $<id> <name>
 */
static int parse_session_changed(const char *rest, TmuxMessage *msg) {
    const char *p = skip_space(rest);
    if (*p == '\0')
        return TMUX_MSG_UNKNOWN;

    /* session_id (starts with $) */
    const char *id_end = skip_word(p);
    safe_copy(msg->session_id, TMUX_ID_MAX, p, (size_t)(id_end - p));

    /* session name (rest of line, may contain spaces) */
    p = skip_space(id_end);
    safe_strcpy(msg->session_name, TMUX_NAME_MAX, p);

    return TMUX_MSG_SESSION_CHANGED;
}

/**
 * Parse %begin <timestamp> <cmd_num> <flags>
 */
static int parse_begin(const char *rest, TmuxMessage *msg) {
    char tok[64];
    if (!next_token(&rest, tok, sizeof(tok)))
        return TMUX_MSG_UNKNOWN;
    if (parse_int64(tok, &msg->timestamp) != 0)
        return TMUX_MSG_UNKNOWN;

    if (!next_token(&rest, tok, sizeof(tok)))
        return TMUX_MSG_UNKNOWN;
    if (parse_int(tok, &msg->command_number) != 0)
        return TMUX_MSG_UNKNOWN;

    if (!next_token(&rest, tok, sizeof(tok)))
        return TMUX_MSG_UNKNOWN;
    if (parse_int(tok, &msg->flags) != 0)
        return TMUX_MSG_UNKNOWN;

    return TMUX_MSG_BEGIN;
}

/**
 * Parse %end <timestamp> <cmd_num> <flags>
 */
static int parse_end(const char *rest, TmuxMessage *msg) {
    char tok[64];
    if (!next_token(&rest, tok, sizeof(tok)))
        return TMUX_MSG_UNKNOWN;
    if (parse_int64(tok, &msg->timestamp) != 0)
        return TMUX_MSG_UNKNOWN;

    if (!next_token(&rest, tok, sizeof(tok)))
        return TMUX_MSG_UNKNOWN;
    if (parse_int(tok, &msg->command_number) != 0)
        return TMUX_MSG_UNKNOWN;

    if (!next_token(&rest, tok, sizeof(tok)))
        return TMUX_MSG_UNKNOWN;
    if (parse_int(tok, &msg->flags) != 0)
        return TMUX_MSG_UNKNOWN;

    return TMUX_MSG_END;
}

/**
 * Parse %exit [reason]
 */
static int parse_exit(const char *rest, TmuxMessage *msg) {
    const char *p = skip_space(rest);
    if (*p != '\0') {
        msg->exit_reason     = p;
        msg->exit_reason_len = strlen(p);
    }
    return TMUX_MSG_EXIT;
}

/**
 * Parse %sessions-changed (no arguments)
 */
static int parse_sessions_changed(const char *rest, TmuxMessage *msg) {
    (void)rest;
    (void)msg;
    return TMUX_MSG_SESSIONS_CHANGED;
}

/**
 * Parse %window-pane-changed @<window_id> %<pane_id>
 */
static int parse_window_pane_changed(const char *rest, TmuxMessage *msg) {
    char tok[TMUX_ID_MAX];
    if (!next_token(&rest, tok, sizeof(tok)))
        return TMUX_MSG_UNKNOWN;
    safe_strcpy(msg->window_id, TMUX_ID_MAX, tok);
    if (!next_token(&rest, tok, sizeof(tok)))
        return TMUX_MSG_UNKNOWN;
    safe_strcpy(msg->pane_id, TMUX_ID_MAX, tok);
    return TMUX_MSG_WINDOW_PANE_CHANGED;
}

/**
 * Parse %session-window-changed $<session_id> @<window_id>
 */
static int parse_session_window_changed(const char *rest, TmuxMessage *msg) {
    char tok[TMUX_ID_MAX];
    if (!next_token(&rest, tok, sizeof(tok)))
        return TMUX_MSG_UNKNOWN;
    safe_strcpy(msg->session_id, TMUX_ID_MAX, tok);
    if (!next_token(&rest, tok, sizeof(tok)))
        return TMUX_MSG_UNKNOWN;
    safe_strcpy(msg->window_id, TMUX_ID_MAX, tok);
    return TMUX_MSG_SESSION_WINDOW_CHANGED;
}

/**
 * Parse %error <message>
 */
static int parse_error(const char *rest, TmuxMessage *msg) {
    const char *p = skip_space(rest);
    msg->error_message     = p;
    msg->error_message_len = strlen(p);
    return TMUX_MSG_ERROR;
}

/* Keyword table for dispatch. */
typedef struct {
    const char *keyword;
    size_t      keyword_len;
    int       (*handler)(const char *rest, TmuxMessage *msg);
} keyword_entry_t;

#define KW_ENTRY(kw, handler) { kw, sizeof(kw) - 1, handler }

static const keyword_entry_t keyword_table[] = {
    KW_ENTRY("%output",           parse_output),
    KW_ENTRY("%layout-change",    parse_layout_change),
    KW_ENTRY("%window-add",       parse_window_add),
    KW_ENTRY("%window-close",          parse_window_close),
    KW_ENTRY("%window-renamed",        parse_window_renamed),
    KW_ENTRY("%unlinked-window-close", parse_unlinked_window_close),
    KW_ENTRY("%session-changed",       parse_session_changed),
    KW_ENTRY("%window-pane-changed",   parse_window_pane_changed),
    KW_ENTRY("%session-window-changed", parse_session_window_changed),
    KW_ENTRY("%sessions-changed", parse_sessions_changed),
    KW_ENTRY("%begin",            parse_begin),
    KW_ENTRY("%end",              parse_end),
    KW_ENTRY("%exit",             parse_exit),
    KW_ENTRY("%error",            parse_error),
};

#define KEYWORD_COUNT (sizeof(keyword_table) / sizeof(keyword_table[0]))

int tmux_parse_line(const char *line, TmuxMessage *msg) {
    if (!msg)
        return TMUX_MSG_UNKNOWN;
    memset(msg, 0, sizeof(*msg));

    if (!line || *line == '\0')
        return TMUX_MSG_UNKNOWN;

    /* All tmux control-mode notifications start with '%'. */
    if (line[0] != '%')
        return TMUX_MSG_UNKNOWN;

    for (size_t i = 0; i < KEYWORD_COUNT; i++) {
        const keyword_entry_t *kw = &keyword_table[i];
        if (strncmp(line, kw->keyword, kw->keyword_len) == 0) {
            char ch = line[kw->keyword_len];
            if (ch == ' ' || ch == '\t' || ch == '\0') {
                return kw->handler(line + kw->keyword_len, msg);
            }
        }
    }

    return TMUX_MSG_UNKNOWN;
}

/* ================================================================
 * tmux_parse_layout  (recursive descent)
 * ================================================================
 *
 * Layout string grammar (simplified):
 *
 *   layout_string := checksum "," node
 *   node          := dims "," x "," y ( "{" node_list "}" |
 *                                       "[" node_list "]" |
 *                                       "," pane_id )
 *   node_list     := node ( "," node )*
 *   dims          := width "x" height
 *
 * We skip the leading 4-hex-digit checksum, then parse the root node.
 * Only leaf nodes (those ending with ",<pane_id>") produce output panes.
 */

#define MAX_LAYOUT_DEPTH 64

typedef struct {
    const char    *input;   /* current position in the layout string */
    TmuxLayoutPane *panes;
    int             max_panes;
    int             count;
    int             error;
} layout_ctx_t;

static void layout_parse_node(layout_ctx_t *ctx, int depth);

/**
 * Read an integer at ctx->input, advance past it.
 * Returns the integer value or -1 on error.
 */
static int layout_read_int(layout_ctx_t *ctx) {
    const char *p = ctx->input;
    if (!isdigit((unsigned char)*p)) {
        ctx->error = 1;
        return -1;
    }
    int v = 0;
    while (isdigit((unsigned char)*p)) {
        int digit = *p - '0';
        if (v > (INT32_MAX - digit) / 10) {
            ctx->error = 1;
            return -1;
        }
        v = v * 10 + digit;
        ++p;
    }
    ctx->input = p;
    return v;
}

/**
 * Expect and consume the character c.
 */
static void layout_expect(layout_ctx_t *ctx, char c) {
    if (*ctx->input == c) {
        ctx->input++;
    } else {
        ctx->error = 1;
    }
}

/**
 * Parse a single node.
 *
 * Format: <width>x<height>,<x>,<y>  followed by one of:
 *   { node_list }    -- vertical split (children arranged side by side)
 *   [ node_list ]    -- horizontal split (children stacked)
 *   ,<pane_id>       -- leaf pane
 */
static void layout_parse_node(layout_ctx_t *ctx, int depth) {
    if (ctx->error)
        return;
    if (depth > MAX_LAYOUT_DEPTH) {
        ctx->error = 1;
        return;
    }

    int width  = layout_read_int(ctx);
    if (ctx->error) return;
    layout_expect(ctx, 'x');
    if (ctx->error) return;
    int height = layout_read_int(ctx);
    if (ctx->error) return;
    layout_expect(ctx, ',');
    if (ctx->error) return;
    int x      = layout_read_int(ctx);
    if (ctx->error) return;
    layout_expect(ctx, ',');
    if (ctx->error) return;
    int y      = layout_read_int(ctx);
    if (ctx->error) return;

    char ch = *ctx->input;

    if (ch == '{' || ch == '[') {
        /* Container node: parse children. */
        char close = (ch == '{') ? '}' : ']';
        ctx->input++;  /* skip opening bracket */

        /* Parse first child. */
        layout_parse_node(ctx, depth + 1);
        if (ctx->error) return;

        /* Parse subsequent children separated by commas. */
        while (*ctx->input == ',') {
            ctx->input++;  /* skip comma */
            layout_parse_node(ctx, depth + 1);
            if (ctx->error) return;
        }

        layout_expect(ctx, close);
    } else if (ch == ',') {
        /* Leaf node: ,<pane_id> */
        ctx->input++;  /* skip comma */
        int pane_id = layout_read_int(ctx);
        if (ctx->error) return;

        if (ctx->count < ctx->max_panes) {
            TmuxLayoutPane *pane = &ctx->panes[ctx->count];
            pane->x       = (int32_t)x;
            pane->y       = (int32_t)y;
            pane->width   = (int32_t)width;
            pane->height  = (int32_t)height;
            pane->pane_id = (int32_t)pane_id;
        }
        ctx->count++;
    } else if (ch == '\0' || ch == '}' || ch == ']') {
        /* We may have reached the end or a closing bracket unexpectedly.
         * This is actually an error for a leaf (no pane_id), but we
         * treat width x height with no further suffix as an error. */
        ctx->error = 1;
    } else {
        ctx->error = 1;
    }
}

int tmux_parse_layout(const char *layout, TmuxLayoutPane *panes,
                      int max_panes, int *out_count) {
    if (!layout || !panes || max_panes <= 0 || !out_count)
        return -1;

    *out_count = 0;

    /* Skip the 4-character hex checksum and the comma that follows. */
    const char *p = layout;
    /* The checksum is exactly 4 hex characters. */
    for (int i = 0; i < 4; i++) {
        if (!isxdigit((unsigned char)*p))
            return -1;
        p++;
    }
    if (*p != ',')
        return -1;
    p++;  /* skip comma after checksum */

    layout_ctx_t ctx;
    ctx.input     = p;
    ctx.panes     = panes;
    ctx.max_panes = max_panes;
    ctx.count     = 0;
    ctx.error     = 0;

    layout_parse_node(&ctx, 0);

    if (ctx.error)
        return -1;

    /* We should have consumed the entire string. */
    if (*ctx.input != '\0')
        return -1;

    *out_count = ctx.count;
    return 0;
}

/* ================================================================
 * Legacy API  (kept for MuxiCore.healthCheck() compatibility)
 * ================================================================ */

struct tmux_protocol {
    int state;
};

tmux_protocol_t *tmux_protocol_create(void) {
    tmux_protocol_t *protocol = calloc(1, sizeof(tmux_protocol_t));
    if (!protocol)
        return NULL;
    protocol->state = 0;
    return protocol;
}

void tmux_protocol_destroy(tmux_protocol_t *protocol) {
    if (protocol)
        free(protocol);
}

int tmux_protocol_feed(tmux_protocol_t *protocol, const char *data, size_t length) {
    if (!protocol || (!data && length > 0))
        return -1;
    (void)data;
    (void)length;
    return 0;
}

void tmux_protocol_reset(tmux_protocol_t *protocol) {
    if (protocol)
        protocol->state = 0;
}
