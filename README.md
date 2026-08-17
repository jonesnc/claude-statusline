# claude-statusline

A fast, width-adaptive statusline for [Claude Code](https://claude.com/claude-code), written in Odin.

One line, right-sized to your terminal: model, path, git branch + dirty counts, PR/CI state, context bar, quota levels, burn rate, and a quota-cap ETA. Everything is cached in `/dev/shm` and refreshed in detached background processes, so a render is ~200µs on a cache hit and never blocks your prompt.

Narrow terminals never wrap. Segments shrink through predefined stages and the lowest-priority ones drop out entirely. `./statusline_odin --demo` renders all five scenarios at six widths with a column ruler, the measured width in brackets, and a `fit:` log naming every shrink and drop it applied — the screenshots below are that output.

**Dirty worktree, PR awaiting review.** Orange branch = uncommitted work; orange PR background = review required. By 132 cols the path, branch and PR have all shrunk; by 80 the duration, reset countdown and ETA are gone.

![--demo: dirty worktree with a PR awaiting review, six widths](docs/screenshots/demo-worktree-pr-awaiting-review.png)

**CI failing, approved.** Review state and CI state are independent and shown independently: green background says approved, the red `✗2` says two checks failed. At 132 cols the PR number goes and the bare red ✗ stays — the failure survives longer than the identity, because it's the part that needs acting on.

![--demo: failing CI on an approved PR, six widths](docs/screenshots/demo-ci-failing-approved.png)

**Clean `main`, no PR.** Green branch, no counters, no PR segment — nothing to report, so nothing takes up space, and the full path survives all the way down to 132 cols.

![--demo: clean main checkout with no PR, six widths](docs/screenshots/demo-clean-main-no-pr.png)

**Context critical, quota over pace.** The bar goes red at 93% and the `CTX HIGH` banner appears; 5h sits at 61% but is colored by *projection*, and the battery ETA says the cap arrives in 2h41m. At 132 cols the banner keeps its slot as a bare icon rather than dropping — it's marked non-droppable.

![--demo: context critical with quota over pace, six widths](docs/screenshots/demo-context-critical-quota-over-pace.png)

**No git repo, vim insert mode.** Outside a repo the branch, counters and PR segments simply don't exist; the green pencil at far left is vim insert mode.

![--demo: no git repo, vim insert mode, six widths](docs/screenshots/demo-no-git-repo-insert-mode.png)

> This repo also contains a legacy C implementation (`statusline.c`, `Makefile.c-legacy`). It is no longer the one being developed — everything below is the Odin workflow.

## Requirements

| Thing | Why | Notes |
|---|---|---|
| [Odin compiler](https://odin-lang.org/docs/install/) | builds the binary | source install only; `odin` must be on `PATH`, and there is no system-wide install on the ITADM box |
| Linux with `/dev/shm` | cache files | macOS/BSD are not supported |
| `git` | branch + status | invoked directly, no shell |
| A Nerd Font + truecolor terminal | icons and Dracula colors | e.g. Ghostty, kitty, WezTerm |
| `gh` (optional) | PR number, review state, CI status | segment is skipped if missing |
| `curl` (optional) | Opus weekly quota window | other quota figures come from Claude Code's own JSON |

## Install

Everyone runs their own copy — install it per developer, not once for the box, so you're free to modify your own. Pick whichever option fits; both end up at `~/.claude/statusline`, so the settings block below is identical either way and you can switch later.

### Option A — prebuilt binary (no toolchain)

```sh
curl -L -o ~/.claude/statusline https://github.com/jonesnc/claude-statusline/releases/latest/download/statusline-linux-x86_64
chmod +x ~/.claude/statusline
```

Built with `-microarch:native` on the ITADM server's Cascade Lake Xeon, so **it contains AVX-512 and will `SIGILL` on a CPU without it** — use Option B anywhere else. Needs glibc 2.35+. Does not auto-update: re-run the `curl` to pick up changes.

### Option B — build from source (customizable, auto-updating)

```sh
git clone git@github.com:jonesnc/claude-statusline.git ~/Projects/claude-statusline
cd ~/Projects/claude-statusline
make install-odin
```

That builds `statusline_odin` and copies it to `~/.claude/statusline`. Requires an Odin toolchain. In exchange you get [auto-update](#auto-update) and a tree you can edit.

### Point Claude Code at it

In `~/.claude/settings.json`:

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

Build flags are `-o:speed -no-bounds-check -disable-assert -microarch:native`. `-microarch:native` targets the CPU you build on — that's why the released binary is AVX-512 and machine-specific. Drop it if you need a portable build.

If `odin build` complains it cannot find the `base` collection, the Makefile already resolves `ODIN_ROOT` via `odin root` and falls back to `/usr/lib/odin`, `/usr/share/odin`, `~/Odin`, `~/odin`. Set `ODIN_ROOT` yourself if your install lives somewhere else:

```sh
make install-odin ODIN_ROOT=/path/to/odin
```

## Auto-update

Source installs only. `make install-odin` writes the repo path to `~/.claude/statusline-src`. Once every 24h the statusline detaches a background process that runs `git pull --ff-only` and `make install-odin` in that directory, so a `git push` to your own copy propagates on its own. A downloaded binary has no pointer file, so it never updates itself.

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

- **vim mode** — icon only, when Claude Code's vim mode is on; color carries the mode
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
