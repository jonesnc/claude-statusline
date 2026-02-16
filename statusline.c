// Claude Code Statusline - C Version
//
// Full port of the Odin statusline with all features:
//   - State cache in /dev/shm for flicker prevention
//   - Git cache with mtime invalidation + background refresh (double-fork)
//   - fork/exec git directly (no shell, no daemon)
//   - Stdin poll with 50ms timeout
//   - Vim mode, context bar, duration, context warnings
//
// Build: cc -O3 -march=native -o statusline statusline.c
// Usage: Set in ~/.claude/settings.json statusLine.command
//
// Shared state files:
//   /dev/shm/statusline-cache.<gppid>   - Per-session cached state
//   /dev/shm/statusline-cleanup         - Sentinel for cleanup interval
//   /dev/shm/claude-git-<hash>          - Per-repo git status cache
//   /tmp/statusline-<uid>/<pid>.log     - Debug timing logs

#define _GNU_SOURCE
#include <dirent.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

//~ Base Types

typedef uint8_t   U8;
typedef uint32_t  U32;
typedef int64_t   S64;
typedef uint64_t  U64;
typedef int       B32;

#define internal static
#define true     1
#define false    0

#define Min(a, b)   ((a) < (b) ? (a) : (b))
#define Max(a, b)   ((a) > (b) ? (a) : (b))

//~ Timing

internal U64
time_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (U64)ts.tv_sec * 1000000 + (U64)ts.tv_nsec / 1000;
}

internal S64
time_ms_realtime(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (S64)ts.tv_sec * 1000 + (S64)ts.tv_nsec / 1000000;
}

//~ ANSI Colors (Dracula Theme)

#define ANSI_RESET      "\x1b[0m"
#define ANSI_BOLD       "\x1b[1m"

#define ANSI_BG_PURPLE  "\x1b[48;2;189;147;249m"
#define ANSI_BG_ORANGE  "\x1b[48;2;255;184;108m"
#define ANSI_BG_DARK    "\x1b[48;2;68;71;90m"
#define ANSI_BG_GREEN   "\x1b[48;2;72;209;104m"
#define ANSI_BG_MINT    "\x1b[48;2;40;167;69m"
#define ANSI_BG_COMMENT "\x1b[48;2;98;114;164m"
#define ANSI_BG_RED     "\x1b[48;2;255;85;85m"
#define ANSI_BG_YELLOW  "\x1b[48;2;241;250;140m"
#define ANSI_BG_CYAN    "\x1b[48;2;139;233;253m"

#define ANSI_FG_BLACK   "\x1b[38;2;40;42;54m"
#define ANSI_FG_WHITE   "\x1b[38;2;248;248;242m"
#define ANSI_FG_PURPLE  "\x1b[38;2;189;147;249m"
#define ANSI_FG_DARK    "\x1b[38;2;68;71;90m"
#define ANSI_FG_GREEN   "\x1b[38;2;80;250;123m"
#define ANSI_FG_COMMENT "\x1b[38;2;98;114;164m"
#define ANSI_FG_YELLOW  "\x1b[38;2;241;250;140m"
#define ANSI_FG_ORANGE  "\x1b[38;2;255;184;108m"
#define ANSI_FG_RED     "\x1b[38;2;255;85;85m"
#define ANSI_FG_CYAN    "\x1b[38;2;139;233;253m"
#define ANSI_FG_PINK    "\x1b[38;2;255;121;198m"

// Powerline separators (UTF-8 encoded)
#define SEP_ROUND   "\xee\x82\xb4"  // U+E0B4

// Nerd Font icons (UTF-8 encoded)
#define ICON_BRANCH   "\xef\x84\xa6"  // U+F126
#define ICON_FOLDER   "\xef\x81\xbc"  // U+F07C
#define ICON_DOLLAR   "\xef\x85\x95"  // U+F155
#define ICON_CLOCK    "\xef\x80\x97"  // U+F017
#define ICON_DIFF     "\xef\x91\x80"  // U+F440
#define ICON_STASH    "\xef\x80\x9c"  // U+F01C
#define ICON_INSERT   "\xef\x81\x80"  // U+F040 (pencil)
#define ICON_NORMAL   "\xee\x9f\x85"  // U+E7C5 (vim logo)
#define ICON_STAGED   "\xef\x80\x8c"  // U+F00C (checkmark)
#define ICON_MODIFIED "\xef\x81\x80"  // U+F040 (pencil)
#define ICON_WARN     "\xef\x81\xb1"  // U+F071 (warning triangle)

// UTF-8 box drawing
#define UTF8_LCAP   "\xe2\x95\xba"  // ╺
#define UTF8_RCAP   "\xe2\x95\xb8"  // ╸
#define UTF8_FILL   "\xe2\x94\x81"  // ━
#define UTF8_EMPTY  "\xe2\x94\x84"  // ┄
#define UTF8_UP     "\xe2\x86\x91"  // ↑
#define UTF8_DOWN   "\xe2\x86\x93"  // ↓

//~ Output Buffer

typedef struct OutBuf OutBuf;
struct OutBuf
{
    char data[4096];
    U64  len;
    const char *prev_bg;
    U64  prev_bg_len;
};

internal void
out_strn(OutBuf *buf, const char *s, U64 slen)
{
    if(buf->len + slen < sizeof(buf->data))
    {
        memcpy(buf->data + buf->len, s, slen);
        buf->len += slen;
    }
}

// For compile-time-known string literals: avoids strlen
#define out_lit(buf, s) out_strn(buf, s, sizeof(s) - 1)

internal void
out_char(OutBuf *buf, char c)
{
    if(buf->len + 1 < sizeof(buf->data))
    {
        buf->data[buf->len] = c;
        buf->len += 1;
    }
}

//~ Hand-Rolled Formatters (replaces snprintf on hot path)

internal int
fmt_u64(char *buf, U64 val)
{
    if(val == 0) { buf[0] = '0'; return 1; }
    char tmp[20];
    int len = 0;
    while(val > 0) { tmp[len++] = '0' + (char)(val % 10); val /= 10; }
    for(int i = 0; i < len; i++) buf[i] = tmp[len - 1 - i];
    return len;
}

internal int
fmt_s64(char *buf, S64 val)
{
    if(val < 0) { buf[0] = '-'; return 1 + fmt_u64(buf + 1, (U64)(-val)); }
    return fmt_u64(buf, (U64)val);
}

internal int
fmt_u32(char *buf, U32 val)
{
    return fmt_u64(buf, (U64)val);
}

// Format double with N decimal places (0, 1, or 2)
internal int
fmt_f64(char *buf, double val, int decimals)
{
    int pos = 0;
    if(val < 0) { buf[pos++] = '-'; val = -val; }

    // Multiply to get fixed-point
    U64 mul = 1;
    for(int i = 0; i < decimals; i++) mul *= 10;
    U64 fixed = (U64)(val * mul + 0.5);
    U64 whole = fixed / mul;
    U64 frac  = fixed % mul;

    pos += fmt_u64(buf + pos, whole);

    if(decimals > 0)
    {
        buf[pos++] = '.';
        // Pad with leading zeros
        for(int i = decimals - 1; i > 0; i--)
        {
            U64 d = 1;
            for(int j = 0; j < i; j++) d *= 10;
            if(frac < d) buf[pos++] = '0';
        }
        if(frac > 0) pos += fmt_u64(buf + pos, frac);
    }
    return pos;
}

// Append a formatted string directly into OutBuf
internal void
out_u64(OutBuf *buf, U64 val)
{
    char tmp[20];
    int len = fmt_u64(tmp, val);
    out_strn(buf, tmp, len);
}

internal void
out_f64(OutBuf *buf, double val, int decimals)
{
    char tmp[32];
    int len = fmt_f64(tmp, val, decimals);
    out_strn(buf, tmp, len);
}

//~ Segment Builder

// All ANSI BG strings have format \x1b[48;2;R;G;Bm
// FG equivalent is \x1b[38;2;R;G;Bm (just change byte 2: '4' -> '3')
internal void
bg_to_fg_buf(const char *bg, U64 bg_len, char *fg_out, U64 *fg_len_out)
{
    if(bg == NULL || bg_len == 0 || bg_len >= 64)
    {
        *fg_len_out = 0;
        return;
    }
    memcpy(fg_out, bg, bg_len);
    fg_out[2] = '3';  // 48;2 -> 38;2
    *fg_len_out = bg_len;
}

internal void
segment(OutBuf *buf, const char *bg, U64 bg_len,
        const char *fg, U64 fg_len,
        const char *text, U64 text_len, B32 first)
{
    if(!first && buf->prev_bg != NULL)
    {
        char fg_tmp[64];
        U64 fg_tmp_len;
        bg_to_fg_buf(buf->prev_bg, buf->prev_bg_len, fg_tmp, &fg_tmp_len);

        out_strn(buf, bg, bg_len);
        out_strn(buf, fg_tmp, fg_tmp_len);
        out_lit(buf, SEP_ROUND);
        out_lit(buf, ANSI_RESET);
    }

    out_strn(buf, bg, bg_len);
    out_strn(buf, fg, fg_len);
    out_char(buf, ' ');
    out_strn(buf, text, text_len);
    out_char(buf, ' ');
    out_lit(buf, ANSI_RESET);

    buf->prev_bg = bg;
    buf->prev_bg_len = bg_len;
}

// Convenience: segment with string literal bg/fg, runtime text
#define seg(buf, bg, fg, text, text_len, first) \
    segment(buf, bg, sizeof(bg)-1, fg, sizeof(fg)-1, text, text_len, first)

// Convenience: segment with string literal bg, empty fg, runtime text
#define seg_nofg(buf, bg, text, text_len, first) \
    segment(buf, bg, sizeof(bg)-1, "", 0, text, text_len, first)

internal void
segment_end(OutBuf *buf)
{
    if(buf->prev_bg != NULL)
    {
        char fg_tmp[64];
        U64 fg_tmp_len;
        bg_to_fg_buf(buf->prev_bg, buf->prev_bg_len, fg_tmp, &fg_tmp_len);
        out_strn(buf, fg_tmp, fg_tmp_len);
        out_lit(buf, SEP_ROUND);
        out_lit(buf, ANSI_RESET);
    }
}

//~ Single-Pass JSON Parser

typedef struct JsonFields JsonFields;
struct JsonFields
{
    const char *current_dir;      U64 current_dir_len;
    const char *display_name;     U64 display_name_len;
    const char *mode;             U64 mode_len;
    double total_cost_usd;
    S64    total_lines_added;
    S64    total_lines_removed;
    S64    total_duration_ms;
    S64    used_percentage;
    S64    context_window_size;
};

// Pre-computed key strings with lengths (no snprintf needle building)
#define KEY_CURRENT_DIR       "\"current_dir\":"
#define KEY_DISPLAY_NAME      "\"display_name\":"
#define KEY_MODE              "\"mode\":"
#define KEY_TOTAL_COST_USD    "\"total_cost_usd\":"
#define KEY_LINES_ADDED       "\"total_lines_added\":"
#define KEY_LINES_REMOVED     "\"total_lines_removed\":"
#define KEY_DURATION_MS       "\"total_duration_ms\":"
#define KEY_USED_PCT          "\"used_percentage\":"
#define KEY_CTX_SIZE          "\"context_window_size\":"

// Parse a JSON string value at current position (p points past ':')
// Returns pointer into json, sets *len. Advances *p past closing quote.
internal const char *
parse_json_string(const char **p, U64 *len)
{
    const char *c = *p;
    while(*c == ' ' || *c == '\t') c++;
    if(*c != '"') { *len = 0; return NULL; }
    c++;
    const char *start = c;
    while(*c && *c != '"') c++;
    *len = (U64)(c - start);
    if(*c == '"') c++;
    *p = c;
    return start;
}

// Parse a JSON number at current position (p points past ':')
internal S64
parse_json_s64(const char **p)
{
    const char *c = *p;
    while(*c == ' ' || *c == '\t') c++;
    S64 val = strtoll(c, (char **)&c, 10);
    *p = c;
    return val;
}

internal double
parse_json_f64(const char **p)
{
    const char *c = *p;
    while(*c == ' ' || *c == '\t') c++;
    double val = strtod(c, (char **)&c);
    *p = c;
    return val;
}

// Match a key at position. Returns length of key if matched, 0 otherwise.
#define TRY_KEY(pos, key) \
    (memcmp(pos, key, sizeof(key)-1) == 0 ? sizeof(key)-1 : 0)

internal void
json_parse_all(const char *json, JsonFields *f)
{
    memset(f, 0, sizeof(*f));
    const char *p = json;

    while(*p)
    {
        // Scan for next '"'
        while(*p && *p != '"') p++;
        if(*p == 0) break;

        U64 klen;

        // Dispatch on first char after '"' for fast rejection
        switch(p[1])
        {
        case 'c':
            if((klen = TRY_KEY(p, KEY_CURRENT_DIR)))
            {
                p += klen;
                f->current_dir = parse_json_string(&p, &f->current_dir_len);
                continue;
            }
            if((klen = TRY_KEY(p, KEY_CTX_SIZE)))
            {
                p += klen;
                f->context_window_size = parse_json_s64(&p);
                continue;
            }
            break;

        case 'd':
            if((klen = TRY_KEY(p, KEY_DISPLAY_NAME)))
            {
                p += klen;
                f->display_name = parse_json_string(&p, &f->display_name_len);
                continue;
            }
            break;

        case 'm':
            if((klen = TRY_KEY(p, KEY_MODE)))
            {
                p += klen;
                f->mode = parse_json_string(&p, &f->mode_len);
                continue;
            }
            break;

        case 't':
            if((klen = TRY_KEY(p, KEY_TOTAL_COST_USD)))
            {
                p += klen;
                f->total_cost_usd = parse_json_f64(&p);
                continue;
            }
            if((klen = TRY_KEY(p, KEY_LINES_ADDED)))
            {
                p += klen;
                f->total_lines_added = parse_json_s64(&p);
                continue;
            }
            if((klen = TRY_KEY(p, KEY_LINES_REMOVED)))
            {
                p += klen;
                f->total_lines_removed = parse_json_s64(&p);
                continue;
            }
            if((klen = TRY_KEY(p, KEY_DURATION_MS)))
            {
                p += klen;
                f->total_duration_ms = parse_json_s64(&p);
                continue;
            }
            break;

        case 'u':
            if((klen = TRY_KEY(p, KEY_USED_PCT)))
            {
                p += klen;
                f->used_percentage = parse_json_s64(&p);
                continue;
            }
            break;
        }

        // Not a key we care about — skip past this '"'
        p++;
    }
}

//~ Path Abbreviation

internal U64
abbrev_path(const char *path, char *out, U64 out_cap)
{
    const char *home = getenv("HOME");
    U64 home_len = home ? strlen(home) : 0;

    // Working buffer: substitute ~ for HOME prefix
    char buf[512];
    U64 buf_len;
    if(home && home_len > 0 && strncmp(path, home, home_len) == 0)
    {
        buf[0] = '~';
        U64 rest_len = strlen(path + home_len);
        U64 copy_len = Min(rest_len, sizeof(buf) - 2);
        memcpy(buf + 1, path + home_len, copy_len);
        buf_len = 1 + copy_len;
        buf[buf_len] = '\0';
    }
    else
    {
        buf_len = strlen(path);
        U64 copy_len = Min(buf_len, sizeof(buf) - 1);
        memcpy(buf, path, copy_len);
        buf_len = copy_len;
        buf[buf_len] = '\0';
    }

    if(buf_len <= 1 || memchr(buf, '/', buf_len) == NULL)
    {
        U64 copy_len = Min(buf_len, out_cap - 1);
        memcpy(out, buf, copy_len);
        out[copy_len] = '\0';
        return copy_len;
    }

    // Walk the string: abbreviate all components except the last to first char
    U64 pos = 0;
    U64 i = 0;

    // Find the last '/' to know where the final component starts
    U64 last_slash = 0;
    for(U64 j = 0; j < buf_len; j++)
        if(buf[j] == '/') last_slash = j;

    while(i < buf_len && pos < out_cap - 1)
    {
        if(i > 0 && buf[i] == '/')
        {
            out[pos++] = '/';
            i++;
            continue;
        }

        // Find end of this component
        U64 comp_start = i;
        while(i < buf_len && buf[i] != '/') i++;
        U64 comp_len = i - comp_start;

        if(comp_start < last_slash && buf[comp_start] != '~')
        {
            // Abbreviate: just first char
            if(pos < out_cap - 1)
                out[pos++] = buf[comp_start];
        }
        else
        {
            // Last component or ~: copy fully
            U64 copy_len = Min(comp_len, out_cap - 1 - pos);
            memcpy(out + pos, buf + comp_start, copy_len);
            pos += copy_len;
        }
    }
    out[pos] = '\0';
    return pos;
}

//~ Context Bar Builder (snprintf-free)

internal U64
make_context_bar(S64 pct, S64 ctx_size, char *out, U64 out_cap)
{
    S64 clamped = Min(pct, 100);
    int width = 15;
    int filled = (int)(clamped * width / 100);
    int empty = width - filled;

    const char *fill_color;
    U64 fill_color_len;
    if(clamped >= 90)      { fill_color = ANSI_FG_RED;    fill_color_len = sizeof(ANSI_FG_RED)-1; }
    else if(clamped >= 80) { fill_color = ANSI_FG_ORANGE; fill_color_len = sizeof(ANSI_FG_ORANGE)-1; }
    else if(clamped >= 50) { fill_color = ANSI_FG_YELLOW; fill_color_len = sizeof(ANSI_FG_YELLOW)-1; }
    else                   { fill_color = ANSI_FG_GREEN;  fill_color_len = sizeof(ANSI_FG_GREEN)-1; }

    char *p = out;
    char *end = out + out_cap - 1;

    // Fill color
    memcpy(p, fill_color, fill_color_len); p += fill_color_len;

    // Used tokens label: Nk
    S64 used_tokens = pct * ctx_size / 100;
    S64 used_k = (used_tokens + 500) / 1000;  // round to nearest k
    p += fmt_s64(p, used_k);
    *p++ = 'k'; *p++ = ' ';

    // Left cap
    memcpy(p, UTF8_LCAP, 3); p += 3;

    // Filled bars
    for(int i = 0; i < filled && p + 3 <= end; i++)
    { memcpy(p, UTF8_FILL, 3); p += 3; }

    // Percentage
    *p++ = ' ';
    p += fmt_s64(p, clamped);
    *p++ = '%'; *p++ = ' ';

    // Comment color for empty portion
    memcpy(p, ANSI_FG_COMMENT, sizeof(ANSI_FG_COMMENT)-1);
    p += sizeof(ANSI_FG_COMMENT)-1;

    // Empty bars
    for(int i = 0; i < empty && p + 3 <= end; i++)
    { memcpy(p, UTF8_EMPTY, 3); p += 3; }

    // Right cap
    memcpy(p, UTF8_RCAP, 3); p += 3;

    // Total context label in fill color
    memcpy(p, fill_color, fill_color_len); p += fill_color_len;
    *p++ = ' ';
    if(ctx_size >= 1000000)
    {
        p += fmt_s64(p, ctx_size / 1000000);
        *p++ = 'M';
    }
    else
    {
        p += fmt_s64(p, ctx_size / 1000);
        *p++ = 'k';
    }

    *p = '\0';
    return (U64)(p - out);
}

//~ Duration Formatting (snprintf-free)

internal U64
format_duration(S64 ms, char *out)
{
    char *p = out;

    if(ms < 1000)
    {
        p += fmt_s64(p, ms);
        *p++ = 'm'; *p++ = 's';
    }
    else if(ms < 60000)
    {
        p += fmt_f64(p, ms / 1000.0, 1);
        *p++ = 's';
    }
    else if(ms < 3600000)
    {
        p += fmt_s64(p, ms / 60000);
        *p++ = 'm';
        p += fmt_s64(p, (ms % 60000) / 1000);
        *p++ = 's';
    }
    else
    {
        p += fmt_s64(p, ms / 3600000);
        *p++ = 'h';
        p += fmt_s64(p, (ms % 3600000) / 60000);
        *p++ = 'm';
    }
    *p = '\0';
    return (U64)(p - out);
}

//~ Git Status

enum CacheState { CACHE_NONE, CACHE_STALE, CACHE_VALID };

typedef struct GitStatus GitStatus;
struct GitStatus
{
    B32  valid;
    char branch[128];
    S64  stashes;
    U32  modified;
    U32  staged;
    U32  ahead;
    U32  behind;
    enum CacheState cache_state;
};

internal S64
git_read_stash_count(const char *dir)
{
    char path[512];
    snprintf(path, sizeof(path), "%s/.git/logs/refs/stash", dir);

    int fd = open(path, O_RDONLY);
    if(fd < 0) return 0;

    char buf[4096];
    S64 count = 0;
    for(;;)
    {
        ssize_t n = read(fd, buf, sizeof(buf));
        if(n <= 0) break;
        for(ssize_t i = 0; i < n; i++)
            if(buf[i] == '\n') count++;
    }
    close(fd);
    return count;
}

internal B32
git_read_branch_fast(const char *dir, char *branch_out, U64 branch_cap)
{
    char head_path[512];
    snprintf(head_path, sizeof(head_path), "%s/.git/HEAD", dir);

    int fd = open(head_path, O_RDONLY);
    if(fd < 0) return false;

    char buf[256];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if(n <= 0) return false;
    buf[n] = '\0';

    while(n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r' || buf[n-1] == ' '))
        buf[--n] = '\0';

    #define REF_PREFIX "ref: refs/heads/"
    if(n > (ssize_t)(sizeof(REF_PREFIX)-1) && memcmp(buf, REF_PREFIX, sizeof(REF_PREFIX)-1) == 0)
    {
        const char *branch = buf + sizeof(REF_PREFIX) - 1;
        U64 len = (U64)(n - (sizeof(REF_PREFIX) - 1));
        U64 copy_len = Min(len, branch_cap - 1);
        memcpy(branch_out, branch, copy_len);
        branch_out[copy_len] = '\0';
        return true;
    }
    #undef REF_PREFIX

    if(n >= 7)
    {
        U64 copy_len = Min(7, branch_cap - 1);
        memcpy(branch_out, buf, copy_len);
        branch_out[copy_len] = '\0';
        return true;
    }

    return false;
}

//~ State Cache

#define CACHE_PATH_PREFIX "/dev/shm/statusline-cache."
#define CLEANUP_INTERVAL_S 300

typedef struct __attribute__((packed)) CachedState CachedState;
struct __attribute__((packed)) CachedState
{
    S64    used_pct;
    S64    context_size;
    double cost_usd;
    S64    lines_added;
    S64    lines_removed;
    S64    duration_ms;
    char   cwd[256];
    char   model[64];
};

internal int
get_grandparent_pid(void)
{
    pid_t ppid = getppid();

    char path[32];
    snprintf(path, sizeof(path), "/proc/%d/status", ppid);

    int fd = open(path, O_RDONLY);
    if(fd < 0) return ppid;

    char buf[1024];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if(n <= 0) return ppid;
    buf[n] = '\0';

    const char *needle = "PPid:\t";
    char *p = strstr(buf, needle);
    if(p == NULL) return ppid;

    p += 6;  // strlen("PPid:\t")
    return (int)strtol(p, NULL, 10);
}

internal void
get_cache_path(char *out, U64 out_cap)
{
    int gppid = get_grandparent_pid();
    snprintf(out, out_cap, "%s%d", CACHE_PATH_PREFIX, gppid);
}

internal B32
read_cached_state(CachedState *state)
{
    char path[64];
    get_cache_path(path, sizeof(path));

    int fd = open(path, O_RDONLY);
    if(fd < 0) return false;

    ssize_t n = read(fd, state, sizeof(CachedState));
    close(fd);
    return n == sizeof(CachedState);
}

internal void
write_cached_state(const CachedState *state)
{
    char path[64];
    get_cache_path(path, sizeof(path));

    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if(fd < 0) return;

    write(fd, state, sizeof(CachedState));
    close(fd);
}

internal void
cleanup_stale_caches(void)
{
    struct stat st;
    S64 now_ms = time_ms_realtime();
    if(stat("/dev/shm/statusline-cleanup", &st) == 0)
    {
        S64 last_s = (S64)st.st_mtim.tv_sec;
        if(now_ms / 1000 - last_s < CLEANUP_INTERVAL_S) return;
    }

    int sentinel_fd = open("/dev/shm/statusline-cleanup", O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if(sentinel_fd >= 0) close(sentinel_fd);

    DIR *dir = opendir("/dev/shm");
    if(dir == NULL) return;

    struct dirent *entry;
    while((entry = readdir(dir)) != NULL)
    {
        if(strncmp(entry->d_name, "statusline-cache.", 17) != 0) continue;

        int pid = (int)strtol(entry->d_name + 17, NULL, 10);
        if(pid <= 0) continue;
        if(kill(pid, 0) == 0) continue;

        char rm_path[300];
        snprintf(rm_path, sizeof(rm_path), "/dev/shm/%s", entry->d_name);
        unlink(rm_path);
    }
    closedir(dir);

    uid_t uid = getuid();
    char log_dir[64];
    snprintf(log_dir, sizeof(log_dir), "/tmp/statusline-%d", uid);

    DIR *tmp_dir = opendir(log_dir);
    if(tmp_dir == NULL) return;

    while((entry = readdir(tmp_dir)) != NULL)
    {
        U64 name_len = strlen(entry->d_name);
        if(name_len < 5 || strcmp(entry->d_name + name_len - 4, ".log") != 0)
            continue;

        char pid_str[32];
        U64 copy_len = Min(name_len - 4, sizeof(pid_str) - 1);
        memcpy(pid_str, entry->d_name, copy_len);
        pid_str[copy_len] = '\0';

        int log_pid = (int)strtol(pid_str, NULL, 10);
        if(log_pid <= 0) continue;
        if(kill(log_pid, 0) == 0) continue;

        char rm_path[96];
        snprintf(rm_path, sizeof(rm_path), "%s/%s", log_dir, entry->d_name);
        unlink(rm_path);
    }
    closedir(tmp_dir);
}

//~ Git Status Cache

typedef struct __attribute__((packed)) GitCache GitCache;
struct __attribute__((packed)) GitCache
{
    S64  index_mtime_sec;
    S64  index_mtime_nsec;
    U32  modified;
    U32  staged;
    U32  ahead;
    U32  behind;
    char branch[64];
    char repo_path[256];
};

#define GIT_CACHE_TTL_MS 5000

internal U32
hash_path(const char *path)
{
    U32 h = 2166136261u;
    for(const char *p = path; *p; p++)
    {
        h ^= (U32)(unsigned char)*p;
        h *= 16777619u;
    }
    return h;
}

internal void
get_git_cache_path(const char *repo_path, char *out, U64 out_cap)
{
    U32 h = hash_path(repo_path);
    snprintf(out, out_cap, "/dev/shm/claude-git-%08x", h);
}

internal enum CacheState
read_git_cache(const char *repo_path, GitCache *cache)
{
    char cache_path[64];
    get_git_cache_path(repo_path, cache_path, sizeof(cache_path));

    int fd = open(cache_path, O_RDONLY);
    if(fd < 0) return CACHE_NONE;

    ssize_t n = read(fd, cache, sizeof(GitCache));
    if(n != sizeof(GitCache)) { close(fd); return CACHE_NONE; }

    if(strncmp(cache->repo_path, repo_path, sizeof(cache->repo_path)) != 0)
    {
        close(fd);
        return CACHE_NONE;
    }

    struct stat cache_st;
    if(fstat(fd, &cache_st) != 0) { close(fd); return CACHE_STALE; }
    close(fd);

    S64 cache_age_ms = time_ms_realtime() -
        ((S64)cache_st.st_mtim.tv_sec * 1000 + (S64)cache_st.st_mtim.tv_nsec / 1000000);
    if(cache_age_ms > GIT_CACHE_TTL_MS) return CACHE_STALE;

    char index_path[512];
    snprintf(index_path, sizeof(index_path), "%s/.git/index", repo_path);
    struct stat idx_st;
    if(stat(index_path, &idx_st) != 0) return CACHE_STALE;

    if((S64)idx_st.st_mtim.tv_sec == cache->index_mtime_sec &&
       (S64)idx_st.st_mtim.tv_nsec == cache->index_mtime_nsec)
    {
        return CACHE_VALID;
    }

    return CACHE_STALE;
}

internal void
write_git_cache(const char *repo_path, U32 modified, U32 staged, U32 ahead, U32 behind)
{
    char index_path[512];
    snprintf(index_path, sizeof(index_path), "%s/.git/index", repo_path);
    struct stat idx_st;
    if(stat(index_path, &idx_st) != 0) return;

    GitCache cache;
    memset(&cache, 0, sizeof(cache));
    cache.index_mtime_sec = (S64)idx_st.st_mtim.tv_sec;
    cache.index_mtime_nsec = (S64)idx_st.st_mtim.tv_nsec;
    cache.modified = modified;
    cache.staged = staged;
    cache.ahead = ahead;
    cache.behind = behind;
    strncpy(cache.repo_path, repo_path, sizeof(cache.repo_path) - 1);

    char cache_path[64];
    get_git_cache_path(repo_path, cache_path, sizeof(cache_path));

    int fd = open(cache_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if(fd < 0) return;
    write(fd, &cache, sizeof(cache));
    close(fd);
}

internal void
run_git_status(const char *repo_path, U32 *out_modified, U32 *out_staged,
               U32 *out_ahead, U32 *out_behind)
{
    *out_modified = 0;
    *out_staged = 0;
    *out_ahead = 0;
    *out_behind = 0;

    int pipe_fds[2];
    if(pipe(pipe_fds) != 0) return;

    pid_t pid = fork();
    if(pid < 0)
    {
        close(pipe_fds[0]);
        close(pipe_fds[1]);
        return;
    }

    if(pid == 0)
    {
        close(pipe_fds[0]);
        chdir(repo_path);
        dup2(pipe_fds[1], STDOUT_FILENO);
        int dev_null = open("/dev/null", O_WRONLY);
        if(dev_null >= 0) { dup2(dev_null, STDERR_FILENO); close(dev_null); }
        close(pipe_fds[1]);

        char *argv[] = {"git", "status", "--porcelain", "-b", "-uno", NULL};
        execvp("git", argv);
        _exit(127);
    }

    close(pipe_fds[1]);

    char buf[4096];
    int total_read = 0;
    for(;;)
    {
        int remaining = (int)sizeof(buf) - total_read;
        if(remaining <= 0) break;
        ssize_t n = read(pipe_fds[0], buf + total_read, remaining);
        if(n <= 0) break;
        total_read += (int)n;
    }
    close(pipe_fds[0]);
    waitpid(pid, NULL, 0);

    char *line = buf;
    char *buf_end = buf + total_read;
    while(line < buf_end)
    {
        char *nl = memchr(line, '\n', buf_end - line);
        int line_len = nl ? (int)(nl - line) : (int)(buf_end - line);
        if(line_len < 2) { line = nl ? nl + 1 : buf_end; continue; }

        if(line[0] == '#' && line[1] == '#')
        {
            char *bracket = memchr(line, '[', line_len);
            if(bracket)
            {
                char *a = strstr(bracket, "ahead ");
                if(a) *out_ahead = (U32)strtol(a + 6, NULL, 10);
                char *b = strstr(bracket, "behind ");
                if(b) *out_behind = (U32)strtol(b + 7, NULL, 10);
            }
        }
        else
        {
            if(line[0] != ' ' && line[0] != '?') *out_staged += 1;
            if(line[1] != ' ' && line[1] != '?') *out_modified += 1;
        }

        line = nl ? nl + 1 : buf_end;
    }
}

internal void
get_git_status_cached(const char *repo_path, U32 *modified, U32 *staged,
                      U32 *ahead, U32 *behind, enum CacheState *state)
{
    GitCache cache;
    *state = read_git_cache(repo_path, &cache);

    switch(*state)
    {
    case CACHE_VALID:
        *modified = cache.modified;
        *staged = cache.staged;
        *ahead = cache.ahead;
        *behind = cache.behind;
        return;

    case CACHE_STALE:
        *modified = cache.modified;
        *staged = cache.staged;
        *ahead = cache.ahead;
        *behind = cache.behind;
        {
            pid_t bg_pid = fork();
            if(bg_pid == 0)
            {
                if(fork() == 0)
                {
                    U32 m, s, a, b;
                    run_git_status(repo_path, &m, &s, &a, &b);
                    write_git_cache(repo_path, m, s, a, b);
                }
                _exit(0);
            }
            if(bg_pid > 0) waitpid(bg_pid, NULL, 0);
        }
        return;

    case CACHE_NONE:
        run_git_status(repo_path, modified, staged, ahead, behind);
        write_git_cache(repo_path, *modified, *staged, *ahead, *behind);
        return;
    }
}

//~ Branch Truncation

internal const char *
truncate_branch(const char *branch, int max_len, U64 *out_len)
{
    static char trunc_buf[64];
    int len = (int)strlen(branch);
    if(len <= max_len) { *out_len = len; return branch; }

    int copy_len = max_len - 3;
    memcpy(trunc_buf, branch, copy_len);
    trunc_buf[copy_len] = '.';
    trunc_buf[copy_len + 1] = '.';
    trunc_buf[copy_len + 2] = '.';
    trunc_buf[copy_len + 3] = '\0';
    *out_len = max_len;
    return trunc_buf;
}

//~ Git Segment Builder (snprintf-free)

internal void
build_git_segment(OutBuf *buf, GitStatus *gs)
{
    if(!gs->valid) return;

    // Branch text: ICON_BRANCH " " + branch name
    char text[256];
    char *p = text;
    memcpy(p, ICON_BRANCH " ", sizeof(ICON_BRANCH " ") - 1);
    p += sizeof(ICON_BRANCH " ") - 1;

    U64 blen;
    const char *br = truncate_branch(gs->branch, 20, &blen);
    memcpy(p, br, blen);
    p += blen;
    U64 text_len = (U64)(p - text);

    const char *bg; U64 bg_len;
    if(gs->modified > 0 || gs->staged > 0)
    { bg = ANSI_BG_ORANGE; bg_len = sizeof(ANSI_BG_ORANGE)-1; }
    else
    { bg = ANSI_BG_GREEN; bg_len = sizeof(ANSI_BG_GREEN)-1; }

    segment(buf, bg, bg_len, ANSI_FG_BLACK, sizeof(ANSI_FG_BLACK)-1, text, text_len, false);

    // Status counts
    if(gs->staged > 0 || gs->modified > 0 || gs->stashes > 0 ||
       gs->ahead > 0 || gs->behind > 0)
    {
        char status[256];
        p = status;

        if(gs->ahead > 0)
        {
            memcpy(p, ANSI_FG_GREEN, sizeof(ANSI_FG_GREEN)-1); p += sizeof(ANSI_FG_GREEN)-1;
            memcpy(p, UTF8_UP, 3); p += 3;
            p += fmt_u32(p, gs->ahead);
            *p++ = ' ';
        }
        if(gs->behind > 0)
        {
            memcpy(p, ANSI_FG_RED, sizeof(ANSI_FG_RED)-1); p += sizeof(ANSI_FG_RED)-1;
            memcpy(p, UTF8_DOWN, 3); p += 3;
            p += fmt_u32(p, gs->behind);
            *p++ = ' ';
        }
        if(gs->staged > 0)
        {
            memcpy(p, ANSI_FG_GREEN, sizeof(ANSI_FG_GREEN)-1); p += sizeof(ANSI_FG_GREEN)-1;
            memcpy(p, ICON_STAGED, sizeof(ICON_STAGED)-1); p += sizeof(ICON_STAGED)-1;
            p += fmt_u32(p, gs->staged);
            *p++ = ' ';
        }
        if(gs->modified > 0)
        {
            memcpy(p, ANSI_FG_ORANGE, sizeof(ANSI_FG_ORANGE)-1); p += sizeof(ANSI_FG_ORANGE)-1;
            memcpy(p, ICON_MODIFIED, sizeof(ICON_MODIFIED)-1); p += sizeof(ICON_MODIFIED)-1;
            p += fmt_u32(p, gs->modified);
            *p++ = ' ';
        }
        if(gs->stashes > 0)
        {
            memcpy(p, ANSI_FG_PURPLE, sizeof(ANSI_FG_PURPLE)-1); p += sizeof(ANSI_FG_PURPLE)-1;
            memcpy(p, ICON_STASH, sizeof(ICON_STASH)-1); p += sizeof(ICON_STASH)-1;
            p += fmt_s64(p, gs->stashes);
        }

        // Trim trailing space
        U64 slen = (U64)(p - status);
        if(slen > 0 && status[slen - 1] == ' ') slen--;

        segment(buf, ANSI_BG_DARK, sizeof(ANSI_BG_DARK)-1, "", 0, status, slen, false);
    }
}

//~ Display State

typedef struct DisplayState DisplayState;
struct DisplayState
{
    char   cwd[512];
    char   model[64];
    double cost_usd;
    S64    lines_added;
    S64    lines_removed;
    S64    total_duration_ms;
    S64    used_pct;
    S64    ctx_size;
    char   vim_mode[32];
};

//~ Stdin Reader

#define STDIN_TIMEOUT_MS 50

internal B32
read_stdin(char *buf, U64 buf_cap, U64 *out_len)
{
    *out_len = 0;
    struct pollfd pfd = {.fd = STDIN_FILENO, .events = POLLIN};
    if(poll(&pfd, 1, STDIN_TIMEOUT_MS) <= 0) return false;

    // Single read — JSON is <4KB, always arrives atomically via pipe (PIPE_BUF=4096)
    ssize_t n = read(STDIN_FILENO, buf, buf_cap - 1);
    if(n <= 0) return false;
    *out_len = (U64)n;
    buf[*out_len] = '\0';
    return true;
}

//~ State Resolution (uses single-pass JSON parser)

internal void
resolve_state(const char *input, B32 has_stdin, DisplayState *state)
{
    CachedState cached;
    memset(&cached, 0, sizeof(cached));
    read_cached_state(&cached);

    memset(state, 0, sizeof(*state));

    if(has_stdin)
    {
        JsonFields f;
        json_parse_all(input, &f);

        // Copy string fields
        if(f.current_dir_len > 0)
        {
            U64 clen = Min(f.current_dir_len, sizeof(state->cwd) - 1);
            memcpy(state->cwd, f.current_dir, clen);
            state->cwd[clen] = '\0';
        }
        else if(cached.cwd[0])
            strcpy(state->cwd, cached.cwd);

        if(f.display_name_len > 0)
        {
            U64 mlen = Min(f.display_name_len, sizeof(state->model) - 1);
            memcpy(state->model, f.display_name, mlen);
            state->model[mlen] = '\0';
        }
        else if(cached.model[0])
            strcpy(state->model, cached.model);

        if(f.mode_len > 0)
        {
            U64 vlen = Min(f.mode_len, sizeof(state->vim_mode) - 1);
            memcpy(state->vim_mode, f.mode, vlen);
            state->vim_mode[vlen] = '\0';
        }

        state->cost_usd          = f.total_cost_usd > 0 ? f.total_cost_usd : cached.cost_usd;
        state->lines_added       = f.total_lines_added > 0 ? f.total_lines_added : cached.lines_added;
        state->lines_removed     = f.total_lines_removed > 0 ? f.total_lines_removed : cached.lines_removed;
        state->total_duration_ms = f.total_duration_ms > 0 ? f.total_duration_ms : cached.duration_ms;
        state->used_pct          = f.used_percentage > 0 ? f.used_percentage : cached.used_pct;
        state->ctx_size          = f.context_window_size > 0 ? f.context_window_size : cached.context_size;

        // Update cache
        CachedState new_cache;
        new_cache.used_pct      = Max(f.used_percentage, cached.used_pct);
        new_cache.context_size  = Max(f.context_window_size, cached.context_size);
        new_cache.cost_usd      = f.total_cost_usd > cached.cost_usd ? f.total_cost_usd : cached.cost_usd;
        new_cache.lines_added   = Max(f.total_lines_added, cached.lines_added);
        new_cache.lines_removed = Max(f.total_lines_removed, cached.lines_removed);
        new_cache.duration_ms   = Max(f.total_duration_ms, cached.duration_ms);

        memset(new_cache.cwd, 0, sizeof(new_cache.cwd));
        memset(new_cache.model, 0, sizeof(new_cache.model));
        if(f.current_dir_len > 0)
            memcpy(new_cache.cwd, f.current_dir, Min(f.current_dir_len, sizeof(new_cache.cwd) - 1));
        else
            memcpy(new_cache.cwd, cached.cwd, sizeof(new_cache.cwd));

        if(f.display_name_len > 0)
            memcpy(new_cache.model, f.display_name, Min(f.display_name_len, sizeof(new_cache.model) - 1));
        else
            memcpy(new_cache.model, cached.model, sizeof(new_cache.model));

        if(memcmp(&new_cache, &cached, sizeof(CachedState)) != 0)
            write_cached_state(&new_cache);
    }
    else
    {
        if(cached.cwd[0]) strcpy(state->cwd, cached.cwd);
        if(cached.model[0]) strcpy(state->model, cached.model);
        state->cost_usd          = cached.cost_usd;
        state->lines_added       = cached.lines_added;
        state->lines_removed     = cached.lines_removed;
        state->total_duration_ms = cached.duration_ms;
        state->used_pct          = cached.used_pct;
        state->ctx_size          = cached.context_size;
    }
}

//~ Statusline Builder (snprintf-free)

internal void
build_statusline(OutBuf *buf, DisplayState *state, GitStatus *gs)
{
    B32 first = true;

    // Vim mode
    if(state->vim_mode[0])
    {
        const char *vim_bg, *vim_fg, *vim_icon;
        U64 vim_bg_len, vim_fg_len, vim_icon_len;
        B32 is_insert = (strcmp(state->vim_mode, "INSERT") == 0);
        if(is_insert)
        {
            vim_bg = ANSI_BG_GREEN; vim_bg_len = sizeof(ANSI_BG_GREEN)-1;
            vim_fg = ANSI_FG_BLACK; vim_fg_len = sizeof(ANSI_FG_BLACK)-1;
            vim_icon = ICON_INSERT; vim_icon_len = sizeof(ICON_INSERT)-1;
        }
        else
        {
            vim_bg = ANSI_BG_DARK;  vim_bg_len = sizeof(ANSI_BG_DARK)-1;
            vim_fg = ANSI_FG_WHITE; vim_fg_len = sizeof(ANSI_FG_WHITE)-1;
            vim_icon = ICON_NORMAL; vim_icon_len = sizeof(ICON_NORMAL)-1;
        }

        char vim_text[64];
        char *p = vim_text;
        if(is_insert)
        {
            memcpy(p, ANSI_BOLD, sizeof(ANSI_BOLD)-1); p += sizeof(ANSI_BOLD)-1;
        }
        memcpy(p, vim_icon, vim_icon_len); p += vim_icon_len;
        *p++ = ' ';
        U64 mode_len = strlen(state->vim_mode);
        memcpy(p, state->vim_mode, mode_len); p += mode_len;

        segment(buf, vim_bg, vim_bg_len, vim_fg, vim_fg_len, vim_text, (U64)(p - vim_text), first);
        first = false;
    }

    // Model (bold)
    {
        char model_text[128];
        memcpy(model_text, ANSI_BOLD, sizeof(ANSI_BOLD)-1);
        U64 model_len = strlen(state->model);
        memcpy(model_text + sizeof(ANSI_BOLD)-1, state->model, model_len);
        U64 text_len = sizeof(ANSI_BOLD)-1 + model_len;

        seg(buf, ANSI_BG_PURPLE, ANSI_FG_BLACK, model_text, text_len, first);
        first = false;
    }

    // Path
    {
        char path_text[300];
        memcpy(path_text, ICON_FOLDER " ", sizeof(ICON_FOLDER " ")-1);
        U64 prefix_len = sizeof(ICON_FOLDER " ")-1;
        U64 abbrev_len = abbrev_path(state->cwd, path_text + prefix_len, sizeof(path_text) - prefix_len);

        seg(buf, ANSI_BG_DARK, ANSI_FG_WHITE, path_text, prefix_len + abbrev_len, false);
    }

    // Git
    if(gs->valid)
        build_git_segment(buf, gs);

    // Cost
    {
        const char *cost_bg; U64 cost_bg_len;
        if(state->cost_usd >= 10.0)      { cost_bg = ANSI_BG_RED;    cost_bg_len = sizeof(ANSI_BG_RED)-1; }
        else if(state->cost_usd >= 5.0)  { cost_bg = ANSI_BG_ORANGE; cost_bg_len = sizeof(ANSI_BG_ORANGE)-1; }
        else if(state->cost_usd >= 1.0)  { cost_bg = ANSI_BG_CYAN;   cost_bg_len = sizeof(ANSI_BG_CYAN)-1; }
        else                              { cost_bg = ANSI_BG_MINT;   cost_bg_len = sizeof(ANSI_BG_MINT)-1; }

        char cost_text[64];
        char *p = cost_text;
        memcpy(p, ICON_DOLLAR " ", sizeof(ICON_DOLLAR " ")-1); p += sizeof(ICON_DOLLAR " ")-1;
        p += fmt_f64(p, state->cost_usd, 2);

        segment(buf, cost_bg, cost_bg_len, ANSI_FG_BLACK, sizeof(ANSI_FG_BLACK)-1,
                cost_text, (U64)(p - cost_text), false);
    }

    // Lines changed
    if(state->lines_added > 0 || state->lines_removed > 0)
    {
        char lines_text[128];
        char *p = lines_text;
        memcpy(p, ANSI_FG_WHITE, sizeof(ANSI_FG_WHITE)-1); p += sizeof(ANSI_FG_WHITE)-1;
        memcpy(p, ICON_DIFF " ", sizeof(ICON_DIFF " ")-1); p += sizeof(ICON_DIFF " ")-1;
        memcpy(p, ANSI_FG_GREEN, sizeof(ANSI_FG_GREEN)-1); p += sizeof(ANSI_FG_GREEN)-1;
        *p++ = '+';
        p += fmt_s64(p, state->lines_added);
        *p++ = ' ';
        memcpy(p, ANSI_FG_RED, sizeof(ANSI_FG_RED)-1); p += sizeof(ANSI_FG_RED)-1;
        *p++ = '-';
        p += fmt_s64(p, state->lines_removed);

        seg_nofg(buf, ANSI_BG_DARK, lines_text, (U64)(p - lines_text), false);
    }

    // Session duration
    if(state->total_duration_ms > 0)
    {
        char dur_text[64];
        char *p = dur_text;
        memcpy(p, ICON_CLOCK " ", sizeof(ICON_CLOCK " ")-1); p += sizeof(ICON_CLOCK " ")-1;
        p += format_duration(state->total_duration_ms, p);

        seg(buf, ANSI_BG_DARK, ANSI_FG_WHITE, dur_text, (U64)(p - dur_text), false);
    }

    // Context bar
    {
        char bar[512];
        U64 bar_len = make_context_bar(state->used_pct, state->ctx_size, bar, sizeof(bar));
        seg_nofg(buf, ANSI_BG_DARK, bar, bar_len, false);
    }

    // Context warnings
    if(state->used_pct >= 80)
    {
        char warn_text[128];
        char *p = warn_text;
        const char *warn_bg; U64 warn_bg_len;

        if(state->used_pct >= 95)
        {
            memcpy(p, ANSI_BOLD, sizeof(ANSI_BOLD)-1); p += sizeof(ANSI_BOLD)-1;
            memcpy(p, ICON_WARN " CRITICAL COMPACT", sizeof(ICON_WARN " CRITICAL COMPACT")-1);
            p += sizeof(ICON_WARN " CRITICAL COMPACT")-1;
            warn_bg = ANSI_BG_RED; warn_bg_len = sizeof(ANSI_BG_RED)-1;
        }
        else if(state->used_pct >= 90)
        {
            memcpy(p, ANSI_BOLD, sizeof(ANSI_BOLD)-1); p += sizeof(ANSI_BOLD)-1;
            memcpy(p, ICON_WARN " LOW CTX COMPACT", sizeof(ICON_WARN " LOW CTX COMPACT")-1);
            p += sizeof(ICON_WARN " LOW CTX COMPACT")-1;
            warn_bg = ANSI_BG_RED; warn_bg_len = sizeof(ANSI_BG_RED)-1;
        }
        else
        {
            memcpy(p, ICON_WARN " CTX 80%+", sizeof(ICON_WARN " CTX 80%+")-1);
            p += sizeof(ICON_WARN " CTX 80%+")-1;
            warn_bg = ANSI_BG_YELLOW; warn_bg_len = sizeof(ANSI_BG_YELLOW)-1;
        }

        segment(buf, warn_bg, warn_bg_len, ANSI_FG_BLACK, sizeof(ANSI_FG_BLACK)-1,
                warn_text, (U64)(p - warn_text), false);
    }

    segment_end(buf);
}

//~ Debug Logging

internal void
write_debug_log(U64 t_start, U64 t_cleanup, U64 t_read, U64 t_parse,
                U64 t_git, U64 t_build, enum CacheState cache_state, B32 has_stdin)
{
    U64 t_end = time_us();
    int gppid = get_grandparent_pid();

    const char *cache_str;
    switch(cache_state)
    {
    case CACHE_VALID: cache_str = "valid"; break;
    case CACHE_STALE: cache_str = "stale"; break;
    case CACHE_NONE:  cache_str = "miss";  break;
    default:          cache_str = "?";     break;
    }

    char line[512];
    int n = snprintf(line, sizeof(line),
        "cleanup=%lluus read=%lluus(%s) parse=%lluus git=%lluus(%s) build=%lluus total=%lluus\n",
        (unsigned long long)(t_cleanup - t_start),
        (unsigned long long)(t_read - t_cleanup),
        has_stdin ? "ok" : "timeout",
        (unsigned long long)(t_parse - t_read),
        (unsigned long long)(t_git - t_parse),
        cache_str,
        (unsigned long long)(t_build - t_git),
        (unsigned long long)(t_end - t_start));

    uid_t uid = getuid();
    char dir_path[64];
    snprintf(dir_path, sizeof(dir_path), "/tmp/statusline-%d", uid);
    mkdir(dir_path, 0700);

    char log_path[96];
    snprintf(log_path, sizeof(log_path), "%s/%d.log", dir_path, gppid);

    int fd = open(log_path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if(fd >= 0)
    {
        write(fd, line, n);
        close(fd);
    }
}

//~ Main

int
main(void)
{
    U64 t_start = time_us();
    B32 debug = (getenv("STATUSLINE_DEBUG") != NULL);

    cleanup_stale_caches();
    U64 t_cleanup = time_us();

    char input[8192];
    U64 input_len;
    B32 has_stdin = read_stdin(input, sizeof(input), &input_len);
    U64 t_read = time_us();

    DisplayState state;
    resolve_state(input, has_stdin, &state);
    U64 t_parse = time_us();

    // Git status
    GitStatus gs;
    memset(&gs, 0, sizeof(gs));
    if(state.cwd[0] && git_read_branch_fast(state.cwd, gs.branch, sizeof(gs.branch)))
    {
        gs.valid = true;
        gs.stashes = git_read_stash_count(state.cwd);
        get_git_status_cached(state.cwd, &gs.modified, &gs.staged,
                              &gs.ahead, &gs.behind, &gs.cache_state);
    }
    U64 t_git = time_us();

    // Build output
    OutBuf buf;
    memset(&buf, 0, sizeof(buf));
    build_statusline(&buf, &state, &gs);
    U64 t_build = time_us();

    // Timing suffix (hand-rolled)
    U64 t_now = time_us();
    U64 total_us = t_now - t_start;
    out_lit(&buf, "  " ANSI_FG_COMMENT);
    if(total_us >= 1000)
    {
        out_f64(&buf, total_us / 1000.0, 1);
        out_lit(&buf, "ms");
    }
    else
    {
        out_u64(&buf, total_us);
        out_lit(&buf, "us");
    }
    out_lit(&buf, ANSI_RESET);

    write(STDOUT_FILENO, buf.data, buf.len);

    if(debug)
        write_debug_log(t_start, t_cleanup, t_read, t_parse, t_git, t_build, gs.cache_state, has_stdin);

    return 0;
}
