# ExecPlan — Statusline v6: two-line, width-adaptive, forward-looking

## Purpose & Big Picture

`statusline.odin` renders Claude Code's statusline as a single powerline-styled
line. It is fast (~200µs on a cache hit) and correct about most things, but it
has three structural problems this plan fixes:

1. **It silently loses the entire git segment in git worktrees and in any
   subdirectory of a repo.** The author works in many worktrees, so this is a
   daily loss. Root cause is hand-rolled `.git` path construction with no
   upward walk (see Context).
2. **It is blind to terminal width.** It reads `COLUMNS` only to log it. A wide
   statusline gets truncated by Claude Code with no say in what gets cut.
3. **Every number it shows is a *level*, never a *trend*.** `5h 21%` cannot
   answer "will I hit the cap"; the context bar cannot answer "when do I
   compact". The most valuable new information is forward-looking.

The end state is **two lines**: line 1 carries *identity* (things that change
only when you move — model, path, branch, PR) and line 2 carries *budget*
(everything volatile — quota, context, burn rate). Both degrade gracefully by a
table-driven priority ladder when the terminal is narrow. Line 1 becomes a
stable visual anchor because all the churn is quarantined on line 2.

The layout was designed and validated in a Python prototype before any Odin was
written. **That prototype is committed alongside this plan at
`thoughts/shared/plans/statusline-v6-layout-prototype.py` and is the
authoritative spec for the layout, the priority numbers, and the shrink
ladders.** Run it (`python3 thoughts/shared/plans/statusline-v6-layout-prototype.py`)
before writing Phase 2 — it prints every scenario at every width with rulers
and a shrink/drop decision log. Delete it in Milestone 6.

---

## Context & Orientation

Single source file: `statusline.odin` (2583 lines), package `main`, no external
deps beyond `core:fmt`, `core:strconv`, `core:strings`, `core:sys/posix`,
`core:time`. `statusline.c` and `Makefile.c-legacy` are a superseded C port —
**do not touch them**.

### Build & run

```bash
make odin          # builds ./statusline_odin  <-- USE THIS
make               # builds the C version. NOT what you want.
```

`ODIN_ROOT` is auto-detected in the Makefile via `odin root`; do not override it.

Run it by piping the statusLine JSON on stdin:
```bash
printf '{"current_dir":"/home/nathanjones/Projects/claude-statusline","display_name":"Opus 5","total_duration_ms":5000}' | ./statusline_odin
```

`STATUSLINE_DEBUG=1` appends a timing suffix and writes
`/tmp/statusline-<uid>/<gppid>.log`.

### HARD CONSTRAINTS — read before doing anything

- **NEVER run `make install-odin` or `make install`.** Not because of the
  binary — the author has explicitly OK'd overwriting their live statusline for
  testing — but because `install-odin` also writes `$(CURDIR)` to
  `~/.claude/statusline-src`, which repoints the built-in daily auto-updater
  (`maybe_auto_update`, statusline.odin:2395) at this throwaway worktree. The
  worktree is deleted when you finish, so the author's auto-update would then
  break silently.
- **Installing for a live look IS allowed**, via a plain copy that has no such
  side effect:
  ```bash
  cp ~/.claude/statusline ~/.claude/statusline.bak   # once, before the first copy
  cp statusline_odin ~/.claude/statusline
  ```
  Claude Code hot-reloads the statusLine command without a restart, so the new
  build appears immediately. **Restore `~/.claude/statusline.bak` before you
  finish** if the final build is not one you would want left installed — and say
  in your final report whether you left a WIP build in place.
- Do not touch `statusline.c`, `Makefile.c-legacy`, or `gitstatus-daemon.sh`.
- Commit conventions (from the repo/user CLAUDE.md): conventional commits,
  **first line ≤50 characters**, no `Co-Authored-By` lines, no "Generated with
  Claude Code" attribution, no `--no-verify`, no `--amend` for content changes.
- Work on the worktree's own branch. Never commit to `main`.
- Do not add a test framework. Verification is the `--demo` mode built in
  Milestone 6 plus the manual commands in Validation & Acceptance.

### Architecture you need to know

**Output buffering.** `OutBuf` (line 74) is a fixed `[4096]u8` with `len` and
`prev_bg`. `out_str` (line 80) **silently discards** anything that would
overflow — no error, no signal. `segment()` (line 129) emits a powerline
separator (`SEP_ROUND :: ""`) when the background color changes, or a
`|` divider when it matches the previous segment's background.

**Caches, all in `/dev/shm`:**
| Path | Struct | Keyed on | Invalidation |
|---|---|---|---|
| `statusline-cache.<gppid>` | `CachedState` (line 1046) | grandparent PID | overwrite each render |
| `statusline-usage.<gppid>` | `UsageCache` (line 1600) | grandparent PID | 60s TTL |
| `claude-git-<hash>` | `GitCache` (line 1264) | `hash_path(cwd)` | `.git/index` mtime + 5s TTL |

All are `#packed` structs written as raw bytes. **A struct layout change
invalidates existing cache files, and that is safe** — every reader checks
`n != size_of(T)` and returns `{}` on a short read, so stale files degrade to
zeros rather than garbage.

**The background-refresh pattern** (`get_git_status_cached`, line 1548) is the
idiom to copy for any new async work: on a stale cache, `fork()`; the child
`fork()`s again and the grandchild does the slow work and writes the cache while
the middle child `_exit(0)`s immediately, reparenting the grandchild to init.
The parent `waitpid`s only the middle child, so it never blocks on the real
work, and returns the **stale** data for this render.

**JSON parsing** is hand-rolled and single-pass (`json_parse_all`, line 361):
scan to `"`, dispatch on the following byte, match key literals. Nested objects
(`context_window`, `rate_limits`, `thinking`) are located, bounded with
`json_object_end` (line 266), and parsed **scoped** — this matters because
`used_percentage` appears under *both* `context_window` and each
`rate_limits.*` window; a flat scan grabs the wrong one. See the comment at
line 288. Do not "simplify" this into a flat scan.

### The three confirmed bugs (verified live in this repo, not theoretical)

**Bug 1 — git segment vanishes in worktrees and subdirectories.**
`git_read_branch_fast` (line 997) opens `<dir>/.git/HEAD` where `dir` is
`current_dir` from stdin, with **no upward walk to the repo root**. `main`
(line 2534) sets `gs.valid` from its return value, so when it fails *the whole
git segment is suppressed* — including `run_git_status`, which would have
worked. Two failure cases:
- **Subdirectory:** `~/repo/src/.git` does not exist.
- **Worktree:** `.git` is a **file**, not a directory. Confirmed:
  `/home/nathanjones/Projects/portal-trees/queue-monitor-dashboard/.git` is an
  81-byte regular file containing `gitdir: <path>`.

Same hand-rolled assumption in `git_read_stash_count` (line 970, reads
`<dir>/.git/logs/refs/stash`) and in the `.git/index` stat inside
`read_git_cache` (line 1349) / `write_git_cache` (line 1379).

Note `run_git_status` (line 1417) is **already correct** — it `chdir`s and
`exec`s real `git status`, which resolves the repo itself. Only the
hand-rolled path readers are broken.

**Bug 2 — git cache keyed on cwd, not repo root.** `get_git_cache_path`
(line 1284) hashes the path it is given, which is `current_dir`. So `~/repo` and
`~/repo/src` get separate cache files and fork separate `git status` processes
for identical repository state.

**Bug 3 — usage-cache refork storm.** `read_usage_cache` (line 1794) calls
`refresh_usage_cache` on a missing file, a short read, **and** TTL expiry, with
no record of failed attempts. When the OAuth fetch is failing (which the comment
at line 336 says it does), this forks `curl` **on every single render**.

### The width model — already settled, do not re-derive

Claude Code measures the statusline with exactly one call, extracted from the
compiled binary at `~/.local/share/claude/versions/2.1.220`:

```js
function Ft(e){return Bun.stringWidth(e,rLg)}   var rLg = {ambiguousIsNarrow:!0}
```

`ambiguousIsNarrow: true` means East-Asian-**Ambiguous** characters count as
**1 cell**. All 20 glyphs this statusline uses measure Ambiguous or Narrow —
nerd-font PUA (U+E000–F8FF), plane-15 PUA (brain U+F09D1), powerline U+E0B4,
`▰▱` U+25B0/B1, `█` U+2588, `…` U+2026, `↑↓` U+2191/3, `✓` U+2713, `→` U+2192.

**Therefore visible width = "strip ANSI escapes, count runes."** No width table
is needed. Keep a Wide/Fullwidth branch anyway so a future 2-cell glyph does not
silently break the math.

Also true: Claude Code reserves **no** chrome columns (usable width = full
`COLUMNS`); the main statusLine JSON has **no** `columns` field (subagent
statuslines only), so `COLUMNS`/`LINES` env vars are the only width source.

---

## Plan of Work

Six milestones. Milestone 1 is independently valuable and should be committed on
its own. Milestones 3.x are mutually independent.

### Milestone 1 — Correctness fixes (no visible layout change)

Land this first; it is worth shipping alone.

**1.1 Resolve the git root by upward walk.** Add:
```odin
GitPaths :: struct {
    root:        string,  // worktree top level
    gitdir:      string,  // per-worktree: HEAD, index live here
    commondir:   string,  // shared: logs/refs/stash lives here
    is_worktree: bool,
}
resolve_git_paths :: proc(start: string) -> (GitPaths, bool)
```
Walk up from `start` until `.git` exists; stop at `/`; cap the walk at ~40
levels. Then:
- `.git` is a **directory** → `gitdir = commondir = <root>/.git`,
  `is_worktree = false`.
- `.git` is a **file** → read it, parse the `gitdir: <path>` line. The path may
  be **relative** — resolve it against `root`. Then read `<gitdir>/commondir`
  (also possibly relative, also resolve against `gitdir`) to get the shared
  directory. `is_worktree = true`.

Then rewire: branch ← `<gitdir>/HEAD`; index mtime ← `<gitdir>/index`;
stash ← `<commondir>/logs/refs/stash`.

**The gitdir/commondir split is the highest-risk detail in this plan.** HEAD and
index are *per-worktree*; refs/stash is *shared*. Getting them backwards makes
the statusline display the wrong branch — a silent, plausible-looking wrong
answer. Verify against the real worktree listed in Validation below.

**1.2 Key the git cache on the resolved root**, not `current_dir`, so all
subdirectories of a repo share one cache entry and one refresh. Pass the
resolved root to `run_git_status` too.

**1.3 Grow `OutBuf` to 16384** and make truncation **segment-boundary only** —
never mid-escape-sequence, since a partial `\x1b[38;2;...` renders as visible
garbage. Two powerline lines at ~25 bytes per escape approaches the old 4096.

**1.4 Remove `@(static)` return buffers.** These procs return pointers into
their own static storage: `bg_to_fg` (line 116), `abbrev_path` (line 628),
`abbreviate_model` (line 751), `make_context_bar` (line 840), `format_duration`
(line 905), `truncate_branch` (line 1833), `format_time_12h` (line 2071),
`get_cache_path` (line 1101), `get_git_cache_path` (line 1284),
`get_usage_cache_path` (line 1610). Composing any two into one `bprintf`
silently corrupts output. The segment table in Milestone 2 makes such
composition far more likely, so convert them to take a caller-supplied
`buf: []u8` and return a slice of it — matching `format_tokens` (line 929) and
`format_countdown` (line 609), which already use that shape.

**1.5 Back off the usage refork storm.** Add `last_attempt_sec: i64` and
`consecutive_failures: i64` to `UsageCache`; only call `refresh_usage_cache`
when `now - last_attempt_sec` exceeds a backoff that doubles from 60s to a
15-minute cap. Have the grandchild write the cache **even on failure** (with the
failure counter incremented) so the backoff is observable.

**1.6 Delete the fake "last update" clock.** `state.last_update_sec` is assigned
`current_time_sec()` unconditionally at line 2004, so the `⟳ 1:04:43 PM` at
line 2242 is a wall clock wearing a sync icon — and it collides with the same
`ICON_SYNC` used by the quota reset countdown. Remove it and the now-unused
`format_time_12h`. Reclaims ~11 cells.

Commit: `fix(odin): resolve git root for worktrees/subdirs` (plus separate
commits for the other items if they are cleanly separable).

### Milestone 2 — Layout engine

**2.1** `display_width :: proc(s: string) -> int` — skip ANSI CSI (`\x1b[...m`)
and OSC8 (`\x1b]8;...\x1b\\`) sequences; for the rest, 2 if East-Asian Wide or
Fullwidth, else 1; skip combining marks. See the prototype's `display_width`.

**2.2** The segment table:
```odin
Seg :: struct {
    name:      string,   // for the --demo decision log
    bg, fg:    string,
    stages:    [3]string, // [0] richest -> [n-1] narrowest
    n_stages:  int,
    priority:  int,      // LOWER sheds/drops FIRST
    droppable: bool,
    line:      int,      // 1 or 2
}
```
Priorities — copy exactly from the prototype:
- Line 1: `model 95` (not droppable), `pr 85`, `branch 80`, `path 75`,
  `gitstat 45`, `vim 20`.
- Line 2: `ctx 100` (not droppable), `warn 99` (not droppable), `5h 90` (not
  droppable), `7d 50`, `reset 40`, `burn 30`, `dur 10`.

**2.3** `fit`: while `total > cols`, shed the next stage of the lowest-priority
segment that still has one; when no segment has a stage left, drop the
lowest-priority droppable segment.

```
total = Σ over live segments (display_width(text) + 2)   // +2 = padding spaces
      + (n_live - 1)                                     // junction cells
      + 1                                                // end cap
```
**The junction and end-cap terms are load-bearing.** Omitting them undercounted
by 5 cells in the prototype's first version and produced silent overflow with an
*empty* decision log — the most confusing possible symptom. Assert against this.

**2.4** Width source: `COLUMNS` env var, **fallback 120** when unset or
unparseable. Degrade as if narrow rather than assuming wide, since assuming wide
lets Claude Code truncate arbitrarily.

**2.5** Path/branch dedup: when the path's last component equals the branch
name — the normal case in this author's worktrees, where the directory is named
after the branch — elide the basename to `…` so the path contributes only the
parent context the branch segment cannot give.
`~/P/p/queue-monitor-dashboard  queue-monitor-dashboard` becomes
`~/P/p/…  queue-monitor-dashboard`. **This is the single largest win in the
plan: line 1 goes from 103 to 81 cells, which is why nothing degrades above 80
columns.**

**2.6** Emit both lines, `\n`-separated, each `fit()` independently against the
same `cols`.

Commit: `feat(odin): width-adaptive two-line layout`

### Milestone 3 — Forward-looking metrics

**3.1 Quota projection.** The window start is derivable from data already
parsed — no new input. `five_hour` start = `resets_at - 18000`; `seven_day`
start = `resets_at - 604800`. Then
`elapsed_frac = (now - start) / 18000` and `projected = used_pct / elapsed_frac`.
Render as `5h 21%→38%` and **color off the projection, not the level** — that is
the entire point, so the segment turns orange while there is still time to act.
Guards: **suppress the projection entirely below 10% elapsed** (30 seconds into
a window, one message projects to 400%), and clamp the display to `>100%`.
**5h only** — the 7d window moves too slowly for a projection to change
in-session behavior, and it would cost the cells twice.

**3.2 Burn rate + time-to-compact.** Add an 8-sample ring buffer of
`(time_sec: i64, input_tokens: i64)` plus a write index to `CachedState`.
Compute the rate by **linear regression over the samples within the last 60
seconds — not from the last single delta.** Claude Code re-renders on events,
not on a clock, so consecutive Δt values range from ~200ms to ~90s and a
single-delta rate is pure noise. Then
`ttc = (0.8 * ctx_size - input_tokens) / rate`. Suppress the whole segment when
there are fewer than 3 usable samples or the rate is non-positive (i.e. right
after a `/compact`). Render `↑2.1k/m ⚠12m`.

**3.3 Worktree icon.** Use `is_worktree` from 1.1 to swap `ICON_BRANCH` for a
distinct worktree glyph. One cell, no new segment — the worktree *name* is
already the path's last component, so a dedicated name segment would duplicate
it.

**3.4 Count untracked files.** Change `run_git_status`'s argv from `-uno` to
`-unormal` and count `??` lines into a new `untracked` field on `GitStatus`;
render it in the dirty group with its own glyph and color, and include it in the
branch segment's dirty test. The added scan cost lands in the background
grandchild, not the render. Known caveat, acceptable: a large un-ignored tree
(e.g. a `node_modules` with no matching `.gitignore` entry) makes the untracked
scan slow enough that the 5s cache can go stale more often than it refreshes.

Commit each separately.

### Milestone 4 — PR + CI status

**Before building anything:** `~/.claude/gh-pr-status-cache.json` already exists
on this machine (written 2026-07-31 12:53) containing exactly the shape this
milestone needs — `{number, title, state, checks:{passed,failed,pending},
review}` — and no producer for it could be found in `~/.claude/hooks`,
`commands`, `agents`, or `~/Projects/claude-tools`. **Look for the producer
first.** If the author already has a PR-status fetcher, consume its cache
instead of building a second fetcher; record the finding under Surprises either
way.

Otherwise: reuse the `get_git_status_cached` double-fork pattern with
`gh pr view --json number,state,statusCheckRollup,reviewDecision`, caching to
`/dev/shm/claude-pr-<hash(gitdir + branch)>` with a **120s TTL**.

**Unlike the git cache there is no local mtime to test staleness against**, so
freshness is pure TTL — which makes negative caching load-bearing here. Failure
is *normal*, not exceptional (no PR for this branch, rate limit, expired auth),
so a failed fetch must write a cache entry with a backoff timestamp, never
nothing. Otherwise this reproduces Bug 3 in a new place.

Display: `#257 ✓` / `✗2` (failure count) / `●` pending / `⊘` draft, with
`reviewDecision` carried in the **background color** — green `APPROVED`, orange
`REVIEW_REQUIRED`, dark undecided — so review state costs zero cells. Shrink
ladder: `#257 ✓2` → `#257 ✓` → `✓`.

Commit: `feat(odin): PR and CI status segment`

### Milestone 5 — OSC8 clickable PR number (gated; may be discarded)

Wrap the PR number in `\x1b]8;;<url>\x1b\\#257\x1b]8;;\x1b\\`. Costs zero
visible cells **if** Claude Code treats OSC8 as zero-width. That is unverified:
the terminal here is bare `xterm-256color` with no tmux and no `TERM_PROGRAM`,
so support is unknown. Build it, render one line, and confirm Claude Code
neither mis-measures the line (which would break every width calculation from
Milestone 2) nor passes the bytes through as visible garbage.

**If it does not survive, delete it and move on** — nothing else depends on it.
Record the outcome under Surprises & Discoveries.

### Milestone 6 — `--demo` verification mode

Add a `--demo` argv flag (a real flag, not an env var) that renders canned
states at widths 60, 80, 100, 140, 200, printing for each: a column ruler, both
rendered lines, each line's `display_width`, and the shrink/drop decision log.

Port these five scenarios from the prototype: typical worktree with PR awaiting
review · clean main checkout with no PR · CI failing but approved · context
critical plus quota over pace · no git repo in insert mode.

`--demo` must **assert and exit non-zero** if any line exceeds its target width
or if any scenario overflows `OutBuf`.

Then `git rm thoughts/shared/plans/statusline-v6-layout-prototype.py` — it was
scaffolding and `--demo` replaces it.

Commit: `feat(odin): add --demo layout verification mode`

---

## Validation & Acceptance

Run after every milestone. All commands from the repo root.

**Builds clean:**
```bash
make odin
```
Expect: no output beyond Odin's own progress, exit 0, and `./statusline_odin`
newer than `statusline.odin`. Any Odin warning about unused variables should be
resolved, not ignored.

**Milestone 1 — the git segment appears where it previously vanished.** This is
the acceptance test for the whole milestone:
```bash
# Worktree (.git is a FILE) -- must show a branch segment
printf '{"current_dir":"/home/nathanjones/Projects/portal-trees/queue-monitor-dashboard","display_name":"Opus 5","total_duration_ms":5000}' | ./statusline_odin | cat -v

# Subdirectory of a repo -- must show a branch segment
printf '{"current_dir":"/home/nathanjones/Projects/claude-statusline/.claude","display_name":"Opus 5","total_duration_ms":5000}' | ./statusline_odin | cat -v
```
Expect **both** to contain a branch name. Before this milestone both emit no git
segment at all — confirm that baseline first with `git stash` if useful, so you
know the test is meaningful.

Cross-check the branch the statusline reports against git's own answer:
```bash
git -C /home/nathanjones/Projects/portal-trees/queue-monitor-dashboard rev-parse --abbrev-ref HEAD
git -C /home/nathanjones/Projects/portal-trees/queue-monitor-dashboard stash list | wc -l
```
Expect the statusline's branch to match exactly, and its stash count to match
that `wc -l`. **A wrong-but-plausible branch name here means gitdir and
commondir are swapped** — the failure mode called out in 1.1.

**Milestone 2 — no line ever exceeds its width.** Once `--demo` exists
(Milestone 6) this is automatic; until then, check by eye with `COLUMNS` set:
```bash
for c in 60 80 100 140 200; do
  echo "--- $c"
  COLUMNS=$c printf '{"current_dir":"/home/nathanjones/Projects/portal-trees/queue-monitor-dashboard","display_name":"Opus 5","total_duration_ms":5000}' | COLUMNS=$c ./statusline_odin | sed 's/\x1b\[[0-9;]*m//g' | awk '{print length($0), $0}'
done
```
Cross-check the expected cell counts and degradation against the prototype:
```bash
python3 thoughts/shared/plans/statusline-v6-layout-prototype.py
```
Expect the Odin output to match the prototype's rendering and its `[NN]` cell
counts at each width. Reference figures: full-richness line 1 = **81** cells,
line 2 = **79**; nothing degrades at or above **80** columns.

**Milestone 6 — the demo passes:**
```bash
./statusline_odin --demo; echo "exit=$?"
```
Expect `exit=0`, 5 scenarios × 5 widths, and no `OVERFLOW` in the output.

**No regression in the normal case** — this must still render correctly and fast:
```bash
STATUSLINE_DEBUG=1 printf '{"current_dir":"/home/nathanjones/Projects/claude-statusline","display_name":"Opus 5","total_duration_ms":5000}' | ./statusline_odin
tail -1 /tmp/statusline-$(id -u)/*.log
```
Expect a `total=` under ~2000µs on a warm cache. The pre-existing warm-cache
figure is ~200µs; `display_width` and `fit` add work, so some increase is
expected, but a jump to milliseconds means something is forking that should not
be.

**Acceptance for the whole plan:** `make odin` clean; `--demo` exits 0 with no
overflow; the git segment present in a worktree, a subdirectory, and a plain
repo root, with branch and stash matching `git`'s own answers; warm-cache render
still sub-millisecond; `git status` clean; every Progress box below ticked.

---

## Progress

- [ ] Milestone 1 — correctness (git root walk, cache key, OutBuf, static bufs, usage backoff, drop fake clock)
- [ ] Milestone 2 — layout engine (display_width, segment table, fit, COLUMNS, dedup, two-line emit)
- [ ] Milestone 3 — forward-looking metrics (quota projection, burn rate + TTC, worktree icon, untracked)
- [ ] Milestone 4 — PR + CI status segment
- [ ] Milestone 5 — OSC8 (gated; record outcome even if discarded)
- [ ] Milestone 6 — `--demo` mode, delete the prototype

---

## Decision Log

Settled by an extended design interview on 2026-07-31. **Do not relitigate
these**; if implementation reveals one is wrong, stop and record it under
Surprises rather than quietly choosing differently.

1. **Two lines**, each independently width-adaptive. Claude Code renders a
   multi-line statusline natively, which dissolves the width pressure that
   killed an earlier right-align attempt.
2. **Line 1 = identity, line 2 = budget.** Chosen over importance-ordering
   because it is the only split that yields a non-shifting anchor line: if a
   value that changes every render sits left of a stable one, the stable one
   slides horizontally and muscle memory is lost.
3. Git root by **pure-syscall upward walk**, not by forking `git rev-parse` —
   keeps path resolution fork-free and inside the latency budget.
4. PR status by **background double-fork `gh`**, 120s TTL, with negative caching
   and backoff.
5. PR review state rides in the **background color**, costing zero cells. The
   PR *title* is deliberately omitted: the branch name sits immediately to its
   left saying the same thing, so a title would cost ~25 cells for a duplicate.
6. Quota shows a **projection**, not a pace arrow (1 bit is too coarse) and not
   a dual-cursor bar (11 cells for only the sign of the pace). **5h only.**
7. **Burn rate + time-to-compact**, over a rolling window rather than the last
   delta. The wall-clock "last update" is deleted rather than kept.
8. **Table-driven priority ladder** over fixed breakpoints (which need
   re-authoring per segment) and over greedy left-to-right fill (which makes
   segment *order* depend on width, destroying decision 2's anchor).
9. Worktree shown by **swapping the branch icon**, not a new segment — the
   worktree name is already the path's last component.
10. **`-unormal`**: untracked files are counted. New files are created
    constantly here and an invisible untracked file is the exact failure mode
    the author's tooling exists to catch. The cost is absorbed by the background
    fork.
11. **OSC8 is gated and built last**, because Claude Code's handling of it is
    unverified and a mis-measurement would break every width calculation.
12. **`--demo`** over golden-file tests: expected output would be an unreadable
    wall of escape sequences needing regeneration on every color tweak.

**Two known rough edges, deliberately accepted** (the author's decision: "leave,
we can fix if problem later"). Do not spend time on either:
- At 60 columns the path can shrink to `~/…/…` — ~5 cells for almost no
  information. Root cause is structural: `fit` exhausts every shrink stage
  before it will drop anything, so a low-value stage always beats a better
  drop. Fixing it properly means comparing the cost of a shrink against the
  benefit of a drop, which trades away the table-driven simplicity.
- At 60 columns the context bar collapses to a bare percentage while the burn
  rate survives, which is arguably backwards.

---

## Surprises & Discoveries

Record anything that contradicts this plan here, then stop with a clean tree.

- (nothing yet)
