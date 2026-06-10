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
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

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
ICON_BRAIN     :: "\U000F09D1"   // \uDB82\uDDD1 md-brain (extended thinking on)

/* -------------------------------------------------------------------------- */
/* Output Buffer                                                              */
/* -------------------------------------------------------------------------- */

OutBuf :: struct {
    data:    [4096]u8,
    len:     int,
    prev_bg: string,
}

out_str :: proc(buf: ^OutBuf, s: string) {
    if buf.len + len(s) < len(buf.data) {
        copy(buf.data[buf.len:], s)
        buf.len += len(s)
    }
}

out_char :: proc(buf: ^OutBuf, c: u8) {
    if buf.len + 1 < len(buf.data) {
        buf.data[buf.len] = c
        buf.len += 1
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

bg_to_fg :: proc(bg: string) -> string {
    // All BG strings are \x1b[48;2;R;G;Bm — byte[2] is '4'
    // FG equivalent is \x1b[38;2;R;G;Bm — just flip to '3'
    if len(bg) < 4 do return ""

    @(static) fg_buf: [64]u8
    if len(bg) >= len(fg_buf) do return ""

    copy(fg_buf[:], bg)
    fg_buf[2] = '3'
    return string(fg_buf[:len(bg)])
}

segment :: proc(
    buf: ^OutBuf,
    bg: string,
    fg: string,
    text: string,
    first: bool,
) {
    if !first && len(buf.prev_bg) > 0 {
        if buf.prev_bg == bg {
            out_str(buf, bg)
            out_str(buf, ANSI_FG_COMMENT)
            out_str(buf, "|")
            out_str(buf, ANSI_RESET)
        } else {
            out_str(buf, bg)
            out_str(buf, bg_to_fg(buf.prev_bg))
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

    buf.prev_bg = bg
}

segment_end :: proc(buf: ^OutBuf) {
    if len(buf.prev_bg) > 0 {
        out_str(buf, bg_to_fg(buf.prev_bg))
        out_str(buf, SEP_ROUND)
        out_str(buf, ANSI_RESET)
    }
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

abbrev_path :: proc(path: string) -> string {
    @(static) result_buf: [256]u8
    @(static) working_buf: [512]u8

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

abbreviate_model :: proc(model: string) -> string {
    @(static) abbrev_buf: [32]u8

    Family :: struct {
        name:   string,
        abbrev: string,
    }
    families := [3]Family{
        {"Opus", "Op"},
        {"Sonnet", "So"},
        {"Haiku", "Ha"},
    }

    // Find version number (digit.digit)
    version_start := -1
    for i in 0 ..< len(model) - 2 {
        if model[i] >= '0' && model[i] <= '9' &&
            model[i + 1] == '.' &&
            model[i + 2] >= '0' &&
            model[i + 2] <= '9' {
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
        // Copy version digits and dots
        i := version_start
        for i < len(model) &&
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

// Fractional block characters: ▏▎▍▌▋▊▉█ (1/8 to 8/8)
FRAC_BLOCKS :: [8]string{
    "\u258F", "\u258E", "\u258D", "\u258C",
    "\u258B", "\u258A", "\u2589", "\u2588",
}
FILLED_BLOCK :: "\u25b0"  // filled rectangle
EMPTY_BLOCK :: "\u25b1"  // empty (outlined) rectangle

// Color zone for a given cell position (0-based) in a
// 10-cell bar. Each cell = 10%.
// 0-3: green (0-40%), 4-5: yellow (40-60%),
// 6-7: orange (60-80%), 8-9: red (80-100%)
zone_color :: proc(cell: int) -> string {
    switch cell {
    case 0, 1, 2, 3: return ANSI_FG_GREEN
    case 4, 5:       return ANSI_FG_YELLOW
    case 6, 7:       return ANSI_FG_ORANGE
    case:            return ANSI_FG_RED
    }
}

// Color for the percentage label (matches leading edge)
pct_label_color :: proc(pct: i64) -> string {
    if pct >= 80 do return ANSI_FG_RED
    if pct >= 60 do return ANSI_FG_ORANGE
    if pct >= 40 do return ANSI_FG_YELLOW
    return ANSI_FG_GREEN
}

make_context_bar :: proc(
    pct: i64,
    ctx_size: i64,
    input_tokens: i64,
) -> string {
    @(static) bar_buf: [512]u8

    clamped := min(pct, 100)
    WIDTH :: 10
    // Number of filled cells (rounded)
    filled := int((clamped * WIDTH + 50) / 100)

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
        s := fmt.bprintf(bar_buf[pos:], "%s%s ", ANSI_FG_WHITE, tok)
        pos += len(s)
    }

    // Bar: WIDTH cells of filled / empty rectangles with color zones
    for cell in 0 ..< WIDTH {
        if cell < filled {
            color := zone_color(cell)
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

format_duration :: proc(ms: i64) -> string {
    @(static) dur_buf: [32]u8

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
    branch:      string,
    stashes:     i64,
    modified:    u32,
    staged:      u32,
    ahead:       u32,
    behind:      u32,
    cache_state: CacheState,
}

git_read_stash_count :: proc(dir: string) -> i64 {
    stash_path := strings.concatenate(
        {dir, "/.git/logs/refs/stash"},
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

git_read_branch_fast :: proc(
    dir: string,
) -> (
    branch: string,
    ok: bool,
) {
    @(static) branch_buf: [128]u8

    head_path := strings.concatenate(
        {dir, "/.git/HEAD"},
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
    last_update_sec: i64,
    input_tokens:    i64,
    cwd:             [256]u8,
    model:           [64]u8,
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

get_cache_path :: proc() -> string {
    @(static) path_buf: [64]u8
    gppid := get_grandparent_pid()
    return fmt.bprintf(
        path_buf[:],
        "%s%d",
        CACHE_PATH_PREFIX,
        gppid,
    )
}

read_cached_state :: proc() -> CachedState {
    cache_path := get_cache_path()
    cache_cstr := strings.clone_to_cstring(
        cache_path,
        context.temp_allocator,
    )
    fd := posix.open(cache_cstr, {})
    if fd < 0 do return {}
    defer posix.close(fd)

    state: CachedState
    buf := transmute([^]u8)&state
    n := posix.read(fd, buf, size_of(CachedState))
    if n != size_of(CachedState) do return {}
    return state
}

write_cached_state :: proc(state: CachedState) {
    cache_path := get_cache_path()
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

get_git_cache_path :: proc(repo_path: string) -> string {
    @(static) path_buf: [64]u8
    h := hash_path(repo_path)
    return fmt.bprintf(
        path_buf[:],
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
) -> (
    cache: GitCache,
    state: CacheState,
) {
    cache_path := get_git_cache_path(repo_path)
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

    index_path := strings.concatenate(
        {repo_path, "/.git/index"},
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
    modified: u32,
    staged: u32,
    ahead: u32,
    behind: u32,
) {
    index_path := strings.concatenate(
        {repo_path, "/.git/index"},
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
    cache.ahead = ahead
    cache.behind = behind
    copy(cache.repo_path[:], repo_path)

    cache_path := get_git_cache_path(repo_path)
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
    ahead: u32,
    behind: u32,
) {
    pipe_fds: [2]posix.FD
    if posix.pipe(&pipe_fds) != .OK {
        return 0, 0, 0, 0
    }
    pipe_read := pipe_fds[0]
    pipe_write := pipe_fds[1]

    pid := posix.fork()
    if pid < 0 {
        posix.close(pipe_read)
        posix.close(pipe_write)
        return 0, 0, 0, 0
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
            "-uno",
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

        if line[0] != ' ' && line[0] != '?' {
            staged += 1
        }
        if line[1] != ' ' && line[1] != '?' {
            modified += 1
        }
    }

    return modified, staged, ahead, behind
}

get_git_status_cached :: proc(
    repo_path: string,
) -> (
    modified: u32,
    staged: u32,
    ahead: u32,
    behind: u32,
    state: CacheState,
) {
    cache, cache_state := read_git_cache(repo_path)

    switch cache_state {
    case .VALID:
        return cache.modified, cache.staged,
            cache.ahead, cache.behind, .VALID
    case .STALE:
        bg_pid := posix.fork()
        if bg_pid == 0 {
            if posix.fork() == 0 {
                m, s, a, b := run_git_status(repo_path)
                write_git_cache(repo_path, m, s, a, b)
            }
            posix._exit(0)
        }
        if bg_pid > 0 {
            posix.waitpid(bg_pid, nil, {})
        }
        return cache.modified, cache.staged,
            cache.ahead, cache.behind, .STALE
    case .NONE:
        modified, staged, ahead, behind =
            run_git_status(repo_path)
        write_git_cache(
            repo_path,
            modified,
            staged,
            ahead,
            behind,
        )
        return modified, staged, ahead, behind, .NONE
    }

    return 0, 0, 0, 0, .NONE
}

/* -------------------------------------------------------------------------- */
/* Usage Quota Cache                                                          */
/* -------------------------------------------------------------------------- */

USAGE_CACHE_TTL_S :: 60
USAGE_CACHE_PREFIX :: "/dev/shm/statusline-usage."

UsageCache :: struct #packed {
    fetch_time_sec:     i64,
    five_hour_pct:      f64,
    seven_day_pct:      f64,
    seven_day_opus_pct: f64,
    five_hour_reset:    i64,  // epoch sec, 0 if unknown
    seven_day_reset:    i64,
    opus_reset:         i64,
}

get_usage_cache_path :: proc(gppid: int) -> string {
    @(static) path_buf: [64]u8
    return fmt.bprintf(
        path_buf[:],
        "%s%d",
        USAGE_CACHE_PREFIX,
        gppid,
    )
}

refresh_usage_cache :: proc(gppid: int) {
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
    home := string(posix.getenv("HOME"))
    if len(home) == 0 do posix._exit(1)

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
    if cred_fd < 0 do posix._exit(1)

    cred_buf: [4096]u8
    cred_len := posix.read(
        cred_fd,
        raw_data(&cred_buf),
        len(cred_buf) - 1,
    )
    posix.close(cred_fd)
    if cred_len <= 0 do posix._exit(1)

    cred_json := string(cred_buf[:cred_len])

    // Find claudeAiOauth object, extract accessToken
    oauth_idx := strings.index(
        cred_json,
        "\"claudeAiOauth\"",
    )
    if oauth_idx < 0 do posix._exit(1)

    oauth_rest := cred_json[oauth_idx:]
    brace_idx := strings.index(oauth_rest, "{")
    if brace_idx < 0 do posix._exit(1)

    oauth_obj := oauth_rest[brace_idx:]
    token := json_get_string(oauth_obj, "accessToken")
    if len(token) == 0 do posix._exit(1)

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
    if posix.pipe(&pipe_fds) != .OK do posix._exit(1)

    curl_pid := posix.fork()
    if curl_pid < 0 do posix._exit(1)

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

    // Write cache
    cache: UsageCache
    cache.fetch_time_sec = current_time_sec()
    cache.five_hour_pct = five_pct
    cache.seven_day_pct = seven_pct
    cache.seven_day_opus_pct = opus_pct
    cache.five_hour_reset = five_reset
    cache.seven_day_reset = seven_reset
    cache.opus_reset = opus_reset

    cache_path := get_usage_cache_path(gppid)
    cache_cstr := strings.clone_to_cstring(
        cache_path,
        context.temp_allocator,
    )

    cache_fd := posix.open(
        cache_cstr,
        {.WRONLY, .CREAT, .TRUNC},
        {.IRUSR, .IWUSR},
    )
    if cache_fd >= 0 {
        c := cache
        posix.write(
            cache_fd,
            transmute([^]u8)&c,
            size_of(UsageCache),
        )
        posix.close(cache_fd)
    }
    posix._exit(0)
}

read_usage_cache :: proc(gppid: int) -> UsageCache {
    cache_path := get_usage_cache_path(gppid)
    cache_cstr := strings.clone_to_cstring(
        cache_path,
        context.temp_allocator,
    )

    fd := posix.open(cache_cstr, {})
    if fd < 0 {
        refresh_usage_cache(gppid)
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
        refresh_usage_cache(gppid)
        return {}
    }

    // Check TTL
    now := current_time_sec()
    if now - cache.fetch_time_sec > USAGE_CACHE_TTL_S {
        refresh_usage_cache(gppid)
    }

    return cache
}

/* -------------------------------------------------------------------------- */
/* Git Segment Builder                                                        */
/* -------------------------------------------------------------------------- */

truncate_branch :: proc(
    branch: string,
    max_len: int,
) -> string {
    @(static) trunc_buf: [64]u8
    if len(branch) <= max_len {
        return branch
    }
    copy(trunc_buf[:], branch[:max_len - 3])
    copy(trunc_buf[max_len - 3:], "...")
    return string(trunc_buf[:max_len])
}

build_git_segment :: proc(
    buf: ^OutBuf,
    gs: ^GitStatus,
) {
    if !gs.valid do return

    text_buf: [256]u8
    text := fmt.bprintf(text_buf[:], "%s %s", ICON_BRANCH, truncate_branch(gs.branch, 20))

    bg := gs.modified > 0 || gs.staged > 0 ? ANSI_BG_ORANGE : ANSI_BG_GREEN
    segment(buf, bg, ANSI_FG_BLACK, text, false)

    if gs.staged > 0 || gs.modified > 0 ||
        gs.stashes > 0 || gs.ahead > 0 ||
        gs.behind > 0 {
        st_buf: [256]u8
        pos := 0
        if gs.ahead > 0 {
            s := fmt.bprintf(st_buf[pos:], "%s\u2191%d ", ANSI_FG_GREEN, gs.ahead)
            pos += len(s)
        }
        if gs.behind > 0 {
            s := fmt.bprintf(st_buf[pos:], "%s\u2193%d ", ANSI_FG_RED, gs.behind)
            pos += len(s)
        }
        if gs.staged > 0 {
            s := fmt.bprintf(st_buf[pos:], "%s%s%d ", ANSI_FG_GREEN, ICON_STAGED, gs.staged)
            pos += len(s)
        }
        if gs.modified > 0 {
            s := fmt.bprintf(st_buf[pos:], "%s%s%d ", ANSI_FG_ORANGE, ICON_MODIFIED, gs.modified)
            pos += len(s)
        }
        if gs.stashes > 0 {
            s := fmt.bprintf(st_buf[pos:], "%s%s%d", ANSI_FG_PURPLE, ICON_STASH, gs.stashes)
            pos += len(s)
        }
        for pos > 0 && st_buf[pos - 1] == ' ' do pos -= 1
        segment(buf, ANSI_BG_DARK, "", string(st_buf[:pos]), false)
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
    last_update_sec:    i64,
    input_tokens:       i64,
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
        state.last_update_sec    = current_time_sec()

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
        new_cache.last_update_sec =
            state.last_update_sec
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
        state.last_update_sec   = cached.last_update_sec
    }

    return state
}

/* -------------------------------------------------------------------------- */
/* Time Formatting                                                            */
/* -------------------------------------------------------------------------- */

format_time_12h :: proc(epoch_sec: i64) -> string {
    @(static) time_buf: [16]u8

    // Convert epoch to local time via localtime_r
    // We use posix tm struct
    t := posix.time_t(epoch_sec)
    local: posix.tm
    posix.localtime_r(&t, &local)

    hour := int(local.tm_hour) % 12
    if hour == 0 do hour = 12
    ampm := int(local.tm_hour) < 12 ? " AM" : " PM"

    return fmt.bprintf(
        time_buf[:],
        "%d:%02d:%02d%s",
        hour,
        int(local.tm_min),
        int(local.tm_sec),
        ampm,
    )
}

usage_color :: proc(pct: f64) -> string {
    if pct >= 90 do return ANSI_FG_RED
    if pct >= 80 do return ANSI_FG_ORANGE
    if pct >= 50 do return ANSI_FG_YELLOW
    return ANSI_FG_GREEN
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

build_statusline :: proc(
    buf   : ^OutBuf,
    state : ^DisplayState,
    gs    : ^GitStatus,
) {
    first := true

    // Vim mode (icon only, color indicates mode)
    if len(state.vim_mode) > 0 {
        vim_bg, vim_fg, vim_icon: string
        is_insert := state.vim_mode == "INSERT"
        if is_insert {
            vim_bg = ANSI_BG_GREEN
            vim_fg = ANSI_FG_BLACK
            vim_icon = ICON_INSERT
        } else {
            vim_bg = ANSI_BG_DARK
            vim_fg = ANSI_FG_WHITE
            vim_icon = ICON_NORMAL
        }
        vim_buf: [64]u8
        vim_text: string
        if is_insert {
            vim_text = fmt.bprintf(vim_buf[:], "%s%s", ANSI_BOLD, vim_icon)
        } else {
            vim_text = vim_icon
        }
        segment(buf, vim_bg, vim_fg, vim_text, first)
        first = false
    }

    // Model (abbreviated, bold). A brain glyph trails the name when extended
    // thinking is enabled for the session (thinking.enabled in stdin JSON).
    model_buf: [128]u8
    model_text: string
    if state.thinking_enabled {
        model_text = fmt.bprintf(
            model_buf[:], "%s%s %s", ANSI_BOLD,
            abbreviate_model(state.model), ICON_BRAIN,
        )
    } else {
        model_text = fmt.bprintf(
            model_buf[:], "%s%s", ANSI_BOLD, abbreviate_model(state.model),
        )
    }
    segment(buf, ANSI_BG_PURPLE, ANSI_FG_BLACK, model_text, first)
    first = false

    // Path
    path_buf: [300]u8
    path_text := fmt.bprintf(path_buf[:], "%s %s", ICON_FOLDER, abbrev_path(state.cwd))
    segment(buf, ANSI_BG_DARK, ANSI_FG_WHITE, path_text, false)

    // Git
    if gs.valid {
        build_git_segment(buf, gs)
    }

    // Cost intentionally omitted: total_cost_usd is an API-equivalent figure,
    // NOT a real charge on a flat subscription. Showing dollars on a Pro plan
    // is misleading, so it's dropped in favor of the real ceiling — usage.

    // Usage quota — the REAL ceiling on a subscription, so show it whenever
    // it's known (any successful fetch sets a reset timestamp), at any level.
    // Opus weekly cap (Max plans) and a countdown to the soonest reset are
    // appended when relevant.
    if state.five_hour_reset > 0 || state.seven_day_reset > 0 {
        // 5h and 7d share one color, driven by whichever window is hotter,
        // so the pair reads as a single rate-limit risk indicator.
        color_rl := rate_limit_color(max(state.five_hour_pct, state.seven_day_pct))
        usage_buf: [256]u8
        pos := 0
        s := fmt.bprintf(
            usage_buf[:],
            "%s5h %s%s%d%% %s7d %s%s%d%%",
            ANSI_FG_WHITE, ANSI_BOLD, color_rl, i64(state.five_hour_pct + 0.5),
            ANSI_FG_WHITE, ANSI_BOLD, color_rl, i64(state.seven_day_pct + 0.5),
        )
        pos += len(s)

        // Opus weekly cap (only when it's actually meaningful)
        if state.seven_day_opus_pct >= 50 {
            color_op := usage_color(state.seven_day_opus_pct)
            so := fmt.bprintf(
                usage_buf[pos:],
                " %sop %s%s%d%%",
                ANSI_FG_WHITE, ANSI_BOLD, color_op,
                i64(state.seven_day_opus_pct + 0.5),
            )
            pos += len(so)
        }

        // Countdown to the soonest relevant reset. Prefer the 5h window
        // when it's the one driving the display; fall back to weekly.
        now := current_time_sec()
        reset_epoch: i64 = 0
        if state.five_hour_reset > now {
            reset_epoch = state.five_hour_reset
        } else if state.seven_day_opus_pct >= 50 && state.opus_reset > now {
            reset_epoch = state.opus_reset
        } else if state.seven_day_reset > now {
            reset_epoch = state.seven_day_reset
        }
        if reset_epoch > now {
            cd_buf: [16]u8
            cd := format_countdown(cd_buf[:], reset_epoch - now)
            // "|" separates the usage totals from the reset countdown. Use
            // FG_DARK, not FG_COMMENT — this segment's background IS
            // ANSI_BG_COMMENT, so a comment-colored bar would be invisible.
            sr := fmt.bprintf(
                usage_buf[pos:],
                " %s| %s%s%s",
                ANSI_FG_DARK, ANSI_FG_WHITE, ICON_SYNC, cd,
            )
            pos += len(sr)
        }

        segment(buf, ANSI_BG_COMMENT, "", string(usage_buf[:pos]), false)
    }

    // Combined: duration | last update | tokens | context bar
    if state.total_duration_ms > 0 {
        dur_buf: [512]u8
        pos := 0
        s := fmt.bprintf(dur_buf[:], "%s%s %s", ANSI_FG_WHITE, ICON_CLOCK, format_duration(state.total_duration_ms))
        pos += len(s)

        if state.last_update_sec > 0 {
            s3 := fmt.bprintf(dur_buf[pos:], " %s| %s%s %s", ANSI_FG_COMMENT, ANSI_FG_WHITE, ICON_SYNC, format_time_12h(state.last_update_sec))
            pos += len(s3)
        }

        s5 := fmt.bprintf(dur_buf[pos:], " %s| ", ANSI_FG_COMMENT)
        pos += len(s5)

        // total_input_tokens is the real current context occupancy (input +
        // cache read/write) as of Claude Code v2.1.132+, so show it exactly
        // rather than deriving a coarse count from the integer percentage.
        bar := make_context_bar(state.used_pct, state.ctx_size, state.input_tokens)
        copy(dur_buf[pos:], bar)
        pos += len(bar)

        segment(buf, ANSI_BG_DARK, "", string(dur_buf[:pos]), false)
    }

    // Context limit warnings
    if state.used_pct >= 80 {
        warn_buf: [128]u8
        warn_text: string
        warn_bg: string
        if state.used_pct >= 95 {
            warn_text = fmt.bprintf(warn_buf[:], "%s%s CRITICAL COMPACT", ANSI_BOLD, ICON_WARN)
            warn_bg = ANSI_BG_RED
        } else if state.used_pct >= 90 {
            warn_text = fmt.bprintf(warn_buf[:], "%s%s LOW CTX COMPACT", ANSI_BOLD, ICON_WARN)
            warn_bg = ANSI_BG_RED
        } else {
            warn_text = fmt.bprintf(warn_buf[:], "%s CTX 80%%+", ICON_WARN)
            warn_bg = ANSI_BG_YELLOW
        }
        segment(buf, warn_bg, ANSI_FG_BLACK, warn_text, false)
    }

    segment_end(buf)
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
        "cleanup=%dus read=%dus(%s) parse=%dus git=%dus(%s) build=%dus total=%dus cols=%s lines=%s\n",
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
/* Main                                                                       */
/* -------------------------------------------------------------------------- */

main :: proc() {
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

    // Git status
    gs: GitStatus
    if len(state.cwd) > 0 {
        if branch, ok := git_read_branch_fast(state.cwd);
            ok {
            gs.valid = true
            gs.branch = branch
            gs.stashes = git_read_stash_count(state.cwd)
            gs.modified, gs.staged, gs.ahead, gs.behind, gs.cache_state =
                get_git_status_cached(state.cwd)
        }
    }
    if debug do timings.t_git = time.tick_now()

    // Build and output
    buf: OutBuf
    build_statusline(&buf, &state, &gs)
    if debug do timings.t_build = time.tick_now()

    // Timing suffix (only in debug mode)
    if debug {
        t_now := time.tick_now()
        total_us := i64(time.duration_microseconds(
            time.tick_diff(timings.t_start, t_now),
        ))
        timing_buf: [64]u8
        timing_str: string
        if total_us >= 1000 {
            timing_str = fmt.bprintf(
                timing_buf[:],
                "  %s%.1fms%s",
                ANSI_FG_COMMENT,
                f64(total_us) / 1000.0,
                ANSI_RESET,
            )
        } else {
            timing_str = fmt.bprintf(
                timing_buf[:],
                "  %s%dus%s",
                ANSI_FG_COMMENT,
                total_us,
                ANSI_RESET,
            )
        }
        out_str(&buf, timing_str)
    }

    posix.write(1, raw_data(&buf.data), uint(buf.len))

    if debug {
        write_debug_log(&timings, &gs, stdin_timeout)
    }
}
