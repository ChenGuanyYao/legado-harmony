from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "output" / "app_intro_v2"
ASSETS = OUT / "assets"

CANVAS = (1080, 1920)
STATUS_BAR_CROP = 124
FONT_REGULAR = Path(r"C:\Windows\Fonts\msyh.ttc")
FONT_BOLD = Path(r"C:\Windows\Fonts\msyhbd.ttc")


POSTERS = [
    {
        "title": "雅致书架\n万卷成景",
        "subtitle": "网络 / 本地 · 进度与分类一目了然",
        "tag": "梅影书架",
        "bg": "bg-01.png",
        "screen": "screen-01.jpg",
        "accent": (75, 118, 97),
    },
    {
        "title": "主题成套\n风格随心",
        "subtitle": "草莓、赤墨、梅影与玫瑰，自由切换",
        "tag": "主题美学",
        "bg": "bg-02.png",
        "screen": "screen-02.jpg",
        "accent": (170, 83, 91),
    },
    {
        "title": "图文相融\n一页入境",
        "subtitle": "插图、正文与标注，排版自然舒展",
        "tag": "沉浸阅读",
        "bg": "bg-03.png",
        "screen": "screen-03.jpg",
        "accent": (139, 66, 43),
    },
    {
        "title": "磨砂玻璃\n质感可调",
        "subtitle": "模糊、透明、边框与圆角，细节自定义",
        "tag": "磨砂面板",
        "bg": "bg-04.png",
        "screen": "screen-04.jpg",
        "accent": (70, 123, 93),
    },
    {
        "title": "听书随行\n倍速可调",
        "subtitle": "定时、倍速与朗读控制，释放双眼",
        "tag": "智能朗读",
        "bg": "bg-05.png",
        "screen": "screen-05.jpg",
        "accent": (93, 128, 91),
    },
]


def font(path: Path, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(path), size=size)


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius, fill=255)
    return mask


def cover(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    return ImageOps.fit(image.convert("RGB"), size, method=Image.Resampling.LANCZOS)


def crop_status_bar(image: Image.Image) -> Image.Image:
    """Remove the HarmonyOS/system status bar before any resizing occurs."""
    if image.height <= STATUS_BAR_CROP:
        raise ValueError("Screenshot is too short for status-bar cropping")
    return image.crop((0, STATUS_BAR_CROP, image.width, image.height))


def add_top_readability(base: Image.Image) -> None:
    overlay = Image.new("RGBA", CANVAS, (0, 0, 0, 0))
    px = overlay.load()
    for y in range(500):
        alpha = int(185 * (1 - y / 500) ** 1.65)
        for x in range(CANVAS[0]):
            px[x, y] = (250, 247, 237, alpha)
    base.alpha_composite(overlay)


def add_phone(base: Image.Image, screenshot_path: Path) -> None:
    screen_w, screen_h = 650, 1396
    border = 13
    frame_w, frame_h = screen_w + border * 2, screen_h + border * 2
    x = (CANVAS[0] - frame_w) // 2
    y = 470

    shadow = Image.new("RGBA", CANVAS, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle(
        (x - 12, y + 10, x + frame_w + 12, y + frame_h + 34),
        radius=54,
        fill=(25, 31, 27, 76),
    )
    base.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(28)))

    frame = Image.new("RGBA", (frame_w, frame_h), (0, 0, 0, 0))
    fd = ImageDraw.Draw(frame)
    fd.rounded_rectangle(
        (0, 0, frame_w - 1, frame_h - 1),
        radius=44,
        fill=(250, 249, 244, 252),
        outline=(255, 255, 255, 220),
        width=2,
    )

    with Image.open(screenshot_path) as source:
        status_free = crop_status_bar(source.convert("RGB"))
        screen = cover(status_free, (screen_w, screen_h)).convert("RGBA")
    screen.putalpha(rounded_mask((screen_w, screen_h), 34))
    frame.alpha_composite(screen, (border, border))
    base.alpha_composite(frame, (x, y))

    highlight = Image.new("RGBA", CANVAS, (0, 0, 0, 0))
    ImageDraw.Draw(highlight).rounded_rectangle(
        (x + 5, y + 5, x + frame_w - 6, y + frame_h - 6),
        radius=42,
        outline=(255, 255, 255, 78),
        width=2,
    )
    base.alpha_composite(highlight)


def add_copy(base: Image.Image, item: dict, index: int) -> None:
    ink = (45, 47, 39, 255)
    muted = (92, 87, 73, 235)
    accent = item["accent"]
    draw = ImageDraw.Draw(base)

    tag_font = font(FONT_BOLD, 27)
    tag_text = f"0{index}  ·  {item['tag']}"
    tag_box = draw.textbbox((0, 0), tag_text, font=tag_font)
    tag_w = tag_box[2] - tag_box[0] + 46
    draw.rounded_rectangle(
        (70, 58, 70 + tag_w, 114),
        radius=28,
        fill=(*accent, 225),
        outline=(255, 255, 255, 105),
        width=1,
    )
    draw.text((93, 69), tag_text, font=tag_font, fill=(255, 255, 250, 255))

    title_font = font(FONT_BOLD, 76)
    draw.multiline_text((70, 128), item["title"], font=title_font, fill=ink, spacing=2)

    subtitle_font = font(FONT_REGULAR, 31)
    draw.text((72, 337), item["subtitle"], font=subtitle_font, fill=muted)

    line_y = 390
    draw.rounded_rectangle((72, line_y, 136, line_y + 6), radius=3, fill=(*accent, 255))
    draw.ellipse((147, line_y - 2, 157, line_y + 8), fill=(*accent, 190))
    draw.ellipse((168, line_y - 2, 178, line_y + 8), fill=(*accent, 90))


def make_poster(item: dict, index: int) -> Path:
    background = cover(Image.open(ASSETS / item["bg"]), CANVAS).convert("RGBA")
    add_top_readability(background)
    add_phone(background, ASSETS / item["screen"])
    add_copy(background, item, index)

    out_path = OUT / f"app-intro-v2-{index:02d}.png"
    background.convert("RGB").save(out_path, format="PNG", optimize=True, compress_level=9)
    return out_path


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for index, item in enumerate(POSTERS, start=1):
        path = make_poster(item, index)
        with Image.open(path) as check:
            if check.size != CANVAS:
                raise RuntimeError(f"Unexpected size for {path}: {check.size}")
        if path.stat().st_size >= 5 * 1024 * 1024:
            raise RuntimeError(f"File exceeds 5 MB: {path} ({path.stat().st_size} bytes)")
        print(f"{path.name}\t{path.stat().st_size}\t{CANVAS[0]}x{CANVAS[1]}\tcrop={STATUS_BAR_CROP}px")


if __name__ == "__main__":
    main()
