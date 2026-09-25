#!/usr/bin/env python3
"""Card infographic: the real hero card, every stat explained.

    infographic.py HERO.ansi [--link] > page.html

Border items (model, effort, clock) get stem callouts above the card; each of
the card's four columns gets a legend underneath, aligned to that column, whose
tokens are lifted from the card itself (same glyphs, same colors). Positions
come from the card's own text, so a layout change in statusline.sh moves the
callouts with it instead of silently pointing at the wrong cell.
"""
import sys, html
sys.dont_write_bytecode = True   # no __pycache__ left in tools/
sys.path.insert(0, __import__('os').path.dirname(__file__))
from ansi2html import cells, cell_html, strip, convert

FONT = 28                 # card font px
CW = FONT * 0.6           # one terminal column (cells are fixed-width in grid mode)
RH = FONT * 1.32          # one row

ansi = open(sys.argv[1], encoding='utf-8').read().rstrip('\n').split('\n')
link = '--link' in sys.argv[2:]
rows = [list(cells(l)) for l in ansi]          # [(ch, style)]
cols = []                                      # per row: display column of each char
for r in rows:
    c, out = 0, []
    for ch, _ in r:
        out.append(c); c += 2 if __import__('ansi2html').width(ch) == 2 else 1
    cols.append(out)
text = [''.join(ch for ch, _ in r) for r in rows]

def find(row, token, after=0):
    """(first char index, last char index) of token in a row, from `after`."""
    i = text[row].find(token, after)
    if i < 0:
        sys.exit(f'infographic: "{token}" not found in row {row}: {text[row]!r}')
    return i, i + len(token) - 1

def span_px(row, i, j):
    """left px and width px of chars i..j."""
    x0 = cols[row][i]
    last_w = 2 if __import__('ansi2html').width(rows[row][j][0]) == 2 else 1
    return x0 * CW, (cols[row][j] + last_w - x0) * CW

def token_html(row, token, after=0):
    i, j = find(row, token, after)
    return ''.join(cell_html(ch, st) for ch, st in rows[row][i:j + 1])

# ---- card column spans (from the separators of row 1) ----------------------
seps = [k for k, ch in enumerate(text[1]) if ch == '│']
starts = [cols[1][seps[0]] + 2] + [cols[1][s] + 2 for s in seps[1:-1]]
ends = [cols[1][s] - 1 for s in seps[1:]]           # the space before each │
colspans = list(zip(starts, ends))                  # display-column spans

def cell_text(row, n):
    """stripped text of card column n in a row (by char index range)."""
    a, b = colspans[n]
    return ''.join(ch for (ch, _), c in zip(rows[row], cols[row]) if a <= c <= b).strip()

# ---- what each thing means ---------------------------------------------------
top = text[0]
model_end = top.index(' · ')
model = top[3:model_end]
effort = top[model_end + 3:].split(' ')[0]
clock = top.rstrip(' ─╮').split(' ')[-1]
ABOVE = [  # (token, tier, NAME, description)
    (model,  2, 'MODEL', 'its own color family —<br>name + frame drift while Claude works'),
    (effort, 1, 'EFFORT', 'low → max,<br>colored cool → hot'),
    (clock,  1, 'LAST ACTIVITY', 'freezes while idle'),
]

wk1, wk2 = cell_text(1, 0), cell_text(2, 0).split()
cx1, cx2 = cell_text(1, 1), cell_text(2, 1).split()
h51, h52 = cell_text(1, 2), cell_text(2, 2).split()
se1, se2 = cell_text(1, 3), cell_text(2, 3)
LEGEND = [  # per card column: NAME, [(row, token, description)]
    ('WEEKLY LIMIT', [
        (1, wk1.split()[-1], 'used — the real <b>/usage</b> number'),
        (2, wk2[0], "today's share left · <b>0</b>&nbsp;=&nbsp;done for today · <b>↓</b>&nbsp;=&nbsp;eating&nbsp;tomorrow's"),
        (2, wk2[1], 'burn rate that lands exactly on the reset'),
        (2, wk2[2], 'vs the even-burn line · <b>▼</b>&nbsp;under · <b>▲</b>&nbsp;caps&nbsp;early'),
    ]),
    ('CONTEXT', [
        (1, cx1.split()[-1], "this chat's window, resets on /clear"),
        (2, cx2[0], 'session time'),
        (2, cx2[1], 'left before the 200k line · then <b>╳</b>&nbsp;=&nbsp;start&nbsp;fresh'),
    ]),
    ('5-HOUR LIMIT', [
        (1, h51.split()[-1], 'used, also server-side'),
        (2, h52[0], 'until the window resets'),
        (2, h52[1], 'vs an even burn of the window'),
    ]),
    ('SESSION', [
        (1, se1, 'cost so far'),
        (2, se2.split(' ⌂ ')[0], 'since your last commit · warms after&nbsp;30m'),
        (2, '⌂ ' + se2.split(' ⌂ ')[1], 'this folder'),
    ]),
]

# ---- build ---------------------------------------------------------------------
TIER = 64                          # px per callout tier
top_h = 2 * TIER + 62
TK = 17                            # legend token font px
card_w = cols[0][-1] * CW + CW

callouts = []
for tok, tier, name, desc in ABOVE:
    i, j = find(0, tok)
    x, w = span_px(0, i, j)
    cx = x + w / 2
    stem = tier * TIER - 12
    callouts.append(
        f'<div class="co" style="left:{cx:.1f}px;bottom:{stem + 8}px">'
        f'<span class="nm">{name}</span><span class="ds">{desc}</span></div>'
        f'<div class="stem" style="left:{cx:.1f}px;bottom:-4px;height:{stem}px"></div>')

def token_cols(row, t):
    i, j = find(row, t)
    return sum(2 if __import__('ansi2html').width(ch) == 2 else 1 for ch, _ in rows[row][i:j + 1])

legend, widths = [], []
for n, (name, items) in enumerate(LEGEND):
    a, b = colspans[n]
    nxt = colspans[n + 1][0] if n + 1 < len(colspans) else b + 2
    widths.append(f'{(nxt - a) * CW:.1f}px')
    tkw = max(token_cols(r, t) for r, t, _ in items) * TK * 0.6   # widest token here
    rows_html = ''.join(
        f'<div class="it" style="grid-template-columns:{tkw:.1f}px 1fr">'
        f'<span class="tk">{token_html(r, t)}</span><span class="tx">{d}</span></div>'
        for r, t, d in items)
    legend.append(
        f'<div class="lg"><div class="br" style="width:{(b - a + 1) * CW:.1f}px"></div>'
        f'<div class="nm">{name}</div>{rows_html}</div>')

card_html = ''.join(f'<div class="row">{convert(l, grid=True)}</div>' for l in ansi)
foot = ('<div class="foot"><b>claude-statusline-burnrate</b> — pure bash + jq · '
        'github.com/Gui-Gou/claude-statusline-burnrate</div>') if link else ''

print(f'''<!doctype html><meta charset="utf-8">
<style>
  * {{ margin:0; padding:0; box-sizing:border-box; }}
  body {{ zoom:2; background:#0d1117; padding:20px 40px 30px; display:flex; justify-content:center;
          font-family:-apple-system,"Helvetica Neue",sans-serif; }}
  .stage {{ position:relative; width:{card_w:.0f}px; }}
  .top {{ position:relative; height:{top_h}px; }}
  .card {{ font-family:"JetBrainsMonoNL Nerd Font","JetBrainsMono Nerd Font","SF Mono",Menlo,monospace;
           font-size:{FONT}px; color:#e6edf3; }}
  .row {{ white-space:nowrap; height:{RH:.2f}px; line-height:{RH:.2f}px; }}
  .c {{ display:inline-block; width:{CW:.2f}px; text-align:center; font-style:normal; }}
  .w {{ width:{2 * CW:.2f}px; }}
  .co {{ position:absolute; transform:translateX(-50%); text-align:center; white-space:nowrap; }}
  .nm {{ display:block; font-size:12px; font-weight:700; letter-spacing:.09em; color:#8b949e; }}
  .ds {{ display:block; font-size:11.5px; color:#697079; line-height:1.4; margin-top:3px; }}
  .stem {{ position:absolute; width:1.5px; background:#30363d; }}
  .legend {{ display:grid; grid-template-columns:{' '.join(widths)}; margin:22px 0 0 {colspans[0][0] * CW:.1f}px; }}
  .lg {{ padding-right:18px; }}
  .lg .br {{ height:8px; border:1.5px solid #30363d; border-top:none; border-radius:0 0 4px 4px; margin-bottom:12px; }}
  .lg .nm {{ margin-bottom:10px; }}
  .it {{ display:grid; column-gap:12px; align-items:baseline; margin-bottom:9px; }}
  .tk {{ font-family:"JetBrainsMonoNL Nerd Font","SF Mono",Menlo,monospace; font-size:{TK}px;
         white-space:nowrap; color:#e6edf3; }}
  .tk .c {{ width:{TK * 0.6:.2f}px; }} .tk .w {{ width:{TK * 1.2:.2f}px; }}
  .tx {{ font-size:12px; color:#8b949e; line-height:1.35; }}
  .tx b {{ color:#adbac7; font-weight:600; }}
  .foot {{ text-align:center; margin-top:30px; font-size:13px; color:#767f8b; letter-spacing:.03em; }}
  .foot b {{ color:#adbac7; font-weight:600; }}
</style>
<div class="stage">
  <div class="top">{''.join(callouts)}</div>
  <div class="card">{card_html}</div>
  <div class="legend">{''.join(legend)}</div>
  {foot}
</div>''')
