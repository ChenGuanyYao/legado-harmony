import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { syncSystemBars } from '../utils/SystemBars';
import { AppIconManager, AppIconOption } from '../utils/AppIconManager';
import { AppIconSettings, AppIconSettingsStore } from '../utils/AppIconSettingsStore';
import { ThemeRuntime } from '../theme/ThemeRuntime';
import { HdsFeedback } from '../utils/HdsFeedback';
import { AppFontSize } from '../theme/AppFontSize';
import { AppSpacing } from '../theme/AppSpacing';
import { PageScaffold } from '../components/common/PageScaffold';

@Entry
@Component
struct AppIconSettingsPage {
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;
  @StorageLink('appIconId') appIconId: string = AppIconSettingsStore.DEFAULT_ICON_ID;
  @State configuredIconIds: string[] = [];
  @State loadedDynamicIcons: boolean = false;
  @State applyingIconId: string = '';

  aboutToAppear(): void {
    this.syncBars();
    AppIconSettingsStore.load(getContext(this)).then((settings: AppIconSettings) => {
      AppIconSettingsStore.applyToStorage(settings);
    }).catch(() => {
      AppStorage.setOrCreate(AppIconSettingsStore.KEY_ICON_ID, AppIconSettingsStore.DEFAULT_ICON_ID);
    });
    this.refreshDynamicIcons();
  }

  onPageShow(): void {
    this.syncBars();
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      PageScaffold({ title: '图标设置', onBack: () => this.backSafely(), content: () => {
        this.pageContent()
      } })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  pageContent() {
    Text('选择桌面图标')
      .fontSize(AppFontSize.BODY)
      .fontColor(this.subTextColor())
      .width('100%')
      .padding({ left: AppSpacing.XL, right: AppSpacing.XL, top: AppSpacing.XXL, bottom: AppSpacing.MD })

    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
      ForEach(AppIconManager.OPTIONS, (option: AppIconOption) => {
        this.iconCard(option)
      }, (option: AppIconOption) => option.id)
    }
    .width('100%')
    .padding({ left: AppSpacing.LG, right: AppSpacing.LG })
  }

  pageColor(): string {
    return ThemeRuntime.pageColor(this.appDarkMode);
  }

  cardColor(): string {
    return ThemeRuntime.cardColor(this.appDarkMode);
  }

  primaryTextColor(): string {
    return ThemeRuntime.primaryTextColor(this.appDarkMode);
  }

  subTextColor(): string {
    return ThemeRuntime.subTextColor(this.appDarkMode);
  }

  optionBorderColor(selected: boolean): string {
    if (selected) {
      return ThemeRuntime.accentColor(this.appDarkMode);
    }
    return ThemeRuntime.dividerColor(this.appDarkMode);
  }

  syncBars(): void {
    syncSystemBars(getContext(this), this.appDarkMode, this.pageColor());
  }

  refreshDynamicIcons(): void {
    AppIconManager.queryConfiguredIconIds().then((ids: string[]) => {
      this.configuredIconIds = ids;
      this.loadedDynamicIcons = true;
    }).catch(() => {
      this.configuredIconIds = [];
      this.loadedDynamicIcons = false;
    });
  }

  isConfigured(option: AppIconOption): boolean {
    if (!option.dynamicIconId) {
      return true;
    }
    return this.configuredIconIds.includes(option.dynamicIconId);
  }

  async selectIcon(option: AppIconOption): Promise<void> {
    if (this.applyingIconId) {
      return;
    }
    if (this.appIconId === option.id) {
      this.showToastSafely(`当前已是${option.title}`);
      return;
    }
    this.applyingIconId = option.id;
    try {
      await AppIconManager.applyIcon(option);
      const settings = new AppIconSettings();
      settings.iconId = option.id;
      AppIconSettingsStore.applyToStorage(settings);
      await AppIconSettingsStore.save(getContext(this), settings);
      this.showToastSafely(`已切换为${option.title}`);
    } catch (e) {
      hilog.warn(0x0000, 'appIcon', 'Switch app icon failed option=%{public}s err=%{public}s',
        option.id, JSON.stringify(e));
      this.showToastSafely(this.switchErrorMessage(e));
      this.refreshDynamicIcons();
    } finally {
      this.applyingIconId = '';
    }
  }

  showToastSafely(message: string): void {
    try {
      HdsFeedback.showToast(message);
    } catch (e) {
      hilog.warn(0x0000, 'appIcon', 'Show app icon toast failed err=%{public}s', JSON.stringify(e));
    }
  }

  backSafely(): void {
    try {
      router.back();
    } catch (e) {
      hilog.warn(0x0000, 'appIcon', 'Back from app icon settings failed err=%{public}s', JSON.stringify(e));
    }
  }

  @Builder
  iconCard(option: AppIconOption) {
    Column() {
      Stack({ alignContent: Alignment.TopEnd }) {
        Image(option.preview)
          .width(72)
          .height(72)
          .borderRadius(18)
          .objectFit(ImageFit.Cover)
        if (this.appIconId === option.id) {
          Text('✓')
            .fontSize(AppFontSize.BODY)
            .fontColor(ThemeRuntime.onAccentColor())
            .fontWeight(FontWeight.Bold)
            .width(22)
            .height(22)
            .textAlign(TextAlign.Center)
            .backgroundColor(ThemeRuntime.accentColor(this.appDarkMode))
            .borderRadius(11)
            .margin({ top: -4, right: -4 })
        }
      }
      .width(82)
      .height(82)
      .alignContent(Alignment.Center)

      Text(option.title)
        .fontSize(AppFontSize.BODY_LARGE)
        .fontColor(this.primaryTextColor())
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: AppSpacing.MD })

      Text(option.desc)
        .fontSize(AppFontSize.CAPTION)
        .fontColor(this.subTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: AppSpacing.XXS })

      if (this.loadedDynamicIcons && !this.isConfigured(option)) {
        Text('未生效')
          .fontSize(AppFontSize.MICRO)
          .fontColor('#B46A00')
          .padding({ left: AppSpacing.MD, right: AppSpacing.MD, top: AppSpacing.XXS, bottom: AppSpacing.XXS })
          .backgroundColor('#FFF2D6')
          .borderRadius(ThemeRuntime.mediumRadius())
          .margin({ top: AppSpacing.MD })
      } else if (this.applyingIconId === option.id) {
        Text('切换中')
          .fontSize(AppFontSize.MICRO)
          .fontColor(this.subTextColor())
          .margin({ top: AppSpacing.MD })
      }
    }
    .width('48%')
    .height(166)
    .padding({ top: AppSpacing.LG, left: AppSpacing.MD, right: AppSpacing.MD, bottom: AppSpacing.LG })
    .margin({ bottom: AppSpacing.LG })
    .backgroundColor(this.cardColor())
    .borderRadius(ThemeRuntime.cardRadius())
    .border({ width: 1, color: this.optionBorderColor(this.appIconId === option.id) })
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.selectIcon(option);
    })
  }

  switchErrorMessage(error: Object): string {
    const code = this.errorCode(error);
    if (!code) {
      return '桌面图标切换失败，请检查图标管理服务、审核状态和图标 ID';
    }
    return `桌面图标切换失败(${code})，请检查图标管理服务、审核状态和图标 ID`;
  }

  errorCode(error: Object): string {
    if (!error) {
      return '';
    }
    const source = error as Record<string, Object>;
    const code = source['code'];
    if (code === undefined || code === null) {
      return '';
    }
    return `${code}`;
  }
}
