// Claude Code Statusline - Odin Version (v5)
//
// A fast statusline for Claude Code written in Odin.
// Full port of the C version with compact layout.
//
// Build: odin build . -o:speed -out:statusline_odin
// Usage: Set in ~/.claude/settings.json statusLine.command
//
// Shared state files:
//   /dev/shm/statusline-cache.<gppid>   - Per-session cached state
//   /dev/shm/statusline-usage.<gppid>   - Per-session usage quota cache
//   /dev/shm/statusline-cleanup         - Sentinel for cleanup interval
//   /dev/shm/claude-git-<hash>          - Per-repo git status cache
//   /tmp/statusline-<uid>/<pid>.log     - Debug timing logs

package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"

/* -------------------------------------------------------------------------- */
/* ANSI Colors (Dracula Theme)                                                */
/* -------------------------------------------------------------------------- */

ANSI_RESET      :: "\x1b[0m"
ANSI_BOLD       :: "\x1b[1m"

ANSI_BG_PURPLE  :: "\x1b[48;2;189;147;249m"
ANSI_BG_ORANGE  :: "\x1b[48;2;255;184;108m"
ANSI_BG_DARK    :: "\x1b[48;2;68;71;90m"
ANSI_BG_GREEN   :: "\x1b[48;2;72;209;104m"
ANSI_BG_MINT    :: "\x1b[48;2;40;167;69m"
ANSI_BG_COMMENT :: "\x1b[48;2;98;114;164m"
ANSI_BG_RED     :: "\x1b[48;2;255;85;85m"
ANSI_BG_YELLOW  :: "\x1b[48;2;241;250;140m"
ANSI_BG_CYAN    :: "\x1b[48;2;139;233;253m"

ANSI_FG_BLACK   :: "\x1b[38;2;40;42;54m"
ANSI_FG_WHITE   :: "\x1b[38;2;248;248;242m"
ANSI_FG_PURPLE  :: "\x1b[38;2;189;147;249m"
ANSI_FG_DARK    :: "\x1b[38;2;68;71;90m"
ANSI_FG_GREEN   :: "\x1b[38;2;80;250;123m"
ANSI_FG_COMMENT :: "\x1b[38;2;98;114;164m"
ANSI_FG_YELLOW  :: "\x1b[38;2;241;250;140m"
ANSI_FG_ORANGE  :: "\x1b[38;2;255;184;108m"
ANSI_FG_RED     :: "\x1b[38;2;255;85;85m"
ANSI_FG_CYAN    :: "\x1b[38;2;139;233;253m"
ANSI_FG_PINK    :: "\x1b[38;2;255;121;198m"

// Powerline separators
SEP_ROUND   :: "\uE0B4"  //

// Nerd Font icons
ICON_BRANCH    :: "\uF126"   //  git branch
ICON_WORKTREE  :: "\uF1E0"   //  share-alt (linked worktree)
ICON_UNTRACKED :: "\uF128"   //  question (untracked files)
ICON_FOLDER    :: "\uF07C"   //  folder open
ICON_DOLLAR    :: "\uF155"   //  dollar
ICON_CLOCK     :: "\uF017"   //  clock
ICON_STASH     :: "\uF01C"   //  inbox/stash
ICON_INSERT    :: "\uF040"   //  pencil (insert mode)
ICON_NORMAL    :: "\uE7C5"   //  vim logo (normal mode)
ICON_STAGED    :: "\uF00C"   //  checkmark (staged)
ICON_MODIFIED  :: "\uF040"   //  pencil (modified)
ICON_WARN      :: "\uF071"   //  warning triangle
ICON_SYNC      :: "\uF0EC"   //  exchange (last send/receive)
ICON_BRAIN     :: "\U000F09D1"
ICON_TOKENS    :: "\uF1C0"   //  database — context window occupancy
ICON_BURN      :: "\uF06D"   //  flame — token burn rate
ICON_COMPACT   :: "\uF066"   //  compress — countdown to compaction   // \uDB82\uDDD1 md-brain (extended thinking on)

/* -------------------------------------------------------------------------- */
/* Output Buffer                                                              */
/* -------------------------------------------------------------------------- */

OutBuf :: struct {
    data:     [16384]u8,
    len:      int,
    prev_bg:  string,
    overflow: bool,
}

out_str :: proc(buf: ^OutBuf, s: string) {
    if buf.overflow do return
    if buf.len + len(s) < len(buf.data) {
        copy(buf.data[buf.len:], s)
        buf.len += len(s)
    } else {
        buf.overflow = true
    }
}

out_char :: proc(buf: ^OutBuf, c: u8) {
    if buf.overflow do return
    if buf.len + 1 < len(buf.data) {
        buf.data[buf.len] = c
        buf.len += 1
    } else {
        buf.overflow = true
    }
}

out_int :: proc(buf: ^OutBuf, val: i64) {
    tmp: [20]u8
    s := fmt.bprintf(tmp[:], "%d", val)
    out_str(buf, s)
}

out_f64 :: proc(buf: ^OutBuf, val: f64, decimals: int) {
    tmp: [32]u8
    s: string
    switch decimals {
    case 0: s = fmt.bprintf(tmp[:], "%.0f", val)
    case 1: s = fmt.bprintf(tmp[:], "%.1f", val)
    case 2: s = fmt.bprintf(tmp[:], "%.2f", val)
    case:   s = fmt.bprintf(tmp[:], "%f", val)
    }
    out_str(buf, s)
}

/* -------------------------------------------------------------------------- */
/* Segment Builder                                                            */
/* -------------------------------------------------------------------------- */

bg_to_fg :: proc(buf: []u8, bg: string) -> string {
    // All BG strings are \x1b[48;2;R;G;Bm — byte[2] is '4'
    // FG equivalent is \x1b[38;2;R;G;Bm — just flip to '3'
    if len(bg) < 4 do return ""
    if len(bg) > len(buf) do return ""

    copy(buf, bg)
    buf[2] = '3'
    return string(buf[:len(bg)])
}

// Truncation is segment-boundary only: if any part of a segment would
// overflow the buffer, the whole segment is rolled back and every later
// segment is skipped — a partial escape sequence renders as garbage.
// Divider colour for two adjacent segments sharing a background. FG_COMMENT is
// the obvious choice and it is invisible on BG_COMMENT -- literally the same
// colour -- which silently erased the separator between the quota figures and
// the reset countdown. Pick something that contrasts with the actual background.
divider_color :: proc(bg: string) -> string {
    if bg == ANSI_BG_COMMENT do return ANSI_FG_DARK
    return ANSI_FG_COMMENT
}

segment :: proc(
    buf: ^OutBuf,
    bg: string,
    fg: string,
    text: string,
    first: bool,
) {
    if buf.overflow do return
    saved_len := buf.len

    if !first && len(buf.prev_bg) > 0 {
        if buf.prev_bg == bg {
            out_str(buf, bg)
            out_str(buf, divider_color(bg))
            out_str(buf, "|")
            out_str(buf, ANSI_RESET)
        } else {
            fg_buf: [64]u8
            out_str(buf, bg)
            out_str(buf, bg_to_fg(fg_buf[:], buf.prev_bg))
            out_str(buf, SEP_ROUND)
            out_str(buf, ANSI_RESET)
        }
    }

    out_str(buf, bg)
    out_str(buf, fg)
    out_char(buf, ' ')
    out_str(buf, text)
    out_char(buf, ' ')
    out_str(buf, ANSI_RESET)

    if buf.overflow {
        buf.len = saved_len
        return
    }
    buf.prev_bg = bg
}

segment_end :: proc(buf: ^OutBuf) {
    if buf.overflow || len(buf.prev_bg) == 0 do return
    saved_len := buf.len
    fg_buf: [64]u8
    out_str(buf, bg_to_fg(fg_buf[:], buf.prev_bg))
    out_str(buf, SEP_ROUND)
    out_str(buf, ANSI_RESET)
    if buf.overflow do buf.len = saved_len
}

/* -------------------------------------------------------------------------- */
/* JSON Parsing (Single-pass for stdin, per-key for usage API)                */
/* -------------------------------------------------------------------------- */

JsonFields :: struct {
    current_dir:           string,
    display_name:          string,
    mode:                  string,
    total_lines_added:     i64,
    total_lines_removed:   i64,
    total_duration_ms:     i64,
    used_percentage:       f64,
    context_window_size:   i64,
    total_input_tokens:    i64,
    exceeds_200k:          bool,
    thinking_enabled:      bool,
    rl_five_hour_pct:      f64,
    rl_five_hour_reset:    i64,
    rl_seven_day_pct:      f64,
    rl_seven_day_reset:    i64,
}

// Parse a string value at cursor (past ':'). Returns
// slice into original json.
json_parse_string_at :: proc(
    json: string,
    pos: ^int,
) -> string {
    i := pos^
    for i < len(json) && (json[i] == ' ' || json[i] == '\t') {
        i += 1
    }
    if i >= len(json) || json[i] != '"' do return ""
    i += 1
    start := i
    for i < len(json) && json[i] != '"' {
        i += 1
    }
    result := json[start:i]
    if i < len(json) do i += 1
    pos^ = i
    return result
}

// Parse an i64 value at cursor (past ':')
json_parse_i64_at :: proc(
    json: string,
    pos: ^int,
) -> i64 {
    i := pos^
    for i < len(json) && (json[i] == ' ' || json[i] == '\t') {
        i += 1
    }
    start := i
    for i < len(json) &&
        ((json[i] >= '0' && json[i] <= '9') ||
            json[i] == '-' || json[i] == '+') {
        i += 1
    }
    pos^ = i
    if i == start do return 0
    val, ok := strconv.parse_i64(json[start:i])
    return ok ? val : 0
}

// Parse an f64 value at cursor (past ':')
json_parse_f64_at :: proc(
    json: string,
    pos: ^int,
) -> f64 {
    i := pos^
    for i < len(json) && (json[i] == ' ' || json[i] == '\t') {
        i += 1
    }
    start := i
    for i < len(json) &&
        ((json[i] >= '0' && json[i] <= '9') ||
            json[i] == '-' || json[i] == '+' ||
            json[i] == '.' || json[i] == 'e' ||
            json[i] == 'E') {
        i += 1
    }
    pos^ = i
    if i == start do return 0.0
    val, ok := strconv.parse_f64(json[start:i])
    return ok ? val : 0.0
}

// Try to match a key literal at position. Returns
// length if matched, 0 otherwise.
try_key :: proc(json: string, pos: int, key: string) -> int {
    if pos + len(key) > len(json) do return 0
    if json[pos:pos + len(key)] == key do return len(key)
    return 0
}

// Return the index just past the '}' that matches the '{' at open_idx.
// Skips braces that appear inside quoted strings.
json_object_end :: proc(json: string, open_idx: int) -> int {
    depth := 0
    in_str := false
    i := open_idx
    for i < len(json) {
        c := json[i]
        if in_str {
            if c == '\\' { i += 2; continue }
            if c == '"' do in_str = false
        } else if c == '"' {
            in_str = true
        } else if c == '{' {
            depth += 1
        } else if c == '}' {
            depth -= 1
            if depth == 0 do return i + 1
        }
        i += 1
    }
    return i
}

// Parse the token/percentage fields from the slice spanning the
// `context_window` object. Scoped on purpose: `used_percentage` also lives
// under `rate_limits.{five_hour,seven_day}`, and a flat whole-document scan
// would grab whichever copy appears last (the 7-day quota), not the context.
parse_context_window :: proc(json: string, fields: ^JsonFields) {
    i := 0
    for i < len(json) {
        for i < len(json) && json[i] != '"' {
            i += 1
        }
        if i >= len(json) do break
        klen: int
        if klen = try_key(json, i, "\"total_input_tokens\":"); klen > 0 {
            i += klen
            fields.total_input_tokens = json_parse_i64_at(json, &i)
            continue
        }
        if klen = try_key(json, i, "\"context_window_size\":"); klen > 0 {
            i += klen
            fields.context_window_size = json_parse_i64_at(json, &i)
            continue
        }
        if klen = try_key(json, i, "\"used_percentage\":"); klen > 0 {
            i += klen
            fields.used_percentage = json_parse_f64_at(json, &i)
            continue
        }
        i += 1
    }
}

// Single-pass: scan for '"', dispatch on char after it
// Parse one rate-limit window object: {"used_percentage": N, "resets_at": E}
// (resets_at is epoch seconds). Scoped like parse_context_window because
// used_percentage also appears under context_window.
parse_rate_window :: proc(obj: string) -> (pct: f64, reset: i64) {
    if i := strings.index(obj, "\"used_percentage\":"); i >= 0 {
        pos := i + len("\"used_percentage\":")
        pct = json_parse_f64_at(obj, &pos)
    }
    if i := strings.index(obj, "\"resets_at\":"); i >= 0 {
        pos := i + len("\"resets_at\":")
        reset = json_parse_i64_at(obj, &pos)
    }
    return
}

// Scoped parse of the `rate_limits` object — quota straight from the stdin
// JSON every render. This is the PRIMARY quota source; the background OAuth
// usage fetch proved flaky (a failed fetch writes an all-zeros cache with a
// fresh TTL, blanking the quota segment for 60s+) and is now only a
// fallback plus the source for the opus weekly window.
parse_rate_limits :: proc(json: string, fields: ^JsonFields) {
    if i := strings.index(json, "\"five_hour\":"); i >= 0 {
        start := i + len("\"five_hour\":")
        for start < len(json) && json[start] != '{' do start += 1
        if start < len(json) {
            end := json_object_end(json, start)
            fields.rl_five_hour_pct, fields.rl_five_hour_reset =
                parse_rate_window(json[start:end])
        }
    }
    if i := strings.index(json, "\"seven_day\":"); i >= 0 {
        start := i + len("\"seven_day\":")
        for start < len(json) && json[start] != '{' do start += 1
        if start < len(json) {
            end := json_object_end(json, start)
            fields.rl_seven_day_pct, fields.rl_seven_day_reset =
                parse_rate_window(json[start:end])
        }
    }
}

json_parse_all :: proc(json: string) -> JsonFields {
    fields: JsonFields
    i := 0
    for i < len(json) {
        // Scan to next '"'
        for i < len(json) && json[i] != '"' {
            i += 1
        }
        if i >= len(json) do break

        klen: int
        // Dispatch on char after opening quote
        if i + 1 >= len(json) { i += 1; continue }
        switch json[i + 1] {
        case 'c':
            if klen = try_key(json, i, "\"current_dir\":"); klen > 0 {
                i += klen
                fields.current_dir = json_parse_string_at(json, &i)
                continue
            }
            if klen = try_key(json, i, "\"context_window\":"); klen > 0 {
                i += klen
                // Skip whitespace to the opening brace, then parse the whole
                // object as a scoped unit. context_window can be null early
                // in a session / right after /compact — guard for that.
                for i < len(json) && (json[i] == ' ' || json[i] == '\t') {
                    i += 1
                }
                if i < len(json) && json[i] == '{' {
                    end := json_object_end(json, i)
                    parse_context_window(json[i:end], &fields)
                    i = end
                }
                continue
            }
        case 'd':
            if klen = try_key(json, i, "\"display_name\":"); klen > 0 {
                i += klen
                fields.display_name = json_parse_string_at(json, &i)
                continue
            }
        case 'm':
            if klen = try_key(json, i, "\"mode\":"); klen > 0 {
                i += klen
                fields.mode = json_parse_string_at(json, &i)
                continue
            }
        case 't':
            if klen = try_key(json, i, "\"total_lines_added\":"); klen > 0 {
                i += klen
                fields.total_lines_added = json_parse_i64_at(json, &i)
                continue
            }
            if klen = try_key(json, i, "\"total_lines_removed\":"); klen > 0 {
                i += klen
                fields.total_lines_removed = json_parse_i64_at(json, &i)
                continue
            }
            if klen = try_key(json, i, "\"total_duration_ms\":"); klen > 0 {
                i += klen
                fields.total_duration_ms = json_parse_i64_at(json, &i)
                continue
            }
            if klen = try_key(json, i, "\"thinking\":"); klen > 0 {
                i += klen
                // value is an object {"enabled": true}. Skip to the brace,
                // grab it as a scoped unit (can be null), find "enabled".
                for i < len(json) && (json[i] == ' ' || json[i] == '\t') {
                    i += 1
                }
                if i < len(json) && json[i] == '{' {
                    end := json_object_end(json, i)
                    obj := json[i:end]
                    if ei := strings.index(obj, "\"enabled\":"); ei >= 0 {
                        j := ei + len("\"enabled\":")
                        for j < len(obj) && (obj[j] == ' ' || obj[j] == '\t') {
                            j += 1
                        }
                        fields.thinking_enabled = j < len(obj) && obj[j] == 't'
                    }
                    i = end
                }
                continue
            }
        case 'r':
            if klen = try_key(json, i, "\"rate_limits\":"); klen > 0 {
                i += klen
                for i < len(json) && (json[i] == ' ' || json[i] == '\t') {
                    i += 1
                }
                if i < len(json) && json[i] == '{' {
                    end := json_object_end(json, i)
                    parse_rate_limits(json[i:end], &fields)
                    i = end
                }
                continue
            }
        case 'e':
            if klen = try_key(json, i, "\"exceeds_200k_tokens\":"); klen > 0 {
                i += klen
                // value is a bare literal: skip space, check for 't'
                j := i
                for j < len(json) && (json[j] == ' ' || json[j] == '\t') {
                    j += 1
                }
                fields.exceeds_200k = j < len(json) && json[j] == 't'
                i = j
                continue
            }
        }
        i += 1  // skip unrecognized quote
    }
    return fields
}

// Per-key helpers (used only by usage cache in
// background child, not hot path)
json_get_string :: proc(
    json: string,
    key: string,
) -> string {
    needle_buf: [256]u8
    needle := fmt.bprintf(
        needle_buf[:],
        "\"%s\":",
        key,
    )

    start_idx := strings.index(json, needle)
    if start_idx < 0 do return ""

    rest := json[start_idx + len(needle):]
    i := 0
    for i < len(rest) && (rest[i] == ' ' || rest[i] == '\t') {
        i += 1
    }
    if i >= len(rest) || rest[i] != '"' do return ""
    i += 1
    start := i
    for i < len(rest) && rest[i] != '"' {
        i += 1
    }
    return rest[start:i]
}

json_find_object_f64 :: proc(
    json: string,
    obj_key: string,
    field_key: string,
) -> f64 {
    obj_needle_buf: [256]u8
    obj_needle := fmt.bprintf(
        obj_needle_buf[:],
        "\"%s\":",
        obj_key,
    )

    idx := strings.index(json, obj_needle)
    if idx < 0 do return 0.0

    rest := json[idx + len(obj_needle):]
    brace := strings.index(rest, "{")
    if brace < 0 do return 0.0

    // Parse "utilization": <f64> from within object
    obj := rest[brace:]
    key_needle_buf: [256]u8
    key_needle := fmt.bprintf(
        key_needle_buf[:],
        "\"%s\":",
        field_key,
    )
    ki := strings.index(obj, key_needle)
    if ki < 0 do return 0.0

    pos := ki + len(key_needle)
    return json_parse_f64_at(obj, &pos)
}

// Like json_find_object_f64 but returns a string field (e.g. resets_at).
json_find_object_str :: proc(
    json: string,
    obj_key: string,
    field_key: string,
) -> string {
    obj_needle_buf: [256]u8
    obj_needle := fmt.bprintf(
        obj_needle_buf[:],
        "\"%s\":",
        obj_key,
    )

    idx := strings.index(json, obj_needle)
    if idx < 0 do return ""

    rest := json[idx + len(obj_needle):]
    brace := strings.index(rest, "{")
    if brace < 0 do return ""

    obj := rest[brace:]
    key_needle_buf: [256]u8
    key_needle := fmt.bprintf(
        key_needle_buf[:],
        "\"%s\":",
        field_key,
    )
    ki := strings.index(obj, key_needle)
    if ki < 0 do return ""

    pos := ki + len(key_needle)
    return json_parse_string_at(obj, &pos)
}

// Days since Unix epoch for a civil (proleptic Gregorian) date.
// Howard Hinnant's days_from_civil algorithm.
days_from_civil :: proc(y, m, d: i64) -> i64 {
    yy := m <= 2 ? y - 1 : y
    era := (yy >= 0 ? yy : yy - 399) / 400
    yoe := yy - era * 400
    doy := (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
    doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

// Parse an RFC3339/ISO8601 timestamp ("2026-06-07T18:00:00Z") to epoch
// seconds (UTC). Returns 0 on any parse failure. Sub-second and timezone
// offsets are ignored — the API returns UTC ("Z").
iso8601_to_epoch :: proc(s: string) -> i64 {
    if len(s) < 19 do return 0
    if s[4] != '-' || s[7] != '-' || s[10] != 'T' do return 0

    pi :: proc(sub: string) -> (i64, bool) {
        return strconv.parse_i64(sub)
    }
    y,  oy := pi(s[0:4])
    mo, om := pi(s[5:7])
    d,  od := pi(s[8:10])
    h,  oh := pi(s[11:13])
    mi, oi := pi(s[14:16])
    se, os := pi(s[17:19])
    if !(oy && om && od && oh && oi && os) do return 0
    if mo < 1 || mo > 12 do return 0

    days := days_from_civil(y, mo, d)
    return days * 86400 + h * 3600 + mi * 60 + se
}

// Compact "resets in" countdown: 45m, 2h13m, or 3d2h for longer windows.
format_countdown :: proc(buf: []u8, secs: i64) -> string {
    if secs <= 0 do return ""
    if secs < 3600 {
        return fmt.bprintf(buf, "%dm", secs / 60)
    }
    if secs < 86400 {
        h := secs / 3600
        m := (secs % 3600) / 60
        return fmt.bprintf(buf, "%dh%dm", h, m)
    }
    d := secs / 86400
    h := (secs % 86400) / 3600
    return fmt.bprintf(buf, "%dd%dh", d, h)
}

/* -------------------------------------------------------------------------- */
/* Path Abbreviation (with issue number preservation)                         */
/* -------------------------------------------------------------------------- */

abbrev_path :: proc(result_buf: []u8, path: string) -> string {
    working_buf: [512]u8

    home := string(posix.getenv("HOME"))
    buf: string

    if len(home) > 0 && strings.has_prefix(path, home) {
        working_buf[0] = '~'
        rest := path[len(home):]
        n := min(len(rest), len(working_buf) - 1)
        copy(working_buf[1:], rest[:n])
        buf = string(working_buf[:1 + n])
    } else {
        buf = path
    }

    if buf == "~" do return "~"

    has_slash := false
    for i in 0 ..< len(buf) {
        if buf[i] == '/' { has_slash = true; break }
    }
    if !has_slash {
        n := min(len(buf), len(result_buf) - 1)
        copy(result_buf[:], buf[:n])
        return string(result_buf[:n])
    }

    // Find last slash position
    last_slash := 0
    for i in 0 ..< len(buf) {
        if buf[i] == '/' do last_slash = i
    }

    result_len := 0
    scan := 0

    for scan < len(buf) &&
        result_len < len(result_buf) - 1 {
        if buf[scan] == '/' {
            result_buf[result_len] = '/'
            result_len += 1
            scan += 1
            continue
        }

        // Find end of this component
        comp_start := scan
        for scan < len(buf) && buf[scan] != '/' {
            scan += 1
        }
        comp_len := scan - comp_start

        if comp_start < last_slash &&
            buf[comp_start] != '~' {
            // Scan for digit run (issue number)
            digit_start, digit_end: int
            found_digits := false
            for i in comp_start ..< comp_start + comp_len {
                if buf[i] >= '0' && buf[i] <= '9' {
                    if !found_digits {
                        digit_start = i
                        found_digits = true
                    }
                    digit_end = i + 1
                } else if found_digits {
                    break
                }
            }

            if found_digits &&
                digit_end - digit_start >= 2 {
                // Copy digit run
                dlen := digit_end - digit_start
                n := min(
                    dlen,
                    len(result_buf) - 1 - result_len,
                )
                copy(
                    result_buf[result_len:],
                    buf[digit_start:digit_start + n],
                )
                result_len += n
                // Ellipsis if more after digits
                if digit_end < comp_start + comp_len &&
                    result_len + 3 <=
                        len(result_buf) - 1 {
                    // U+2026 ellipsis (UTF-8: E2 80 A6)
                    result_buf[result_len] = 0xe2
                    result_buf[result_len + 1] = 0x80
                    result_buf[result_len + 2] = 0xa6
                    result_len += 3
                }
            } else {
                // No issue number: first char only
                if result_len < len(result_buf) - 1 {
                    result_buf[result_len] =
                        buf[comp_start]
                    result_len += 1
                }
            }
        } else {
            // Last component or ~: copy fully
            n := min(
                comp_len,
                len(result_buf) - 1 - result_len,
            )
            copy(
                result_buf[result_len:],
                buf[comp_start:comp_start + n],
            )
            result_len += n
        }
    }

    return string(result_buf[:result_len])
}

/* -------------------------------------------------------------------------- */
/* Model Abbreviation                                                         */
/* -------------------------------------------------------------------------- */

// "Opus 5 (1M context)" -> "Op5", "Sonnet 5" -> "Sonn5", "Haiku 4.5" -> "Haik4.5".
//
// The previous version required a digit.digit version and so silently stopped
// abbreviating the moment models were named "Opus 5" instead of "Opus 4.6" —
// it fell through to copy-as-is and spent 19 cells on "Opus 5 (1M context)".
// Now a bare major version matches, and any trailing parenthetical is dropped.
abbreviate_model :: proc(abbrev_buf: []u8, model: string) -> string {
    Family :: struct {
        name:   string,
        abbrev: string,
    }
    families := [4]Family{
        {"Opus", "Op"},
        {"Sonnet", "Sonn"},
        {"Haiku", "Haik"},
        {"Fable", "Fabl"},
    }

    // First digit run, with optional .minor — accepts "5" as well as "4.5".
    version_start := -1
    for i in 0 ..< len(model) {
        if model[i] >= '0' && model[i] <= '9' {
            version_start = i
            break
        }
    }

    // Find family name
    abbrev: string
    for f in families {
        if strings.contains(model, f.name) {
            abbrev = f.abbrev
            break
        }
    }

    if abbrev != "" && version_start >= 0 {
        pos := 0
        copy(abbrev_buf[:], abbrev)
        pos = len(abbrev)
        i := version_start
        for i < len(model) && pos < len(abbrev_buf) &&
            ((model[i] >= '0' && model[i] <= '9') ||
                    model[i] == '.') {
            abbrev_buf[pos] = model[i]
            pos += 1
            i += 1
        }
        return string(abbrev_buf[:pos])
    }

    // Fallback: copy as-is
    n := min(len(model), len(abbrev_buf) - 1)
    copy(abbrev_buf[:], model[:n])
    return string(abbrev_buf[:n])
}

/* -------------------------------------------------------------------------- */
/* Context Bar (Compact block style)                                          */
/* -------------------------------------------------------------------------- */

FILLED_BLOCK :: "\u25b0"  // filled rectangle
EMPTY_BLOCK :: "\u25b1"  // empty (outlined) rectangle

// Color for the percentage label (matches leading edge).
//
// Thresholds track when compaction actually looms, not raw fill. Half a context
// window is a normal working state, so the old 40%/60% yellow/orange pair spent
// most of a session shouting; auto-compact is the real event, and it lands
// around 80-92%.
pct_label_color :: proc(pct: i64) -> string {
    if pct >= 90 do return ANSI_FG_RED      // compact imminent
    if pct >= 80 do return ANSI_FG_ORANGE   // compact soon
    if pct >= 65 do return ANSI_FG_YELLOW   // worth knowing
    return ANSI_FG_GREEN                    // normal working range
}

make_context_bar :: proc(
    bar_buf: []u8,
    pct: i64,
    ctx_size: i64,
    input_tokens: i64,
    width: int = 10,
) -> string {
    clamped := min(pct, 100)
    WIDTH := width
    // Number of filled cells (rounded)
    filled := int((clamped * i64(WIDTH) + 50) / 100)

    pos := 0

    // Token count (bright white), right-aligned to the width of the full
    // context window (the largest value it can reach) so the bar after it
    // never shifts horizontally as the count grows or shrinks.
    if input_tokens > 0 {
        tok_buf: [16]u8
        tok := format_tokens(tok_buf[:], input_tokens)
        width_buf: [16]u8
        full := format_tokens(width_buf[:], ctx_size)
        field := ctx_size > 0 ? len(full) : len(tok)
        for _ in len(tok) ..< field {
            bar_buf[pos] = ' '
            pos += 1
        }
        s := fmt.bprintf(bar_buf[pos:], "%s%s %s ", ANSI_FG_WHITE, ICON_TOKENS, tok)
        pos += len(s)
    }

    // Bar: WIDTH cells of filled / empty rectangles with color zones
    for cell in 0 ..< WIDTH {
        if cell < filled {
            // Color by the percentage this cell represents so 5- and
            // 10-wide bars share one gradient.
            color := pct_label_color(i64(cell * 100 / WIDTH + 5))
            copy(bar_buf[pos:], color)
            pos += len(color)
            copy(bar_buf[pos:], FILLED_BLOCK)
            pos += len(FILLED_BLOCK)
        } else {
            copy(bar_buf[pos:], ANSI_FG_WHITE)
            pos += len(ANSI_FG_WHITE)
            copy(bar_buf[pos:], EMPTY_BLOCK)
            pos += len(EMPTY_BLOCK)
        }
    }

    // Percentage label
    bar_buf[pos] = ' '
    pos += 1
    label_color := pct_label_color(clamped)
    copy(bar_buf[pos:], label_color)
    pos += len(label_color)
    s := fmt.bprintf(bar_buf[pos:], "%d", clamped)
    pos += len(s)
    bar_buf[pos] = '%'
    pos += 1

    return string(bar_buf[:pos])
}

/* -------------------------------------------------------------------------- */
/* Duration Formatting                                                        */
/* -------------------------------------------------------------------------- */

format_duration :: proc(dur_buf: []u8, ms: i64) -> string {
    if ms < 1000 {
        return fmt.bprintf(dur_buf[:], "%dms", ms)
    } else if ms < 60000 {
        return fmt.bprintf(
            dur_buf[:],
            "%.1fs",
            f64(ms) / 1000.0,
        )
    } else if ms < 3600000 {
        mins := ms / 60000
        secs := (ms % 60000) / 1000
        return fmt.bprintf(dur_buf[:], "%dm%ds", mins, secs)
    } else {
        hours := ms / 3600000
        mins := (ms % 3600000) / 60000
        return fmt.bprintf(dur_buf[:], "%dh%dm", hours, mins)
    }
}

// Exact count with thousands separators (no rounding), e.g. 69287 -> "69,287".
// The previous "%dk" form rounded 69287 down to "69k", hiding real movement.
format_tokens :: proc(buf: []u8, tokens: i64) -> string {
    if tokens < 1000 {
        return fmt.bprintf(buf, "%d", tokens)
    }
    // Collect digits least-significant first.
    digits: [24]u8
    n := tokens
    dlen := 0
    for n > 0 {
        digits[dlen] = u8('0' + (n % 10))
        n /= 10
        dlen += 1
    }
    // Emit most-significant first, inserting a comma every third digit.
    pos := 0
    for idx := dlen - 1; idx >= 0; idx -= 1 {
        buf[pos] = digits[idx]
        pos += 1
        if idx > 0 && idx % 3 == 0 {
            buf[pos] = ','
            pos += 1
        }
    }
    return string(buf[:pos])
}

/* -------------------------------------------------------------------------- */
/* Git Status (Fast Path)                                                     */
/* -------------------------------------------------------------------------- */

GitStatus :: struct {
    valid:       bool,
    is_worktree: bool,
    branch:      string,
    stashes:     i64,
    modified:    u32,
    staged:      u32,
    untracked:   u32,
    ahead:       u32,
    behind:      u32,
    cache_state: CacheState,
}

// Resolved git locations for a working directory.
// gitdir holds the per-worktree files (HEAD, index); commondir holds the
// shared ones (logs/refs/stash, objects). For a plain checkout the two are
// the same directory. Getting them backwards shows the WRONG branch.
GitPaths :: struct {
    root:        string, // worktree top level (dir containing .git)
    gitdir:      string, // per-worktree: HEAD, index live here
    commondir:   string, // shared: logs/refs/stash lives here
    is_worktree: bool,
}

GitPathsBuf :: struct {
    root:      [512]u8,
    gitdir:    [512]u8,
    commondir: [512]u8,
}

// Read a small text file into buf, trimmed of trailing whitespace.
read_small_file :: proc(path: string, buf: []u8) -> (string, bool) {
    path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
    fd := posix.open(path_cstr, {})
    if fd < 0 do return "", false
    defer posix.close(fd)
    n := posix.read(fd, raw_data(buf), len(buf) - 1)
    if n <= 0 do return "", false
    return strings.trim_right_space(string(buf[:n])), true
}

// Join base + "/" + rel into out (rel may be absolute, then it wins).
join_path :: proc(out: []u8, base: string, rel: string) -> string {
    if len(rel) > 0 && rel[0] == '/' {
        n := min(len(rel), len(out))
        copy(out, rel[:n])
        return string(out[:n])
    }
    return fmt.bprintf(out, "%s/%s", base, rel)
}

// Walk upward from start until a .git entry is found (dir OR file), then
// resolve gitdir/commondir. Pure syscalls, no fork. Caps at 40 levels.
resolve_git_paths :: proc(
    start: string,
    bufs: ^GitPathsBuf,
) -> (
    gp: GitPaths,
    ok: bool,
) {
    if len(start) == 0 || start[0] != '/' do return {}, false

    // Current candidate root lives in bufs.root.
    n := min(len(start), len(bufs.root) - 8)
    copy(bufs.root[:], start[:n])
    root_len := n

    probe_buf: [560]u8
    st: posix.stat_t
    found := false
    is_file := false

    for _ in 0 ..< 40 {
        root := string(bufs.root[:root_len])
        probe := fmt.bprintf(probe_buf[:], "%s/.git", root)
        probe_cstr := strings.clone_to_cstring(probe, context.temp_allocator)
        if posix.stat(probe_cstr, &st) == .OK {
            found = true
            is_file = !posix.S_ISDIR(st.st_mode)
            break
        }
        if root_len <= 1 do break // reached "/"
        // Strip last path component.
        for root_len > 1 && bufs.root[root_len - 1] != '/' do root_len -= 1
        if root_len > 1 do root_len -= 1 // drop the '/'
    }
    if !found do return {}, false

    gp.root = string(bufs.root[:root_len])

    if !is_file {
        // Plain checkout: gitdir == commondir == <root>/.git
        gp.gitdir = fmt.bprintf(bufs.gitdir[:], "%s/.git", gp.root)
        gp.commondir = fmt.bprintf(bufs.commondir[:], "%s/.git", gp.root)
        gp.is_worktree = false
        return gp, true
    }

    // Worktree: .git is a file "gitdir: <path>" (path may be relative).
    gitfile_buf: [512]u8
    gitfile_path := fmt.bprintf(probe_buf[:], "%s/.git", gp.root)
    content, rok := read_small_file(gitfile_path, gitfile_buf[:])
    if !rok do return {}, false
    prefix :: "gitdir: "
    if !strings.has_prefix(content, prefix) do return {}, false
    gd := content[len(prefix):]
    if nl := strings.index(gd, "\n"); nl >= 0 do gd = gd[:nl]
    gd = strings.trim_right_space(gd)
    gp.gitdir = join_path(bufs.gitdir[:], gp.root, gd)
    gp.is_worktree = true

    // <gitdir>/commondir names the shared dir (usually relative "../..").
    cd_file_buf: [560]u8
    cd_path := fmt.bprintf(cd_file_buf[:], "%s/commondir", gp.gitdir)
    cd_content_buf: [512]u8
    if cd, cok := read_small_file(cd_path, cd_content_buf[:]); cok {
        gp.commondir = join_path(bufs.commondir[:], gp.gitdir, cd)
    } else {
        cn := min(len(gp.gitdir), len(bufs.commondir))
        copy(bufs.commondir[:], gp.gitdir[:cn])
        gp.commondir = string(bufs.commondir[:cn])
    }
    return gp, true
}

// Stash log lives in the SHARED dir (commondir), one line per stash entry.
git_read_stash_count :: proc(commondir: string) -> i64 {
    stash_path := strings.concatenate(
        {commondir, "/logs/refs/stash"},
        context.temp_allocator,
    )
    stash_cstr := strings.clone_to_cstring(
        stash_path,
        context.temp_allocator,
    )

    fd := posix.open(stash_cstr, {})
    if fd < 0 do return 0
    defer posix.close(fd)

    buf: [4096]u8
    count: i64 = 0
    for {
        n := posix.read(fd, raw_data(&buf), len(buf))
        if n <= 0 do break
        for i in 0 ..< int(n) {
            if buf[i] == '\n' do count += 1
        }
    }

    return count
}

// HEAD is PER-WORKTREE, so it is read from gitdir, never commondir.
git_read_branch_fast :: proc(
    branch_buf: []u8,
    gitdir: string,
) -> (
    branch: string,
    ok: bool,
) {
    head_path := strings.concatenate(
        {gitdir, "/HEAD"},
        context.temp_allocator,
    )
    head_cstr := strings.clone_to_cstring(
        head_path,
        context.temp_allocator,
    )

    fd := posix.open(head_cstr, {})
    if fd < 0 do return "", false
    defer posix.close(fd)

    buf: [256]u8
    n := posix.read(fd, raw_data(&buf), len(buf))
    if n <= 0 do return "", false

    content := string(buf[:n])
    content = strings.trim_right_space(content)

    prefix :: "ref: refs/heads/"
    if strings.has_prefix(content, prefix) {
        branch_name := content[len(prefix):]
        copy(branch_buf[:], branch_name)
        return string(branch_buf[:len(branch_name)]), true
    }

    if len(content) >= 7 {
        copy(branch_buf[:], content[:7])
        return string(branch_buf[:7]), true
    }

    return "", false
}

/* -------------------------------------------------------------------------- */
/* State Cache (prevents flicker during API calls)                            */
/* -------------------------------------------------------------------------- */

CACHE_PATH_PREFIX :: "/dev/shm/statusline-cache."

CachedState :: struct #packed {
    used_pct:        i64,
    context_size:    i64,
    lines_added:     i64,
    lines_removed:   i64,
    duration_ms:     i64,
    input_tokens:    i64,
    // Ring buffer of (time, input_tokens) samples for the burn rate.
    // Claude Code re-renders on events, not a clock, so Δt between samples
    // swings 200ms..90s — the rate must come from a regression over a ~60s
    // window, never from the last single delta.
    burn_times:      [8]i64,
    burn_tokens:     [8]i64,
    burn_idx:        i64,
    cwd:             [256]u8,
    model:           [64]u8,
}

// Least-squares slope over the ring samples from the last 60s.
// Needs >=3 usable samples and a positive rate (a /compact makes tokens
// fall, which must suppress the segment, not show a negative rate).
// Sample window for the burn-rate regression. Was 60s, which required three
// renders inside one minute -- Claude Code renders roughly per turn, so the
// segment almost never qualified during real work.
BURN_WINDOW_S :: 900

compute_burn :: proc(
    cached: ^CachedState,
    now: i64,
    ctx_size: i64,
    cur_tokens: i64,
) -> (
    rate_per_min: f64,
    ttc_sec: i64,
    ok: bool,
) {
    xs, ys: [8]f64
    n := 0
    for i in 0 ..< 8 {
        t := cached.burn_times[i]
        if t <= 0 || now - t > BURN_WINDOW_S || t > now do continue
        xs[n] = f64(t - now) // negative offsets; only differences matter
        ys[n] = f64(cached.burn_tokens[i])
        n += 1
    }
    if n < 2 do return 0, 0, false

    sx, sy, sxx, sxy: f64
    for i in 0 ..< n {
        sx += xs[i]; sy += ys[i]
        sxx += xs[i] * xs[i]; sxy += xs[i] * ys[i]
    }
    fn := f64(n)
    denom := fn * sxx - sx * sx
    if denom <= 0 do return 0, 0, false
    slope := (fn * sxy - sx * sy) / denom // tokens per second
    if slope <= 0 do return 0, 0, false

    rate_per_min = slope * 60.0
    if ctx_size > 0 {
        headroom := f64(ctx_size) * 0.8 - f64(cur_tokens)
        if headroom < 0 do headroom = 0
        ttc_sec = i64(headroom / slope)
    }
    return rate_per_min, ttc_sec, true
}

get_grandparent_pid :: proc() -> int {
    @(static) cached_gppid: int = 0
    if cached_gppid != 0 do return cached_gppid

    ppid := int(posix.getppid())

    path_buf: [32]u8
    path := fmt.bprintf(
        path_buf[:],
        "/proc/%d/status",
        ppid,
    )
    path_cstr := strings.clone_to_cstring(
        path,
        context.temp_allocator,
    )

    fd := posix.open(path_cstr, {})
    if fd < 0 do return ppid
    defer posix.close(fd)

    buf: [1024]u8
    n := posix.read(fd, raw_data(&buf), len(buf))
    if n <= 0 do return ppid

    content := string(buf[:n])
    ppid_prefix :: "PPid:\t"
    idx := strings.index(content, ppid_prefix)
    if idx < 0 do return ppid

    start := idx + len(ppid_prefix)
    rest := content[start:]
    end := strings.index(rest, "\n")
    if end < 0 do end = len(rest)

    gppid, ok := strconv.parse_int(
        strings.trim_space(rest[:end]),
    )
    result := ok ? gppid : ppid
    cached_gppid = result
    return result
}

get_cache_path :: proc(path_buf: []u8) -> string {
    gppid := get_grandparent_pid()
    return fmt.bprintf(
        path_buf,
        "%s%d",
        CACHE_PATH_PREFIX,
        gppid,
    )
}

read_cached_state :: proc() -> CachedState {
    cache_path_buf: [64]u8
    cache_path := get_cache_path(cache_path_buf[:])
    cache_cstr := strings.clone_to_cstring(
        cache_path,
        context.temp_allocator,
    )
    fd := posix.open(cache_cstr, {})
    if fd < 0 do return {}
    defer posix.close(fd)

    // Reject files whose size doesn't match exactly — a SHRUNKEN struct
    // would otherwise read cleanly from a stale larger file and interpret
    // shifted bytes as plausible values.
    st: posix.stat_t
    if posix.fstat(fd, &st) != .OK do return {}
    if i64(st.st_size) != size_of(CachedState) do return {}

    state: CachedState
    buf := transmute([^]u8)&state
    n := posix.read(fd, buf, size_of(CachedState))
    if n != size_of(CachedState) do return {}
    return state
}

write_cached_state :: proc(state: CachedState) {
    cache_path_buf: [64]u8
    cache_path := get_cache_path(cache_path_buf[:])
    cache_cstr := strings.clone_to_cstring(
        cache_path,
        context.temp_allocator,
    )
    fd := posix.open(
        cache_cstr,
        {.WRONLY, .CREAT, .TRUNC},
        {.IRUSR, .IWUSR},
    )
    if fd < 0 do return
    defer posix.close(fd)
    s := state
    buf := transmute([^]u8)&s
    posix.write(fd, buf, size_of(CachedState))
}

CLEANUP_INTERVAL_S :: 300
// Hash-keyed cache files (claude-git-*, claude-pr-*) have no PID to test for
// liveness, so they are reaped on age alone.
SHM_MAX_AGE_S :: 86400

cleanup_stale_caches :: proc() {
    sentinel_cstr: cstring = "/dev/shm/statusline-cleanup"
    st: posix.stat_t
    now_ms := current_time_ms()
    if posix.stat(sentinel_cstr, &st) == .OK {
        last_s := i64(st.st_mtim.tv_sec)
        if now_ms / 1000 - last_s < CLEANUP_INTERVAL_S {
            return
        }
    }
    sentinel_fd := posix.open(
        sentinel_cstr,
        {.WRONLY, .CREAT, .TRUNC},
        {.IRUSR, .IWUSR, .IRGRP, .IWGRP, .IROTH, .IWOTH},
    )
    if sentinel_fd >= 0 do posix.close(sentinel_fd)

    SHM_DIR :: "/dev/shm"

    dir := posix.opendir(SHM_DIR)
    if dir == nil do return
    defer posix.closedir(dir)

    for {
        entry := posix.readdir(dir)
        if entry == nil do break

        name := string(cstring(&entry.d_name[0]))

        // Clean both cache and usage files
        // Hash-keyed caches carry no PID, so liveness cannot be tested --
        // reap them on age alone. Without this they accumulate one file per
        // repo-and-branch ever visited, forever.
        if strings.has_prefix(name, "claude-git-") ||
            strings.has_prefix(name, "claude-pr-") {
            path_buf2: [64]u8
            pth := fmt.bprintf(path_buf2[:], "%s/%s", SHM_DIR, name)
            pth_cstr := strings.clone_to_cstring(pth, context.temp_allocator)
            st2: posix.stat_t
            if posix.stat(pth_cstr, &st2) == .OK {
                if now_ms / 1000 - i64(st2.st_mtim.tv_sec) > SHM_MAX_AGE_S {
                    posix.unlink(pth_cstr)
                }
            }
            continue
        }

        pid_str: string
        if strings.has_prefix(
            name,
            "statusline-cache.",
        ) {
            pid_str = name[len("statusline-cache."):]
        } else if strings.has_prefix(
            name,
            "statusline-usage.",
        ) {
            pid_str = name[len("statusline-usage."):]
        } else {
            continue
        }

        pid, ok := strconv.parse_int(pid_str)
        if !ok || pid <= 0 do continue
        if posix.kill(posix.pid_t(pid), .NONE) == .OK {
            continue
        }

        path_buf: [64]u8
        path := fmt.bprintf(
            path_buf[:],
            "%s/%s",
            SHM_DIR,
            name,
        )
        path_cstr := strings.clone_to_cstring(
            path,
            context.temp_allocator,
        )
        posix.unlink(path_cstr)
    }

    // Clean up stale debug logs
    uid := posix.getuid()
    log_dir_buf: [64]u8
    log_dir := fmt.bprintf(
        log_dir_buf[:],
        "/tmp/statusline-%d",
        uid,
    )
    log_dir_cstr := strings.clone_to_cstring(
        log_dir,
        context.temp_allocator,
    )

    tmp_dir := posix.opendir(log_dir_cstr)
    if tmp_dir == nil do return
    defer posix.closedir(tmp_dir)

    for {
        entry := posix.readdir(tmp_dir)
        if entry == nil do break

        name := string(cstring(&entry.d_name[0]))
        if !strings.has_suffix(name, ".log") do continue

        pid_str := strings.trim_suffix(name, ".log")
        log_pid, ok := strconv.parse_int(pid_str)
        if !ok || log_pid <= 0 do continue
        if posix.kill(posix.pid_t(log_pid), .NONE) == .OK {
            continue
        }

        tmp_path_buf: [96]u8
        tmp_path := fmt.bprintf(
            tmp_path_buf[:],
            "%s/%s",
            log_dir,
            name,
        )
        tmp_path_cstr := strings.clone_to_cstring(
            tmp_path,
            context.temp_allocator,
        )
        posix.unlink(tmp_path_cstr)
    }
}

/* -------------------------------------------------------------------------- */
/* Git Status Cache                                                           */
/* -------------------------------------------------------------------------- */

GitCache :: struct #packed {
    index_mtime_sec:  i64,
    index_mtime_nsec: i64,
    modified:         u32,
    staged:           u32,
    untracked:        u32,
    ahead:            u32,
    behind:           u32,
    branch:           [64]u8,
    repo_path:        [256]u8,
}

hash_path :: proc(path: string) -> u32 {
    h: u32 = 2166136261
    for c in path {
        h ~= u32(c)
        h *= 16777619
    }
    return h
}

get_git_cache_path :: proc(path_buf: []u8, repo_path: string) -> string {
    h := hash_path(repo_path)
    return fmt.bprintf(
        path_buf,
        "/dev/shm/claude-git-%08x",
        h,
    )
}

current_time_ms :: proc() -> i64 {
    ts: posix.timespec
    posix.clock_gettime(.REALTIME, &ts)
    return i64(ts.tv_sec) * 1000 +
        i64(ts.tv_nsec) / 1_000_000
}

current_time_sec :: proc() -> i64 {
    ts: posix.timespec
    posix.clock_gettime(.REALTIME, &ts)
    return i64(ts.tv_sec)
}

GIT_CACHE_TTL_MS :: 5000

CacheState :: enum {
    NONE,
    STALE,
    VALID,
}

read_git_cache :: proc(
    repo_path: string,
    gitdir: string,
) -> (
    cache: GitCache,
    state: CacheState,
) {
    cache_path_buf: [64]u8
    cache_path := get_git_cache_path(cache_path_buf[:], repo_path)
    cache_cstr := strings.clone_to_cstring(
        cache_path,
        context.temp_allocator,
    )

    fd := posix.open(cache_cstr, {})
    if fd < 0 do return {}, .NONE
    defer posix.close(fd)

    buf := transmute([^]u8)&cache
    n := posix.read(fd, buf, size_of(GitCache))
    if n != size_of(GitCache) do return {}, .NONE

    cached_repo := string(cstring(&cache.repo_path[0]))
    if cached_repo != repo_path do return {}, .NONE

    cache_st: posix.stat_t
    if posix.fstat(fd, &cache_st) != .OK {
        return cache, .STALE
    }
    cache_age_ms := current_time_ms() -
        (i64(cache_st.st_mtim.tv_sec) * 1000 +
            i64(cache_st.st_mtim.tv_nsec) / 1_000_000)
    if cache_age_ms > GIT_CACHE_TTL_MS {
        return cache, .STALE
    }

    // index is PER-WORKTREE — stat it in gitdir, not <root>/.git.
    index_path := strings.concatenate(
        {gitdir, "/index"},
        context.temp_allocator,
    )
    index_cstr := strings.clone_to_cstring(
        index_path,
        context.temp_allocator,
    )
    idx_st: posix.stat_t
    if posix.stat(index_cstr, &idx_st) != .OK {
        return cache, .STALE
    }

    if i64(idx_st.st_mtim.tv_sec) ==
            cache.index_mtime_sec &&
        i64(idx_st.st_mtim.tv_nsec) ==
            cache.index_mtime_nsec {
        return cache, .VALID
    }

    return cache, .STALE
}

write_git_cache :: proc(
    repo_path: string,
    gitdir: string,
    modified: u32,
    staged: u32,
    untracked: u32,
    ahead: u32,
    behind: u32,
) {
    index_path := strings.concatenate(
        {gitdir, "/index"},
        context.temp_allocator,
    )
    index_cstr := strings.clone_to_cstring(
        index_path,
        context.temp_allocator,
    )
    st: posix.stat_t
    if posix.stat(index_cstr, &st) != .OK do return

    cache: GitCache
    cache.index_mtime_sec = i64(st.st_mtim.tv_sec)
    cache.index_mtime_nsec = i64(st.st_mtim.tv_nsec)
    cache.modified = modified
    cache.staged = staged
    cache.untracked = untracked
    cache.ahead = ahead
    cache.behind = behind
    copy(cache.repo_path[:], repo_path)

    cache_path_buf: [64]u8
    cache_path := get_git_cache_path(cache_path_buf[:], repo_path)
    cache_cstr := strings.clone_to_cstring(
        cache_path,
        context.temp_allocator,
    )

    fd := posix.open(
        cache_cstr,
        {.WRONLY, .CREAT, .TRUNC},
        {.IRUSR, .IWUSR, .IRGRP, .IROTH},
    )
    if fd < 0 do return
    defer posix.close(fd)

    buf := transmute([^]u8)&cache
    posix.write(fd, buf, size_of(GitCache))
}

run_git_status :: proc(
    repo_path: string,
) -> (
    modified: u32,
    staged: u32,
    untracked: u32,
    ahead: u32,
    behind: u32,
) {
    pipe_fds: [2]posix.FD
    if posix.pipe(&pipe_fds) != .OK {
        return 0, 0, 0, 0, 0
    }
    pipe_read := pipe_fds[0]
    pipe_write := pipe_fds[1]

    pid := posix.fork()
    if pid < 0 {
        posix.close(pipe_read)
        posix.close(pipe_write)
        return 0, 0, 0, 0, 0
    }

    if pid == 0 {
        posix.close(pipe_read)
        repo_cstr := strings.clone_to_cstring(
            repo_path,
            context.temp_allocator,
        )
        posix.chdir(repo_cstr)
        posix.dup2(pipe_write, 1)
        dev_null := posix.open("/dev/null", {.WRONLY})
        if dev_null >= 0 do posix.dup2(dev_null, 2)
        posix.close(pipe_write)

        argv := []cstring{
            "git",
            "status",
            "--porcelain",
            "-b",
            "-unormal",
            nil,
        }
        posix.execvp("git", raw_data(argv))
        posix._exit(127)
    }

    posix.close(pipe_write)

    buf: [4096]u8
    total_read := 0
    for {
        remaining := len(buf) - total_read
        if remaining <= 0 do break
        n := posix.read(
            pipe_read,
            raw_data(buf[total_read:]),
            uint(remaining),
        )
        if n <= 0 do break
        total_read += int(n)
    }
    posix.close(pipe_read)
    posix.waitpid(pid, nil, {})

    output := string(buf[:total_read])
    rest := output
    for len(rest) > 0 {
        nl := strings.index(rest, "\n")
        line: string
        if nl >= 0 {
            line = rest[:nl]
            rest = rest[nl + 1:]
        } else {
            line = rest
            rest = ""
        }
        if len(line) < 2 do continue

        if line[0] == '#' && line[1] == '#' {
            if idx := strings.index(line, "[");
                idx >= 0 {
                bracket := line[idx:]
                if a := strings.index(
                    bracket,
                    "ahead ",
                ); a >= 0 {
                    num_start := a + 6
                    num_end := num_start
                    for num_end < len(bracket) &&
                        bracket[num_end] >= '0' &&
                        bracket[num_end] <= '9' {
                        num_end += 1
                    }
                    if v, ok := strconv.parse_int(
                        bracket[num_start:num_end],
                    ); ok {
                        ahead = u32(v)
                    }
                }
                if b := strings.index(
                    bracket,
                    "behind ",
                ); b >= 0 {
                    num_start := b + 7
                    num_end := num_start
                    for num_end < len(bracket) &&
                        bracket[num_end] >= '0' &&
                        bracket[num_end] <= '9' {
                        num_end += 1
                    }
                    if v, ok := strconv.parse_int(
                        bracket[num_start:num_end],
                    ); ok {
                        behind = u32(v)
                    }
                }
            }
            continue
        }

        if line[0] == '?' && line[1] == '?' {
            untracked += 1
            continue
        }
        if line[0] != ' ' && line[0] != '?' {
            staged += 1
        }
        if line[1] != ' ' && line[1] != '?' {
            modified += 1
        }
    }

    return modified, staged, untracked, ahead, behind
}

get_git_status_cached :: proc(
    repo_path: string,
    gitdir: string,
) -> (
    modified: u32,
    staged: u32,
    untracked: u32,
    ahead: u32,
    behind: u32,
    state: CacheState,
) {
    cache, cache_state := read_git_cache(repo_path, gitdir)

    switch cache_state {
    case .VALID:
        return cache.modified, cache.staged, cache.untracked,
            cache.ahead, cache.behind, .VALID
    case .STALE:
        bg_pid := posix.fork()
        if bg_pid == 0 {
            if posix.fork() == 0 {
                m, s, u, a, b := run_git_status(repo_path)
                write_git_cache(repo_path, gitdir, m, s, u, a, b)
            }
            posix._exit(0)
        }
        if bg_pid > 0 {
            posix.waitpid(bg_pid, nil, {})
        }
        return cache.modified, cache.staged, cache.untracked,
            cache.ahead, cache.behind, .STALE
    case .NONE:
        modified, staged, untracked, ahead, behind =
            run_git_status(repo_path)
        write_git_cache(
            repo_path,
            gitdir,
            modified,
            staged,
            untracked,
            ahead,
            behind,
        )
        return modified, staged, untracked, ahead, behind, .NONE
    }

    return 0, 0, 0, 0, 0, .NONE
}

/* -------------------------------------------------------------------------- */
/* Usage Quota Cache                                                          */
/* -------------------------------------------------------------------------- */

USAGE_CACHE_TTL_S :: 60
USAGE_CACHE_PREFIX :: "/dev/shm/statusline-usage."

UsageCache :: struct #packed {
    fetch_time_sec:       i64,
    five_hour_pct:        f64,
    seven_day_pct:        f64,
    seven_day_opus_pct:   f64,
    five_hour_reset:      i64,  // epoch sec, 0 if unknown
    seven_day_reset:      i64,
    opus_reset:           i64,
    last_attempt_sec:     i64,  // when a fetch was last STARTED
    consecutive_failures: i64,  // doubles the retry backoff, 60s..15m
}

// Failed fetches also write the cache (data preserved, failure counter
// bumped) so the backoff below is observable and curl is not forked on
// every render while the OAuth endpoint is down (Bug 3).
usage_backoff_s :: proc(failures: i64) -> i64 {
    b: i64 = USAGE_CACHE_TTL_S
    for _ in 0 ..< min(failures, 4) do b *= 2
    return min(b, 900)
}

write_usage_cache :: proc(gppid: int, cache: UsageCache) {
    path_buf: [64]u8
    cache_path := get_usage_cache_path(path_buf[:], gppid)
    cache_cstr := strings.clone_to_cstring(
        cache_path,
        context.temp_allocator,
    )
    // Write to a temp file and rename so a concurrent reader never sees a
    // truncated half-written cache (which read as {} and blanked the quota).
    tmp_buf: [80]u8
    tmp_path := fmt.bprintf(tmp_buf[:], "%s.tmp%d", cache_path, posix.getpid())
    tmp_cstr := strings.clone_to_cstring(
        tmp_path,
        context.temp_allocator,
    )
    fd := posix.open(
        tmp_cstr,
        {.WRONLY, .CREAT, .TRUNC},
        {.IRUSR, .IWUSR},
    )
    if fd < 0 do return
    c := cache
    posix.write(fd, transmute([^]u8)&c, size_of(UsageCache))
    posix.close(fd)
    posix.rename(tmp_cstr, cache_cstr)
}

get_usage_cache_path :: proc(path_buf: []u8, gppid: int) -> string {
    return fmt.bprintf(
        path_buf,
        "%s%d",
        USAGE_CACHE_PREFIX,
        gppid,
    )
}

// Write prev back with the failure counter bumped, then exit. Called from
// the grandchild on any failure so the backoff timestamp always lands.
usage_fail_exit :: proc(gppid: int, prev: UsageCache, now: i64) -> ! {
    c := prev
    c.last_attempt_sec = now
    c.consecutive_failures += 1
    write_usage_cache(gppid, c)
    posix._exit(1)
}

refresh_usage_cache :: proc(gppid: int, prev: UsageCache) {
    first_fork := posix.fork()
    if first_fork < 0 do return
    if first_fork > 0 {
        // Use WNOHANG-style: wait briefly, don't block forever
        posix.waitpid(first_fork, nil, {})
        return
    }

    // Middle child - fork grandchild and exit immediately
    grandchild := posix.fork()
    if grandchild != 0 {
        posix._exit(0)
        // unreachable - but just in case
    }

    // Grandchild: read credentials, curl, parse, write
    attempt_sec := current_time_sec()
    home := string(posix.getenv("HOME"))
    if len(home) == 0 do usage_fail_exit(gppid, prev, attempt_sec)

    cred_path_buf: [512]u8
    cred_path := fmt.bprintf(
        cred_path_buf[:],
        "%s/.claude/.credentials.json",
        home,
    )
    cred_cstr := strings.clone_to_cstring(
        cred_path,
        context.temp_allocator,
    )

    cred_fd := posix.open(cred_cstr, {})
    if cred_fd < 0 do usage_fail_exit(gppid, prev, attempt_sec)

    cred_buf: [4096]u8
    cred_len := posix.read(
        cred_fd,
        raw_data(&cred_buf),
        len(cred_buf) - 1,
    )
    posix.close(cred_fd)
    if cred_len <= 0 do usage_fail_exit(gppid, prev, attempt_sec)

    cred_json := string(cred_buf[:cred_len])

    // Find claudeAiOauth object, extract accessToken
    oauth_idx := strings.index(
        cred_json,
        "\"claudeAiOauth\"",
    )
    if oauth_idx < 0 do usage_fail_exit(gppid, prev, attempt_sec)

    oauth_rest := cred_json[oauth_idx:]
    brace_idx := strings.index(oauth_rest, "{")
    if brace_idx < 0 do usage_fail_exit(gppid, prev, attempt_sec)

    oauth_obj := oauth_rest[brace_idx:]
    token := json_get_string(oauth_obj, "accessToken")
    if len(token) == 0 do usage_fail_exit(gppid, prev, attempt_sec)

    // Build Authorization header
    auth_buf: [2048]u8
    auth_header := fmt.bprintf(
        auth_buf[:],
        "Authorization: Bearer %s",
        token,
    )
    auth_cstr := strings.clone_to_cstring(
        auth_header,
        context.temp_allocator,
    )

    // Fork/exec curl
    pipe_fds: [2]posix.FD
    if posix.pipe(&pipe_fds) != .OK do usage_fail_exit(gppid, prev, attempt_sec)

    curl_pid := posix.fork()
    if curl_pid < 0 do usage_fail_exit(gppid, prev, attempt_sec)

    if curl_pid == 0 {
        posix.close(pipe_fds[0])
        posix.dup2(pipe_fds[1], 1)
        dev_null := posix.open("/dev/null", {.WRONLY})
        if dev_null >= 0 {
            posix.dup2(dev_null, 2)
            posix.close(dev_null)
        }
        posix.close(pipe_fds[1])

        beta_cstr: cstring =
            "anthropic-beta: oauth-2025-04-20"
        url_cstr: cstring =
            "https://api.anthropic.com/api/oauth/usage"

        argv := []cstring{
            "curl", "-s", "--max-time", "10",
            "-H", auth_cstr,
            "-H", beta_cstr,
            url_cstr,
            nil,
        }
        posix.execvp("curl", raw_data(argv))
        posix._exit(127)
    }

    posix.close(pipe_fds[1])

    response_buf: [8192]u8
    total_read := 0
    for {
        remaining := len(response_buf) - total_read - 1
        if remaining <= 0 do break
        n := posix.read(
            pipe_fds[0],
            raw_data(response_buf[total_read:]),
            uint(remaining),
        )
        if n <= 0 do break
        total_read += int(n)
    }
    posix.close(pipe_fds[0])
    posix.waitpid(curl_pid, nil, {})

    response := string(response_buf[:total_read])

    // Parse utilization + reset timestamps for each window. seven_day_opus
    // is the Max-plan Opus-specific weekly cap (may be absent → 0).
    five_pct := json_find_object_f64(response, "five_hour", "utilization")
    seven_pct := json_find_object_f64(response, "seven_day", "utilization")
    opus_pct := json_find_object_f64(response, "seven_day_opus", "utilization")

    five_reset := iso8601_to_epoch(
        json_find_object_str(response, "five_hour", "resets_at"),
    )
    seven_reset := iso8601_to_epoch(
        json_find_object_str(response, "seven_day", "resets_at"),
    )
    opus_reset := iso8601_to_epoch(
        json_find_object_str(response, "seven_day_opus", "resets_at"),
    )

    // No usable data at all -> count as a failure so backoff kicks in.
    if five_reset == 0 && seven_reset == 0 {
        usage_fail_exit(gppid, prev, attempt_sec)
    }

    // Write cache (success resets the failure counter)
    cache: UsageCache
    cache.fetch_time_sec = current_time_sec()
    cache.five_hour_pct = five_pct
    cache.seven_day_pct = seven_pct
    cache.seven_day_opus_pct = opus_pct
    cache.five_hour_reset = five_reset
    cache.seven_day_reset = seven_reset
    cache.opus_reset = opus_reset
    cache.last_attempt_sec = attempt_sec
    cache.consecutive_failures = 0
    write_usage_cache(gppid, cache)
    posix._exit(0)
}

read_usage_cache :: proc(gppid: int) -> UsageCache {
    path_buf: [64]u8
    cache_path := get_usage_cache_path(path_buf[:], gppid)
    cache_cstr := strings.clone_to_cstring(
        cache_path,
        context.temp_allocator,
    )

    now := current_time_sec()
    fd := posix.open(cache_cstr, {})
    if fd < 0 {
        refresh_usage_cache(gppid, {})
        return {}
    }

    cache: UsageCache
    n := posix.read(
        fd,
        transmute([^]u8)&cache,
        size_of(UsageCache),
    )
    posix.close(fd)

    if n != size_of(UsageCache) {
        refresh_usage_cache(gppid, {})
        return {}
    }

    // Refresh on TTL expiry, but back off while fetches keep failing —
    // otherwise a broken OAuth endpoint forks curl on EVERY render.
    if now - cache.fetch_time_sec > USAGE_CACHE_TTL_S {
        backoff := usage_backoff_s(cache.consecutive_failures)
        if now - cache.last_attempt_sec >= backoff {
            refresh_usage_cache(gppid, cache)
        }
    }

    return cache
}

/* -------------------------------------------------------------------------- */
/* PR + CI Status (background gh fetch, 120s TTL, negative caching)           */
/* -------------------------------------------------------------------------- */

PR_CACHE_TTL_S :: 120

PrCi :: enum u8 { PASS, FAIL, PENDING, DRAFT }
PrReview :: enum u8 { NONE, APPROVED, REVIEW_REQUIRED }

// Unlike the git cache there is no local mtime to test staleness against —
// freshness is pure TTL, which makes negative caching load-bearing. Failure
// is NORMAL here (no PR for the branch, rate limit, expired auth), so a
// failed fetch must still write an entry with a backoff timestamp; anything
// else reproduces the usage-cache refork storm in a new place.
PrCache :: struct #packed {
    fetch_time_sec:       i64,
    last_attempt_sec:     i64,
    consecutive_failures: i64,
    has_pr:               u8,
    ci:                   PrCi,
    review:               PrReview,
    _pad:                 u8,
    number:               i64,
    failed:               i64,
    url:                  [128]u8,
}

PrStatus :: struct {
    valid:  bool,
    number: i64,
    failed: i64,
    ci:     PrCi,
    review: PrReview,
    url:    string,
}

get_pr_cache_path :: proc(path_buf: []u8, gitdir: string, branch: string) -> string {
    h := hash_path(gitdir)
    // Fold the branch into the same FNV hash so each worktree+branch pair
    // gets its own entry.
    for c in branch {
        h ~= u32(c)
        h *= 16777619
    }
    return fmt.bprintf(path_buf, "/dev/shm/claude-pr-%08x", h)
}

count_substr :: proc(s: string, needle: string) -> i64 {
    count: i64 = 0
    rest := s
    for {
        idx := strings.index(rest, needle)
        if idx < 0 do break
        count += 1
        rest = rest[idx + len(needle):]
    }
    return count
}

write_pr_cache :: proc(gitdir: string, branch: string, cache: PrCache) {
    path_buf: [64]u8
    cache_path := get_pr_cache_path(path_buf[:], gitdir, branch)
    tmp_buf: [80]u8
    tmp_path := fmt.bprintf(tmp_buf[:], "%s.tmp%d", cache_path, posix.getpid())
    tmp_cstr := strings.clone_to_cstring(tmp_path, context.temp_allocator)
    cache_cstr := strings.clone_to_cstring(cache_path, context.temp_allocator)
    fd := posix.open(tmp_cstr, {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR})
    if fd < 0 do return
    c := cache
    posix.write(fd, transmute([^]u8)&c, size_of(PrCache))
    posix.close(fd)
    posix.rename(tmp_cstr, cache_cstr)
}

// Grandchild worker: run gh in the repo, parse, write the cache.
// Never returns.
fetch_pr_status_exit :: proc(
    root: string,
    gitdir: string,
    branch: string,
    prev: PrCache,
) -> ! {
    now := current_time_sec()
    fail :: proc(gitdir, branch: string, prev: PrCache, now: i64) -> ! {
        c := prev
        c.last_attempt_sec = now
        c.consecutive_failures += 1
        // A definite "no PR" also lands here: cheap to retry after backoff,
        // and indistinguishable from transient gh failures without exit
        // codes we don't capture.
        c.has_pr = 0
        write_pr_cache(gitdir, branch, c)
        posix._exit(1)
    }

    pipe_fds: [2]posix.FD
    if posix.pipe(&pipe_fds) != .OK do fail(gitdir, branch, prev, now)

    gh_pid := posix.fork()
    if gh_pid < 0 do fail(gitdir, branch, prev, now)
    if gh_pid == 0 {
        posix.close(pipe_fds[0])
        root_cstr := strings.clone_to_cstring(root, context.temp_allocator)
        posix.chdir(root_cstr)
        posix.dup2(pipe_fds[1], 1)
        dev_null := posix.open("/dev/null", {.WRONLY})
        if dev_null >= 0 do posix.dup2(dev_null, 2)
        posix.close(pipe_fds[1])
        argv := []cstring{
            "gh", "pr", "view", "--json",
            "number,state,isDraft,statusCheckRollup,reviewDecision,url",
            nil,
        }
        posix.execvp("gh", raw_data(argv))
        posix._exit(127)
    }
    posix.close(pipe_fds[1])

    buf: [65536]u8
    total := 0
    for {
        remaining := len(buf) - total - 1
        if remaining <= 0 do break
        n := posix.read(pipe_fds[0], raw_data(buf[total:]), uint(remaining))
        if n <= 0 do break
        total += int(n)
    }
    posix.close(pipe_fds[0])
    posix.waitpid(gh_pid, nil, {})

    resp := string(buf[:total])
    num_idx := strings.index(resp, "\"number\":")
    if num_idx < 0 do fail(gitdir, branch, prev, now)
    pos := num_idx + len("\"number\":")
    number := json_parse_i64_at(resp, &pos)
    if number <= 0 do fail(gitdir, branch, prev, now)

    passed := count_substr(resp, "\"conclusion\":\"SUCCESS\"")
    failed := count_substr(resp, "\"conclusion\":\"FAILURE\"") +
        count_substr(resp, "\"conclusion\":\"ERROR\"")
    pending := count_substr(resp, "\"status\":\"IN_PROGRESS\"") +
        count_substr(resp, "\"status\":\"QUEUED\"") +
        count_substr(resp, "\"status\":\"PENDING\"")
    _ = passed
    is_draft := strings.index(resp, "\"isDraft\":true") >= 0

    ci: PrCi = .PASS
    if is_draft {
        ci = .DRAFT
    } else if failed > 0 {
        ci = .FAIL
    } else if pending > 0 {
        ci = .PENDING
    }

    review: PrReview = .NONE
    if strings.index(resp, "\"reviewDecision\":\"APPROVED\"") >= 0 {
        review = .APPROVED
    } else if strings.index(resp, "\"reviewDecision\":\"REVIEW_REQUIRED\"") >= 0 {
        review = .REVIEW_REQUIRED
    }

    cache: PrCache
    cache.fetch_time_sec = now
    cache.last_attempt_sec = now
    cache.consecutive_failures = 0
    cache.has_pr = 1
    cache.ci = ci
    cache.review = review
    cache.number = number
    cache.failed = failed
    url := json_get_string(resp, "url")
    copy(cache.url[:len(cache.url) - 1], url)
    write_pr_cache(gitdir, branch, cache)
    posix._exit(0)
}

// Backoff for failed PR fetches: 120s doubling to a 15-minute cap.
pr_backoff_s :: proc(failures: i64) -> i64 {
    b: i64 = PR_CACHE_TTL_S
    for _ in 0 ..< min(failures, 3) do b *= 2
    return min(b, 900)
}

get_pr_status_cached :: proc(
    root: string,
    gitdir: string,
    branch: string,
    url_buf: []u8,
) -> PrStatus {
    path_buf: [64]u8
    cache_path := get_pr_cache_path(path_buf[:], gitdir, branch)
    cache_cstr := strings.clone_to_cstring(cache_path, context.temp_allocator)

    cache: PrCache
    have := false
    fd := posix.open(cache_cstr, {})
    if fd >= 0 {
        n := posix.read(fd, transmute([^]u8)&cache, size_of(PrCache))
        posix.close(fd)
        have = n == size_of(PrCache)
    }
    if !have do cache = {}

    now := current_time_sec()
    ttl: i64 = PR_CACHE_TTL_S
    if cache.consecutive_failures > 0 {
        ttl = pr_backoff_s(cache.consecutive_failures)
    }
    if !have || now - cache.last_attempt_sec >= ttl {
        // Stale (or missing): kick a detached refresh, render stale data now.
        bg_pid := posix.fork()
        if bg_pid == 0 {
            if posix.fork() == 0 {
                fetch_pr_status_exit(root, gitdir, branch, cache)
            }
            posix._exit(0)
        }
        if bg_pid > 0 do posix.waitpid(bg_pid, nil, {})
    }

    if !have || cache.has_pr == 0 do return {}
    n := min(len(url_buf) - 1, len(cache.url))
    copy(url_buf, cache.url[:n])
    url := string(cstring(raw_data(url_buf)))
    return {
        valid = true, number = cache.number, failed = cache.failed,
        ci = cache.ci, review = cache.review, url = url,
    }
}

/* -------------------------------------------------------------------------- */
/* Display State                                                              */
/* -------------------------------------------------------------------------- */

DisplayState :: struct {
    cwd:               string,
    model:             string,
    lines_added:        i64,
    lines_removed:      i64,
    total_duration_ms:  i64,
    used_pct:           i64,
    ctx_size:           i64,
    input_tokens:       i64,
    burn_per_min:       f64,
    ttc_sec:            i64,
    burn_ok:            bool,
    five_hour_pct:      f64,
    seven_day_pct:      f64,
    seven_day_opus_pct: f64,
    five_hour_reset:    i64,
    seven_day_reset:    i64,
    opus_reset:         i64,
    exceeds_200k:       bool,
    vim_mode:           string,
    thinking_enabled:   bool,
}

DebugTimings :: struct {
    t_start:   time.Tick,
    t_cleanup: time.Tick,
    t_read:    time.Tick,
    t_parse:   time.Tick,
    t_git:     time.Tick,
    t_build:   time.Tick,
}

/* -------------------------------------------------------------------------- */
/* Stdin Reader                                                               */
/* -------------------------------------------------------------------------- */

STDIN_TIMEOUT_MS :: 50

read_stdin :: proc() -> (string, bool) {
    @(static) input_buf: [8192]u8

    pfds := [1]posix.pollfd{
        {fd = 0, events = {.IN}},
    }
    if posix.poll(raw_data(&pfds), 1, STDIN_TIMEOUT_MS) >
        0 {
        // Single read - JSON is <4KB, arrives atomically
        n := posix.read(
            0,
            raw_data(&input_buf),
            len(input_buf) - 1,
        )
        if n <= 0 do return "", true
        return string(input_buf[:n]), false
    }
    return "", true
}

/* -------------------------------------------------------------------------- */
/* State Resolution (JSON + Cache Merge)                                      */
/* -------------------------------------------------------------------------- */

resolve_state :: proc(
    input: string,
    stdin_timeout: bool,
) -> DisplayState {
    @(static) cached: CachedState
    cached = read_cached_state()
    state: DisplayState

    if !stdin_timeout {
        f                  := json_parse_all(input)
        json_cwd           := f.current_dir
        json_model         := f.display_name
        json_lines_added   := f.total_lines_added
        json_lines_removed := f.total_lines_removed
        json_duration      := f.total_duration_ms
        json_ctx_size      := f.context_window_size
        json_in_tok        := f.total_input_tokens
        state.vim_mode      = f.mode
        state.thinking_enabled = f.thinking_enabled

        // Quota from stdin JSON (per-render fresh) — primary source; the
        // background OAuth fetch cache is only a fallback (see main).
        state.five_hour_pct   = f.rl_five_hour_pct
        state.five_hour_reset = f.rl_five_hour_reset
        state.seven_day_pct   = f.rl_seven_day_pct
        state.seven_day_reset = f.rl_seven_day_reset

        cached_cwd              := string(cstring(&cached.cwd[0]))
        cached_model            := string(cstring(&cached.model[0]))
        state.cwd                = len(json_cwd) > 0 ? json_cwd : cached_cwd
        state.model              = len(json_model) > 0 ? json_model : cached_model
        state.lines_added        = json_lines_added > 0 ? json_lines_added : cached.lines_added
        state.lines_removed      = json_lines_removed > 0 ? json_lines_removed : cached.lines_removed
        state.total_duration_ms  = json_duration > 0 ? json_duration : cached.duration_ms
        state.ctx_size           = json_ctx_size > 0 ? json_ctx_size : cached.context_size
        // context_window.used_percentage is authoritative — it accounts for
        // cache tokens. Only fall back to total_input_tokens/ctx_size when the
        // percentage is missing (e.g. briefly after a /compact).
        json_pct := i64(f.used_percentage + 0.5)
        if json_pct > 0 {
            state.used_pct = json_pct
        } else {
            in_tok := json_in_tok > 0 ? json_in_tok : cached.input_tokens
            ctx_sz := state.ctx_size
            if in_tok > 0 && ctx_sz > 0 {
                state.used_pct = i64(f64(in_tok) / f64(ctx_sz) * 100.0 + 0.5)
            } else {
                state.used_pct = cached.used_pct
            }
        }
        state.input_tokens       = json_in_tok > 0 ? json_in_tok : cached.input_tokens
        state.exceeds_200k       = f.exceeds_200k

        // Update cache
        new_cache: CachedState
        new_cache.used_pct = state.used_pct
        new_cache.context_size = max(
            json_ctx_size,
            cached.context_size,
        )
        new_cache.lines_added = max(
            json_lines_added,
            cached.lines_added,
        )
        new_cache.lines_removed = max(
            json_lines_removed,
            cached.lines_removed,
        )
        new_cache.duration_ms = max(
            json_duration,
            cached.duration_ms,
        )
        // Current context occupancy (v2.1.132+): store the latest value, not
        // the high-water mark — it must be able to fall after a /compact.
        // Keep the last known value when this frame omits it (post-compact the
        // context_window object can be null until the next API response).
        new_cache.input_tokens =
            json_in_tok > 0 ? json_in_tok : cached.input_tokens

        // Burn-rate ring: carry samples forward, append this render's
        // (time, tokens) unless it duplicates the newest sample.
        new_cache.burn_times = cached.burn_times
        new_cache.burn_tokens = cached.burn_tokens
        new_cache.burn_idx = cached.burn_idx
        if json_in_tok > 0 {
            now_s := current_time_sec()
            newest := int((cached.burn_idx + 7) % 8)
            dup := cached.burn_times[newest] == now_s &&
                cached.burn_tokens[newest] == json_in_tok
            if !dup {
                w := int(cached.burn_idx % 8)
                new_cache.burn_times[w] = now_s
                new_cache.burn_tokens[w] = json_in_tok
                new_cache.burn_idx = cached.burn_idx + 1
            }
            state.burn_per_min, state.ttc_sec, state.burn_ok =
                compute_burn(&new_cache, now_s, state.ctx_size, state.input_tokens)
        }
        if len(json_cwd) > 0 {
            copy(
                new_cache.cwd[:len(new_cache.cwd) - 1],
                json_cwd,
            )
        } else {
            new_cache.cwd = cached.cwd
        }
        if len(json_model) > 0 {
            copy(
                new_cache.model[:len(new_cache.model) - 1],
                json_model,
            )
        } else {
            new_cache.model = cached.model
        }
        if new_cache != cached {
            write_cached_state(new_cache)
        }
    } else {
        state.cwd               = string(cstring(&cached.cwd[0]))
        state.model             = string(cstring(&cached.model[0]))
        state.lines_added       = cached.lines_added
        state.lines_removed     = cached.lines_removed
        state.total_duration_ms = cached.duration_ms
        state.used_pct          = cached.used_pct
        state.ctx_size          = cached.context_size
        state.input_tokens      = cached.input_tokens
    }

    return state
}

/* -------------------------------------------------------------------------- */
/* Time Formatting                                                            */
/* -------------------------------------------------------------------------- */

// Opus weekly cap. Warns one step earlier than the 5h/7d windows because a
// weekly cap is slow to recover from — but 50% was too early: burning half your
// weekly Opus allowance by midweek is on-plan, not a problem.
usage_color :: proc(pct: f64) -> string {
    if pct >= 90 do return ANSI_FG_RED
    if pct >= 80 do return ANSI_FG_ORANGE
    if pct >= 70 do return ANSI_FG_YELLOW
    return ANSI_FG_GREEN
}

// Projected end-of-window quota. Finishing a window just under the cap is the
// BEST possible outcome on a flat subscription, so everything under 100% is
// green — a projection of 99% is not a warning, it is perfect pacing. Only a
// real overshoot is concerning, and severity is how early you would be capped.
projection_color :: proc(proj: f64) -> string {
    if proj >= 200 do return ANSI_FG_RED      // capped around half-way in
    if proj >= 140 do return ANSI_FG_ORANGE   // capped well before reset
    if proj >= 105 do return ANSI_FG_YELLOW   // capped near the end
    return ANSI_FG_GREEN                      // finishes under the cap
}

// 5h/7d rate-limit color: stays green through normal use and only escalates
// when a window is genuinely near its cap. (usage_color, used for the Opus
// weekly cap, keeps its earlier-warning thresholds.)
rate_limit_color :: proc(pct: f64) -> string {
    if pct >= 90 do return ANSI_FG_RED
    if pct >= 80 do return ANSI_FG_ORANGE
    return ANSI_FG_GREEN
}

/* -------------------------------------------------------------------------- */
/* Statusline Builder                                                         */
/* -------------------------------------------------------------------------- */
/*
Two-line width-adaptive layout (v6).

Line 1 = identity (model, path, branch, git counts, PR) — changes only when
you move, so it is a stable visual anchor. Line 2 = budget (quota, context,
burn) — all per-render churn is quarantined here. Each line degrades
independently via a table-driven priority ladder: the lowest-priority segment
sheds display stages first, then droppable segments are dropped outright.
Authoritative spec: thoughts/shared/plans/statusline-v6-layout-prototype.py.
*/

// ---- display width (mirrors Bun.stringWidth(s, {ambiguousIsNarrow: true}))

// East-Asian Wide/Fullwidth ranges -> 2 cells. Every glyph this statusline
// currently uses is Narrow or Ambiguous (1 cell); this branch exists so a
// future 2-cell glyph doesn't silently break the width math.
is_wide_rune :: proc(r: rune) -> bool {
    switch r {
    case 0x1100 ..= 0x115F,   // Hangul Jamo
         0x2E80 ..= 0x303E,   // CJK Radicals .. CJK Symbols
         0x3041 ..= 0x33FF,   // Hiragana .. CJK Compat
         0x3400 ..= 0x4DBF,   // CJK Ext A
         0x4E00 ..= 0x9FFF,   // CJK Unified
         0xA000 ..= 0xA4CF,   // Yi
         0xAC00 ..= 0xD7A3,   // Hangul Syllables
         0xF900 ..= 0xFAFF,   // CJK Compat Ideographs
         0xFE30 ..= 0xFE4F,   // CJK Compat Forms
         0xFF00 ..= 0xFF60,   // Fullwidth Forms
         0xFFE0 ..= 0xFFE6,
         0x1F300 ..= 0x1F64F, // Emoji (most render wide)
         0x1F900 ..= 0x1F9FF,
         0x20000 ..= 0x2FFFD, // CJK Ext B+
         0x30000 ..= 0x3FFFD:
        return true
    }
    return false
}

is_combining_rune :: proc(r: rune) -> bool {
    switch r {
    case 0x0300 ..= 0x036F,
         0x1AB0 ..= 0x1AFF,
         0x1DC0 ..= 0x1DFF,
         0x20D0 ..= 0x20FF,
         0xFE20 ..= 0xFE2F:
        return true
    }
    return false
}

// Visible cell count: skip ANSI CSI (\x1b[...X) and OSC (\x1b]...(BEL|ESC\))
// sequences, then count runes (2 for Wide/Fullwidth, 0 for combining marks).
display_width :: proc(s: string) -> int {
    w := 0
    i := 0
    for i < len(s) {
        c := s[i]
        if c == 0x1b {
            if i + 1 < len(s) && s[i + 1] == '[' {
                // CSI: params then one final byte in 0x40..0x7e
                j := i + 2
                for j < len(s) && !(s[j] >= 0x40 && s[j] <= 0x7e) do j += 1
                i = j < len(s) ? j + 1 : len(s)
                continue
            }
            if i + 1 < len(s) && s[i + 1] == ']' {
                // OSC (e.g. OSC8 hyperlink): ends at BEL or ESC-backslash
                j := i + 2
                for j < len(s) {
                    if s[j] == 0x07 { j += 1; break }
                    if s[j] == 0x1b && j + 1 < len(s) && s[j + 1] == '\\' {
                        j += 2
                        break
                    }
                    j += 1
                }
                i = j
                continue
            }
            i += 1
            continue
        }
        r, size := utf8.decode_rune_in_string(s[i:])
        if size <= 0 do size = 1
        i += size
        if is_combining_rune(r) do continue
        w += is_wide_rune(r) ? 2 : 1
    }
    return w
}

// ---- segment table

MAX_STAGES :: 3

Seg :: struct {
    name:      string,     // for the --demo decision log
    bg, fg:    string,
    stages:    [MAX_STAGES]string, // [0] richest -> narrowest
    n_stages:  int,
    priority:  int,        // LOWER sheds/drops FIRST
    droppable: bool,
    stage:     int,
    dropped:   bool,
}

SegList :: struct {
    segs: [12]Seg,
    n:    int,
}

add_seg :: proc(l: ^SegList, s: Seg) {
    if l.n < len(l.segs) {
        l.segs[l.n] = s
        l.n += 1
    }
}

seg1 :: proc(name, bg, fg, text: string, priority: int, droppable := true) -> Seg {
    return {name = name, bg = bg, fg = fg, stages = {text, "", ""},
            n_stages = 1, priority = priority, droppable = droppable}
}

FitAction :: enum { SHRINK, DROP }

FitLog :: struct {
    actions: [64]FitAction,
    names:   [64]string,
    stages:  [64]int,
    n:       int,
}

// Total visible width of the rendered line:
//   Σ (display_width(stage text) + 2 padding spaces)
// + (n_live - 1) junction cells (powerline sep or '|' divider)
// + 1 end cap.
// The junction and end-cap terms are LOAD-BEARING — omitting them
// undercounts by ~5 cells and overflows with an empty decision log.
line_total_width :: proc(l: ^SegList) -> int {
    total := 0
    n_live := 0
    for i in 0 ..< l.n {
        s := &l.segs[i]
        if s.dropped do continue
        n_live += 1
        total += display_width(s.stages[s.stage]) + 2
    }
    if n_live == 0 do return 0
    return total + (n_live - 1) + 1
}

// Priority ladder: shed the next stage of the lowest-priority segment that
// still has one; when none has a stage left, drop the lowest-priority
// droppable segment. Repeats until the line fits (or nothing can shrink).
fit_line :: proc(l: ^SegList, cols: int, flog: ^FitLog = nil) {
    for _ in 0 ..< 200 {
        if line_total_width(l) <= cols do break

        // Lowest-priority segment with a stage left to shed
        best := -1
        for i in 0 ..< l.n {
            s := &l.segs[i]
            if s.dropped || s.stage >= s.n_stages - 1 do continue
            if best < 0 || s.priority < l.segs[best].priority do best = i
        }
        if best >= 0 {
            l.segs[best].stage += 1
            if flog != nil && flog.n < len(flog.actions) {
                flog.actions[flog.n] = .SHRINK
                flog.names[flog.n] = l.segs[best].name
                flog.stages[flog.n] = l.segs[best].stage
                flog.n += 1
            }
            continue
        }

        // Nothing left to shrink: drop the lowest-priority droppable segment
        best = -1
        for i in 0 ..< l.n {
            s := &l.segs[i]
            if s.dropped || !s.droppable do continue
            if best < 0 || s.priority < l.segs[best].priority do best = i
        }
        if best < 0 do break
        l.segs[best].dropped = true
        if flog != nil && flog.n < len(flog.actions) {
            flog.actions[flog.n] = .DROP
            flog.names[flog.n] = l.segs[best].name
            flog.stages[flog.n] = -1
            flog.n += 1
        }
    }
}

render_line :: proc(buf: ^OutBuf, l: ^SegList, cap_end := true) {
    buf.prev_bg = ""
    first := true
    for i in 0 ..< l.n {
        s := &l.segs[i]
        if s.dropped do continue
        segment(buf, s.bg, s.fg, s.stages[s.stage], first)
        first = false
    }
    if cap_end do segment_end(buf)
}

/* -------------------------------------------------------------------------- */
/* Terminal width                                                             */
/* -------------------------------------------------------------------------- */

// core:sys/posix exposes neither ioctl nor winsize, so bind them directly.
Winsize :: struct {
    ws_row:    u16,
    ws_col:    u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
}
TIOCGWINSZ :: 0x5413  // Linux
MAX_COLUMNS :: 500

foreign import libc "system:c"
foreign libc {
    // Explicit rawptr, NOT `#c_vararg ..any`: an Odin `any` is a 16-byte fat
    // pointer (data + typeid), so a variadic binding passes two words where C
    // expects one and the ioctl silently reads garbage as its argument.
    ioctl :: proc(fd: posix.FD, request: uint, arg: rawptr) -> i32 ---
}

// Measure the terminal width from the kernel, for when COLUMNS is missing.
//
// Our own fds are useless: stdout and stdin are pipes (Claude Code captures
// them) and stderr is captured too — all three return ENOTTY, verified by
// probing the real statusline. /dev/tty is equally useless: Claude Code setsids,
// so there is no controlling terminal (tty_nr=0) and the open fails with ENXIO.
//
// What does work is going through the Claude Code process itself. Its fds still
// point at the real pty, so resolve /proc/<pid>/fd/N to a /dev/pts/* path, open
// that, and ioctl it. Verified against a live session: returns 196, matching
// COLUMNS=196 exactly.
//
// Read-only is the empty flag set in Odin's posix (there is no RDONLY).
// NOCTTY because we must never acquire the pty as a controlling terminal as a
// side effect of measuring it. Returns 0 when the width cannot be determined.
ioctl_columns :: proc() -> int {
    ws: Winsize
    pid := get_grandparent_pid()

    link_buf: [256]u8
    path_buf: [64]u8
    for fd in ([]int{1, 2, 0}) {
        p := fmt.bprintf(path_buf[:], "/proc/%d/fd/%d", pid, fd)
        p_cstr := strings.clone_to_cstring(p, context.temp_allocator)
        n := posix.readlink(p_cstr, raw_data(&link_buf), len(link_buf) - 1)
        if n <= 0 do continue
        target := string(link_buf[:n])
        // Only pty paths are worth opening; a socket or file cannot answer, and
        // opening an arbitrary target for its side effects would be reckless.
        if !strings.has_prefix(target, "/dev/pts/") do continue

        t_cstr := strings.clone_to_cstring(target, context.temp_allocator)
        tfd := posix.open(t_cstr, {.NOCTTY})
        if tfd < 0 do continue
        ok := ioctl(tfd, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0
        posix.close(tfd)
        if ok do return int(ws.ws_col)
    }
    return 0
}

// Width resolution, most trustworthy first: COLUMNS (what Claude Code itself
// sets and therefore what it measures against), then a live kernel query, then
// 120 — degrade as if narrow rather than assume wide and let Claude Code
// truncate arbitrarily.
get_columns :: proc() -> int {
    cols_c := posix.getenv("COLUMNS")
    if cols_c != nil {
        if v, ok := strconv.parse_int(string(cols_c)); ok && v > 0 {
            // Clamp: an absurd COLUMNS filled OutBuf with gap padding and
            // silently truncated, mid-escape-sequence.
            return min(v, MAX_COLUMNS)
        }
    }
    if v := ioctl_columns(); v > 0 do return min(v, MAX_COLUMNS)
    return 120
}

// ---- line 1: identity

// Last path component of a raw path.
path_basename :: proc(path: string) -> string {
    last := -1
    for i in 0 ..< len(path) {
        if path[i] == '/' do last = i
    }
    return last >= 0 ? path[last + 1:] : path
}

// Strip the last /component from an abbreviated path ("~/P/p/x" -> "~/P/p").
path_parent :: proc(path: string) -> string {
    last := -1
    for i in 0 ..< len(path) {
        if path[i] == '/' do last = i
    }
    return last > 0 ? path[:last] : path
}

// Byte-truncate at a rune boundary (branch names are ASCII in practice, but
// never cut a UTF-8 sequence in half).
trunc_runes :: proc(s: string, max_bytes: int) -> string {
    if len(s) <= max_bytes do return s
    end := max_bytes
    for end > 0 && (s[end] & 0xC0) == 0x80 do end -= 1
    return s[:end]
}

build_line1 :: proc(l: ^SegList, state: ^DisplayState, gs: ^GitStatus, pr: ^PrStatus) {
    // Vim mode (icon only; color carries the mode)
    if len(state.vim_mode) > 0 {
        is_insert := state.vim_mode == "INSERT"
        if is_insert {
            add_seg(l, seg1("vim", ANSI_BG_GREEN, ANSI_FG_BLACK,
                fmt.tprintf("%s%s", ANSI_BOLD, ICON_INSERT), 20))
        } else {
            add_seg(l, seg1("vim", ANSI_BG_DARK, ANSI_FG_WHITE,
                ICON_NORMAL, 20))
        }
    }

    // Model: ALWAYS abbreviated. The full display name was never worth 19 cells
    // ("Opus 5 (1M context)") when the model is the one thing you already know —
    // so the abbreviation is now the primary form, not a shrink stage. The brain
    // glyph still trails it when extended thinking is on.
    short_buf: [32]u8
    short := strings.clone(
        abbreviate_model(short_buf[:], state.model), context.temp_allocator)
    brain := state.thinking_enabled ? fmt.tprintf(" %s", ICON_BRAIN) : ""
    add_seg(l, Seg{
        name = "model", bg = ANSI_BG_PURPLE, fg = ANSI_FG_BLACK,
        stages = {
            fmt.tprintf("%s%s%s", ANSI_BOLD, short, brain),
            fmt.tprintf("%s%s", ANSI_BOLD, short),  // drop the brain glyph
            "",
        },
        n_stages = 2, priority = 95, droppable = false,
    })

    // Path. When the basename equals the branch (worktrees named after their
    // branch), elide it to '…' — the branch segment already carries the name
    // and the path then contributes only parent context. This is the single
    // largest win: line 1 drops from 103 to 81 cells.
    abbrev_buf: [256]u8
    path_full := strings.clone(
        abbrev_path(abbrev_buf[:], state.cwd), context.temp_allocator)
    base := path_basename(state.cwd)
    path_short := fmt.tprintf("~/…/%s", base)
    // Compare against the branch's LAST component, not the whole ref: real
    // branches are prefixed (feat/queue-monitor-dashboard) while the worktree
    // directory is not, so exact equality never matched and the elision never
    // fired — which silently cost the ~22 cells this whole thing exists to save.
    branch_leaf := gs.branch
    if i := strings.last_index_byte(gs.branch, '/'); i >= 0 {
        branch_leaf = gs.branch[i + 1:]
    }
    dup := gs.valid && base == branch_leaf
    path_seg: Seg
    if dup {
        path_seg = Seg{
            name = "path", bg = ANSI_BG_DARK, fg = ANSI_FG_WHITE,
            stages = {
                fmt.tprintf("%s %s/…", ICON_FOLDER, path_parent(path_full)),
                fmt.tprintf("%s ~/…/…", ICON_FOLDER),
                "",
            },
            n_stages = 2, priority = 75,
        }
    } else {
        path_seg = Seg{
            name = "path", bg = ANSI_BG_DARK, fg = ANSI_FG_WHITE,
            stages = {
                fmt.tprintf("%s %s", ICON_FOLDER, path_full),
                fmt.tprintf("%s %s", ICON_FOLDER, path_short),
                fmt.tprintf("%s %s", ICON_FOLDER, base),
            },
            n_stages = 3, priority = 75,
        }
    }
    add_seg(l, path_seg)

    if gs.valid {
        icon: string = gs.is_worktree ? ICON_WORKTREE : ICON_BRANCH
        dirty := gs.staged > 0 || gs.modified > 0 || gs.untracked > 0
        b := gs.branch
        s1: string
        if len(b) > 12 {
            s1 = fmt.tprintf("%s %s…", icon, trunc_runes(b, 12))
        } else {
            s1 = fmt.tprintf("%s %s", icon, b)
        }
        add_seg(l, Seg{
            name = "branch",
            bg = dirty ? ANSI_BG_ORANGE : ANSI_BG_GREEN,
            fg = ANSI_FG_BLACK,
            stages = {
                fmt.tprintf("%s %s", icon, b),
                s1,
                fmt.tprintf("%s %s…", icon, trunc_runes(b, 8)),
            },
            n_stages = 3, priority = 80,
        })

        // Dirty/sync counters, colored per kind
        bits := make([dynamic]string, context.temp_allocator)
        if gs.ahead > 0 {
            append(&bits, fmt.tprintf("%s↑%d", ANSI_FG_GREEN, gs.ahead))
        }
        if gs.behind > 0 {
            append(&bits, fmt.tprintf("%s↓%d", ANSI_FG_RED, gs.behind))
        }
        if gs.staged > 0 {
            append(&bits, fmt.tprintf("%s%s%d", ANSI_FG_GREEN, ICON_STAGED, gs.staged))
        }
        if gs.modified > 0 {
            append(&bits, fmt.tprintf("%s%s%d", ANSI_FG_ORANGE, ICON_MODIFIED, gs.modified))
        }
        if gs.untracked > 0 {
            append(&bits, fmt.tprintf("%s%s%d", ANSI_FG_CYAN, ICON_UNTRACKED, gs.untracked))
        }
        if gs.stashes > 0 {
            append(&bits, fmt.tprintf("%s%s%d", ANSI_FG_PURPLE, ICON_STASH, gs.stashes))
        }
        if len(bits) > 0 {
            joined := strings.join(bits[:], " ", context.temp_allocator)
            add_seg(l, seg1("gitstat", ANSI_BG_DARK, "", joined, 45))
        }
    }

    // PR + CI. Review state rides in the BACKGROUND color (green approved,
    // orange review required, dark undecided) — zero cells. The PR title is
    // deliberately omitted: the branch name to its left says the same thing.
    if pr.valid {
        glyph, gcol: string
        switch pr.ci {
        case .PASS:    glyph = ICON_STAGED; gcol = ANSI_FG_GREEN
        case .FAIL:    glyph = "✗";         gcol = ANSI_FG_RED
        case .PENDING: glyph = "●";         gcol = ANSI_FG_YELLOW
        case .DRAFT:   glyph = "⊘";         gcol = ANSI_FG_COMMENT
        }
        cnt := pr.ci == .FAIL ? fmt.tprintf("%d", pr.failed) : ""
        prbg, prfg: string
        switch pr.review {
        case .APPROVED:        prbg = ANSI_BG_GREEN;  prfg = ANSI_FG_BLACK
        case .REVIEW_REQUIRED: prbg = ANSI_BG_ORANGE; prfg = ANSI_FG_BLACK
        case .NONE:            prbg = ANSI_BG_DARK;   prfg = ANSI_FG_WHITE
        }
        // OSC8 hyperlink around the PR number. Zero visible cells: verified
        // that Bun.stringWidth({ambiguousIsNarrow:true}) — the exact call
        // Claude Code measures with — counts OSC8 (BEL- or ST-terminated)
        // as width 0 (Bun 1.3.14). display_width here skips OSC too.
        num: string
        if len(pr.url) > 0 {
            num = fmt.tprintf("\x1b]8;;%s\x1b\\#%d\x1b]8;;\x1b\\",
                pr.url, pr.number)
        } else {
            num = fmt.tprintf("#%d", pr.number)
        }
        add_seg(l, Seg{
            name = "pr", bg = prbg, fg = prfg,
            stages = {
                fmt.tprintf("%s %s%s%s", num, gcol, glyph, cnt),
                fmt.tprintf("%s %s%s", num, gcol, glyph),
                fmt.tprintf("%s%s", gcol, glyph),
            },
            n_stages = 3, priority = 85,
        })
    }
}

// ---- line 2: budget

// Left-pad with SPACES to a fixed field width. Odin's "%3d" zero-pads ("005%"),
// which is uglier than the sliding it was meant to cure -- so pad explicitly.
// Fixed-width fields matter here because the budget group is right-aligned:
// any field that changes width shifts everything to its LEFT.
padl :: proc(v: string, width: int) -> string {
    if len(v) >= width do return v
    b := make([]u8, width, context.temp_allocator)
    pad := width - len(v)
    for i in 0 ..< pad do b[i] = ' '
    copy(b[pad:], v)
    return string(b)
}

build_line2 :: proc(l: ^SegList, state: ^DisplayState) {
    // Context bar FIRST. This group is right-aligned, so segment order
    // runs right-to-left visually from the screen edge -- emitting ctx
    // first puts it at the group's far LEFT, furthest from the edge.
    // Context bar: 10-cell -> 5-cell -> bare percentage
    bar10_buf: [512]u8
    bar5_buf: [512]u8
    bar10 := make_context_bar(bar10_buf[:], state.used_pct, state.ctx_size,
        state.input_tokens, 10)
    bar5 := make_context_bar(bar5_buf[:], state.used_pct, state.ctx_size,
        state.input_tokens, 5)
    add_seg(l, Seg{
        name = "ctx", bg = ANSI_BG_DARK, fg = "",
        stages = {
            strings.clone(bar10, context.temp_allocator),
            strings.clone(bar5, context.temp_allocator),
            fmt.tprintf("%s%s%%", pct_label_color(min(state.used_pct, 100)),
                padl(fmt.tprintf("%d", min(state.used_pct, 100)), 3)),
        },
        n_stages = 3, priority = 100, droppable = false,
    })

    if state.five_hour_reset > 0 || state.seven_day_reset > 0 {
        // ONE number per window: the level. A bare level cannot answer "will I
        // get capped" -- 23% is fine at minute five and alarming at hour four --
        // but showing the projection as a second percentage read as two
        // unexplained figures. So the level is the number and the PROJECTION
        // drives its colour: green while on pace to finish under the cap,
        // escalating by how badly it would overshoot.
        five := i64(state.five_hour_pct + 0.5)
        seven := i64(state.seven_day_pct + 0.5)

        // Projection: where the 5h window lands at the current pace. It drives
        // the colour ALWAYS, but only appears as a number when it is actually
        // saying something -- on pace, the level alone is the whole story and a
        // second percentage was just noise. Overshooting, the magnitude matters:
        // 110% and 400% call for very different responses.
        c5 := rate_limit_color(state.five_hour_pct)
        proj_txt := ""
        if state.five_hour_reset > 0 {
            start := state.five_hour_reset - 18000
            elapsed_frac := f64(current_time_sec() - start) / 18000.0
            // Below 10% elapsed the projection explodes (30s in, one message
            // projects to 400%), so fall back to colouring by level.
            if elapsed_frac >= 0.10 && elapsed_frac <= 1.0 {
                proj := state.five_hour_pct / elapsed_frac
                c5 = projection_color(proj)
                // 105 is projection_color's first escalation: show the number
                // exactly when the colour stops being green.
                if proj >= 105 {
                    v := proj > 999 ? "999" : fmt.tprintf("%d", i64(proj + 0.5))
                    proj_txt = fmt.tprintf("%s\u2192%s%s%s%%", ANSI_FG_DARK, ANSI_BOLD, c5, v)
                }
            }
        }
        c7 := rate_limit_color(state.seven_day_pct)

        // 5h and 7d live in ONE segment. As two segments they paid for a "|"
        // divider plus a padding space on each side of it -- 4 cells of gap for
        // two numbers that read as a pair. Colours still differ per window;
        // they are inline escapes, not a property of the segment.
        add_seg(l, Seg{
            name = "quota", bg = ANSI_BG_COMMENT, fg = "",
            stages = {
                fmt.tprintf("%s5h %s%s%d%%%s %s7d %s%s%d%%",
                    ANSI_FG_WHITE, ANSI_BOLD, c5, five,
                    proj_txt,
                    ANSI_FG_WHITE, ANSI_BOLD, c7, seven),
                // Shrink: drop 7d, keep 5h (the window you can actually hit).
                fmt.tprintf("%s5h %s%s%d%%%s", ANSI_FG_WHITE, ANSI_BOLD, c5,
                    five, proj_txt),
                "",
            },
            n_stages = 2, priority = 90, droppable = false,
        })

        // Opus weekly cap (Max plans) — only when it's meaningful
        if state.seven_day_opus_pct >= 50 {
            add_seg(l, seg1("opus", ANSI_BG_COMMENT, "",
                fmt.tprintf("%sop %s%s%d%%", ANSI_FG_WHITE, ANSI_BOLD,
                    usage_color(state.seven_day_opus_pct),
                    i64(state.seven_day_opus_pct + 0.5)),
                45))
        }

        // ONE countdown: time until you stop being able to work. That is
        // either the 5h quota running out or the window resetting, whichever
        // lands first, and the icon says which. Compaction used to own this
        // field; it is an inconvenience (auto-compact keeps you going) whereas
        // the quota is a wall, so the wall wins the space.
        now := current_time_sec()
        reset_epoch: i64 = 0
        if state.five_hour_reset > now {
            reset_epoch = state.five_hour_reset
        } else if state.seven_day_opus_pct >= 50 && state.opus_reset > now {
            reset_epoch = state.opus_reset
        } else if state.seven_day_reset > now {
            reset_epoch = state.seven_day_reset
        }

        // Seconds until the 5h window hits 100% at the observed pace.
        // pct_per_sec = level / elapsed; remaining = (100 - level) / rate.
        // Meaningless before ~10% elapsed, same guard as the projection.
        full_secs: i64 = 0
        if state.five_hour_reset > 0 && state.five_hour_pct > 0 {
            w_start := state.five_hour_reset - 18000
            elapsed := now - w_start
            if elapsed > 1800 && state.five_hour_pct < 100 {
                rate := state.five_hour_pct / f64(elapsed) // % per second
                if rate > 0 {
                    full_secs = i64((100.0 - state.five_hour_pct) / rate)
                }
            }
        }

        cd_buf: [16]u8
        if full_secs > 0 && (reset_epoch == 0 || full_secs < reset_epoch - now) {
            // The cap arrives before the reset: this is the deadline that
            // matters, so flag it rather than counting down to a reset you
            // will not reach with quota to spare.
            cd := format_countdown(cd_buf[:], full_secs)
            add_seg(l, seg1("reset", ANSI_BG_COMMENT, "",
                fmt.tprintf("%s%s%s", ANSI_FG_ORANGE, ICON_WARN,
                    strings.clone(cd, context.temp_allocator)),
                40))
        } else if reset_epoch > now {
            cd := format_countdown(cd_buf[:], reset_epoch - now)
            add_seg(l, seg1("reset", ANSI_BG_COMMENT, "",
                fmt.tprintf("%s%s%s", ANSI_FG_WHITE, ICON_SYNC,
                    strings.clone(cd, context.temp_allocator)),
                40))
        }
    }

    if state.total_duration_ms > 0 {
        dur_buf: [32]u8
        dur := format_duration(dur_buf[:], state.total_duration_ms)
        add_seg(l, seg1("dur", ANSI_BG_DARK, "",
            fmt.tprintf("%s%s %s", ANSI_FG_WHITE, ICON_CLOCK,
                strings.clone(dur, context.temp_allocator)),
            10))
    }

    // Burn rate + time-to-compact (until input hits 80% of the window)
    if state.burn_ok && state.burn_per_min > 0 {
        rate: string
        if state.burn_per_min >= 1000 {
            rate = fmt.tprintf("%.1fk", state.burn_per_min / 1000.0)
        } else {
            rate = fmt.tprintf("%.0f", state.burn_per_min)
        }
        add_seg(l, Seg{
            name = "burn", bg = ANSI_BG_DARK, fg = "",
            stages = {
                fmt.tprintf("%s%s %s/m", ANSI_FG_WHITE, ICON_BURN, rate),
                "",
                "",
            },
            n_stages = 1, priority = 55,
        })
    } else {
        // No usable rate yet. Still show the field so its absence never reads
        // as "nothing to report" -- em dash means unknown, not zero.
        add_seg(l, seg1("burn", ANSI_BG_DARK, "",
            fmt.tprintf("%s%s %s\u2014/m", ANSI_FG_WHITE, ICON_BURN, ANSI_FG_COMMENT), 55))
    }

    // Context warning. Deliberately later than the bar's own color ramp: the
    // bar already goes yellow at 65 and orange at 80, so this full-width banner
    // is reserved for "act now". Firing it at 80 made it near-permanent
    // furniture, which is the fastest way to teach yourself to ignore it.
    if state.used_pct >= 88 {
        crit := state.used_pct >= 94
        add_seg(l, Seg{
            name = "warn",
            bg = crit ? ANSI_BG_RED : ANSI_BG_YELLOW,
            fg = ANSI_FG_BLACK,
            stages = {
                fmt.tprintf("%s%s %s", ANSI_BOLD, ICON_WARN,
                    crit ? "COMPACT NOW" : "CTX HIGH"),
                fmt.tprintf("%s%s", ANSI_BOLD, ICON_WARN),
                "",
            },
            n_stages = 2, priority = 99, droppable = false,
        })
    }
}

// Width of a SegList once rendered, without committing it to the output.
measure_line :: proc(l: ^SegList, cap_end := true) -> int {
    tmp: OutBuf
    render_line(&tmp, l, cap_end)
    return display_width(string(tmp.data[:tmp.len]))
}

// Shrink two groups against ONE shared budget, always sacrificing the
// lowest-priority available action across both. Without this the groups would
// each fit `cols` individually and still overflow when placed on one line.
fit_pair :: proc(a: ^SegList, b: ^SegList, budget: int) {
    for _ in 0 ..< 64 {
        if measure_line(a) + measure_line(b, false) <= budget do return
        // Ask each group for its cheapest single step, take the cheaper one.
        pa := lowest_action_priority(a)
        pb := lowest_action_priority(b)
        if pa < 0 && pb < 0 do return
        target := (pb < 0) || (pa >= 0 && pa <= pb) ? a : b
        step_once(target)
    }
}

// Priority of the next action this group would take, or -1 if it has none.
lowest_action_priority :: proc(l: ^SegList) -> int {
    best := -1
    for i in 0 ..< l.n {
        s := &l.segs[i]
        if s.dropped do continue
        has_shrink := s.stage < s.n_stages - 1
        if !has_shrink && !s.droppable do continue
        // A drop is a bigger loss than a shrink, so rank it later.
        p := has_shrink ? s.priority : s.priority + 1000
        if best < 0 || p < best do best = p
    }
    return best
}

// Apply exactly one shrink-or-drop, matching fit_line's ordering.
step_once :: proc(l: ^SegList) {
    best := -1
    for i in 0 ..< l.n {
        s := &l.segs[i]
        if s.dropped || s.stage >= s.n_stages - 1 do continue
        if best < 0 || s.priority < l.segs[best].priority do best = i
    }
    if best >= 0 {
        l.segs[best].stage += 1
        return
    }
    best = -1
    for i in 0 ..< l.n {
        s := &l.segs[i]
        if s.dropped || !s.droppable do continue
        if best < 0 || s.priority < l.segs[best].priority do best = i
    }
    if best >= 0 do l.segs[best].dropped = true
}

// Left-facing round cap, so the floating right-hand group reads as a detached
// group rather than a severed one.
SEP_ROUND_L :: ""

build_statusline :: proc(
    buf   : ^OutBuf,
    state : ^DisplayState,
    gs    : ^GitStatus,
    pr    : ^PrStatus,
) {
    build_statusline_cols(buf, state, gs, pr, get_columns())
}

// Same renderer with the width injected so --demo drives the real code path.
build_statusline_cols :: proc(
    buf   : ^OutBuf,
    state : ^DisplayState,
    gs    : ^GitStatus,
    pr    : ^PrStatus,
    cols  : int,
) {

    l1, l2: SegList
    build_line1(&l1, state, gs, pr)
    build_line2(&l2, state)

    // One cell for the left cap on the right-hand group, plus one reserved
    // slack cell. Right-alignment is unforgiving: a single uncounted cell and
    // Claude Code truncates the RIGHT edge, which is exactly where quota and
    // context live. Left-aligned the same error is invisible.
    CAP_W :: 1
    // Claude Code truncates a few cells before COLUMNS -- it reserves edge
    // columns that v2.1.170 did not (that era's note in this repo says zero).
    // Deduced, not guessed: 13 Ambiguous glyphs are on a typical line, so if CC
    // were miscounting them as 2 cells the overflow would be ~12 and most of the
    // right end would vanish. Observed loss is 1-3 cells, i.e. a small constant.
    // The gap absorbs this for free at any realistic width.
    SLACK :: 3
    budget := cols - CAP_W - SLACK
    if budget < 20 do budget = 20

    fit_pair(&l1, &l2, budget)

    w1 := measure_line(&l1)
    w2 := measure_line(&l2, false)
    gap := budget - w1 - w2
    if gap < 1 do gap = 1

    render_line(buf, &l1)
    for _ in 0 ..< gap do out_char(buf, ' ')

    // Cap is drawn in the FG matching the first surviving segment's background,
    // over the terminal default background.
    for i in 0 ..< l2.n {
        if l2.segs[i].dropped do continue
        cap_buf: [64]u8
        out_str(buf, bg_to_fg(cap_buf[:], l2.segs[i].bg))
        out_str(buf, SEP_ROUND_L)
        out_str(buf, ANSI_RESET)
        break
    }
    render_line(buf, &l2, false)
}

/* -------------------------------------------------------------------------- */
/* Debug Logging                                                              */
/* -------------------------------------------------------------------------- */

write_debug_log :: proc(
    timings       : ^DebugTimings,
    gs            : ^GitStatus,
    stdin_timeout : bool,
) {
    t_end := time.tick_now()
    gppid := get_grandparent_pid()
    cache_str: string
    switch gs.cache_state {
    case .VALID:
        cache_str = "valid"
    case .STALE:
        cache_str = "stale"
    case .NONE:
        cache_str = "miss"
    }
    stdin_str := stdin_timeout ? "timeout" : "ok"
    // Claude Code sets COLUMNS/LINES (v2.1.153+) since stdout is a pipe, not a
    // TTY. Logged here so terminal-width-dependent work can confirm the values.
    cols_c := posix.getenv("COLUMNS")
    lines_c := posix.getenv("LINES")
    cols_s := cols_c != nil ? string(cols_c) : "unset"
    lines_s := lines_c != nil ? string(lines_c) : "unset"
    debug_buf: [512]u8
    debug_str := fmt.bprintf(
        debug_buf[:],
        "cleanup=%dus read=%dus(%s) parse=%dus git=%dus(%s) build=%dus total=%dus cols=%s lines=%s ioctl=%d resolved=%d\n",
        i64(time.duration_microseconds(
            time.tick_diff(
                timings.t_start,
                timings.t_cleanup,
            ),
        )),
        i64(time.duration_microseconds(
            time.tick_diff(
                timings.t_cleanup,
                timings.t_read,
            ),
        )),
        stdin_str,
        i64(time.duration_microseconds(
            time.tick_diff(
                timings.t_read,
                timings.t_parse,
            ),
        )),
        i64(time.duration_microseconds(
            time.tick_diff(
                timings.t_parse,
                timings.t_git,
            ),
        )),
        cache_str,
        i64(time.duration_microseconds(
            time.tick_diff(
                timings.t_git,
                timings.t_build,
            ),
        )),
        i64(time.duration_microseconds(
            time.tick_diff(timings.t_start, t_end),
        )),
        cols_s,
        lines_s,
        ioctl_columns(),
        get_columns(),
    )

    uid := posix.getuid()
    dir_buf: [64]u8
    dir_path := fmt.bprintf(
        dir_buf[:],
        "/tmp/statusline-%d",
        uid,
    )
    dir_cstr := strings.clone_to_cstring(
        dir_path,
        context.temp_allocator,
    )
    posix.mkdir(dir_cstr, {.IRUSR, .IWUSR, .IXUSR})

    log_path_buf: [96]u8
    log_path := fmt.bprintf(
        log_path_buf[:],
        "%s/%d.log",
        dir_path,
        gppid,
    )
    log_cstr := strings.clone_to_cstring(
        log_path,
        context.temp_allocator,
    )
    log_fd := posix.open(
        log_cstr,
        {.WRONLY, .CREAT, .APPEND},
        {.IRUSR, .IWUSR},
    )
    if log_fd >= 0 {
        posix.write(
            log_fd,
            raw_data(debug_buf[:]),
            uint(len(debug_str)),
        )
        posix.close(log_fd)
    }
}

/* -------------------------------------------------------------------------- */
/* Auto-Update (once per day, fire-and-forget)                               */
/* -------------------------------------------------------------------------- */

AUTO_UPDATE_INTERVAL_S :: 86400

maybe_auto_update :: proc() {
    home := string(posix.getenv("HOME"))
    if len(home) == 0 do return

    sentinel_buf: [256]u8
    sentinel_path := fmt.bprintf(
        sentinel_buf[:],
        "%s/.claude/statusline-last-update",
        home,
    )
    sentinel_cstr := strings.clone_to_cstring(
        sentinel_path,
        context.temp_allocator,
    )

    st: posix.stat_t
    now := current_time_sec()
    if posix.stat(sentinel_cstr, &st) == .OK {
        if now - i64(st.st_mtim.tv_sec) < AUTO_UPDATE_INTERVAL_S {
            return
        }
    }

    // Read repo source path written by `make install-odin`
    src_path_buf: [512]u8
    src_path_file := fmt.bprintf(
        src_path_buf[:],
        "%s/.claude/statusline-src",
        home,
    )
    src_cstr := strings.clone_to_cstring(
        src_path_file,
        context.temp_allocator,
    )

    src_fd := posix.open(src_cstr, {})
    if src_fd < 0 do return

    src_data: [512]u8
    n := posix.read(src_fd, raw_data(&src_data), len(src_data) - 1)
    posix.close(src_fd)
    if n <= 0 do return

    src_dir := strings.trim_right_space(string(src_data[:n]))
    if len(src_dir) == 0 do return

    // Touch sentinel immediately to prevent concurrent runs
    touch_fd := posix.open(
        sentinel_cstr,
        {.WRONLY, .CREAT, .TRUNC},
        {.IRUSR, .IWUSR},
    )
    if touch_fd >= 0 do posix.close(touch_fd)

    // Double-fork so grandchild is reparented to init (fully detached)
    first_fork := posix.fork()
    if first_fork < 0 do return
    if first_fork > 0 {
        posix.waitpid(first_fork, nil, {})
        return
    }

    // Middle child
    grandchild := posix.fork()
    if grandchild != 0 do posix._exit(0)

    // Grandchild: pull then rebuild+install
    src_dir_cstr := strings.clone_to_cstring(
        src_dir,
        context.temp_allocator,
    )

    dev_null := posix.open("/dev/null", {.RDWR})
    if dev_null >= 0 {
        posix.dup2(dev_null, 0)
        posix.dup2(dev_null, 1)
        posix.dup2(dev_null, 2)
        if dev_null > 2 do posix.close(dev_null)
    }

    // git pull --ff-only -q
    git_pid := posix.fork()
    if git_pid == 0 {
        git_argv := []cstring{
            "git", "-C", src_dir_cstr,
            "pull", "--ff-only", "-q",
            nil,
        }
        posix.execvp("git", raw_data(git_argv))
        posix._exit(127)
    }
    if git_pid > 0 do posix.waitpid(git_pid, nil, {})

    // make install-odin (exec directly — grandchild becomes make)
    make_argv := []cstring{
        "make", "-C", src_dir_cstr, "install-odin",
        nil,
    }
    posix.execvp("make", raw_data(make_argv))
    posix._exit(127)
}

/* -------------------------------------------------------------------------- */
/* --demo: layout verification (replaces the Python prototype)               */
/* -------------------------------------------------------------------------- */

DemoScenario :: struct {
    title: string,
    state: DisplayState,
    gs:    GitStatus,
    pr:    PrStatus,
}

demo_scenarios :: proc(now: i64) -> [5]DemoScenario {
    // Canned states ported from the layout prototype. Quota resets are
    // chosen so the countdown text matches the prototype ("1h5m" / "47m");
    // the 5h projection is DERIVED from (pct, resets_at) like production,
    // so its value differs from the prototype's hand-set figure but not
    // its width class (see plan Surprises).
    base_state := DisplayState{
        vim_mode = "NORMAL", model = "Opus 5", thinking_enabled = true,
        cwd = "/home/nathanjones/Projects/portal-trees/queue-monitor-dashboard",
        total_duration_ms = 5000,
        used_pct = 35, ctx_size = 200000, input_tokens = 69287,
        five_hour_pct = 21, seven_day_pct = 20,
        five_hour_reset = now + 3900,    // "1h5m"
        seven_day_reset = now + 300000,
        burn_ok = true, burn_per_min = 2100, ttc_sec = 720, // ↑2.1k/m ⚠12m
    }
    base_gs := GitStatus{
        valid = true, is_worktree = true,
        branch = "queue-monitor-dashboard",
        staged = 2, modified = 3, untracked = 1, stashes = 1, ahead = 4,
    }
    base_pr := PrStatus{
        valid = true, number = 257, ci = .PASS, review = .REVIEW_REQUIRED,
        url = "https://github.com/suu-itadm/portal/pull/257",
    }

    s := [5]DemoScenario{
        {"typical worktree, PR awaiting review", base_state, base_gs, base_pr},
        {"clean main checkout, no PR", base_state, base_gs, {}},
        {"CI failing, approved", base_state, base_gs,
            {valid = true, number = 9829, ci = .FAIL, failed = 2,
             review = .APPROVED,
             url = "https://github.com/suu-itadm/mysuu-portal/pull/9829"}},
        {"context critical + quota over pace", base_state, base_gs, base_pr},
        {"no git repo, insert mode", base_state, {}, {}},
    }

    // clean main checkout
    s[1].gs.is_worktree = false
    s[1].gs.branch = "main"
    s[1].gs.staged = 0; s[1].gs.modified = 0; s[1].gs.untracked = 0
    s[1].gs.stashes = 0; s[1].gs.ahead = 0
    s[1].state.used_pct = 8; s[1].state.input_tokens = 16204
    s[1].state.burn_ok = false

    // context critical + quota over pace
    s[3].state.used_pct = 93; s[3].state.input_tokens = 186_400
    s[3].state.five_hour_pct = 61; s[3].state.seven_day_pct = 77
    s[3].state.five_hour_reset = now + 2820 // "47m"
    s[3].state.burn_per_min = 9400; s[3].state.ttc_sec = 120

    // no git repo, insert mode
    s[4].state.vim_mode = "INSERT"
    s[4].state.cwd = "/home/nathanjones/llm-wiki"
    s[4].state.used_pct = 44; s[4].state.input_tokens = 88_012

    return s
}

demo_print_ruler :: proc(cols: int) {
    fmt.printf("  %s", ANSI_FG_COMMENT)
    for i in 0 ..< cols {
        if i % 10 == 0 {
            fmt.printf("%d", (i / 10) % 10)
        } else {
            fmt.printf("·")
        }
    }
    fmt.printf("%s\n", ANSI_RESET)
}

demo_print_log :: proc(flog: ^FitLog) {
    for i in 0 ..< flog.n {
        if i > 0 do fmt.printf(", ")
        if flog.actions[i] == .SHRINK {
            fmt.printf("shrink %s->s%d", flog.names[i], flog.stages[i])
        } else {
            fmt.printf("drop %s", flog.names[i])
        }
    }
    if flog.n == 0 do fmt.printf("-")
}

// Render every scenario at every width with a ruler, measured widths, and
// the shrink/drop decision log. Exits non-zero if any line exceeds its
// target width or overflows OutBuf.
run_demo :: proc() -> int {
    now := current_time_sec()
    scenarios := demo_scenarios(now)
    // Nathan's real logged COLUMNS values, plus 80 as a stress floor. The old
    // list (60/140/200) tested widths that never occur on this machine.
    widths := [6]int{225, 196, 193, 159, 132, 80}
    failed := false

    for &sc in scenarios {
        fmt.printf("%s%s\u2500\u2500 %s %s\n", ANSI_BOLD, ANSI_FG_PURPLE,
            sc.title, ANSI_RESET)
        for cols in widths {
            // Drive the SHIPPING path. The previous demo fitted each group
            // against the full width independently and printed two lines: it
            // passed while never touching the gap arithmetic, the cap cell or
            // fit_pair -- which is exactly where both of this layout's real
            // bugs lived.
            buf: OutBuf
            build_statusline_cols(&buf, &sc.state, &sc.gs, &sc.pr, cols)
            line := string(buf.data[:buf.len])
            w := display_width(line)

            fmt.printf("%s  cols=%d%s\n", ANSI_FG_COMMENT, cols, ANSI_RESET)
            demo_print_ruler(cols)
            fmt.printf("  %s  %s[%d]%s\n", line, ANSI_FG_COMMENT, w, ANSI_RESET)
            if w > cols {
                fmt.printf("%s    !! OVERFLOW w=%d cols=%d%s\n", ANSI_FG_RED,
                    w, cols, ANSI_RESET)
                failed = true
            }
            if buf.overflow {
                fmt.printf("%s    !! OUTBUF TRUNCATED%s\n", ANSI_FG_RED,
                    ANSI_RESET)
                failed = true
            }
            fmt.printf("\n")
        }
    }
    if failed {
        fmt.printf("%sdemo FAILED%s\n", ANSI_FG_RED, ANSI_RESET)
        return 1
    }
    fmt.printf("%sdemo ok: 5 scenarios x 6 widths, no overflow%s\n",
        ANSI_FG_GREEN, ANSI_RESET)
    return 0
}

/* -------------------------------------------------------------------------- */
/* Main                                                                       */
/* -------------------------------------------------------------------------- */

main :: proc() {
    for arg in os.args[1:] {
        if arg == "--demo" {
            os.exit(run_demo())
        }
    }

    timings: DebugTimings
    timings.t_start = time.tick_now()
    debug := posix.getenv("STATUSLINE_DEBUG") != nil

    cleanup_stale_caches()
    maybe_auto_update()
    if debug do timings.t_cleanup = time.tick_now()

    input, stdin_timeout := read_stdin()
    if debug do timings.t_read = time.tick_now()

    state := resolve_state(input, stdin_timeout)
    if debug do timings.t_parse = time.tick_now()

    // Usage quota: stdin JSON rate_limits (set in resolve_state) is the
    // primary source. The background OAuth fetch cache fills in only when
    // the JSON had none (stdin timeout / older Claude Code), and is the
    // sole source for the opus weekly window, which the JSON lacks.
    gppid := get_grandparent_pid()
    usage := read_usage_cache(gppid)
    if state.five_hour_reset == 0 && state.seven_day_reset == 0 {
        state.five_hour_pct = usage.five_hour_pct
        state.seven_day_pct = usage.seven_day_pct
        state.five_hour_reset = usage.five_hour_reset
        state.seven_day_reset = usage.seven_day_reset
    }
    state.seven_day_opus_pct = usage.seven_day_opus_pct
    state.opus_reset = usage.opus_reset

    // Git status. Resolve the repo root by upward walk so worktrees
    // (.git is a file) and subdirectories both work. Cache is keyed on the
    // resolved root, so every subdir of a repo shares one entry.
    gs: GitStatus
    pr: PrStatus
    pr_url_buf: [128]u8
    git_bufs: GitPathsBuf
    branch_buf: [128]u8
    if len(state.cwd) > 0 {
        if gp, gok := resolve_git_paths(state.cwd, &git_bufs); gok {
            if branch, ok := git_read_branch_fast(branch_buf[:], gp.gitdir);
                ok {
                gs.valid = true
                gs.is_worktree = gp.is_worktree
                gs.branch = branch
                gs.stashes = git_read_stash_count(gp.commondir)
                gs.modified, gs.staged, gs.untracked,
                    gs.ahead, gs.behind, gs.cache_state =
                    get_git_status_cached(gp.root, gp.gitdir)
                pr = get_pr_status_cached(
                    gp.root, gp.gitdir, gs.branch, pr_url_buf[:])
            }
        }
    }
    if debug do timings.t_git = time.tick_now()

    // Build and output
    buf: OutBuf
    build_statusline(&buf, &state, &gs, &pr)
    if debug do timings.t_build = time.tick_now()

    // No visible timing suffix. Timings still go to the debug log
    // (write_debug_log below) -- rendering them INTO the statusline meant the
    // measurement changed the thing being measured, and it shifted the line
    // width by 6-8 cells, which now matters for width-aware layout.

    posix.write(1, raw_data(&buf.data), uint(buf.len))

    if debug {
        write_debug_log(&timings, &gs, stdin_timeout)
    }
}
