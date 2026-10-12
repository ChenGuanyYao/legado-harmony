import { ThemeAssetRegistry } from '../theme/ThemeAssetRegistry';
import { ThemeRuntime } from '../theme/ThemeRuntime';
import { ImmersiveMaterialRuntime } from '../utils/ImmersiveMaterialRuntime';
import { ReaderTtsFloatingSession } from '../utils/ReaderTtsFloatingSession';
import deviceInfo from '@ohos.deviceInfo';
import { AppFontSize } from '../theme/AppFontSize';
import { AppSpacing } from '../theme/AppSpacing';
import { TtsPanelThemeBackground } from './TtsPanelThemeBackground';

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
        }

        Column({ space: AppSpacing.LG }) {
          this.header()
          this.contentPanel()

          if (this.globalTtsMode === 'audio') {
            this.audioProgress()
          }

          this.playbackControls()

          if (this.optionsPanel === 1) {
            this.timerOptions()
          } else if (this.optionsPanel === 2) {
            this.speedOptions()
          }

          this.bottomActions()
        }
        .width('100%')
        .height('100%')
        .padding({ left: AppSpacing.XL, right: AppSpacing.XL, top: this.topInset + 16, bottom: this.bottomInset + 16 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.backgroundThemeId ? Color.Transparent : this.panelColor)
      .backdropBlur(this.backgroundThemeId ? 0 : ThemeRuntime.glassBlur('panel', 24))
      .transition(TransitionEffect.translate({ y: 520 })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 280, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  header() {
    Row({ space: AppSpacing.LG }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle().width(38).height(38).fill(ThemeRuntime.accentSurfaceColor(this.darkMode))
        SymbolGlyph($r('sys.symbol.speaker_wave_3'))
          .fontSize(19)
          .fontColor([this.accentColor])
      }
      Column({ space: AppSpacing.XXS }) {
        Text(this.globalTtsBookName || '快速朗读')
          .fontSize(AppFontSize.SUBTITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.globalTtsChapterTitle || this.globalTtsChapterProgress)
          .fontSize(AppFontSize.CAPTION)
          .fontColor(this.subTextColor)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize(20)
        .fontColor([this.primaryTextColor])
        .width(38)
        .height(38)
        .accessibilityText('收起播放面板')
        .onClick(() => this.close())
    }
    .width('100%')
  }

  @Builder
  contentPanel() {
    Column({ space: AppSpacing.MD }) {
      this.bookCover()
      if (this.globalTtsMode === 'audio') {
        Scroll() {
          Text(this.globalTtsContent || '暂无书籍简介')
            .fontSize(AppFontSize.BODY_LARGE)
            .lineHeight(25)
            .fontColor(this.primaryTextColor)
            .copyOption(CopyOptions.LocalDevice)
            .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
            .width('100%')
        }
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .layoutWeight(1)
        .width('100%')
        .padding({ left: AppSpacing.XS, right: AppSpacing.XS })
        .scrollBar(BarState.Auto)
      } else {
        List({ scroller: this.textScroller, space: AppSpacing.MD }) {
          ListItem() {
            Text(this.globalTtsTextBefore)
              .fontSize(AppFontSize.BODY_LARGE)
              .lineHeight(25)
              .fontColor(this.subTextColor)
              .width('100%')
          }
          ListItem() {
            Text(this.globalTtsCurrentText || '正在定位当前朗读内容…')
              .fontSize(AppFontSize.BODY_LARGE)
              .fontWeight(FontWeight.Medium)
              .lineHeight(26)
              .fontColor(this.primaryTextColor)
              .width('100%')
              .padding({ left: AppSpacing.MD, right: AppSpacing.MD, top: AppSpacing.SM, bottom: AppSpacing.SM })
              .borderRadius(ThemeRuntime.mediumRadius())
              .backgroundColor(ThemeRuntime.hairlineColor(this.darkMode))
          }
          ListItem() {
            Text(this.globalTtsTextAfter || (this.globalTtsContent ? '' : '正在准备当前朗读内容…'))
              .fontSize(AppFontSize.BODY_LARGE)
              .lineHeight(25)
              .fontColor(this.subTextColor)
              .width('100%')
          }
        }
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .layoutWeight(1)
        .width('100%')
        .padding({ left: AppSpacing.XS, right: AppSpacing.XS })
        .scrollBar(BarState.Auto)
      }
      Row() {
        Text(this.globalTtsChapterProgress || (this.globalTtsMode === 'audio' ? '后台听书' : '正在朗读'))
          .fontSize(AppFontSize.MICRO)
          .fontColor(this.subTextColor)
          .layoutWeight(1)
        if (this.globalTtsVoiceCode) {
          Text(this.globalTtsVoiceCode)
            .fontSize(AppFontSize.MICRO)
            .fontColor(this.subTextColor)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 150 })
        }
      }
      .width('100%')
      if (this.globalTtsMode !== 'audio' && this.globalTtsProgress > 0) {
        Progress({ value: this.globalTtsProgress, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(3)
          .color(this.accentColor)
          .backgroundColor(ThemeRuntime.hairlineColor(this.darkMode))
      }
    }
    .layoutWeight(1)
    .width('100%')
    .padding(AppSpacing.LG)
    .borderRadius(ThemeRuntime.largeRadius())
    .backgroundColor(ThemeRuntime.accentSurfaceColor(this.darkMode))
    .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: ThemeRuntime.glassBorderColor(this.darkMode) })
  }

  @Builder
  bookCover() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.globalTtsCover) {
        Image(this.globalTtsCover)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
        if (this.globalTtsCoverFrame) {
          Image(this.globalTtsCoverFrame)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
        }
      } else if (this.themePlaceholderCover()) {
        Image(this.themePlaceholderCover())
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
        if (this.themePlaceholderFrame()) {
          Image(this.themePlaceholderFrame())
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
        }
      } else {
        Column() {
          Text(this.globalTtsBookName ? this.globalTtsBookName.substring(0, 1) : '书')
            .fontSize(42)
            .fontColor(ThemeRuntime.onAccentColor())
        }
        .width('58%')
        .height('88%')
        .constraintSize({ maxWidth: 260, maxHeight: 360 })
        .borderRadius(ThemeRuntime.mediumRadius())
        .backgroundColor(this.accentColor)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height(this.coverHeight())
    .padding(AppSpacing.MD)
    .borderRadius(ThemeRuntime.mediumRadius())
    .clip(true)
  }

  @Builder
  playbackControls() {
    Row() {
      this.control($r('sys.symbol.timer'), this.globalTtsTimerMinutes > 0 ?
        `${Math.max(1, Math.ceil(this.globalTtsTimerRemainingSeconds / 60))}分` : '定时', true,
        () => this.optionsPanel = this.optionsPanel === 1 ? 0 : 1)
      this.control($r('sys.symbol.arrow_left'), '上一章', this.globalTtsCanPrevious,
        () => ReaderTtsFloatingSession.previous())
      this.playbackControl()
      this.control($r('sys.symbol.arrow_right'), '下一章', this.globalTtsCanNext,
        () => ReaderTtsFloatingSession.next())
      this.speedControl()
    }
    .width('100%')
  }

  @Builder
  playbackControl() {
    Column({ space: AppSpacing.SM }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle().width(46).height(46).fill(this.playButtonColor)
        SymbolGlyph(this.globalTtsPaused ? $r('sys.symbol.play') : $r('sys.symbol.pause'))
          .id(`shared_tts_panel_playback_${this.globalTtsPaused}`)
          .fontSize(23)
          .fontColor([ThemeRuntime.onAccentColor()])
      }
      Text(this.globalTtsPaused ? '播放' : '暂停')
        .fontSize(AppFontSize.MICRO)
        .fontColor(this.subTextColor)
    }
    .layoutWeight(1)
    .height(68)
    .justifyContent(FlexAlign.Center)
    .onClick(() => ReaderTtsFloatingSession.toggle())
  }

  @Builder
  control(icon: Resource, label: string, enabled: boolean, action: () => void) {
    Column({ space: AppSpacing.SM }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle().width(38).height(38).fill(ThemeRuntime.hairlineColor(this.darkMode))
        SymbolGlyph(icon)
          .fontSize(19)
          .fontColor([enabled ? this.primaryTextColor : this.subTextColor])
      }
      Text(label).fontSize(AppFontSize.MICRO).fontColor(this.subTextColor)
    }
    .layoutWeight(1)
    .height(68)
    .justifyContent(FlexAlign.Center)
    .opacity(enabled ? 1 : 0.45)
    .onClick(() => { if (enabled) action(); })
  }

  @Builder
  speedControl() {
    Column({ space: AppSpacing.SM }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle().width(38).height(38).fill(ThemeRuntime.hairlineColor(this.darkMode))
        SymbolGlyph($r('sys.symbol.hourglass'))
          .fontSize(19)
          .fontColor([this.primaryTextColor])
      }
      Text(`${this.globalTtsSpeed.toFixed(1)}x`).fontSize(AppFontSize.MICRO).fontColor(this.subTextColor)
    }
    .layoutWeight(1)
    .height(68)
    .justifyContent(FlexAlign.Center)
    .onClick(() => this.optionsPanel = this.optionsPanel === 2 ? 0 : 2)
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

  /**
   * Voice, catalog and stop share one row so the reading text keeps the panel
   * height. Both reader modes use this row; their footers only differ in where
   * the voice list comes from.
   */
  @Builder
  bottomActions() {
    Row({ space: AppSpacing.MD }) {
      if (this.globalTtsMode === 'audio') {
        this.voiceButton()
      } else if (ReaderTtsFloatingSession.ttsVoiceTitles().length > 0) {
        this.ttsVoiceSelect()
      }
      this.bottomAction($r('sys.symbol.list_bullet'), '目录', '目录跳转', false,
        () => this.onOpenCatalog())
      this.bottomAction($r('sys.symbol.stop_circle_fill'), '停止',
        this.globalTtsMode === 'audio' ? '停止听书' : '停止朗读', true, () => {
          this.close();
          ReaderTtsFloatingSession.stop();
        })
    }
    .width('100%')
    .height(44)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  bottomAction(icon: Resource, label: string, accessibility: string, danger: boolean,
    action: () => void) {
    Row({ space: AppSpacing.XS }) {
      SymbolGlyph(icon)
        .fontSize(16)
        .fontColor([danger ? ThemeRuntime.onAccentColor() : this.primaryTextColor])
      Text(label)
        .fontSize(AppFontSize.CAPTION)
        .fontColor(danger ? ThemeRuntime.onAccentColor() : this.primaryTextColor)
        .maxLines(1)
    }
    .height(44)
    .padding({ left: AppSpacing.MD, right: AppSpacing.MD })
    .borderRadius(ThemeRuntime.mediumRadius())
    .backgroundColor(danger ? ThemeRuntime.dangerColor(this.darkMode) : (ThemeRuntime.softFillColor(this.darkMode)))
    .border({ width: danger ? 0 : ThemeRuntime.glassBorderWidth('button'),
      color: ThemeRuntime.glassBorderColor(this.darkMode, 'button') })
    .alignItems(VerticalAlign.Center)
    .accessibilityText(accessibility)
    .onClick(action)
  }

  /** Voice entry for the audio mode, whose voice list comes from the book source. */
  @Builder
  voiceButton() {
    Row({ space: AppSpacing.SM }) {
      SymbolGlyph($r('sys.symbol.speaker_wave_3'))
        .fontSize(16)
        .fontColor([this.accentColor])
      Text(`音色 · ${this.globalTtsVoiceCode || '4'}`)
        .fontSize(AppFontSize.BODY)
        .fontColor(this.primaryTextColor)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize(13)
        .fontColor([this.subTextColor])
    }
    .layoutWeight(1)
    .height(44)
    .padding({ left: AppSpacing.LG, right: AppSpacing.MD })
    .borderRadius(ThemeRuntime.mediumRadius())
    .backgroundColor(ThemeRuntime.softFillColor(this.darkMode))
    .border({ width: ThemeRuntime.glassBorderWidth('button'),
      color: ThemeRuntime.glassBorderColor(this.darkMode, 'button') })
    .alignItems(VerticalAlign.Center)
    .accessibilityText('选择音色')
    .onClick(() => this.onOpenVoice())
  }

  close(): void {
    this.optionsPanel = 0;
    this.onClose();
  }

  /** Theme cover shown when the book has none; empty for themes without cover art. */
  themePlaceholderCover(): ResourceStr {
    return ThemeAssetRegistry.themeBookCover(ThemeRuntime.bookTokens().coverAssetId);
  }

  themePlaceholderFrame(): ResourceStr {
    return ThemeAssetRegistry.themeShelfFrame(ThemeRuntime.bookTokens().shelfFrameAssetId);
  }

  coverHeight(): number {
    return Math.min(250, Math.max(130,
      (Math.max(1, this.viewportHeight) - this.topInset - this.bottomInset) * 0.32));
  }

  scrollToCurrentSentence(smooth: boolean): void {
    setTimeout(() => {
      if (this.globalTtsMode === 'audio') return;
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
