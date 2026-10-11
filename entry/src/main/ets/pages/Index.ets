import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { webview } from '@kit.ArkWeb';
import { WebRuntimeAvailability } from '../utils/WebRuntimeAvailability';
import { HdsTabs } from '@kit.UIDesignKit';
import { Book, BookChapter } from '../model/data/Book';
import { AppDatabase } from '../model/data/AppDatabase';
import { BookSourceStageWebRuntime } from '../core/book/BookSourceStageWebRuntime';
import { WebBookFetchRuntimeHost } from '../components/WebBookFetchRuntimeHost';
import { syncSystemSafeAreas } from '../utils/SystemBars';
import { ImmersiveMaterialRuntime } from '../utils/ImmersiveMaterialRuntime';
import { HdsFeedback } from '../utils/HdsFeedback';
import { RecentReadShortcut } from '../utils/RecentReadShortcut';
import { ThemeAssetRegistry } from '../theme/ThemeAssetRegistry';
import { ThemeRuntime } from '../theme/ThemeRuntime';
import { CloudSyncCoordinator } from '../account/CloudSyncCoordinator';
import { ReaderTtsFloatingSession } from '../utils/ReaderTtsFloatingSession';
import { ReaderTtsPlayerPanel } from '../components/ReaderTtsPlayerPanel';
import { TtsCatalogSheet, CatalogTitleDataSource } from '../components/TtsCatalogSheet';
import { BlankTabPage } from '../components/home/HomeTabShells';
import { BookshelfPage } from '../components/home/BookshelfPage';
import { ExplorePage } from '../components/home/ExplorePage';
import { SearchPage } from '../components/home/SearchPage';
import { SettingsPage } from '../components/home/SettingsTabPage';
import { AppFontSize } from '../theme/AppFontSize';
import { AppSpacing } from '../theme/AppSpacing';

@Entry
@Component
struct Index {
  private stageRuntimeController: webview.WebviewController = new webview.WebviewController();
  @State stageRuntimeMounted: boolean = true;
  private stageRuntimeResetScheduled: boolean = false;
  private stageRuntimeDisappearing: boolean = false;
  private stageRuntimeAttachRetryId: number = -1;
  private shortcutRoutingActive: boolean = false;
  private cloudSyncDebounceTimer: number = -1;
  @State currentIndex: number = 0;
  @State hdsMaterialRenderBranch: boolean = false;
  @State bookshelfMultiSelectActive: boolean = false;
  @State bookshelfActiveGroupId: number = 0;
  @StorageLink('themeRevision') @Watch('onThemeRevisionChanged') themeRevision: number = 0;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @StorageLink('appDarkMode') @Watch('onAppDarkModeChanged') appDarkMode: boolean = false;
  @StorageLink('appLightAccentColor') appLightAccentColor: string = '#007DFF';
  @StorageLink('appDarkAccentColor') appDarkAccentColor: string = '#4E9BFF';
  @StorageLink('launchShortcutNonce') @Watch('onLaunchShortcutChanged') launchShortcutNonce: number = 0;
  @StorageLink('singleSourceSearchNonce') @Watch('onSingleSourceSearchRequested') singleSourceSearchNonce: number = 0;
  @StorageLink('globalSearchPendingNonce') @Watch('onGlobalSearchRequested') globalSearchPendingNonce: number = 0;
  @StorageLink('bookSourceExploreRefreshNonce') @Watch('onBookSourceExploreRefreshRequested')
  bookSourceExploreRefreshNonce: number = 0;
  @StorageLink('cloudSyncDataChangeRevision') @Watch('onCloudSyncDataChanged')
  cloudSyncDataRevision: number = 0;
  @StorageLink('cloudSyncPreferenceChangeRevision') @Watch('onCloudSyncDataChanged')
  cloudSyncPreferenceRevision: number = 0;
  @StorageLink('cloudSyncApplicationPreferenceChangeRevision') @Watch('onCloudSyncDataChanged')
  cloudSyncApplicationPreferenceRevision: number = 0;
  @StorageLink('cloudSyncBookSourceChangeRevision') @Watch('onCloudSyncDataChanged')
  cloudSyncBookSourceRevision: number = 0;
  @StorageLink('globalTtsActive') @Watch('onGlobalTtsActiveChanged') globalTtsActive: boolean = false;
  @StorageLink('globalTtsPaused') globalTtsPaused: boolean = false;
  @StorageLink('globalTtsBookName') globalTtsBookName: string = '';
  @StorageLink('globalTtsCover') globalTtsCover: ResourceStr = '';
  @StorageLink('globalTtsChapterTitle') globalTtsChapterTitle: string = '';
  @StorageLink('globalTtsMode') globalTtsMode: string = '';
  @StorageLink('globalTtsChapterProgress') globalTtsChapterProgress: string = '';
  @State showGlobalTtsPanel: boolean = false;
  @State showGlobalTtsCatalog: boolean = false;
  @StorageLink('globalTtsAudioCatalogReverseOrder') @Watch('onGlobalTtsCatalogOrderChanged')
  globalTtsCatalogReverseOrder: boolean = false;
  @State globalTtsViewportWidth: number = 360;
  @State globalTtsViewportHeight: number = 720;
  @StorageLink('globalTtsCapsulePositionX') globalTtsCapsulePositionX: number = 16;
  @StorageLink('globalTtsCapsulePositionY') globalTtsCapsulePositionY: number = -1;
  private globalTtsDragOriginX: number = 0;
  private globalTtsDragOriginY: number = 0;
  private globalTtsCatalogScroller: ListScroller = new ListScroller();
  private globalTtsCatalogSource: CatalogTitleDataSource = new CatalogTitleDataSource();

  aboutToAppear() {
    this.shortcutRoutingActive = true;
    this.stageRuntimeDisappearing = false;
    this.scheduleStageRuntimeAttachFallback(0);
    BookSourceStageWebRuntime.get().setResetHandler((): void => this.resetStageRuntimeHost(),
      this.stageRuntimeController);
    hilog.info(0x0000, 'testTag', 'StartupTrace Index aboutToAppear %{public}d', Date.now());
    this.syncHomeSystemBars();
    this.openPendingShortcut();
  }

  onPageShow(): void {
    this.shortcutRoutingActive = true;
    hilog.info(0x0000, 'testTag', 'StartupTrace Index onPageShow %{public}d', Date.now());
    this.syncHomeSystemBars();
    // ReadBook is pushed over the retained Index route. Its final progress notification can arrive while the
    // bookshelf component is covered, so the storage watcher may already have been consumed before the route is
    // visible again. Publish a strictly monotonic refresh revision on page-show to force the retained shelf to
    // reload the committed Book snapshot without requiring a tab switch.
    if (this.currentIndex === 0) {
      const previousShelfUpdate = AppStorage.get<number>('shelfUpdateTime') || 0;
      AppStorage.setOrCreate('shelfUpdateTime', Math.max(Date.now(), previousShelfUpdate + 1));
    }
  }

  onAppDarkModeChanged(): void {
    this.hdsMaterialRenderBranch = !this.hdsMaterialRenderBranch;
    this.syncHomeSystemBars();
  }

  onLaunchShortcutChanged(): void {
    if (!this.shortcutRoutingActive) {
      return;
    }
    this.openPendingShortcut();
  }

  onPageHide(): void {
    this.shortcutRoutingActive = false;
  }

  aboutToDisappear(): void {
    this.stageRuntimeDisappearing = true;
    if (this.stageRuntimeAttachRetryId >= 0) clearTimeout(this.stageRuntimeAttachRetryId);
    this.stageRuntimeAttachRetryId = -1;
    BookSourceStageWebRuntime.get().clearResetHandler(this.stageRuntimeController);
    BookSourceStageWebRuntime.get().detach(this.stageRuntimeController);
  }

  private adoptStageRuntimeController(): void {
    if (this.stageRuntimeDisappearing) return;
    if (this.stageRuntimeAttachRetryId >= 0) clearTimeout(this.stageRuntimeAttachRetryId);
    this.stageRuntimeAttachRetryId = -1;
    BookSourceStageWebRuntime.get().attach(this.stageRuntimeController);
    BookSourceStageWebRuntime.get().setResetHandler((): void => this.resetStageRuntimeHost(),
      this.stageRuntimeController);
  }

  private scheduleStageRuntimeAttachFallback(attempt: number): void {
    if (this.stageRuntimeDisappearing) return;
    this.stageRuntimeAttachRetryId = setTimeout((): void => {
      if (this.stageRuntimeDisappearing) return;
      try {
        // A successful getWebId proves the controller is associated with a Web component. On
        // some routed/hidden Web nodes ArkWeb omits onControllerAttached — including nodes
        // rebuilt by resetStageRuntimeHost() — so treat this poll as the authoritative attach path.
        this.stageRuntimeController.getWebId();
        this.adoptStageRuntimeController();
        return;
      } catch (_) {}
      if (attempt < 100) this.scheduleStageRuntimeAttachFallback(attempt + 1);
    }, attempt === 0 ? 0 : 100);
  }

  resetStageRuntimeHost(): void {
    if (this.stageRuntimeResetScheduled) return;
    this.stageRuntimeResetScheduled = true;
    if (this.stageRuntimeAttachRetryId >= 0) clearTimeout(this.stageRuntimeAttachRetryId);
    this.stageRuntimeAttachRetryId = -1;
    const previous = this.stageRuntimeController;
    BookSourceStageWebRuntime.get().detach(previous);
    this.stageRuntimeMounted = false;
    // Let ArkUI commit the unmounted branch before constructing the replacement controller.
    setTimeout(() => {
      this.stageRuntimeController = new webview.WebviewController();
      this.stageRuntimeMounted = true;
      this.stageRuntimeResetScheduled = false;
      this.scheduleStageRuntimeAttachFallback(0);
    }, 50);
  }

  onSingleSourceSearchRequested(): void {
    const sourceUrl = AppStorage.get<string>('singleSourceSearchUrl') || '';
    if (!sourceUrl) {
      return;
    }
    this.bookshelfMultiSelectActive = false;
    this.currentIndex = 2;
    this.syncHomeSystemBars();
  }

  onGlobalSearchRequested(): void {
    const keyword = AppStorage.get<string>('globalSearchPendingKeyword') || '';
    if (!keyword.trim()) {
      return;
    }
    this.bookshelfMultiSelectActive = false;
    this.currentIndex = 2;
    this.syncHomeSystemBars();
  }

  onBookSourceExploreRefreshRequested(): void {
    if (this.bookSourceExploreRefreshNonce <= 0) return;
    this.bookshelfMultiSelectActive = false;
    this.currentIndex = 1;
    this.syncHomeSystemBars();
  }

  onThemeRevisionChanged(): void {
    this.hdsMaterialRenderBranch = !this.hdsMaterialRenderBranch;
    this.syncHomeSystemBars();
  }

  onCloudSyncDataChanged(): void {
    if (this.cloudSyncDebounceTimer >= 0) {
      clearTimeout(this.cloudSyncDebounceTimer);
    }
    this.cloudSyncDebounceTimer = setTimeout(() => {
      this.cloudSyncDebounceTimer = -1;
      CloudSyncCoordinator.syncAutomatically(
        getContext(this), CloudSyncCoordinator.TRIGGER_CHANGE).catch((error: Error) => {
        console.warn('数据变更后自动同步失败:', error);
      });
    }, 15 * 1000);
  }

  onGlobalTtsActiveChanged(): void {
    if (!this.globalTtsActive) {
      this.showGlobalTtsPanel = false;
    }
  }

  onBackPress(): boolean {
    if (this.showGlobalTtsCatalog) {
      this.closeGlobalTtsCatalog();
      return true;
    }
    if (this.showGlobalTtsPanel) {
      this.closeGlobalTtsPanel();
      return true;
    }
    if (this.currentIndex !== 0) {
      this.bookshelfMultiSelectActive = false;
      this.currentIndex = 0;
      this.syncHomeSystemBars();
      return true;
    }
    if (this.currentIndex === 0 && this.bookshelfActiveGroupId > 0) {
      this.bookshelfActiveGroupId = 0;
      return true;
    }
    return false;
  }

  openGlobalTtsPanel(): void {
    animateTo({ duration: 280, curve: Curve.Friction }, () => {
      this.showGlobalTtsPanel = true;
    });
  }

  closeGlobalTtsPanel(): void {
    this.showGlobalTtsCatalog = false;
    animateTo({ duration: 190, curve: Curve.EaseIn }, () => {
      this.showGlobalTtsPanel = false;
    });
  }

  openGlobalTtsCatalog(): void {
    const titles = ReaderTtsFloatingSession.catalogTitles();
    if (titles.length === 0) {
      HdsFeedback.showToast('暂未获取到听书目录');
      return;
    }
    this.globalTtsCatalogSource.replace(this.globalTtsCatalogReverseOrder ? titles.slice().reverse() : titles);
    this.openGlobalTtsCatalogWithFreshCacheFlags();
  }

  /**
   * The shelf holds no chapter list of its own, so the cache snapshot is rebuilt
   * from the database before the sheet appears — otherwise the chips would show
   * whatever the publishing page last reported.
   */
  private openGlobalTtsCatalogWithFreshCacheFlags(): void {
    const ownerId = ReaderTtsFloatingSession.currentOwnerId();
    const bookUrl = AppStorage.get<string>('globalTtsBookUrl') || '';
    if (!ownerId || !bookUrl) {
      this.presentGlobalTtsCatalog();
      return;
    }
    AppDatabase.getInstance().getBookChapters(bookUrl)
      .then((chapters: BookChapter[]): void => {
        ReaderTtsFloatingSession.updateCatalogCachedFlags(ownerId, this.chapterCachedFlagsOf(chapters));
        this.presentGlobalTtsCatalog();
      })
      .catch((error: Error) => {
        console.warn('刷新听书目录缓存标记失败:', error);
        this.presentGlobalTtsCatalog();
      });
  }

  private presentGlobalTtsCatalog(): void {
    animateTo({ duration: 280, curve: Curve.Friction }, () => {
      this.showGlobalTtsCatalog = true;
    });
    setTimeout(() => {
      if (!this.showGlobalTtsCatalog) return;
      try {
        this.globalTtsCatalogScroller.scrollToIndex(
          this.globalTtsCatalogDisplayIndex(ReaderTtsFloatingSession.catalogIndex()), false, ScrollAlign.CENTER);
      } catch (_) {}
    }, 0);
  }

  /**
   * Positional, to line up with how every publisher builds the titles array
   * (`chapters.map(title)`) — the rest of the reader treats array position as the
   * canonical chapter index too.
   */
  private chapterCachedFlagsOf(chapters: BookChapter[]): boolean[] {
    const flags: boolean[] = [];
    for (let index = 0; index < chapters.length; index++) {
      flags.push(chapters[index].cacheDate > 0);
    }
    return flags;
  }

  closeGlobalTtsCatalog(): void {
    animateTo({ duration: 210, curve: Curve.EaseIn }, () => {
      this.showGlobalTtsCatalog = false;
    });
  }

  onGlobalTtsCatalogOrderChanged(): void {
    const titles = ReaderTtsFloatingSession.catalogTitles();
    if (titles.length === 0) return;
    this.globalTtsCatalogSource.replace(this.globalTtsCatalogReverseOrder ? titles.slice().reverse() : titles);
    this.scrollGlobalTtsCatalogToCurrent();
  }

  selectGlobalTtsCatalog(index: number): void {
    this.closeGlobalTtsCatalog();
    ReaderTtsFloatingSession.selectCatalogIndex(this.globalTtsCatalogCanonicalIndex(index));
  }

  globalTtsCatalogCanonicalIndex(displayIndex: number): number {
    const count = ReaderTtsFloatingSession.catalogCount();
    return this.globalTtsCatalogReverseOrder ? count - 1 - displayIndex : displayIndex;
  }

  globalTtsCatalogDisplayIndex(canonicalIndex: number): number {
    const count = ReaderTtsFloatingSession.catalogCount();
    return this.globalTtsCatalogReverseOrder ? count - 1 - canonicalIndex : canonicalIndex;
  }

  toggleGlobalTtsCatalogOrder(): void {
    this.globalTtsCatalogReverseOrder = !this.globalTtsCatalogReverseOrder;
  }

  scrollGlobalTtsCatalogToCurrent(): void {
    setTimeout(() => {
      if (!this.showGlobalTtsCatalog) return;
      try {
        this.globalTtsCatalogScroller.scrollToIndex(
          this.globalTtsCatalogDisplayIndex(ReaderTtsFloatingSession.catalogIndex()), false, ScrollAlign.CENTER);
      } catch (_) {}
    }, 0);
  }

  globalTtsCapsuleTransition(): TransitionEffect {
    const appear = TransitionEffect.scale({ x: 0.84, y: 0.84, centerX: '50%', centerY: '50%' })
      .combine(TransitionEffect.opacity(0))
      .animation({ duration: 240, curve: Curve.Friction });
    const disappear = TransitionEffect.scale({ x: 0.9, y: 0.9, centerX: '50%', centerY: '50%' })
      .combine(TransitionEffect.opacity(0))
      .animation({ duration: 170, curve: Curve.EaseIn });
    return TransitionEffect.asymmetric(appear, disappear);
  }

  globalTtsPanelTransition(): TransitionEffect {
    const appear = TransitionEffect.translate({ y: 52 })
      .combine(TransitionEffect.scale({ x: 0.985, y: 0.985, centerX: '50%', centerY: '100%' }))
      .combine(TransitionEffect.opacity(0))
      .animation({ duration: 300, curve: Curve.Friction });
    const disappear = TransitionEffect.translate({ y: 28 })
      .combine(TransitionEffect.scale({ x: 0.99, y: 0.99, centerX: '50%', centerY: '100%' }))
      .combine(TransitionEffect.opacity(0))
      .animation({ duration: 190, curve: Curve.EaseIn });
    return TransitionEffect.asymmetric(appear, disappear);
  }

  async openPendingShortcut(): Promise<void> {
    if (!RecentReadShortcut.isPending()) {
      return;
    }
    try {
      await RecentReadShortcut.openPending(getContext(this));
    } catch (e) {
      console.error('打开最近阅读快捷项失败:', e);
    }
  }

  pageTransition() {
    if (AppStorage.get<boolean>('shelfReaderDirectTransition') === true) {
      PageTransitionExit({ type: RouteType.Push, duration: 0 })
    }
  }

  build() {
    Stack() {
      if (this.supportsImmersiveTabs()) {
        if (this.hdsMaterialRenderBranch) {
          this.immersiveTabs()
        } else {
          this.immersiveTabs()
        }
      } else {
        this.compatTabs()
      }
      if (this.globalTtsActive && !this.showGlobalTtsPanel) {
        this.globalTtsMiniPlayer()
      }
      if (this.globalTtsActive && this.showGlobalTtsPanel) {
        ReaderTtsPlayerPanel({
          darkMode: this.appDarkMode,
          accentColor: this.tabBarActiveColor(),
          primaryTextColor: ThemeRuntime.primaryTextColor(this.appDarkMode),
          subTextColor: ThemeRuntime.subTextColor(this.appDarkMode),
          panelColor: ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'),
          topInset: this.statusBarHeight,
          bottomInset: this.navBarHeight,
          viewportHeight: this.globalTtsViewportHeight,
          onClose: () => this.closeGlobalTtsPanel(),
          onOpenCatalog: () => this.openGlobalTtsCatalog()
        })
      }
      if (this.globalTtsActive && this.showGlobalTtsPanel && this.showGlobalTtsCatalog) {
        this.globalTtsCatalogOverlay()
      }
      if (this.stageRuntimeMounted && WebRuntimeAvailability.isAvailable()) {
        Web({ src: 'about:blank', controller: this.stageRuntimeController })
          .width(1)
          .height(1)
          .opacity(0.01)
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .mixedMode(MixedMode.All)
          .onControllerAttached(() => {
            this.adoptStageRuntimeController();
          })
          .onPageBegin(() => {
            BookSourceStageWebRuntime.get().setReady(false, this.stageRuntimeController);
          })
          .onPageEnd(() => {
            BookSourceStageWebRuntime.get().setReady(true, this.stageRuntimeController);
          })
      }
      WebBookFetchRuntimeHost()
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const width = typeof newValue.width === 'number' ? newValue.width : Number.parseFloat(`${newValue.width}`);
      const height = typeof newValue.height === 'number' ? newValue.height : Number.parseFloat(`${newValue.height}`);
      if (Number.isFinite(width) && width > 0) this.globalTtsViewportWidth = width;
      if (Number.isFinite(height) && height > 0) this.globalTtsViewportHeight = height;
    })
  }

  @Builder
  globalTtsMiniPlayer() {
    Row({ space: AppSpacing.SM }) {
      Row({ space: AppSpacing.SM }) {
        Stack({ alignContent: Alignment.Center }) {
          Circle().width(30).height(30).fill(this.tabBarActiveColor())
          SymbolGlyph($r('sys.symbol.speaker_wave_3'))
            .fontSize(15)
            .fontColor(['#FFFFFF'])
        }
        Column({ space: 1 }) {
          Text(this.globalTtsPaused ? '已暂停' : (this.globalTtsMode === 'audio' ? '听书中' : '朗读中'))
            .fontSize(AppFontSize.CAPTION)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeRuntime.primaryTextColor(this.appDarkMode))
          Text(this.globalTtsChapterProgress || (this.globalTtsMode === 'audio' ? '后台听书' : '后台朗读'))
            .fontSize(9)
            .fontColor(ThemeRuntime.subTextColor(this.appDarkMode))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .onClick(() => this.openGlobalTtsPanel())
      SymbolGlyph(this.globalTtsPaused ? $r('sys.symbol.play') : $r('sys.symbol.pause'))
        .id(`global_tts_capsule_playback_${this.globalTtsPaused}`)
        .fontSize(17)
        .fontColor([ThemeRuntime.primaryTextColor(this.appDarkMode)])
        .width(28)
        .height(34)
        .onClick(() => ReaderTtsFloatingSession.toggle())
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(14)
        .fontColor([ThemeRuntime.subTextColor(this.appDarkMode)])
        .width(24)
        .height(34)
        .onClick(() => {
          this.closeGlobalTtsPanel();
          ReaderTtsFloatingSession.stop();
        })
    }
    .width(184)
    .height(46)
    .padding({ left: AppSpacing.MD, right: AppSpacing.XS })
    .borderRadius(23)
    .clip(true)
    .backgroundColor(ThemeRuntime.cardColor(this.appDarkMode))
    .border({ width: 0.5, color: this.appDarkMode ? '#30FFFFFF' : '#18000000' })
    .shadow({ radius: 18, color: this.appDarkMode ? '#50000000' : '#26000000', offsetY: 6 })
    .position({ x: 0, y: 0 })
    .translate({
      x: this.globalTtsCapsuleLeft(),
      y: this.globalTtsCapsuleTop()
    })
    .parallelGesture(
      PanGesture({ direction: PanDirection.All, distance: 4 })
        .onActionStart(() => {
          this.globalTtsDragOriginX = this.globalTtsCapsuleLeft();
          this.globalTtsDragOriginY = this.globalTtsCapsuleTop();
        })
        .onActionUpdate((event: GestureEvent) => {
          this.globalTtsCapsulePositionX = this.clampGlobalTtsPositionX(
            this.globalTtsDragOriginX + event.offsetX);
          this.globalTtsCapsulePositionY = this.clampGlobalTtsPositionY(
            this.globalTtsDragOriginY + event.offsetY);
        })
    )
    .transition(this.globalTtsCapsuleTransition())
  }

  globalTtsCapsuleLeft(): number {
    return this.clampGlobalTtsPositionX(this.globalTtsCapsulePositionX);
  }

  globalTtsCapsuleTop(): number {
    const defaultTop = this.globalTtsViewportHeight - this.navBarHeight - 118;
    return this.clampGlobalTtsPositionY(this.globalTtsCapsulePositionY < 0 ?
      defaultTop : this.globalTtsCapsulePositionY);
  }

  clampGlobalTtsPositionX(position: number): number {
    const minLeft = 8;
    const maxLeft = Math.max(minLeft, this.globalTtsViewportWidth - 184 - 8);
    return Math.max(minLeft, Math.min(position, maxLeft));
  }

  clampGlobalTtsPositionY(position: number): number {
    const minTop = this.statusBarHeight + 8;
    const maxTop = Math.max(minTop, this.globalTtsViewportHeight - this.navBarHeight - 110);
    return Math.max(minTop, Math.min(position, maxTop));
  }

  @Builder
  globalTtsCatalogOverlay() {
    TtsCatalogSheet({
      darkMode: this.appDarkMode,
      accentColor: this.tabBarActiveColor(),
      primaryTextColor: ThemeRuntime.primaryTextColor(this.appDarkMode),
      subTextColor: ThemeRuntime.subTextColor(this.appDarkMode),
      controlIconColor: ThemeRuntime.primaryTextColor(this.appDarkMode),
      panelColor: ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'),
      bookName: this.globalTtsBookName,
      bookInitial: this.globalTtsCatalogInitial(),
      cover: this.globalTtsCover,
      // The shelf only receives the book name and cover with the TTS session, so the
      // subtitle falls back to the chapter being played instead of the author.
      bookSubtitle: this.globalTtsChapterTitle,
      count: ReaderTtsFloatingSession.catalogCount(),
      currentDisplayIndex: this.globalTtsCatalogDisplayIndex(ReaderTtsFloatingSession.catalogIndex()),
      reverseOrder: this.globalTtsCatalogReverseOrder,
      progressText: `${ReaderTtsFloatingSession.catalogIndex() + 1} / ` +
        `${ReaderTtsFloatingSession.catalogCount()}`,
      bottomInset: this.navBarHeight,
      viewportHeight: this.globalTtsViewportHeight,
      zIndexValue: 80,
      scroller: this.globalTtsCatalogScroller,
      source: this.globalTtsCatalogSource,
      isCached: (displayIndex: number): boolean => this.isGlobalTtsCatalogChapterCached(displayIndex),
      onToggleOrder: () => this.toggleGlobalTtsCatalogOrder(),
      onSelect: (displayIndex: number) => this.selectGlobalTtsCatalog(displayIndex),
      onClose: () => this.closeGlobalTtsCatalog()
    })
  }

  globalTtsCatalogInitial(): string {
    const name = (this.globalTtsBookName || '书').trim();
    return name.length > 0 ? name.substring(0, 1) : '书';
  }

  isGlobalTtsCatalogChapterCached(displayIndex: number): boolean {
    return ReaderTtsFloatingSession.catalogCachedFlag(this.globalTtsCatalogCanonicalIndex(displayIndex));
  }

  supportsImmersiveTabs(): boolean {
    return ImmersiveMaterialRuntime.supportsHdsTabs();
  }

  immersiveTabsBarBackgroundColor(): ResourceColor {
    return this.supportsImmersiveTabs() ? Color.Transparent :
      ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel');
  }

  @Builder
  immersiveTabs() {
    HdsTabs({ barPosition: BarPosition.End, index: this.currentIndex }) {
      TabContent() {
        if (this.currentIndex === 0) {
          BookshelfPage({
            statusBarHeight: this.statusBarHeight,
            navBarHeight: this.navBarHeight,
            isBookMultiSelect: $bookshelfMultiSelectActive,
            activeShelfGroupId: $bookshelfActiveGroupId
          })
        } else {
          BlankTabPage()
        }
      }
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      .tabBar(this.bottomTabBar(this.navigationIcon('bookshelf'), '书架'))

      TabContent() {
        if (this.currentIndex === 1) {
          ExplorePage({
            statusBarHeight: this.statusBarHeight,
            navBarHeight: this.navBarHeight,
            isActive: true
          })
        } else {
          BlankTabPage()
        }
      }
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      .tabBar(this.bottomTabBar(this.navigationIcon('explore'), '发现'))

      TabContent() {
        SearchPage({
          statusBarHeight: this.statusBarHeight,
          navBarHeight: this.navBarHeight,
          isActive: this.currentIndex === 2
        })
      }
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      .tabBar(this.bottomTabBar(this.navigationIcon('search'), '搜索'))

      TabContent() {
        if (this.currentIndex === 3) {
          SettingsPage({ statusBarHeight: this.statusBarHeight, navBarHeight: this.navBarHeight })
        } else {
          BlankTabPage()
        }
      }
      .height('100%')
      .align(Alignment.TopStart)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      .tabBar(this.bottomTabBar(this.navigationIcon('mine'), '我的'))
    }
    .key(`home_immersive_tabs_${this.themeRevision}_${this.appDarkMode ? 'dark' : 'light'}`)
    .barBackgroundColor(this.immersiveTabsBarBackgroundColor())
    .barMode(BarMode.Fixed)
    .barHeight(this.bookshelfMultiSelectActive ? 0 : 56)
    .barOverlap(true)
    .borderRadius(30)
    .clip(true)
    .barFloatingStyle({
      systemMaterialEffect: {
        materialType: ImmersiveMaterialRuntime.materialType(),
        materialLevel: ImmersiveMaterialRuntime.materialLevel()
      },
      barBottomMargin: this.floatingBarBottomMargin(),
      gradientMask: {
        maskColor: '#00000000',
        maskHeight: 96
      },
      adaptToHandedness: true,
      thermoCtrl: true,
      barOpacity: this.bookshelfMultiSelectActive ? 0 : 1
    })
    .scrollable(false)
    .onChange((index: number) => {
      this.currentIndex = index;
      this.syncHomeSystemBars();
    })
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeRuntime.pageColor(this.appDarkMode))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder
  compatTabs() {
    Tabs({ barPosition: BarPosition.End, index: this.currentIndex }) {
      TabContent() {
        if (this.currentIndex === 0) {
          BookshelfPage({
            statusBarHeight: this.statusBarHeight,
            navBarHeight: this.navBarHeight,
            isBookMultiSelect: $bookshelfMultiSelectActive,
            activeShelfGroupId: $bookshelfActiveGroupId
          })
        } else {
          BlankTabPage()
        }
      }
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      .tabBar(this.compatTabBar(this.navigationIcon('bookshelf'), '书架', 0))

      TabContent() {
        if (this.currentIndex === 1) {
          ExplorePage({
            statusBarHeight: this.statusBarHeight,
            navBarHeight: this.navBarHeight,
            isActive: true
          })
        } else {
          BlankTabPage()
        }
      }
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      .tabBar(this.compatTabBar(this.navigationIcon('explore'), '发现', 1))

      TabContent() {
        SearchPage({
          statusBarHeight: this.statusBarHeight,
          navBarHeight: this.navBarHeight,
          isActive: this.currentIndex === 2
        })
      }
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      .tabBar(this.compatTabBar(this.navigationIcon('search'), '搜索', 2))

      TabContent() {
        if (this.currentIndex === 3) {
          SettingsPage({ statusBarHeight: this.statusBarHeight, navBarHeight: this.navBarHeight })
        } else {
          BlankTabPage()
        }
      }
      .height('100%')
      .align(Alignment.TopStart)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      .tabBar(this.compatTabBar(this.navigationIcon('mine'), '我的', 3))
    }
    .barMode(BarMode.Fixed)
    .barHeight(this.bookshelfMultiSelectActive ? 0 : 56 + this.compatTabSafeHeight())
    .barBackgroundColor(ThemeRuntime.cardColor(this.appDarkMode))
    .scrollable(false)
    .onChange((index: number) => {
      this.currentIndex = index;
      this.syncHomeSystemBars();
    })
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeRuntime.pageColor(this.appDarkMode))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  bottomTabBar(icon: Resource, title: string): BottomTabBarStyle {
    return BottomTabBarStyle.of(icon, title)
      .labelStyle({
        font: { size: 11 },
        selectedColor: this.tabBarActiveColor(),
        unselectedColor: this.tabBarTextColor()
      })
      .iconStyle({
        selectedColor: this.tabBarActiveColor(),
        unselectedColor: this.tabBarTextColor()
      })
      .padding({ left: AppSpacing.XS, right: AppSpacing.XS, top: 0, bottom: 0 })
      .layoutMode(LayoutMode.VERTICAL)
      .verticalAlign(VerticalAlign.Center);
  }

  @Builder
  compatTabBar(icon: Resource, title: string, index: number) {
    Column() {
      Column({ space: AppSpacing.XXS }) {
        Column() {
          Image(icon)
            .width(22)
            .height(22)
            .fillColor(this.currentIndex === index ? this.tabBarActiveColor() : this.tabBarTextColor())
        }
        .width(24)
        .height(24)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)

        Text(title)
          .fontSize(AppFontSize.MICRO)
          .lineHeight(14)
          .height(14)
          .fontColor(this.currentIndex === index ? this.tabBarActiveColor() : this.tabBarTextColor())
      }
      .width('100%')
      .height(56)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height(56 + this.compatTabSafeHeight())
    .padding({ bottom: this.compatTabSafeHeight() })
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.Center)
  }

  syncHomeSystemBars(): void {
    window.getLastWindow(getContext(this)).then((mainWindow: window.Window) => {
      const bg = ThemeRuntime.pageColor(this.appDarkMode);
      mainWindow.setWindowBackgroundColor(bg);
      mainWindow.setWindowLayoutFullScreen(true);
      mainWindow.setWindowSystemBarEnable(['navigation', 'status']);
      syncSystemSafeAreas(mainWindow);
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        isStatusBarLightIcon: this.appDarkMode,
        statusBarContentColor: ThemeRuntime.primaryTextColor(this.appDarkMode),
        navigationBarColor: '#00000000',
        isNavigationBarLightIcon: this.appDarkMode,
        navigationBarContentColor: ThemeRuntime.primaryTextColor(this.appDarkMode)
      });
    }).catch((err: Error) => {
      console.error('同步首页系统栏颜色失败:', err);
    });
  }

  tabBarActiveColor(): string {
    return ThemeRuntime.accentColor(this.appDarkMode);
  }

  tabBarTextColor(): string {
    return ThemeRuntime.subTextColor(this.appDarkMode);
  }

  navigationIcon(tabId: string): Resource {
    return ThemeAssetRegistry.navigationIcon(ThemeRuntime.iconPackId(), tabId);
  }

  floatingBarBottomMargin(): number {
    return this.navBarHeight > 0 ? this.navBarHeight : 8;
  }

  compatTabSafeHeight(): number {
    return this.navBarHeight > 0 ? this.navBarHeight : 24;
  }

}
