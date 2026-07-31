import { ThemeAssetRegistry } from '../theme/ThemeAssetRegistry';

/**
 * Responsive reader background for builtin themes.
 *
 * Builtin artwork is deliberately rendered as proportional corner ornaments
 * over a native, size-aware surface instead of stretching or cropping the old
 * 9:16 wallpaper. User-selected images still keep their chosen fit mode.
 */
@Component
export struct ReaderThemeBackground {
  @Prop surfaceColor: ResourceColor = Color.Transparent;
  @Prop backgroundAssetId: string = '';
  @Prop customImage: ResourceStr = '';
  @Prop customImageFit: ImageFit = ImageFit.Cover;
  @Prop compact: boolean = false;
  @State viewportWidth: number = 0;
  @State viewportHeight: number = 0;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row()
        .width('100%')
        .height('100%')
        .backgroundColor(this.surfaceColor)

      if (this.customImage) {
        Image(this.customImage)
          .width('100%')
          .height('100%')
          .objectFit(this.customImageFit)
          .draggable(false)
          .hitTestBehavior(HitTestMode.None)
      } else if (this.backgroundAssetId) {
        this.builtinThemeDecoration()
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const width = this.areaDimension(newValue.width);
      const height = this.areaDimension(newValue.height);
      if (width > 0 && Math.abs(width - this.viewportWidth) >= 1) {
        this.viewportWidth = width;
      }
      if (height > 0 && Math.abs(height - this.viewportHeight) >= 1) {
        this.viewportHeight = height;
      }
    })
  }

  @Builder
  builtinThemeDecoration() {
    if (ThemeAssetRegistry.readerBackgroundDecoration(this.backgroundAssetId)) {
      Column() {
        Row() {
          Image(ThemeAssetRegistry.readerBackgroundDecoration(this.backgroundAssetId))
            .width(this.decorationSize())
            .height(this.decorationSize())
            .objectFit(ImageFit.Contain)
            .draggable(false)
          Blank()
            .layoutWeight(1)
        }
        .width('100%')

        Blank()
          .layoutWeight(1)

        Row() {
          Blank()
            .layoutWeight(1)
          Image(ThemeAssetRegistry.readerBackgroundDecoration(this.backgroundAssetId))
            .width(this.decorationSize())
            .height(this.decorationSize())
            .objectFit(ImageFit.Contain)
            .rotate({ angle: 180 })
            .draggable(false)
        }
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .padding(this.decorationInset())
      .hitTestBehavior(HitTestMode.None)
    }

    if (ThemeAssetRegistry.readerBackgroundBorderColor(this.backgroundAssetId)) {
      Column() {
        Blank()
          .width('100%')
          .height('100%')
          .border({
            width: this.compact ? 1 : ThemeAssetRegistry.readerBackgroundBorderWidth(this.backgroundAssetId),
            color: ThemeAssetRegistry.readerBackgroundBorderColor(this.backgroundAssetId)
          })
          .borderRadius(this.compact ? 3 : 7)
      }
      .width('100%')
      .height('100%')
      .padding(this.frameInset())
      .hitTestBehavior(HitTestMode.None)
    }
  }

  decorationSize(): number {
    const fallback = this.compact ? 42 : 156;
    if (this.viewportWidth <= 0 || this.viewportHeight <= 0) return fallback;
    const shortEdge = Math.min(this.viewportWidth, this.viewportHeight);
    if (this.compact) return Math.max(30, Math.min(54, shortEdge * 0.72));
    // Size follows the short edge, so portrait, landscape, tablet and split
    // window layouts preserve the ornament's proportions without device rules.
    return Math.max(112, Math.min(260, shortEdge * 0.36));
  }

  decorationInset(): Padding {
    const inset = this.compact ? 2 : Math.max(8, Math.min(22, this.shortEdge() * 0.025));
    return { left: inset, right: inset, top: inset, bottom: inset };
  }

  frameInset(): Padding {
    const inset = this.compact ? 3 : Math.max(12, Math.min(28, this.shortEdge() * 0.035));
    return { left: inset, right: inset, top: inset, bottom: inset };
  }

  shortEdge(): number {
    if (this.viewportWidth <= 0 || this.viewportHeight <= 0) return this.compact ? 58 : 480;
    return Math.min(this.viewportWidth, this.viewportHeight);
  }

  areaDimension(value: Length): number {
    if (typeof value === 'number') return Number.isFinite(value) ? value : 0;
    const parsed = Number.parseFloat(`${value}`);
    return Number.isFinite(parsed) ? parsed : 0;
  }
}
