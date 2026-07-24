#!/usr/bin/env python3
"""Generate the QuotaBar README hero: a stylized illustration of the popover.

Synthetic data only (a@example.com / b@example.com, invented percentages).
Emits two variants so GitHub's <picture> can pick per colour scheme.
"""
from pathlib import Path

W, H = 504, 462

THEMES = {
    "light": dict(
        bg0="#eef1f5", bg1="#e2e6ec", bgStroke="#00000014",
        bar="#ffffff", barStroke="#0000001a", barGhost="#0000001f",
        pop="#fbfcfd", popStroke="#00000018", popShadow="#0000002e",
        card="#ffffff", cardStroke="#0000001a",
        text="#1f2328", text2="#5a636e", text3="#8b949e",
        track="#00000016", chip="#0000000f",
        green="#1a7f37", amber="#bf8700", red="#cf222e", accent="#0969da",
        btn="#00000008", btnStroke="#0000001f",
    ),
    "dark": dict(
        bg0="#12161d", bg1="#0b0e13", bgStroke="#ffffff12",
        bar="#1b212b", barStroke="#ffffff14", barGhost="#ffffff20",
        pop="#191e26", popStroke="#ffffff16", popShadow="#00000066",
        card="#222834", cardStroke="#ffffff14",
        text="#e6edf3", text2="#9aa4b1", text3="#6e7681",
        track="#ffffff1c", chip="#ffffff14",
        green="#3fb950", amber="#d29922", red="#f85149", accent="#4493f8",
        btn="#ffffff0d", btnStroke="#ffffff1f",
    ),
}

FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', Helvetica, Arial, sans-serif"


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


class Canvas:
    def __init__(self, t):
        self.t = t
        self.o = []

    def rect(self, x, y, w, h, r, fill, stroke=None, sw=1):
        s = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
        self.o.append(
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}"{s}/>'
        )

    def circle(self, cx, cy, r, fill):
        self.o.append(f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{fill}"/>')

    def text(self, x, y, s, size=10, fill=None, weight=400, anchor="start", ls=0, mono=False):
        fill = fill or self.t["text"]
        fam = ("ui-monospace, 'SF Mono', Menlo, monospace" if mono else FONT)
        extra = f' letter-spacing="{ls}"' if ls else ""
        self.o.append(
            f'<text x="{x}" y="{y}" font-family="{fam}" font-size="{size}" '
            f'font-weight="{weight}" fill="{fill}" text-anchor="{anchor}"{extra}>{esc(s)}</text>'
        )

    def chip(self, right, cy, label, tint=None):
        """Right-anchored capsule. Returns its left edge so chips can be stacked leftward."""
        t = self.t
        tint = tint or t["text2"]
        w = 7 * len(label) + 12
        x = right - w
        fill = t["chip"] if tint == t["text2"] else tint + "26"
        self.rect(x, cy - 7, w, 14, 7, fill)
        self.text(x + w / 2, cy + 3.2, label, size=8, weight=600, fill=tint, anchor="middle", ls=0.4)
        return x

    def gauge(self, x, y, label, pct, tint, caption=None, dim=1.0):
        """One 5h/Week row: label, capacity bar, right-aligned percentage, reset caption."""
        t = self.t
        g = [len(self.o)]
        self.text(x, y + 4, label, size=10, weight=500, fill=t["text2"])
        bar_x, bar_w = x + 42, 180
        self.rect(bar_x, y, bar_w, 6, 3, t["track"])
        self.rect(bar_x, y, max(6, round(bar_w * pct / 100)), 6, 3, tint)
        self.text(x + 264, y + 5, f"{pct}%", size=10, weight=600, fill=t["text"], anchor="end", mono=True)
        if caption:
            self.text(bar_x, y + 19, caption, size=9, fill=t["text3"])
        if dim < 1.0:
            body = "".join(self.o[g[0]:])
            del self.o[g[0]:]
            self.o.append(f'<g opacity="{dim}">{body}</g>')

    def button(self, x, y, label, w=None, tint=None):
        t = self.t
        w = w or 7 * len(label) + 20
        self.rect(x, y, w, 19, 5, t["btn"], t["btnStroke"], 1)
        self.text(x + w / 2, y + 13, label, size=10, weight=500,
                  fill=tint or t["text"], anchor="middle")
        return x + w

    def svg(self):
        body = "\n  ".join(self.o)
        return (
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" '
            f'height="{H}" role="img" aria-label="QuotaBar menu bar popover showing two Claude '
            f'accounts and a Codex account with their 5-hour and weekly usage">\n  '
            + body + "\n</svg>\n"
        )


def build(theme_name):
    t = THEMES[theme_name]
    c = Canvas(t)
    c.o.append(
        f'<defs>'
        f'<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="{t["bg0"]}"/><stop offset="1" stop-color="{t["bg1"]}"/>'
        f'</linearGradient>'
        f'<filter id="lift" x="-30%" y="-20%" width="160%" height="160%">'
        f'<feDropShadow dx="0" dy="6" stdDeviation="10" flood-color="{t["popShadow"][:7]}" '
        f'flood-opacity="0.34"/></filter>'
        f'</defs>'
    )
    c.rect(0.5, 0.5, W - 1, H - 1, 18, "url(#bg)", t["bgStroke"], 1)

    # --- menu bar strip -------------------------------------------------------
    c.rect(22, 22, 460, 26, 7, t["bar"], t["barStroke"], 1)
    for i, w in enumerate((14, 22, 18, 16)):          # ghosted app menus, left
        x = 34 + sum((14, 22, 18, 16)[:i]) + i * 10
        c.rect(x, 32, w, 6, 3, t["barGhost"])
    for i in range(2):                                 # ghosted status items, right
        c.rect(346 + i * 22, 32, 12, 6, 3, t["barGhost"])
    c.rect(392, 26, 66, 18, 5, t["chip"])              # the QuotaBar status item
    c.circle(403, 35, 3.5, t["amber"])
    c.text(412, 39, "78%", size=11, weight=600, fill=t["text"], mono=True)

    # --- popover --------------------------------------------------------------
    px, py, pw = 170, 62, 312
    # 12 top inset + two 112pt cards + a 76pt Codex card (10pt gutters) + the footer band.
    ph = 12 + 112 + 10 + 112 + 10 + 76 + 12 + 34
    c.o.append(f'<g filter="url(#lift)">')
    c.rect(px, py, pw, ph, 14, t["pop"], t["popStroke"], 1)
    c.o.append("</g>")

    cx, cw = px + 12, pw - 24          # card box
    ix = cx + 12                       # card content inset
    y = py + 12

    def card(h):
        c.rect(cx, y, cw, h, 10, t["card"], t["cardStroke"], 1)

    # Card 1 — active account, healthy.
    card(112)
    c.circle(ix + 3.5, y + 20, 3.5, t["amber"])
    c.text(ix + 15, y + 24, "a@example.com", size=12, weight=500)
    right = c.chip(cx + cw - 12, y + 20, "ACTIVE", t["accent"])
    c.chip(right - 5, y + 20, "MAX")
    c.gauge(ix, y + 38, "5h", 78, t["amber"], "resets 14:00 (in 2h 41m)")
    c.gauge(ix, y + 72, "Week", 41, t["green"])
    e = c.button(ix, y + 84, "Ping")
    c.text(cx + cw - 12, y + 97, "auto-ping", size=9, weight=500, fill=t["accent"], anchor="end")
    y += 112 + 10

    # Card 2 — parked account, warning band, offers the swap.
    card(112)
    c.circle(ix + 3.5, y + 20, 3.5, t["green"])
    c.text(ix + 15, y + 24, "b@example.com", size=12, weight=500)
    c.chip(cx + cw - 12, y + 20, "PRO")
    c.gauge(ix, y + 38, "5h", 12, t["green"], "resets 16:30 (in 5h 12m)")
    c.gauge(ix, y + 72, "Week", 24, t["green"])
    e = c.button(ix, y + 84, "Ping")
    c.button(e + 7, y + 84, "Swap here")
    c.text(cx + cw - 12, y + 97, "auto-ping off", size=9, fill=t["text3"], anchor="end")
    y += 112 + 10

    # Card 3 — Codex, read-only, so no action row.
    card(76)
    c.circle(ix + 3.5, y + 20, 3.5, t["green"])
    c.text(ix + 15, y + 24, "Codex", size=12, weight=500)
    c.chip(cx + cw - 12, y + 20, "PLUS")
    c.gauge(ix, y + 38, "5h", 31, t["green"])
    c.gauge(ix, y + 58, "Week", 46, t["green"])
    y += 76 + 12

    # Footer: divider, then "Updated …  ·  ⟳" left, add + settings right.
    c.rect(cx, y, cw, 1, 0.5, t["cardStroke"])
    fy = y + 20
    c.text(ix - 12, fy, "Updated 12s ago", size=10, fill=t["text2"], mono=True)
    c.text(ix + 86, fy, "·", size=10, fill=t["text3"])
    # refresh glyph
    c.o.append(
        f'<path d="M{ix + 108} {fy - 4} a5 5 0 1 1 -3.4 -4.7" fill="none" '
        f'stroke="{t["text2"]}" stroke-width="1.3" stroke-linecap="round"/>'
        f'<path d="M{ix + 104.6} {fy - 11.6} l0 3.2 l3.2 0" fill="none" stroke="{t["text2"]}" '
        f'stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/>'
    )
    # add + settings glyphs
    ax = cx + cw - 34
    c.o.append(
        f'<circle cx="{ax}" cy="{fy - 4}" r="5.6" fill="none" stroke="{t["text2"]}" stroke-width="1.3"/>'
        f'<path d="M{ax - 2.8} {fy - 4} h5.6 M{ax} {fy - 6.8} v5.6" stroke="{t["text2"]}" '
        f'stroke-width="1.3" stroke-linecap="round"/>'
    )
    gx = cx + cw - 12
    c.o.append(
        f'<circle cx="{gx}" cy="{fy - 4}" r="5.6" fill="none" stroke="{t["text2"]}" stroke-width="1.3"/>'
        f'<circle cx="{gx}" cy="{fy - 4}" r="2" fill="none" stroke="{t["text2"]}" stroke-width="1.3"/>'
    )
    return c.svg()


out = Path(__file__).resolve().parent
out.mkdir(exist_ok=True)
for name in THEMES:
    p = out / f"popover-{name}.svg"
    p.write_text(build(name))
    print("wrote", p)
