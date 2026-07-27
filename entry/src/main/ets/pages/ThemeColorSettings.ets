import { router } from '@kit.ArkUI';
import { syncSystemBars } from '../utils/SystemBars';
import { AppThemeSettings, AppThemeSettingsStore } from '../utils/AppThemeSettingsStore';
import { ReaderSettingsStore } from '../utils/ReaderSettingsStore';
import { ColorCodePicker } from '../components/ColorCodePicker';
import { ThemeRuntime } from '../theme/ThemeRuntime';
import { ThemeComponentSourceIds, ThemeIds, ThemePack, ThemeVariant } from '../theme/ThemeModels';
import { BuiltinThemeRegistry } from '../theme/BuiltinThemeRegistry';
import { ThemeAssetRegistry } from '../theme/ThemeAssetRegistry';
import { AccountSessionStore } from '../account/AccountSessionStore';
import { ImmersiveBackButton } from '../components/ImmersiveBackButton';

@Component
struct ThemeColorOption {
  @Link color: string;
  @Prop title: string = '';
  @Prop appDarkMode: boolean = false;
  @Prop cardColor: string = '#FFFFFF';
  @Prop primaryTextColor: string = '#1F1F1F';
  @Prop accentColor: string = '#007DFF';
  onColorChange: (color: string) => void = (_color: string): void => {};

  build() {
    Stack() {
      Row() {
        Text(this.title)
          .fontSize(16)
          .fontColor(this.primaryTextColor)
          .layoutWeight(1)
        Row()
          .width(30)
          .height(30)
          .borderRadius(15)
          .backgroundColor(this.color)
          .border({ width: 2, color: this.appDarkMode ? '#55FFFFFF' : '#22000000' })
      }
      .width('calc(100% - 32vp)')
      .height(60)
      .padding({ left: 0, right: 0 })
      .margin({ left: 16, right: 16 })
      .backgroundColor(Color.Transparent)
      .border({ width: { bottom: 0.5 }, color: this.appDarkMode ? '#24FFFFFF' : '#14000000' })
      .alignItems(VerticalAlign.Center)

      ColorCodePicker({
        value: this.color,
        placeholder: this.color,
        appDarkMode: this.appDarkMode,
        accentColor: this.accentColor,
        optionTitle: this.title,
        hideOptionTrigger: true,
        onColorChange: (color: string) => {
          this.color = color;
          this.onColorChange(color);
        }
      })
    }
    .width('100%')
    .margin({ top: 1 })
  }
}

@Entry
@Component
struct ThemeColorSettingsPage {
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('appCustomLightAccentColor') lightAccentColor: string = '#007DFF';
  @StorageLink('appCustomDarkAccentColor') darkAccentColor: string = '#4E9BFF';
  @StorageLink('appCustomLightButtonColor') lightButtonColor: string = '#007DFF';
  @StorageLink('appCustomDarkButtonColor') darkButtonColor: string = '#3F8CFF';
  @StorageLink('appCustomBaseThemeId') customBaseThemeId: string = AppThemeSettingsStore.DEFAULT_THEME_ID;
  @StorageLink('appThemeId') appThemeId: string = AppThemeSettingsStore.DEFAULT_THEME_ID;
  @StorageLink('accountEntitlementsRevision') accountEntitlementsRevision: number = 0;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State selectedMode: string = 'light';
  @State lightSources: ThemeComponentSourceIds = new ThemeComponentSourceIds();
  @State darkSources: ThemeComponentSourceIds = new ThemeComponentSourceIds();
  @State availableThemes: ThemePack[] = [];

  aboutToAppear(): void {
    this.reloadSettings();
    this.syncBars();
  }

  onPageShow(): void {
    this.reloadSettings();
    this.syncBars();
  }

  build() {
    Column() {
      this.titleBar()

      Scroll() {
        Column() {
          this.sectionTitle('从免费或已购买主题中组合部件，修改后自动启用自定义主题')
          this.modeOptions()
          this.sectionTitle(`${this.selectedMode === 'dark' ? '深色' : '浅色'}模式 · 主题部件`)
          this.sourceOptions()
          this.sectionTitle(`${this.selectedMode === 'dark' ? '深色' : '浅色'}模式 · 自定义颜色`)
          Column() {
            this.colorOptions()
          }
          .width('calc(100% - 24vp)')
          .margin({ left: 12, right: 12, top: 12 })
          .borderRadius(16)
          .clip(true)
          .backgroundColor(this.cardColor())
          this.previewPanel()
        }
        .width('100%')
        .padding({ bottom: 32 })
      }
      .layoutWeight(1)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%').justifyContent(FlexAlign.Start)
    .padding({ top: this.statusBarHeight, bottom: this.navBarHeight })
    .backgroundColor(this.pageColor())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  async reloadSettings(): Promise<void> {
    try {
      const settings = await AppThemeSettingsStore.load(getContext(this));
      AppThemeSettingsStore.applyToStorage(settings);
      this.customBaseThemeId = settings.customBaseThemeId;
      this.lightAccentColor = settings.customLightAccentColor;
      this.darkAccentColor = settings.customDarkAccentColor;
      this.lightButtonColor = settings.customLightButtonColor;
      this.darkButtonColor = settings.customDarkButtonColor;
      this.lightSources = AppThemeSettingsStore.cloneSources(
        settings.customLightSources, settings.customBaseThemeId);
      this.darkSources = AppThemeSettingsStore.cloneSources(
        settings.customDarkSources, settings.customBaseThemeId);
      this.refreshAvailableThemes();
    } catch (e) {
      console.warn('读取主题色设置失败:', e);
    }
  }

  async onSettingChanged(): Promise<void> {
    try {
      const settings: AppThemeSettings = await AppThemeSettingsStore.load(getContext(this));
      const previousThemeId = settings.themeId;
      settings.themeId = ThemeIds.CUSTOM;
      settings.customBaseThemeId = this.customBaseThemeId;
      settings.lightAccentColor = this.lightAccentColor;
      settings.darkAccentColor = this.darkAccentColor;
      settings.lightButtonColor = this.lightButtonColor;
      settings.darkButtonColor = this.darkButtonColor;
      settings.customLightAccentColor = this.lightAccentColor;
      settings.customDarkAccentColor = this.darkAccentColor;
      settings.customLightButtonColor = this.lightButtonColor;
      settings.customDarkButtonColor = this.darkButtonColor;
      AppThemeSettingsStore.applyToStorage(settings);
      await AppThemeSettingsStore.save(getContext(this), settings);
      if (previousThemeId !== settings.themeId) {
        await ReaderSettingsStore.switchThemeProfile(getContext(this), previousThemeId, settings.themeId);
      }
    } catch (e) {
      console.warn('保存主题色设置失败:', e);
    }
  }

  async setComponentSource(category: string, themeId: string): Promise<void> {
    if (!themeId) return;
    try {
      const settings: AppThemeSettings = await AppThemeSettingsStore.load(getContext(this));
      const previousThemeId = settings.themeId;
      const dark = this.selectedMode === 'dark';
      const sources = AppThemeSettingsStore.cloneSources(
        dark ? settings.customDarkSources : settings.customLightSources,
        settings.customBaseThemeId);
      this.setSourceValue(sources, category, themeId);
      if (dark) settings.customDarkSources = sources;
      else settings.customLightSources = sources;
      this.copyVariantOverrides(settings, BuiltinThemeRegistry.findById(themeId), dark, category);
      settings.themeId = ThemeIds.CUSTOM;
      settings.lightAccentColor = settings.customLightAccentColor;
      settings.darkAccentColor = settings.customDarkAccentColor;
      settings.lightButtonColor = settings.customLightButtonColor;
      settings.darkButtonColor = settings.customDarkButtonColor;
      AppThemeSettingsStore.applyToStorage(settings);
      await AppThemeSettingsStore.save(getContext(this), settings);
      this.lightSources = AppThemeSettingsStore.cloneSources(
        settings.customLightSources, settings.customBaseThemeId);
      this.darkSources = AppThemeSettingsStore.cloneSources(
        settings.customDarkSources, settings.customBaseThemeId);
      this.lightAccentColor = settings.customLightAccentColor;
      this.darkAccentColor = settings.customDarkAccentColor;
      this.lightButtonColor = settings.customLightButtonColor;
      this.darkButtonColor = settings.customDarkButtonColor;
      this.appThemeId = settings.themeId;
      if (previousThemeId !== settings.themeId) {
        await ReaderSettingsStore.switchThemeProfile(getContext(this), previousThemeId, settings.themeId);
      }
      if (dark === this.appDarkMode && category === 'layout') {
        const layout = BuiltinThemeRegistry.findById(themeId).readerLayout;
        await ReaderSettingsStore.saveLayoutSettings(getContext(this), layout.fontSize, layout.lineHeight,
          layout.paragraphSpacing, layout.marginLeft, layout.marginRight, layout.marginTop, layout.marginBottom);
      }
      if (dark === this.appDarkMode && category === 'typography') {
        getContext(this).getApplicationContext().setFont(ThemeRuntime.fontFamily());
      }
      this.syncBars();
    } catch (e) {
      console.warn('保存自定义主题部件失败:', e);
    }
  }

  setSourceValue(sources: ThemeComponentSourceIds, category: string, themeId: string): void {
    if (category === 'palette') sources.paletteThemeId = themeId;
    else if (category === 'reader') sources.readerThemeId = themeId;
    else if (category === 'bubble') sources.bubbleThemeId = themeId;
    else if (category === 'navigation') sources.navigationThemeId = themeId;
    else if (category === 'book') sources.bookThemeId = themeId;
    else if (category === 'typography') sources.typographyThemeId = themeId;
    else if (category === 'layout') sources.layoutThemeId = themeId;
    else if (category === 'radius') sources.radiusThemeId = themeId;
    else if (category === 'glass') sources.glassThemeId = themeId;
  }

  copyVariantOverrides(settings: AppThemeSettings, theme: ThemePack, dark: boolean, category: string): void {
    const variant = dark ? theme.dark : theme.light;
    if (category === 'palette') {
      if (dark) {
        settings.customDarkAccentColor = variant.colors.accentColor;
        settings.customDarkButtonColor = variant.colors.buttonColor;
      } else {
        settings.customLightAccentColor = variant.colors.accentColor;
        settings.customLightButtonColor = variant.colors.buttonColor;
      }
    }
    if (category !== 'reader') return;
    if (dark) {
      settings.customDarkReaderBackgroundColor = variant.reader.backgroundColor;
      settings.customDarkReaderTextColor = variant.reader.textColor;
      settings.customDarkReaderSubTextColor = variant.reader.subTextColor;
      settings.customDarkReaderBackgroundAssetId = variant.reader.backgroundAssetId;
      settings.customDarkReaderBackgroundImageFit = variant.reader.backgroundImageFit;
      settings.customDarkReaderContentTone = variant.reader.contentTone;
    } else {
      settings.customLightReaderBackgroundColor = variant.reader.backgroundColor;
      settings.customLightReaderTextColor = variant.reader.textColor;
      settings.customLightReaderSubTextColor = variant.reader.subTextColor;
      settings.customLightReaderBackgroundAssetId = variant.reader.backgroundAssetId;
      settings.customLightReaderBackgroundImageFit = variant.reader.backgroundImageFit;
      settings.customLightReaderContentTone = variant.reader.contentTone;
    }
  }

  currentSources(): ThemeComponentSourceIds {
    return this.selectedMode === 'dark' ? this.darkSources : this.lightSources;
  }

  sourceThemeId(category: string): string {
    const sources = this.currentSources();
    if (category === 'palette') return sources.paletteThemeId;
    if (category === 'reader') return sources.readerThemeId;
    if (category === 'bubble') return sources.bubbleThemeId;
    if (category === 'navigation') return sources.navigationThemeId;
    if (category === 'book') return sources.bookThemeId;
    if (category === 'typography') return sources.typographyThemeId;
    if (category === 'layout') return sources.layoutThemeId;
    if (category === 'radius') return sources.radiusThemeId;
    return sources.glassThemeId;
  }

  themeOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (const theme of this.availableThemes) {
      options.push({ value: theme.name });
    }
    return options;
  }

  sourceSelectedIndex(category: string): number {
    const themeId = this.sourceThemeId(category);
    for (let index = 0; index < this.availableThemes.length; index++) {
      if (this.availableThemes[index].id === themeId) return index;
    }
    return 0;
  }

  customPreviewTheme(): ThemePack {
    return AppThemeSettingsStore.currentCustomTheme(this.selectedMode === 'dark');
  }

  customPreviewVariant(): ThemeVariant {
    const theme = this.customPreviewTheme();
    return this.selectedMode === 'dark' ? theme.dark : theme.light;
  }

  refreshAvailableThemes(): void {
    const themes = BuiltinThemeRegistry.all();
    const available: ThemePack[] = [];
    for (const theme of themes) {
      if (BuiltinThemeRegistry.isFree(theme.id) || theme.id === this.appThemeId ||
        AccountSessionStore.hasValidEntitlement(theme.id) || this.isSourceInUse(theme.id)) {
        available.push(theme);
      }
    }
    this.availableThemes = available;
  }

  isSourceInUse(themeId: string): boolean {
    return this.sourceUsesTheme(this.lightSources, themeId) || this.sourceUsesTheme(this.darkSources, themeId);
  }

  sourceUsesTheme(sources: ThemeComponentSourceIds, themeId: string): boolean {
    return sources.paletteThemeId === themeId || sources.readerThemeId === themeId ||
      sources.bubbleThemeId === themeId || sources.navigationThemeId === themeId ||
      sources.bookThemeId === themeId || sources.typographyThemeId === themeId ||
      sources.layoutThemeId === themeId || sources.radiusThemeId === themeId ||
      sources.glassThemeId === themeId;
  }

  setCurrentAccentColor(color: string): void {
    const normalized = AppThemeSettingsStore.normalizeColor(color, this.currentAccentColor());
    if (this.selectedMode === 'dark') {
      this.darkAccentColor = normalized;
    } else {
      this.lightAccentColor = normalized;
    }
    this.onSettingChanged();
  }

  setCurrentButtonColor(color: string): void {
    const normalized = AppThemeSettingsStore.normalizeColor(color, this.currentButtonColor());
    if (this.selectedMode === 'dark') {
      this.darkButtonColor = normalized;
    } else {
      this.lightButtonColor = normalized;
    }
    this.onSettingChanged();
  }

  currentAccentColor(): string {
    return this.selectedMode === 'dark' ? this.darkAccentColor : this.lightAccentColor;
  }

  currentButtonColor(): string {
    return this.selectedMode === 'dark' ? this.darkButtonColor : this.lightButtonColor;
  }

  pageColor(): string {
    return ThemeRuntime.pageColor(this.appDarkMode);
  }

  cardColor(): string {
    return ThemeRuntime.cardColor(this.appDarkMode);
  }

  inputColor(): string {
    return ThemeRuntime.inputColor(this.appDarkMode);
  }

  primaryTextColor(): string {
    return ThemeRuntime.primaryTextColor(this.appDarkMode);
  }

  subTextColor(): string {
    return ThemeRuntime.subTextColor(this.appDarkMode);
  }

  syncBars(): void {
    syncSystemBars(getContext(this), this.appDarkMode, this.pageColor());
  }

  @Builder
  titleBar() {
    Row() {
      ImmersiveBackButton({ iconColor: this.primaryTextColor(), darkMode: this.appDarkMode,
        buttonSize: 40, containerWidth: 56, materialScale: 0.83, compactLayout: true,
        onBack: () => router.back() })
      Text('自定义主题')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryTextColor())
        .layoutWeight(1)
    }
    .width('100%')
    .height(56)
    .backgroundColor(this.cardColor())
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor(this.subTextColor())
      .width('100%')
      .padding({ left: 16, right: 16, top: 20, bottom: 8 })
  }

  @Builder
  modeOptions() {
    Row({ space: 8 }) {
      this.modeButton('浅色模式', 'light')
      this.modeButton('深色模式', 'dark')
    }
    .width('calc(100% - 24vp)')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .margin({ left: 12, right: 12 })
    .borderRadius(16)
    .clip(true)
    .backgroundColor(this.cardColor())
  }

  @Builder
  modeButton(title: string, mode: string) {
    Stack({ alignContent: Alignment.Center }) {
      Text(title)
        .fontSize(14)
        .fontColor(this.selectedMode === mode ? '#FFFFFF' : this.primaryTextColor())
    }
      .layoutWeight(1)
      .height(38)
      .borderRadius(19)
      .backgroundColor(this.selectedMode === mode ? this.currentAccentColor() : this.inputColor())
      .onClick(() => {
        this.selectedMode = mode;
      })
  }

  @Builder
  sourceOptions() {
    Column() {
      this.componentSourceRow('完整配色', '页面、卡片、文字、状态栏图标及基础颜色', 'palette')
      this.componentSourceRow('阅读背景', '阅读背景、正文颜色和背景素材', 'reader')
      this.componentSourceRow('强调气泡', '正文强调方式、气泡样式及气泡配色', 'bubble')
      this.componentSourceRow('导航图标', '书架、发现、搜索和我的底部图标', 'navigation')
      this.componentSourceRow('书籍素材', '主题封面、书架边框和文件夹图案', 'book')
      this.componentSourceRow('字体', '主题自带的应用字体风格', 'typography')
      this.componentSourceRow('阅读排版', '字号、行距、段距和页面边距', 'layout')
      this.componentSourceRow('圆角形状', '卡片、按钮、气泡等圆角尺寸', 'radius')
      this.componentSourceRow('磨砂效果', '模糊、透明度、边框和阴影参数', 'glass', false)
    }
    .width('calc(100% - 24vp)')
    .margin({ left: 12, right: 12 })
    .borderRadius(16)
    .clip(true)
    .backgroundColor(this.cardColor())
  }

  @Builder
  componentSourceRow(title: string, desc: string, category: string, divider: boolean = true) {
    Row({ space: 8 }) {
      Column() {
        Text(title)
          .fontSize(15)
          .fontColor(this.primaryTextColor())
        Text(desc)
          .fontSize(11)
          .fontColor(this.subTextColor())
          .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Select(this.themeOptions())
        .selected(this.sourceSelectedIndex(category))
        .value(BuiltinThemeRegistry.findById(this.sourceThemeId(category)).name)
        .font({ size: 13 })
        .fontColor(this.subTextColor())
        .backgroundColor(Color.Transparent)
        .arrowPosition(ArrowPosition.END)
        .padding({ left: 0, right: 0 })
        .borderRadius(0)
        .border({ width: 0 })
        .optionBgColor(Color.Transparent)
        .optionFontColor(this.primaryTextColor())
        .selectedOptionFontColor(ThemeRuntime.accentColor(this.appDarkMode))
        .selectedOptionBgColor(ThemeRuntime.accentSurfaceColor(this.appDarkMode))
        .menuBackgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode))
        .menuBackgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
        .onSelect((index: number) => {
          if (index >= 0 && index < this.availableThemes.length) {
            this.setComponentSource(category, this.availableThemes[index].id);
          }
        })
    }
    .width('calc(100% - 28vp)')
    .constraintSize({ minHeight: 68 })
    .padding({ top: 9, bottom: 9 })
    .margin({ left: 14, right: 14 })
    .border({ width: { bottom: divider ? 0.5 : 0 },
      color: this.appDarkMode ? '#24FFFFFF' : '#14000000' })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  colorOptions() {
    if (this.selectedMode === 'dark') {
      ThemeColorOption({
        title: '按钮色',
        color: $darkButtonColor,
        appDarkMode: this.appDarkMode,
        cardColor: this.cardColor(),
        primaryTextColor: this.primaryTextColor(),
        accentColor: this.darkAccentColor,
        onColorChange: (color: string) => {
          this.setCurrentButtonColor(color);
        }
      })
      ThemeColorOption({
        title: '强调色',
        color: $darkAccentColor,
        appDarkMode: this.appDarkMode,
        cardColor: this.cardColor(),
        primaryTextColor: this.primaryTextColor(),
        accentColor: this.darkAccentColor,
        onColorChange: (color: string) => {
          this.setCurrentAccentColor(color);
        }
      })
    } else {
      ThemeColorOption({
        title: '按钮色',
        color: $lightButtonColor,
        appDarkMode: this.appDarkMode,
        cardColor: this.cardColor(),
        primaryTextColor: this.primaryTextColor(),
        accentColor: this.lightAccentColor,
        onColorChange: (color: string) => {
          this.setCurrentButtonColor(color);
        }
      })
      ThemeColorOption({
        title: '强调色',
        color: $lightAccentColor,
        appDarkMode: this.appDarkMode,
        cardColor: this.cardColor(),
        primaryTextColor: this.primaryTextColor(),
        accentColor: this.lightAccentColor,
        onColorChange: (color: string) => {
          this.setCurrentAccentColor(color);
        }
      })
    }
  }

  @Builder
  previewPanel() {
    Column() {
      Text(`${this.selectedMode === 'dark' ? '深色' : '浅色'}模式预览`)
        .fontSize(13)
        .fontColor(this.subTextColor())
        .width('100%')
        .margin({ bottom: 12 })

      Row({ space: 10 }) {
        Stack() {
          if (this.customPreviewVariant().reader.backgroundAssetId) {
            Image(ThemeAssetRegistry.readerBackground(
              this.customPreviewVariant().reader.backgroundAssetId))
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
          }
          Text('阅读')
            .fontSize(14)
            .fontFamily(this.customPreviewTheme().typography.appFontFamily)
            .fontColor(this.customPreviewVariant().reader.textColor)
        }
        .width(70)
        .height(58)
        .borderRadius(this.customPreviewTheme().radius.medium)
        .backgroundColor(this.customPreviewVariant().reader.backgroundColor)

        Column({ space: 7 }) {
          Row({ space: 6 }) {
            Blank()
              .height(8)
              .layoutWeight(1)
              .borderRadius(4)
              .backgroundColor(this.customPreviewVariant().colors.primaryTextColor)
            Blank()
              .width(28)
              .height(8)
              .borderRadius(4)
              .backgroundColor(this.customPreviewVariant().colors.subTextColor)
          }
          Text('强调气泡')
            .fontSize(12)
            .fontColor(this.customPreviewVariant().regexEmphasis.emphasisTextColor)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(this.customPreviewTheme().radius.bubble)
            .backgroundColor(this.customPreviewVariant().regexEmphasis.emphasisColor)
          Row({ space: 8 }) {
            ForEach(['bookshelf', 'explore', 'search', 'mine'], (tabId: string) => {
              Image(ThemeAssetRegistry.navigationIcon(
                this.customPreviewTheme().navigation.iconPackId, tabId))
                .width(17)
                .height(17)
                .fillColor(this.customPreviewVariant().colors.accentColor)
            }, (tabId: string) => `custom_preview_${this.selectedMode}_${tabId}`)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Stack() {
          Image(ThemeAssetRegistry.themeBookCover(this.customPreviewTheme().book.coverAssetId))
            .width(30)
            .height(44)
            .objectFit(ImageFit.Fill)
          Image(ThemeAssetRegistry.themeShelfFrame(this.customPreviewTheme().book.shelfFrameAssetId))
            .width(30)
            .height(44)
            .objectFit(ImageFit.Fill)
        }
        .width(30)
        .height(44)
      }
      .width('100%')
      .padding(12)
      .borderRadius(this.customPreviewTheme().radius.medium)
      .backgroundColor(this.customPreviewVariant().colors.inputColor)

      Row({ space: 12 }) {
        Button('主要按钮')
          .height(40)
          .layoutWeight(1)
          .fontColor('#FFFFFF')
          .backgroundColor(this.currentButtonColor())
        Text('强调文字')
          .fontSize(15)
          .fontColor(this.currentAccentColor())
          .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .backgroundColor(this.cardColor())
    .margin({ top: 12 })
  }

}
