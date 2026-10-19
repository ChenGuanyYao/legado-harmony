import { ThemeAssetRegistry } from '../theme/ThemeAssetRegistry';
import { ThemeRuntime } from '../theme/ThemeRuntime';
import { ImmersiveMaterialRuntime } from '../utils/ImmersiveMaterialRuntime';
import { ReaderTtsFloatingSession } from '../utils/ReaderTtsFloatingSession';
import deviceInfo from '@ohos.deviceInfo';
import { AppFontSize } from '../theme/AppFontSize';
import { AppSpacing } from '../theme/AppSpacing';
import { TtsPanelThemeBackground } from './TtsPanelThemeBackground';
import { ImmersiveMaterialSurface } from './ImmersiveMaterialSurface';

/** 顶栏圆形按钮的尺寸。 */
const PANEL_CONTROL_SIZE: number = 40;

@Component
export struct ReaderTtsPlayerPanel {
  @Prop darkMode: boolean = false;
  @Prop accentColor: ResourceColor = '#5B8F86';
  @Prop playButtonColor: ResourceColor = '#5B8F86';
  @Prop primaryTextColor: ResourceColor = '#18191C';
  @Prop subTextColor: ResourceColor = '#71747A';
  @Prop panelColor: ResourceColor = '#F7F7F7';
  // Theme whose panel artwork is drawn behind the controls; empty keeps the plain glass surface.
  @Prop backgroundThemeId: string = '';
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  @Prop viewportHeight: number = 720;
  onClose: () => void = () => {};
  onOpenCatalog: () => void = () => {};
  onOpenVoice: () => void = () => ReaderTtsFloatingSession.openVoice();
  onTogglePlayback: () => void = () => {
    ReaderTtsFloatingSession.toggle();
  };
  // 听书页自己的书籍信息与播放状态。共享会话要等第一章音频地址取到后才发布，失败时又会被清掉，
  // 这段时间面板仍显示这本书和加载/失败提示，而不是朗读模式的占位文字。
  @Prop hostAudioPage: boolean = false;
  @Prop hostBookName: string = '';
  @Prop hostChapterTitle: string = '';
  @Prop hostIntro: string = '';
  @Prop hostCover: ResourceStr = '';
  @Prop hostPlaying: boolean = false;
  @Prop hostStatusText: string = '';
  @Prop hostBusy: boolean = false;

  @StorageLink('globalTtsPaused') globalTtsPaused: boolean = false;
  @StorageLink('globalTtsBookName') globalTtsBookName: string = '';
  @StorageLink('globalTtsChapterTitle') globalTtsChapterTitle: string = '';
  @StorageLink('globalTtsMode') globalTtsMode: string = '';
  @StorageLink('globalTtsVoiceCode') globalTtsVoiceCode: string = '';
  @StorageLink('globalTtsCover') globalTtsCover: ResourceStr = '';
  @StorageLink('globalTtsCoverFrame') globalTtsCoverFrame: ResourceStr = '';
  @StorageLink('globalTtsContent') globalTtsContent: string = '';
  @StorageLink('globalTtsTextBefore') globalTtsTextBefore: string = '';
  @StorageLink('globalTtsCurrentText') @Watch('onCurrentTextChanged') globalTtsCurrentText: string = '';
  @StorageLink('globalTtsTextAfter') globalTtsTextAfter: string = '';
  @StorageLink('globalTtsChapterProgress') globalTtsChapterProgress: string = '';
  @StorageLink('globalTtsProgress') globalTtsProgress: number = 0;
  @StorageLink('globalTtsSpeed') globalTtsSpeed: number = 1;
  @StorageLink('globalTtsTimerMinutes') globalTtsTimerMinutes: number = 0;
  @StorageLink('globalTtsTimerRemainingSeconds') globalTtsTimerRemainingSeconds: number = 0;
  @StorageLink('globalTtsCanPrevious') globalTtsCanPrevious: boolean = false;
  @StorageLink('globalTtsCanNext') globalTtsCanNext: boolean = false;
  @StorageLink('globalTtsAudioPositionMs') globalTtsAudioPositionMs: number = 0;
  @StorageLink('globalTtsAudioDurationMs') globalTtsAudioDurationMs: number = 0;
  @StorageLink('globalTtsVoiceRevision') globalTtsVoiceRevision: number = 0;
  @StorageLink('globalTtsStatusText') globalTtsStatusText: string = '';
  @StorageLink('globalTtsBusy') globalTtsBusy: boolean = false;
  @State optionsPanel: number = 0;
  private textScroller: ListScroller = new ListScroller();

  aboutToAppear(): void {
    this.scrollToCurrentSentence(false);
  }

  onCurrentTextChanged(): void {
    this.scrollToCurrentSentence(true);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.darkMode ? '#52000000' : '#26000000')
        .backdropBlur(ThemeRuntime.glassBlur('popover', 10))
        .onClick(() => this.close())

      Stack({ alignContent: Alignment.TopStart }) {
        if (this.backgroundThemeId) {
          TtsPanelThemeBackground({ themeId: this.backgroundThemeId, darkMode: this.darkMode })
        } else {
          this.ambientBackdrop()
        }

        Column({ space: AppSpacing.LG }) {
          this.header()

          if (this.isAudio()) {
            this.audioHero()
          } else {
            this.readingCard()
          }

          if (this.statusText()) {
            this.statusLine()
          }

          if (this.isAudio()) {
            this.audioProgress()
          } else if (this.globalTtsProgress > 0) {
            Progress({ value: this.globalTtsProgress, total: 100, type: ProgressType.Linear })
              .width('100%')
              .height(3)
              .color(this.accentColor)
              .backgroundColor(ThemeRuntime.hairlineColor(this.darkMode))
          }

          this.mainControls()

          if (this.optionsPanel === 1) {
            this.timerOptions()
          } else if (this.optionsPanel === 2) {
            this.speedOptions()
          }

          this.secondaryActions()
        }
        .width('100%')
        .height('100%')
        .padding({ left: AppSpacing.XL, right: AppSpacing.XL, top: this.topInset + 8, bottom: this.bottomInset + 12 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.backgroundThemeId ? Color.Transparent : ThemeRuntime.pageColor(this.darkMode))
      .transition(TransitionEffect.translate({ y: 520 })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 280, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
  }

  /** 没有主题背景图时，用封面做模糊氛围背景，渐隐到页面底色（底色层与渐变层不透明，底部无硬边）。 */
  @Builder
  ambientBackdrop() {
    Stack({ alignContent: Alignment.Top }) {
      if (this.coverSource()) {
        Image(this.coverSource())
          .width('100%')
          .height(this.ambientHeight())
          .objectFit(ImageFit.Cover)
          .sourceSize({ width: 96, height: 128 })
          .blur(48)
          .opacity(this.darkMode ? 0.5 : 0.6)
      }
      Column()
        .width('100%')
        .height(this.ambientHeight())
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: [
            [this.pageColorWithAlpha('40'), 0],
            [this.pageColorWithAlpha('33'), 0.3],
            [this.pageColorWithAlpha('B3'), 0.7],
            [ThemeRuntime.pageColor(this.darkMode), 1]
          ]
        })
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  header() {
    Row() {
      this.circleButton($r('sys.symbol.chevron_down'), '收起播放面板', () => this.close())
      Column({ space: AppSpacing.XXS }) {
        Text(this.hostBookName || this.globalTtsBookName || (this.isAudio() ? '听书' : '快速朗读'))
          .fontSize(AppFontSize.BODY_LARGE)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.isAudio() ? (this.globalTtsChapterProgress || '正在听书') : '正在朗读')
          .fontSize(AppFontSize.CAPTION)
          .fontColor(this.subTextColor)
          .maxLines(1)
      }
      .layoutWeight(1)
      .padding({ left: AppSpacing.MD, right: AppSpacing.MD })
      .alignItems(HorizontalAlign.Center)
      // 与左侧按钮等宽的占位，让标题真正居中。
      Column()
        .width(PANEL_CONTROL_SIZE)
        .height(PANEL_CONTROL_SIZE)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  circleButton(icon: Resource, label: string, action: () => void) {
    ImmersiveMaterialSurface({
      surfaceWidth: PANEL_CONTROL_SIZE,
      surfaceHeight: PANEL_CONTROL_SIZE,
      darkMode: this.darkMode,
      fallbackColor: ThemeRuntime.cardColor(this.darkMode),
      glowColor: this.accentGlowColor()
    }) {
      Stack() {
        SymbolGlyph(icon)
          .fontSize(20)
          .fontColor([this.primaryTextColor])
      }
      .width('100%')
      .height('100%')
      .accessibilityText(label)
      .onClick(() => action())
    }
  }

  /** 听书：大封面居中，下面是章节名、进度与简介。 */
  @Builder
  audioHero() {
    Column({ space: AppSpacing.MD }) {
      Stack() {
        this.heroCover(Math.round(this.coverHeight() * 0.75), this.coverHeight())
      }
      .shadow({ radius: 24, color: this.darkMode ? '#73000000' : '#40000000', offsetX: 0, offsetY: 10 })
      .margin({ top: AppSpacing.SM })

      Text(this.hostChapterTitle || this.globalTtsChapterTitle || '正在获取章节…')
        .fontSize(AppFontSize.SUBTITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .margin({ top: AppSpacing.SM })

      Scroll() {
        Text(this.globalTtsContent || this.hostIntro || '暂无书籍简介')
          .fontSize(AppFontSize.BODY)
          .lineHeight(22)
          .fontColor(this.subTextColor)
          .copyOption(CopyOptions.LocalDevice)
          .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
          .width('100%')
      }
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .layoutWeight(1)
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /** 朗读：当前朗读文字放在玻璃卡片里，上下文浅色，当前句高亮并自动居中。 */
  @Builder
  readingCard() {
    Column({ space: AppSpacing.MD }) {
      Row({ space: AppSpacing.MD }) {
        this.heroCover(42, 56)
        Column({ space: AppSpacing.XXS }) {
          Text(this.hostChapterTitle || this.globalTtsChapterTitle || '正在朗读')
            .fontSize(AppFontSize.BODY)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.globalTtsChapterProgress || '')
            .fontSize(AppFontSize.CAPTION)
            .fontColor(this.subTextColor)
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      List({ scroller: this.textScroller, space: AppSpacing.MD }) {
        ListItem() {
          Text(this.globalTtsTextBefore)
            .fontSize(AppFontSize.BODY_LARGE)
            .lineHeight(26)
            .fontColor(this.subTextColor)
            .width('100%')
        }
        ListItem() {
          Text(this.globalTtsCurrentText || '正在定位当前朗读内容…')
            .fontSize(AppFontSize.SUBTITLE)
            .fontWeight(FontWeight.Medium)
            .lineHeight(28)
            .fontColor(this.primaryTextColor)
            .width('100%')
            .padding({ left: AppSpacing.MD, right: AppSpacing.MD, top: AppSpacing.SM, bottom: AppSpacing.SM })
            .borderRadius(ThemeRuntime.mediumRadius())
            .backgroundColor(ThemeRuntime.accentSurfaceColor(this.darkMode))
        }
        ListItem() {
          Text(this.globalTtsTextAfter || (this.globalTtsContent ? '' : '正在准备当前朗读内容…'))
            .fontSize(AppFontSize.BODY_LARGE)
            .lineHeight(26)
            .fontColor(this.subTextColor)
            .width('100%')
        }
      }
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)

      if (ReaderTtsFloatingSession.ttsVoiceTitles().length > 0) {
        Row() {
          this.ttsVoiceSelect()
        }
        .width('100%')
      }
    }
    .layoutWeight(1)
    .width('100%')
    .padding(AppSpacing.LG)
    .borderRadius(ThemeRuntime.largeRadius())
    .backgroundColor(this.darkMode ? '#991C1C1E' : '#B3FFFFFF')
    .border({ width: 0.5, color: this.darkMode ? '#26FFFFFF' : '#E6FFFFFF' })
  }

  @Builder
  heroCover(width: number, height: number) {
    Stack({ alignContent: Alignment.Center }) {
      if (this.coverSource()) {
        Image(this.coverSource())
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .sourceSize({ width: 480, height: 640 })
        if (this.globalTtsCoverFrame) {
          Image(this.globalTtsCoverFrame)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Fill)
        }
      } else if (this.themePlaceholderCover()) {
        Image(this.themePlaceholderCover())
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
        if (this.themePlaceholderFrame()) {
          Image(this.themePlaceholderFrame())
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Fill)
        }
      } else {
        Text(this.coverInitial())
          .fontSize(Math.max(16, Math.round(height * 0.22)))
          .fontColor(ThemeRuntime.onAccentColor())
      }
    }
    .width(width)
    .height(height)
    .borderRadius(height > 100 ? 14 : 6)
    .clip(true)
    .backgroundColor(this.accentColor)
  }

  @Builder
  statusLine() {
    Row({ space: AppSpacing.SM }) {
      if (this.isBusy()) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color(this.accentColor)
      }
      Text(this.statusText())
        .fontSize(AppFontSize.CAPTION)
        .fontColor(this.isBusy() ? this.primaryTextColor : ThemeRuntime.dangerColor(this.darkMode))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: AppSpacing.MD, right: AppSpacing.MD, top: AppSpacing.SM, bottom: AppSpacing.SM })
    .borderRadius(ThemeRuntime.mediumRadius())
    .backgroundColor(ThemeRuntime.hairlineColor(this.darkMode))
    .alignItems(VerticalAlign.Center)
    .accessibilityText(this.statusText())
  }

  /** 主控制区：上一章、大号播放键、下一章。 */
  @Builder
  mainControls() {
    Row() {
      this.chapterButton($r('sys.symbol.backward_end_fill'), '上一章', this.globalTtsCanPrevious,
        () => ReaderTtsFloatingSession.previous())
      Stack({ alignContent: Alignment.Center }) {
        Circle().width(68).height(68).fill(this.playButtonColor)
        if (this.isBusy()) {
          LoadingProgress()
            .width(36)
            .height(36)
            .color(ThemeRuntime.onAccentColor())
        } else {
          SymbolGlyph(this.isPaused() ? $r('sys.symbol.play_fill') : $r('sys.symbol.pause_fill'))
            .id(`shared_tts_panel_playback_${this.isPaused()}`)
            .fontSize(30)
            .fontColor([ThemeRuntime.onAccentColor()])
        }
      }
      .width(68)
      .height(68)
      .borderRadius(34)
      .shadow({ radius: 16, color: this.darkMode ? '#66000000' : '#33000000', offsetX: 0, offsetY: 6 })
      .clickEffect({ level: ClickEffectLevel.MIDDLE, scale: 0.92 })
      .accessibilityText(this.isBusy() ? '正在加载' : (this.isPaused() ? '播放' : '暂停'))
      .onClick(() => {
        if (!this.isBusy()) this.onTogglePlayback();
      })
      this.chapterButton($r('sys.symbol.forward_end_fill'), '下一章', this.globalTtsCanNext,
        () => ReaderTtsFloatingSession.next())
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceEvenly)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  chapterButton(icon: Resource, label: string, enabled: boolean, action: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(icon)
        .fontSize(30)
        .fontColor([enabled ? this.primaryTextColor : this.subTextColor])
    }
    .width(56)
    .height(56)
    .opacity(enabled ? 1 : 0.4)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
    .accessibilityText(label)
    .onClick(() => {
      if (enabled) action();
    })
  }

  /** 底部一排：定时、倍速、音色（听书）、目录、停止；开启的选项用主题色，停止用警示色。 */
  @Builder
  secondaryActions() {
    Row() {
      this.secondaryItem($r('sys.symbol.timer'), this.globalTtsTimerMinutes > 0 ?
        `${Math.max(1, Math.ceil(this.globalTtsTimerRemainingSeconds / 60))}分` : '定时',
        this.globalTtsTimerMinutes > 0 || this.optionsPanel === 1, false,
        () => this.optionsPanel = this.optionsPanel === 1 ? 0 : 1)
      this.secondaryItem($r('sys.symbol.hourglass'), `${this.globalTtsSpeed.toFixed(1)}x`,
        Math.abs(this.globalTtsSpeed - 1) > 0.01 || this.optionsPanel === 2, false,
        () => this.optionsPanel = this.optionsPanel === 2 ? 0 : 2)
      if (this.isAudio()) {
        this.secondaryItem($r('sys.symbol.speaker_wave_3'),
          this.globalTtsVoiceCode ? `音色 ${this.globalTtsVoiceCode}` : '音色', false, false,
          () => this.onOpenVoice())
      }
      this.secondaryItem($r('sys.symbol.list_bullet'), '目录', false, false, () => this.onOpenCatalog())
      this.secondaryItem($r('sys.symbol.stop_circle'), '停止', false, true, () => {
        this.close();
        ReaderTtsFloatingSession.stop();
      })
    }
    .width('100%')
    .padding({ top: AppSpacing.XS })
  }

  @Builder
  secondaryItem(icon: Resource, label: string, active: boolean, danger: boolean, action: () => void) {
    Column({ space: AppSpacing.XS }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([danger ? ThemeRuntime.dangerColor(this.darkMode) : (active ? this.accentColor : this.primaryTextColor)])
      Text(label)
        .fontSize(AppFontSize.CAPTION)
        .fontColor(danger ? ThemeRuntime.dangerColor(this.darkMode) : (active ? this.accentColor : this.subTextColor))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .height(56)
    .justifyContent(FlexAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
    .accessibilityText(label)
    .onClick(action)
  }

  @Builder
  timerOptions() {
    Row({ space: AppSpacing.SM }) {
      this.timerChip(0, '关闭')
      this.timerChip(15, '15分')
      this.timerChip(30, '30分')
      this.timerChip(60, '60分')
      this.timerChip(90, '90分')
      this.timerChip(120, '120分')
    }
    .width('100%')
  }

  @Builder
  speedOptions() {
    Row({ space: AppSpacing.MD }) {
      this.speedChip(0.8)
      this.speedChip(1.0)
      this.speedChip(1.2)
      this.speedChip(1.5)
      this.speedChip(2.0)
    }
    .width('100%')
  }

  @Builder
  speedChip(value: number) {
    Text(`${value.toFixed(1)}x`)
      .fontSize(AppFontSize.CAPTION)
      .fontWeight(Math.abs(this.globalTtsSpeed - value) < 0.01 ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(Math.abs(this.globalTtsSpeed - value) < 0.01 ? ThemeRuntime.onAccentColor() : this.primaryTextColor)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(30)
      .borderRadius(ThemeRuntime.buttonRadius())
      .backgroundColor(Math.abs(this.globalTtsSpeed - value) < 0.01 ? this.accentColor :
        (ThemeRuntime.softFillColor(this.darkMode)))
      .onClick(() => ReaderTtsFloatingSession.setSpeed(value))
  }

  @Builder
  timerChip(minutes: number, label: string) {
    Text(label)
      .fontSize(AppFontSize.CAPTION)
      .fontWeight(this.globalTtsTimerMinutes === minutes ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.globalTtsTimerMinutes === minutes ? ThemeRuntime.onAccentColor() : this.primaryTextColor)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(30)
      .borderRadius(ThemeRuntime.buttonRadius())
      .backgroundColor(this.globalTtsTimerMinutes === minutes ? this.accentColor :
        (ThemeRuntime.softFillColor(this.darkMode)))
      .onClick(() => ReaderTtsFloatingSession.setTimer(minutes))
  }

  @Builder
  ttsVoiceSelect() {
    if (deviceInfo.sdkApiVersion >= 26) {
      // The API 26 Select paints its own component surface, so the speaker mark has to
      // sit inside that surface instead of beside it, matching the shelf sort chip.
      Stack({ alignContent: Alignment.Start }) {
        this.ttsVoiceSelectControl(34, ThemeRuntime.softFillColor(this.darkMode))
        SymbolGlyph($r('sys.symbol.speaker_wave_3'))
          .fontSize(17)
          .fontColor([this.accentColor])
          .width(22)
          .margin({ left: AppSpacing.LG })
          .hitTestBehavior(HitTestMode.None)
      }
      .layoutWeight(1)
      .width('100%')
      .height(44)
    } else {
      Row({ space: AppSpacing.MD }) {
        SymbolGlyph($r('sys.symbol.speaker_wave_3'))
          .fontSize(17)
          .fontColor([this.accentColor])
          .width(24)
        this.ttsVoiceSelectControl(0, Color.Transparent)
      }
      .layoutWeight(1)
      .width('100%')
      .height(44)
      .padding({ left: AppSpacing.LG, right: AppSpacing.MD })
      .borderRadius(ThemeRuntime.mediumRadius())
      .backgroundColor(ThemeRuntime.softFillColor(this.darkMode))
      .border({ width: ThemeRuntime.glassBorderWidth('button'),
        color: ThemeRuntime.glassBorderColor(this.darkMode, 'button') })
    }
  }

  @Builder
  ttsVoiceSelectControl(leadingInset: number, surfaceColor: ResourceColor) {
    Select(this.ttsVoiceOptions())
      .id(`shared_tts_voice_${this.globalTtsVoiceRevision}_${ReaderTtsFloatingSession.ttsVoiceIndex()}`)
      .selected(ReaderTtsFloatingSession.ttsVoiceIndex())
      .value(this.globalTtsVoiceCode)
      .font({ size: AppFontSize.BODY })
      .fontColor(this.primaryTextColor)
      // The API 26 branch fills its Stack by width; inside the legacy Row the
      // layoutWeight owns the main axis and this width is ignored, so both
      // branches can share one definition.
      .width('100%')
      .layoutWeight(1)
      .height(44)
      .padding({ left: leadingInset, right: 0 })
      .backgroundColor(surfaceColor)
      .borderRadius(ThemeRuntime.mediumRadius())
      .border({ width: 0 })
      .optionBgColor(Color.Transparent)
      .divider(null)
      .optionFontColor(this.primaryTextColor)
      .selectedOptionFontColor(this.accentColor)
      .selectedOptionBgColor(ThemeRuntime.accentSurfaceColor(this.darkMode))
      // This menu floats over the page image, so it needs a genuinely frosted
      // surface: the opaque card color used by the settings dropdowns hides
      // the API 26 menu material completely, and the translucent tint alone
      // reads as see-through. Keep the translucent dropdown tint used by every
      // other menu (so menuSystemMaterial can frost the page behind it) and add
      // an explicit component blur so the frost also works on devices where the
      // immersive menu material is unavailable.
      .menuBackgroundColor(ThemeRuntime.dropdownPanelColor(this.darkMode, ''))
      .menuBackgroundBlurStyle(ThemeRuntime.glassEnabled() ? BlurStyle.COMPONENT_THICK : BlurStyle.NONE)
      .attributeModifier(ImmersiveMaterialRuntime.selectMenuModifier())
      .onSelect((index: number) => ReaderTtsFloatingSession.selectTtsVoice(index))
  }

  ttsVoiceOptions(): SelectOption[] {
    return ReaderTtsFloatingSession.ttsVoiceTitles().map((title: string): SelectOption => ({ value: title }));
  }

  @Builder
  audioProgress() {
    Column({ space: AppSpacing.XXS }) {
      Slider({ value: this.globalTtsAudioPositionMs, min: 0,
        max: Math.max(1, this.globalTtsAudioDurationMs), step: 1000 })
        .width('100%')
        .showTips(true)
        .selectedColor(this.accentColor)
        .trackColor(ThemeRuntime.inputColor(this.darkMode))
        .onChange((value: number, mode: SliderChangeMode) => {
          this.globalTtsAudioPositionMs = value;
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            ReaderTtsFloatingSession.seekAudio(value);
          }
        })
      Row() {
        Text(this.formatAudioDuration(this.globalTtsAudioPositionMs)).fontSize(AppFontSize.CAPTION).fontColor(this.subTextColor)
        Blank()
        Text(this.formatAudioDuration(this.globalTtsAudioDurationMs)).fontSize(AppFontSize.CAPTION).fontColor(this.subTextColor)
      }
      .width('100%')
    }
    .width('100%')
  }

  close(): void {
    this.optionsPanel = 0;
    this.onClose();
  }

  isAudio(): boolean {
    return this.hostAudioPage || this.globalTtsMode === 'audio';
  }

  isPaused(): boolean {
    return this.hostAudioPage ? !this.hostPlaying : this.globalTtsPaused;
  }

  isBusy(): boolean {
    return this.hostAudioPage ? this.hostBusy : this.globalTtsBusy;
  }

  statusText(): string {
    return this.hostAudioPage ? this.hostStatusText : this.globalTtsStatusText;
  }

  coverSource(): ResourceStr {
    return this.globalTtsCover || this.hostCover;
  }

  /** Theme cover shown when the book has none; empty for themes without cover art. */
  themePlaceholderCover(): ResourceStr {
    return ThemeAssetRegistry.themeBookCover(ThemeRuntime.bookTokens().coverAssetId);
  }

  themePlaceholderFrame(): ResourceStr {
    return ThemeAssetRegistry.themeShelfFrame(ThemeRuntime.bookTokens().shelfFrameAssetId);
  }

  coverHeight(): number {
    return Math.round(Math.min(300, Math.max(150,
      (Math.max(1, this.viewportHeight) - this.topInset - this.bottomInset) * 0.36)));
  }

  ambientHeight(): number {
    return Math.round(Math.max(360, (Math.max(1, this.viewportHeight)) * 0.6));
  }

  coverInitial(): string {
    const name = this.hostBookName || this.globalTtsBookName;
    return name ? name.substring(0, 1) : '书';
  }

  pageColorWithAlpha(alpha: string): string {
    return `#${alpha}${ThemeRuntime.pageColor(this.darkMode).substring(1)}`;
  }

  accentGlowColor(): string {
    return `#40${ThemeRuntime.accentColor(this.darkMode).substring(1)}`;
  }

  scrollToCurrentSentence(smooth: boolean): void {
    setTimeout(() => {
      if (this.isAudio()) return;
      try {
        this.textScroller.scrollToIndex(1, smooth, ScrollAlign.CENTER);
      } catch (_) {}
    }, 0);
  }

  formatAudioDuration(valueMs: number): string {
    const totalSeconds = Math.max(0, Math.floor((valueMs || 0) / 1000));
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const seconds = totalSeconds % 60;
    const mm = minutes.toString().padStart(2, '0');
    const ss = seconds.toString().padStart(2, '0');
    return hours > 0 ? `${hours}:${mm}:${ss}` : `${minutes}:${ss}`;
  }
}
