//~ nj: Claude Code Statusline
//
// A fast statusline for Claude Code written in C.
// Follows RAD Debugger style conventions.
// Uses pthreads for parallel gitstatus query.
//
// Build: cc -O3 -pthread -o statusline statusline.c
// Usage: Set in ~/.claude/settings.json statusLine.command
//

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <pthread.h>
#include <poll.h>

//~ nj: Base Types

typedef unsigned char      U8;
typedef unsigned short     U16;
typedef unsigned int       U32;
typedef unsigned long long U64;
typedef signed int         S32;
typedef signed long long   S64;
typedef U32                B32;

#define internal static
#define global   static
#define true     1
#define false    0

//~ nj: Macros

#define ArrayCount(a) (sizeof(a) / sizeof((a)[0]))
#define Min(a, b)     ((a) < (b) ? (a) : (b))
#define Max(a, b)     ((a) > (b) ? (a) : (b))
#define ClampTop(x, hi) Min(x, hi)
#define Unused(x) (void)(x)

//~ nj: Timing (for benchmarks)

internal U64
time_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (U64)ts.tv_sec * 1000000 + (U64)ts.tv_nsec / 1000;
}

//~ nj: String Slice

typedef struct Str8 Str8;
struct Str8
{
    U8 *data;
    U64 size;
};

#define str8_lit(s) (Str8){(U8*)(s), sizeof(s)-1}

//~ nj: ANSI Colors (Dracula Theme)

#define ANSI_RESET       "\033[0m"
#define ANSI_BG_PURPLE   "\033[48;2;189;147;249m"
#define ANSI_BG_ORANGE   "\033[48;2;255;184;108m"
#define ANSI_BG_DARK     "\033[48;2;68;71;90m"
#define ANSI_BG_GREEN    "\033[48;2;72;209;104m"
#define ANSI_BG_MINT     "\033[48;2;40;167;69m"
#define ANSI_BG_COMMENT  "\033[48;2;98;114;164m"
#define ANSI_BG_RED      "\033[48;2;255;85;85m"
#define ANSI_BG_CYAN     "\033[48;2;139;233;253m"
#define ANSI_BG_PINK     "\033[48;2;255;121;198m"

#define ANSI_FG_BLACK    "\033[38;2;40;42;54m"
#define ANSI_FG_WHITE    "\033[38;2;248;248;242m"
#define ANSI_FG_PURPLE   "\033[38;2;189;147;249m"
#define ANSI_FG_DARK     "\033[38;2;68;71;90m"
#define ANSI_FG_GREEN    "\033[38;2;80;250;123m"
#define ANSI_FG_COMMENT  "\033[38;2;98;114;164m"
#define ANSI_FG_YELLOW   "\033[38;2;241;250;140m"
#define ANSI_FG_ORANGE   "\033[38;2;255;184;108m"
#define ANSI_FG_RED      "\033[38;2;255;85;85m"
#define ANSI_FG_CYAN     "\033[38;2;139;233;253m"
#define ANSI_FG_PINK     "\033[38;2;255;121;198m"

#define SEP_CHAR "\xee\x82\xb0"  // Powerline separator U+E0B0

//~ nj: Output Buffer

typedef struct OutBuf OutBuf;
struct OutBuf
{
    char data[4096];
    U64  len;
    char *prev_bg;
};

internal void
out_str(OutBuf *buf, char *s)
{
    U64 slen = strlen(s);
    if(buf->len + slen < sizeof(buf->data))
    {
        memcpy(buf->data + buf->len, s, slen);
        buf->len += slen;
    }
}

internal void
out_char(OutBuf *buf, char c)
{
    if(buf->len + 1 < sizeof(buf->data))
    {
        buf->data[buf->len] = c;
        buf->len += 1;
    }
}

//~ nj: Segment Builder

internal char *
bg_to_fg(char *bg, char *fg_buf, U64 fg_buf_cap)
{
    if(bg == NULL) return "";

    char *src = strstr(bg, "48;2");
    if(src == NULL) return "";

    U64 prefix_len = (U64)(src - bg);
    if(prefix_len + strlen(src) >= fg_buf_cap) return "";

    memcpy(fg_buf, bg, prefix_len);
    fg_buf[prefix_len] = '3';
    fg_buf[prefix_len + 1] = '8';
    strcpy(fg_buf + prefix_len + 2, src + 2);
    return fg_buf;
}

internal void
segment(OutBuf *buf, char *bg, char *fg, char *text, B32 first)
{
    char fg_buf[64];

    if(!first && buf->prev_bg != NULL)
    {
        out_str(buf, bg);
        out_str(buf, bg_to_fg(buf->prev_bg, fg_buf, sizeof(fg_buf)));
        out_str(buf, SEP_CHAR);
        out_str(buf, ANSI_RESET);
    }

    out_str(buf, bg);
    out_str(buf, fg);
    out_char(buf, ' ');
    out_str(buf, text);
    out_char(buf, ' ');
    out_str(buf, ANSI_RESET);

    buf->prev_bg = bg;
}

internal void
segment_end(OutBuf *buf)
{
    char fg_buf[64];
    if(buf->prev_bg != NULL)
    {
        out_str(buf, bg_to_fg(buf->prev_bg, fg_buf, sizeof(fg_buf)));
        out_str(buf, SEP_CHAR);
        out_str(buf, ANSI_RESET);
    }
}

//~ nj: JSON Parsing (Minimal)

internal Str8
json_get_string(char *json, char *key)
{
    Str8 result = {0};

    char needle[256];
    snprintf(needle, sizeof(needle), "\"%s\":\"", key);

    char *start = strstr(json, needle);
    if(start == NULL) return result;

    start += strlen(needle);
    char *end = strchr(start, '"');
    if(end == NULL) return result;

    result.data = (U8*)start;
    result.size = (U64)(end - start);
    return result;
}

internal S64
json_get_number(char *json, char *key)
{
    char needle[256];
    snprintf(needle, sizeof(needle), "\"%s\":", key);

    char *start = strstr(json, needle);
    if(start == NULL) return 0;

    start += strlen(needle);
    while(*start == ' ') start += 1;

    return strtoll(start, NULL, 10);
}

internal double
json_get_float(char *json, char *key)
{
    char needle[256];
    snprintf(needle, sizeof(needle), "\"%s\":", key);

    char *start = strstr(json, needle);
    if(start == NULL) return 0.0;

    start += strlen(needle);
    while(*start == ' ') start += 1;

    return strtod(start, NULL);
}

//~ nj: Path Abbreviation

internal void
abbrev_path(char *path, char *out, U64 out_cap)
{
    char *home = getenv("HOME");
    U64 home_len = home ? strlen(home) : 0;

    char buf[1024];
    if(home && strncmp(path, home, home_len) == 0)
    {
        buf[0] = '~';
        strcpy(buf + 1, path + home_len);
    }
    else
    {
        U64 len = strlen(path);
        memcpy(buf, path, Min(len, sizeof(buf) - 1));
        buf[Min(len, sizeof(buf) - 1)] = '\0';
    }

    U64 slash_count = 0;
    for(char *p = buf; *p; p += 1) if(*p == '/') slash_count += 1;

    if(strcmp(buf, "~") == 0 || slash_count == 0)
    {
        U64 len = strlen(buf);
        memcpy(out, buf, Min(len, out_cap - 1));
        out[Min(len, out_cap - 1)] = '\0';
        return;
    }

    char *parts[64];
    U64 part_count = 0;
    char *tok = strtok(buf, "/");
    while(tok && part_count < ArrayCount(parts))
    {
        parts[part_count] = tok;
        part_count += 1;
        tok = strtok(NULL, "/");
    }

    out[0] = '\0';
    for(U64 i = 0; i < part_count; i += 1)
    {
        if(i > 0) strcat(out, "/");

        if(i < part_count - 1 && parts[i][0] != '~')
        {
            char abbr[2] = {parts[i][0], '\0'};
            strcat(out, abbr);
        }
        else
        {
            strcat(out, parts[i]);
        }
    }
}

//~ nj: Progress Bar

internal void
make_progress_bar(S64 pct, char *out, U64 out_cap)
{
    pct = ClampTop(pct, 100);
    S64 filled = pct / 10;
    S64 empty = 10 - filled;

    char *color = ANSI_FG_GREEN;
    if(pct >= 90)      color = ANSI_FG_RED;
    else if(pct >= 80) color = ANSI_FG_ORANGE;
    else if(pct >= 50) color = ANSI_FG_YELLOW;

    char bar[64] = "";
    for(S64 i = 0; i < filled; i += 1) strcat(bar, "\xe2\x96\x88");
    for(S64 i = 0; i < empty; i += 1)  strcat(bar, "\xe2\x96\x91");

    snprintf(out, out_cap, "%s%s %lld%%", color, bar, (long long)pct);
}

//~ nj: Git Status Types

typedef struct GitStatus GitStatus;
struct GitStatus
{
    B32  valid;
    B32  queried;  // Query completed (even if no repo)
    char branch[128];
    S64  staged;
    S64  unstaged;
    S64  untracked;
    S64  conflicted;
    S64  ahead;
    S64  behind;
    S64  stashes;
    char action[32];
};

typedef struct GitQueryJob GitQueryJob;
struct GitQueryJob
{
    char      dir[512];
    GitStatus result;
    U64       time_us;  // Query duration
};

//~ nj: Fast Branch Reader (direct .git/HEAD read, no daemon)

internal B32
git_read_branch_fast(char *dir, char *branch_out, U64 branch_cap)
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

    // Remove trailing newline
    if(n > 0 && buf[n-1] == '\n') buf[n-1] = '\0';

    // Parse "ref: refs/heads/branch-name"
    char *prefix = "ref: refs/heads/";
    if(strncmp(buf, prefix, strlen(prefix)) == 0)
    {
        char *branch = buf + strlen(prefix);
        U64 len = strlen(branch);
        memcpy(branch_out, branch, Min(len, branch_cap - 1));
        branch_out[Min(len, branch_cap - 1)] = '\0';
        return true;
    }

    // Detached HEAD - show short hash
    if(n >= 7)
    {
        memcpy(branch_out, buf, Min(7, branch_cap - 1));
        branch_out[Min(7, branch_cap - 1)] = '\0';
        return true;
    }

    return false;
}

//~ nj: Gitstatus Daemon Query (runs in separate thread)

internal void *
gitstatus_query_thread(void *arg)
{
    GitQueryJob *job = (GitQueryJob*)arg;
    GitStatus *out = &job->result;
    U64 t0 = time_us();

    memset(out, 0, sizeof(*out));

    // Find gitstatus FIFO
    char pattern[256];
    uid_t uid = getuid();
    snprintf(pattern, sizeof(pattern), "/tmp/gitstatus.CLAUDE_STATUSLINE.%d", uid);

    char req_fifo[512], resp_fifo[512];
    snprintf(req_fifo, sizeof(req_fifo), "%s.req", pattern);
    snprintf(resp_fifo, sizeof(resp_fifo), "%s.resp", pattern);

    // Check if FIFOs exist (fast path: daemon not running)
    struct stat st;
    if(stat(req_fifo, &st) != 0 || stat(resp_fifo, &st) != 0)
    {
        out->queried = true;
        job->time_us = time_us() - t0;
        return NULL;
    }

    // Open response FIFO first (before sending request) to avoid race
    int resp_fd = open(resp_fifo, O_RDONLY | O_NONBLOCK);
    if(resp_fd < 0)
    {
        out->queried = true;
        job->time_us = time_us() - t0;
        return NULL;
    }

    // Build and send request
    char req[1024];
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    U64 req_id = (U64)ts.tv_sec * 1000000 + (U64)ts.tv_nsec / 1000;
    snprintf(req, sizeof(req), "%llu\x1f%s\x1f" "0\x1e", (unsigned long long)req_id, job->dir);

    int req_fd = open(req_fifo, O_WRONLY | O_NONBLOCK);
    if(req_fd < 0)
    {
        close(resp_fd);
        out->queried = true;
        job->time_us = time_us() - t0;
        return NULL;
    }

    ssize_t written = write(req_fd, req, strlen(req));
    close(req_fd);
    if(written < 0)
    {
        close(resp_fd);
        out->queried = true;
        job->time_us = time_us() - t0;
        return NULL;
    }

    char resp[4096] = {0};
    U64 resp_len = 0;

    // Use poll() for efficient waiting (max 50ms total)
    struct pollfd pfd = {.fd = resp_fd, .events = POLLIN};
    while(resp_len < sizeof(resp) - 1)
    {
        int ready = poll(&pfd, 1, 50);
        if(ready <= 0) break;  // Timeout or error

        ssize_t n = read(resp_fd, resp + resp_len, sizeof(resp) - resp_len - 1);
        if(n <= 0) break;

        resp_len += (U64)n;
        if(strchr(resp, '\x1e')) break;
    }
    close(resp_fd);

    out->queried = true;

    if(resp_len == 0)
    {
        job->time_us = time_us() - t0;
        return NULL;
    }

    // Parse response
    char *fields[32];
    U64 field_count = 0;
    char *p = resp;
    fields[field_count] = p;
    field_count += 1;

    while(*p && field_count < ArrayCount(fields))
    {
        if(*p == '\x1f' || *p == '\x1e')
        {
            *p = '\0';
            if(*(p+1) && *(p+1) != '\x1e')
            {
                fields[field_count] = p + 1;
                field_count += 1;
            }
        }
        p += 1;
    }

    if(field_count < 5 || strcmp(fields[1], "1") != 0)
    {
        job->time_us = time_us() - t0;
        return NULL;
    }

    // Gitstatus protocol fields (0-indexed):
    // 0=req_id, 1=status, 2=workdir, 3=.git, 4=HEAD, 5=branch, 6=upstream,
    // 7=remote_url, 8=action, 9=index_size, 10=staged, 11=unstaged,
    // 12=conflicted, 13=untracked, 14=ahead, 15=behind, 16=stashes

    out->valid = true;
    if(field_count > 5)
    {
        U64 branch_len = strlen(fields[5]);
        memcpy(out->branch, fields[5], Min(branch_len, sizeof(out->branch) - 1));
        out->branch[Min(branch_len, sizeof(out->branch) - 1)] = '\0';
    }

    if(field_count > 10) out->staged     = strtoll(fields[10], NULL, 10);
    if(field_count > 11) out->unstaged   = strtoll(fields[11], NULL, 10);
    if(field_count > 12) out->conflicted = strtoll(fields[12], NULL, 10);
    if(field_count > 13) out->untracked  = strtoll(fields[13], NULL, 10);
    if(field_count > 14) out->ahead      = strtoll(fields[14], NULL, 10);
    if(field_count > 15) out->behind     = strtoll(fields[15], NULL, 10);
    if(field_count > 16) out->stashes    = strtoll(fields[16], NULL, 10);

    if(field_count > 8)
    {
        U64 action_len = strlen(fields[8]);
        if(action_len > 0)
        {
            memcpy(out->action, fields[8], Min(action_len, sizeof(out->action) - 1));
            out->action[Min(action_len, sizeof(out->action) - 1)] = '\0';
        }
    }

    job->time_us = time_us() - t0;
    return NULL;
}

//~ nj: Git Segment Builder

internal void
build_git_segment(OutBuf *buf, GitStatus *gs)
{
    if(!gs->valid) return;

    char text[256];
    char *p = text;

    p += sprintf(p, "\xef\x90\xa6 %s", gs->branch);

    if(gs->ahead > 0)  p += sprintf(p, " \xe2\x86\x91%lld", (long long)gs->ahead);
    if(gs->behind > 0) p += sprintf(p, " \xe2\x86\x93%lld", (long long)gs->behind);

    char *bg = ANSI_BG_GREEN;
    if(gs->conflicted > 0)
    {
        bg = ANSI_BG_RED;
    }
    else if(gs->staged > 0 || gs->unstaged > 0 || gs->untracked > 0)
    {
        bg = ANSI_BG_ORANGE;
    }

    segment(buf, bg, ANSI_FG_BLACK, text, false);

    if(gs->staged > 0 || gs->unstaged > 0 || gs->untracked > 0 || gs->stashes > 0)
    {
        char status[128];
        char *s = status;

        if(gs->staged > 0)    s += sprintf(s, "\xe2\x9c\x93%lld ", (long long)gs->staged);
        if(gs->unstaged > 0)  s += sprintf(s, "\xe2\x9c\x8e%lld ", (long long)gs->unstaged);
        if(gs->untracked > 0) s += sprintf(s, "+%lld ", (long long)gs->untracked);
        if(gs->stashes > 0)   s += sprintf(s, "\xe2\x98\xb0%lld", (long long)gs->stashes);

        U64 len = strlen(status);
        if(len > 0 && status[len-1] == ' ') status[len-1] = '\0';

        segment(buf, ANSI_BG_DARK, ANSI_FG_WHITE, status, false);
    }

    if(gs->action[0] != '\0')
    {
        segment(buf, ANSI_BG_RED, ANSI_FG_WHITE, gs->action, false);
    }
}

//~ nj: Main

int
main(int argc, char **argv)
{
    Unused(argc);
    Unused(argv);

    U64 t_start = time_us();


    //~ Phase 1: Quick CWD extract and launch git query thread
    // Read just enough to get current_dir, then launch thread while we read the rest

    char input[8192];
    U64 input_len = 0;

    ssize_t n;
    while((n = read(STDIN_FILENO, input + input_len, sizeof(input) - input_len - 1)) > 0)
    {
        input_len += (U64)n;
    }
    input[input_len] = '\0';

    // Debug: dump input JSON to file when STATUSLINE_DEBUG is set
    if(getenv("STATUSLINE_DEBUG"))
    {
        FILE *dbg = fopen("/tmp/statusline_input.json", "w");
        if(dbg) { fputs(input, dbg); fclose(dbg); }
    }

    U64 t_read = time_us();

    // Extract CWD immediately for git query
    Str8 cwd = json_get_string(input, "current_dir");
    char cwd_str[512] = {0};
    if(cwd.size > 0) memcpy(cwd_str, cwd.data, Min(cwd.size, sizeof(cwd_str)-1));

    // Git query - fast mode (default) or full daemon mode (STATUSLINE_GITSTATUS=1)
    GitQueryJob git_job = {0};
    memcpy(git_job.dir, cwd_str, sizeof(git_job.dir));

    pthread_t git_thread;
    B32 thread_launched = false;
    B32 use_daemon = (getenv("STATUSLINE_GITSTATUS") != NULL);

    if(use_daemon)
    {
        thread_launched = (pthread_create(&git_thread, NULL, gitstatus_query_thread, &git_job) == 0);
    }
    else
    {
        // Fast path: read .git/HEAD directly (branch only, no status counts)
        if(git_read_branch_fast(cwd_str, git_job.result.branch, sizeof(git_job.result.branch)))
        {
            git_job.result.valid = true;
            git_job.result.queried = true;
        }
    }

    //~ Phase 2: Parse JSON while git query runs

    Str8 model = json_get_string(input, "display_name");
    Str8 version = json_get_string(input, "version");
    S64 used_pct = json_get_number(input, "used_percentage");
    double cost_usd = json_get_float(input, "total_cost_usd");
    S64 lines_added = json_get_number(input, "total_lines_added");
    S64 lines_removed = json_get_number(input, "total_lines_removed");

    char model_str[64] = {0};
    char version_str[32] = {0};

    if(model.size > 0) memcpy(model_str, model.data, Min(model.size, sizeof(model_str)-1));
    if(version.size > 0) memcpy(version_str, version.data, Min(version.size, sizeof(version_str)-1));

    U64 t_parse = time_us();

    //~ Phase 3: Build non-git segments

    OutBuf buf = {0};

    segment(&buf, ANSI_BG_PURPLE, ANSI_FG_BLACK, model_str, true);

    char abbrev[256];
    abbrev_path(cwd_str, abbrev, sizeof(abbrev));
    segment(&buf, ANSI_BG_DARK, ANSI_FG_WHITE, abbrev, false);

    //~ Phase 4: Wait for git query and add git segment

    if(thread_launched)
    {
        pthread_join(git_thread, NULL);
    }

    if(git_job.result.valid)
    {
        build_git_segment(&buf, &git_job.result);
    }

    U64 t_git = time_us();

    //~ Phase 5: Remaining segments

    // Cost segment with color coding
    {
        char cost_str[32];
        char *cost_bg = ANSI_BG_MINT;
        if(cost_usd >= 10.0)      cost_bg = ANSI_BG_RED;
        else if(cost_usd >= 5.0)  cost_bg = ANSI_BG_ORANGE;
        else if(cost_usd >= 1.0)  cost_bg = ANSI_BG_CYAN;

        snprintf(cost_str, sizeof(cost_str), "$%.2f", cost_usd);
        segment(&buf, cost_bg, ANSI_FG_BLACK, cost_str, false);
    }

    // Lines changed segment
    if(lines_added > 0 || lines_removed > 0)
    {
        char lines_str[64];
        snprintf(lines_str, sizeof(lines_str),
                 ANSI_FG_GREEN "+%lld " ANSI_FG_RED "-%lld",
                 (long long)lines_added, (long long)lines_removed);
        segment(&buf, ANSI_BG_DARK, "", lines_str, false);
    }

    segment(&buf, ANSI_BG_COMMENT, ANSI_FG_WHITE, version_str, false);

    // Execution time segment
    {
        U64 exec_us = time_us() - t_start;
        char exec_str[32];
        if(exec_us >= 1000)
        {
            snprintf(exec_str, sizeof(exec_str), "%.1fms", exec_us / 1000.0);
        }
        else
        {
            snprintf(exec_str, sizeof(exec_str), "%lluus", (unsigned long long)exec_us);
        }
        segment(&buf, ANSI_BG_DARK, ANSI_FG_COMMENT, exec_str, false);
    }

    char bar[128];
    make_progress_bar(used_pct, bar, sizeof(bar));
    segment(&buf, ANSI_BG_DARK, "", bar, false);

    segment_end(&buf);

    U64 t_end = time_us();

    //~ Output

    buf.data[buf.len] = '\0';
    fputs(buf.data, stdout);

    //~ Timing (to stderr if STATUSLINE_TIMING is set)
    if(getenv("STATUSLINE_TIMING"))
    {
        fprintf(stderr, "timing: read=%lluus parse=%lluus git=%lluus (query=%lluus) build=%lluus total=%lluus\n",
                (unsigned long long)(t_read - t_start),
                (unsigned long long)(t_parse - t_read),
                (unsigned long long)(t_git - t_parse),
                (unsigned long long)git_job.time_us,
                (unsigned long long)(t_end - t_git),
                (unsigned long long)(t_end - t_start));
    }

    return 0;
}
