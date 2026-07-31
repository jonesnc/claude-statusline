#!/usr/bin/env python3
"""THROWAWAY design demo for the Odin statusline redesign. Discard after review.

Answers three questions:
  1. What is the real display width model? (validated against CC's Bun call)
  2. Does the 2-line identity/budget split + priority ladder actually look good?
  3. Where does degradation land at 60/80/100/140/200 columns?

Not a port. Not integrated. Python purely because it is fast to iterate.
"""
import re
import unicodedata

# ---------------------------------------------------------------- width model
ANSI = re.compile(r"\x1b\[[0-9;]*m|\x1b\]8;[^\x1b]*\x1b\\")


def display_width(s: str) -> int:
    """Mirror Bun.stringWidth(s, {ambiguousIsNarrow: true}) -- what CC uses.

    Ambiguous (A) and Narrow (N/Na/H) -> 1.  Wide (W) and Fullwidth (F) -> 2.
    Every glyph this statusline uses measures A or N, so this reduces to
    'count runes, ignore escapes'.  Kept general to catch future 2-cell glyphs.
    """
    plain = ANSI.sub("", s)
    w = 0
    for ch in plain:
        if unicodedata.combining(ch):
            continue
        w += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return w


# ---------------------------------------------------------------- palette
R = "\x1b[0m"
BOLD = "\x1b[1m"


def bg(r, g, b):
    return f"\x1b[48;2;{r};{g};{b}m"


def fg(r, g, b):
    return f"\x1b[38;2;{r};{g};{b}m"


BG_PURPLE, BG_DARK, BG_GREEN = bg(189, 147, 249), bg(68, 71, 90), bg(72, 209, 104)
BG_ORANGE, BG_COMMENT, BG_RED = bg(255, 184, 108), bg(98, 114, 164), bg(255, 85, 85)
BG_YELLOW = bg(241, 250, 140)
FG_BLACK, FG_WHITE, FG_DARK = fg(40, 42, 54), fg(248, 248, 242), fg(68, 71, 90)
FG_GREEN, FG_YELLOW, FG_ORANGE = fg(80, 250, 123), fg(241, 250, 140), fg(255, 184, 108)
FG_RED, FG_PURPLE, FG_COMMENT = fg(255, 85, 85), fg(189, 147, 249), fg(98, 114, 164)
FG_CYAN = fg(139, 233, 253)

SEP = ""
I_BRANCH, I_WORKTREE, I_FOLDER = "", "", ""
I_CLOCK, I_STASH, I_PENCIL, I_VIM = "", "", "", ""
I_STAGED, I_WARN, I_SYNC, I_BRAIN = "", "", "", "\U000f09d1"
I_UNTRACKED, I_PR = "", ""
FILLED, EMPTY = "▰", "▱"


def bg_to_fg(b):
    return b[:2] + "3" + b[3:]


# ---------------------------------------------------------------- segments
class Seg:
    """One rendered segment plus its degradation ladder.

    stages[0] is the richest form; each later entry is narrower.  priority is
    the drop order -- lowest priority sheds stages (and finally vanishes) first.
    """

    def __init__(self, name, bgc, fgc, stages, priority, droppable=True):
        self.name, self.bg, self.fg = name, bgc, fgc
        self.stages, self.priority, self.droppable = stages, priority, droppable
        self.stage = 0
        self.dropped = False

    def text(self):
        return self.stages[self.stage]

    def width(self):
        return 0 if self.dropped else display_width(self.text()) + 2  # padding


def render(segs):
    """Powerline-join surviving segments; same-bg neighbours get a '|' divider."""
    live = [s for s in segs if not s.dropped]
    out, prev = [], None
    for s in live:
        if prev is not None:
            if prev.bg == s.bg:
                out.append(f"{s.bg}{FG_COMMENT}|{R}")
            else:
                out.append(f"{s.bg}{bg_to_fg(prev.bg)}{SEP}{R}")
        out.append(f"{s.bg}{s.fg} {s.text()} {R}")
        prev = s
    if prev is not None:
        out.append(f"{bg_to_fg(prev.bg)}{SEP}{R}")
    return "".join(out)


def fit(segs, cols):
    """Priority ladder: shed stages from the lowest-priority segment that still
    has one, then drop it outright.  Returns the decision log for debugging."""
    log = []

    def total():
        """Segment bodies + one cell per junction (powerline sep or '|' divider)
        + one end cap. Missing the junctions is what made v1 under-count by 5."""
        live = [s for s in segs if not s.dropped]
        if not live:
            return 0
        return sum(s.width() for s in live) + (len(live) - 1) + 1

    guard = 0
    while total() > cols and guard < 200:
        guard += 1
        cands = [s for s in segs if not s.dropped and s.stage < len(s.stages) - 1]
        if cands:
            v = min(cands, key=lambda s: s.priority)
            v.stage += 1
            log.append(f"shrink {v.name}->s{v.stage}")
            continue
        cands = [s for s in segs if not s.dropped and s.droppable]
        if not cands:
            break
        v = min(cands, key=lambda s: s.priority)
        v.dropped = True
        log.append(f"drop {v.name}")
    return log


# ---------------------------------------------------------------- state -> segs
def pct_color(p):
    return FG_RED if p >= 80 else FG_ORANGE if p >= 60 else (
        FG_YELLOW if p >= 40 else FG_GREEN)


def rl_color(p):
    return FG_RED if p >= 90 else FG_ORANGE if p >= 80 else FG_GREEN


def ctx_bar(pct, tokens, ctx_size, width=10):
    filled = (min(pct, 100) * width + 50) // 100
    cells = "".join(
        (pct_color((i * 100) // width + 5) + FILLED) if i < filled
        else (FG_WHITE + EMPTY) for i in range(width))
    tok = f"{tokens:,}".rjust(len(f"{ctx_size:,}"))
    return f"{FG_WHITE}{tok} {cells} {pct_color(pct)}{pct}%"


def line1(st):
    """Identity: things that change only when you move. Stable anchor."""
    s = []
    if st.get("vim"):
        ins = st["vim"] == "INSERT"
        s.append(Seg("vim", BG_GREEN if ins else BG_DARK,
                     FG_BLACK if ins else FG_WHITE,
                     [BOLD + I_PENCIL if ins else I_VIM], priority=20))
    model = st["model"] + (f" {I_BRAIN}" if st.get("thinking") else "")
    s.append(Seg("model", BG_PURPLE, FG_BLACK,
                 [BOLD + model, BOLD + st["model_short"]], priority=95,
                 droppable=False))
    # FIX 1: in a worktree the dir basename and the branch are usually the SAME
    # string, so rendering both wastes ~25 cells. When they match, elide the
    # basename to '…' -- the path then contributes only the parent context the
    # branch segment cannot give, and the branch segment carries the name.
    dup = st.get("branch") and st["path_base"] == st["branch"]
    if dup:
        parent = st["path"].rsplit("/", 1)[0]
        pstages = [f"{I_FOLDER} {parent}/…",
                   f"{I_FOLDER} {st['path_short'].rsplit('/', 1)[0]}/…"]
    else:
        pstages = [f"{I_FOLDER} {st['path']}",
                   f"{I_FOLDER} {st['path_short']}",
                   f"{I_FOLDER} {st['path_base']}"]
    s.append(Seg("path", BG_DARK, FG_WHITE, pstages, priority=75))
    if st.get("branch"):
        icon = I_WORKTREE if st.get("worktree") else I_BRANCH
        dirty = st["staged"] or st["modified"] or st["untracked"]
        b = st["branch"]
        s.append(Seg("branch", BG_ORANGE if dirty else BG_GREEN, FG_BLACK,
                     [f"{icon} {b}", f"{icon} {b[:12]}…" if len(b) > 12
                      else f"{icon} {b}", f"{icon} {b[:8]}…"], priority=80))
        bits = []
        if st["ahead"]:
            bits.append(f"{FG_GREEN}↑{st['ahead']}")
        if st["behind"]:
            bits.append(f"{FG_RED}↓{st['behind']}")
        if st["staged"]:
            bits.append(f"{FG_GREEN}{I_STAGED}{st['staged']}")
        if st["modified"]:
            bits.append(f"{FG_ORANGE}{I_PENCIL}{st['modified']}")
        if st["untracked"]:
            bits.append(f"{FG_CYAN}{I_UNTRACKED}{st['untracked']}")
        if st["stashes"]:
            bits.append(f"{FG_PURPLE}{I_STASH}{st['stashes']}")
        if bits:
            s.append(Seg("gitstat", BG_DARK, "", [" ".join(bits)], priority=45))
    if st.get("pr"):
        pr = st["pr"]
        glyph, gcol = {
            "pass": (I_STAGED, FG_GREEN), "fail": ("✗", FG_RED),
            "pending": ("●", FG_YELLOW), "draft": ("⊘", FG_COMMENT),
        }[pr["ci"]]
        cnt = f"{pr['failed']}" if pr["ci"] == "fail" else ""
        # review state rides in the background colour -- costs zero cells
        prbg = {"APPROVED": BG_GREEN, "REVIEW_REQUIRED": BG_ORANGE,
                None: BG_DARK}[pr["review"]]
        prfg = FG_BLACK if prbg is not BG_DARK else FG_WHITE
        # FIX 2: CI/review state is what you actually wait on, so the PR must
        # outrank the path -- v1 shed '✗2' at 100 cols while a 27-char path
        # stayed full. Stage 1 keeps the glyph and drops only the failure count.
        s.append(Seg("pr", prbg, prfg,
                     [f"#{pr['number']} {gcol}{glyph}{cnt}",
                      f"#{pr['number']} {gcol}{glyph}",
                      f"{gcol}{glyph}"], priority=85))
    return s


def line2(st):
    """Budget: everything volatile. All churn quarantined here."""
    s = []
    if st.get("five_pct") is not None:
        c5 = rl_color(max(st["five_pct"], st["seven_pct"]))
        proj = ""
        if st.get("five_proj") is not None:
            pc = rl_color(st["five_proj"])
            v = ">100" if st["five_proj"] > 100 else st["five_proj"]
            proj = f"{FG_DARK}→{pc}{BOLD}{v}%"
        # FIX 3: 5h / 7d / reset are three independent segments, not one bundled
        # string. v1's single ladder killed 7d before the reset countdown; as
        # separate priorities the ladder can shed reset first and keep 7d.
        s.append(Seg("5h", BG_COMMENT, "",
                     [f"{FG_WHITE}5h {BOLD}{c5}{st['five_pct']}%{proj}",
                      f"{FG_WHITE}5h {BOLD}{c5}{st['five_pct']}%"],
                     priority=90, droppable=False))
        s.append(Seg("7d", BG_COMMENT, "",
                     [f"{FG_WHITE}7d {BOLD}{c5}{st['seven_pct']}%"], priority=50))
        if st.get("reset"):
            s.append(Seg("reset", BG_COMMENT, "",
                         [f"{FG_WHITE}{I_SYNC}{st['reset']}"], priority=40))
    s.append(Seg("dur", BG_DARK, "",
                 [f"{FG_WHITE}{I_CLOCK} {st['duration']}"], priority=10))
    s.append(Seg("ctx", BG_DARK, "",
                 [ctx_bar(st["ctx_pct"], st["tokens"], st["ctx_size"], 10),
                  ctx_bar(st["ctx_pct"], st["tokens"], st["ctx_size"], 5),
                  f"{pct_color(st['ctx_pct'])}{st['ctx_pct']}%"],
                 priority=100, droppable=False))
    if st.get("burn"):
        s.append(Seg("burn", BG_DARK, "",
                     [f"{FG_WHITE}↑{st['burn']} {FG_ORANGE}{I_WARN}{st['ttc']}",
                      f"{FG_WHITE}↑{st['burn']}"], priority=30))
    if st["ctx_pct"] >= 80:
        crit = st["ctx_pct"] >= 90
        s.append(Seg("warn", BG_RED if crit else BG_YELLOW, FG_BLACK,
                     [f"{BOLD}{I_WARN} " + ("COMPACT NOW" if crit else "CTX 80%+"),
                      f"{BOLD}{I_WARN}"], priority=99, droppable=False))
    return s


# ---------------------------------------------------------------- scenarios
BASE = dict(
    vim="NORMAL", model="Opus 5", model_short="Op5", thinking=True,
    path="~/P/p/queue-monitor-dashboard", path_short="~/…/queue-monitor-dashboard",
    path_base="queue-monitor-dashboard", worktree=True,
    branch="queue-monitor-dashboard", staged=2, modified=3, untracked=1,
    stashes=1, ahead=4, behind=0,
    pr=dict(number=257, ci="pass", failed=0, review="REVIEW_REQUIRED"),
    five_pct=21, seven_pct=20, five_proj=38, reset="1h5m",
    duration="5.0s", tokens=69287, ctx_size=200000, ctx_pct=35,
    burn="2.1k/m", ttc="12m",
)

SCENARIOS = [
    ("typical worktree, PR awaiting review", {}),
    ("clean main checkout, no PR",
     dict(worktree=False, branch="main", staged=0, modified=0, untracked=0,
          stashes=0, ahead=0, pr=None, ctx_pct=8, tokens=16204, burn=None)),
    ("CI failing, approved",
     dict(pr=dict(number=9829, ci="fail", failed=2, review="APPROVED"))),
    ("context critical + quota over pace",
     dict(ctx_pct=93, tokens=186_400, five_pct=61, five_proj=104,
          seven_pct=77, burn="9.4k/m", ttc="2m", reset="47m")),
    ("no git repo, insert mode",
     dict(vim="INSERT", branch=None, pr=None, path="~/llm-wiki",
          path_short="~/llm-wiki", path_base="llm-wiki", worktree=False,
          ctx_pct=44, tokens=88_012)),
]

WIDTHS = [200, 140, 100, 80, 60]


def ruler(cols):
    s = "".join(str((i // 10) % 10) if i % 10 == 0 else "·"
                for i in range(cols))
    return FG_COMMENT + s + R


def main():
    print(f"\n{BOLD}display_width model{R}: Bun.stringWidth(s,"
          " {ambiguousIsNarrow:true}) -- extracted from claude 2.1.220 binary")
    print(f"  {FG_COMMENT}every glyph used measures Ambiguous or Narrow ->"
          f" 1 cell. width == runes, escapes ignored.{R}\n")

    print(f"{BOLD}per-glyph widths (assert all == 1){R}")
    glyphs = [SEP, I_BRANCH, I_WORKTREE, I_FOLDER, I_CLOCK, I_STASH, I_PENCIL,
              I_VIM, I_STAGED, I_WARN, I_SYNC, I_BRAIN, I_UNTRACKED, FILLED,
              EMPTY, "…", "↑", "✗", "●", "⊘", "→"]
    bad = [g for g in glyphs if display_width(g) != 1]
    print("  " + " ".join(f"{g}={display_width(g)}" for g in glyphs))
    print(f"  {FG_GREEN if not bad else FG_RED}"
          f"{'all 1 cell' if not bad else f'NOT 1 CELL: {bad!r}'}{R}\n")

    for title, over in SCENARIOS:
        st = {**BASE, **over}
        print(f"{BOLD}{FG_PURPLE}── {title} {R}")
        for cols in WIDTHS:
            l1, l2 = line1(st), line2(st)
            log1, log2 = fit(l1, cols), fit(l2, cols)
            r1, r2 = render(l1), render(l2)
            w1, w2 = display_width(r1), display_width(r2)
            print(f"{FG_COMMENT}  cols={cols}{R}")
            print("  " + ruler(cols))
            print("  " + r1 + f"  {FG_COMMENT}[{w1}]{R}")
            print("  " + r2 + f"  {FG_COMMENT}[{w2}]{R}")
            if log1 or log2:
                print(f"  {FG_COMMENT}  L1: {', '.join(log1) or '-'}"
                      f" | L2: {', '.join(log2) or '-'}{R}")
            over1 = [x for x in ((r1, w1), (r2, w2)) if x[1] > cols]
            if over1:
                print(f"  {FG_RED}  !! OVERFLOW {[w for _, w in over1]}{R}")
            print()
    print(f"{BOLD}calibration string{R} (paste into a real statusline to confirm"
          " CC's width matches ours):")
    cal = f"{I_BRANCH}{I_FOLDER}{I_BRAIN}{FILLED*3}{EMPTY*3}{SEP}{'X'*10}"
    print(f"  {cal}\n  predicted width = {display_width(cal)}"
          " (10 X's + 11 glyphs)\n")


if __name__ == "__main__":
    main()
