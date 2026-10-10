import { HdsTabs } from '@kit.UIDesignKit';
import { ThemeRuntime } from '../../theme/ThemeRuntime';
import { ImmersiveMaterialRuntime } from '../../utils/ImmersiveMaterialRuntime';

/**
 * 朗读/听书悬浮胶囊：本页朗读与后台朗读共用同一外观。
 * 位置由使用方通过 translate 控制，这里只上报拖动的起止与偏移。
 */
@Component
export struct ReaderTtsCapsule {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop paused: boolean = false;
  @Prop playbackKey: string = '';
  @Prop textColor: string = '#202124';
  @Prop subTextColor: string = '#8A8A8A';
  @Prop accentColor: string = '#0A59F7';
  @Prop panelColor: string = '#FFFFFF';
  @Prop panelBorderColor: string = '#22000000';
  @Prop panelShadowColor: string = '#22000000';
  onOpen: () => void = (): void => {
  };
  onToggle: () => void = (): void => {
  };
  onClose: () => void = (): void => {
  };
  onCapsuleDragStart: () => void = (): void => {
  };
  onCapsuleDragMove: (offsetX: number, offsetY: number) => void = (_offsetX: number, _offsetY: number): void => {
  };

  static readonly WIDTH: number = 184;
  static readonly HEIGHT: number = 46;

  build() {
    Row({ space: 7 }) {
      Row({ space: 7 }) {
        Stack({ alignContent: Alignment.Center }) {
          Circle().width(30).height(30).fill(this.accentColor)
          SymbolGlyph($r('sys.symbol.speaker_wave_3'))
            .fontSize(15)
            .fontColor(['#FFFFFF'])
        }

        Column({ space: 1 }) {
          Text(this.title)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textColor)
          Text(this.subtitle)
            .fontSize(9)
            .fontColor(this.subTextColor)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .onClick(() => this.onOpen())

      SymbolGlyph(this.paused ? $r('sys.symbol.play') : $r('sys.symbol.pause'))
        .id(this.playbackKey)
        .fontSize(17)
        .fontColor([this.textColor])
        .width(28)
        .height(34)
        .onClick(() => this.onToggle())
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(14)
        .fontColor([this.subTextColor])
        .width(24)
        .height(34)
        .onClick(() => this.onClose())
    }
    .width(ReaderTtsCapsule.WIDTH)
    .height(ReaderTtsCapsule.HEIGHT)
    .padding({ left: 8, right: 5 })
    .borderRadius(23)
    .clip(true)
    .backgroundColor(this.panelColor)
    .backdropBlur(ThemeRuntime.glassBlur('button', 18))
    .border({ width: ThemeRuntime.glassBorderWidth('button'), color: this.panelBorderColor })
    .shadow({
      radius: ThemeRuntime.glassShadowRadius('button'),
      color: this.panelShadowColor,
      offsetX: ThemeRuntime.glassShadowOffsetX('button'),
      offsetY: ThemeRuntime.glassShadowOffsetY('button')
    })
    .parallelGesture(
      PanGesture({ direction: PanDirection.All, distance: 4 })
        .onActionStart(() => this.onCapsuleDragStart())
        .onActionUpdate((event: GestureEvent) => this.onCapsuleDragMove(event.offsetX, event.offsetY))
    )
  }
}

/** 底部菜单上方展开的朗读控制条：定时、上一章、播放/暂停、下一章、语速、收起。 */
@Component
export struct ReaderTtsMediaControlsBar {
  @Prop playing: boolean = false;
  @Prop canPrevious: boolean = false;
  @Prop canNext: boolean = false;
  @Prop speed: number = 1;
  @Prop sleepTimerMinutes: number = 0;
  @Prop sleepTimerRemainingSeconds: number = 0;
  @Prop themeKey: string = '';
  @Prop textColor: string = '#202124';
  @Prop subTextColor: string = '#8A8A8A';
  @Prop accentColor: string = '#0A59F7';
  @Prop panelColor: string = '#FFFFFF';
  // index: 0 定时 1 上一章 2 播放/暂停 3 下一章 4 语速 5 收起
  onControl: (index: number) => void = (_index: number): void => {
  };

  static readonly WIDTH: number = 264;
  static readonly HEIGHT: number = 56;

  private remainingMinutes(): number {
    return Math.max(1, Math.ceil(this.sleepTimerRemainingSeconds / 60));
  }

  @Builder
  timerControl() {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph($r('sys.symbol.timer'))
        .fontSize(22)
        .fontColor([this.textColor])

      if (this.sleepTimerMinutes > 0) {
        Text(`${this.remainingMinutes()}`)
          .fontSize(8)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .width(16)
          .height(16)
          .borderRadius(8)
          .backgroundColor(this.accentColor)
          .position({ x: 25, y: 2 })
      }
    }
    .width('100%')
    .height(48)
    .accessibilityText(this.sleepTimerMinutes > 0 ? `朗读定时剩余 ${this.remainingMinutes()} 分钟` : '设置朗读定时')
    .translate({ y: -2 })
  }

  @Builder
  symbolControl(icon: Resource, enabled: boolean, accessibilityLabel: string) {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([enabled ? this.textColor : this.subTextColor])
    }
    .width('100%')
    .height(48)
    .opacity(enabled ? 1 : 0.45)
    .accessibilityText(accessibilityLabel)
    .translate({ y: -2 })
  }

  @Builder
  speedControl() {
    Text(`${this.speed.toFixed(1)}x`)
      .fontSize(13)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.textColor)
      .textAlign(TextAlign.Center)
      .width('100%')
      .height(48)
      .translate({ y: -2 })
  }

  build() {
    HdsTabs({ barPosition: BarPosition.End, index: 0 }) {
      TabContent() {
        Column()
      }
      .height(48)
      .tabBar(this.timerControl())

      TabContent() {
        Column()
      }
      .height(48)
      .tabBar(this.symbolControl($r('sys.symbol.arrow_left'), this.canPrevious, '上一章'))

      TabContent() {
        Column()
      }
      .height(48)
      .tabBar(this.symbolControl(this.playing ? $r('sys.symbol.pause') : $r('sys.symbol.play'), true,
        this.playing ? '暂停朗读' : '播放朗读'))

      TabContent() {
        Column()
      }
      .height(48)
      .tabBar(this.symbolControl($r('sys.symbol.arrow_right'), this.canNext, '下一章'))

      TabContent() {
        Column()
      }
      .height(48)
      .tabBar(this.speedControl())

      TabContent() {
        Column()
      }
      .height(48)
      .tabBar(this.symbolControl($r('sys.symbol.xmark'), true, '关闭朗读控制'))
    }
    .key(`reader_tts_controls_bar_${this.themeKey}`)
    .barBackgroundColor(this.panelColor)
    .barMode(BarMode.Fixed)
    .barHeight(48)
    .barOverlap(true)
    .barFloatingStyle({
      barWidth: {
        smallWidth: ReaderTtsMediaControlsBar.WIDTH,
        mediumWidth: ReaderTtsMediaControlsBar.WIDTH,
        largeWidth: ReaderTtsMediaControlsBar.WIDTH
      },
      systemMaterialEffect: {
        materialType: ImmersiveMaterialRuntime.materialType(),
        materialLevel: ImmersiveMaterialRuntime.materialLevel()
      },
      barSideMargin: 0,
      barBottomMargin: 4,
      gradientMask: {
        maskColor: '#00000000',
        maskHeight: 56
      },
      adaptToHandedness: false,
      thermoCtrl: true,
      barOpacity: 1
    })
    .scrollable(false)
    .onContentWillChange(() => false)
    .onTabBarClick((index: number) => this.onControl(index))
    .width(ReaderTtsMediaControlsBar.WIDTH)
    .height(ReaderTtsMediaControlsBar.HEIGHT)
  }
}
