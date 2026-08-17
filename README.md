# claude-statusline

A fast, width-adaptive statusline for [Claude Code](https://claude.com/claude-code), written in Odin.

One line, right-sized to your terminal: model, path, git branch + dirty counts, PR/CI state, context bar, quota levels, burn rate, and a quota-cap ETA. Everything is cached in `/dev/shm` and refreshed in detached background processes, so a render is ~200µs on a cache hit and never blocks your prompt.

> This repo also contains a legacy C implementation (`statusline.c`, `Makefile.c-legacy`). It is no longer the one being developed — everything below is the Odin workflow.

## Requirements

| Thing | Why | Notes |
|---|---|---|
| [Odin compiler](https://odin-lang.org/docs/install/) | builds the binary | `odin` must be on `PATH` |
| Linux with `/dev/shm` | cache files | macOS/BSD are not supported |
| `git` | branch + status | invoked directly, no shell |
| A Nerd Font + truecolor terminal | icons and Dracula colors | e.g. Ghostty, kitty, WezTerm |
| `gh` (optional) | PR number, review state, CI status | segment is skipped if missing |
| `curl` (optional) | Opus weekly quota window | other quota figures come from Claude Code's own JSON |

## Install

```sh
git clone <this repo> ~/Projects/claude-statusline
cd ~/Projects/claude-statusline
make install-odin
```

That builds `statusline_odin` and copies it to `~/.claude/statusline`.

Then point Claude Code at it — in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline"
  }
}
```

Start a new Claude Code session (or `/config`-reload) and the line appears.

### Build without installing

```sh
make odin     # produces ./statusline_odin
make clean
```

Build flags are `-o:speed -no-bounds-check -disable-assert -microarch:native`.

If `odin build` complains it cannot find the `base` collection, the Makefile already resolves `ODIN_ROOT` via `odin root` and falls back to `/usr/lib/odin`, `/usr/share/odin`, `~/Odin`, `~/odin`. Set `ODIN_ROOT` yourself if your install lives somewhere else:

```sh
make install-odin ODIN_ROOT=/path/to/odin
```

## Auto-update

`make install-odin` writes the repo path to `~/.claude/statusline-src`. Once every 24h the statusline detaches a background process that runs `git pull --ff-only` and `make install-odin` in that directory, so a `git push` to your own copy propagates on its own.

To disable it, delete the pointer file:

```sh
rm ~/.claude/statusline-src
```

## Verify it works

Render against synthetic JSON:

```sh
echo '{"current_dir":"'$PWD'","display_name":"Opus 5","total_duration_ms":120000}' | ./statusline_odin
```

Check the layout logic at six terminal widths across five scenarios:

```sh
./statusline_odin --demo
```

Compare C vs Odin output side by side:

```sh
make bench
```

## What's on the line

Segments are priority-ranked. When the terminal is narrow they shrink through
predefined stages (full → abbreviated → icon-only) and low-priority ones drop
entirely, so the line never wraps.

- **model** — abbreviated name, plus a brain glyph when extended thinking is on
- **path** — abbreviated cwd; elided to `…` when the directory name duplicates the branch
- **branch** — green when clean, orange when dirty; worktrees get their own icon
- **git counters** — ahead/behind, staged, modified, untracked, stashes
- **PR** — number (OSC8-hyperlinked), CI glyph; review state rides in the background color
- **context bar** — 10-cell → 5-cell → bare percentage, with a `CTX HIGH` / `COMPACT NOW` banner past 88% / 94%
- **quota** — 5h and 7d levels, colored by *projected* end-of-window usage; Opus weekly appears above 50%
- **reset** — countdown to the next window reset
- **burn** — tokens per minute
- **ETA** — time until the 5h window hits 100% at the current pace

## Environment variables

| Variable | Effect |
|---|---|
| `STATUSLINE_DEBUG` | set to anything to write timing logs to `/tmp/statusline-<uid>/<pid>.log` |
| `COLUMNS` | override the detected terminal width (otherwise `ioctl`, falling back to 120) |

## Cache files

All caches are self-invalidating and cleaned up periodically; deleting them is always safe.

```
/dev/shm/statusline-cache.<gppid>   per-session state (flicker prevention)
/dev/shm/statusline-usage-shared    account-wide quota cache
/dev/shm/statusline-cleanup.<uid>   cleanup-interval sentinel
/dev/shm/claude-git-<hash>          per-repo git status
/dev/shm/claude-pr-<hash>           per-worktree+branch PR/CI status
```

## Uninstall

```sh
rm ~/.claude/statusline ~/.claude/statusline-src ~/.claude/statusline-last-update
rm -f /dev/shm/statusline-* /dev/shm/claude-git-* /dev/shm/claude-pr-*
```

and remove the `statusLine` block from `~/.claude/settings.json`.
