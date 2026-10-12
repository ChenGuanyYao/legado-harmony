"""Generates the vector assets of the two anime themes, Azure Mecha and Starwish Magic.

Covers navigation icons, theme logo, shelf frame, emphasis bubble frame and cap, the
top-left reader ornament and the legacy full-page reader background. Their bottom-right
reader ornaments and player panel artwork live in generate-reader-trailing-ornaments.py
and generate-tts-panel-backgrounds.py; the painted covers and startup art are bitmaps.

Usage: python scripts/generate-anime-theme-assets.py
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'entry', 'src', 'main', 'resources', 'base',
                   'media')


def svg(width, height, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
            f'viewBox="0 0 {width} {height}">\n  {body}\n</svg>\n')


def icon(d):
    return svg(24, 24, f'<path fill-rule="evenodd" d="{d}" fill="#000"/>')


FILES = {}

# ---------------------------------------------------------------- Azure Mecha
FILES['ic_theme_azure_mecha_bookshelf'] = icon(
    'M4 3h13l3 3v15H4ZM7 8v2h10V8ZM7 12v2h10v-2ZM7 16v2h6v-2Z')
FILES['ic_theme_azure_mecha_explore'] = icon(
    'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20ZM12 4a8 8 0 1 1 0 16 8 8 0 0 1 0-16ZM12 7a5 5 0 1 0 5 5h-5Z')
FILES['ic_theme_azure_mecha_search'] = icon(
    'M11 3a8 8 0 1 0 5 14.2l4.4 4.4 1.4-1.4-4.4-4.4A8 8 0 0 0 11 3ZM11 5a6 6 0 1 1 0 12 6 6 0 0 1 0-12Z'
    'M10 7v3H7v2h3v3h2v-3h3v-2h-3V7Z')
FILES['ic_theme_azure_mecha_mine'] = icon(
    'M12 2c-5 0-8 3.6-8 8.5V17l3 4h10l3-4v-6.5C20 5.6 17 2 12 2ZM7 11h10v3H7Z')

FILES['theme_logo_azure_mecha'] = svg(64, 64, '\n  '.join([
    '<rect x="3" y="3" width="58" height="58" rx="9" fill="#EEF2F6" stroke="#2F6FB3" stroke-width="2"/>',
    '<path d="M32 10c-12 0-19 9-19 21v11l7 10h24l7-10V31c0-12-7-21-19-21Z" fill="#FFFFFF" stroke="#1C2836" stroke-width="2"/>',
    '<path d="M16 30h32v8H16Z" fill="#1C2836"/>',
    '<path d="M18 32h28v4H18Z" fill="#3FD3E6"/>',
    '<path d="M29 10h6v14h-6Z" fill="#2F6FB3"/>',
    '<path d="M22 46h20l-3 5H25Z" fill="#E8731F"/>',
]))

FILES['theme_frame_azure_mecha'] = svg(300, 440, '\n  '.join([
    '<path d="M22 7h256l15 15v396l-15 15H22L7 418V22Z" fill="none" stroke="#1C2836" stroke-opacity=".6" stroke-width="2"/>',
    '<path d="M7 86V22L22 7h64M214 7h64l15 15v64M293 354v64l-15 15h-64M86 433H22L7 418v-64" fill="none" stroke="#2F6FB3" stroke-width="5" stroke-linejoin="round"/>',
    '<path d="M100 7h30M170 433h30" stroke="#E8731F" stroke-width="5"/>',
    '<path d="M14 110v12M14 128v12M14 146v12M286 282v12M286 300v12M286 318v12" stroke="#3FD3E6" stroke-width="3"/>',
]))

FILES['regex_cap_mecha_comm'] = svg(32, 32,
    '<path d="M5 7h7l11 9-11 9H5l11-9Z" fill="#2F6FB3"/><path d="M17 11h4l6 5-6 5h-4l6-5Z" fill="#E8731F"/>')
FILES['regex_frame_mecha_comm'] = svg(1000, 260, '\n  '.join([
    '<path d="M44 4h912l40 40v172l-40 40H44L4 216V44Z" fill="#DCEBFA" fill-opacity=".16" stroke="#2F6FB3" stroke-opacity=".7" stroke-width="4"/>',
    '<path d="M4 110V44L44 4h110M996 150v66l-40 40H846" fill="none" stroke="#2F6FB3" stroke-width="10"/>',
    '<path d="M190 4h70M740 256h70" stroke="#E8731F" stroke-width="10"/>',
    '<path d="M60 236h18M90 236h18M120 236h18M862 24h18M892 24h18M922 24h18" stroke="#3FD3E6" stroke-opacity=".8" stroke-width="6"/>',
]))


def mecha_decor(ink, cyan, orange):
    hexes = ''
    for cx, cy in ((300, 70), (345, 96), (300, 122), (390, 70), (345, 148)):
        hexes += f'M{cx - 26} {cy}l13-22h26l13 22-13 22h-26Z'
    ticks = ''.join(f'M{18 + i * 14} 150v{16 if i % 5 == 0 else 8}' for i in range(15))
    return svg(480, 480, '\n  '.join([
        f'<path d="M12 190V40l28-28h200" fill="none" stroke="{ink}" stroke-opacity=".34" stroke-width="3"/>',
        f'<path d="M12 96V40l28-28h70" fill="none" stroke="{ink}" stroke-opacity=".5" stroke-width="7"/>',
        f'<path d="M130 12h46" stroke="{orange}" stroke-opacity=".7" stroke-width="7"/>',
        f'<path d="{hexes}" fill="none" stroke="{ink}" stroke-opacity=".16" stroke-width="2"/>',
        f'<path d="M274 70l13-22h26l13 22-13 22h-26Z" fill="{ink}" fill-opacity=".10"/>',
        f'<path d="{ticks}" stroke="{ink}" stroke-opacity=".28" stroke-width="2"/>',
        f'<path d="M30 60h74M30 76h52M30 92h62" stroke="{ink}" stroke-opacity=".2" stroke-width="5"/>',
        f'<circle cx="96" cy="250" r="34" fill="none" stroke="{cyan}" stroke-opacity=".3" stroke-width="3"/>',
        f'<path d="M96 204v20M96 276v20M50 250h20M122 250h20" stroke="{cyan}" stroke-opacity=".4" stroke-width="3"/>',
        f'<circle cx="96" cy="250" r="5" fill="{orange}" fill-opacity=".6"/>',
    ]))


def mecha_legacy(background, ink, cyan, orange):
    return svg(1080, 1920, '\n  '.join([
        f'<rect width="1080" height="1920" fill="{background}"/>',
        f'<path d="M40 420V110l70-70h420" fill="none" stroke="{ink}" stroke-opacity=".14" stroke-width="6"/>',
        f'<path d="M560 40h110" stroke="{orange}" stroke-opacity=".3" stroke-width="12"/>',
        f'<path d="M1040 1500v310l-70 70H550" fill="none" stroke="{ink}" stroke-opacity=".14" stroke-width="6"/>',
        f'<circle cx="880" cy="1700" r="110" fill="none" stroke="{cyan}" stroke-opacity=".16" stroke-width="5"/>',
        f'<circle cx="880" cy="1700" r="70" fill="none" stroke="{cyan}" stroke-opacity=".12" stroke-width="4"/>',
    ]))


FILES['reader_decor_azure_mecha_light'] = mecha_decor('#2F6FB3', '#2A9DB0', '#E8731F')
FILES['reader_decor_azure_mecha_dark'] = mecha_decor('#8FB6DE', '#3FD3E6', '#F08A3C')
FILES['reader_bg_azure_mecha_light'] = mecha_legacy('#F1F4F7', '#2F6FB3', '#2A9DB0', '#E8731F')
FILES['reader_bg_azure_mecha_dark'] = mecha_legacy('#0D141D', '#8FB6DE', '#3FD3E6', '#F08A3C')

# ------------------------------------------------------------- Starwish Magic
def star4(cx, cy, r):
    inner = round(r * 0.3, 1)
    outer = round(r - inner, 1)
    return (f'M{cx} {cy - r}l{inner} {outer} {outer} {inner}-{outer} {inner}-{inner} {outer}'
            f'-{inner}-{outer}-{outer}-{inner} {outer}-{inner}Z')


FILES['ic_theme_starwish_magic_bookshelf'] = icon(
    'M5 3h12a2 2 0 0 1 2 2v16H7a2 2 0 0 1-2-2Z' + star4(12, 11, 5))
FILES['ic_theme_starwish_magic_explore'] = icon(
    'M12 2a8 8 0 0 0-5.3 14H6l-1 5h14l-1-5h-.7A8 8 0 0 0 12 2ZM12 4a6 6 0 1 1 0 12 6 6 0 0 1 0-12Z'
    + star4(12, 10, 3.5))
FILES['ic_theme_starwish_magic_search'] = icon(
    'M10.5 2a8.5 8.5 0 1 0 5.3 15.1l4.5 4.5 1.4-1.4-4.5-4.5A8.5 8.5 0 0 0 10.5 2Z'
    'M10.5 4a6.5 6.5 0 1 1 0 13 6.5 6.5 0 0 1 0-13Z' + star4(10.5, 10.5, 4))
FILES['ic_theme_starwish_magic_mine'] = icon(
    'M12 10.5C9 6 4 5 3 7v8c1 2 6 1 9-3.5 3 4.5 8 5.5 9 3.5V7c-1-2-6-1-9 3.5ZM10 13l-2.5 8 3.5-2.5 1-5.5 1 5.5'
    ' 3.5 2.5-2.5-8Z')

FILES['theme_logo_starwish_magic'] = svg(64, 64, '\n  '.join([
    '<rect x="3" y="3" width="58" height="58" rx="18" fill="#F8F4FC" stroke="#9A74D6" stroke-width="2"/>',
    '<path d="M38 12a22 22 0 1 0 14 34a18 18 0 1 1-14-34Z" fill="#E3BE58"/>',
    f'<path d="{star4(40, 30, 13)}" fill="#9A74D6"/>',
    f'<path d="{star4(22, 20, 5)}{star4(50, 48, 4)}" fill="#C3A2F2"/>',
]))

FILES['theme_frame_starwish_magic'] = svg(300, 440, '\n  '.join([
    '<rect x="7" y="7" width="286" height="426" rx="20" fill="none" stroke="#9A74D6" stroke-opacity=".7" stroke-width="2"/>',
    '<path d="M8 80V28Q8 8 28 8h54M218 432h54q20 0 20-20v-52" fill="none" stroke="#C3A2F2" stroke-width="5" stroke-linecap="round"/>',
    '<path d="M292 96c-22 6-34 22-30 44M8 344c22-6 34-22 30-44" fill="none" stroke="#E3BE58" stroke-width="3" stroke-linecap="round"/>',
    f'<path d="{star4(26, 26, 13)}{star4(274, 414, 13)}" fill="#E3BE58"/>',
    f'<path d="{star4(278, 24, 7)}{star4(22, 416, 7)}{star4(262, 140, 5)}{star4(38, 300, 5)}" fill="#C3A2F2"/>',
]))

FILES['regex_cap_starwish_ribbon'] = svg(32, 32,
    f'<path d="{star4(16, 16, 13)}" fill="#E3BE58"/><path d="{star4(16, 16, 6)}" fill="#FFF6D8"/>')
FILES['regex_frame_starwish_ribbon'] = svg(1000, 260, '\n  '.join([
    '<rect x="4" y="4" width="992" height="252" rx="96" fill="#F3EAFB" fill-opacity=".2" stroke="#9A74D6" stroke-opacity=".65" stroke-width="4"/>',
    '<path d="M120 20c80 18 150 10 210-4M670 244c70-16 140-16 210 0" fill="none" stroke="#C3A2F2" stroke-opacity=".7" stroke-width="5" stroke-linecap="round"/>',
    f'<path d="{star4(70, 70, 30)}{star4(930, 190, 30)}" fill="#E3BE58" fill-opacity=".85"/>',
    f'<path d="{star4(120, 190, 14)}{star4(880, 66, 14)}" fill="#C3A2F2"/>',
]))


def magic_decor(violet, pale, gold):
    return svg(480, 480, '\n  '.join([
        f'<path d="M0 0h480v40c-70 30-140 30-210 8C200 26 130 30 60 58 36 68 16 70 0 66Z" fill="{pale}" fill-opacity=".34"/>',
        f'<path d="M70 0c-6 70 10 120-14 190M150 0c4 60-12 96 6 150M236 0c-4 40 8 66-2 104" fill="none" stroke="{violet}" stroke-opacity=".42" stroke-width="4" stroke-linecap="round"/>',
        f'<path d="{star4(56, 214, 24)}{star4(156, 172, 20)}{star4(234, 122, 16)}" fill="{gold}" fill-opacity=".85"/>',
        f'<path d="M352 40a62 62 0 1 0 40 96a50 50 0 1 1-40-96Z" fill="{gold}" fill-opacity=".5"/>',
        f'<path d="M0 104c60-22 104 6 150-18s96-30 150-6" fill="none" stroke="{violet}" stroke-opacity=".24" stroke-width="7" stroke-linecap="round"/>',
        f'<path d="{star4(300, 196, 9)}{star4(96, 300, 8)}{star4(196, 250, 6)}{star4(420, 220, 7)}{star4(40, 372, 6)}" fill="{violet}" fill-opacity=".5"/>',
    ]))


def magic_legacy(background, violet, gold):
    return svg(1080, 1920, '\n  '.join([
        f'<rect width="1080" height="1920" fill="{background}"/>',
        f'<path d="M150 0c-14 160 22 270-30 430M330 0c10 130-26 210 14 330" fill="none" stroke="{violet}" stroke-opacity=".16" stroke-width="8" stroke-linecap="round"/>',
        f'<path d="{star4(120, 480, 50)}{star4(344, 380, 40)}" fill="{gold}" fill-opacity=".3"/>',
        f'<path d="M860 1560a130 130 0 1 0 84 200a104 104 0 1 1-84-200Z" fill="{gold}" fill-opacity=".2"/>',
        f'<path d="{star4(700, 1700, 26)}{star4(960, 1500, 20)}" fill="{violet}" fill-opacity=".2"/>',
    ]))


FILES['reader_decor_starwish_magic_light'] = magic_decor('#9A74D6', '#E2D0F5', '#D9B24C')
FILES['reader_decor_starwish_magic_dark'] = magic_decor('#C3A2F2', '#4A3878', '#E8C76A')
FILES['reader_bg_starwish_magic_light'] = magic_legacy('#FBF7FD', '#9A74D6', '#D9B24C')
FILES['reader_bg_starwish_magic_dark'] = magic_legacy('#171226', '#C3A2F2', '#E8C76A')


def main():
    for name, content in FILES.items():
        with open(os.path.join(OUT, name + '.svg'), 'w', encoding='utf-8', newline='\n') as f:
            f.write(content)
    print(f'Generated {len(FILES)} anime theme assets.')


if __name__ == '__main__':
    main()
