#ifndef TMUX_PROTOCOL_H
#define TMUX_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

/**
 * Tmux Control-Mode Protocol Parser.
 *
 * Shared across iOS and Android via platform-specific wrappers.
 * Parses tmux control-mode output (lines prefixed with %) and
 * tmux layout strings into structured data.
 */

/* ---------- Message type constants ---------- */
#define TMUX_MSG_UNKNOWN          0
#define TMUX_MSG_OUTPUT           1
#define TMUX_MSG_LAYOUT_CHANGE    2
#define TMUX_MSG_WINDOW_ADD       3
#define TMUX_MSG_WINDOW_CLOSE     4
#define TMUX_MSG_SESSION_CHANGED  5
#define TMUX_MSG_BEGIN            6
#define TMUX_MSG_END              7
#define TMUX_MSG_EXIT             8
#define TMUX_MSG_ERROR            9

/* ---------- Buffer size constants ---------- */
#define TMUX_ID_MAX    32
#define TMUX_NAME_MAX  256

/* ---------- Parsed message ---------- */

/**
 * Holds the fields extracted from a single tmux control-mode line.
 *
 * Pointer fields (output_data, layout, error_message, exit_reason) point
 * directly into the original line buffer.  They are only valid as long as
 * the line string passed to tmux_parse_line() is alive.
 *
 * Which fields are populated depends on the message type returned by
 * tmux_parse_line().
 */
typedef struct {
    char pane_id[TMUX_ID_MAX];        /* "%0", "%1", ... */
    char window_id[TMUX_ID_MAX];      /* "@0", "@1", ... */
    char session_id[TMUX_ID_MAX];     /* "$0", "$1", ... */
    char session_name[TMUX_NAME_MAX];

    const char *layout;               /* points into original line */
    size_t layout_len;

    const char *output_data;          /* points into original line */
    size_t output_len;

    const char *error_message;        /* points into original line */
    size_t error_message_len;

    const char *exit_reason;          /* points into original line */
    size_t exit_reason_len;

    int64_t timestamp;
    int command_number;
    int flags;
} TmuxMessage;

/* ---------- Layout pane ---------- */

/**
 * One leaf pane in a parsed tmux layout string.
 */
typedef struct {
    int32_t x, y, width, height;
    int32_t pane_id;
} TmuxLayoutPane;

/* ---------- Public API ---------- */

/**
 * Parse one line from tmux -CC output.
 *
 * @param line   Null-terminated line (without trailing newline).
 * @param msg    Out-parameter; zero-initialised, then populated.
 * @return       One of the TMUX_MSG_* constants.
 */
int tmux_parse_line(const char *line, TmuxMessage *msg);

/**
 * Parse a tmux layout string into an array of leaf pane geometries.
 *
 * Layout strings look like:
 *   abcd,80x24,0,0{40x24,0,0,0,39x24,41,0,1}
 *
 * @param layout     Null-terminated layout string.
 * @param panes      Output array.
 * @param max_panes  Capacity of the output array.
 * @param out_count  Number of panes written on success.
 * @return           0 on success, -1 on error.
 */
int tmux_parse_layout(const char *layout, TmuxLayoutPane *panes,
                      int max_panes, int *out_count);

/* ---------- Legacy API (kept for health-check compatibility) ---------- */

/// Opaque protocol handler state (legacy).
typedef struct tmux_protocol tmux_protocol_t;

/// Create a new tmux protocol handler. Returns NULL on allocation failure.
tmux_protocol_t *tmux_protocol_create(void);

/// Destroy a tmux protocol handler and free associated memory.
void tmux_protocol_destroy(tmux_protocol_t *protocol);

/// Feed a chunk of control-mode output into the handler.
/// Returns 0 on success, -1 on error.
int tmux_protocol_feed(tmux_protocol_t *protocol, const char *data, size_t length);

/// Reset the protocol handler to its initial state.
void tmux_protocol_reset(tmux_protocol_t *protocol);

#endif /* TMUX_PROTOCOL_H */
