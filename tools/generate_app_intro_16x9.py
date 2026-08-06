from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "output" / "app_intro_16x9"
ASSETS = OUT / "assets"

CANVAS = (1920, 1080)
STATUS_BAR_CROP = 124
FONT_REGULAR = Path(r"C:\Windows\Fonts\msyh.ttc")
FONT_BOLD = Path(r"C:\Windows\Fonts\msyhbd.ttc")


POSTERS = [
    {
        "title": "雅致书架\n万卷成景",
        "subtitle": "网络 / 本地 · 进度与分类一目了然",
        "tag": "梅影书架",
        "features": ["进度同步", "分类管理", "网络 / 本地"],
        "caption": "让每一次打开，都回到熟悉的阅读现场。",
        "bg": "bg-01.png",
        "screen": "screen-01.jpg",
        "accent": (75, 118, 97),
    },
    {
        "title": "主题成套\n风格随心",
        "subtitle": "草莓、赤墨、梅影与玫瑰，自由切换",
        "tag": "主题美学",
        "features": ["成套设计", "多款预设", "一键切换"],
        "caption": "从纸张到图标，让阅读拥有完整气质。",
        "bg": "bg-02.png",
        "screen": "screen-02.jpg",
        "accent": (170, 83, 91),
    },
    {
        "title": "图文相融\n一页入境",
        "subtitle": "插图、正文与标注，排版自然舒展",
        "tag": "沉浸阅读",
        "features": ["图文混排", "舒适间距", "重点标注"],
        "caption": "故事与画面同页展开，阅读更有层次。",
        "bg": "bg-03.png",
        "screen": "screen-03.jpg",
        "accent": (139, 66, 43),
    },
    {
        "title": "磨砂玻璃\n质感可调",
        "subtitle": "模糊、透明、边框与圆角，细节自定义",
        "tag": "磨砂面板",
        "features": ["模糊强度", "透明边框", "组件圆角"],
        "caption": "细腻光影与清晰层级，由你亲手定义。",
        "bg": "bg-04.png",
        "screen": "screen-04.jpg",
        "accent": (70, 123, 93),
    },
    {
        "title": "听书随行\n倍速可调",
        "subtitle": "定时、倍速与朗读控制，释放双眼",
        "tag": "智能朗读",
        "features": ["定时停止", "多档倍速", "便捷控制"],
        "caption": "放下屏幕，也能让故事继续陪伴。",
        "bg": "bg-05.png",
        "screen": "screen-05.jpg",
        "accent": (93, 128, 91),
    },
]


def font(path: Path, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(path), size=size)


def cover(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    return ImageOps.fit(image.convert("RGB"), size, method=Image.Resampling.LANCZOS)


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius, fill=255)
    return mask


def crop_status_bar(image: Image.Image) -> Image.Image:
    if image.height <= STATUS_BAR_CROP:
        raise ValueError("Screenshot is too short for status-bar cropping")
    return image.crop((0, STATUS_BAR_CROP, image.width, image.height))


def add_left_readability(base: Image.Image) -> None:
    wash = Image.new("RGBA", CANVAS, (0, 0, 0, 0))
    px = wash.load()
    for x in range(1260):
        if x < 900:
            alpha = 185
        else:
            alpha = int(185 * (1260 - x) / 360)
        for y in range(CANVAS[1]):
            px[x, y] = (250, 247, 237, max(0, alpha))
    base.alpha_composite(wash)


def add_phone(base: Image.Image, screenshot_path: Path, accent: tuple[int, int, int]) -> None:
    screen_w, screen_h = 460, 988
    border = 13
    frame_w, frame_h = screen_w + border * 2, screen_h + border * 2
    x, y = 1328, 33

    halo = Image.new("RGBA", CANVAS, (0, 0, 0, 0))
    hd = ImageDraw.Draw(halo)
    hd.ellipse((1225, 80, 1870, 1020), fill=(*accent, 35))
    base.alpha_composite(halo.filter(ImageFilter.GaussianBlur(54)))

    shadow = Image.new("RGBA", CANVAS, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle(
        (x - 14, y + 10, x + frame_w + 14, y + frame_h + 28),
        radius=48,
        fill=(25, 31, 27, 88),
    )
    base.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(26)))

    frame = Image.new("RGBA", (frame_w, frame_h), (0, 0, 0, 0))
    fd = ImageDraw.Draw(frame)
    fd.rounded_rectangle(
        (0, 0, frame_w - 1, frame_h - 1),
        radius=40,
        fill=(250, 249, 244, 252),
        outline=(255, 255, 255, 225),
        width=2,
    )

    with Image.open(screenshot_path) as source:
        screen = cover(crop_status_bar(source.convert("RGB")), (screen_w, screen_h)).convert("RGBA")
    screen.putalpha(rounded_mask((screen_w, screen_h), 30))
    frame.alpha_composite(screen, (border, border))
    base.alpha_composite(frame, (x, y))

    highlight = Image.new("RGBA", CANVAS, (0, 0, 0, 0))
    ImageDraw.Draw(highlight).rounded_rectangle(
        (x + 5, y + 5, x + frame_w - 6, y + frame_h - 6),
        radius=38,
        outline=(255, 255, 255, 82),
        width=2,
    )
    base.alpha_composite(highlight)


def draw_chip(draw: ImageDraw.ImageDraw, x: int, y: int, text: str, accent: tuple[int, int, int]) -> int:
    chip_font = font(FONT_BOLD, 29)
    box = draw.textbbox((0, 0), text, font=chip_font)
    width = box[2] - box[0] + 56
    draw.rounded_rectangle(
        (x, y, x + width, y + 58),
        radius=29,
        fill=(255, 255, 250, 205),
        outline=(*accent, 78),
        width=2,
    )
    draw.text((x + 28, y + 10), text, font=chip_font, fill=(67, 70, 60, 255))
    return width


def add_copy(base: Image.Image, item: dict, index: int) -> None:
    draw = ImageDraw.Draw(base)
    ink = (42, 45, 38, 255)
    muted = (91, 87, 75, 242)
    accent = item["accent"]

    tag_font = font(FONT_BOLD, 28)
    tag_text = f"0{index}  ·  {item['tag']}"
    tag_box = draw.textbbox((0, 0), tag_text, font=tag_font)
    tag_w = tag_box[2] - tag_box[0] + 54
    draw.rounded_rectangle((100, 86, 100 + tag_w, 144), radius=29, fill=(*accent, 232))
    draw.text((127, 97), tag_text, font=tag_font, fill=(255, 255, 250, 255))

    title_font = font(FONT_BOLD, 96)
    draw.multiline_text((100, 180), item["title"], font=title_font, fill=ink, spacing=-2)

    subtitle_font = font(FONT_REGULAR, 38)
    draw.text((104, 430), item["subtitle"], font=subtitle_font, fill=muted)
    draw.rounded_rectangle((104, 502, 190, 510), radius=4, fill=(*accent, 255))
    draw.ellipse((207, 499, 219, 511), fill=(*accent, 180))
    draw.ellipse((233, 499, 245, 511), fill=(*accent, 90))

    x = 100
    for feature in item["features"]:
        x += draw_chip(draw, x, 574, feature, accent) + 18

    caption_font = font(FONT_REGULAR, 39)
    draw.rounded_rectangle((100, 734, 1115, 895), radius=32, fill=(255, 255, 250, 142), outline=(*accent, 48), width=2)
    draw.rounded_rectangle((132, 778, 141, 850), radius=4, fill=(*accent, 235))
    draw.text((174, 787), item["caption"], font=caption_font, fill=(57, 61, 52, 255))

    foot_font = font(FONT_BOLD, 24)
    draw.text((104, 978), f"阅读体验  {index:02d} / 05", font=foot_font, fill=(*accent, 220))


def make_poster(item: dict, index: int) -> Path:
    with Image.open(ASSETS / item["bg"]) as bg:
        background = cover(bg, CANVAS).convert("RGBA")
    add_left_readability(background)
    add_phone(background, ASSETS / item["screen"], item["accent"])
    add_copy(background, item, index)

    out_path = OUT / f"app-intro-16x9-{index:02d}.png"
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
