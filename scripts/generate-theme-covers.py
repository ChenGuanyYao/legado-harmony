"""Generates the illustrated book covers of the vector-art themes (theme_cover_<id>_NN.svg).

Classic Blue, Warm Paper, Forest Mist, Ink Wash and Neon Night each get four full-bleed
300 x 440 scenes that the bookshelf rotates through, in place of a single book-with-emblem
drawing. Covers carry no title or author; the shelf frame is drawn separately.

Usage: python scripts/generate-theme-covers.py
"""
import math
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'entry', 'src', 'main', 'resources', 'base',
                   'media')
W, H = 300, 440


class Cover:
    def __init__(self):
        self.defs = []
        self.body = []

    def gradient(self, stops, x1=0, y1=0, x2=0, y2=1):
        name = f'g{len(self.defs)}'
        items = ''.join(
            f'<stop offset="{offset}" stop-color="{color}"' + (f' stop-opacity="{opacity}"' if opacity < 1 else '') + '/>'
            for offset, color, opacity in [(s[0], s[1], s[2] if len(s) > 2 else 1) for s in stops])
        self.defs.append(f'<linearGradient id="{name}" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{items}</linearGradient>')
        return f'url(#{name})'

    def glow(self, color, cx, cy, r, opacity=0.6):
        # A square carrier keeps the default bounding-box gradient circular.
        name = f'g{len(self.defs)}'
        self.defs.append(f'<radialGradient id="{name}"><stop stop-color="{color}" stop-opacity="{opacity}"/>'
                         f'<stop offset="1" stop-color="{color}" stop-opacity="0"/></radialGradient>')
        self.add(f'<rect x="{cx - r}" y="{cy - r}" width="{r * 2}" height="{r * 2}" fill="url(#{name})"/>')

    def add(self, element):
        self.body.append(element)

    def sky(self, stops):
        self.add(f'<rect width="{W}" height="{H}" fill="{self.gradient(stops)}"/>')

    def fill(self, d, color, opacity=1, transform=''):
        t = f' transform="{transform}"' if transform else ''
        o = f' fill-opacity="{opacity}"' if opacity < 1 else ''
        self.add(f'<path d="{d}" fill="{color}"{o}{t}/>')

    def line(self, d, color, width, opacity=1, extra='', transform=''):
        t = f' transform="{transform}"' if transform else ''
        o = f' stroke-opacity="{opacity}"' if opacity < 1 else ''
        self.add(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}" stroke-linecap="round" '
                 f'stroke-linejoin="round"{o}{extra}{t}/>')

    def circle(self, cx, cy, r, color, opacity=1):
        o = f' fill-opacity="{opacity}"' if opacity < 1 else ''
        self.add(f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{color}"{o}/>')

    def ring(self, cx, cy, r, color, width, opacity=1):
        self.add(f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{color}" stroke-width="{width}" '
                 f'stroke-opacity="{opacity}"/>')

    def stars(self, points, color, opacity=0.9):
        d = ''.join(f'M{x + r} {y}a{r} {r} 0 1 0 .1 0Z' for x, y, r in points)
        self.fill(d, color, opacity)

    def svg(self):
        defs = f'<defs>{"".join(self.defs)}</defs>\n  ' if self.defs else ''
        body = '\n  '.join(self.body)
        return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">\n'
                f'  {defs}{body}\n</svg>\n')


STARS = ((30, 40, 1.6), (70, 90, 1.1), (120, 30, 1.4), (170, 70, 1), (215, 36, 1.6), (262, 84, 1.2), (280, 30, 1),
         (46, 150, 1), (238, 150, 1.3), (150, 120, 1), (96, 180, 1.2), (200, 200, 1), (20, 220, 1.1), (276, 232, 1))


def pine(x, base, h, w):
    d = ''
    for i in range(3):
        top = base - h + i * h * 0.24
        bottom = base - h + (i + 1.25) * h * 0.4
        half = w * (0.34 + i * 0.33)
        d += f'M{x} {top:.0f}L{x + half:.0f} {min(bottom, base):.0f}H{x - half:.0f}Z'
    return d + f'M{x - 3} {base - 6}h6v16h-6Z'


def lens(length, width):
    return (f'M0 0C{length * 0.3:.0f}-{width:.0f} {length * 0.7:.0f}-{width:.0f} {length} 0'
            f'C{length * 0.7:.0f} {width:.0f} {length * 0.3:.0f} {width:.0f} 0 0Z')


def cloud(c, x, y, s, color, opacity):
    c.fill('M0 0c-4-22 26-30 38-12c8-22 46-18 48 8c22-4 30 24 8 32H-8c-24-4-20-30 8-28Z', color, opacity,
           f'translate({x} {y}) scale({s})')


# ---------------------------------------------------------------- classic blue
def blue_lighthouse():
    c = Cover()
    c.sky([(0, '#0E2A5C'), (0.55, '#2F74C8'), (1, '#9BD0FF')])
    c.glow('#FFF3C4', 208, 150, 150, 0.55)
    c.stars(STARS[:9], '#FFFFFF', 0.7)
    c.fill('M205 150L20 96V132Z', '#FFF3C4', 0.22)
    c.fill('M0 340C60 318 120 330 180 322S260 330 300 316V440H0Z', '#12386F')
    c.fill('M150 440V352L196 328L246 346L300 330V440Z', '#0A2248')
    c.fill('M196 170h20l10 172h-40Z', '#F4F9FF')
    c.fill('M194 210h24l2 34h-28ZM190 280h32l2 34h-36Z', '#E4572E')
    c.fill('M188 158h36v14h-36ZM194 132h24v26h-24Z', '#12386F')
    c.fill('M198 138h16v16h-16Z', '#FFE89A')
    c.fill('M190 132L206 112L222 132Z', '#E4572E')
    for y, o in ((372, 0.5), (392, 0.4), (414, 0.3)):
        c.line(f'M-10 {y}c20-10 40-10 60 0s40 10 60 0 40-10 60 0', '#BFE2FF', 3, o)
    return c


def blue_mountains():
    c = Cover()
    c.sky([(0, '#0B1E48'), (0.6, '#27579E'), (1, '#7FB6EE')])
    c.circle(214, 96, 46, '#F3F8FF', 0.95)
    c.circle(214, 96, 70, '#F3F8FF', 0.12)
    c.stars(STARS[:8], '#FFFFFF', 0.8)
    c.fill('M0 250L60 186L104 226L170 150L226 220L262 190L300 232V440H0Z', '#5E94D6')
    c.fill('M170 150L150 176L166 172L176 186L192 176Z', '#EAF4FF', 0.85)
    c.fill('M0 304L70 238L128 290L196 226L250 286L300 252V440H0Z', '#3468AE')
    c.fill('M0 356L80 300L150 350L220 296L300 350V440H0Z', '#1B437F')
    c.fill('M0 400C80 376 150 392 220 384S280 388 300 380V440H0Z', '#0C2552')
    c.fill(pine(52, 398, 60, 18) + pine(82, 404, 44, 14) + pine(246, 396, 66, 20), '#081A3B')
    return c


def blue_paper_plane():
    c = Cover()
    c.sky([(0, '#2E7CD6'), (0.6, '#7DBBF5'), (1, '#E4F3FF')])
    c.glow('#FFFFFF', 80, 90, 150, 0.5)
    cloud(c, 150, 120, 1.2, '#FFFFFF', 0.9)
    cloud(c, 20, 220, 1.0, '#FFFFFF', 0.75)
    cloud(c, 170, 320, 1.4, '#FFFFFF', 0.85)
    cloud(c, -20, 380, 1.6, '#FFFFFF', 0.95)
    c.line('M40 330C90 300 96 250 140 232S190 200 196 176', '#FFFFFF', 3, 0.8, ' stroke-dasharray="2 10"')
    c.fill('M196 176L262 134L226 206L214 184Z', '#FFFFFF')
    c.fill('M214 184L262 134L222 196Z', '#BFDDF8')
    c.fill('M214 184L226 206L220 190Z', '#8FBDE8')
    return c


def blue_star_chart():
    c = Cover()
    c.sky([(0, '#071538'), (1, '#173F78')])
    c.glow('#4E9BFF', 150, 210, 190, 0.4)
    c.stars(STARS, '#FFFFFF', 0.8)
    for r, o in ((120, 0.35), (92, 0.5), (60, 0.3)):
        c.ring(150, 210, r, '#9CCBFF', 1.5, o)
    c.line('M150 80V340M20 210H280M58 118L242 302M242 118L58 302', '#9CCBFF', 1, 0.3)
    points = ((92, 150), (128, 176), (150, 210), (188, 196), (214, 232), (198, 276))
    c.line('M' + 'L'.join(f'{x} {y}' for x, y in points), '#EAF4FF', 1.6, 0.9)
    for x, y in points:
        c.circle(x, y, 4, '#FFFFFF')
    c.fill('M150 168L160 200L192 210L160 220L150 252L140 220L108 210L140 200Z', '#BFE1FF', 0.9)
    c.fill('M150 182L156 204L178 210L156 216L150 238L144 216L122 210L144 204Z', '#2A63A6')
    c.fill('M0 400C70 382 150 396 300 376V440H0Z', '#061030')
    return c


# ------------------------------------------------------------------ warm paper
def paper_window():
    c = Cover()
    c.sky([(0, '#F3DFC0'), (1, '#E2C194')])
    c.fill('M60 50h180v210H60Z', '#FBE9B8')
    c.glow('#FFF6D8', 150, 150, 170, 0.8)
    c.circle(186, 118, 34, '#F29C54', 0.9)
    c.fill('M60 210C100 184 140 196 180 188S230 190 240 180V260H60Z', '#C98B55', 0.8)
    c.line('M60 50h180v210H60ZM150 50V260M60 150H240', '#8A5632', 7)
    c.fill('M40 260h220v14H40Z', '#8A5632')
    c.fill('M0 340h300v100H0Z', '#9C6238')
    c.fill('M0 340h300v10H0Z', '#B97A49')
    for i, (color, width, x) in enumerate((('#B66A3C', 130, 70), ('#5E7F6B', 116, 78), ('#D9A679', 124, 72))):
        y = 318 - i * 24
        c.fill(f'M{x} {y}h{width}v22h-{width}Z', color)
        c.fill(f'M{x + 8} {y + 4}h{width - 16}v14h-{width - 16}Z', '#FFF4DE', 0.5)
    c.fill('M218 300h46v14c0 16-10 26-23 26s-23-10-23-26Z', '#FFF4DE')
    c.line('M264 306c14 0 14 20 0 20', '#FFF4DE', 5)
    c.line('M232 290c-6-10 6-16 0-26M248 290c-6-10 6-16 0-26', '#FFF4DE', 3, 0.7)
    return c


def paper_wheat_sunset():
    c = Cover()
    c.sky([(0, '#F7C98B'), (0.5, '#F3A568'), (1, '#E5804F')])
    c.circle(150, 190, 70, '#FFF0C9', 0.95)
    c.circle(150, 190, 104, '#FFF0C9', 0.2)
    c.fill('M0 250C70 220 130 236 190 226S260 232 300 214V440H0Z', '#B9673A')
    c.fill('M0 300C80 274 160 292 300 268V440H0Z', '#8E4A28')
    for x, lean, h in ((30, 6, 150), (64, -8, 176), (98, 10, 160), (134, -4, 190), (170, 8, 166), (206, -10, 182),
                       (240, 6, 156), (274, -6, 172)):
        top_x, top_y = x + lean, 440 - h
        c.line(f'M{x} 440Q{x + lean / 2} {440 - h / 2} {top_x} {top_y}', '#F6D48C', 2.5)
        grains = ''
        for i in range(5):
            gy = top_y + i * 12
            for side in (-1, 1):
                grains += f'M{top_x} {gy}q{side * 9}-6 {side * 7}-18q{side * -8} 6-{side * 7} 18Z'
        c.fill(grains, '#FFE7A8')
    c.line('M70 110q10-10 20 0q10-10 20 0M210 80q8-8 16 0q8-8 16 0', '#6E3A20', 2.5, 0.7)
    return c


def paper_still_life():
    c = Cover()
    c.sky([(0, '#EBD3AE'), (1, '#D9B484')])
    c.glow('#FFF3D6', 110, 130, 190, 0.75)
    c.fill('M0 320h300v120H0Z', '#8C5A3A')
    c.fill('M0 320h300v8H0Z', '#A9714A')
    c.line('M150 240C140 190 120 150 96 110M150 240C156 180 176 140 204 96M150 240C150 190 148 150 150 84', '#6A4A2E', 3)
    for x, y, a in ((96, 110, -120), (116, 150, -150), (204, 96, -60), (186, 132, -30), (150, 84, -90), (150, 130, -40),
                    (132, 180, -160), (168, 176, -20)):
        c.fill(lens(34, 9), '#7C9A76', 1, f'translate({x} {y}) rotate({a})')
    for x, y in ((96, 104), (204, 90), (150, 78), (120, 144), (186, 126)):
        c.circle(x, y, 8, '#D9603B')
    c.fill('M118 240h64c14 26 22 52 22 72c0 20-24 30-54 30s-54-10-54-30c0-20 8-46 22-72Z', '#B66A3C')
    c.fill('M118 240h64l6 14h-76Z', '#9A552C')
    c.line('M104 290c30 10 62 10 92 0', '#F2D7A8', 3, 0.7)
    c.fill('M214 300a22 22 0 1 0 .1 0Z', '#E08A3E')
    c.fill('M56 306a16 16 0 1 0 .1 0Z', '#C5512F')
    return c


def paper_balloon():
    c = Cover()
    c.sky([(0, '#F6E3C2'), (0.6, '#F3C993'), (1, '#E9A76D')])
    c.circle(232, 96, 30, '#FFF6DE', 0.9)
    cloud(c, 20, 120, 0.9, '#FFF8EA', 0.8)
    cloud(c, 190, 220, 0.8, '#FFF8EA', 0.7)
    c.fill('M150 90c46 0 76 32 76 74c0 40-40 66-60 94h-32c-20-28-60-54-60-94c0-42 30-74 76-74Z', '#B66A3C')
    c.fill('M150 90c20 0 34 32 34 74c0 40-14 66-20 94h-28c-6-28-20-54-20-94c0-42 14-74 34-74Z', '#F2D7A8')
    c.fill('M150 90c6 0 10 32 10 74c0 40-4 66-6 94h-8c-2-28-6-54-6-94c0-42 4-74 10-74Z', '#C98B55')
    c.line('M136 258l4 26M164 258l-4 26', '#6A4A2E', 2)
    c.fill('M136 284h28v20h-28Z', '#7A4C2A')
    c.fill('M0 360C70 330 140 352 200 340S270 346 300 330V440H0Z', '#B5713F')
    c.fill('M0 400C90 372 180 396 300 372V440H0Z', '#84492A')
    c.fill(pine(40, 398, 40, 12) + pine(250, 386, 48, 14) + pine(226, 392, 34, 10), '#5C3320')
    return c


# ----------------------------------------------------------------- forest mist
def forest_morning():
    c = Cover()
    c.sky([(0, '#CFE6D6'), (0.6, '#EAF4E6'), (1, '#F7F3DC')])
    c.circle(200, 120, 40, '#FFFBE6', 0.95)
    c.circle(200, 120, 74, '#FFFBE6', 0.3)
    c.fill(''.join(pine(x, 300, h, w) for x, h, w in ((20, 150, 44), (70, 190, 52), (130, 140, 40), (190, 200, 56),
                                                   (250, 160, 46), (292, 190, 50))), '#9CC2AA')
    c.fill('M-20 262h340v46h-340Z', '#F4FAF2', 0.7)
    c.fill(''.join(pine(x, 370, h, w) for x, h, w in ((0, 200, 60), (60, 150, 46), (118, 220, 64), (184, 160, 48),
                                                   (238, 230, 66), (296, 170, 50))), '#4E8A68')
    c.fill('M-20 338h340v40h-340Z', '#EEF7EE', 0.55)
    c.fill(''.join(pine(x, 450, h, w) for x, h, w in ((30, 190, 70), (110, 150, 56), (200, 210, 76), (280, 160, 60))),
           '#1F4A36')
    return c


def forest_cabin():
    c = Cover()
    c.sky([(0, '#16332A'), (0.6, '#2F6650'), (1, '#8CC0A0')])
    c.circle(70, 90, 26, '#F4F8D8', 0.95)
    c.stars(STARS[2:10], '#F4F8D8', 0.7)
    c.fill(''.join(pine(x, 320, h, w) for x, h, w in ((10, 190, 54), (64, 230, 60), (236, 240, 62), (290, 200, 56))),
           '#1E4A39')
    c.fill('M0 320C80 300 200 300 300 318V440H0Z', '#143327')
    c.fill('M110 250h90v70h-90Z', '#6B4630')
    c.fill('M98 254L155 204L212 254Z', '#3A2318')
    c.fill('M146 284h20v36h-20Z', '#2A1810')
    c.fill('M120 268h18v18h-18ZM172 268h18v18h-18Z', '#FFD97A')
    c.glow('#FFD97A', 155, 280, 70, 0.35)
    c.fill('M182 216h12v24h-12Z', '#3A2318')
    c.line('M188 210c-8-12 8-18 0-32s8-18 0-32', '#DCEBDD', 5, 0.45)
    c.fill('M150 320C150 360 120 390 90 440H170C180 400 176 360 166 320Z', '#3F7A5C', 0.7)
    c.fill(pine(44, 440, 110, 40) + pine(262, 440, 130, 46), '#0C2219')
    return c


def forest_deer():
    c = Cover()
    c.sky([(0, '#DCEBDD'), (1, '#A9CDB5')])
    c.circle(150, 170, 92, '#F8FBEF', 0.95)
    c.fill(''.join(pine(x, 330, h, w) for x, h, w in ((16, 170, 46), (62, 130, 38), (250, 150, 42), (292, 190, 50))),
           '#6FA487')
    c.fill('M0 300C70 268 130 262 180 270S260 290 300 280V440H0Z', '#2F6650')
    deer = ('M0 0c10-4 22-4 34 0l8-18c2-6 0-12-4-18l6-2 6 12 8-2-2 10c4 2 4 8 0 10l-8 2-4 22c8 6 10 16 10 28l-4 34h-6l0-30'
            'l-10-14-22 2-6 16 2 26h-6l-6-28-4-22c-4-8-4-20 4-28Z')
    c.fill(deer, '#16332A', 1, 'translate(118 196) scale(1.15)')
    c.line('M168 172c-6-12-4-20 2-28M168 172c2-14 10-20 20-22M172 160c-8-4-12-10-12-18M176 156c8-2 14-8 16-16', '#16332A',
           3, 1, '', 'translate(-1 4)')
    c.fill('M0 350C90 320 200 336 300 316V440H0Z', '#1E4A39')
    c.fill(pine(30, 440, 120, 42) + pine(270, 440, 140, 48), '#0F2A20')
    return c


def forest_stream():
    c = Cover()
    c.sky([(0, '#BFE0CC'), (1, '#EDF6E8')])
    c.glow('#FFFFFF', 150, 120, 170, 0.7)
    c.fill('M0 200L60 130L110 180L170 110L230 176L300 130V440H0Z', '#8FBFA4')
    c.fill(''.join(pine(x, 250, h, w) for x, h, w in ((20, 90, 28), (56, 110, 32), (240, 100, 30), (280, 120, 34))),
           '#5E9A7B')
    c.fill('M0 240C90 222 210 222 300 240V440H0Z', '#3C7A5C')
    c.fill('M150 236C120 280 190 300 150 340S70 390 60 440H220C230 400 250 370 200 330S180 270 162 236Z', '#CDEBF2')
    c.line('M140 290c14 4 26 4 36 0M110 370c20 6 44 6 66 0M96 412c26 6 60 6 90 0', '#FFFFFF', 2.5, 0.8)
    for x, y, a, s in ((30, 440, -70, 1.3), (30, 440, -100, 1.1), (30, 440, -40, 1.0), (270, 440, -110, 1.3),
                       (270, 440, -80, 1.1), (270, 440, -140, 1.0)):
        t = f'translate({x} {y}) rotate({a}) scale({s})'
        c.line('M0 0C30-6 60-4 90 4', '#1E4A39', 2.5, 1, '', t)
        d = ''
        for i in range(1, 8):
            px = i * 11
            size = 15 - i * 1.2
            for side in (-1, 1):
                d += f'M{px} 0q{size * 0.5:.0f} {side * size * 0.9:.0f} {size * 1.2:.0f} {side * size:.0f}q-{size * 0.9:.0f} {side * -size * 0.2:.0f}-{size * 1.2:.0f}-{side * size:.0f}Z'
        c.fill(d, '#1E4A39', 1, t)
    return c


# -------------------------------------------------------------------- ink wash
def ink_boat():
    c = Cover()
    c.sky([(0, '#ECE9DF'), (1, '#DAD6CA')])
    c.circle(214, 96, 26, '#B74747', 0.9)
    c.fill('M0 210C40 196 70 140 110 126S170 176 206 168 262 110 300 130V300H0Z', '#4E5D6C', 0.22)
    c.fill('M0 262C50 244 80 196 130 188S208 232 250 224 280 196 300 204V330H0Z', '#30363A', 0.36)
    c.fill('M0 300C60 284 120 262 170 264S250 296 300 288V340H0Z', '#1C2023', 0.6)
    c.fill('M0 318h300v122H0Z', '#E4E1D6', 0.7)
    c.fill('M96 366h80l-14 16h-52Z', '#1C2023')
    c.line('M132 366V330', '#1C2023', 2.5)
    c.fill('M132 332l26 30h-26Z', '#30363A', 0.7)
    c.line('M60 396h70M150 404h96M90 420h50M190 384h60', '#4E5D6C', 1.5, 0.5)
    c.line('M60 150q8-8 16 0q8-8 16 0M100 120q6-6 12 0q6-6 12 0', '#1C2023', 2, 0.7)
    return c


def ink_bamboo():
    c = Cover()
    c.sky([(0, '#F0EEE5'), (1, '#DEDACE')])
    c.fill('M150 340a130 60 0 1 0 .1 0Z', '#4E5D6C', 0.1)
    c.line('M92 450C90 330 86 190 78-10', '#1C2023', 12, 0.85, ' stroke-dasharray="78 6"')
    c.line('M150 450C150 340 154 200 162-10', '#30363A', 9, 0.6, ' stroke-dasharray="64 6"')
    c.line('M214 450C216 360 222 250 232 60', '#4E5D6C', 6, 0.4, ' stroke-dasharray="52 5"')
    c.line('M86 156C120 140 150 140 180 152M156 232C190 220 214 224 240 238M82 290C60 280 40 282 20 292', '#1C2023', 2.5,
           0.8)
    leaves = ((180, 152, 70, 20, 9), (180, 152, 60, 60, 8), (180, 152, 64, -18, 8), (240, 238, 66, 30, 9),
              (240, 238, 58, 70, 8), (240, 238, 60, -10, 8), (20, 292, 60, 150, 8), (20, 292, 54, 110, 7),
              (20, 292, 56, 190, 7), (120, 70, 60, 36, 8), (120, 70, 54, 74, 7))
    for x, y, length, angle, width in leaves:
        c.fill(lens(length, width), '#1C2023', 0.82, f'translate({x} {y}) rotate({angle})')
    c.fill('M232 372h34v34h-34Z', '#B74747', 0.9)
    c.line('M241 382h16v14h-16ZM249 382v14', '#F0EEE5', 2)
    return c


def ink_pine_moon():
    c = Cover()
    c.sky([(0, '#D8D5CA'), (1, '#ECE9DF')])
    c.circle(96, 130, 62, '#F7F5EC')
    c.circle(96, 130, 84, '#F7F5EC', 0.4)
    c.line('M310 90C250 104 220 150 170 160S100 190 60 250', '#1C2023', 12, 0.9)
    c.line('M236 122C230 90 210 70 184 56M170 160C176 200 166 232 140 260M110 202C90 190 70 186 46 190', '#1C2023', 6, 0.9)
    pads = ((184, 52, 46, 9), (140, 262, 44, 9), (46, 188, 40, 8), (250, 96, 44, 9), (96, 222, 36, 7), (210, 150, 40, 8))
    for x, y, rx, ry in pads:
        c.add(f'<ellipse cx="{x}" cy="{y}" rx="{rx}" ry="{ry}" fill="#30363A" fill-opacity="0.75"/>')
        needles = ''.join(f'M{x + dx} {y}l{dx * 0.16:.0f}-{14 - abs(dx) * 0.12:.0f}' for dx in range(-rx + 6, rx, 8))
        c.line(needles, '#1C2023', 1.6, 0.7)
    c.fill('M0 360C60 340 110 352 170 344S250 350 300 336V440H0Z', '#4E5D6C', 0.25)
    c.fill('M0 396C80 374 180 392 300 370V440H0Z', '#30363A', 0.45)
    c.fill('M30 384h30v30h-30Z', '#B74747', 0.9)
    return c


def ink_geese():
    c = Cover()
    c.sky([(0, '#E6E3D8'), (0.7, '#F2F0E7'), (1, '#DCD8CC')])
    c.circle(210, 130, 40, '#B74747', 0.75)
    c.fill('M0 250C60 236 110 240 160 232S250 238 300 226V300H0Z', '#4E5D6C', 0.2)
    for i, (x, y) in enumerate(((150, 80), (120, 100), (180, 102), (92, 122), (210, 126), (64, 146))):
        s = 1 - i * 0.06
        c.line(f'M{x - 14 * s:.0f} {y + 6 * s:.0f}q{7 * s:.0f}-{10 * s:.0f} {14 * s:.0f}-{2 * s:.0f}'
               f'q{7 * s:.0f}-{8 * s:.0f} {14 * s:.0f}{2 * s:.0f}', '#1C2023', 2.6, 0.85)
    c.line('M20 300h90M140 312h120M60 330h70M190 290h80', '#4E5D6C', 1.5, 0.45)
    for x, lean, h in ((30, 10, 170), (52, -6, 200), (78, 14, 150), (238, -12, 190), (262, 8, 220), (284, -6, 160)):
        c.line(f'M{x} 450Q{x + lean / 2} {450 - h / 2} {x + lean} {450 - h}', '#1C2023', 2.5, 0.85)
        c.fill(f'M{x + lean - 4} {450 - h + 30}q4-34 6-40q6 14 2 40Z', '#30363A', 0.85)
    c.fill('M0 410C80 396 200 404 300 392V440H0Z', '#1C2023', 0.5)
    return c


# ------------------------------------------------------------------ neon night
def neon_grid(c, horizon, color):
    grid = ''.join(f'M150 {horizon}L{x} 440' for x in range(-450, 751, 100))
    step, y = 8, horizon
    while y < 440:
        y += step
        step *= 1.5
        grid += f'M0 {y:.0f}H300'
    c.line(grid, color, 1.5, 0.7)


def neon_sun(c, cx, cy, r, top, bottom):
    for i in range(9):
        y = cy - r + i * (2 * r / 9)
        half = math.sqrt(max(0, r * r - (y + r / 9 - cy) ** 2))
        height = max(4, 2 * r / 9 - i * 1.6)
        color = top if i < 4 else bottom
        c.add(f'<rect x="{cx - half:.0f}" y="{y:.0f}" width="{half * 2:.0f}" height="{height:.0f}" '
              f'rx="{height / 2:.0f}" fill="{color}"/>')


def neon_synthwave():
    c = Cover()
    c.sky([(0, '#0B0620'), (0.6, '#3A1466'), (1, '#8A2B8F')])
    c.stars(STARS[:10], '#FFFFFF', 0.8)
    c.glow('#FF4D8D', 150, 200, 150, 0.45)
    neon_sun(c, 150, 190, 78, '#FFD166', '#FF4D8D')
    c.fill('M0 290V250h20v-30h26v44h18v-66h30v80h22v-40h24v52ZM160 290v-56h22v-34h26v50h20v-76h30v96h22v-36h20v56Z',
           '#12082E')
    c.fill('M0 290h300v150H0Z', '#0B0620')
    c.line('M0 290H300', '#00D5FF', 2.5)
    neon_grid(c, 290, '#00D5FF')
    return c


def neon_rain_street():
    c = Cover()
    c.sky([(0, '#070B1E'), (1, '#1B1140')])
    c.glow('#8A5CFF', 150, 300, 220, 0.4)
    c.fill('M0 440V90h70v350ZM230 440V60h70v380Z', '#0D1230')
    c.fill('M80 440V160h60v280ZM156 440V200h60v240Z', '#141A40')
    windows = ''
    for bx, by, cols, rows in ((10, 110, 3, 12), (240, 80, 3, 14), (88, 180, 3, 9), (164, 220, 3, 7)):
        for row in range(rows):
            for col in range(cols):
                if (row * 3 + col * 5 + bx) % 4:
                    windows += f'M{bx + col * 17} {by + row * 24}h9v12h-9Z'
    c.fill(windows, '#FFD166', 0.55)
    c.add('<rect x="86" y="120" width="26" height="92" rx="5" fill="none" stroke="#FF4D8D" stroke-width="3"/>')
    c.line('M94 136h10M94 152h10M94 168h10M94 184h10', '#FF4D8D', 3)
    c.add('<rect x="172" y="150" width="74" height="28" rx="6" fill="none" stroke="#00D5FF" stroke-width="3"/>')
    c.line('M184 164h14M206 164h8M222 164h12', '#00D5FF', 3)
    c.ring(46, 62, 16, '#8A5CFF', 3)
    rain = ''.join(f'M{x} {y}l-6 22' for x in range(10, 300, 22) for y in range(10 + (x * 7) % 60, 430, 96))
    c.line(rain, '#BFE9FF', 1.2, 0.45)
    c.fill('M0 400h300v40H0Z', '#070B1E')
    c.line('M20 414h60M110 424h90M220 412h60', '#FF4D8D', 2, 0.5)
    c.line('M60 430h50M170 408h40', '#00D5FF', 2, 0.5)
    return c


def neon_planet():
    c = Cover()
    c.sky([(0, '#060818'), (1, '#1A0F3D')])
    c.stars(STARS, '#FFFFFF', 0.85)
    c.glow('#00D5FF', 150, 190, 170, 0.3)
    c.circle(150, 190, 72, '#8A5CFF')
    c.fill('M82 170a72 72 0 0 1 130-36C170 130 120 144 82 170Z', '#B69CFF', 0.6)
    c.fill('M90 228c40 8 90 0 128-24a72 72 0 0 1-128 24Z', '#5A2FD0', 0.8)
    c.add('<ellipse cx="150" cy="190" rx="124" ry="26" fill="none" stroke="#00D5FF" stroke-width="4" '
          'transform="rotate(-18 150 190)" stroke-dasharray="330 150" stroke-dashoffset="-70"/>')
    c.add('<ellipse cx="150" cy="190" rx="104" ry="18" fill="none" stroke="#FF4D8D" stroke-width="2" '
          'transform="rotate(-18 150 190)" stroke-dasharray="270 130" stroke-dashoffset="-60"/>')
    c.circle(244, 92, 10, '#FF4D8D')
    c.fill('M0 330h300v110H0Z', '#060818')
    c.line('M0 330H300', '#FF4D8D', 2)
    neon_grid(c, 330, '#FF4D8D')
    return c


def neon_wire_mountains():
    c = Cover()
    c.sky([(0, '#120A2E'), (0.7, '#3B1B7A'), (1, '#FF4D8D')])
    c.stars(STARS[:9], '#FFFFFF', 0.8)
    neon_sun(c, 150, 210, 64, '#FFE08A', '#FF7A59')
    c.fill('M0 300L50 220L90 262L150 170L206 256L250 214L300 286V330H0Z', '#120A2E')
    c.line('M0 300L50 220L90 262L150 170L206 256L250 214L300 286', '#00D5FF', 2.5)
    c.line('M50 220L60 300M90 262L96 304M150 170L140 300M150 170L170 302M206 256L204 304M250 214L246 300M50 220L90 262'
           'M150 170L90 262M150 170L206 256M250 214L206 256', '#00D5FF', 1.2, 0.6)
    c.fill('M0 304h300v136H0Z', '#0B0620')
    c.line('M0 304H300', '#FF4D8D', 2.5)
    neon_grid(c, 304, '#8A5CFF')
    return c


COVERS = {
    'classic_blue': (blue_lighthouse, blue_mountains, blue_paper_plane, blue_star_chart),
    'warm_paper': (paper_window, paper_wheat_sunset, paper_still_life, paper_balloon),
    'forest_mist': (forest_morning, forest_cabin, forest_deer, forest_stream),
    'ink_wash': (ink_boat, ink_bamboo, ink_pine_moon, ink_geese),
    'neon_night': (neon_synthwave, neon_rain_street, neon_planet, neon_wire_mountains),
}


def main():
    count = 0
    for name, scenes in COVERS.items():
        for index, draw in enumerate(scenes, start=1):
            with open(os.path.join(OUT, f'theme_cover_{name}_{index:02d}.svg'), 'w', encoding='utf-8', newline='\n') as f:
                f.write(draw().svg())
            count += 1
    print(f'Generated {count} theme covers.')


if __name__ == '__main__':
    main()
