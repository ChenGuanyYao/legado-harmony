import { TtsPanelThemeStyle, TtsPanelThemeStyles } from '../theme/TtsPanelThemeStyles';

/**
 * Themed background of the TTS / audiobook player panel.
 *
 * A top-anchored scene sits on its own sky gradient and dissolves into the
 * opaque panel colour, so the controls below always rest on a calm surface
 * whatever the window's aspect ratio. Also used at pane size by the theme
 * previews.
 */
@Component
export struct TtsPanelThemeBackground {
  @Prop themeId: string = '';
  @Prop darkMode: boolean = false;

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.style().surfaceColor)

      Stack({ alignContent: Alignment.Bottom }) {
        Image(this.style().artwork)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Fill)
          .syncLoad(true)
          .draggable(false)
        Column()
          .width('100%')
          .height('50%')
          .linearGradient({
            direction: GradientDirection.Bottom,
            colors: [[this.transparent(this.style().surfaceColor), 0], [this.style().surfaceColor, 1]]
          })
      }
      .width('100%')
      .aspectRatio(TtsPanelThemeStyles.ARTWORK_ASPECT_RATIO)
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [[this.style().skyColor, 0], [this.style().surfaceColor, 1]]
      })

      Column() {
        Blank()
          .layoutWeight(1)
        Column()
          .width('100%')
          .height('42%')
          .radialGradient({
            center: ['50%', '100%'],
            radius: '70%',
            colors: [[this.style().glowColor, 0], [this.transparent(this.style().glowColor), 1]]
          })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
  }

  style(): TtsPanelThemeStyle {
    return TtsPanelThemeStyles.resolve(this.themeId, this.darkMode);
  }

  // Fading to the same hue avoids the grey fringe a plain transparent stop produces.
  transparent(color: string): string {
    return `#00${color.substring(color.length - 6)}`;
  }
}
