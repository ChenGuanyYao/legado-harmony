import { ReaderSettingsStore } from '../../utils/ReaderSettingsStore';
import { HdsFeedback } from '../../utils/HdsFeedback';
import { ImmersiveBackButton } from '../ImmersiveBackButton';
import { ThemeRuntime } from '../../theme/ThemeRuntime';

/**
 * 阅读页"布局元素设置"浮层：控制点击阅读页后出现哪些快捷组件。
 * 两个开关直接绑定全局设置并自行保存；浮层画在阅读页上，配色用阅读主题，由页面传入。
 */
@Component
export struct ReaderLayoutElementSettingsPanel {
  dark: boolean = false;
  textColor: string = '#202124';
  subTextColor: string = '#80868B';
  accentColor: string = '#0A59F7';
  panelColor: string = '#F2FFFFFF';
  panelBorderColor: string = '#1F000000';
  panelShadowColor: string = '#33000000';
  panelWidth: number = 420;
  onClose: () => void = (): void => {
  };
  /** 关掉章节快速跳转组件时，页面要复位章节滑杆的预览。 */
  onChapterQuickJumpChanged: (enabled: boolean) => void = (_enabled: boolean): void => {
  };

  @StorageLink('readerUseTtsQuickAction') readerUseTtsQuickAction: boolean = true;
  @StorageLink('readerUseChapterQuickJump') readerUseChapterQuickJump: boolean = true;

  private save(): void {
    ReaderSettingsStore.saveLayoutElementSettings(getContext(this), this.readerUseTtsQuickAction,
      this.readerUseChapterQuickJump).catch((e: Error) => {
      console.error('保存阅读布局元素设置失败:', e);
      HdsFeedback.showToast('布局元素设置保存失败');
    });
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.dark ? '#52000000' : '#26000000')
        .backdropBlur(ThemeRuntime.glassBlur('overlay', 18))
        .onClick(() => this.onClose())

      Column({ space: 4 }) {
        Row() {
          Text('布局元素设置')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor)
            .layoutWeight(1)
          ImmersiveBackButton({
            icon: $r('sys.symbol.xmark'),
            iconOffsetX: 0,
            iconColor: this.dark ? '#FFFFFFFF' : '#FF202124',
            darkMode: this.dark,
            buttonSize: 38,
            containerWidth: 38,
            containerHeight: 38,
            startInset: 0,
            compactLayout: true,
            accessibilityLabel: '关闭布局元素设置',
            onBack: () => this.onClose()
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text('控制点击阅读页后出现的快捷组件')
          .fontSize(13)
          .fontColor(this.subTextColor)
          .width('100%')
          .margin({ bottom: 8 })

        this.toggleRow('使用快速朗读组件', '显示朗读快捷按钮与朗读悬浮胶囊', this.readerUseTtsQuickAction,
          (enabled: boolean) => {
            this.readerUseTtsQuickAction = enabled;
            this.save();
          })
        this.toggleRow('使用章节快速跳转组件', '显示章节滑杆与上一章、下一章按钮', this.readerUseChapterQuickJump,
          (enabled: boolean) => {
            this.readerUseChapterQuickJump = enabled;
            this.onChapterQuickJumpChanged(enabled);
            this.save();
          })
      }
      .width(this.panelWidth)
      .padding({ left: 20, right: 20, top: 18, bottom: 18 })
      .borderRadius(ThemeRuntime.glassCornerRadius(24, 'overlay'))
      .backgroundColor(this.panelColor)
      .backdropBlur(ThemeRuntime.glassBlur('overlay', 24))
      .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: this.panelBorderColor })
      .shadow({
        radius: ThemeRuntime.glassShadowRadius('overlay'),
        color: this.panelShadowColor,
        offsetX: ThemeRuntime.glassShadowOffsetX('overlay'),
        offsetY: ThemeRuntime.glassShadowOffsetY('overlay')
      })
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  toggleRow(title: string, description: string, enabled: boolean, onChange: (enabled: boolean) => void) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(title)
          .fontSize(16)
          .fontColor(this.textColor)
        Text(description)
          .fontSize(12)
          .fontColor(this.subTextColor)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: enabled })
        .selectedColor(this.accentColor)
        .onChange(onChange)
    }
    .width('100%')
    .constraintSize({ minHeight: 64 })
    .padding({ left: 12, right: 8 })
    .borderRadius(14)
    .backgroundColor(this.dark ? '#1FFFFFFF' : '#0D000000')
    .alignItems(VerticalAlign.Center)
  }
}
