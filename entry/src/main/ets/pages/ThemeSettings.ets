import { promptAction, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppThemeSettings, AppThemeSettingsStore } from '../utils/AppThemeSettingsStore';
import { ReaderSettings, ReaderSettingsStore } from '../utils/ReaderSettingsStore';
import { ReaderThemeHelper } from '../utils/ReaderThemeHelper';
import { syncSystemBars } from '../utils/SystemBars';
import { RecentReadCardUpdater } from '../utils/RecentReadCardUpdater';
import { BuiltinThemeRegistry } from '../theme/BuiltinThemeRegistry';
import { ImmersiveBackButton } from '../components/ImmersiveBackButton';
import { ThemeAssetRegistry } from '../theme/ThemeAssetRegistry';
import { ThemeIds, ThemePack, ThemeVariant } from '../theme/ThemeModels';
import { ThemeRuntime } from '../theme/ThemeRuntime';
import { AccountCommerceConfig } from '../account/AccountCommerceConfig';
import { AccountApiError, ThemeEntitlement } from '../account/AccountCommerceModels';
import { AccountSessionStore } from '../account/AccountSessionStore';
import { HuaweiAccountService } from '../account/HuaweiAccountService';
import {
  ReaderRegexBubbleStyleResolver,
  ReaderRegexEmphasisContext,
  ReaderResolvedRegexEmphasis
} from '../model/reader/ReaderRegexFontRule';
import fs from '@ohos.file.fs';

@Entry
@Component
struct ThemeSettingsPage {
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('appThemeId') appThemeId: string = AppThemeSettingsStore.DEFAULT_THEME_ID;
  @StorageLink('appThemeBookCoverEnabled') themeBookCoverEnabled: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;
  @StorageLink('appCustomBaseThemeId') customBaseThemeId: string = AppThemeSettingsStore.DEFAULT_THEME_ID;
  @StorageLink('appCustomLightAccentColor') customLightAccentColor: string = '#007DFF';
  @StorageLink('appCustomDarkAccentColor') customDarkAccentColor: string = '#4E9BFF';
  @StorageLink('appCustomLightButtonColor') customLightButtonColor: string = '#007DFF';
  @StorageLink('appCustomDarkButtonColor') customDarkButtonColor: string = '#3F8CFF';
  @StorageLink('appCustomLightReaderBackgroundColor') customLightReaderBackgroundColor: string = '#F7F1E3';
  @StorageLink('appCustomLightReaderTextColor') customLightReaderTextColor: string = '#2F261D';
  @StorageLink('appCustomLightReaderSubTextColor') customLightReaderSubTextColor: string = '#7A6F63';
  @StorageLink('appCustomLightReaderBackgroundAssetId') customLightReaderBackgroundAssetId: string = '';
  @StorageLink('appCustomLightReaderBackgroundImageFit') customLightReaderBackgroundImageFit: string = 'cover';
  @StorageLink('appCustomLightReaderContentTone') customLightReaderContentTone: string = 'light';
  @StorageLink('appCustomDarkReaderBackgroundColor') customDarkReaderBackgroundColor: string = '#1F2329';
  @StorageLink('appCustomDarkReaderTextColor') customDarkReaderTextColor: string = '#D8D8D8';
  @StorageLink('appCustomDarkReaderSubTextColor') customDarkReaderSubTextColor: string = '#9AA0A6';
  @StorageLink('appCustomDarkReaderBackgroundAssetId') customDarkReaderBackgroundAssetId: string = '';
  @StorageLink('appCustomDarkReaderBackgroundImageFit') customDarkReaderBackgroundImageFit: string = 'cover';
  @StorageLink('appCustomDarkReaderContentTone') customDarkReaderContentTone: string = 'dark';
  @StorageLink('readerLightThemeIndex') readerLightThemeIndex: number = 0;
  @StorageLink('readerDarkThemeIndex') readerDarkThemeIndex: number = 0;
  @StorageLink('accountLoggedIn') accountLoggedIn: boolean = false;
  @StorageLink('accountPoints') accountPoints: number = 0;
  @StorageLink('accountEntitlementsRevision') accountEntitlementsRevision: number = 0;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State applyingThemeId: string = '';

  aboutToAppear(): void {
    this.loadThemeSettings();
    this.initializeAccount();
    this.syncBars();
  }

  onPageShow(): void {
    this.syncBars();
  }

  build() {
    Column() {
      this.titleBar()

      Scroll() {
        Column({ space: 12 }) {
          this.sectionTitle('默认主题')
          this.themeCard(BuiltinThemeRegistry.findById(ThemeIds.PLAIN_DEFAULT))
          this.sectionTitle('自定义主题')
          this.themeCard(this.customTheme())
          this.sectionTitle('内置主题')
          ForEach(this.additionalBuiltinThemes(), (theme: ThemePack) => {
            this.themeCard(theme)
          }, (theme: ThemePack) => theme.id)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 14, bottom: 32 })
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

  async initializeAccount(): Promise<void> {
    try {
      await HuaweiAccountService.initialize(getContext(this));
      if (AccountSessionStore.isLoggedIn() && AccountCommerceConfig.isServerConfigured()) {
        await HuaweiAccountService.refresh(getContext(this));
      }
    } catch (e) {
      console.warn('同步主题权益失败:', e);
    }
  }

  async loadThemeSettings(): Promise<void> {
    try {
      const settings = await AppThemeSettingsStore.load(getContext(this));
      const theme = settings.themeId === ThemeIds.CUSTOM ?
        AppThemeSettingsStore.customTheme(settings, this.appDarkMode) :
        BuiltinThemeRegistry.findById(settings.themeId);
      if (settings.themeBookCoverEnabled && !this.themeHasBookCover(theme)) {
        settings.themeBookCoverEnabled = false;
        await AppThemeSettingsStore.save(getContext(this), settings);
      }
      AppThemeSettingsStore.applyToStorage(settings);
      this.appThemeId = settings.themeId;
      this.themeBookCoverEnabled = settings.themeBookCoverEnabled;
      const readerSettings = await ReaderSettingsStore.load(getContext(this));
      ReaderSettingsStore.applyToStorage(readerSettings);
    } catch (e) {
      console.warn('加载主题设置失败:', e);
    }
  }

  async selectTheme(themeId: string): Promise<void> {
    if (this.applyingThemeId || themeId === this.appThemeId) {
      return;
    }
    const accessible = await this.ensureThemeAccess(themeId);
    if (!accessible) {
      return;
    }
    this.applyingThemeId = themeId;
    try {
      const theme = themeId === ThemeIds.CUSTOM ? this.customTheme() : BuiltinThemeRegistry.findById(themeId);
      let enableThemeBookCover = false;
      if (this.themeHasBookCover(theme)) {
        const coverDialog = await promptAction.showDialog({
          title: `启用「${theme.name}」主题封面？`,
          message: '启用后，书架会忽略图书原封面，改用这套主题封面与配套书籍边框。之后可在本页随时关闭。',
          buttons: [
            { text: '保留原封面', color: this.subTextColor() },
            { text: '启用主题封面', color: this.accentColor() }
          ]
        });
        enableThemeBookCover = coverDialog.index === 1;
      }
      const previous: AppThemeSettings = await AppThemeSettingsStore.load(getContext(this));
      const settings: AppThemeSettings = AppThemeSettingsStore.activateTheme(themeId, previous);
      settings.themeBookCoverEnabled = enableThemeBookCover;
      AppThemeSettingsStore.applyToStorage(settings);
      await AppThemeSettingsStore.save(getContext(this), settings);
      this.appThemeId = settings.themeId;
      this.themeBookCoverEnabled = settings.themeBookCoverEnabled;
      const readerSettings = await ReaderSettingsStore.switchThemeProfile(
        getContext(this), previous.themeId, settings.themeId);
      const layout = theme.readerLayout;
      await ReaderSettingsStore.saveLayoutSettings(getContext(this), layout.fontSize, layout.lineHeight,
        layout.paragraphSpacing, layout.marginLeft, layout.marginRight, layout.marginTop, layout.marginBottom);
      await ReaderSettingsStore.saveThemeSettings(getContext(this), ReaderThemeHelper.APP_THEME_INDEX,
        ReaderThemeHelper.APP_THEME_INDEX, readerSettings.lightCustomThemeBackgroundColor,
        readerSettings.lightCustomThemeTextColor, readerSettings.darkCustomThemeBackgroundColor,
        readerSettings.darkCustomThemeTextColor, this.appDarkMode, readerSettings.customThemesRaw);
      this.readerLightThemeIndex = ReaderThemeHelper.APP_THEME_INDEX;
      this.readerDarkThemeIndex = ReaderThemeHelper.APP_THEME_INDEX;
      await this.applyThemeFontWhenAvailable();
      this.refreshRecentReadCard();
      this.syncBars();
      promptAction.showToast({ message: `已应用「${BuiltinThemeRegistry.findById(themeId).name}」主题` });
    } catch (e) {
      console.error('应用主题失败:', e);
      promptAction.showToast({ message: '应用主题失败，请稍后重试' });
    } finally {
      this.applyingThemeId = '';
    }
  }

  async ensureThemeAccess(themeId: string): Promise<boolean> {
    if (themeId === ThemeIds.CUSTOM || BuiltinThemeRegistry.isFree(themeId) || themeId === this.appThemeId ||
      AccountSessionStore.hasValidEntitlement(themeId)) {
      return true;
    }
    if (!this.accountLoggedIn) {
      const loginDialog = await promptAction.showDialog({
        title: '登录后获取主题',
        message: `该主题需要 ${AccountCommerceConfig.THEME_PRICE_POINTS} 点，获取后有效一年。首次登录免费送 300 点。`,
        buttons: [
          { text: '取消', color: this.subTextColor() },
          { text: '去登录', color: this.accentColor() }
        ]
      });
      if (loginDialog.index === 1) {
        router.pushUrl({ url: 'pages/AccountCenter' });
      }
      return false;
    }
    const theme = BuiltinThemeRegistry.findById(themeId);
    const confirm = await promptAction.showDialog({
      title: `获取「${theme.name}」`,
      message: `将扣除 ${AccountCommerceConfig.THEME_PRICE_POINTS} 点，主题有效期为 365 天。有效期内可在所有已登录终端使用。`,
      buttons: [
        { text: '取消', color: this.subTextColor() },
        { text: `确认 · ${AccountCommerceConfig.THEME_PRICE_POINTS} 点`, color: this.accentColor() }
      ]
    });
    if (confirm.index !== 1) {
      return false;
    }
    try {
      await HuaweiAccountService.redeemTheme(getContext(this), themeId);
      promptAction.showToast({ message: `已获取「${theme.name}」，有效期一年` });
      return true;
    } catch (e) {
      const error = e as AccountApiError;
      if (error.errorCode === 'INSUFFICIENT_POINTS') {
        const recharge = await promptAction.showDialog({
          title: '点数不足',
          message: `当前有 ${this.accountPoints} 点，获取该主题需要 ${AccountCommerceConfig.THEME_PRICE_POINTS} 点。`,
          buttons: [
            { text: '取消', color: this.subTextColor() },
            { text: '去充值', color: this.accentColor() }
          ]
        });
        if (recharge.index === 1) {
          router.pushUrl({ url: 'pages/AccountCenter' });
        }
      } else {
        promptAction.showToast({ message: error.message || '获取主题失败，请稍后重试' });
      }
      return false;
    }
  }

  async setThemeBookCoverEnabled(enabled: boolean): Promise<void> {
    try {
      const settings = await AppThemeSettingsStore.load(getContext(this));
      settings.themeBookCoverEnabled = enabled;
      AppThemeSettingsStore.applyToStorage(settings);
      await AppThemeSettingsStore.save(getContext(this), settings);
      this.themeBookCoverEnabled = enabled;
      promptAction.showToast({ message: enabled ? '已启用主题封面与书籍边框' : '已恢复图书原封面' });
    } catch (e) {
      console.error('保存主题封面设置失败:', e);
      promptAction.showToast({ message: '保存主题封面设置失败' });
    }
  }

  async applyThemeFontWhenAvailable(): Promise<void> {
    const settings: ReaderSettings = await ReaderSettingsStore.load(getContext(this));
    if (settings.fontFilePath && this.fontFileExists(settings.fontFilePath)) {
      return;
    }
    try {
      getContext(this).getApplicationContext().setFont(ThemeRuntime.fontFamily());
    } catch (e) {
      console.warn('应用主题默认字体失败:', e);
    }
  }

  fontFileExists(filePath: string): boolean {
    if (!filePath) {
      return false;
    }
    try {
      return fs.accessSync(filePath);
    } catch (e) {
      return false;
    }
  }

  refreshRecentReadCard(): void {
    const context = getContext(this) as common.UIAbilityContext;
    RecentReadCardUpdater.reload(context).catch((e: Error) => {
      console.warn('主题切换后刷新最近阅读卡片失败:', e);
    });
  }

  customTheme(): ThemePack {
    return AppThemeSettingsStore.currentCustomTheme(this.appDarkMode);
  }

  activeVariant(theme: ThemePack): ThemeVariant {
    return this.appDarkMode ? theme.dark : theme.light;
  }

  isSelected(theme: ThemePack): boolean {
    return theme.id === this.appThemeId;
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

  accentColor(): string {
    return ThemeRuntime.accentColor(this.appDarkMode);
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
      Text('主题')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryTextColor())
        .layoutWeight(1)
    }
    .width('100%')
    .height(56)
    .padding({ right: 12 })
    .backgroundColor(this.cardColor())
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor(this.subTextColor())
      .width('100%')
      .padding({ left: 2, top: 6, bottom: 0 })
  }

  @Builder
  themeBookCoverSetting(theme: ThemePack) {
    Row({ space: 12 }) {
      Stack() {
        Swiper() {
          ForEach(this.themeCoverSet(theme), (cover: ResourceStr, index: number) => {
            Image(cover)
              .width(42)
              .height(58)
              .objectFit(ImageFit.Fill)
          }, (_cover: ResourceStr, index: number) => `active_cover_${index}`)
        }
        .width(42)
        .height(58)
        .autoPlay(this.themeCoverSet(theme).length > 1)
        .interval(2800)
        .indicator(false)
        .loop(true)
        Image(ThemeAssetRegistry.themeShelfFrame(theme.book.shelfFrameAssetId))
          .width(42)
          .height(58)
          .objectFit(ImageFit.Fill)
      }
      .width(42)
      .height(58)

      Column({ space: 4 }) {
        Text('主题书籍封面')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.activeVariant(theme).colors.primaryTextColor)
        Text(this.themeBookCoverEnabled ? '书架已使用主题封面和配套边框' : '保留每本书原有封面')
          .fontSize(12)
          .fontColor(this.activeVariant(theme).colors.subTextColor)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: this.themeBookCoverEnabled })
        .selectedColor(this.accentColor())
        .onChange((enabled: boolean) => {
          this.setThemeBookCoverEnabled(enabled);
        })
    }
    .width('100%')
    .padding(12)
    .alignItems(VerticalAlign.Center)
    .borderRadius(theme.radius.medium)
    .backgroundColor(this.activeVariant(theme).colors.inputColor)
  }

  @Builder
  themeCard(theme: ThemePack) {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Image(ThemeAssetRegistry.themeLogo(theme.id))
          .width(42)
          .height(42)
          .borderRadius(theme.radius.medium)
          .objectFit(ImageFit.Contain)

        Column({ space: 3 }) {
          Text(theme.name)
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontFamily(theme.typography.appFontFamily)
            .fontColor(this.activeVariant(theme).colors.primaryTextColor)
          Text(theme.description)
            .fontSize(12)
            .fontColor(this.activeVariant(theme).colors.subTextColor)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.isSelected(theme)) {
          Text('已启用')
            .fontSize(12)
            .fontColor('#FFFFFF')
            .padding({ left: 9, right: 9, top: 4, bottom: 4 })
            .borderRadius(12)
            .backgroundColor(this.activeVariant(theme).colors.accentColor)
        } else if (this.applyingThemeId === theme.id) {
          Text('应用中')
            .fontSize(12)
            .fontColor(this.activeVariant(theme).colors.accentColor)
        } else if (theme.id !== ThemeIds.CUSTOM) {
          Text(this.themeAccessLabel(theme.id))
            .fontSize(11)
            .fontColor(this.hasThemeAccess(theme.id) ?
              this.activeVariant(theme).colors.accentColor : this.activeVariant(theme).colors.subTextColor)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .borderRadius(11)
            .backgroundColor(this.activeVariant(theme).colors.inputColor)
        }
      }
      .width('100%')

      this.themeVisualPreview(theme)
      if (this.isSelected(theme) && this.themeHasBookCover(theme)) {
        this.themeBookCoverSetting(theme)
      }
      Row({ space: 8 }) {
        if (!this.isSelected(theme) && this.themeHasBookCover(theme)) {
          Stack() {
            Swiper() {
              ForEach(this.themeCoverSet(theme), (cover: ResourceStr, index: number) => {
                Image(cover)
                  .width(28)
                  .height(40)
                  .objectFit(ImageFit.Fill)
              }, (_cover: ResourceStr, index: number) => `${theme.id}_cover_${index}`)
            }
            .width(28)
            .height(40)
            .autoPlay(this.themeCoverSet(theme).length > 1)
            .interval(3000)
            .indicator(false)
            .loop(true)
            Image(ThemeAssetRegistry.themeShelfFrame(theme.book.shelfFrameAssetId))
              .width(28)
              .height(40)
              .objectFit(ImageFit.Fill)
          }
          .width(28)
          .height(40)
        }
        Text(`${theme.readerLayout.fontSize} 字号 · ${theme.readerLayout.lineHeight} 行距 · ` +
          `${theme.readerLayout.marginLeft}/${theme.readerLayout.marginRight} 左右边距`)
          .fontSize(11)
          .fontColor(this.activeVariant(theme).colors.subTextColor)
          .layoutWeight(1)
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      if (theme.id === ThemeIds.CUSTOM) {
        Row() {
          Text('浅色 / 深色可分别组合全部主题部件')
            .fontSize(11)
            .fontColor(this.activeVariant(theme).colors.subTextColor)
            .layoutWeight(1)
          Button('编辑主题')
            .height(32)
            .fontSize(12)
            .fontColor('#FFFFFF')
            .backgroundColor(this.activeVariant(theme).colors.buttonColor)
            .onClick(() => {
              router.pushUrl({ url: 'pages/ThemeColorSettings' });
            })
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .borderRadius(theme.radius.card)
    .backgroundColor(this.activeVariant(theme).colors.cardColor)
    .border({
      width: this.isSelected(theme) ? 2 : 1,
      color: this.isSelected(theme) ? this.activeVariant(theme).colors.accentColor :
        this.activeVariant(theme).colors.dividerColor
    })
    .onClick(() => {
      this.selectTheme(theme.id);
    })
  }

  hasThemeAccess(themeId: string): boolean {
    return BuiltinThemeRegistry.isFree(themeId) || themeId === this.appThemeId ||
      AccountSessionStore.hasValidEntitlement(themeId);
  }

  additionalBuiltinThemes(): ThemePack[] {
    const themes: ThemePack[] = [];
    for (const theme of BuiltinThemeRegistry.all()) {
      if (theme.id !== ThemeIds.PLAIN_DEFAULT) {
        themes.push(theme);
      }
    }
    return themes;
  }

  themeHasBookCover(theme: ThemePack): boolean {
    return !!theme.book.coverAssetId && this.themeCoverSet(theme).length > 0;
  }

  themeAccessLabel(themeId: string): string {
    if (BuiltinThemeRegistry.isFree(themeId)) {
      return '免费';
    }
    const entitlement: ThemeEntitlement | null = AccountSessionStore.entitlement(themeId);
    if (entitlement && entitlement.expiresAt > Date.now()) {
      return `有效至 ${this.formatDate(entitlement.expiresAt)}`;
    }
    return `${AccountCommerceConfig.THEME_PRICE_POINTS}点 / 1年`;
  }

  formatDate(timestamp: number): string {
    const date = new Date(timestamp);
    const month = `${date.getMonth() + 1}`.padStart(2, '0');
    const day = `${date.getDate()}`.padStart(2, '0');
    return `${date.getFullYear()}-${month}-${day}`;
  }

  @Builder
  themeVisualPreview(theme: ThemePack) {
    Row({ space: 10 }) {
      Stack() {
        if (this.activeVariant(theme).reader.backgroundAssetId) {
          Image(ThemeAssetRegistry.readerBackground(this.activeVariant(theme).reader.backgroundAssetId))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
        }
        Text('阅读')
          .fontSize(13)
          .fontFamily(theme.typography.appFontFamily)
          .fontColor(this.activeVariant(theme).reader.textColor)
      }
      .width(76)
      .height(58)
      .borderRadius(theme.radius.medium)
      .backgroundColor(this.activeVariant(theme).reader.backgroundColor)

      Column({ space: 7 }) {
        Row({ space: 6 }) {
          Blank()
            .height(8)
            .layoutWeight(1)
            .borderRadius(4)
            .backgroundColor(this.activeVariant(theme).colors.primaryTextColor)
          Blank()
            .width(32)
            .height(8)
            .borderRadius(4)
            .backgroundColor(this.activeVariant(theme).colors.subTextColor)
        }
        Text() {
          ContainerSpan() {
            ImageSpan(ThemeAssetRegistry.regexBubbleCap(this.activeVariant(theme).regexEmphasis.bubbleStyle))
              .width(16)
              .height(16)
              .objectFit(ImageFit.Contain)
              .verticalAlign(ImageSpanAlignment.CENTER)
            Span(this.themeRegexPreviewLabel(theme))
              .fontSize(12)
              .fontColor(this.themeRegexPreview(theme).textColor)
              .textShadow(this.themeRegexPreviewShadow(theme))
              .decoration({ type: TextDecorationType.None })
            ImageSpan(ThemeAssetRegistry.regexBubbleCap(this.activeVariant(theme).regexEmphasis.bubbleStyle))
              .width(16)
              .height(16)
              .objectFit(ImageFit.Contain)
              .verticalAlign(ImageSpanAlignment.CENTER)
              .rotate({ angle: 180 })
          }
          .textBackgroundStyle(this.themeRegexPreviewBackground(theme))
        }
        Row({ space: 5 }) {
          ForEach(['bookshelf', 'explore', 'search', 'mine'], (tabId: string) => {
            Image(ThemeAssetRegistry.navigationIcon(theme.navigation.iconPackId, tabId))
              .width(16)
              .height(16)
              .fillColor(this.activeVariant(theme).colors.accentColor)
          }, (tabId: string) => `${theme.id}_${tabId}`)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(10)
    .borderRadius(theme.radius.medium)
    .backgroundColor(this.activeVariant(theme).colors.inputColor)
  }

  themeRegexPreview(theme: ThemePack): ReaderResolvedRegexEmphasis {
    const variant = this.activeVariant(theme);
    const context = new ReaderRegexEmphasisContext();
    context.inheritedMode = variant.regexEmphasis.emphasisMode;
    context.inheritedBubbleStyleId = variant.regexEmphasis.bubbleStyle;
    context.inheritedColor = variant.regexEmphasis.emphasisColor;
    context.inheritedTextColor = variant.regexEmphasis.emphasisTextColor;
    context.accentColor = variant.colors.accentColor;
    context.surfaceColor = variant.reader.backgroundColor;
    context.normalTextColor = variant.reader.textColor;
    context.darkMode = variant.reader.contentTone === 'dark';
    return ReaderRegexBubbleStyleResolver.resolve(null, context);
  }

  themeCoverSet(theme: ThemePack): ResourceStr[] {
    return ThemeAssetRegistry.themeBookCovers(theme.book.coverAssetId);
  }

  themeRegexPreviewLabel(theme: ThemePack): string {
    const styleId = this.activeVariant(theme).regexEmphasis.bubbleStyle;
    if (styleId === 'classic-glass') return '经典玻璃';
    if (styleId === 'warm-scroll') return '暖纸卷轴';
    if (styleId === 'forest-dew') return '林间露珠';
    if (styleId === 'ink-brush') return '水墨笔触';
    if (styleId === 'neon-pulse') return '霓虹脉冲';
    if (styleId === 'strawberry-ribbon') return '草莓软框';
    if (styleId === 'crimson-stamp') return '赤墨印章';
    if (styleId === 'celadon-slip') return '青瓷纸笺';
    if (styleId === 'rose-frame') return '玫瑰信框';
    if (styleId === 'moon-halo') return '月光描边';
    return '强调气泡';
  }

  themeRegexPreviewBackground(theme: ThemePack): TextBackgroundStyle {
    const style = this.themeRegexPreview(theme);
    if (!style.backgroundEnabled) return {};
    return {
      color: style.backgroundColor,
      radius: {
        topLeft: style.radiusTopLeft,
        topRight: style.radiusTopRight,
        bottomLeft: style.radiusBottomLeft,
        bottomRight: style.radiusBottomRight
      }
    };
  }

  themeRegexPreviewShadow(theme: ThemePack): ShadowOptions | ShadowOptions[] {
    const style = this.themeRegexPreview(theme);
    if (style.textShadows.length > 0) return style.textShadows;
    return {
      radius: style.textShadowRadius,
      color: style.textShadowColor,
      offsetX: style.textShadowOffsetX,
      offsetY: style.textShadowOffsetY
    };
  }

  themeRegexPreviewDecoration(theme: ThemePack): DecorationStyleInterface {
    const style = this.themeRegexPreview(theme);
    if (!style.decorationEnabled) return { type: TextDecorationType.None };
    return {
      type: TextDecorationType.Underline,
      color: style.decorationColor,
      style: this.themeRegexDecorationStyle(style.decorationStyleId)
    };
  }

  themeRegexDecorationStyle(styleId: string): TextDecorationStyle {
    if (styleId === 'double') return TextDecorationStyle.DOUBLE;
    if (styleId === 'dotted') return TextDecorationStyle.DOTTED;
    if (styleId === 'dashed') return TextDecorationStyle.DASHED;
    if (styleId === 'wavy') return TextDecorationStyle.WAVY;
    return TextDecorationStyle.SOLID;
  }

}
