"""Generates the bottom-right reader ornaments (reader_decor_<id>_trailing_<mode>.svg).

Each builtin reader background pairs its top-left ornament with a second drawing made for
the bottom-right corner, so the page reads as one scene instead of a mirrored motif. The
artwork is 480 x 480 on a transparent canvas, anchored to the bottom-right corner (480, 480)
and thinning out towards the text. A theme's light and dark files share one drawing and
differ only in palette.

Usage: python scripts/generate-reader-trailing-ornaments.py
"""
import math
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'entry', 'src', 'main', 'resources', 'base',
                   'media')


def fill(shape, color, opacity):
    return f'<{shape} fill="{color}" fill-opacity="{opacity}"/>'


def stroke(shape, color, opacity, width, extra=''):
    return (f'<{shape} fill="none" stroke="{color}" stroke-opacity="{opacity}" stroke-width="{width}" '
            f'stroke-linecap="round" stroke-linejoin="round"{extra}/>')


def both(shape, fill_color, fill_opacity, stroke_color, stroke_opacity, width):
    return (f'<{shape} fill="{fill_color}" fill-opacity="{fill_opacity}" stroke="{stroke_color}" '
            f'stroke-opacity="{stroke_opacity}" stroke-width="{width}" stroke-linejoin="round"/>')


def circle(cx, cy, r, transform=''):
    t = f' transform="{transform}"' if transform else ''
    return f'circle cx="{cx}" cy="{cy}" r="{r}"{t}'


def ellipse(cx, cy, rx, ry, transform=''):
    t = f' transform="{transform}"' if transform else ''
    return f'ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}"{t}'


def rect(x, y, w, h, rx=0, transform=''):
    t = f' transform="{transform}"' if transform else ''
    r = f' rx="{rx}"' if rx else ''
    return f'rect x="{x}" y="{y}" width="{w}" height="{h}"{r}{t}'


def path(d, transform=''):
    t = f' transform="{transform}"' if transform else ''
    return f'path d="{d}"{t}'


def lens(length, width):
    """Leaf / petal outline from the origin along +x."""
    return (f'M0 0C{length * 0.3:.0f}-{width:.0f} {length * 0.7:.0f}-{width:.0f} {length} 0'
            f'C{length * 0.7:.0f} {width:.0f} {length * 0.3:.0f} {width:.0f} 0 0Z')


def paper(p):
    """A quill resting on the turned-up page corner."""
    return [
        fill(path('M480 316C420 344 356 404 316 480H480Z'), p['b'], 0.16),
        stroke(path('M480 316C420 344 356 404 316 480'), p['a'], 0.22, 3),
        both(path('M316 480C350 432 404 404 446 402C444 434 426 462 404 480Z'), p['b'], 0.26, p['a'], 0.22, 2),
        fill(path('M428 236C380 244 322 300 296 378C332 352 388 326 428 236Z'), p['a'], 0.15),
        fill(path('M428 236C440 284 408 340 344 388C366 344 392 300 428 236Z'), p['a'], 0.10),
        stroke(path('M240 462L428 236'), p['a'], 0.32, 3),
        stroke(path('M330 354l-28-2M354 326l-30-6M378 298l-28-10M360 318l24 12M336 346l26 14'), p['a'], 0.18, 2),
        stroke(path('M176 438c50-14 98-10 142 6M222 398c30-8 58-6 84 4'), p['a'], 0.10, 2),
        fill(ellipse(232, 468, 7, 3), p['a'], 0.3),
        fill(ellipse(206, 460, 4, 2), p['a'], 0.22),
        fill(ellipse(262, 474, 3, 1.5), p['a'], 0.2),
    ]


def frond(x, y, angle, length, p, opacity):
    t = f'translate({x} {y}) rotate({angle})'
    out = [stroke(path(f'M0 0C{length * 0.3:.0f}-10 {length * 0.7:.0f}-6 {length} 8', t), p['a'], opacity + 0.06, 3)]
    d = ''
    for i in range(1, 9):
        px = length * i / 9
        size = (length * 0.2) * (1 - i / 11)
        for side in (-1, 1):
            d += (f'M{px:.0f} {-4 + i * 0.6:.0f}q{size * 0.5:.0f} {side * size * 0.9:.0f} {size * 1.2:.0f} {side * size:.0f}'
                  f'q-{size * 0.9:.0f} {side * -size * 0.2:.0f}-{size * 1.2:.0f}-{side * size:.0f}Z')
    out.append(fill(path(d, t), p['a'], opacity))
    return out


def forest(p):
    """Ferns and mushrooms on the forest floor."""
    out = [fill(path('M480 480H170c62-42 134-54 206-46 42 4 76-8 104-32Z'), p['b'], 0.16)]
    out += frond(452, 462, -128, 220, p, 0.16)
    out += frond(448, 468, -104, 190, p, 0.13)
    out += frond(440, 470, -156, 200, p, 0.12)
    out.append(fill(path('M300 432a40 26 0 0 1 80 0ZM332 432h16v34h-16Z'), p['a'], 0.22))
    out.append(fill(path('M250 452a24 16 0 0 1 48 0ZM269 452h10v20h-10Z'), p['a'], 0.17))
    for x, y, r in ((260, 330, 4), (330, 290, 3), (398, 250, 3), (220, 400, 3), (300, 370, 2)):
        out.append(fill(circle(x, y, r), p['b'], 0.5))
    return out


def ink(p):
    """Bamboo beside the ink pool."""
    out = [
        fill(ellipse(420, 452, 170, 62), p['b'], 0.07),
        stroke(path('M424 486C420 400 414 300 402 196'), p['a'], 0.16, 11, ' stroke-dasharray="62 6"'),
        stroke(path('M458 486C456 420 454 350 446 262'), p['a'], 0.12, 7, ' stroke-dasharray="48 5"'),
        stroke(path('M406 262C380 250 356 250 330 262M412 330C384 322 360 326 336 342'), p['a'], 0.16, 3),
    ]
    leaves = ((330, 262, 86, 150, 9), (336, 258, 70, 186, 8), (342, 266, 78, 122, 8), (336, 342, 90, 158, 10),
              (342, 338, 72, 196, 8), (350, 346, 80, 128, 9), (402, 196, 64, 200, 7), (398, 202, 70, 160, 7))
    for x, y, length, angle, width in leaves:
        out.append(fill(path(lens(length, width), f'translate({x} {y}) rotate({angle})'), p['a'], 0.20))
    out.append(stroke(path('M210 452h70M246 466h96M300 440h44'), p['b'], 0.14, 2))
    out.append(fill(circle(214, 420, 5), p['c'], 0.3))
    return out


def neon(p):
    """A lit skyline rising out of the corner."""
    return [
        fill(path('M480 480V236L246 480Z'), p['b'], 0.05),
        stroke(path('M150 478v-46h32v-42h38v62h30v-94h46v72h32v-114h42v136h32v-64h38v40h40'), p['a'], 0.24, 4),
        stroke(path('M246 372h22M246 396h22M342 318h18M342 344h18M342 370h18M194 410h14'), p['a'], 0.20, 3),
        stroke(path('M404 232l62 106h-124Z'), p['b'], 0.20, 4),
        stroke(path('M404 268l30 52h-60Z'), p['c'], 0.15, 3),
        stroke(path('M480 300h-58l-42 42h-96M480 204h-40l-30 30'), p['b'], 0.17, 4),
        stroke(circle(284, 342, 12), p['b'], 0.2, 3),
        stroke(path('M210 452H480M176 466H480'), p['c'], 0.13, 3),
    ]


def strawberry_shape(x, y, scale, angle, p):
    t = f'translate({x} {y}) rotate({angle}) scale({scale})'
    seeds = ''.join(f'M{sx} {sy}a2.2 3.4 0 1 0 .1 0Z' for sx, sy in ((-16, -6), (14, -8), (0, 8), (-10, 24), (12, 22),
                                                                    (0, 38)))
    return [
        both(path('M0-30C36-46 58-8 32 26C18 44 6 52 0 58C-6 52-18 44-32 26C-58-8-36-46 0-30Z', t), p['a'], 0.88, p['b'],
             0.9, 4),
        fill(path(seeds, t), p['d'], 0.9),
        fill(path('M0-26L-26-44L-8-40L0-58L8-40L26-44Z', t), p['c'], 0.95),
    ]


def strawberry(p):
    """Two strawberries on a lace doily."""
    out = [fill(path('M480 296A184 184 0 0 0 296 480H480Z'), p['d'], 0.72)]
    scallops = ''
    for i in range(9):
        angle = math.radians(180 + i * 11.25)
        cx, cy = 480 + math.cos(angle) * 184, 480 + math.sin(angle) * 184
        scallops += f'M{cx + 22:.0f} {cy:.0f}a22 22 0 1 0 .1 0Z'
    out.append(fill(path(scallops), p['d'], 0.72))
    out.append(stroke(path('M480 334A146 146 0 0 0 334 480'), p['e'], 0.72, 5, ' stroke-dasharray="1 13"'))
    out += strawberry_shape(402, 398, 1.15, -14, p)
    out += strawberry_shape(326, 444, 0.62, 16, p)
    hearts = ((250, 392, 0.5), (300, 330, 0.36), (220, 452, 0.3))
    for x, y, s in hearts:
        out.append(fill(path('M0-8C10-22 30-6 0 20C-30-6-10-22 0-8Z', f'translate({x} {y}) scale({s * 2})'), p['f'], 0.7))
    return out


def crimson(p):
    """Evidence on the desk: a fingerprint, a barcode and the red thread's end."""
    out = [fill(path('M480 480H286l42-32 52 16 42-38 58 22Z'), p['a'], 0.08)]
    for i in range(7):
        r = 22 + i * 15
        out.append(stroke(ellipse(382, 372, r, round(r * 1.22), 'rotate(-22 382 372)'), p['a'], 0.15, 4,
                          f' stroke-dasharray="{60 + i * 34} {14 + i * 3}"'))
    x = 206
    bars = ''
    for width in (5, 2, 8, 3, 3, 6, 2, 9, 4, 2, 6):
        bars += f'M{x} 438h{width}v34h-{width}Z'
        x += width + 5
    out.append(fill(path(bars), p['a'], 0.3))
    out.append(stroke(path('M232 292C292 344 268 410 344 436S440 404 486 428'), p['b'], 0.75, 6))
    out.append(fill(circle(232, 292, 9), p['b'], 0.75))
    out.append(stroke(path('M470 372V470H372'), p['a'], 0.45, 6, ' stroke-dasharray="15 10"'))
    return out


def blossom(x, y, r, color, opacity, heart):
    d = ''
    for i in range(5):
        angle = math.radians(i * 72 - 90)
        px, py = x + math.cos(angle) * r, y + math.sin(angle) * r
        d += f'M{px + r * 0.74:.1f} {py:.1f}a{r * 0.74:.1f} {r * 0.74:.1f} 0 1 0 .1 0Z'
    return [fill(path(d), color, opacity), fill(circle(x, y, round(r * 0.3, 1)), heart, 0.8)]


def plum_tea(p):
    """A folding fan under the window lattice."""
    out = [
        stroke(path('M480 318H318V480M480 362H362V480M318 400h44M400 318v44M440 362v48h40M362 440h48v40'), p['d'], 0.40, 5),
    ]
    cx, cy, radius = 236, 474, 150
    start, end = math.radians(196), math.radians(300)
    x0, y0 = cx + math.cos(start) * radius, cy + math.sin(start) * radius
    x1, y1 = cx + math.cos(end) * radius, cy + math.sin(end) * radius
    out.append(both(path(f'M{cx} {cy}L{x0:.0f} {y0:.0f}A{radius} {radius} 0 0 1 {x1:.0f} {y1:.0f}Z'), p['d'], 0.13,
                    p['a'], 0.38, 3))
    ribs = ''
    for i in range(1, 7):
        angle = start + (end - start) * i / 7
        ribs += f'M{cx} {cy}L{cx + math.cos(angle) * radius:.0f} {cy + math.sin(angle) * radius:.0f}'
    out.append(stroke(path(ribs), p['a'], 0.24, 2))
    inner = 62
    out.append(stroke(path(f'M{cx + math.cos(start) * inner:.0f} {cy + math.sin(start) * inner:.0f}'
                           f'A{inner} {inner} 0 0 1 {cx + math.cos(end) * inner:.0f} {cy + math.sin(end) * inner:.0f}'),
                      p['a'], 0.3, 3))
    out += blossom(196, 372, 13, p['b'], 0.8, p['c'])
    out += blossom(254, 356, 10, p['c'], 0.75, p['b'])
    for x, y, angle in ((150, 300, 30), (300, 270, -24), (410, 262, 54), (120, 420, 12), (350, 300, 70)):
        out.append(fill(ellipse(x, y, 11, 6, f'rotate({angle} {x} {y})'), p['b'], 0.55))
    return out


def rose_letter(p):
    """The sealed letter, postmarked, with a rosebud laid beside it."""
    env = 'rotate(-12 344 382)'
    out = [
        stroke(path('M176 470c84-30 190-32 304-10'), p['e'], 0.3, 3),
        stroke(circle(232, 318, 44), p['f'], 0.45, 3),
        stroke(circle(232, 318, 33), p['f'], 0.3, 2),
        stroke(path('M280 300c14-8 28 8 42 0s28 8 42 0M284 318c14-8 28 8 42 0s28 8 42 0M280 336c14-8 28 8 42 0s28 8 42 0'),
               p['f'], 0.34, 3),
        both(rect(246, 320, 196, 126, 6, env), p['e'], 0.20, p['e'], 0.7, 3),
        stroke(path('M246 320l98 74l98-74M246 446l70-62M442 446l-70-62', env), p['e'], 0.6, 3),
        both(circle(344, 396, 21, env), p['a'], 0.95, p['b'], 0.9, 3),
        stroke(path('M336 398c-2-10 8-14 13-8s4 14-4 14', env), p['c'], 0.9, 3),
        fill(path('M400 428c-40 4-62 24-70 54c38-4 62-22 70-54Z'), p['d'], 0.9),
        both(circle(438, 428, 34), p['a'], 1, p['b'], 1, 4),
        fill(circle(438, 428, 18), p['c'], 1),
        stroke(path('M430 430c-2-10 8-14 13-8'), p['b'], 0.8, 3),
    ]
    return out


def cloud(x, y, scale, p):
    t = f'translate({x} {y}) scale({scale})'
    return [
        both(path('M0 0c-4-26 30-34 44-14c10-26 52-22 54 8c26-4 34 28 10 38H-8c-28-4-24-34 8-32Z', t), p['c'], 0.8,
             p['a'], 0.34, 3),
        stroke(path('M22 14c10-12 28-8 30 6M70 20c10-6 22 0 22 10', t), p['a'], 0.3, 3),
    ]


def moon_crane(p):
    """Auspicious clouds over the reed bank, a second crane on the wing."""
    out = [
        stroke(ellipse(340, 452, 150, 18), p['a'], 0.3, 3),
        stroke(ellipse(340, 452, 96, 10), p['a'], 0.24, 2),
        stroke(path('M436 480C430 400 418 330 392 262M456 480C456 420 452 372 442 318M410 480C400 430 384 392 356 356'),
               p['a'], 0.36, 4),
    ]
    for x, y, angle in ((392, 262, -18), (442, 318, -8), (356, 356, -34)):
        out.append(fill(ellipse(x, y - 14, 7, 22, f'rotate({angle} {x} {y})'), p['a'], 0.42))
    out += cloud(214, 376, 1.15, p)
    out += cloud(320, 300, 0.7, p)
    out.append(fill(path('M180 196c-87-45-147-24-188 36 73-25 128-17 170 26-53-2-91 16-119 54 80-21 140-7 181 44-15-50-34-91-44-160Z',
                         'translate(150 150) scale(0.42)'), p['a'], 0.36))
    for x, y, r in ((300, 220, 4), (420, 196, 3), (160, 330, 3), (250, 270, 2)):
        out.append(fill(circle(x, y, r), p['b'], 0.62))
    return out


def sword_frost(p):
    """A cliff pine, a traveller's bamboo hat and the cinnabar seal."""
    out = [
        fill(path('M480 480H232l34-42 46-10 28-52 52-16 30-62 58-14Z'), p['a'], 0.12),
        stroke(path('M232 480l34-42 46-10 28-52 52-16 30-62 58-14'), p['a'], 0.2, 3),
        stroke(path('M416 366C392 332 392 296 362 262M392 314C372 304 350 306 330 318M378 282C390 270 406 266 424 268'),
               p['a'], 0.28, 6),
    ]
    for x, y, rx, ry in ((352, 252, 56, 10), (318, 322, 44, 9), (430, 262, 40, 8), (368, 226, 36, 7)):
        out.append(fill(ellipse(x, y, rx, ry), p['a'], 0.20))
    out.append(both(path('M206 462L266 420L326 462Z'), p['a'], 0.10, p['a'], 0.32, 3))
    out.append(stroke(ellipse(266, 462, 66, 9), p['a'], 0.32, 3))
    out.append(stroke(path('M236 441l60 0M222 452h88'), p['a'], 0.18, 2))
    out.append(fill(rect(430, 430, 34, 34, 4), p['b'], 0.5))
    out.append(stroke(path('M439 440h16v14h-16ZM447 440v14'), p['c'], 0.8, 2))
    for x, y, r in ((250, 300, 4), (300, 240, 3), (190, 380, 3), (440, 180, 3), (330, 380, 2), (220, 430, 2)):
        out.append(fill(circle(x, y, r), p['a'], 0.22))
    return out


def qingluan_water(p):
    """A lotus in bloom on the water the luan looks into, one tail feather drifting down."""
    out = [
        stroke(path('M176 446c40-16 80-16 120 0M214 468c56-20 112-20 168 0'), p['a'], 0.15, 3),
        fill(ellipse(388, 446, 92, 28), p['a'], 0.15),
        stroke(path('M388 446l-70-12M388 446l-40 22M388 446l62-18M388 446l20 26M388 446l-14-26'), p['a'], 0.16, 2),
        fill(ellipse(270, 466, 50, 14), p['a'], 0.11),
        stroke(path('M396 444C392 420 394 400 402 384'), p['a'], 0.3, 4),
    ]
    for angle in (-150, -122, -90, -58, -30):
        out.append(both(path(lens(64, 17), f'translate(402 386) rotate({angle})'), p['b'], 0.26, p['b'], 0.45, 2))
    out.append(both(path(lens(46, 14), 'translate(402 386) rotate(-90)'), p['b'], 0.3, p['b'], 0.5, 2))
    out.append(stroke(path('M486 226C420 240 360 262 300 318'), p['a'], 0.18, 4))
    out.append(stroke(path('M452 234l-14 20M420 244l-16 22M388 258l-16 22M356 276l-14 22M440 236l8-18M406 248l8-18M372 264l6-18'),
                      p['a'], 0.13, 3))
    out.append(fill(ellipse(300, 318, 20, 12, 'rotate(-42 300 318)'), p['a'], 0.18))
    out.append(fill(ellipse(298, 320, 9, 6, 'rotate(-42 298 320)'), p['b'], 0.45))
    for x, y, angle in ((230, 380, 24), (300, 400, -30), (190, 410, 60)):
        out.append(fill(ellipse(x, y, 10, 5, f'rotate({angle} {x} {y})'), p['b'], 0.3))
    return out


THEMES = {
    'paper': (paper, {'a': '#9B764B', 'b': '#CDAE7C'}, {'a': '#D2A068', 'b': '#D7A96F'}),
    'forest': (forest, {'a': '#557A62', 'b': '#9EB7A3'}, {'a': '#94B49C', 'b': '#9BB9A2'}),
    'ink': (ink, {'a': '#343D3B', 'b': '#4D5754', 'c': '#A34B42'}, {'a': '#C9D0CC', 'b': '#C3CBC7', 'c': '#C86059'}),
    'neon': (neon, {'a': '#25AFC6', 'b': '#C548A7', 'c': '#6E56C9'}, {'a': '#31E5F4', 'b': '#FF5DCD', 'c': '#9B7BFF'}),
    'strawberry': (strawberry,
                   {'a': '#E97076', 'b': '#B84D55', 'c': '#78986F', 'd': '#F7CDD0', 'e': '#A9C8DF', 'f': '#E8A0A7'},
                   {'a': '#C95F69', 'b': '#E68B93', 'c': '#71866D', 'd': '#4B303A', 'e': '#7397B0', 'f': '#C07D86'}),
    'crimson': (crimson, {'a': '#252220', 'b': '#8D211C'}, {'a': '#ECE7DF', 'b': '#D55A50'}),
    'plum_tea': (plum_tea, {'a': '#665046', 'b': '#A75C58', 'c': '#D8AAA3', 'd': '#637E70'},
                 {'a': '#B5A093', 'b': '#B96661', 'c': '#D8AAA3', 'd': '#90AE9E'}),
    'rose_letter': (rose_letter,
                    {'a': '#A84550', 'b': '#7D3039', 'c': '#D18A91', 'd': '#73816F', 'e': '#BFA06A', 'f': '#8F9B8D'},
                    {'a': '#9B424C', 'b': '#CE6E78', 'c': '#D7838A', 'd': '#697C6A', 'e': '#D6B477', 'f': '#849183'}),
    'moon_crane': (moon_crane, {'a': '#5F7799', 'b': '#6D86A7', 'c': '#EEF3F8'},
                   {'a': '#AFCDF4', 'b': '#BBD5F8', 'c': '#142033'}),
    'sword_frost': (sword_frost, {'a': '#476963', 'b': '#9B3B31', 'c': '#F4ECD9'},
                    {'a': '#8AB1A7', 'b': '#C76559', 'c': '#151C19'}),
    'qingluan_water': (qingluan_water, {'a': '#607F79', 'b': '#9C4F62'}, {'a': '#8AB5AC', 'b': '#C16A7D'}),
}


def main():
    for name, (draw, light, dark) in THEMES.items():
        for mode, palette in (('light', light), ('dark', dark)):
            body = '\n  '.join(draw(palette))
            svg = (f'<svg width="480" height="480" viewBox="0 0 480 480" xmlns="http://www.w3.org/2000/svg">\n'
                   f'  {body}\n</svg>\n')
            target = os.path.join(OUT, f'reader_decor_{name}_trailing_{mode}.svg')
            with open(target, 'w', encoding='utf-8', newline='\n') as f:
                f.write(svg)
    print(f'Generated {len(THEMES) * 2} trailing ornaments.')


if __name__ == '__main__':
    main()
