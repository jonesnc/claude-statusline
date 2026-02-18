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
time_microseconds(void)
{
    struct timespec timestamp;
    clock_gettime(CLOCK_MONOTONIC, &timestamp);
    return (U64)timestamp.tv_sec * 1000000 + (U64)timestamp.tv_nsec / 1000;
}

internal S64
time_milliseconds_realtime(void)
{
    struct timespec timestamp;
    clock_gettime(CLOCK_REALTIME, &timestamp);
    return (S64)timestamp.tv_sec * 1000 + (S64)timestamp.tv_nsec / 1000000;
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

typedef struct Output_Buffer Output_Buffer;
struct Output_Buffer
{
    char       data[4096];
    U64        length;
    const char *previous_background;
    U64        previous_background_length;
};

internal void
output_string(Output_Buffer *buffer, const char *string, U64 string_length)
{
    if(buffer->length + string_length < sizeof(buffer->data))
    {
        memcpy(buffer->data + buffer->length, string, string_length);
        buffer->length += string_length;
    }
}

// For compile-time-known string literals: avoids strlen
#define output_literal(buffer, string) output_string(buffer, string, sizeof(string) - 1)

internal void
output_char(Output_Buffer *buffer, char character)
{
    if(buffer->length + 1 < sizeof(buffer->data))
    {
        buffer->data[buffer->length] = character;
        buffer->length += 1;
    }
}

//~ Hand-Rolled Formatters (replaces snprintf on hot path)

internal int
format_u64(char *output, U64 value)
{
    if(value == 0) { output[0] = '0'; return 1; }
    char digits[20];
    int length = 0;
    while(value > 0) { digits[length++] = '0' + (char)(value % 10); value /= 10; }
    for(int index = 0; index < length; index++) output[index] = digits[length - 1 - index];
    return length;
}

internal int
format_s64(char *output, S64 value)
{
    if(value < 0) { output[0] = '-'; return 1 + format_u64(output + 1, (U64)(-value)); }
    return format_u64(output, (U64)value);
}

internal int
format_u32(char *output, U32 value)
{
    return format_u64(output, (U64)value);
}

// Format double with N decimal places (0, 1, or 2)
internal int
format_f64(char *output, double value, int decimals)
{
    int position = 0;
    if(value < 0) { output[position++] = '-'; value = -value; }

    // Multiply to get fixed-point
    U64 multiplier = 1;
    for(int index = 0; index < decimals; index++) multiplier *= 10;
    U64 fixed = (U64)(value * multiplier + 0.5);
    U64 whole = fixed / multiplier;
    U64 fraction = fixed % multiplier;

    position += format_u64(output + position, whole);

    if(decimals > 0)
    {
        output[position++] = '.';
        // Pad with leading zeros
        for(int digit_index = decimals - 1; digit_index > 0; digit_index--)
        {
            U64 divisor = 1;
            for(int inner = 0; inner < digit_index; inner++) divisor *= 10;
            if(fraction < divisor) output[position++] = '0';
        }
        if(fraction > 0) position += format_u64(output + position, fraction);
    }
    return position;
}

// Append a formatted number directly into Output_Buffer
internal void
output_u64(Output_Buffer *buffer, U64 value)
{
    char temp[20];
    int length = format_u64(temp, value);
    output_string(buffer, temp, length);
}

internal void
output_f64(Output_Buffer *buffer, double value, int decimals)
{
    char temp[32];
    int length = format_f64(temp, value, decimals);
    output_string(buffer, temp, length);
}

//~ Segment Builder

// All ANSI BG strings have format \x1b[48;2;R;G;Bm
// FG equivalent is \x1b[38;2;R;G;Bm (just change byte 2: '4' -> '3')
internal void
background_to_foreground(const char *background, U64 background_length,
                         char *foreground_output, U64 *foreground_length_output)
{
    if(background == NULL || background_length == 0 || background_length >= 64)
    {
        *foreground_length_output = 0;
        return;
    }
    memcpy(foreground_output, background, background_length);
    foreground_output[2] = '3';  // 48;2 -> 38;2
    *foreground_length_output = background_length;
}

internal void
segment(Output_Buffer *buffer, const char *background, U64 background_length,
        const char *foreground, U64 foreground_length,
        const char *text, U64 text_length, B32 first)
{
    if(!first && buffer->previous_background != NULL)
    {
        char foreground_temp[64];
        U64 foreground_temp_length;
        background_to_foreground(buffer->previous_background,
                                 buffer->previous_background_length,
                                 foreground_temp, &foreground_temp_length);

        output_string(buffer, background, background_length);
        output_string(buffer, foreground_temp, foreground_temp_length);
        output_literal(buffer, SEP_ROUND);
        output_literal(buffer, ANSI_RESET);
    }

    output_string(buffer, background, background_length);
    output_string(buffer, foreground, foreground_length);
    output_char(buffer, ' ');
    output_string(buffer, text, text_length);
    output_char(buffer, ' ');
    output_literal(buffer, ANSI_RESET);

    buffer->previous_background = background;
    buffer->previous_background_length = background_length;
}

// Convenience: segment with string literal background/foreground, runtime text
#define segment_literal(buffer, background, foreground, text, text_length, first) \
    segment(buffer, background, sizeof(background)-1, foreground, sizeof(foreground)-1, text, text_length, first)

// Convenience: segment with string literal background, empty foreground, runtime text
#define segment_no_foreground(buffer, background, text, text_length, first) \
    segment(buffer, background, sizeof(background)-1, "", 0, text, text_length, first)

internal void
segment_end(Output_Buffer *buffer)
{
    if(buffer->previous_background != NULL)
    {
        char foreground_temp[64];
        U64 foreground_temp_length;
        background_to_foreground(buffer->previous_background,
                                 buffer->previous_background_length,
                                 foreground_temp, &foreground_temp_length);
        output_string(buffer, foreground_temp, foreground_temp_length);
        output_literal(buffer, SEP_ROUND);
        output_literal(buffer, ANSI_RESET);
    }
}

//~ Single-Pass JSON Parser

typedef struct Json_Parsed_Fields Json_Parsed_Fields;
struct Json_Parsed_Fields
{
    const char *current_dir;      U64 current_dir_length;
    const char *display_name;     U64 display_name_length;
    const char *mode;             U64 mode_length;
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

// Parse a JSON string value at current position (cursor points past ':')
// Returns pointer into json, sets *length. Advances *cursor past closing quote.
internal const char *
parse_json_string(const char **cursor, U64 *length)
{
    const char *scanner = *cursor;
    while(*scanner == ' ' || *scanner == '\t') scanner++;
    if(*scanner != '"') { *length = 0; return NULL; }
    scanner++;
    const char *start = scanner;
    while(*scanner && *scanner != '"') scanner++;
    *length = (U64)(scanner - start);
    if(*scanner == '"') scanner++;
    *cursor = scanner;
    return start;
}

// Parse a JSON number at current position (cursor points past ':')
internal S64
parse_json_s64(const char **cursor)
{
    const char *scanner = *cursor;
    while(*scanner == ' ' || *scanner == '\t') scanner++;
    S64 value = strtoll(scanner, (char **)&scanner, 10);
    *cursor = scanner;
    return value;
}

internal double
parse_json_f64(const char **cursor)
{
    const char *scanner = *cursor;
    while(*scanner == ' ' || *scanner == '\t') scanner++;
    double value = strtod(scanner, (char **)&scanner);
    *cursor = scanner;
    return value;
}

// Match a key at position. Returns length of key if matched, 0 otherwise.
#define TRY_KEY(position, key) \
    (memcmp(position, key, sizeof(key)-1) == 0 ? sizeof(key)-1 : 0)

internal void
json_parse_all(const char *json, Json_Parsed_Fields *fields)
{
    memset(fields, 0, sizeof(*fields));
    const char *cursor = json;

    while(*cursor)
    {
        // Scan for next '"'
        while(*cursor && *cursor != '"') cursor++;
        if(*cursor == 0) break;

        U64 key_length;

        // Dispatch on first char after '"' for fast rejection
        switch(cursor[1])
        {
        case 'c':
            if((key_length = TRY_KEY(cursor, KEY_CURRENT_DIR)))
            {
                cursor += key_length;
                fields->current_dir = parse_json_string(&cursor, &fields->current_dir_length);
                continue;
            }
            if((key_length = TRY_KEY(cursor, KEY_CTX_SIZE)))
            {
                cursor += key_length;
                fields->context_window_size = parse_json_s64(&cursor);
                continue;
            }
            break;

        case 'd':
            if((key_length = TRY_KEY(cursor, KEY_DISPLAY_NAME)))
            {
                cursor += key_length;
                fields->display_name = parse_json_string(&cursor, &fields->display_name_length);
                continue;
            }
            break;

        case 'm':
            if((key_length = TRY_KEY(cursor, KEY_MODE)))
            {
                cursor += key_length;
                fields->mode = parse_json_string(&cursor, &fields->mode_length);
                continue;
            }
            break;

        case 't':
            if((key_length = TRY_KEY(cursor, KEY_TOTAL_COST_USD)))
            {
                cursor += key_length;
                fields->total_cost_usd = parse_json_f64(&cursor);
                continue;
            }
            if((key_length = TRY_KEY(cursor, KEY_LINES_ADDED)))
            {
                cursor += key_length;
                fields->total_lines_added = parse_json_s64(&cursor);
                continue;
            }
            if((key_length = TRY_KEY(cursor, KEY_LINES_REMOVED)))
            {
                cursor += key_length;
                fields->total_lines_removed = parse_json_s64(&cursor);
                continue;
            }
            if((key_length = TRY_KEY(cursor, KEY_DURATION_MS)))
            {
                cursor += key_length;
                fields->total_duration_ms = parse_json_s64(&cursor);
                continue;
            }
            break;

        case 'u':
            if((key_length = TRY_KEY(cursor, KEY_USED_PCT)))
            {
                cursor += key_length;
                fields->used_percentage = parse_json_s64(&cursor);
                continue;
            }
            break;
        }

        // Not a key we care about — skip past this '"'
        cursor++;
    }
}

//~ Path Abbreviation

internal U64
abbreviate_path(const char *path, char *output, U64 output_capacity)
{
    const char *home = getenv("HOME");
    U64 home_length = home ? strlen(home) : 0;

    // Working buffer: substitute ~ for HOME prefix
    char working[512];
    U64 working_length;
    if(home && home_length > 0 && strncmp(path, home, home_length) == 0)
    {
        working[0] = '~';
        U64 rest_length = strlen(path + home_length);
        U64 copy_length = Min(rest_length, sizeof(working) - 2);
        memcpy(working + 1, path + home_length, copy_length);
        working_length = 1 + copy_length;
        working[working_length] = '\0';
    }
    else
    {
        working_length = strlen(path);
        U64 copy_length = Min(working_length, sizeof(working) - 1);
        memcpy(working, path, copy_length);
        working_length = copy_length;
        working[working_length] = '\0';
    }

    if(working_length <= 1 || memchr(working, '/', working_length) == NULL)
    {
        U64 copy_length = Min(working_length, output_capacity - 1);
        memcpy(output, working, copy_length);
        output[copy_length] = '\0';
        return copy_length;
    }

    // Walk the string: abbreviate all components except the last to first char
    U64 output_position = 0;
    U64 scan_position = 0;

    // Find the last '/' to know where the final component starts
    U64 last_slash = 0;
    for(U64 search_index = 0; search_index < working_length; search_index++)
        if(working[search_index] == '/') last_slash = search_index;

    while(scan_position < working_length && output_position < output_capacity - 1)
    {
        if(scan_position > 0 && working[scan_position] == '/')
        {
            output[output_position++] = '/';
            scan_position++;
            continue;
        }

        // Find end of this component
        U64 component_start = scan_position;
        while(scan_position < working_length && working[scan_position] != '/') scan_position++;
        U64 component_length = scan_position - component_start;

        if(component_start < last_slash && working[component_start] != '~')
        {
            // Abbreviate: just first char
            if(output_position < output_capacity - 1)
                output[output_position++] = working[component_start];
        }
        else
        {
            // Last component or ~: copy fully
            U64 copy_length = Min(component_length, output_capacity - 1 - output_position);
            memcpy(output + output_position, working + component_start, copy_length);
            output_position += copy_length;
        }
    }
    output[output_position] = '\0';
    return output_position;
}

//~ Context Bar Builder (snprintf-free)

internal U64
make_context_bar(S64 percent, S64 context_size, char *output, U64 output_capacity)
{
    S64 clamped = Min(percent, 100);
    int width = 10;
    int filled = (int)(clamped * width / 100);
    int empty = width - filled;

    const char *fill_color;
    U64 fill_color_length;
    if(clamped >= 90)      { fill_color = ANSI_FG_RED;    fill_color_length = sizeof(ANSI_FG_RED)-1; }
    else if(clamped >= 80) { fill_color = ANSI_FG_ORANGE; fill_color_length = sizeof(ANSI_FG_ORANGE)-1; }
    else if(clamped >= 50) { fill_color = ANSI_FG_YELLOW; fill_color_length = sizeof(ANSI_FG_YELLOW)-1; }
    else                   { fill_color = ANSI_FG_GREEN;  fill_color_length = sizeof(ANSI_FG_GREEN)-1; }

    char *cursor = output;
    char *buffer_end = output + output_capacity - 1;

    // Fill color
    memcpy(cursor, fill_color, fill_color_length); cursor += fill_color_length;

    // Used tokens label: Nk
    S64 used_tokens = percent * context_size / 100;
    S64 used_thousands = (used_tokens + 500) / 1000;
    cursor += format_s64(cursor, used_thousands);
    *cursor++ = 'k'; *cursor++ = ' ';

    // Left cap
    memcpy(cursor, UTF8_LCAP, 3); cursor += 3;

    // Filled bars
    for(int bar_index = 0; bar_index < filled && cursor + 3 <= buffer_end; bar_index++)
    { memcpy(cursor, UTF8_FILL, 3); cursor += 3; }

    // Percentage
    *cursor++ = ' ';
    cursor += format_s64(cursor, clamped);
    *cursor++ = '%'; *cursor++ = ' ';

    // Comment color for empty portion
    memcpy(cursor, ANSI_FG_COMMENT, sizeof(ANSI_FG_COMMENT)-1);
    cursor += sizeof(ANSI_FG_COMMENT)-1;

    // Empty bars
    for(int bar_index = 0; bar_index < empty && cursor + 3 <= buffer_end; bar_index++)
    { memcpy(cursor, UTF8_EMPTY, 3); cursor += 3; }

    // Right cap
    memcpy(cursor, UTF8_RCAP, 3); cursor += 3;

    // Total context label in fill color
    memcpy(cursor, fill_color, fill_color_length); cursor += fill_color_length;
    *cursor++ = ' ';
    if(context_size >= 1000000)
    {
        cursor += format_s64(cursor, context_size / 1000000);
        *cursor++ = 'M';
    }
    else
    {
        cursor += format_s64(cursor, context_size / 1000);
        *cursor++ = 'k';
    }

    *cursor = '\0';
    return (U64)(cursor - output);
}

//~ Duration Formatting (snprintf-free)

internal U64
format_duration(S64 milliseconds, char *output)
{
    char *cursor = output;

    if(milliseconds < 1000)
    {
        cursor += format_s64(cursor, milliseconds);
        *cursor++ = 'm'; *cursor++ = 's';
    }
    else if(milliseconds < 60000)
    {
        cursor += format_f64(cursor, milliseconds / 1000.0, 1);
        *cursor++ = 's';
    }
    else if(milliseconds < 3600000)
    {
        cursor += format_s64(cursor, milliseconds / 60000);
        *cursor++ = 'm';
        cursor += format_s64(cursor, (milliseconds % 60000) / 1000);
        *cursor++ = 's';
    }
    else
    {
        cursor += format_s64(cursor, milliseconds / 3600000);
        *cursor++ = 'h';
        cursor += format_s64(cursor, (milliseconds % 3600000) / 60000);
        *cursor++ = 'm';
    }
    *cursor = '\0';
    return (U64)(cursor - output);
}

//~ Git Status

enum Cache_State { CACHE_NONE, CACHE_STALE, CACHE_VALID };

typedef struct Git_Status Git_Status;
struct Git_Status
{
    B32  valid;
    char branch[128];
    S64  stashes;
    U32  modified;
    U32  staged;
    U32  ahead;
    U32  behind;
    enum Cache_State cache_state;
};

internal S64
git_read_stash_count(const char *repo_directory)
{
    char path[512];
    snprintf(path, sizeof(path), "%s/.git/logs/refs/stash", repo_directory);

    int file_desc = open(path, O_RDONLY);
    if(file_desc < 0) return 0;

    char buffer[4096];
    S64 count = 0;
    for(;;)
    {
        ssize_t bytes_read = read(file_desc, buffer, sizeof(buffer));
        if(bytes_read <= 0) break;
        for(ssize_t index = 0; index < bytes_read; index++)
            if(buffer[index] == '\n') count++;
    }
    close(file_desc);
    return count;
}

internal B32
git_read_branch_fast(const char *repo_directory, char *branch_output, U64 branch_capacity)
{
    char head_path[512];
    snprintf(head_path, sizeof(head_path), "%s/.git/HEAD", repo_directory);

    int file_desc = open(head_path, O_RDONLY);
    if(file_desc < 0) return false;

    char buffer[256];
    ssize_t bytes_read = read(file_desc, buffer, sizeof(buffer) - 1);
    close(file_desc);
    if(bytes_read <= 0) return false;
    buffer[bytes_read] = '\0';

    while(bytes_read > 0 && (buffer[bytes_read-1] == '\n' || buffer[bytes_read-1] == '\r' || buffer[bytes_read-1] == ' '))
        buffer[--bytes_read] = '\0';

    #define REF_PREFIX "ref: refs/heads/"
    if(bytes_read > (ssize_t)(sizeof(REF_PREFIX)-1) && memcmp(buffer, REF_PREFIX, sizeof(REF_PREFIX)-1) == 0)
    {
        const char *branch_name = buffer + sizeof(REF_PREFIX) - 1;
        U64 length = (U64)(bytes_read - (sizeof(REF_PREFIX) - 1));
        U64 copy_length = Min(length, branch_capacity - 1);
        memcpy(branch_output, branch_name, copy_length);
        branch_output[copy_length] = '\0';
        return true;
    }
    #undef REF_PREFIX

    if(bytes_read >= 7)
    {
        U64 copy_length = Min(7, branch_capacity - 1);
        memcpy(branch_output, buffer, copy_length);
        branch_output[copy_length] = '\0';
        return true;
    }

    return false;
}

//~ State Cache

#define CACHE_PATH_PREFIX "/dev/shm/statusline-cache."
#define CLEANUP_INTERVAL_S 300

typedef struct __attribute__((packed)) Cached_State Cached_State;
struct __attribute__((packed)) Cached_State
{
    S64    used_percent;
    S64    context_size;
    double cost_usd;
    S64    lines_added;
    S64    lines_removed;
    S64    duration_ms;
    S64    last_update_sec;
    char   working_directory[256];
    char   model[64];
};

internal int
get_grandparent_pid(void)
{
    pid_t parent_pid = getppid();

    char path[32];
    snprintf(path, sizeof(path), "/proc/%d/status", parent_pid);

    int file_desc = open(path, O_RDONLY);
    if(file_desc < 0) return parent_pid;

    char buffer[1024];
    ssize_t bytes_read = read(file_desc, buffer, sizeof(buffer) - 1);
    close(file_desc);
    if(bytes_read <= 0) return parent_pid;
    buffer[bytes_read] = '\0';

    const char *needle = "PPid:\t";
    char *cursor = strstr(buffer, needle);
    if(cursor == NULL) return parent_pid;

    cursor += 6;  // strlen("PPid:\t")
    return (int)strtol(cursor, NULL, 10);
}

internal void
get_cache_path(char *output, U64 output_capacity)
{
    int grandparent_pid = get_grandparent_pid();
    snprintf(output, output_capacity, "%s%d", CACHE_PATH_PREFIX, grandparent_pid);
}

internal B32
read_cached_state(Cached_State *state)
{
    char path[64];
    get_cache_path(path, sizeof(path));

    int file_desc = open(path, O_RDONLY);
    if(file_desc < 0) return false;

    ssize_t bytes_read = read(file_desc, state, sizeof(Cached_State));
    close(file_desc);
    return bytes_read == sizeof(Cached_State);
}

internal void
write_cached_state(const Cached_State *state)
{
    char path[64];
    get_cache_path(path, sizeof(path));

    int file_desc = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if(file_desc < 0) return;

    write(file_desc, state, sizeof(Cached_State));
    close(file_desc);
}

internal void
cleanup_stale_caches(void)
{
    struct stat stat_info;
    S64 now_milliseconds = time_milliseconds_realtime();
    if(stat("/dev/shm/statusline-cleanup", &stat_info) == 0)
    {
        S64 last_seconds = (S64)stat_info.st_mtim.tv_sec;
        if(now_milliseconds / 1000 - last_seconds < CLEANUP_INTERVAL_S) return;
    }

    int sentinel_file_desc = open("/dev/shm/statusline-cleanup", O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if(sentinel_file_desc >= 0) close(sentinel_file_desc);

    DIR *shared_memory_dir = opendir("/dev/shm");
    if(shared_memory_dir == NULL) return;

    struct dirent *entry;
    while((entry = readdir(shared_memory_dir)) != NULL)
    {
        if(strncmp(entry->d_name, "statusline-cache.", 17) != 0) continue;

        int pid = (int)strtol(entry->d_name + 17, NULL, 10);
        if(pid <= 0) continue;
        if(kill(pid, 0) == 0) continue;

        char remove_path[300];
        snprintf(remove_path, sizeof(remove_path), "/dev/shm/%s", entry->d_name);
        unlink(remove_path);
    }
    closedir(shared_memory_dir);

    uid_t uid = getuid();
    char log_directory[64];
    snprintf(log_directory, sizeof(log_directory), "/tmp/statusline-%d", uid);

    DIR *log_dir_handle = opendir(log_directory);
    if(log_dir_handle == NULL) return;

    while((entry = readdir(log_dir_handle)) != NULL)
    {
        U64 name_length = strlen(entry->d_name);
        if(name_length < 5 || strcmp(entry->d_name + name_length - 4, ".log") != 0)
            continue;

        char pid_string[32];
        U64 copy_length = Min(name_length - 4, sizeof(pid_string) - 1);
        memcpy(pid_string, entry->d_name, copy_length);
        pid_string[copy_length] = '\0';

        int log_pid = (int)strtol(pid_string, NULL, 10);
        if(log_pid <= 0) continue;
        if(kill(log_pid, 0) == 0) continue;

        char remove_path[96];
        snprintf(remove_path, sizeof(remove_path), "%s/%s", log_directory, entry->d_name);
        unlink(remove_path);
    }
    closedir(log_dir_handle);
}

//~ Git Status Cache

typedef struct __attribute__((packed)) Git_Cache Git_Cache;
struct __attribute__((packed)) Git_Cache
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
    U32 hash = 2166136261u;
    for(const char *cursor = path; *cursor; cursor++)
    {
        hash ^= (U32)(unsigned char)*cursor;
        hash *= 16777619u;
    }
    return hash;
}

internal void
get_git_cache_path(const char *repo_path, char *output, U64 output_capacity)
{
    U32 path_hash = hash_path(repo_path);
    snprintf(output, output_capacity, "/dev/shm/claude-git-%08x", path_hash);
}

internal enum Cache_State
read_git_cache(const char *repo_path, Git_Cache *cache)
{
    char cache_path[64];
    get_git_cache_path(repo_path, cache_path, sizeof(cache_path));

    int file_desc = open(cache_path, O_RDONLY);
    if(file_desc < 0) return CACHE_NONE;

    ssize_t bytes_read = read(file_desc, cache, sizeof(Git_Cache));
    if(bytes_read != sizeof(Git_Cache)) { close(file_desc); return CACHE_NONE; }

    if(strncmp(cache->repo_path, repo_path, sizeof(cache->repo_path)) != 0)
    {
        close(file_desc);
        return CACHE_NONE;
    }

    struct stat cache_stat;
    if(fstat(file_desc, &cache_stat) != 0) { close(file_desc); return CACHE_STALE; }
    close(file_desc);

    S64 cache_age_milliseconds = time_milliseconds_realtime() -
        ((S64)cache_stat.st_mtim.tv_sec * 1000 + (S64)cache_stat.st_mtim.tv_nsec / 1000000);
    if(cache_age_milliseconds > GIT_CACHE_TTL_MS) return CACHE_STALE;

    char index_path[512];
    snprintf(index_path, sizeof(index_path), "%s/.git/index", repo_path);
    struct stat index_stat;
    if(stat(index_path, &index_stat) != 0) return CACHE_STALE;

    if((S64)index_stat.st_mtim.tv_sec == cache->index_mtime_sec &&
       (S64)index_stat.st_mtim.tv_nsec == cache->index_mtime_nsec)
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
    struct stat index_stat;
    if(stat(index_path, &index_stat) != 0) return;

    Git_Cache cache;
    memset(&cache, 0, sizeof(cache));
    cache.index_mtime_sec = (S64)index_stat.st_mtim.tv_sec;
    cache.index_mtime_nsec = (S64)index_stat.st_mtim.tv_nsec;
    cache.modified = modified;
    cache.staged = staged;
    cache.ahead = ahead;
    cache.behind = behind;
    strncpy(cache.repo_path, repo_path, sizeof(cache.repo_path) - 1);

    char cache_path[64];
    get_git_cache_path(repo_path, cache_path, sizeof(cache_path));

    int file_desc = open(cache_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if(file_desc < 0) return;
    write(file_desc, &cache, sizeof(cache));
    close(file_desc);
}

internal void
run_git_status(const char *repo_path, U32 *out_modified, U32 *out_staged,
               U32 *out_ahead, U32 *out_behind)
{
    *out_modified = 0;
    *out_staged   = 0;
    *out_ahead    = 0;
    *out_behind   = 0;

    int pipe_fds[2];
    if(pipe(pipe_fds) != 0) return;

    pid_t child_pid = fork();
    if(child_pid < 0)
    {
        close(pipe_fds[0]);
        close(pipe_fds[1]);
        return;
    }

    if(child_pid == 0)
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

    char buffer[4096];
    int total_bytes_read = 0;
    for(;;)
    {
        int remaining = (int)sizeof(buffer) - total_bytes_read;
        if(remaining <= 0) break;
        ssize_t bytes_read = read(pipe_fds[0], buffer + total_bytes_read, remaining);
        if(bytes_read <= 0) break;
        total_bytes_read += (int)bytes_read;
    }
    close(pipe_fds[0]);
    waitpid(child_pid, NULL, 0);

    char *line = buffer;
    char *buffer_end = buffer + total_bytes_read;
    while(line < buffer_end)
    {
        char *newline = memchr(line, '\n', buffer_end - line);
        int line_length = newline ? (int)(newline - line) : (int)(buffer_end - line);
        if(line_length < 2) { line = newline ? newline + 1 : buffer_end; continue; }

        if(line[0] == '#' && line[1] == '#')
        {
            char *bracket = memchr(line, '[', line_length);
            if(bracket)
            {
                char *ahead_match = strstr(bracket, "ahead ");
                if(ahead_match) *out_ahead = (U32)strtol(ahead_match + 6, NULL, 10);
                char *behind_match = strstr(bracket, "behind ");
                if(behind_match) *out_behind = (U32)strtol(behind_match + 7, NULL, 10);
            }
        }
        else
        {
            if(line[0] != ' ' && line[0] != '?') *out_staged += 1;
            if(line[1] != ' ' && line[1] != '?') *out_modified += 1;
        }

        line = newline ? newline + 1 : buffer_end;
    }
}

internal void
get_git_status_cached(const char *repo_path, U32 *modified, U32 *staged,
                      U32 *ahead, U32 *behind, enum Cache_State *state)
{
    Git_Cache cache;
    *state = read_git_cache(repo_path, &cache);

    switch(*state)
    {
    case CACHE_VALID:
        *modified = cache.modified;
        *staged   = cache.staged;
        *ahead    = cache.ahead;
        *behind   = cache.behind;
        return;

    case CACHE_STALE:
        *modified = cache.modified;
        *staged   = cache.staged;
        *ahead    = cache.ahead;
        *behind   = cache.behind;
        {
            pid_t background_pid = fork();
            if(background_pid == 0)
            {
                if(fork() == 0)
                {
                    U32 new_modified, new_staged, new_ahead, new_behind;
                    run_git_status(repo_path, &new_modified, &new_staged, &new_ahead, &new_behind);
                    write_git_cache(repo_path, new_modified, new_staged, new_ahead, new_behind);
                }
                _exit(0);
            }
            if(background_pid > 0) waitpid(background_pid, NULL, 0);
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
truncate_branch(const char *branch, int max_length, U64 *output_length)
{
    static char truncation_buffer[64];
    int length = (int)strlen(branch);
    if(length <= max_length) { *output_length = length; return branch; }

    int copy_length = max_length - 3;
    memcpy(truncation_buffer, branch, copy_length);
    truncation_buffer[copy_length] = '.';
    truncation_buffer[copy_length + 1] = '.';
    truncation_buffer[copy_length + 2] = '.';
    truncation_buffer[copy_length + 3] = '\0';
    *output_length = max_length;
    return truncation_buffer;
}

//~ Git Segment Builder (snprintf-free)

internal void
build_git_segment(Output_Buffer *buffer, Git_Status *git_status)
{
    if(!git_status->valid) return;

    // Branch text: ICON_BRANCH " " + branch name
    char text[256];
    char *cursor = text;
    memcpy(cursor, ICON_BRANCH " ", sizeof(ICON_BRANCH " ") - 1);
    cursor += sizeof(ICON_BRANCH " ") - 1;

    U64 branch_length;
    const char *branch_name = truncate_branch(git_status->branch, 20, &branch_length);
    memcpy(cursor, branch_name, branch_length);
    cursor += branch_length;
    U64 text_length = (U64)(cursor - text);

    const char *background; U64 background_length;
    if(git_status->modified > 0 || git_status->staged > 0)
    { background = ANSI_BG_ORANGE; background_length = sizeof(ANSI_BG_ORANGE)-1; }
    else
    { background = ANSI_BG_GREEN; background_length = sizeof(ANSI_BG_GREEN)-1; }

    segment(buffer, background, background_length, ANSI_FG_BLACK, sizeof(ANSI_FG_BLACK)-1, text, text_length, false);

    // Status counts
    if(git_status->staged > 0 || git_status->modified > 0 || git_status->stashes > 0 ||
       git_status->ahead > 0 || git_status->behind > 0)
    {
        char status_text[256];
        cursor = status_text;

        if(git_status->ahead > 0)
        {
            memcpy(cursor, ANSI_FG_GREEN, sizeof(ANSI_FG_GREEN)-1); cursor += sizeof(ANSI_FG_GREEN)-1;
            memcpy(cursor, UTF8_UP, 3); cursor += 3;
            cursor += format_u32(cursor, git_status->ahead);
            *cursor++ = ' ';
        }
        if(git_status->behind > 0)
        {
            memcpy(cursor, ANSI_FG_RED, sizeof(ANSI_FG_RED)-1); cursor += sizeof(ANSI_FG_RED)-1;
            memcpy(cursor, UTF8_DOWN, 3); cursor += 3;
            cursor += format_u32(cursor, git_status->behind);
            *cursor++ = ' ';
        }
        if(git_status->staged > 0)
        {
            memcpy(cursor, ANSI_FG_GREEN, sizeof(ANSI_FG_GREEN)-1); cursor += sizeof(ANSI_FG_GREEN)-1;
            memcpy(cursor, ICON_STAGED, sizeof(ICON_STAGED)-1); cursor += sizeof(ICON_STAGED)-1;
            cursor += format_u32(cursor, git_status->staged);
            *cursor++ = ' ';
        }
        if(git_status->modified > 0)
        {
            memcpy(cursor, ANSI_FG_ORANGE, sizeof(ANSI_FG_ORANGE)-1); cursor += sizeof(ANSI_FG_ORANGE)-1;
            memcpy(cursor, ICON_MODIFIED, sizeof(ICON_MODIFIED)-1); cursor += sizeof(ICON_MODIFIED)-1;
            cursor += format_u32(cursor, git_status->modified);
            *cursor++ = ' ';
        }
        if(git_status->stashes > 0)
        {
            memcpy(cursor, ANSI_FG_PURPLE, sizeof(ANSI_FG_PURPLE)-1); cursor += sizeof(ANSI_FG_PURPLE)-1;
            memcpy(cursor, ICON_STASH, sizeof(ICON_STASH)-1); cursor += sizeof(ICON_STASH)-1;
            cursor += format_s64(cursor, git_status->stashes);
        }

        // Trim trailing space
        U64 status_length = (U64)(cursor - status_text);
        if(status_length > 0 && status_text[status_length - 1] == ' ') status_length--;

        segment(buffer, ANSI_BG_DARK, sizeof(ANSI_BG_DARK)-1, "", 0, status_text, status_length, false);
    }
}

//~ Display State

typedef struct Display_State Display_State;
struct Display_State
{
    char   working_directory[512];
    char   model[64];
    double cost_usd;
    S64    lines_added;
    S64    lines_removed;
    S64    total_duration_ms;
    S64    used_percent;
    S64    context_size;
    S64    last_update_sec;
    char   vim_mode[32];
};

//~ Stdin Reader

#define STDIN_TIMEOUT_MS 50

internal B32
read_stdin(char *buffer, U64 buffer_capacity, U64 *output_length)
{
    *output_length = 0;
    struct pollfd poll_fd = {.fd = STDIN_FILENO, .events = POLLIN};
    if(poll(&poll_fd, 1, STDIN_TIMEOUT_MS) <= 0) return false;

    // Single read — JSON is <4KB, always arrives atomically via pipe (PIPE_BUF=4096)
    ssize_t bytes_read = read(STDIN_FILENO, buffer, buffer_capacity - 1);
    if(bytes_read <= 0) return false;
    *output_length = (U64)bytes_read;
    buffer[*output_length] = '\0';
    return true;
}

//~ State Resolution (uses single-pass JSON parser)

internal void
resolve_state(const char *input, B32 has_stdin, Display_State *state)
{
    Cached_State cached;
    memset(&cached, 0, sizeof(cached));
    read_cached_state(&cached);

    memset(state, 0, sizeof(*state));

    if(has_stdin)
    {
        Json_Parsed_Fields fields;
        json_parse_all(input, &fields);

        // Copy string fields
        if(fields.current_dir_length > 0)
        {
            U64 cwd_length = Min(fields.current_dir_length, sizeof(state->working_directory) - 1);
            memcpy(state->working_directory, fields.current_dir, cwd_length);
            state->working_directory[cwd_length] = '\0';
        }
        else if(cached.working_directory[0])
            strcpy(state->working_directory, cached.working_directory);

        if(fields.display_name_length > 0)
        {
            U64 model_length = Min(fields.display_name_length, sizeof(state->model) - 1);
            memcpy(state->model, fields.display_name, model_length);
            state->model[model_length] = '\0';
        }
        else if(cached.model[0])
            strcpy(state->model, cached.model);

        if(fields.mode_length > 0)
        {
            U64 vim_mode_length = Min(fields.mode_length, sizeof(state->vim_mode) - 1);
            memcpy(state->vim_mode, fields.mode, vim_mode_length);
            state->vim_mode[vim_mode_length] = '\0';
        }

        state->cost_usd          = fields.total_cost_usd > 0 ? fields.total_cost_usd : cached.cost_usd;
        state->lines_added       = fields.total_lines_added > 0 ? fields.total_lines_added : cached.lines_added;
        state->lines_removed     = fields.total_lines_removed > 0 ? fields.total_lines_removed : cached.lines_removed;
        state->total_duration_ms = fields.total_duration_ms > 0 ? fields.total_duration_ms : cached.duration_ms;
        state->used_percent      = fields.used_percentage > 0 ? fields.used_percentage : cached.used_percent;
        state->context_size      = fields.context_window_size > 0 ? fields.context_window_size : cached.context_size;
        state->last_update_sec   = (S64)time(NULL);

        // Update cache
        Cached_State new_cache;
        new_cache.used_percent  = Max(fields.used_percentage, cached.used_percent);
        new_cache.context_size  = Max(fields.context_window_size, cached.context_size);
        new_cache.cost_usd      = fields.total_cost_usd > cached.cost_usd ? fields.total_cost_usd : cached.cost_usd;
        new_cache.lines_added   = Max(fields.total_lines_added, cached.lines_added);
        new_cache.lines_removed = Max(fields.total_lines_removed, cached.lines_removed);
        new_cache.duration_ms   = Max(fields.total_duration_ms, cached.duration_ms);
        new_cache.last_update_sec = state->last_update_sec;

        memset(new_cache.working_directory, 0, sizeof(new_cache.working_directory));
        memset(new_cache.model, 0, sizeof(new_cache.model));
        if(fields.current_dir_length > 0)
            memcpy(new_cache.working_directory, fields.current_dir, Min(fields.current_dir_length, sizeof(new_cache.working_directory) - 1));
        else
            memcpy(new_cache.working_directory, cached.working_directory, sizeof(new_cache.working_directory));

        if(fields.display_name_length > 0)
            memcpy(new_cache.model, fields.display_name, Min(fields.display_name_length, sizeof(new_cache.model) - 1));
        else
            memcpy(new_cache.model, cached.model, sizeof(new_cache.model));

        if(memcmp(&new_cache, &cached, sizeof(Cached_State)) != 0)
            write_cached_state(&new_cache);
    }
    else
    {
        if(cached.working_directory[0]) strcpy(state->working_directory, cached.working_directory);
        if(cached.model[0]) strcpy(state->model, cached.model);
        state->cost_usd          = cached.cost_usd;
        state->lines_added       = cached.lines_added;
        state->lines_removed     = cached.lines_removed;
        state->total_duration_ms = cached.duration_ms;
        state->used_percent      = cached.used_percent;
        state->context_size      = cached.context_size;
        state->last_update_sec   = cached.last_update_sec;
    }
}

//~ Statusline Builder (snprintf-free)

internal void
build_statusline(Output_Buffer *buffer, Display_State *state, Git_Status *git_status)
{
    B32 first = true;

    // Vim mode
    if(state->vim_mode[0])
    {
        const char *vim_background, *vim_foreground, *vim_icon;
        U64 vim_background_length, vim_foreground_length, vim_icon_length;
        B32 is_insert = (strcmp(state->vim_mode, "INSERT") == 0);
        if(is_insert)
        {
            vim_background = ANSI_BG_GREEN; vim_background_length = sizeof(ANSI_BG_GREEN)-1;
            vim_foreground = ANSI_FG_BLACK; vim_foreground_length = sizeof(ANSI_FG_BLACK)-1;
            vim_icon = ICON_INSERT; vim_icon_length = sizeof(ICON_INSERT)-1;
        }
        else
        {
            vim_background = ANSI_BG_DARK;  vim_background_length = sizeof(ANSI_BG_DARK)-1;
            vim_foreground = ANSI_FG_WHITE; vim_foreground_length = sizeof(ANSI_FG_WHITE)-1;
            vim_icon = ICON_NORMAL; vim_icon_length = sizeof(ICON_NORMAL)-1;
        }

        char vim_text[64];
        char *cursor = vim_text;
        if(is_insert)
        {
            memcpy(cursor, ANSI_BOLD, sizeof(ANSI_BOLD)-1); cursor += sizeof(ANSI_BOLD)-1;
        }
        memcpy(cursor, vim_icon, vim_icon_length); cursor += vim_icon_length;
        *cursor++ = ' ';
        U64 mode_length = strlen(state->vim_mode);
        memcpy(cursor, state->vim_mode, mode_length); cursor += mode_length;

        segment(buffer, vim_background, vim_background_length, vim_foreground, vim_foreground_length, vim_text, (U64)(cursor - vim_text), first);
        first = false;
    }

    // Model (bold)
    {
        char model_text[128];
        memcpy(model_text, ANSI_BOLD, sizeof(ANSI_BOLD)-1);
        U64 model_length = strlen(state->model);
        memcpy(model_text + sizeof(ANSI_BOLD)-1, state->model, model_length);
        U64 text_length = sizeof(ANSI_BOLD)-1 + model_length;

        segment_literal(buffer, ANSI_BG_PURPLE, ANSI_FG_BLACK, model_text, text_length, first);
        first = false;
    }

    // Path
    {
        char path_text[300];
        memcpy(path_text, ICON_FOLDER " ", sizeof(ICON_FOLDER " ")-1);
        U64 prefix_length = sizeof(ICON_FOLDER " ")-1;
        U64 abbreviated_length = abbreviate_path(state->working_directory, path_text + prefix_length, sizeof(path_text) - prefix_length);

        segment_literal(buffer, ANSI_BG_DARK, ANSI_FG_WHITE, path_text, prefix_length + abbreviated_length, false);
    }

    // Git
    if(git_status->valid)
        build_git_segment(buffer, git_status);

    // Cost
    {
        const char *cost_background; U64 cost_background_length;
        if(state->cost_usd >= 10.0)      { cost_background = ANSI_BG_RED;    cost_background_length = sizeof(ANSI_BG_RED)-1;    }
        else if(state->cost_usd >= 5.0)  { cost_background = ANSI_BG_ORANGE; cost_background_length = sizeof(ANSI_BG_ORANGE)-1; }
        else if(state->cost_usd >= 1.0)  { cost_background = ANSI_BG_CYAN;   cost_background_length = sizeof(ANSI_BG_CYAN)-1;   }
        else                             { cost_background = ANSI_BG_MINT;   cost_background_length = sizeof(ANSI_BG_MINT)-1;   }

        char cost_text[64];
        char *cursor = cost_text;
        memcpy(cursor, ICON_DOLLAR " ", sizeof(ICON_DOLLAR " ")-1); cursor += sizeof(ICON_DOLLAR " ")-1;
        cursor += format_f64(cursor, state->cost_usd, 2);

        segment(buffer, cost_background, cost_background_length, ANSI_FG_BLACK, sizeof(ANSI_FG_BLACK)-1,
                cost_text, (U64)(cursor - cost_text), false);
    }

    // Lines changed
    if(state->lines_added > 0 || state->lines_removed > 0)
    {
        char lines_text[128];
        char *cursor = lines_text;
        memcpy(cursor, ANSI_FG_WHITE, sizeof(ANSI_FG_WHITE)-1); cursor += sizeof(ANSI_FG_WHITE)-1;
        memcpy(cursor, ICON_DIFF " ", sizeof(ICON_DIFF " ")-1); cursor += sizeof(ICON_DIFF " ")-1;
        memcpy(cursor, ANSI_FG_GREEN, sizeof(ANSI_FG_GREEN)-1); cursor += sizeof(ANSI_FG_GREEN)-1;
        *cursor++ = '+';
        cursor += format_s64(cursor, state->lines_added);
        *cursor++ = ' ';
        memcpy(cursor, ANSI_FG_RED, sizeof(ANSI_FG_RED)-1); cursor += sizeof(ANSI_FG_RED)-1;
        *cursor++ = '-';
        cursor += format_s64(cursor, state->lines_removed);

        segment_no_foreground(buffer, ANSI_BG_DARK, lines_text, (U64)(cursor - lines_text), false);
    }

    // Session duration + last update time
    if(state->total_duration_ms > 0)
    {
        char duration_text[128];
        char *cursor = duration_text;
        memcpy(cursor, ICON_CLOCK " ", sizeof(ICON_CLOCK " ")-1); cursor += sizeof(ICON_CLOCK " ")-1;
        cursor += format_duration(state->total_duration_ms, cursor);

        if(state->last_update_sec > 0)
        {
            // Faint separator
            memcpy(cursor, " " ANSI_FG_COMMENT "| " ANSI_FG_WHITE, sizeof(" " ANSI_FG_COMMENT "| " ANSI_FG_WHITE)-1);
            cursor += sizeof(" " ANSI_FG_COMMENT "| " ANSI_FG_WHITE)-1;

            time_t update_time = (time_t)state->last_update_sec;
            struct tm local_time;
            localtime_r(&update_time, &local_time);

            int hour12 = local_time.tm_hour % 12;
            if(hour12 == 0) hour12 = 12;
            const char *ampm = local_time.tm_hour < 12 ? " AM" : " PM";

            cursor += format_u64(cursor, (U64)hour12);
            *cursor++ = ':';
            if(local_time.tm_min < 10) *cursor++ = '0';
            cursor += format_u64(cursor, (U64)local_time.tm_min);
            *cursor++ = ':';
            if(local_time.tm_sec < 10) *cursor++ = '0';
            cursor += format_u64(cursor, (U64)local_time.tm_sec);
            memcpy(cursor, ampm, 3); cursor += 3;
        }

        segment_literal(buffer, ANSI_BG_DARK, ANSI_FG_WHITE, duration_text, (U64)(cursor - duration_text), false);
    }

    // Context bar
    {
        char context_bar[512];
        U64 context_bar_length = make_context_bar(state->used_percent, state->context_size, context_bar, sizeof(context_bar));
        segment_no_foreground(buffer, ANSI_BG_DARK, context_bar, context_bar_length, false);
    }

    // Context warnings
    if(state->used_percent >= 80)
    {
        char warning_text[128];
        char *cursor = warning_text;
        const char *warning_background; U64 warning_background_length;

        if(state->used_percent >= 95)
        {
            memcpy(cursor, ANSI_BOLD, sizeof(ANSI_BOLD)-1); cursor += sizeof(ANSI_BOLD)-1;
            memcpy(cursor, ICON_WARN " CRITICAL COMPACT", sizeof(ICON_WARN " CRITICAL COMPACT")-1);
            cursor += sizeof(ICON_WARN " CRITICAL COMPACT")-1;
            warning_background = ANSI_BG_RED; warning_background_length = sizeof(ANSI_BG_RED)-1;
        }
        else if(state->used_percent >= 90)
        {
            memcpy(cursor, ANSI_BOLD, sizeof(ANSI_BOLD)-1); cursor += sizeof(ANSI_BOLD)-1;
            memcpy(cursor, ICON_WARN " LOW CTX COMPACT", sizeof(ICON_WARN " LOW CTX COMPACT")-1);
            cursor += sizeof(ICON_WARN " LOW CTX COMPACT")-1;
            warning_background = ANSI_BG_RED; warning_background_length = sizeof(ANSI_BG_RED)-1;
        }
        else
        {
            memcpy(cursor, ICON_WARN " CTX 80%+", sizeof(ICON_WARN " CTX 80%+")-1);
            cursor += sizeof(ICON_WARN " CTX 80%+")-1;
            warning_background = ANSI_BG_YELLOW; warning_background_length = sizeof(ANSI_BG_YELLOW)-1;
        }

        segment(buffer, warning_background, warning_background_length, ANSI_FG_BLACK, sizeof(ANSI_FG_BLACK)-1,
                warning_text, (U64)(cursor - warning_text), false);
    }

    segment_end(buffer);
}

//~ Debug Logging

internal void
write_debug_log(U64 time_start, U64 time_cleanup, U64 time_read, U64 time_parse,
                U64 time_git, U64 time_build, enum Cache_State cache_state, B32 has_stdin)
{
    U64 time_end = time_microseconds();
    int grandparent_pid = get_grandparent_pid();

    const char *cache_string;
    switch(cache_state)
    {
    case CACHE_VALID: cache_string = "valid"; break;
    case CACHE_STALE: cache_string = "stale"; break;
    case CACHE_NONE:  cache_string = "miss";  break;
    default:          cache_string = "?";     break;
    }

    char line[512];
    int line_length = snprintf(line, sizeof(line),
        "cleanup=%lluus read=%lluus(%s) parse=%lluus git=%lluus(%s) build=%lluus total=%lluus\n",
        (unsigned long long)(time_cleanup - time_start),
        (unsigned long long)(time_read - time_cleanup),
        has_stdin ? "ok" : "timeout",
        (unsigned long long)(time_parse - time_read),
        (unsigned long long)(time_git - time_parse),
        cache_string,
        (unsigned long long)(time_build - time_git),
        (unsigned long long)(time_end - time_start));

    uid_t uid = getuid();
    char directory_path[64];
    snprintf(directory_path, sizeof(directory_path), "/tmp/statusline-%d", uid);
    mkdir(directory_path, 0700);

    char log_path[96];
    snprintf(log_path, sizeof(log_path), "%s/%d.log", directory_path, grandparent_pid);

    int file_desc = open(log_path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if(file_desc >= 0)
    {
        write(file_desc, line, line_length);
        close(file_desc);
    }
}

//~ Main

int
main(void)
{
    U64 time_start = time_microseconds();
    B32 debug = (getenv("STATUSLINE_DEBUG") != NULL);

    cleanup_stale_caches();
    U64 time_cleanup = time_microseconds();

    char input[8192];
    U64 input_length;
    B32 has_stdin = read_stdin(input, sizeof(input), &input_length);
    U64 time_read = time_microseconds();

    Display_State state;
    resolve_state(input, has_stdin, &state);
    U64 time_parse = time_microseconds();

    // Git status
    Git_Status git_status;
    memset(&git_status, 0, sizeof(git_status));
    if(state.working_directory[0] && git_read_branch_fast(state.working_directory, git_status.branch, sizeof(git_status.branch)))
    {
        git_status.valid = true;
        git_status.stashes = git_read_stash_count(state.working_directory);
        get_git_status_cached(state.working_directory, &git_status.modified, &git_status.staged,
                              &git_status.ahead, &git_status.behind, &git_status.cache_state);
    }
    U64 time_git = time_microseconds();

    // Build output
    Output_Buffer output_buffer;
    memset(&output_buffer, 0, sizeof(output_buffer));
    build_statusline(&output_buffer, &state, &git_status);
    U64 time_build = time_microseconds();

    // Timing suffix (render time only)
    U64 time_now = time_microseconds();
    U64 total_microseconds = time_now - time_start;
    output_literal(&output_buffer, "  " ANSI_FG_COMMENT);
    if(total_microseconds >= 1000)
    {
        output_f64(&output_buffer, total_microseconds / 1000.0, 1);
        output_literal(&output_buffer, "ms");
    }
    else
    {
        output_u64(&output_buffer, total_microseconds);
        output_literal(&output_buffer, "us");
    }
    output_literal(&output_buffer, ANSI_RESET);

    write(STDOUT_FILENO, output_buffer.data, output_buffer.length);

    if(debug)
        write_debug_log(time_start, time_cleanup, time_read, time_parse, time_git, time_build, git_status.cache_state, has_stdin);

    return 0;
}
