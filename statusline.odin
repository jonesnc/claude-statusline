// Claude Code Statusline - Odin Version (v4)
//
// A fast statusline for Claude Code written in Odin.
// Port of the C version with enhanced visuals.
//
// Build: odin build . -o:speed -out:statusline_odin
// Usage: Set in ~/.claude/settings.json statusLine.command
//
// Shared state files:
//   /dev/shm/statusline-cache.<gppid>   - Per-session cached state (cost, tokens, pct, cwd,
//                                         model, lines, duration) to prevent flicker during
//                                         API calls and serve as fallback on stdin timeout
//   /dev/shm/statusline-cleanup         - Sentinel file; mtime tracks last cleanup run
//                                         (cleanup runs every 5 minutes)
//   /dev/shm/claude-git-<hash>          - Per-repo git status cache (modified/staged counts)
//                                         keyed by FNV-1a hash of repo path, mtime-invalidated
//   /tmp/statusline-<uid>/<pid>.log     - Per-user, per-session debug timing logs
//                                         (only when STATUSLINE_DEBUG=1)

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
SEP_ARROW   :: "\uE0B0"  //
SEP_ROUND   :: "\uE0B4"  //
SEP_FLAME   :: "\uE0C0"  //

// Nerd Font icons
ICON_BRANCH    :: "\uF126"   //  git branch
ICON_FOLDER    :: "\uF07C"   //  folder open
ICON_DOLLAR    :: "\uF155"   //  dollar
ICON_TAG       :: "\uF02B"   //  tag
ICON_CLOCK     :: "\uF017"   //  clock
ICON_DIFF      :: "\uF440"   //  diff
ICON_STASH     :: "\uF01C"   //  inbox/stash
ICON_TOKENS    :: "\uF2DB"   //  microchip
ICON_INSERT    :: "\uF040"   //  pencil (insert mode)
ICON_NORMAL    :: "\uE7C5"   //  vim logo (normal mode)
ICON_STAGED    :: "\uF00C"   //  checkmark (staged)
ICON_MODIFIED  :: "\uF040"   //  pencil (modified)
ICON_AGENT     :: "\uF544"   //  robot (agent)
ICON_WARN      :: "\uF071"   //  warning triangle

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
    needle := fmt.bprintf(needle_buf[:], "\"%s\":", key)

    start_idx := strings.index(json, needle)
    if start_idx < 0 do return ""

    // Skip past key and colon, then whitespace
    rest := strings.trim_left_space(json[start_idx + len(needle):])

    // Expect opening quote
    if len(rest) == 0 || rest[0] != '"' do return ""
    rest = rest[1:]

    // Find closing quote
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

make_context_bar :: proc(pct: i64, ctx_size: i64) -> string {
    @(static) bar_buf: [512]u8

    clamped := min(pct, 100)
    width :: 15
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

    // Used tokens label
    used_tokens := pct * ctx_size / 100
    used_k := f64(used_tokens) / 1000.0
    fmt.sbprintf(&bar, "%s%.0fk ", fill_color, used_k)

    // Left cap + filled portion
    strings.write_string(&bar, "\u257A")  // ╺ left half-line cap
    for _ in 0 ..< filled do strings.write_string(&bar, "\u2501")  // ━

    // Percentage at the boundary
    fmt.sbprintf(&bar, " %d%% ", clamped)

    // Empty portion + right cap
    strings.write_string(&bar, ANSI_FG_COMMENT)
    for _ in 0 ..< empty do strings.write_string(&bar, "\u2504")   // ┄
    strings.write_string(&bar, "\u2578")  // ╸ right half-line cap

    // Total context label
    strings.write_string(&bar, fill_color)
    if ctx_size >= 1_000_000 {
        fmt.sbprintf(&bar, " %dM", ctx_size / 1_000_000)
    } else {
        fmt.sbprintf(&bar, " %dk", ctx_size / 1000)
    }

    result := fmt.bprintf(bar_buf[:], "%s", strings.to_string(bar))
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

// Cache path includes grandparent PID (Claude's PID) to isolate multiple instances
CACHE_PATH_PREFIX :: "/dev/shm/statusline-cache."

CachedState :: struct #packed {
    used_pct:       i64,
    context_size:   i64,
    cost_usd:       f64,
    lines_added:    i64,
    lines_removed:  i64,
    duration_ms:    i64,
    cwd:            [256]u8,
    model:          [64]u8,
}

// Get grandparent PID (Claude's PID) by reading /proc/<ppid>/status
get_grandparent_pid :: proc() -> int {
    ppid := int(posix.getppid())

    // Read /proc/<ppid>/status to find grandparent
    path_buf: [32]u8
    path := fmt.bprintf(path_buf[:], "/proc/%d/status", ppid)
    path_cstr := strings.clone_to_cstring(path, context.temp_allocator)

    fd := posix.open(path_cstr, {})
    if fd < 0 do return ppid  // fallback to parent
    defer posix.close(fd)

    buf: [1024]u8
    n := posix.read(fd, raw_data(&buf), len(buf))
    if n <= 0 do return ppid

    content := string(buf[:n])
    // Find "PPid:\t<number>"
    ppid_prefix :: "PPid:\t"
    idx := strings.index(content, ppid_prefix)
    if idx < 0 do return ppid

    start := idx + len(ppid_prefix)
    rest := content[start:]
    end := strings.index(rest, "\n")
    if end < 0 do end = len(rest)

    gppid, ok := strconv.parse_int(strings.trim_space(rest[:end]))
    return ok ? gppid : ppid
}

get_cache_path :: proc() -> string {
    @(static) path_buf: [64]u8
    gppid := get_grandparent_pid()
    return fmt.bprintf(path_buf[:], "%s%d", CACHE_PATH_PREFIX, gppid)
}

read_cached_state :: proc() -> CachedState {
    cache_path := get_cache_path()
    cache_cstr := strings.clone_to_cstring(cache_path, context.temp_allocator)
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
    cache_cstr := strings.clone_to_cstring(cache_path, context.temp_allocator)
    fd := posix.open(cache_cstr, {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR})
    if fd < 0 do return
    defer posix.close(fd)
    s := state  // local copy so we can take address
    buf := transmute([^]u8)&s
    posix.write(fd, buf, size_of(CachedState))
}

CLEANUP_INTERVAL_S :: 300  // 5 minutes

// Clean up orphaned cache files from dead Claude processes
cleanup_stale_caches :: proc() {
    // Check if cleanup is due (sentinel file mtime)
    sentinel_cstr: cstring = "/dev/shm/statusline-cleanup"
    st: posix.stat_t
    now_ms := current_time_ms()
    if posix.stat(sentinel_cstr, &st) == .OK {
        last_s := i64(st.st_mtim.tv_sec)
        if now_ms / 1000 - last_s < CLEANUP_INTERVAL_S do return
    }
    // Touch sentinel
    sentinel_fd := posix.open(sentinel_cstr, {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR, .IRGRP, .IWGRP, .IROTH, .IWOTH})
    if sentinel_fd >= 0 do posix.close(sentinel_fd)

    PREFIX :: "statusline-cache."
    SHM_DIR :: "/dev/shm"

    dir := posix.opendir(SHM_DIR)
    if dir == nil do return
    defer posix.closedir(dir)

    for {
        entry := posix.readdir(dir)
        if entry == nil do break

        name := string(cstring(&entry.d_name[0]))
        if !strings.has_prefix(name, PREFIX) do continue

        // Extract PID from filename
        pid_str := name[len(PREFIX):]
        pid, ok := strconv.parse_int(pid_str)
        if !ok || pid <= 0 do continue

        // Check if process is still alive (kill with signal 0 just checks, doesn't kill)
        if posix.kill(posix.pid_t(pid), .NONE) == .OK do continue

        // Process is dead, remove the cache file
        path_buf: [64]u8
        path := fmt.bprintf(path_buf[:], "%s/%s", SHM_DIR, name)
        path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
        posix.unlink(path_cstr)
    }

    // Clean up stale debug logs in per-user subdir
    uid := posix.getuid()
    log_dir_buf: [64]u8
    log_dir := fmt.bprintf(log_dir_buf[:], "/tmp/statusline-%d", uid)
    log_dir_cstr := strings.clone_to_cstring(log_dir, context.temp_allocator)

    tmp_dir := posix.opendir(log_dir_cstr)
    if tmp_dir == nil do return
    defer posix.closedir(tmp_dir)

    for {
        entry := posix.readdir(tmp_dir)
        if entry == nil do break

        name := string(cstring(&entry.d_name[0]))
        if !strings.has_suffix(name, ".log") do continue

        // Filename is just <pid>.log
        pid_str := strings.trim_suffix(name, ".log")
        log_pid, ok := strconv.parse_int(pid_str)
        if !ok || log_pid <= 0 do continue

        if posix.kill(posix.pid_t(log_pid), .NONE) == .OK do continue

        tmp_path_buf: [96]u8
        tmp_path := fmt.bprintf(tmp_path_buf[:], "%s/%s", log_dir, name)
        tmp_path_cstr := strings.clone_to_cstring(tmp_path, context.temp_allocator)
        posix.unlink(tmp_path_cstr)
    }
}

/* ---------------------------------------------------------------------------------- */
/* Git Status Cache (shared across Claude instances via shm)                          */
/* ---------------------------------------------------------------------------------- */

GitCache :: struct #packed {
    index_mtime_sec:  i64,  // .git/index mtime seconds
    index_mtime_nsec: i64,  // .git/index mtime nanoseconds
    modified:         u32,  // Unstaged modified files
    staged:           u32,  // Staged files
    ahead:            u32,  // Commits ahead of remote
    behind:           u32,  // Commits behind remote
    branch:           [64]u8,   // Branch name
    repo_path:        [256]u8,  // Repo path (for validation)
}

// Simple hash of repo path to create shm name
hash_path :: proc(path: string) -> u32 {
    // FNV-1a hash
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
    return fmt.bprintf(path_buf[:], "/dev/shm/claude-git-%08x", h)
}

current_time_ms :: proc() -> i64 {
    ts: posix.timespec
    posix.clock_gettime(.REALTIME, &ts)
    return i64(ts.tv_sec) * 1000 + i64(ts.tv_nsec) / 1_000_000
}

GIT_CACHE_TTL_MS :: 5000  // Working tree changes don't touch .git/index; TTL catches them

CacheState :: enum { NONE, STALE, VALID }

read_git_cache :: proc(repo_path: string) -> (cache: GitCache, state: CacheState) {
    cache_path := get_git_cache_path(repo_path)
    cache_cstr := strings.clone_to_cstring(cache_path, context.temp_allocator)

    fd := posix.open(cache_cstr, {})
    if fd < 0 do return {}, .NONE
    defer posix.close(fd)

    buf := transmute([^]u8)&cache
    n := posix.read(fd, buf, size_of(GitCache))
    if n != size_of(GitCache) do return {}, .NONE

    // Validate repo path matches
    cached_repo := string(cstring(&cache.repo_path[0]))
    if cached_repo != repo_path do return {}, .NONE

    // TTL: stat the cache file itself — its mtime is when we last wrote it
    cache_st: posix.stat_t
    if posix.fstat(fd, &cache_st) != .OK do return cache, .STALE
    cache_age_ms := current_time_ms() - (i64(cache_st.st_mtim.tv_sec) * 1000 + i64(cache_st.st_mtim.tv_nsec) / 1_000_000)
    if cache_age_ms > GIT_CACHE_TTL_MS do return cache, .STALE

    // .git/index mtime: catches git add/commit/stash immediately (within TTL window)
    index_path := strings.concatenate({repo_path, "/.git/index"}, context.temp_allocator)
    index_cstr := strings.clone_to_cstring(index_path, context.temp_allocator)
    st: posix.stat_t
    if posix.stat(index_cstr, &st) != .OK do return cache, .STALE

    if i64(st.st_mtim.tv_sec) == cache.index_mtime_sec &&
       i64(st.st_mtim.tv_nsec) == cache.index_mtime_nsec {
        return cache, .VALID
    }

    return cache, .STALE
}

write_git_cache :: proc(repo_path: string, modified: u32, staged: u32, ahead: u32, behind: u32) {
    // Stat .git/index to capture current mtime
    index_path := strings.concatenate({repo_path, "/.git/index"}, context.temp_allocator)
    index_cstr := strings.clone_to_cstring(index_path, context.temp_allocator)
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
    cache_cstr := strings.clone_to_cstring(cache_path, context.temp_allocator)

    fd := posix.open(cache_cstr, {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
    if fd < 0 do return
    defer posix.close(fd)

    buf := transmute([^]u8)&cache
    posix.write(fd, buf, size_of(GitCache))
}

// Run git status --porcelain -b -uno via fork/exec (skips shell)
run_git_status :: proc(repo_path: string) -> (modified: u32, staged: u32, ahead: u32, behind: u32) {
    pipe_fds: [2]posix.FD
    if posix.pipe(&pipe_fds) != .OK do return 0, 0, 0, 0
    pipe_read  := pipe_fds[0]
    pipe_write := pipe_fds[1]

    pid := posix.fork()
    if pid < 0 {
        posix.close(pipe_read)
        posix.close(pipe_write)
        return 0, 0, 0, 0
    }

    if pid == 0 {
        // Child: chdir, redirect stdout, exec git
        posix.close(pipe_read)
        repo_cstr := strings.clone_to_cstring(repo_path, context.temp_allocator)
        posix.chdir(repo_cstr)
        posix.dup2(pipe_write, 1)  // stdout
        dev_null := posix.open("/dev/null", {.WRONLY})
        if dev_null >= 0 do posix.dup2(dev_null, 2)  // stderr -> /dev/null
        posix.close(pipe_write)

        argv := []cstring{"git", "status", "--porcelain", "-b", "-uno", nil}
        posix.execvp("git", raw_data(argv))
        posix._exit(127)
    }

    // Parent: read output, parse, waitpid
    posix.close(pipe_write)

    buf: [4096]u8
    total_read := 0
    for {
        remaining := len(buf) - total_read
        if remaining <= 0 do break
        n := posix.read(pipe_read, raw_data(buf[total_read:]), uint(remaining))
        if n <= 0 do break
        total_read += int(n)
    }
    posix.close(pipe_read)
    posix.waitpid(pid, nil, {})

    // Parse porcelain output line by line
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

        // ## branch...remote [ahead N, behind M]
        if line[0] == '#' && line[1] == '#' {
            if idx := strings.index(line, "["); idx >= 0 {
                bracket := line[idx:]
                if a := strings.index(bracket, "ahead "); a >= 0 {
                    num_start := a + 6
                    num_end := num_start
                    for num_end < len(bracket) && bracket[num_end] >= '0' && bracket[num_end] <= '9' {
                        num_end += 1
                    }
                    if v, ok := strconv.parse_int(bracket[num_start:num_end]); ok {
                        ahead = u32(v)
                    }
                }
                if b := strings.index(bracket, "behind "); b >= 0 {
                    num_start := b + 7
                    num_end := num_start
                    for num_end < len(bracket) && bracket[num_end] >= '0' && bracket[num_end] <= '9' {
                        num_end += 1
                    }
                    if v, ok := strconv.parse_int(bracket[num_start:num_end]); ok {
                        behind = u32(v)
                    }
                }
            }
            continue
        }

        // X = staged, Y = unstaged (no untracked with -uno)
        if line[0] != ' ' && line[0] != '?' {
            staged += 1
        }
        if line[1] != ' ' && line[1] != '?' {
            modified += 1
        }
    }

    return modified, staged, ahead, behind
}

// Get git status with caching and background refresh
get_git_status_cached :: proc(repo_path: string) -> (modified: u32, staged: u32, ahead: u32, behind: u32, state: CacheState) {
    cache, cache_state := read_git_cache(repo_path)

    switch cache_state {
    case .VALID:
        return cache.modified, cache.staged, cache.ahead, cache.behind, .VALID
    case .STALE:
        // Return stale data immediately, double-fork to refresh in background
        bg_pid := posix.fork()
        if bg_pid == 0 {
            // First child: fork again so grandchild is orphaned (no zombie)
            if posix.fork() == 0 {
                // Grandchild: refresh cache and exit
                m, s, a, b := run_git_status(repo_path)
                write_git_cache(repo_path, m, s, a, b)
            }
            posix._exit(0)
        }
        if bg_pid > 0 {
            posix.waitpid(bg_pid, nil, {})  // Reap first child immediately
        }
        return cache.modified, cache.staged, cache.ahead, cache.behind, .STALE
    case .NONE:
        // First-ever miss: block and run
        modified, staged, ahead, behind = run_git_status(repo_path)
        write_git_cache(repo_path, modified, staged, ahead, behind)
        return modified, staged, ahead, behind, .NONE
    }

    return 0, 0, 0, 0, .NONE
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

    // Color based on status: green=clean, orange=dirty
    bg: string
    if gs.modified > 0 || gs.staged > 0 {
        bg = ANSI_BG_ORANGE
    } else {
        bg = ANSI_BG_GREEN
    }
    segment(buf, bg, ANSI_FG_BLACK, strings.to_string(text), false)

    // Show counts if any changes or ahead/behind
    if gs.staged > 0 || gs.modified > 0 || gs.stashes > 0 || gs.ahead > 0 || gs.behind > 0 {
        status_text := strings.builder_make(context.temp_allocator)
        if gs.ahead > 0 {
            fmt.sbprintf(&status_text, "%s\u2191%d ", ANSI_FG_GREEN, gs.ahead)  // ↑
        }
        if gs.behind > 0 {
            fmt.sbprintf(&status_text, "%s\u2193%d ", ANSI_FG_RED, gs.behind)  // ↓
        }
        if gs.staged > 0 {
            fmt.sbprintf(&status_text, "%s%s%d ", ANSI_FG_GREEN, ICON_STAGED, gs.staged)
        }
        if gs.modified > 0 {
            fmt.sbprintf(&status_text, "%s%s%d ", ANSI_FG_ORANGE, ICON_MODIFIED, gs.modified)
        }
        if gs.stashes > 0 {
            fmt.sbprintf(&status_text, "%s%s%d", ANSI_FG_PURPLE, ICON_STASH, gs.stashes)
        }
        status_str := strings.trim_right_space(strings.to_string(status_text))
        segment(buf, ANSI_BG_DARK, "", status_str, false)
    }
}


/* ---------------------------------------------------------------------------------- */
/* Display State                                                                      */
/* ---------------------------------------------------------------------------------- */

DisplayState :: struct {
    cwd:               string,
    model:             string,
    cost_usd:          f64,
    lines_added:       i64,
    lines_removed:     i64,
    total_duration_ms: i64,
    used_pct:          i64,
    ctx_size:          i64,
    vim_mode:          string,
    agent_name:        string,
}

DebugTimings :: struct {
    t_start, t_cleanup, t_read, t_parse, t_git, t_build: time.Tick,
}

/* ---------------------------------------------------------------------------------- */
/* Stdin Reader                                                                       */
/* ---------------------------------------------------------------------------------- */

STDIN_TIMEOUT_MS :: 50

read_stdin :: proc() -> (string, bool) {
    @(static) input_buf: [8192]u8
    input_len := 0

    pfds := [1]posix.pollfd{{fd = 0, events = {.IN}}}
    if posix.poll(raw_data(&pfds), 1, STDIN_TIMEOUT_MS) > 0 {
        for {
            remaining := len(input_buf) - input_len - 1
            if remaining <= 0 do break
            n := posix.read(0, raw_data(input_buf[input_len:]), uint(remaining))
            if n <= 0 do break
            input_len += int(n)
        }
        return string(input_buf[:input_len]), false
    }
    return "", true
}

/* ---------------------------------------------------------------------------------- */
/* State Resolution (JSON + Cache Merge)                                              */
/* ---------------------------------------------------------------------------------- */

resolve_state :: proc(input: string, stdin_timeout: bool) -> DisplayState {
    @(static) cached: CachedState
    cached = read_cached_state()
    state: DisplayState

    if !stdin_timeout {
        json_cwd           := json_get_string(input, "current_dir")
        json_model         := json_get_string(input, "display_name")
        json_cost          := json_get_float (input, "total_cost_usd")
        json_lines_added   := json_get_number(input, "total_lines_added")
        json_lines_removed := json_get_number(input, "total_lines_removed")
        json_duration      := json_get_number(input, "total_duration_ms")
        json_pct           := json_get_number(input, "used_percentage")
        json_ctx_size      := json_get_number(input, "context_window_size")
        state.vim_mode      = json_get_string(input, "mode")
        state.agent_name    = json_get_string(input, "name")

        // Overlay non-zero JSON with cache (prevents flicker during API calls)
        state.cwd               = len(json_cwd) > 0 ? json_cwd : string(cstring(&cached.cwd[0]))
        state.model             = len(json_model) > 0 ? json_model : string(cstring(&cached.model[0]))
        state.cost_usd          = json_cost > 0 ? json_cost : cached.cost_usd
        state.lines_added       = json_lines_added > 0 ? json_lines_added : cached.lines_added
        state.lines_removed     = json_lines_removed > 0 ? json_lines_removed : cached.lines_removed
        state.total_duration_ms = json_duration > 0 ? json_duration : cached.duration_ms
        state.used_pct          = json_pct > 0 ? json_pct : cached.used_pct
        state.ctx_size          = json_ctx_size > 0 ? json_ctx_size : cached.context_size

        // Update full-snapshot cache
        new_cache: CachedState
        new_cache.used_pct      = max(json_pct, cached.used_pct)
        new_cache.context_size  = max(json_ctx_size, cached.context_size)
        new_cache.cost_usd      = max(json_cost, cached.cost_usd)
        new_cache.lines_added   = max(json_lines_added, cached.lines_added)
        new_cache.lines_removed = max(json_lines_removed, cached.lines_removed)
        new_cache.duration_ms   = max(json_duration, cached.duration_ms)
        if len(json_cwd) > 0 {
            copy(new_cache.cwd[:len(new_cache.cwd)-1], json_cwd)
        } else {
            new_cache.cwd = cached.cwd
        }
        if len(json_model) > 0 {
            copy(new_cache.model[:len(new_cache.model)-1], json_model)
        } else {
            new_cache.model = cached.model
        }
        if new_cache != cached {
            write_cached_state(new_cache)
        }
    } else {
        // Stdin timeout: render entirely from cached snapshot
        state.cwd               = string(cstring(&cached.cwd[0]))
        state.model             = string(cstring(&cached.model[0]))
        state.cost_usd          = cached.cost_usd
        state.lines_added       = cached.lines_added
        state.lines_removed     = cached.lines_removed
        state.total_duration_ms = cached.duration_ms
        state.used_pct          = cached.used_pct
        state.ctx_size          = cached.context_size
    }

    return state
}

/* ---------------------------------------------------------------------------------- */
/* Statusline Builder                                                                 */
/* ---------------------------------------------------------------------------------- */

build_statusline :: proc(buf: ^OutBuf, state: ^DisplayState, gs: ^GitStatus) {
    first := true

    // Vim mode (first, as primary state indicator)
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
        vim_text := strings.builder_make(context.temp_allocator)
        if is_insert {
            fmt.sbprintf(&vim_text, "%s%s %s", ANSI_BOLD, vim_icon, state.vim_mode)
        } else {
            fmt.sbprintf(&vim_text, "%s %s", vim_icon, state.vim_mode)
        }
        segment(buf, vim_bg, vim_fg, strings.to_string(vim_text), first)
        first = false
    }

    // Model (bold)
    model_text := strings.builder_make(context.temp_allocator)
    strings.write_string(&model_text, ANSI_BOLD)
    strings.write_string(&model_text, state.model)
    segment(buf, ANSI_BG_PURPLE, ANSI_FG_BLACK, strings.to_string(model_text), first)
    first = false

    // Agent name (only when using --agent)
    if len(state.agent_name) > 0 {
        agent_text := strings.builder_make(context.temp_allocator)
        fmt.sbprintf(&agent_text, "%s %s", ICON_AGENT, state.agent_name)
        segment(buf, ANSI_BG_CYAN, ANSI_FG_BLACK, strings.to_string(agent_text), false)
    }

    // Path
    path_text := strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&path_text, "%s %s", ICON_FOLDER, abbrev_path(state.cwd))
    segment(buf, ANSI_BG_DARK, ANSI_FG_WHITE, strings.to_string(path_text), false)

    // Git
    if gs.valid {
        build_git_segment(buf, gs)
    }

    // Cost
    cost_bg: string
    if state.cost_usd >= 10.0 {
        cost_bg = ANSI_BG_RED
    } else if state.cost_usd >= 5.0 {
        cost_bg = ANSI_BG_ORANGE
    } else if state.cost_usd >= 1.0 {
        cost_bg = ANSI_BG_CYAN
    } else {
        cost_bg = ANSI_BG_MINT
    }
    cost_text := strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&cost_text, "%s %.2f", ICON_DOLLAR, state.cost_usd)
    segment(buf, cost_bg, ANSI_FG_BLACK, strings.to_string(cost_text), false)

    // Lines changed
    if state.lines_added > 0 || state.lines_removed > 0 {
        lines_text := strings.builder_make(context.temp_allocator)
        fmt.sbprintf(&lines_text, "%s%s %s+%d %s-%d",
            ANSI_FG_WHITE, ICON_DIFF,
            ANSI_FG_GREEN, state.lines_added,
            ANSI_FG_RED, state.lines_removed)
        segment(buf, ANSI_BG_DARK, "", strings.to_string(lines_text), false)
    }

    // Session duration
    if state.total_duration_ms > 0 {
        dur_text := strings.builder_make(context.temp_allocator)
        fmt.sbprintf(&dur_text, "%s %s", ICON_CLOCK, format_duration(state.total_duration_ms))
        segment(buf, ANSI_BG_DARK, ANSI_FG_WHITE, strings.to_string(dur_text), false)
    }

    // Context window: used ━━━ pct% ┄┄┄ total
    bar := make_context_bar(state.used_pct, state.ctx_size)
    segment(buf, ANSI_BG_DARK, "", bar, false)

    // Context limit warnings
    if state.used_pct >= 80 {
        warn_text := strings.builder_make(context.temp_allocator)
        warn_bg: string
        if state.used_pct >= 95 {
            fmt.sbprintf(&warn_text, "%s%s CRITICAL COMPACT", ANSI_BOLD, ICON_WARN)
            warn_bg = ANSI_BG_RED
        } else if state.used_pct >= 90 {
            fmt.sbprintf(&warn_text, "%s%s LOW CTX COMPACT", ANSI_BOLD, ICON_WARN)
            warn_bg = ANSI_BG_RED
        } else {
            fmt.sbprintf(&warn_text, "%s CTX 80%%+", ICON_WARN)
            warn_bg = ANSI_BG_YELLOW
        }
        segment(buf, warn_bg, ANSI_FG_BLACK, strings.to_string(warn_text), false)
    }

    segment_end(buf)
}

/* ---------------------------------------------------------------------------------- */
/* Debug Logging                                                                      */
/* ---------------------------------------------------------------------------------- */

write_debug_log :: proc(timings: ^DebugTimings, gs: ^GitStatus, stdin_timeout: bool) {
    t_end := time.tick_now()
    gppid := get_grandparent_pid()
    cache_str: string
    switch gs.cache_state {
    case .VALID: cache_str = "valid"
    case .STALE: cache_str = "stale"
    case .NONE:  cache_str = "miss"
    }
    stdin_str := stdin_timeout ? "timeout" : "ok"
    debug_buf: [512]u8
    debug_str := fmt.bprintf(debug_buf[:],
        "cleanup=%dus read=%dus(%s) parse=%dus git=%dus(%s) build=%dus total=%dus\n",
        i64(time.duration_microseconds(time.tick_diff(timings.t_start, timings.t_cleanup))),
        i64(time.duration_microseconds(time.tick_diff(timings.t_cleanup, timings.t_read))),
        stdin_str,
        i64(time.duration_microseconds(time.tick_diff(timings.t_read, timings.t_parse))),
        i64(time.duration_microseconds(time.tick_diff(timings.t_parse, timings.t_git))),
        cache_str,
        i64(time.duration_microseconds(time.tick_diff(timings.t_git, timings.t_build))),
        i64(time.duration_microseconds(time.tick_diff(timings.t_start, t_end))))

    uid := posix.getuid()
    dir_buf: [64]u8
    dir_path := fmt.bprintf(dir_buf[:], "/tmp/statusline-%d", uid)
    dir_cstr := strings.clone_to_cstring(dir_path, context.temp_allocator)
    posix.mkdir(dir_cstr, {.IRUSR, .IWUSR, .IXUSR})

    log_path_buf: [96]u8
    log_path := fmt.bprintf(log_path_buf[:], "%s/%d.log", dir_path, gppid)
    log_cstr := strings.clone_to_cstring(log_path, context.temp_allocator)
    log_fd := posix.open(log_cstr, {.WRONLY, .CREAT, .APPEND}, {.IRUSR, .IWUSR})
    if log_fd >= 0 {
        posix.write(log_fd, raw_data(debug_buf[:]), uint(len(debug_str)))
        posix.close(log_fd)
    }
}

/* ---------------------------------------------------------------------------------- */
/* Main                                                                               */
/* ---------------------------------------------------------------------------------- */

main :: proc() {
    timings: DebugTimings
    timings.t_start = time.tick_now()
    debug := os.get_env("STATUSLINE_DEBUG", context.temp_allocator) != ""

    cleanup_stale_caches()
    if debug do timings.t_cleanup = time.tick_now()

    input, stdin_timeout := read_stdin()
    if debug do timings.t_read = time.tick_now()

    state := resolve_state(input, stdin_timeout)
    if debug do timings.t_parse = time.tick_now()

    // Git status
    gs: GitStatus
    if branch, ok := git_read_branch_fast(state.cwd); ok {
        gs.valid = true
        gs.branch = branch
        gs.stashes = git_read_stash_count(state.cwd)
        gs.modified, gs.staged, gs.ahead, gs.behind, gs.cache_state = get_git_status_cached(state.cwd)
    }
    if debug do timings.t_git = time.tick_now()

    // Build and output
    buf: OutBuf
    build_statusline(&buf, &state, &gs)
    if debug do timings.t_build = time.tick_now()

    // Timing suffix
    t_now := time.tick_now()
    total_us := i64(time.duration_microseconds(time.tick_diff(timings.t_start, t_now)))
    timing_buf: [64]u8
    timing_str: string
    if total_us >= 1000 {
        timing_str = fmt.bprintf(timing_buf[:], "  %s%.1fms%s", ANSI_FG_COMMENT, f64(total_us) / 1000.0, ANSI_RESET)
    } else {
        timing_str = fmt.bprintf(timing_buf[:], "  %s%dus%s", ANSI_FG_COMMENT, total_us, ANSI_RESET)
    }
    out_str(&buf, timing_str)

    posix.write(1, raw_data(&buf.data), uint(buf.len))

    if debug {
        write_debug_log(&timings, &gs, stdin_timeout)
    }
}
