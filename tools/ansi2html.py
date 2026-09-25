#!/usr/bin/env python3
"""ANSI SGR -> HTML spans. Reads stdin, writes span-wrapped HTML lines.

    ansi2html.py          free-flowing text (one <div class="row"> per line)
    ansi2html.py --grid   every character in its own fixed-width cell, wide
                          (emoji) ones two cells — the only way to keep a box
                          frame's right edge straight in a browser, where an
                          emoji is never exactly two monospace columns wide.
                          Style .c / .w in the page (see make-images.sh).
Importable: convert(text, grid=False), cells(text), cell_html(), width(ch), strip(text).
"""
import sys, re, html, unicodedata

def xterm256(n):
    if n < 16:
        base = ['#000000','#cd3131','#0dbc79','#e5e510','#2472c8','#bc3fbc','#11a8cd','#e5e5e5',
                '#666666','#f14c4c','#23d18b','#f5f543','#3b8eea','#d670d6','#29b8db','#ffffff']
        return base[n]
    if n < 232:
        n -= 16
        steps = [0,95,135,175,215,255]
        r, g, b = steps[n//36], steps[(n//6)%6], steps[n%6]
        return f'#{r:02x}{g:02x}{b:02x}'
    v = 8 + (n-232)*10
    return f'#{v:02x}{v:02x}{v:02x}'

BASIC = {31:'#f85149', 32:'#3fb950', 33:'#d4c11f', 34:'#409bf0', 35:'#d670d6', 36:'#4dd0e1', 37:'#e6edf3'}
SGR = re.compile(r'\x1b\[([0-9;]*)m')

def width(ch):
    """Terminal columns for one character: 2 for wide/fullwidth, else 1."""
    return 2 if unicodedata.east_asian_width(ch) in ('W', 'F') else 1

def strip(text):
    return SGR.sub('', text)

def cells(text):
    """Yield (char, css-style) for every visible character of an ANSI line."""
    pos = 0
    color, dim = None, False
    def style():
        s = []
        if color: s.append(f'color:{color}')
        if dim: s.append('color:#767f8b') if not color else s.append('opacity:.62')
        return ';'.join(s)
    for m in list(SGR.finditer(text)) + [None]:
        end = m.start() if m else len(text)
        for ch in text[pos:end]:
            yield ch, style()
        if not m:
            break
        pos = m.end()
        params = [int(p) for p in m.group(1).split(';') if p != ''] or [0]
        i = 0
        while i < len(params):
            p = params[i]
            if p == 0: color, dim = None, False
            elif p == 2: dim = True
            elif p == 22: dim = False
            elif p == 39: color = None
            elif p in BASIC: color = BASIC[p]
            elif p == 38 and i+2 < len(params) and params[i+1] == 5:
                color = xterm256(params[i+2]); i += 2
            elif p == 38 and i+4 < len(params) and params[i+1] == 2:
                color = '#{:02x}{:02x}{:02x}'.format(*params[i+2:i+5]); i += 4
            i += 1

def cell_html(ch, st):
    cls = 'c w' if width(ch) == 2 else 'c'
    attr = f' style="{st}"' if st else ''
    return f'<i class="{cls}"{attr}>{html.escape(ch) if ch != " " else "&nbsp;"}</i>'

def convert(text, grid=False):
    if grid:
        return ''.join(cell_html(ch, st) for ch, st in cells(text))
    out, run, cur = [], '', None
    for ch, st in cells(text):
        if st != cur and run:
            out.append((f'<span style="{cur}">' if cur else '<span>') + html.escape(run) + '</span>')
            run = ''
        cur = st; run += ch
    if run:
        out.append((f'<span style="{cur}">' if cur else '<span>') + html.escape(run) + '</span>')
    return ''.join(out)

if __name__ == '__main__':
    grid = '--grid' in sys.argv[1:]
    for line in sys.stdin.read().rstrip('\n').split('\n'):
        print(f'<div class="row">{convert(line, grid)}</div>' if line.strip() else '<div class="gap"></div>')
