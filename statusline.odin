// Claude Code Statusline - Odin Version (v4)
//
// A fast statusline for Claude Code written in Odin.
// Port of the C version with enhanced visuals.
//
// Build: odin build . -o:speed -out:statusline_odin
// Usage: Set in ~/.claude/settings.json statusLine.command

package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

/* ---------------------------------------------------------------------------------- */
/* ANSI Colors (Dracula Theme)                                                        */
/* ---------------------------------------------------------------------------------- */

ANSI_RESET      :: "\x1b[0m"
ANSI_BOLD       :: "\x1b[1m"
ANSI_DIM        :: "\x1b[2m"

ANSI_BG_PURPLE  :: "\x1b[48;2;189;147;249m"
ANSI_BG_ORANGE  :: "\x1b[48;2;255;184;108m"
ANSI_BG_DARK    :: "\x1b[48;2;68;71;90m"
ANSI_BG_GREEN   :: "\x1b[48;2;72;209;104m"
ANSI_BG_MINT    :: "\x1b[48;2;40;167;69m"
ANSI_BG_COMMENT :: "\x1b[48;2;98;114;164m"
ANSI_BG_RED     :: "\x1b[48;2;255;85;85m"
ANSI_BG_CYAN    :: "\x1b[48;2;139;233;253m"
ANSI_BG_PINK    :: "\x1b[48;2;255;121;198m"
ANSI_BG_YELLOW  :: "\x1b[48;2;241;250;140m"
ANSI_BG_DARKER  :: "\x1b[48;2;40;42;54m"

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
SEP_ARROW   :: "\uE0B0"  //
SEP_ROUND   :: "\uE0B4"  //
SEP_FLAME   :: "\uE0C0"  //

// Nerd Font icons
ICON_BRANCH   :: "\uF126"   //  git branch
ICON_FOLDER   :: "\uF07C"   //  folder open
ICON_DOLLAR   :: "\uF155"   //  dollar
ICON_TAG      :: "\uF02B"   //  tag
ICON_CLOCK    :: "\uF017"   //  clock
ICON_DIFF     :: "\uF440"   //  diff
ICON_STASH    :: "\uF01C"   //  inbox/stash
ICON_TOKENS   :: "\uF2DB"   //  microchip
ICON_INSERT   :: "\uF040"   //  pencil (insert mode)
ICON_NORMAL   :: "\uE7C5"   //  vim logo (normal mode)

/* ---------------------------------------------------------------------------------- */
/* Output Buffer                                                                      */
/* ---------------------------------------------------------------------------------- */

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

/* ---------------------------------------------------------------------------------- */
/* Segment Builder                                                                    */
/* ---------------------------------------------------------------------------------- */

bg_to_fg :: proc(bg: string) -> string {
    if len(bg) == 0 do return ""

    idx := strings.index(bg, "48;2")
    if idx < 0 do return ""

    @(static) fg_buf: [64]u8
    if idx + len(bg[idx:]) >= len(fg_buf) do return ""

    copy(fg_buf[:], bg[:idx])
    fg_buf[idx] = '3'
    fg_buf[idx + 1] = '8'
    copy(fg_buf[idx + 2:], bg[idx + 2:])

    return string(fg_buf[:len(bg)])
}

segment :: proc(buf: ^OutBuf, bg: string, fg: string, text: string, first: bool) {
    if !first && len(buf.prev_bg) > 0 {
        out_str(buf, bg)
        out_str(buf, bg_to_fg(buf.prev_bg))
        out_str(buf, SEP_ROUND)
        out_str(buf, ANSI_RESET)
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

/* ---------------------------------------------------------------------------------- */
/* JSON Parsing (Minimal)                                                             */
/* ---------------------------------------------------------------------------------- */

json_get_string :: proc(json: string, key: string) -> string {
    needle_buf: [256]u8
    needle := fmt.bprintf(needle_buf[:], "\"%s\":\"", key)

    start_idx := strings.index(json, needle)
    if start_idx < 0 do return ""

    start   := start_idx + len(needle)
    rest    := json[start:]
    end_idx := strings.index(rest, "\"")

    if end_idx < 0 do return ""

    return rest[:end_idx]
}

json_get_number :: proc(json: string, key: string) -> i64 {
    needle_buf: [256]u8
    needle := fmt.bprintf(needle_buf[:], "\"%s\":", key)

    start_idx := strings.index(json, needle)
    if start_idx < 0 do return 0

    start := start_idx + len(needle)
    rest := strings.trim_left_space(json[start:])

    end := 0
    for end < len(rest) {
        c := rest[end]
        if c >= '0' && c <= '9' || c == '-' || c == '+' {
            end += 1
        } else {
            break
        }
    }

    if end == 0 do return 0
    val, ok := strconv.parse_i64(rest[:end])
    return ok ? val : 0
}

json_get_float :: proc(json: string, key: string) -> f64 {
    needle_buf: [256]u8
    needle := fmt.bprintf(needle_buf[:], "\"%s\":", key)

    start_idx := strings.index(json, needle)
    if start_idx < 0 do return 0.0

    start := start_idx + len(needle)
    rest := strings.trim_left_space(json[start:])

    end := 0
    for end < len(rest) {
        c := rest[end]
        if c >= '0' && c <= '9' || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E' {
            end += 1
        } else {
            break
        }
    }

    if end == 0 do return 0.0
    val, ok := strconv.parse_f64(rest[:end])
    return ok ? val : 0.0
}

/* ---------------------------------------------------------------------------------- */
/* Path Abbreviation                                                                  */
/* ---------------------------------------------------------------------------------- */

abbrev_path :: proc(path: string) -> string {
    @(static) result_buf: [256]u8

    home := os.get_env("HOME", context.temp_allocator)
    buf: string

    if len(home) > 0 && strings.has_prefix(path, home) {
        buf = strings.concatenate({"~", path[len(home):]}, context.temp_allocator)
    } else {
        buf = path
    }

    if buf == "~" do return "~"

    slash_count := strings.count(buf, "/")
    if slash_count == 0 {
        copy(result_buf[:], buf)
        return string(result_buf[:len(buf)])
    }

    parts := strings.split(buf, "/", context.temp_allocator)

    result_len := 0
    for part, i in parts {
        if len(part) == 0 do continue

        if result_len > 0 {
            result_buf[result_len] = '/'
            result_len += 1
        }

        if i < len(parts) - 1 && part[0] != '~' {
            result_buf[result_len] = part[0]
            result_len += 1
        } else {
            copy(result_buf[result_len:], part)
            result_len += len(part)
        }
    }

    return string(result_buf[:result_len])
}

/* ---------------------------------------------------------------------------------- */
/* Progress Bar (Compact)                                                             */
/* ---------------------------------------------------------------------------------- */

make_progress_bar :: proc(pct: i64) -> string {
    @(static) bar_buf: [256]u8

    clamped := min(pct, 100)
    width :: 20
    filled := (clamped * width) / 100
    empty := width - filled

    // Color based on usage
    fill_color: string
    if clamped >= 90 {
        fill_color = ANSI_FG_RED
    } else if clamped >= 80 {
        fill_color = ANSI_FG_ORANGE
    } else if clamped >= 50 {
        fill_color = ANSI_FG_YELLOW
    } else {
        fill_color = ANSI_FG_GREEN
    }

    bar := strings.builder_make(context.temp_allocator)

    // Filled portion with color
    strings.write_string(&bar, fill_color)
    for _ in 0 ..< filled do strings.write_string(&bar, "\u2501")  // ━ thick horizontal

    // Empty portion with dots (dimmed)
    strings.write_string(&bar, ANSI_FG_COMMENT)
    for _ in 0 ..< empty do strings.write_string(&bar, "\u2504")   // ┄ dotted line

    // Percentage with matching color (no reset - segment handles it)
    result := fmt.bprintf(bar_buf[:], "%s %s%d%%", strings.to_string(bar), fill_color, clamped)
    return result
}

/* ---------------------------------------------------------------------------------- */
/* Duration Formatting                                                                */
/* ---------------------------------------------------------------------------------- */

format_duration :: proc(ms: i64) -> string {
    @(static) dur_buf: [32]u8

    if ms < 1000 {
        return fmt.bprintf(dur_buf[:], "%dms", ms)
    } else if ms < 60000 {
        return fmt.bprintf(dur_buf[:], "%.1fs", f64(ms) / 1000.0)
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

/* ---------------------------------------------------------------------------------- */
/* Git Status (Fast Path)                                                             */
/* ---------------------------------------------------------------------------------- */

GitStatus :: struct {
    valid:   bool,
    branch:  string,
    stashes: i64,
}

git_read_stash_count :: proc(dir: string) -> i64 {
    stash_path := strings.concatenate({dir, "/.git/logs/refs/stash"}, context.temp_allocator)
    stash_cstr := strings.clone_to_cstring(stash_path, context.temp_allocator)

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

git_read_branch_fast :: proc(dir: string) -> (branch: string, ok: bool) {
    @(static) branch_buf: [128]u8

    head_path := strings.concatenate({dir, "/.git/HEAD"}, context.temp_allocator)
    head_cstr := strings.clone_to_cstring(head_path, context.temp_allocator)

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

/* ---------------------------------------------------------------------------------- */
/* State Cache (prevents flicker during API calls)                                    */
/* ---------------------------------------------------------------------------------- */

CACHE_PATH :: "/dev/shm/statusline-cache"

CachedState :: struct {
    used_pct:     i64,
    total_tokens: i64,
    cost_usd:     f64,
}

read_cached_state :: proc() -> CachedState {
    fd := posix.open(CACHE_PATH, {})
    if fd < 0 do return {}
    defer posix.close(fd)

    state: CachedState
    buf := transmute([^]u8)&state
    n := posix.read(fd, buf, size_of(CachedState))
    if n != size_of(CachedState) do return {}
    return state
}

write_cached_state :: proc(state: CachedState) {
    fd := posix.open(CACHE_PATH, {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR})
    if fd < 0 do return
    defer posix.close(fd)
    s := state  // local copy so we can take address
    buf := transmute([^]u8)&s
    posix.write(fd, buf, size_of(CachedState))
}

/* ---------------------------------------------------------------------------------- */
/* Git Segment Builder                                                                */
/* ---------------------------------------------------------------------------------- */

// Truncate branch name if too long
truncate_branch :: proc(branch: string, max_len: int) -> string {
    @(static) trunc_buf: [64]u8
    if len(branch) <= max_len {
        return branch
    }
    copy(trunc_buf[:], branch[:max_len - 3])
    copy(trunc_buf[max_len - 3:], "...")
    return string(trunc_buf[:max_len])
}

build_git_segment :: proc(buf: ^OutBuf, gs: ^GitStatus) {
    if !gs.valid do return

    text := strings.builder_make(context.temp_allocator)
    strings.write_string(&text, ICON_BRANCH)
    strings.write_string(&text, " ")
    strings.write_string(&text, truncate_branch(gs.branch, 20))

    // Yellow = unknown status (we don't have staged/unstaged info)
    segment(buf, ANSI_BG_YELLOW, ANSI_FG_BLACK, strings.to_string(text), false)

    if gs.stashes > 0 {
        stash_text := strings.builder_make(context.temp_allocator)
        fmt.sbprintf(&stash_text, "%s %d", ICON_STASH, gs.stashes)
        segment(buf, ANSI_BG_DARK, ANSI_FG_WHITE, strings.to_string(stash_text), false)
    }
}

/* ---------------------------------------------------------------------------------- */
/* Main                                                                               */
/* ---------------------------------------------------------------------------------- */

main :: proc() {
    t_start := time.tick_now()

    // Read stdin
    input_buf: [8192]u8
    input_len := 0

    for {
        remaining := len(input_buf) - input_len - 1
        if remaining <= 0 do break
        n := posix.read(0, raw_data(input_buf[input_len:]), uint(remaining))
        if n <= 0 do break
        input_len += int(n)
    }

    input := string(input_buf[:input_len])

    // Parse JSON
    cwd               := json_get_string(input, "current_dir")
    model             := json_get_string(input, "display_name")
    json_cost         := json_get_float( input, "total_cost_usd")
    lines_added       := json_get_number(input, "total_lines_added")
    lines_removed     := json_get_number(input, "total_lines_removed")
    total_duration_ms := json_get_number(input, "total_duration_ms")
    // Token counts
    input_tokens      := json_get_number(input, "input_tokens")
    output_tokens     := json_get_number(input, "output_tokens")
    cache_creation    := json_get_number(input, "cache_creation_input_tokens")
    cache_read        := json_get_number(input, "cache_read_input_tokens")
    json_tokens       := input_tokens + output_tokens + cache_creation + cache_read
    json_pct          := json_get_number(input, "used_percentage")

    // Start with cached values, overlay non-zero JSON values
    // This prevents flicker when Claude sends partial/empty updates during API calls
    cached := read_cached_state()
    used_pct     := json_pct > 0 ? json_pct : cached.used_pct
    total_tokens := json_tokens > 0 ? json_tokens : cached.total_tokens
    cost_usd     := json_cost > 0 ? json_cost : cached.cost_usd

    // Update cache with any new non-zero values
    new_cache := CachedState{
        used_pct     = max(json_pct, cached.used_pct),
        total_tokens = max(json_tokens, cached.total_tokens),
        cost_usd     = max(json_cost, cached.cost_usd),
    }
    if new_cache != cached {
        write_cached_state(new_cache)
    }

    // Vim mode (nested under "vim": {"mode": "..."}) - undocumented feature
    vim_mode := json_get_string(input, "mode")

    // Git status
    gs: GitStatus
    if branch, ok := git_read_branch_fast(cwd); ok {
        gs.valid = true
        gs.branch = branch
        gs.stashes = git_read_stash_count(cwd)
    }

    // Build output
    buf: OutBuf

    // Vim mode (first, as primary state indicator) - undocumented feature
    if len(vim_mode) > 0 {
        vim_bg, vim_fg, vim_icon: string
        is_insert := vim_mode == "INSERT"
        if is_insert {
            vim_bg = ANSI_BG_GREEN
            vim_fg = ANSI_FG_BLACK
            vim_icon = ICON_INSERT
        } else {
            // NORMAL mode (default)
            vim_bg = ANSI_BG_DARK
            vim_fg = ANSI_FG_WHITE
            vim_icon = ICON_NORMAL
        }
        vim_text := strings.builder_make(context.temp_allocator)
        if is_insert {
            fmt.sbprintf(&vim_text, "%s%s %s", ANSI_BOLD, vim_icon, vim_mode)
        } else {
            fmt.sbprintf(&vim_text, "%s %s", vim_icon, vim_mode)
        }
        segment(&buf, vim_bg, vim_fg, strings.to_string(vim_text), true)
    }

    // Model (bold)
    model_text := strings.builder_make(context.temp_allocator)
    strings.write_string(&model_text, ANSI_BOLD)
    strings.write_string(&model_text, model)
    segment(&buf, ANSI_BG_PURPLE, ANSI_FG_BLACK, strings.to_string(model_text), len(vim_mode) == 0)

    // Path
    path_text := strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&path_text, "%s %s", ICON_FOLDER, abbrev_path(cwd))
    segment(&buf, ANSI_BG_DARK, ANSI_FG_WHITE, strings.to_string(path_text), false)

    // Git
    if gs.valid {
        build_git_segment(&buf, &gs)
    }

    // Cost
    cost_bg: string
    if cost_usd >= 10.0 {
        cost_bg = ANSI_BG_RED
    } else if cost_usd >= 5.0 {
        cost_bg = ANSI_BG_ORANGE
    } else if cost_usd >= 1.0 {
        cost_bg = ANSI_BG_CYAN
    } else {
        cost_bg = ANSI_BG_MINT
    }

    cost_text := strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&cost_text, "%s %.2f", ICON_DOLLAR, cost_usd)
    segment(&buf, cost_bg, ANSI_FG_BLACK, strings.to_string(cost_text), false)

    // Lines changed
    if lines_added > 0 || lines_removed > 0 {
        lines_text := strings.builder_make(context.temp_allocator)
        fmt.sbprintf(&lines_text, "%s%s %s+%d %s-%d",
            ANSI_FG_WHITE, ICON_DIFF, ANSI_FG_GREEN, lines_added, ANSI_FG_RED, lines_removed)
        segment(&buf, ANSI_BG_DARK, "", strings.to_string(lines_text), false)
    }

    // Session duration
    if total_duration_ms > 0 {
        dur_text := strings.builder_make(context.temp_allocator)
        fmt.sbprintf(&dur_text, "%s %s", ICON_CLOCK, format_duration(total_duration_ms))
        segment(&buf, ANSI_BG_DARK, ANSI_FG_WHITE, strings.to_string(dur_text), false)
    }

    // Token count
    if total_tokens > 0 {
        tok_text := strings.builder_make(context.temp_allocator)
        total_k := f64(total_tokens) / 1000.0
        fmt.sbprintf(&tok_text, "%s %.0fk", ICON_TOKENS, total_k)
        segment(&buf, ANSI_BG_COMMENT, ANSI_FG_WHITE, strings.to_string(tok_text), false)
    }

    // Progress bar (cached value prevents flicker during API calls)
    bar := make_progress_bar(used_pct)
    segment(&buf, ANSI_BG_DARK, "", bar, false)

    segment_end(&buf)

    // Timing suffix (after segments, with spacing)
    t_now := time.tick_now()
    total_us := i64(time.duration_microseconds(time.tick_diff(t_start, t_now)))
    timing_buf: [64]u8
    timing_str := fmt.bprintf(timing_buf[:], "  %s%dus%s", ANSI_FG_COMMENT, total_us, ANSI_RESET)
    out_str(&buf, timing_str)

    // Output
    posix.write(1, raw_data(&buf.data), uint(buf.len))
}
