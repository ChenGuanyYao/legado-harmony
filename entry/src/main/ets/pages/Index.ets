import { router, window } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { common, WantAgent, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { webview } from '@kit.ArkWeb';
import deviceInfo from '@ohos.deviceInfo';
import image from '@ohos.multimedia.image';
import fs from '@ohos.file.fs';
import fileUri from '@ohos.file.fileuri';
import commonEventManager from '@ohos.commonEventManager';
import { HdsTabs, hdsMaterial } from '@kit.UIDesignKit';
import { Book, BookChapter, BookGroup, BookSource, SearchBook } from '../model/data/Book';
import { AppDatabase } from '../model/data/AppDatabase';
import { SearchCoordinator, SearchCallback, SearchProgress } from '../core/book/SearchCoordinator';
import { ExploreCoordinator, ExploreEntry, ExploreSourceOption } from '../core/book/ExploreCoordinator';
import { BookSourceStageWebRuntime } from '../core/book/BookSourceStageWebRuntime';
import { ReadBookEngine } from '../core/book/ReadBookEngine';
import { SearchBookResultList } from '../components/book/SearchBookResultList';
import { ImmersiveBackButton } from '../components/ImmersiveBackButton';
import { syncSystemSafeAreas } from '../utils/SystemBars';
import { RecentReadShortcut } from '../utils/RecentReadShortcut';
import { BookDisplayHelper } from '../utils/BookDisplayHelper';
import { BookCoverCache } from '../utils/BookCoverCache';
import { CoverGallerySettings } from '../utils/CoverGallerySettings';
import { BookshelfDisplaySettingsStore } from '../utils/BookshelfDisplaySettingsStore';
import { BookshelfStateStore } from '../utils/BookshelfStateStore';
import { SearchBookShelfHelper } from '../utils/SearchBookShelfHelper';
import { SearchExplorePendingBook } from '../utils/SearchExplorePendingBook';
import { BookshelfSortHelper } from '../utils/BookshelfSortHelper';
import { SearchExploreSettings, SearchExploreSettingsStore } from '../utils/SearchExploreSettingsStore';
import { ExploreCacheHit, ExploreResultCache } from '../utils/ExploreResultCache';
import { AppThemeSettingsStore } from '../utils/AppThemeSettingsStore';
import { ThemeAssetRegistry } from '../theme/ThemeAssetRegistry';
import { ThemeRuntime } from '../theme/ThemeRuntime';
import { LocalBookService } from '../core/book/LocalBookService';
import { CloudSyncSettingsStore } from '../account/CloudSyncSettingsStore';
import { CloudSyncCoordinator } from '../account/CloudSyncCoordinator';
import { ReaderTtsFloatingSession } from '../utils/ReaderTtsFloatingSession';
import { BookTypeSupport } from '../core/book/BookTypeSupport';
import { WebBookService } from '../core/book/WebBookService';
import { ChangeSourceResultCache } from '../utils/ChangeSourceResultCache';
import { BookFieldSanitizer } from '../utils/BookFieldSanitizer';
import { CoverUrlNormalizer } from '../utils/CoverUrlNormalizer';

const SHELF_FULL_TEXT_CACHE_CANCEL_EVENT: string = 'com.legado.harmony.action.SHELF_FULL_TEXT_CACHE_CANCEL';
const SHELF_FULL_TEXT_CACHE_NOTIFICATION_INTERVAL_MS: number = 5000;
const SHELF_COVER_INITIAL_PREFETCH_COUNT: number = 16;
const SHELF_COVER_UPDATE_BATCH_MS: number = 48;

interface FullTextCacheCancelSignal {
  nonce: number;
  taskKey: string;
  bookUrl: string;
}

interface ShelfFullTextCacheTask {
  taskId: number;
  bookUrl: string;
  bookName: string;
  taskKey: string;
  createdAt: number;
  cancelRequested: boolean;
  cancelSeenNonce: number;
  notificationLastAt: number;
  cancelAgent: WantAgent | null;
  done: number;
  total: number;
  status: string;
  coverPixelMap: image.PixelMap | null;
  notificationFailureHintShown: boolean;
}

class ShelfTileSortEntry {
  kind: string = 'book';
  key: string = '';
  book: Book | null = null;
  group: BookGroup | null = null;
  readTime: number = 0;
  addTime: number = 0;
  name: string = '';
  originalOrder: number = 0;
}

class ShelfBookDataSource implements IDataSource {
  private books: Book[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number { return this.books.length; }
  getData(index: number): Book { return this.books[index]; }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) this.listeners.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) this.listeners.splice(index, 1);
  }

  replace(books: Book[], force: boolean = false): void {
    if (!force && this.books.length === books.length &&
      this.books.every((book: Book, index: number) => book === books[index])) {
      return;
    }
    this.books = [...books];
    for (const listener of this.listeners) listener.onDataReloaded();
  }
}

class FloatingCatalogDataSource implements IDataSource {
  private titles: string[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number { return this.titles.length; }
  getData(index: number): string { return this.titles[index]; }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) this.listeners.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) this.listeners.splice(index, 1);
  }

  replace(titles: string[]): void {
    this.titles = titles.slice();
    for (const listener of this.listeners) listener.onDataReloaded();
  }
}

class ShelfTileEntryDataSource implements IDataSource {
  private entries: ShelfTileSortEntry[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number { return this.entries.length; }
  getData(index: number): ShelfTileSortEntry { return this.entries[index]; }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) this.listeners.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) this.listeners.splice(index, 1);
  }

  replace(entries: ShelfTileSortEntry[], force: boolean = false): void {
    if (!force && this.entries.length === entries.length &&
      this.entries.every((entry: ShelfTileSortEntry, index: number) => entry.key === entries[index].key &&
        entry.book === entries[index].book && entry.group === entries[index].group)) {
      return;
    }
    this.entries = [...entries];
    for (const listener of this.listeners) listener.onDataReloaded();
  }
}

@Entry
@Component
struct Index {
  private stageRuntimeController: webview.WebviewController = new webview.WebviewController();
  @State stageRuntimeMounted: boolean = true;
  private stageRuntimeResetScheduled: boolean = false;
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
  @StorageLink('globalTtsChapterTitle') globalTtsChapterTitle: string = '';
  @StorageLink('globalTtsMode') globalTtsMode: string = '';
  @StorageLink('globalTtsVoiceCode') globalTtsVoiceCode: string = '';
  @StorageLink('globalTtsCover') globalTtsCover: ResourceStr = '';
  @StorageLink('globalTtsCoverFrame') globalTtsCoverFrame: ResourceStr = '';
  @StorageLink('globalTtsContent') globalTtsContent: string = '';
  @StorageLink('globalTtsTextBefore') globalTtsTextBefore: string = '';
  @StorageLink('globalTtsCurrentText') globalTtsCurrentText: string = '';
  @StorageLink('globalTtsTextAfter') globalTtsTextAfter: string = '';
  @StorageLink('globalTtsChapterProgress') globalTtsChapterProgress: string = '';
  @StorageLink('globalTtsSpeed') globalTtsSpeed: number = 1;
  @StorageLink('globalTtsTimerMinutes') globalTtsTimerMinutes: number = 0;
  @StorageLink('globalTtsTimerRemainingSeconds') globalTtsTimerRemainingSeconds: number = 0;
  @StorageLink('globalTtsCanPrevious') globalTtsCanPrevious: boolean = false;
  @StorageLink('globalTtsCanNext') globalTtsCanNext: boolean = false;
  @StorageLink('globalTtsRevision') @Watch('onGlobalTtsRevisionChanged') globalTtsRevision: number = 0;
  @State showGlobalTtsPanel: boolean = false;
  @State showGlobalTtsCatalog: boolean = false;
  @State globalTtsOptionsPanel: number = 0;
  @State globalTtsViewportWidth: number = 360;
  @State globalTtsViewportHeight: number = 720;
  @StorageLink('globalTtsCapsulePositionX') globalTtsCapsulePositionX: number = 16;
  @StorageLink('globalTtsCapsulePositionY') globalTtsCapsulePositionY: number = -1;
  private globalTtsDragOriginX: number = 0;
  private globalTtsDragOriginY: number = 0;
  private globalTtsTextScroller: ListScroller = new ListScroller();
  private globalTtsCatalogScroller: ListScroller = new ListScroller();
  private globalTtsCatalogSource: FloatingCatalogDataSource = new FloatingCatalogDataSource();

  aboutToAppear() {
    this.shortcutRoutingActive = true;
    BookSourceStageWebRuntime.get().setResetHandler((): void => this.resetStageRuntimeHost());
    hilog.info(0x0000, 'testTag', 'StartupTrace Index aboutToAppear %{public}d', Date.now());
    this.syncHomeSystemBars();
    this.openPendingShortcut();
  }

  onPageShow(): void {
    this.shortcutRoutingActive = true;
    hilog.info(0x0000, 'testTag', 'StartupTrace Index onPageShow %{public}d', Date.now());
    this.syncHomeSystemBars();
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
    BookSourceStageWebRuntime.get().setResetHandler(null);
    BookSourceStageWebRuntime.get().detach(this.stageRuntimeController);
  }

  resetStageRuntimeHost(): void {
    if (this.stageRuntimeResetScheduled) return;
    this.stageRuntimeResetScheduled = true;
    const previous = this.stageRuntimeController;
    BookSourceStageWebRuntime.get().detach(previous);
    this.stageRuntimeMounted = false;
    setTimeout(() => {
      this.stageRuntimeController = new webview.WebviewController();
      this.stageRuntimeMounted = true;
      this.stageRuntimeResetScheduled = false;
    }, 0);
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
      this.globalTtsOptionsPanel = 0;
    }
  }

  onGlobalTtsRevisionChanged(): void {
    if (this.globalTtsMode !== 'audio') this.scrollGlobalTtsTextToCurrent();
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
    this.globalTtsOptionsPanel = 0;
    animateTo({ duration: 280, curve: Curve.Friction }, () => {
      this.showGlobalTtsPanel = true;
    });
    this.scrollGlobalTtsTextToCurrent(false);
  }

  scrollGlobalTtsTextToCurrent(smooth: boolean = true): void {
    setTimeout(() => {
      if (!this.showGlobalTtsPanel) return;
      try {
        this.globalTtsTextScroller.scrollToIndex(1, smooth, ScrollAlign.CENTER);
      } catch (_) {}
    }, 0);
  }

  closeGlobalTtsPanel(): void {
    this.globalTtsOptionsPanel = 0;
    this.showGlobalTtsCatalog = false;
    animateTo({ duration: 190, curve: Curve.EaseIn }, () => {
      this.showGlobalTtsPanel = false;
    });
  }

  openGlobalTtsCatalog(): void {
    const titles = ReaderTtsFloatingSession.catalogTitles();
    if (titles.length === 0) {
      promptAction.showToast({ message: '暂未获取到听书目录' });
      return;
    }
    this.globalTtsCatalogSource.replace(titles);
    animateTo({ duration: 280, curve: Curve.Friction }, () => {
      this.showGlobalTtsCatalog = true;
    });
    setTimeout(() => {
      if (!this.showGlobalTtsCatalog) return;
      try {
        this.globalTtsCatalogScroller.scrollToIndex(
          ReaderTtsFloatingSession.catalogIndex(), false, ScrollAlign.CENTER);
      } catch (_) {}
    }, 0);
  }

  closeGlobalTtsCatalog(): void {
    animateTo({ duration: 210, curve: Curve.EaseIn }, () => {
      this.showGlobalTtsCatalog = false;
    });
  }

  selectGlobalTtsCatalog(index: number): void {
    this.closeGlobalTtsCatalog();
    ReaderTtsFloatingSession.selectCatalogIndex(index);
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
        this.globalTtsPlayerOverlay()
      }
      if (this.globalTtsActive && this.showGlobalTtsPanel && this.showGlobalTtsCatalog) {
        this.globalTtsCatalogOverlay()
      }
      if (this.stageRuntimeMounted) {
        Web({ src: 'about:blank', controller: this.stageRuntimeController })
          .width(1)
          .height(1)
          .opacity(0.01)
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .mixedMode(MixedMode.All)
          .onControllerAttached(() => {
            BookSourceStageWebRuntime.get().attach(this.stageRuntimeController);
          })
          .onPageBegin(() => {
            BookSourceStageWebRuntime.get().setReady(false, this.stageRuntimeController);
          })
          .onPageEnd(() => {
            BookSourceStageWebRuntime.get().setReady(true, this.stageRuntimeController);
          })
      }
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
    Row({ space: 7 }) {
      Row({ space: 7 }) {
        Stack({ alignContent: Alignment.Center }) {
          Circle().width(30).height(30).fill(this.tabBarActiveColor())
          SymbolGlyph($r('sys.symbol.speaker_wave_3'))
            .fontSize(15)
            .fontColor(['#FFFFFF'])
        }
        Column({ space: 1 }) {
          Text(this.globalTtsPaused ? '已暂停' : (this.globalTtsMode === 'audio' ? '听书中' : '朗读中'))
            .fontSize(12)
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
    .padding({ left: 8, right: 5 })
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
  globalTtsPlayerOverlay() {
    Column({ space: 14 }) {
      Row({ space: 11 }) {
        Stack({ alignContent: Alignment.Center }) {
          Circle().width(38).height(38).fill(ThemeRuntime.accentSurfaceColor(this.appDarkMode))
          SymbolGlyph($r('sys.symbol.speaker_wave_3'))
            .fontSize(19)
            .fontColor([this.tabBarActiveColor()])
        }
        Column({ space: 3 }) {
          Text(this.globalTtsBookName || '快速朗读')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(ThemeRuntime.primaryTextColor(this.appDarkMode))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.globalTtsChapterTitle || this.globalTtsChapterProgress)
            .fontSize(11)
            .fontColor(ThemeRuntime.subTextColor(this.appDarkMode))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(20)
          .fontColor([ThemeRuntime.primaryTextColor(this.appDarkMode)])
          .width(38)
          .height(38)
          .onClick(() => this.closeGlobalTtsPanel())
      }
      .width('100%')

      Column({ space: 8 }) {
        this.globalTtsPanelCover()
        if (this.globalTtsMode === 'audio') {
          Scroll() {
            Text(this.globalTtsContent || '暂无书籍简介')
              .fontSize(15)
              .lineHeight(25)
              .fontColor(ThemeRuntime.primaryTextColor(this.appDarkMode))
              .width('100%')
          }
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 4, right: 4 })
          .scrollBar(BarState.Auto)
        } else {
          List({ scroller: this.globalTtsTextScroller, space: 8 }) {
            ListItem() {
              Text(this.globalTtsTextBefore)
                .fontSize(15)
                .lineHeight(25)
                .fontColor(ThemeRuntime.subTextColor(this.appDarkMode))
                .width('100%')
            }
            ListItem() {
              Text(this.globalTtsCurrentText || '正在准备当前朗读内容…')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .lineHeight(26)
                .fontColor(ThemeRuntime.primaryTextColor(this.appDarkMode))
                .width('100%')
                .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                .borderRadius(8)
                .backgroundColor(this.appDarkMode ? '#24FFFFFF' : '#12000000')
            }
            ListItem() {
              Text(this.globalTtsTextAfter)
                .fontSize(15)
                .lineHeight(25)
                .fontColor(ThemeRuntime.subTextColor(this.appDarkMode))
                .width('100%')
            }
          }
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 4, right: 4 })
          .scrollBar(BarState.Auto)
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding(14)
      .borderRadius(14)
      .backgroundColor(ThemeRuntime.accentSurfaceColor(this.appDarkMode))

      Row() {
        this.globalTtsControl($r('sys.symbol.timer'), this.globalTtsTimerMinutes > 0 ?
          `${Math.max(1, Math.ceil(this.globalTtsTimerRemainingSeconds / 60))}分` : '定时', true,
          () => this.globalTtsOptionsPanel = this.globalTtsOptionsPanel === 1 ? 0 : 1)
        this.globalTtsControl($r('sys.symbol.arrow_left'), '上一章', this.globalTtsCanPrevious,
          () => ReaderTtsFloatingSession.previous())
        this.globalTtsPlaybackControl()
        this.globalTtsControl($r('sys.symbol.arrow_right'), '下一章', this.globalTtsCanNext,
          () => ReaderTtsFloatingSession.next())
        this.globalTtsControl($r('sys.symbol.hourglass'), `${this.globalTtsSpeed.toFixed(1)}x`, true,
          () => this.globalTtsOptionsPanel = this.globalTtsOptionsPanel === 2 ? 0 : 2)
      }
      .width('100%')

      if (this.globalTtsOptionsPanel === 1) {
        Row({ space: 6 }) {
          this.globalTtsTimerChip(0, '关闭')
          this.globalTtsTimerChip(15, '15分')
          this.globalTtsTimerChip(30, '30分')
          this.globalTtsTimerChip(60, '60分')
          this.globalTtsTimerChip(90, '90分')
          this.globalTtsTimerChip(120, '120分')
        }
        .width('100%')
      } else if (this.globalTtsOptionsPanel === 2) {
        Row({ space: 8 }) {
          this.globalTtsSpeedChip(0.8)
          this.globalTtsSpeedChip(1.0)
          this.globalTtsSpeedChip(1.2)
          this.globalTtsSpeedChip(1.5)
          this.globalTtsSpeedChip(2.0)
        }
        .width('100%')
      }

      if (this.globalTtsMode === 'audio') {
        Row({ space: 10 }) {
          Button(`音色 · ${this.globalTtsVoiceCode || '4'}`)
            .layoutWeight(1)
            .height(40)
            .backgroundColor(ThemeRuntime.inputColor(this.appDarkMode))
            .fontColor(ThemeRuntime.primaryTextColor(this.appDarkMode))
            .onClick(() => ReaderTtsFloatingSession.openVoice())
          Button('目录跳转')
            .layoutWeight(1)
            .height(40)
            .backgroundColor(ThemeRuntime.inputColor(this.appDarkMode))
            .fontColor(ThemeRuntime.primaryTextColor(this.appDarkMode))
            .onClick(() => this.openGlobalTtsCatalog())
        }
        .width('100%')
      }

      Button(this.globalTtsMode === 'audio' ? '停止听书' : '停止朗读')
        .width('100%')
        .height(42)
        .borderRadius(12)
        .fontColor('#FFFFFF')
        .backgroundColor('#D94841')
        .onClick(() => {
          this.closeGlobalTtsPanel();
          ReaderTtsFloatingSession.stop();
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 18, right: 18, top: this.statusBarHeight + 16, bottom: this.navBarHeight + 16 })
    .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
    .backdropBlur(ThemeRuntime.glassBlur('panel', 24))
    .transition(this.globalTtsPanelTransition())
  }

  @Builder
  globalTtsCatalogOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#78000000')
        .onClick(() => this.closeGlobalTtsCatalog())
      Column({ space: 10 }) {
        Row() {
          Text('听书目录')
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor(ThemeRuntime.primaryTextColor(this.appDarkMode))
          Blank()
          Text(`${ReaderTtsFloatingSession.catalogIndex() + 1} / ` +
            `${ReaderTtsFloatingSession.catalogTitles().length}`)
            .fontSize(12)
            .fontColor(ThemeRuntime.subTextColor(this.appDarkMode))
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(17)
            .fontColor([ThemeRuntime.primaryTextColor(this.appDarkMode)])
            .width(40)
            .height(40)
            .margin({ left: 6 })
            .onClick(() => this.closeGlobalTtsCatalog())
        }
        .width('100%')
        List({ scroller: this.globalTtsCatalogScroller, space: 4 }) {
          LazyForEach(this.globalTtsCatalogSource, (title: string, index: number) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(`${index + 1}`)
                  .fontSize(11)
                  .fontColor(index === ReaderTtsFloatingSession.catalogIndex() ? '#FFFFFF' :
                    ThemeRuntime.subTextColor(this.appDarkMode))
                  .textAlign(TextAlign.Center)
                  .width(34)
                  .height(26)
                  .borderRadius(13)
                  .backgroundColor(index === ReaderTtsFloatingSession.catalogIndex() ?
                    this.tabBarActiveColor() : ThemeRuntime.inputColor(this.appDarkMode))
                Text(title || `第${index + 1}章`)
                  .fontSize(15)
                  .fontWeight(index === ReaderTtsFloatingSession.catalogIndex() ?
                    FontWeight.Bold : FontWeight.Regular)
                  .fontColor(index === ReaderTtsFloatingSession.catalogIndex() ?
                    this.tabBarActiveColor() : ThemeRuntime.primaryTextColor(this.appDarkMode))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')
              .constraintSize({ minHeight: 50 })
              .padding({ left: 8, right: 8, top: 7, bottom: 7 })
              .borderRadius(10)
              .backgroundColor(index === ReaderTtsFloatingSession.catalogIndex() ?
                ThemeRuntime.accentSurfaceColor(this.appDarkMode) : Color.Transparent)
              .onClick(() => this.selectGlobalTtsCatalog(index))
            }
          }, (title: string, index: number) => `${index}_${title}`)
        }
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
      }
      .width('100%')
      .height('72%')
      .padding({ left: 16, right: 16, top: 12, bottom: this.navBarHeight + 12 })
      .borderRadius({ topLeft: 22, topRight: 22 })
      .backgroundColor(ThemeRuntime.cardColor(this.appDarkMode))
      .transition(TransitionEffect.translate({ y: 520 })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 280, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
    .zIndex(80)
  }

  @Builder
  globalTtsPlaybackControl() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(46)
          .height(46)
          .fill(this.tabBarActiveColor())
        SymbolGlyph(this.globalTtsPaused ? $r('sys.symbol.play') : $r('sys.symbol.pause'))
          .id(`global_tts_panel_playback_${this.globalTtsPaused}`)
          .fontSize(23)
          .fontColor(['#FFFFFF'])
      }
      Text(this.globalTtsPaused ? '播放' : '暂停')
        .fontSize(10)
        .fontColor(ThemeRuntime.subTextColor(this.appDarkMode))
    }
    .layoutWeight(1)
    .height(68)
    .justifyContent(FlexAlign.Center)
    .onClick(() => ReaderTtsFloatingSession.toggle())
  }

  @Builder
  globalTtsPanelCover() {
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
      } else {
        Column() {
          Text(this.globalTtsBookName ? this.globalTtsBookName.substring(0, 1) : '书')
            .fontSize(42)
            .fontColor('#FFFFFF')
        }
        .width('58%')
        .height('88%')
        .constraintSize({ maxWidth: 260, maxHeight: 360 })
        .borderRadius(10)
        .backgroundColor(this.tabBarActiveColor())
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height(Math.min(250, Math.max(130,
      (this.globalTtsViewportHeight - this.statusBarHeight - this.navBarHeight) * 0.32)))
    .padding(10)
    .borderRadius(14)
    .clip(true)
  }

  @Builder
  globalTtsControl(icon: Resource, label: string, enabled: boolean, action: () => void,
    primary: boolean = false) {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(primary ? 46 : 38)
          .height(primary ? 46 : 38)
          .fill(primary ? this.tabBarActiveColor() : (this.appDarkMode ? '#24FFFFFF' : '#10000000'))
        SymbolGlyph(icon)
          .fontSize(primary ? 23 : 19)
          .fontColor([enabled ? (primary ? '#FFFFFF' : ThemeRuntime.primaryTextColor(this.appDarkMode)) :
            ThemeRuntime.subTextColor(this.appDarkMode)])
      }
      Text(label)
        .fontSize(10)
        .fontColor(ThemeRuntime.subTextColor(this.appDarkMode))
    }
    .layoutWeight(1)
    .height(68)
    .justifyContent(FlexAlign.Center)
    .opacity(enabled ? 1 : 0.45)
    .onClick(() => { if (enabled) action(); })
  }

  @Builder
  globalTtsSpeedChip(value: number) {
    Text(`${value.toFixed(1)}x`)
      .fontSize(11)
      .fontWeight(Math.abs(this.globalTtsSpeed - value) < 0.01 ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(Math.abs(this.globalTtsSpeed - value) < 0.01 ? '#FFFFFF' :
        ThemeRuntime.primaryTextColor(this.appDarkMode))
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(30)
      .borderRadius(15)
      .backgroundColor(Math.abs(this.globalTtsSpeed - value) < 0.01 ? this.tabBarActiveColor() :
        (this.appDarkMode ? '#20FFFFFF' : '#0D000000'))
      .onClick(() => ReaderTtsFloatingSession.setSpeed(value))
  }

  @Builder
  globalTtsTimerChip(minutes: number, label: string) {
    Text(label)
      .fontSize(11)
      .fontWeight(this.globalTtsTimerMinutes === minutes ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.globalTtsTimerMinutes === minutes ? '#FFFFFF' :
        ThemeRuntime.primaryTextColor(this.appDarkMode))
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(30)
      .borderRadius(15)
      .backgroundColor(this.globalTtsTimerMinutes === minutes ? this.tabBarActiveColor() :
        (this.appDarkMode ? '#20FFFFFF' : '#0D000000'))
      .onClick(() => ReaderTtsFloatingSession.setTimer(minutes))
  }

  supportsImmersiveTabs(): boolean {
    return deviceInfo.sdkApiVersion >= 23;
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
    .barBackgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
    .barMode(BarMode.Fixed)
    .barHeight(this.bookshelfMultiSelectActive ? 0 : 56)
    .barOverlap(true)
    .barFloatingStyle({
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
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
      .padding({ left: 4, right: 4, top: 0, bottom: 0 })
      .layoutMode(LayoutMode.VERTICAL)
      .verticalAlign(VerticalAlign.Center);
  }

  @Builder
  compatTabBar(icon: Resource, title: string, index: number) {
    Column() {
      Column({ space: 2 }) {
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
          .fontSize(11)
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

@Component
struct FastBookshelfShell {
  @Prop statusBarHeight: number = 0;
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;

  build() {
    Column() {
      Row() {
        Text('书架')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
          .layoutWeight(1)
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      Column({ space: 10 }) {
        this.placeholderCard(0.92)
        this.placeholderCard(0.78)
        this.placeholderCard(0.86)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  placeholderCard(widthRatio: number) {
    Row() {
      Column()
        .width(56)
        .height(72)
        .borderRadius(6)
        .backgroundColor(this.appDarkMode ? '#24272D' : '#E6E9EE')

      Column({ space: 8 }) {
        Column()
          .width(`${Math.floor(widthRatio * 100)}%`)
          .height(16)
          .borderRadius(8)
          .backgroundColor(this.appDarkMode ? '#24272D' : '#E2E5EA')
        Column()
          .width('48%')
          .height(12)
          .borderRadius(6)
          .backgroundColor(this.appDarkMode ? '#202329' : '#ECEEF2')
        Column()
          .width('34%')
          .height(12)
          .borderRadius(6)
          .backgroundColor(this.appDarkMode ? '#202329' : '#ECEEF2')
      }
      .layoutWeight(1)
      .margin({ left: 12 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(12)
    .borderRadius(8)
    .backgroundColor(this.appDarkMode ? '#191B1F' : '#FFFFFF')
  }

  pageColor(): string {
    return ThemeRuntime.pageColor(this.appDarkMode);
  }

  primaryTextColor(): string {
    return ThemeRuntime.primaryTextColor(this.appDarkMode);
  }
}

@Component
struct BlankTabPage {
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;

  build() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor(ThemeRuntime.pageColor(this.appDarkMode))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}

@Component
struct BookshelfPage {
  @Prop statusBarHeight: number = 0;
  @Prop navBarHeight: number = 0;
  @Link isBookMultiSelect: boolean;
  @Link @Watch('onActiveShelfGroupChanged') activeShelfGroupId: number;
  @StorageLink('appThemeBookCoverEnabled') themeBookCoverEnabled: boolean = false;
  @StorageLink('appThemeId') appThemeId: string = AppThemeSettingsStore.DEFAULT_THEME_ID;
  @StorageLink('appCustomBaseThemeId') appCustomBaseThemeId: string = AppThemeSettingsStore.DEFAULT_THEME_ID;
  @State books: Book[] = [];
  @State allBooks: Book[] = [];
  private shelfListBooksSource: ShelfBookDataSource = new ShelfBookDataSource();
  private shelfTileBooksSource: ShelfBookDataSource = new ShelfBookDataSource();
  private shelfTileEntriesSource: ShelfTileEntryDataSource = new ShelfTileEntryDataSource();
  private shelfTileEntriesCacheKey: string = '';
  private shelfTileEntriesCache: ShelfTileSortEntry[] = [];
  @State shelfScope: string = 'all';
  @State showShelfScopeOptions: boolean = false;
  @State showShelfSortMenu: boolean = false;
  @State showShelfLayoutMenu: boolean = false;
  @State showShelfGroups: boolean = false;
  @State shelfGroups: BookGroup[] = [];
  @State shelfScopeTransitionX: number = 0;
  @State shelfScopeTransitionScale: number = 1;
  @State shelfScopeTransitionOpacity: number = 1;
  @State tileGroupTransitionX: number = 0;
  @State tileGroupTransitionScale: number = 1;
  @State tileGroupTransitionOpacity: number = 1;
  @State openingBook: Book | null = null;
  @State openingBookScale: number = 0.28;
  @State openingBookTranslateX: number = 0;
  @State openingBookTranslateY: number = 0;
  @State openingBookOpacity: number = 0;
  @State openingBookBackdropOpacity: number = 0;
  @State openingBookCoverAngle: number = 0;
  @State selectedBookUrls: string[] = [];
  @State showBookGroupPicker: boolean = false;
  @State groupPickerSingleBookUrl: string = '';
  @State showAddBookGroupDialog: boolean = false;
  @State newBookGroupName: string = '';
  @State showBookGroupActionMenu: boolean = false;
  @State showRenameBookGroupDialog: boolean = false;
  @State renameBookGroupName: string = '';
  @State pendingBookGroup: BookGroup | null = null;
  @State showDeleteBookGroupDialog: boolean = false;
  @State pendingDeleteBookGroup: BookGroup | null = null;
  @State showBatchDeleteDialog: boolean = false;
  @State isLoading: boolean = false;
  @State showDeleteDialog: boolean = false;
  @State showActionDialog: boolean = false;
  @State showEditBookInfoDialog: boolean = false;
  @State editingBookName: string = '';
  @State editingBookAuthor: string = '';
  @State showTagDialog: boolean = false;
  @State showCacheDialog: boolean = false;
  @State showChapterCacheDialog: boolean = false;
  @State showNetworkCoverDialog: boolean = false;
  @State networkCoverTargetBook: Book | null = null;
  @State networkCoverCandidates: SearchBook[] = [];
  @State networkCoverSearching: boolean = false;
  @State networkCoverStatus: string = '';
  @State pendingDeleteBook: Book | null = null;
  @State pendingActionBook: Book | null = null;
  @State showShelfChangeSourceDialog: boolean = false;
  @State shelfChangeSourceTarget: Book | null = null;
  @State shelfChangeSourceResults: SearchBook[] = [];
  @State shelfChangeSourceStatus: string = '';
  @State shelfChangeSourceSearching: boolean = false;
  @State shelfChangeSourceSwitching: boolean = false;
  @State contextMenuX: number = 16;
  @State contextMenuY: number = 96;
  @State contextViewportWidth: number = 360;
  @State contextViewportHeight: number = 720;
  @State shelfTileViewportWidth: number = 360;
  @State cacheTargetBook: Book | null = null;
  @State cacheChapters: BookChapter[] = [];
  @State cacheStatus: string = '';
  @State isCaching: boolean = false;
  @State activeFullTextCacheBookUrls: string[] = [];
  @State isCacheTocLoading: boolean = false;
  @State isShelfRefreshing: boolean = false;
  @State shelfRefreshPrompt: string = '下拉刷新书架';
  @State editingTags: string[] = [];
  @State tagInput: string = '';
  @State shelfCoverMap: Map<string, string> = new Map();
  @State shelfCoverRenderVersions: Map<string, number> = new Map();
  private shelfCoverRawUrls: Map<string, string> = new Map();
  private shelfCoverCacheRevision: number = 0;
  private shelfCoverBookTasks: Set<string> = new Set();
  private pendingShelfCoverUpdates: Map<string, string> = new Map();
  private shelfCoverUpdateTimer: number = -1;
  @StorageLink('shelfUpdateTime') @Watch('onShelfChanged') shelfUpdateTime: number = 0;
  @StorageLink('bookshelfSortMode') sortMode: string = 'recentRead';
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;
  @StorageLink('bookshelfShowTags') bookshelfShowTags: boolean = true;
  @StorageLink('bookshelfShowSource') bookshelfShowSource: boolean = true;
  @StorageLink('bookshelfShowIntro') bookshelfShowIntro: boolean = true;
  @StorageLink('bookshelfShowFullIntro') bookshelfShowFullIntro: boolean = false;
  @StorageLink('bookshelfShowProgressBar') bookshelfShowProgressBar: boolean = false;
  @StorageLink('bookshelfShowLastReadTime') bookshelfShowLastReadTime: boolean = true;
  @StorageLink('bookshelfShowLastReadChapter') bookshelfShowLastReadChapter: boolean = false;
  @StorageLink('bookshelfShowTypeBadge') bookshelfShowTypeBadge: boolean = true;
  @StorageLink('bookshelfLayoutMode') bookshelfLayoutMode: string = 'compact';
  @StorageLink('bookshelfLastReadLeafMode') bookshelfLastReadLeafMode: string = 'adaptive';
  @StorageLink('bookshelfCoverAlbums') @Watch('onShelfCoverSettingsChanged') bookshelfCoverAlbums: string = '';
  @StorageLink('bookshelfLightCoverAlbumId') @Watch('onShelfCoverSettingsChanged') bookshelfLightCoverAlbumId: string = '';
  @StorageLink('bookshelfDarkCoverAlbumId') @Watch('onShelfCoverSettingsChanged') bookshelfDarkCoverAlbumId: string = '';
  @StorageLink('bookshelfCoverApplyScope') @Watch('onShelfCoverSettingsChanged') bookshelfCoverApplyScope: string = 'all';
  @StorageLink('bookshelfCoverTargetBooks') @Watch('onShelfCoverSettingsChanged') bookshelfCoverTargetBooks: string = '';
  @StorageLink('bookshelfIgnoreSourceCover') @Watch('onShelfCoverSettingsChanged') bookshelfIgnoreSourceCover: boolean = false;
  @StorageLink('bookshelfCoverMode') @Watch('onShelfCoverSettingsChanged') bookshelfCoverMode: string = 'sequence';
  @StorageLink('appLightAccentColor') appLightAccentColor: string = '#007DFF';
  @StorageLink('appDarkAccentColor') appDarkAccentColor: string = '#4E9BFF';
  @StorageLink('appLightButtonColor') appLightButtonColor: string = '#007DFF';
  @StorageLink('appDarkButtonColor') appDarkButtonColor: string = '#3F8CFF';
  @StorageLink('fullTextCacheCancelNonce') @Watch('onFullTextCacheCancelNonceChanged') fullTextCacheCancelNonce: number = 0;
  @StorageLink('fullTextCacheCancelSignal') @Watch('onFullTextCacheCancelSignalChanged') fullTextCacheCancelSignal: string = '';
  @StorageLink('shelfBookCloseAnimationNonce') @Watch('onShelfBookCloseAnimationRequested')
  shelfBookCloseAnimationNonce: number = 0;
  @StorageLink('shelfBookCloseAnimationUrl') shelfBookCloseAnimationUrl: string = '';
  private loadTimer: number = -1;
  private cacheTocLoadToken: number = 0;
  private cacheTocLoadBookUrl: string = '';
  private cacheTocLoadPromise: Promise<boolean> | null = null;
  private cacheDialogOpenedAt: number = 0;
  private fullTextCacheTasks: Map<string, ShelfFullTextCacheTask> = new Map();
  private fullTextCacheCancelSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private activeCacheBookUrl: string = '';
  private shelfRefreshRunning: boolean = false;
  private shelfChangeSourceSessionId: number = 0;
  private activeShelfChangeSourceCoordinator: SearchCoordinator | null = null;
  private fullTextCacheTaskId: number = 0;
  private fullTextCacheCancelRequested: boolean = false;
  private fullTextCacheCancelSeenNonce: number = 0;
  private fullTextCacheNotificationLastAt: number = 0;
  private fullTextCacheBackgroundRunning: boolean = false;
  private fullTextCacheCancelAgent: WantAgent | null = null;
  private fullTextCacheDone: number = 0;
  private fullTextCacheTotal: number = 0;
  private fullTextCacheStatus: string = '';
  private fullTextCacheBookName: string = '';
  private fullTextCacheNotificationSlotReady: boolean = false;
  private fullTextCacheNotificationFailureHintShown: boolean = false;
  private openingBookGrowTimer: number = -1;
  private openingBookTurnTimer: number = -1;
  private openingBookRouteTimer: number = -1;
  private shelfScopeSwapTimer: number = -1;
  private shelfScopeFinishTimer: number = -1;
  private shelfScopeSwitchAnimating: boolean = false;
  private suppressShelfBookClickUntil: number = 0;
  private pendingShelfSortTimer: number = -1;
  private pendingShelfSortMode: string = '';
  private openingBookOriginX: number = 0;
  private openingBookOriginY: number = 0;
  private networkCoverCoordinator: SearchCoordinator | null = null;
  private networkCoverSearchToken: number = 0;
  private activeShelfGroupRestored: boolean = false;
  private localBookIntroMigrationQueue: Book[] = [];
  private localBookIntroMigrationRunning: boolean = false;
  private localBookIntroMigrationGeneration: number = 0;
  private shelfComponentActive: boolean = false;

  aboutToAppear() {
    this.shelfComponentActive = true;
    this.reloadDisplaySettings();
    this.scheduleLoadBooks();
    this.ensureShelfFullTextCacheCancelSubscriber();
  }

  aboutToDisappear(): void {
    this.shelfComponentActive = false;
    this.releaseShelfFullTextCacheCancelSubscriber();
    this.cancelShelfBookOpening();
    this.cancelNetworkCoverSearch();
    this.cancelShelfChangeSourceSearch();
    this.clearShelfScopeTransition();
    this.shelfCoverCacheRevision++;
    this.localBookIntroMigrationGeneration++;
    this.localBookIntroMigrationQueue = [];
    this.shelfCoverBookTasks.clear();
    this.pendingShelfCoverUpdates.clear();
    if (this.shelfCoverUpdateTimer >= 0) {
      clearTimeout(this.shelfCoverUpdateTimer);
      this.shelfCoverUpdateTimer = -1;
    }
    if (this.pendingShelfSortTimer >= 0) {
      clearTimeout(this.pendingShelfSortTimer);
      this.pendingShelfSortTimer = -1;
    }
    this.pendingShelfSortMode = '';
  }

  onActiveShelfGroupChanged(): void {
    this.applyShelfScope();
    if (this.activeShelfGroupRestored) {
      BookshelfStateStore.saveActiveGroupId(getContext(this), this.activeShelfGroupId).catch((e: Error) => {
        console.warn('保存书架分组状态失败:', e);
      });
    }
    if (!this.isTileLayout()) {
      return;
    }
    this.tileGroupTransitionX = this.activeShelfGroupId > 0 ? 34 : -34;
    this.tileGroupTransitionScale = 0.965;
    this.tileGroupTransitionOpacity = 0.2;
    animateTo({ duration: 300, curve: Curve.Friction }, () => {
      this.tileGroupTransitionX = 0;
      this.tileGroupTransitionScale = 1;
      this.tileGroupTransitionOpacity = 1;
    });
  }

  onShelfBookCloseAnimationRequested(): void {
    if (!this.shelfBookCloseAnimationUrl) {
      return;
    }
    this.closeShelfBook(this.shelfBookCloseAnimationUrl);
  }

  async reloadDisplaySettings(): Promise<void> {
    try {
      const settings = await BookshelfDisplaySettingsStore.load(getContext(this));
      this.bookshelfShowTags = settings.showTags;
      this.bookshelfShowSource = settings.showSource;
      this.bookshelfShowIntro = settings.showIntro;
      this.bookshelfShowFullIntro = settings.showFullIntro;
      this.bookshelfShowProgressBar = settings.showProgressBar;
      this.bookshelfShowLastReadTime = settings.showLastReadTime;
      this.bookshelfShowLastReadChapter = settings.showLastReadChapter;
      this.bookshelfShowTypeBadge = settings.showTypeBadge;
      this.bookshelfLayoutMode = settings.layoutMode;
      this.bookshelfLastReadLeafMode = settings.lastReadLeafMode;
    } catch (e) {
      console.warn('恢复书架显示设置失败:', e);
    }
  }

  onShelfChanged(): void {
    this.scheduleLoadBooks();
  }

  onShelfCoverSettingsChanged(): void {
    this.shelfCoverMap = new Map();
    this.shelfCoverRawUrls.clear();
    this.refreshShelfCoverCache(this.books);
  }

  async loadBooks() {
    this.isLoading = true;
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      const loadedBooks = SearchExplorePendingBook.filterShelfBooks(await db.getAllBooks());
      this.allBooks = loadedBooks;
      this.shelfGroups = await db.getCustomBookGroups();
      if (!this.activeShelfGroupRestored) {
        try {
          this.activeShelfGroupId = await BookshelfStateStore.loadActiveGroupId(getContext(this));
        } catch (e) {
          console.warn('恢复书架分组状态失败:', e);
        }
        this.activeShelfGroupRestored = true;
      }
      if (this.activeShelfGroupId > 0 && !this.shelfGroups.some((group: BookGroup) => group.groupId === this.activeShelfGroupId)) {
        this.activeShelfGroupId = 0;
      }
      this.applyShelfScope();
      this.refreshShelfCoverCache(this.books);
      this.scheduleLocalBookIntroMigration(loadedBooks);
    } catch (e) {
      console.error('加载书籍失败:', e);
    } finally {
      this.isLoading = false;
    }
  }

  scheduleLoadBooks(): void {
    if (this.loadTimer >= 0) {
      clearTimeout(this.loadTimer);
    }
    this.loadTimer = setTimeout(() => {
      this.loadTimer = -1;
      this.loadBooks();
    }, 80);
  }

  async deleteBook(book: Book) {
    try {
      const db = AppDatabase.getInstance();
      this.deleteBookCoverCache(book);
      LocalBookService.deleteLocalBookFiles(getContext(this), book);
      await db.deleteBook(book.bookUrl);
      promptAction.showToast({ message: `已删除《${book.name}》` });
      AppStorage.setOrCreate('shelfUpdateTime', Date.now());
      await this.loadBooks();
    } catch (e) {
      console.error('删除书籍失败:', e);
      promptAction.showToast({ message: '删除失败' });
    }
  }

  showDeleteConfirm(book: Book) {
    this.pendingDeleteBook = book;
    this.showDeleteDialog = true;
  }

  showBookActions(book: Book, event?: GestureEvent): void {
    this.captureContextMenuAnchor(event);
    this.pendingActionBook = book;
    this.showActionDialog = true;
  }

  scheduleLocalBookIntroMigration(books: Book[]): void {
    this.localBookIntroMigrationQueue = books.filter((book: Book) =>
      LocalBookService.isLocalBook(book) &&
      (book.getVariable('localContentIntroVersion') !== '6' || !book.intro.trim()));
    if (!this.shelfComponentActive || this.localBookIntroMigrationQueue.length === 0 ||
      this.localBookIntroMigrationRunning) return;
    const generation = ++this.localBookIntroMigrationGeneration;
    this.localBookIntroMigrationRunning = true;
    setTimeout(() => this.runLocalBookIntroMigration(generation), 120);
  }

  async runLocalBookIntroMigration(generation: number): Promise<void> {
    try {
      while (generation === this.localBookIntroMigrationGeneration &&
        this.localBookIntroMigrationQueue.length > 0) {
        const book = this.localBookIntroMigrationQueue.shift();
        if (!book) break;
        try {
          const changed = await LocalBookService.ensureContentIntro(book);
          if (changed && generation === this.localBookIntroMigrationGeneration) {
            this.allBooks = this.allBooks.map((item: Book) => item.bookUrl === book.bookUrl ? book : item);
            this.applyShelfScope();
          }
        } catch (e) {
          console.warn('后台生成本地书籍简介失败:', book.name, e);
        }
        // Keep migrations behind user input and list animation work.
        await new Promise<void>((resolve) => setTimeout(resolve, 16));
      }
    } finally {
      this.localBookIntroMigrationRunning = false;
      if (this.shelfComponentActive && this.localBookIntroMigrationQueue.length > 0) {
        this.scheduleLocalBookIntroMigration(this.localBookIntroMigrationQueue);
      }
    }
  }

  closeBookActions(): void {
    this.showActionDialog = false;
    this.pendingActionBook = null;
  }

  openShelfBookDetail(book: Book): void {
    router.pushUrl({
      url: 'pages/SearchBookDetail',
      params: {
        bookUrl: book.bookUrl,
        tocUrl: book.tocUrl,
        origin: book.origin,
        originName: book.originName,
        name: book.name,
        author: book.author,
        kind: book.kind,
        coverUrl: book.customCoverUrl || book.coverUrl,
        intro: book.customIntro || book.intro,
        latestChapterTitle: book.latestChapterTitle,
        wordCount: book.wordCount,
        type: `${book.type}`,
        variable: book.variable,
        promptAddToShelfOnBack: 'false'
      }
    });
  }

  async openShelfChangeSource(book: Book): Promise<void> {
    if (!book.name.trim() || LocalBookService.isLocalBook(book)) {
      promptAction.showToast({ message: '当前书籍不支持换源' });
      return;
    }
    this.cancelShelfChangeSourceSearch();
    const sessionId = ++this.shelfChangeSourceSessionId;
    this.shelfChangeSourceTarget = book;
    this.shelfChangeSourceResults = [];
    this.shelfChangeSourceStatus = '正在读取历史换源结果...';
    this.shelfChangeSourceSearching = true;
    this.shelfChangeSourceSwitching = false;
    this.showShelfChangeSourceDialog = true;
    try {
      const cached = await ChangeSourceResultCache.load(getContext(this), book.name);
      if (!this.isShelfChangeSourceSessionActive(sessionId)) return;
      this.shelfChangeSourceResults = this.filterShelfChangeSourceResults(cached, book.bookUrl, book.origin);
      if (this.shelfChangeSourceResults.length > 0) {
        this.shelfChangeSourceSearching = false;
        this.shelfChangeSourceStatus = `已显示历史结果，共 ${this.shelfChangeSourceResults.length} 个；点击刷新可重新搜索`;
        return;
      }
    } catch (e) {
      console.warn('读取书架换源历史失败:', e);
    }
    if (this.isShelfChangeSourceSessionActive(sessionId)) {
      this.searchShelfChangeSource(sessionId);
    }
  }

  refreshShelfChangeSource(): void {
    if (!this.shelfChangeSourceTarget || this.shelfChangeSourceSwitching) return;
    this.cancelShelfChangeSourceSearch();
    const sessionId = ++this.shelfChangeSourceSessionId;
    this.shelfChangeSourceSearching = true;
    this.shelfChangeSourceStatus = '正在刷新可用书源...';
    this.searchShelfChangeSource(sessionId);
  }

  closeShelfChangeSource(): void {
    this.shelfChangeSourceSessionId++;
    this.cancelShelfChangeSourceSearch();
    this.showShelfChangeSourceDialog = false;
    this.shelfChangeSourceTarget = null;
    this.shelfChangeSourceResults = [];
    this.shelfChangeSourceStatus = '';
    this.shelfChangeSourceSearching = false;
    this.shelfChangeSourceSwitching = false;
  }

  async searchShelfChangeSource(sessionId: number): Promise<void> {
    const target = this.shelfChangeSourceTarget;
    if (!target) return;
    const cacheBookName = target.name;
    const coordinator = new SearchCoordinator(SearchExploreSettingsStore.getSearchConcurrency());
    this.activeShelfChangeSourceCoordinator = coordinator;
    this.shelfChangeSourceSearching = true;
    this.shelfChangeSourceStatus = '正在搜索可用书源...';
    try {
      const results = await coordinator.search(target.name, (progress: SearchProgress) => {
        if (!this.isShelfChangeSourceSessionActive(sessionId)) return;
        if (progress.finished) {
          this.shelfChangeSourceResults = this.filterShelfChangeSourceResults(
            progress.results, target.bookUrl, target.origin);
        } else if (progress.deltaResults && progress.deltaResults.length > 0) {
          this.shelfChangeSourceResults = this.filterShelfChangeSourceResults(
            this.shelfChangeSourceResults.concat(progress.deltaResults), target.bookUrl, target.origin);
        }
        this.shelfChangeSourceStatus = progress.status;
        if (progress.finished) this.shelfChangeSourceSearching = false;
      }, { exactMatch: true });
      if (!this.isShelfChangeSourceSessionActive(sessionId)) return;
      this.shelfChangeSourceResults = this.filterShelfChangeSourceResults(results, target.bookUrl, target.origin);
      this.shelfChangeSourceStatus = this.shelfChangeSourceResults.length > 0 ?
        `搜索完成，找到 ${this.shelfChangeSourceResults.length} 个可切换书源` : '搜索完成，未找到可切换书源';
      try {
        await ChangeSourceResultCache.save(getContext(this), cacheBookName, results);
      } catch (e) {
        console.warn('保存书架换源结果失败:', e);
      }
    } catch (e) {
      if (!this.isShelfChangeSourceSessionActive(sessionId)) return;
      console.error('书架搜索换源失败:', e);
      this.shelfChangeSourceStatus = '搜索换源失败';
    } finally {
      if (this.activeShelfChangeSourceCoordinator === coordinator) {
        this.activeShelfChangeSourceCoordinator = null;
      }
      if (this.isShelfChangeSourceSessionActive(sessionId)) {
        this.shelfChangeSourceSearching = false;
      }
    }
  }

  isShelfChangeSourceSessionActive(sessionId: number): boolean {
    return this.showShelfChangeSourceDialog && sessionId === this.shelfChangeSourceSessionId;
  }

  cancelShelfChangeSourceSearch(): void {
    if (this.activeShelfChangeSourceCoordinator) {
      this.activeShelfChangeSourceCoordinator.cancel();
      this.activeShelfChangeSourceCoordinator = null;
    }
  }

  filterShelfChangeSourceResults(results: SearchBook[], currentBookUrl: string, currentOrigin: string): SearchBook[] {
    const filtered: SearchBook[] = [];
    for (const result of results) {
      if (!result.bookUrl || (result.bookUrl === currentBookUrl && result.origin === currentOrigin)) continue;
      if (!filtered.some((item: SearchBook) => item.bookUrl === result.bookUrl && item.origin === result.origin)) {
        filtered.push(result);
      }
    }
    return filtered;
  }

  async switchShelfBookSource(searchBook: SearchBook): Promise<void> {
    const target = this.shelfChangeSourceTarget;
    if (!target || this.shelfChangeSourceSwitching) return;
    this.cancelShelfChangeSourceSearch();
    this.shelfChangeSourceSearching = false;
    const sessionId = ++this.shelfChangeSourceSessionId;
    this.shelfChangeSourceSwitching = true;
    this.shelfChangeSourceStatus = '正在切换书源...';
    const oldBookUrl = target.bookUrl;
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      const oldBook = await db.getBook(oldBookUrl) || target;
      const source = searchBook.origin ? await db.getBookSource(searchBook.origin) : null;
      if (!source) {
        promptAction.showToast({ message: '书源不存在或已删除' });
        return;
      }
      if (!this.isShelfChangeSourceSessionActive(sessionId)) return;

      const nextBook = this.buildShelfSourceBook(searchBook, oldBook);
      const service = new WebBookService();
      const fullBook = await service.getBookInfo(source, nextBook);
      if (!this.isShelfChangeSourceSessionActive(sessionId)) return;
      this.preserveShelfSourceBookState(fullBook, nextBook, oldBook);
      const chapters = await service.getChapterList(source, fullBook);
      if (!this.isShelfChangeSourceSessionActive(sessionId)) return;
      fullBook.totalChapterNum = chapters.length;
      if (chapters.length > 0) {
        const safeIndex = Math.max(0, Math.min(oldBook.durChapterIndex, chapters.length - 1));
        fullBook.durChapterIndex = safeIndex;
        fullBook.durChapterTitle = chapters[safeIndex].title;
        fullBook.latestChapterTitle = chapters[chapters.length - 1].title;
      }

      if (oldBookUrl !== fullBook.bookUrl) {
        const existing = await db.getBook(fullBook.bookUrl);
        if (existing) await db.deleteBook(existing.bookUrl);
        await db.moveBookBookmarks(oldBookUrl, fullBook.bookUrl, fullBook.name, fullBook.author);
        await db.deleteBook(oldBookUrl);
        await db.insertBook(fullBook);
      } else {
        await db.updateBook(fullBook);
        await db.deleteBookChapters(fullBook.bookUrl);
        await db.deleteBookCachedContent(fullBook.bookUrl);
      }
      if (chapters.length > 0) await db.insertBookChapters(chapters);

      this.closeShelfChangeSource();
      AppStorage.setOrCreate('shelfUpdateTime', Date.now());
      await this.loadBooks();
      promptAction.showToast({ message: `已切换至 ${fullBook.originName || searchBook.originName}` });
    } catch (e) {
      if (!this.isShelfChangeSourceSessionActive(sessionId)) return;
      console.error('书架切换书源失败:', e);
      promptAction.showToast({ message: '切换书源失败' });
    } finally {
      if (sessionId === this.shelfChangeSourceSessionId) {
        this.shelfChangeSourceSwitching = false;
      }
    }
  }

  buildShelfSourceBook(searchBook: SearchBook, oldBook: Book): Book {
    const book = new Book();
    book.bookUrl = searchBook.bookUrl;
    book.tocUrl = searchBook.tocUrl;
    book.origin = searchBook.origin;
    book.originName = searchBook.originName;
    book.name = searchBook.name || oldBook.name;
    book.author = searchBook.author || oldBook.author;
    book.kind = BookFieldSanitizer.prefer(searchBook.kind, oldBook.kind);
    book.coverUrl = CoverUrlNormalizer.prefer(searchBook.coverUrl, oldBook.coverUrl);
    book.customCoverUrl = oldBook.customCoverUrl;
    book.intro = BookFieldSanitizer.prefer(searchBook.intro, oldBook.intro);
    book.customIntro = oldBook.customIntro;
    book.latestChapterTitle = BookFieldSanitizer.prefer(searchBook.latestChapterTitle, oldBook.latestChapterTitle);
    book.wordCount = BookFieldSanitizer.prefer(searchBook.wordCount, oldBook.wordCount);
    book.variable = searchBook.variable || '';
    book.group = oldBook.group;
    book.order = oldBook.order;
    book.originOrder = oldBook.originOrder;
    book.readConfig = oldBook.readConfig;
    book.canUpdate = oldBook.canUpdate;
    book.type = oldBook.type;
    book.durChapterIndex = oldBook.durChapterIndex;
    book.durChapterPos = oldBook.durChapterPos;
    book.durChapterTitle = oldBook.durChapterTitle;
    book.durChapterTime = oldBook.durChapterTime;
    return book;
  }

  preserveShelfSourceBookState(target: Book, source: Book, oldBook: Book): void {
    target.origin = source.origin;
    target.originName = source.originName;
    target.coverUrl = CoverUrlNormalizer.prefer(source.coverUrl, target.coverUrl);
    target.group = oldBook.group;
    target.order = oldBook.order;
    target.originOrder = oldBook.originOrder;
    target.customCoverUrl = oldBook.customCoverUrl;
    target.customIntro = oldBook.customIntro;
    target.readConfig = oldBook.readConfig;
    target.canUpdate = oldBook.canUpdate;
    target.durChapterIndex = oldBook.durChapterIndex;
    target.durChapterPos = oldBook.durChapterPos;
    target.durChapterTitle = oldBook.durChapterTitle;
    target.durChapterTime = oldBook.durChapterTime;
    target.syncTime = oldBook.syncTime;
  }

  @Builder
  shelfChangeSourceDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')
        .onClick(() => {
          if (!this.shelfChangeSourceSwitching) this.closeShelfChangeSource();
        })

      Column() {
        Row() {
          Column({ space: 3 }) {
            Text('换源')
              .fontSize(19)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
            Text(`《${this.shelfChangeSourceTarget?.name || ''}》`)
              .fontSize(12)
              .fontColor(this.subTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          if (this.shelfChangeSourceSearching) {
            LoadingProgress()
              .width(26)
              .height(26)
              .margin({ right: 14 })
          } else {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(21)
              .fontColor([this.primaryTextColor()])
              .width(40)
              .height(40)
              .margin({ right: 4 })
              .onClick(() => this.refreshShelfChangeSource())
          }
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(20)
            .fontColor([this.primaryTextColor()])
            .width(40)
            .height(40)
            .onClick(() => {
              if (!this.shelfChangeSourceSwitching) this.closeShelfChangeSource();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(this.shelfChangeSourceStatus || '将使用当前书名进行全词匹配搜索')
          .fontSize(13)
          .fontColor(this.subTextColor())
          .width('100%')
          .margin({ top: 8, bottom: 10 })

        if (this.shelfChangeSourceSearching && this.shelfChangeSourceResults.length === 0) {
          Column({ space: 10 }) {
            LoadingProgress().width(36).height(36)
            Text('正在搜索可用书源...')
              .fontSize(13)
              .fontColor(this.subTextColor())
          }
          .width('100%')
          .height(260)
          .justifyContent(FlexAlign.Center)
        } else if (this.shelfChangeSourceResults.length === 0) {
          Text('暂无可切换书源')
            .fontSize(15)
            .fontColor(this.subTextColor())
            .width('100%')
            .height(260)
            .textAlign(TextAlign.Center)
        } else {
          List({ space: 8 }) {
            ForEach(this.shelfChangeSourceResults, (book: SearchBook) => {
              ListItem() {
                Row() {
                  Column({ space: 4 }) {
                    Text(book.originName || book.origin)
                      .fontSize(15)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(this.primaryTextColor())
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`${book.author || '作者未知'} ${book.latestChapterTitle || ''}`)
                      .fontSize(12)
                      .fontColor(this.subTextColor())
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  Button(this.shelfChangeSourceSwitching ? '切换中' : '切换')
                    .width(68)
                    .height(32)
                    .fontSize(13)
                    .borderRadius(16)
                    .backgroundColor(this.buttonColor())
                    .fontColor('#FFFFFF')
                    .enabled(!this.shelfChangeSourceSwitching)
                    .onClick(() => this.switchShelfBookSource(book))
                }
                .width('100%')
                .padding(12)
                .backgroundColor(this.inputColor())
                .borderRadius(10)
              }
            }, (book: SearchBook) => `${book.origin}|${book.bookUrl}`)

            if (this.shelfChangeSourceSearching) {
              ListItem() {
                Row({ space: 8 }) {
                  LoadingProgress().width(20).height(20)
                  Text('继续加载中...').fontSize(13).fontColor(this.subTextColor())
                }
                .width('100%')
                .height(42)
                .justifyContent(FlexAlign.Center)
              }
            }
          }
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .width('100%')
          .height(340)
        }
      }
      .width('90%')
      .padding(20)
      .borderRadius(ThemeRuntime.glassCornerRadius(14, 'panel'))
      .clip(true)
      .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
      .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
      .border({ width: ThemeRuntime.glassBorderWidth('panel'),
        color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'panel') })
    }
    .width('100%')
    .height('100%')
  }

  async openNetworkCoverPicker(book: Book): Promise<void> {
    const keyword = (book.name || '').trim();
    if (!keyword) {
      promptAction.showToast({ message: '书名为空，无法搜索封面' });
      return;
    }
    this.cancelNetworkCoverSearch();
    this.networkCoverTargetBook = book;
    this.networkCoverCandidates = [];
    this.networkCoverSearching = true;
    this.networkCoverStatus = '正在从启用的书源中搜索...';
    this.showNetworkCoverDialog = true;
    const token = this.networkCoverSearchToken;
    const coordinator = new SearchCoordinator(SearchExploreSettingsStore.getSearchConcurrency());
    this.networkCoverCoordinator = coordinator;
    try {
      await AppDatabase.getInstance().initWithContext(getContext(this));
      const results = await coordinator.search(keyword, (progress: SearchProgress) => {
        if (token !== this.networkCoverSearchToken || this.networkCoverCoordinator !== coordinator) return;
        const incoming = progress.finished ? progress.results : (progress.deltaResults || []);
        if (incoming.length > 0) {
          this.appendNetworkCoverCandidates(incoming);
        }
        this.networkCoverStatus = progress.finished ?
          `搜索完成，找到 ${this.networkCoverCandidates.length} 个可选封面` :
          `${progress.status}，可选封面 ${this.networkCoverCandidates.length} 个`;
        if (progress.finished) this.networkCoverSearching = false;
      }, {
        exactMatch: true,
        exactMatchAuthor: false
      });
      if (token !== this.networkCoverSearchToken || this.networkCoverCoordinator !== coordinator) return;
      this.appendNetworkCoverCandidates(results);
      this.networkCoverSearching = false;
      this.networkCoverStatus = this.networkCoverCandidates.length > 0 ?
        `搜索完成，找到 ${this.networkCoverCandidates.length} 个可选封面` : '搜索完成，未找到带封面的书籍';
    } catch (e) {
      if (token !== this.networkCoverSearchToken) return;
      console.error('搜索网络封面失败:', e);
      this.networkCoverSearching = false;
      this.networkCoverStatus = '搜索网络封面失败，请稍后重试';
    } finally {
      if (token === this.networkCoverSearchToken && this.networkCoverCoordinator === coordinator) {
        this.networkCoverCoordinator = null;
      }
    }
  }

  appendNetworkCoverCandidates(results: SearchBook[]): void {
    const merged = this.networkCoverCandidates.slice();
    const coverUrls = new Set<string>(merged.map((item: SearchBook) => item.coverUrl));
    for (const result of results) {
      const coverUrl = (result.coverUrl || '').trim();
      if (!/^https?:\/\//i.test(coverUrl) || coverUrls.has(coverUrl)) continue;
      result.coverUrl = coverUrl;
      merged.push(result);
      coverUrls.add(coverUrl);
      if (merged.length >= 90) break;
    }
    this.networkCoverCandidates = merged;
  }

  async applyNetworkCover(candidate: SearchBook): Promise<void> {
    const target = this.networkCoverTargetBook;
    const coverUrl = (candidate.coverUrl || '').trim();
    if (!target || !coverUrl) return;
    try {
      const db = AppDatabase.getInstance();
      const current = await db.getBook(target.bookUrl);
      if (!current) {
        promptAction.showToast({ message: '书籍已不在书架中' });
        this.closeNetworkCoverPicker();
        return;
      }
      current.customCoverUrl = coverUrl;
      await db.updateBook(current);
      this.applyShelfBookCoverState(current);
      this.closeNetworkCoverPicker();
      AppStorage.setOrCreate('shelfUpdateTime', Date.now());
      promptAction.showToast({ message: '网络封面已启用' });
    } catch (e) {
      console.error('应用网络封面失败:', e);
      promptAction.showToast({ message: '应用网络封面失败' });
    }
  }

  async restoreDefaultBookCover(book: Book): Promise<void> {
    if (!book.customCoverUrl) return;
    try {
      const db = AppDatabase.getInstance();
      const current = await db.getBook(book.bookUrl);
      if (!current) {
        promptAction.showToast({ message: '书籍已不在书架中' });
        return;
      }
      current.customCoverUrl = '';
      await db.updateBook(current);
      this.applyShelfBookCoverState(current);
      AppStorage.setOrCreate('shelfUpdateTime', Date.now());
      promptAction.showToast({ message: '已恢复默认封面' });
    } catch (e) {
      console.error('恢复默认封面失败:', e);
      promptAction.showToast({ message: '恢复默认封面失败' });
    }
  }

  applyShelfBookCoverState(current: Book): void {
    this.allBooks = this.allBooks.map((book: Book) => book.bookUrl === current.bookUrl ? current : book);
    this.applyShelfScope();
    this.bumpShelfBookCoverRenderVersion(current.bookUrl);
    this.shelfCoverMap = new Map();
    this.shelfCoverRawUrls.clear();
    this.refreshShelfCoverCache(this.books);
  }

  bumpShelfBookCoverRenderVersion(bookUrl: string): void {
    const versions = new Map<string, number>(this.shelfCoverRenderVersions);
    versions.set(bookUrl, (versions.get(bookUrl) || 0) + 1);
    this.shelfCoverRenderVersions = versions;
  }

  shelfBookRenderKey(book: Book, prefix: string): string {
    return `${prefix}_${book.bookUrl}_cover_${this.shelfCoverRenderVersions.get(book.bookUrl) || 0}`;
  }

  closeNetworkCoverPicker(): void {
    this.cancelNetworkCoverSearch();
    this.showNetworkCoverDialog = false;
    this.networkCoverTargetBook = null;
    this.networkCoverCandidates = [];
    this.networkCoverStatus = '';
    this.networkCoverSearching = false;
  }

  cancelNetworkCoverSearch(): void {
    this.networkCoverSearchToken++;
    this.networkCoverCoordinator?.cancel();
    this.networkCoverCoordinator = null;
    this.networkCoverSearching = false;
  }

  networkCoverColumnCount(): number {
    const horizontalPadding = 32;
    const targetCardWidth = 108;
    const preferredColumnGap = 8;
    const contentWidth = Math.max(1, this.contextViewportWidth - horizontalPadding);
    const fittedCount = Math.round(
      (contentWidth + preferredColumnGap) / (targetCardWidth + preferredColumnGap)
    );
    return Math.max(3, Math.min(24, fittedCount));
  }

  networkCoverColumnsTemplate(): string {
    const columnCount = this.networkCoverColumnCount();
    let template = '1fr';
    for (let index = 1; index < columnCount; index++) {
      template += ' 1fr';
    }
    return template;
  }

  networkCoverColumnGap(): number {
    const horizontalPadding = 32;
    const targetCardWidth = 108;
    const columnCount = this.networkCoverColumnCount();
    const contentWidth = Math.max(1, this.contextViewportWidth - horizontalPadding);
    const fittedGap = columnCount > 1 ?
      (contentWidth - targetCardWidth * columnCount) / (columnCount - 1) : 8;
    return Math.max(8, Math.min(12, fittedGap));
  }

  networkCoverRowGap(): number {
    return this.networkCoverColumnGap() + 2;
  }

  captureContextMenuAnchor(event?: GestureEvent): void {
    const finger = event && event.fingerList.length > 0 ? event.fingerList[0] : undefined;
    if (finger) {
      this.contextMenuX = finger.globalX;
      this.contextMenuY = finger.globalY;
    }
  }

  updateContextViewport(area: Area): void {
    const width = this.areaDimension(area.width);
    const height = this.areaDimension(area.height);
    if (width > 0) {
      this.contextViewportWidth = width;
      this.shelfTileViewportWidth = width;
    }
    if (height > 0) this.contextViewportHeight = height;
  }

  areaDimension(value: Length): number {
    if (typeof value === 'number') return Number.isFinite(value) ? value : 0;
    const parsed = Number.parseFloat(`${value}`);
    return Number.isFinite(parsed) ? parsed : 0;
  }

  contextMenuLeft(menuWidth: number): number {
    return Math.max(12, Math.min(this.contextMenuX - 18, this.contextViewportWidth - menuWidth - 12));
  }

  contextMenuTop(menuHeight: number): number {
    const topLimit = this.statusBarHeight + 8;
    const maxTop = Math.max(topLimit,
      this.contextViewportHeight - this.contextMenuBottomInset() - menuHeight);
    const below = this.contextMenuY + 12;
    if (below <= maxTop) return below;
    return Math.max(topLimit, Math.min(this.contextMenuY - menuHeight - 12, maxTop));
  }

  bookActionMenuHeight(book: Book): number {
    const baseHeight = 320;
    return baseHeight + (LocalBookService.isLocalBook(book) ? 0 : 44) + (book.customCoverUrl ? 44 : 0);
  }

  contextMenuBottomInset(): number {
    if (deviceInfo.sdkApiVersion < 23) {
      return 12;
    }
    const floatingTabHeight = 56;
    const comfortableGap = 12;
    return floatingTabHeight + Math.max(this.navBarHeight, 8) + comfortableGap;
  }

  deleteBookCoverCache(book: Book): void {
    const context = getContext(this);
    const covers = [
      ...BookDisplayHelper.decodeCoverList(book.customCoverUrl),
      ...BookDisplayHelper.decodeCoverList(book.coverUrl)
    ];
    for (const cover of covers) {
      BookCoverCache.deleteCachedCover(context, cover);
    }
    const nextMap: Map<string, string> = new Map(this.shelfCoverMap);
    const coverCount = Math.max(1, BookDisplayHelper.getCoverList(book).length);
    for (let i = 0; i < coverCount; i++) {
      const key = this.shelfCoverKey(book, i);
      nextMap.delete(key);
      this.shelfCoverRawUrls.delete(key);
    }
    this.shelfCoverMap = nextMap;
  }

  async refreshShelfCoverCache(books: Book[]): Promise<void> {
    const revision = ++this.shelfCoverCacheRevision;
    this.shelfCoverBookTasks.clear();
    this.pendingShelfCoverUpdates.clear();
    if (this.shelfCoverUpdateTimer >= 0) {
      clearTimeout(this.shelfCoverUpdateTimer);
      this.shelfCoverUpdateTimer = -1;
    }
    // Only warm the initial viewport. Remaining covers are scheduled from coverView.onAppear.
    const initialBooks = books.slice(0, SHELF_COVER_INITIAL_PREFETCH_COUNT);
    const tasks: Promise<void>[] = initialBooks.map(async (book: Book): Promise<void> => {
      const taskKey = `${revision}:${book.bookUrl}`;
      this.shelfCoverBookTasks.add(taskKey);
      try {
        const updates = await this.resolveShelfBookCoverUpdates(book, revision);
        this.queueShelfCoverUpdates(updates, revision);
      } finally {
        this.shelfCoverBookTasks.delete(taskKey);
      }
    });
    try {
      await Promise.all(tasks);
    } catch (e) {
      console.warn('预缓存首屏书架封面失败:', e);
    }
  }

  ensureShelfBookCoverCache(book: Book): void {
    const revision = this.shelfCoverCacheRevision;
    const taskKey = `${revision}:${book.bookUrl}`;
    if (this.shelfCoverBookTasks.has(taskKey)) return;
    this.shelfCoverBookTasks.add(taskKey);
    this.resolveShelfBookCoverUpdates(book, revision)
      .then((updates: Map<string, string>) => this.queueShelfCoverUpdates(updates, revision))
      .catch((e: Error) => console.warn('缓存可见书籍封面失败:', e))
      .finally(() => this.shelfCoverBookTasks.delete(taskKey));
  }

  async resolveShelfBookCoverUpdates(book: Book, revision: number): Promise<Map<string, string>> {
    const updates: Map<string, string> = new Map();
    if (revision !== this.shelfCoverCacheRevision) return updates;
    const covers = CoverGallerySettings.getDisplayCoverList(
      book,
      this.appDarkMode,
      this.bookshelfCoverAlbums,
      this.bookshelfLightCoverAlbumId,
      this.bookshelfDarkCoverAlbumId,
      this.bookshelfCoverApplyScope,
      this.bookshelfCoverTargetBooks,
      this.bookshelfIgnoreSourceCover,
      this.bookshelfCoverMode
    );
    const context = getContext(this);
    for (let i = 0; i < covers.length; i++) {
      if (revision !== this.shelfCoverCacheRevision) return new Map();
      const raw = covers[i];
      if (!raw || (!raw.startsWith('http://') && !raw.startsWith('https://'))) continue;
      const key = this.shelfCoverKey(book, i);
      if (this.shelfCoverMap.get(key) && this.shelfCoverRawUrls.get(key) === raw) continue;
      try {
        const local = await BookCoverCache.resolveCachedCoverAsync(context, raw) ||
          await BookCoverCache.resolveCover(context, raw);
        if (revision !== this.shelfCoverCacheRevision) return new Map();
        if (local && local !== raw) {
          this.shelfCoverRawUrls.set(key, raw);
          updates.set(key, local);
        }
      } catch (e) {
        console.warn('缓存书架封面失败:', e);
      }
    }
    return updates;
  }

  queueShelfCoverUpdates(updates: Map<string, string>, revision: number): void {
    if (revision !== this.shelfCoverCacheRevision || updates.size === 0) return;
    updates.forEach((value: string, key: string) => this.pendingShelfCoverUpdates.set(key, value));
    if (this.shelfCoverUpdateTimer >= 0) return;
    this.shelfCoverUpdateTimer = setTimeout(() => {
      this.shelfCoverUpdateTimer = -1;
      if (revision !== this.shelfCoverCacheRevision || this.pendingShelfCoverUpdates.size === 0) return;
      const nextMap = new Map(this.shelfCoverMap);
      this.pendingShelfCoverUpdates.forEach((value: string, key: string) => nextMap.set(key, value));
      this.pendingShelfCoverUpdates.clear();
      this.shelfCoverMap = nextMap;
    }, SHELF_COVER_UPDATE_BATCH_MS);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        Column() {
        Row() {
          if (this.isTileGroupPage() && !this.isBookMultiSelect) {
            ImmersiveBackButton({
              iconColor: this.primaryTextColor(),
              darkMode: this.appDarkMode,
              buttonSize: 40,
              containerWidth: 56,
              materialScale: 0.83,
              compactLayout: true,
              onBack: () => this.exitTileGroupPage()
            })
            Text(this.activeShelfGroupName())
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Blank()
            if (this.books.length > 0) {
              this.shelfSortButton()
            }
            Text(this.books.length > 0 ? `${this.books.length}本` : '')
              .fontSize(14)
              .fontColor('#999')
          } else {
            this.shelfLayoutButton()

            if (this.isBookMultiSelect) {
              Blank()
              Text('取消')
                .fontSize(15)
                .fontColor(this.primaryTextColor())
                .width(52)
                .height(56)
                .textAlign(TextAlign.Center)
                .onClick(() => this.exitBookMultiSelect())
            } else {
              this.shelfScopeSegment()

              Blank()

              if (this.books.length > 0) {
                this.shelfSortButton()
              }

              Row({ space: 4 }) {
                Text(this.books.length > 0 ? `${this.books.length}本` : '')
                  .fontSize(14)
                  .fontColor('#999')
                SymbolGlyph(this.showShelfGroups ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
                  .fontSize(15)
                  .fontColor([this.secondaryTextColor()])
              }
              .height(36)
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                const next = !this.showShelfGroups;
                animateTo({ duration: 190, curve: Curve.Friction }, () => {
                  this.showShelfGroups = next;
                });
                this.showShelfScopeOptions = false;
                this.showShelfSortMenu = false;
                this.showShelfLayoutMenu = false;
              })
            }
          }
        }
        .width('100%')
        .height(56 + this.statusBarHeight)
        .padding({
          left: this.isTileGroupPage() && !this.isBookMultiSelect ? 0 : 16,
          right: 16,
          top: this.statusBarHeight
        })
        .alignItems(VerticalAlign.Center)

        if (this.isBookMultiSelect) {
          this.bookSelectionStatusBar()
        }

        if (this.showShelfGroups && !this.isBookMultiSelect) {
          this.shelfGroupBar()
        }
        }
        .width('100%')
        .position({ x: 0, y: 0 })
        .zIndex(4)
        .backgroundColor(ThemeRuntime.topBarColor(this.appDarkMode))
        .backdropBlur(ThemeRuntime.topBarBlur())

        if (this.isLoading) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
            Text('加载中...')
              .fontSize(14)
              .fontColor(this.subTextColor())
              .margin({ top: 8 })
          }
          .width('100%')
          .height('100%')
          .padding({ top: this.bookshelfTopOverlayHeight() })
          .justifyContent(FlexAlign.Center)
          .translate({ x: this.shelfScopeTransitionX })
          .scale({ x: this.shelfScopeTransitionScale, y: this.shelfScopeTransitionScale })
          .opacity(this.shelfScopeTransitionOpacity)
          .priorityGesture(
            PanGesture({ direction: PanDirection.Horizontal, distance: 24 })
              .onActionStart(() => {
                this.markShelfScopePanGesture(500);
              })
              .onActionUpdate(() => {
                this.markShelfScopePanGesture(240);
              })
              .onActionEnd((event: GestureEvent) => {
                this.switchShelfScopeBySwipe(event.offsetX);
              })
          )
        } else if (this.books.length === 0) {
          Column() {
            Text('📚')
              .fontSize(48)
              .margin({ bottom: 16 })
            Text('暂无书籍')
              .fontSize(16)
              .fontColor(this.subTextColor())
            Text(this.shelfScopeEmptyHint())
              .fontSize(14)
              .fontColor(this.subTextColor())
              .margin({ top: 8 })
          }
          .width('100%')
          .height('100%')
          .padding({ top: this.bookshelfTopOverlayHeight() })
          .justifyContent(FlexAlign.Center)
          .translate({ x: this.shelfScopeTransitionX })
          .scale({ x: this.shelfScopeTransitionScale, y: this.shelfScopeTransitionScale })
          .opacity(this.shelfScopeTransitionOpacity)
          .priorityGesture(
            PanGesture({ direction: PanDirection.Horizontal, distance: 24 })
              .onActionStart(() => {
                this.markShelfScopePanGesture(500);
              })
              .onActionUpdate(() => {
                this.markShelfScopePanGesture(240);
              })
              .onActionEnd((event: GestureEvent) => {
                this.switchShelfScopeBySwipe(event.offsetX);
              })
          )
        } else {
          Refresh({ refreshing: $$this.isShelfRefreshing, builder: this.shelfRefreshBuilder }) {
            if (this.isTileLayout()) {
              this.shelfTileGrid()
            } else {
              List({ space: 8 }) {
              ListItem() {
                Row()
                  .height(this.bookshelfTopOverlayHeight())
              }

              LazyForEach(this.shelfListBookDataSource(), (book: Book) => {
                ListItem() {
                  Row() {
                    if (this.isBookMultiSelect) {
                      Toggle({ type: ToggleType.Checkbox, isOn: this.isBookSelected(book.bookUrl) })
                        .selectedColor(this.buttonColor())
                        .margin({ right: 12 })
                        .onChange((isOn: boolean) => {
                          this.setBookSelected(book.bookUrl, isOn);
                        })
                    }
                    Column() {
                      if (this.isCompactLayout()) {
                        this.compactBookContent(book)
                      } else {
                        this.looseBookContent(book)
                      }
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    .backgroundColor(this.glassCardColor())
                    .borderRadius(8)
                    .clip(true)
                    .border({ width: ThemeRuntime.glassBorderWidth(), color: this.glassBorderColor() })
                    .shadow({ radius: ThemeRuntime.glassShadowRadius(), color: this.glassShadowColor(), offsetX: ThemeRuntime.glassShadowOffsetX(), offsetY: ThemeRuntime.glassShadowOffsetY() })
                    .gesture(
                      LongPressGesture({ repeat: false })
                        .onAction((event: GestureEvent) => {
                          if (!this.isBookMultiSelect) {
                            this.showBookActions(book, event);
                          }
                        })
                    )
                    .onClick((event: ClickEvent) => {
                      if (this.consumeShelfSwipeClick()) {
                        return;
                      }
                      if (this.isBookMultiSelect) {
                        this.toggleSelectedBook(book.bookUrl);
                        return;
                      }
                      this.openShelfBook(book, event.windowX, event.windowY);
                    })
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)
                }
              }, (book: Book) => this.shelfBookRenderKey(book, `list_${this.shelfScope}`))

              ListItem() {
                Column()
                  .height(this.bookshelfListBottomInset())
              }
            }
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
            .width('100%')
            .height('100%')
            .padding({ left: 16, right: 16 })
            .backgroundColor(this.pageColor())
              .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
            }
          }
          .layoutWeight(1)
          .backgroundColor(this.pageColor())
          .refreshOffset(64)
          .onStateChange((state: RefreshStatus) => {
            this.updateShelfRefreshPrompt(state);
          })
          .onRefreshing(() => {
            this.refreshBookshelfToc();
          })
          .translate({ x: this.shelfScopeTransitionX })
          .scale({ x: this.shelfScopeTransitionScale, y: this.shelfScopeTransitionScale })
          .opacity(this.shelfScopeTransitionOpacity)
          .priorityGesture(
            PanGesture({ direction: PanDirection.Horizontal, distance: 24 })
              .onActionStart(() => {
                this.markShelfScopePanGesture(500);
              })
              .onActionUpdate(() => {
                this.markShelfScopePanGesture(240);
              })
              .onActionEnd((event: GestureEvent) => {
                this.switchShelfScopeBySwipe(event.offsetX);
              })
          )
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageColor())
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])

      if (this.showShelfSortMenu && this.books.length > 0) {
        this.shelfSortFloatingMenu()
      }

      if (this.showShelfLayoutMenu && !this.isBookMultiSelect && !this.isTileGroupPage()) {
        this.shelfLayoutFloatingMenu()
      }

      if (this.showShelfScopeOptions && !this.isBookMultiSelect && !this.isTileGroupPage()) {
        this.shelfScopeFloatingMenu()
      }

      if (this.showActionDialog && this.pendingActionBook) {
        Stack({ alignContent: Alignment.TopStart }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.appDarkMode ? '#52000000' : '#26FFFFFF')
            .backdropBlur(ThemeRuntime.glassBlur('popover', 18))
            .onClick(() => this.closeBookActions())

          Column() {
            this.contextActionItem($r('sys.symbol.info_circle'), '查看书籍详情', this.primaryTextColor(), () => {
              if (this.pendingActionBook) {
                const book = this.pendingActionBook;
                this.closeBookActions();
                this.openShelfBookDetail(book);
              }
            })
            if (!LocalBookService.isLocalBook(this.pendingActionBook)) {
              this.contextActionItem($r('sys.symbol.arrow_left_arrow_right'), '换源', this.primaryTextColor(), () => {
                if (this.pendingActionBook) {
                  const book = this.pendingActionBook;
                  this.closeBookActions();
                  this.openShelfChangeSource(book);
                }
              })
            }
            if (!LocalBookService.isLocalBook(this.pendingActionBook)) {
              this.contextActionItem($r('sys.symbol.download'), '缓存', this.primaryTextColor(), () => {
                if (this.pendingActionBook) {
                  const book = this.pendingActionBook;
                  this.showActionDialog = false;
                  setTimeout(() => {
                    this.openCacheDialog(book);
                  }, 0);
                }
              })
            }
            this.contextActionItem($r('sys.symbol.picture_badge_arrow_down'), '获取网络封面', this.primaryTextColor(), () => {
              if (this.pendingActionBook) {
                const book = this.pendingActionBook;
                this.showActionDialog = false;
                this.pendingActionBook = null;
                this.openNetworkCoverPicker(book);
              }
            })
            if (this.pendingActionBook.customCoverUrl) {
              this.contextActionItem($r('sys.symbol.minus_circle'), '恢复默认封面',
                this.primaryTextColor(), () => {
                  if (this.pendingActionBook) {
                    const book = this.pendingActionBook;
                    this.closeBookActions();
                    this.restoreDefaultBookCover(book);
                  }
                })
            }
            if (LocalBookService.isLocalBook(this.pendingActionBook)) {
              this.contextActionItem($r('sys.symbol.square_and_pencil'), '编辑书籍信息',
                this.primaryTextColor(), () => {
                  if (this.pendingActionBook) {
                    this.editingBookName = this.pendingActionBook.name;
                    this.editingBookAuthor = this.pendingActionBook.author;
                    this.showActionDialog = false;
                    this.showEditBookInfoDialog = true;
                  }
                })
            }
            this.contextActionItem($r('sys.symbol.folder'), '移动分组', this.primaryTextColor(), () => {
              if (this.pendingActionBook) {
                const bookUrl = this.pendingActionBook.bookUrl;
                this.showActionDialog = false;
                this.pendingActionBook = null;
                this.groupPickerSingleBookUrl = bookUrl;
                this.showBookGroupPicker = true;
              }
            })
            this.contextActionItem($r('sys.symbol.bookmark'), '自定义标签', this.primaryTextColor(), () => {
              if (this.pendingActionBook) {
                this.editingTags = BookDisplayHelper.getBookTags(this.pendingActionBook);
                this.tagInput = '';
              }
              this.showActionDialog = false;
              this.showTagDialog = true;
            })
            this.contextActionItem($r('sys.symbol.checkmark_circle'), '多选', this.primaryTextColor(), () => {
              if (this.pendingActionBook) {
                const bookUrl = this.pendingActionBook.bookUrl;
                this.closeBookActions();
                this.enterBookMultiSelect(bookUrl);
              }
            })
            this.contextActionItem($r('sys.symbol.trash'), '移出书架', '#E53935', () => {
              if (this.pendingActionBook) {
                const book = this.pendingActionBook;
                this.closeBookActions();
                this.showDeleteConfirm(book);
              }
            })
          }
          .width(158)
          .padding({ top: 6, bottom: 6 })
          .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
          .borderRadius(ThemeRuntime.glassCornerRadius(14, 'panel'))
          .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
          .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'panel') })
          .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'panel'), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
          .position({
            x: this.contextMenuLeft(158),
            y: this.contextMenuTop(this.bookActionMenuHeight(this.pendingActionBook))
          })
        }
        .width('100%')
        .height('100%')
      }

      if (this.showShelfChangeSourceDialog && this.shelfChangeSourceTarget) {
        this.shelfChangeSourceDialog()
      }

      if (this.showNetworkCoverDialog && this.networkCoverTargetBook) {
        Column() {
          Blank()
            .layoutWeight(1)
            .onClick(() => this.closeNetworkCoverPicker())

          Column() {
            Row() {
              Column() {
                Text('获取网络封面')
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.primaryTextColor())
                Text(`《${this.networkCoverTargetBook.name}》`)
                  .fontSize(13)
                  .fontColor(this.secondaryTextColor())
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 3 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Button('取消')
                .height(36)
                .backgroundColor(this.inputColor())
                .fontColor(this.primaryTextColor())
                .onClick(() => this.closeNetworkCoverPicker())
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Row({ space: 8 }) {
              if (this.networkCoverSearching) {
                LoadingProgress()
                  .width(18)
                  .height(18)
              }
              Text(this.networkCoverStatus || '正在准备搜索...')
                .fontSize(12)
                .fontColor(this.subTextColor())
                .maxLines(2)
                .layoutWeight(1)
            }
            .width('100%')
            .margin({ top: 12, bottom: 10 })

            if (this.networkCoverCandidates.length === 0 && !this.networkCoverSearching) {
              Column({ space: 10 }) {
                SymbolGlyph($r('sys.symbol.square_grid_2x2'))
                  .fontSize(42)
                  .fontColor([this.subTextColor()])
                Text('未找到可用的网络封面')
                  .fontSize(14)
                  .fontColor(this.secondaryTextColor())
              }
              .width('100%')
              .height(220)
              .justifyContent(FlexAlign.Center)
            } else {
              Grid() {
                ForEach(this.networkCoverCandidates, (candidate: SearchBook) => {
                  GridItem() {
                    Column() {
                      Stack() {
                        Column() {
                          Text((candidate.name || '书').substring(0, 1))
                            .fontSize(28)
                            .fontColor('#FFFFFF')
                        }
                        .width('100%')
                        .aspectRatio(0.72)
                        .justifyContent(FlexAlign.Center)
                        .backgroundColor(this.accentColor())

                        Image(candidate.coverUrl)
                          .width('100%')
                          .height('100%')
                          .objectFit(ImageFit.Cover)
                      }
                      .width('100%')
                      .aspectRatio(0.72)
                      .borderRadius(7)
                      .clip(true)
                      .backgroundColor(this.inputColor())

                      Text(candidate.name || '未知书名')
                        .fontSize(12)
                        .fontColor(this.primaryTextColor())
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                        .margin({ top: 6 })
                      Text(candidate.originName || candidate.author || '启用书源')
                        .fontSize(10)
                        .fontColor(this.subTextColor())
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                        .margin({ top: 2 })
                    }
                    .width('100%')
                    .padding(5)
                    .borderRadius(9)
                    .backgroundColor(this.glassCardColor())
                    .border({ width: ThemeRuntime.glassBorderWidth(), color: this.glassBorderColor() })
                    .onClick(() => this.applyNetworkCover(candidate))
                  }
                }, (candidate: SearchBook) => candidate.coverUrl)
                GridItem() {
                  Column()
                    .height(68)
                }
                .columnStart(0)
                .columnEnd(this.networkCoverColumnCount() - 1)
              }
              .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
              .columnsTemplate(this.networkCoverColumnsTemplate())
              .columnsGap(this.networkCoverColumnGap())
              .rowsGap(this.networkCoverRowGap())
              .layoutWeight(1)
              .width('100%')
            }
          }
          .width('100%')
          .height('72%')
          .padding({ left: 16, right: 16, top: 18, bottom: Math.max(this.navBarHeight, 12) + 12 })
          .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
          .borderRadius({
            topLeft: ThemeRuntime.glassCornerRadius(22, 'panel'),
            topRight: ThemeRuntime.glassCornerRadius(22, 'panel')
          })
          .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
          .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'panel') })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
      }

      if (this.showEditBookInfoDialog && this.pendingActionBook) {
        Column() {
          Column() {
            Text('编辑书籍信息')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ bottom: 18 })

            Text('书名')
              .fontSize(13)
              .fontColor(this.secondaryTextColor())
              .width('100%')
              .margin({ bottom: 6 })

            TextInput({ placeholder: '请输入书名', text: this.editingBookName })
              .width('100%')
              .height(44)
              .fontColor(this.primaryTextColor())
              .placeholderColor(this.subTextColor())
              .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'popover'))
              .backdropBlur(ThemeRuntime.glassBlur('popover', 18))
              .border({ width: ThemeRuntime.glassBorderWidth('popover'),
                color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'popover') })
              .borderRadius(12)
              .onChange((value: string) => {
                this.editingBookName = value;
              })

            Text('作者')
              .fontSize(13)
              .fontColor(this.secondaryTextColor())
              .width('100%')
              .margin({ top: 14, bottom: 6 })

            TextInput({ placeholder: '请输入作者（可留空）', text: this.editingBookAuthor })
              .width('100%')
              .height(44)
              .fontColor(this.primaryTextColor())
              .placeholderColor(this.subTextColor())
              .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'popover'))
              .backdropBlur(ThemeRuntime.glassBlur('popover', 18))
              .border({ width: ThemeRuntime.glassBorderWidth('popover'),
                color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'popover') })
              .borderRadius(12)
              .onChange((value: string) => {
                this.editingBookAuthor = value;
              })

            Row() {
              Button('取消')
                .width('45%')
                .height(44)
                .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'popover'))
                .fontColor(this.primaryTextColor())
                .onClick(() => this.closeEditBookInfoDialog())

              Button('保存')
                .width('45%')
                .height(44)
                .enabled(!!this.editingBookName.trim())
                .opacity(this.editingBookName.trim() ? 1 : 0.45)
                .onClick(() => this.saveLocalBookInfo())
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
            .margin({ top: 22 })
          }
          .width('85%')
          .padding(20)
          .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
          .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
          .border({ width: ThemeRuntime.glassBorderWidth('overlay'),
            color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
          .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'),
            color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'),
            offsetX: ThemeRuntime.glassShadowOffsetX('overlay'),
            offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
          .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')
        .justifyContent(FlexAlign.Center)
      }

      if (this.showCacheDialog && this.cacheTargetBook) {
        Column() {
          Blank()
            .layoutWeight(1)
            .onClick(() => {
              if (!this.isCacheTargetBookCaching()) {
                this.closeCacheDialog();
              }
            })

          Column() {
            Text(`缓存《${this.cacheTargetBook.name}》`)
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ bottom: 8 })

            if (this.cacheStatus) {
              Text(this.cacheStatus)
                .fontSize(13)
                .fontColor(this.subTextColor())
                .width('100%')
                .textAlign(TextAlign.Center)
                .margin({ bottom: 8 })
            }

            this.actionItem(this.isCacheTargetBookCaching() ? '正在缓存...' : '缓存全文', this.primaryTextColor(), () => {
              this.cacheWholeBook();
            })
            this.actionItem('缓存指定章节', this.primaryTextColor(), () => {
              if (!this.isCacheTargetBookCaching()) {
                this.showCacheDialog = false;
                this.showChapterCacheDialog = true;
                if (this.cacheTargetBook) {
                  this.loadCacheChapters(this.cacheTargetBook);
                }
              }
            })
            this.actionItem('清除已缓存章节', '#E53935', () => {
              this.clearCachedChapters();
            })

            Button('取消')
              .width('100%')
              .height(44)
              .margin({ top: 10 })
              .backgroundColor(this.appDarkMode ? '#24272D' : '#F5F5F5')
              .fontColor(this.primaryTextColor())
              .onClick(() => {
                this.closeCacheDialog(false);
              })
          }
          .width('100%')
          .padding({ left: 18, right: 18, top: 18, bottom: 18 })
          .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
          .borderRadius({
            topLeft: ThemeRuntime.glassCornerRadius(18, 'panel'),
            topRight: ThemeRuntime.glassCornerRadius(18, 'panel')
          })
          .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
          .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'panel') })
          .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'panel'), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
          .margin({ bottom: this.actionSheetBottomMargin() })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
      }

      if (this.showChapterCacheDialog && this.cacheTargetBook) {
        Column() {
          Blank()
            .layoutWeight(1)
            .onClick(() => {
              if (!this.isCacheTargetBookCaching()) {
                this.closeCacheDialog();
              }
            })

          Column() {
            Row() {
              Text('选择章节缓存')
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.primaryTextColor())
                .layoutWeight(1)
              Button('关闭')
                .height(34)
                .fontSize(13)
                .borderRadius(17)
                .onClick(() => {
                  if (!this.isCacheTargetBookCaching()) {
                    this.closeCacheDialog();
                  }
                })
            }
            .width('100%')
            .height(46)

            if (this.cacheStatus) {
              Text(this.cacheStatus)
                .fontSize(13)
                .fontColor(this.subTextColor())
                .width('100%')
                .margin({ bottom: 8 })
            }

            List({ space: 2 }) {
              ForEach(this.cacheChapters, (chapter: BookChapter, index: number) => {
                ListItem() {
                  Row({ space: 8 }) {
                    Text(chapter.title)
                      .fontSize(15)
                      .fontColor(chapter.cacheDate > 0 ? this.cachedChapterTextColor() : this.primaryTextColor())
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    if (chapter.cacheDate > 0) {
                      Text('已缓存')
                        .fontSize(11)
                        .fontColor(this.appDarkMode ? '#7CC7A0' : '#1F8F55')
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .backgroundColor(this.appDarkMode ? '#24382F' : '#E6F4EC')
                        .borderRadius(4)
                    }
                  }
                  .width('100%')
                  .padding({ left: 2, right: 2, top: 12, bottom: 12 })
                  .onClick(() => {
                    if (!this.isCacheTargetBookCaching()) {
                      this.cacheSingleChapter(index);
                    }
                  })
                }
              })
            }
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
            .width('100%')
            .height(420)
          }
          .width('100%')
          .padding({ left: 18, right: 18, top: 18, bottom: 18 })
          .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
          .borderRadius({
            topLeft: ThemeRuntime.glassCornerRadius(18, 'panel'),
            topRight: ThemeRuntime.glassCornerRadius(18, 'panel')
          })
          .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
          .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'panel') })
          .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'panel'), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
          .margin({ bottom: this.actionSheetBottomMargin() })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
      }

      if (this.showTagDialog && this.pendingActionBook) {
        Column() {
          Column() {
            Text('自定义标签')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ bottom: 14 })

            Scroll() {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.editingTags, (tag: string, index: number) => {
                  Row() {
                    Text(tag)
                      .fontSize(13)
                      .fontColor(BookDisplayHelper.getTagTextColor(index, this.appDarkMode))
                    Text('×')
                      .fontSize(14)
                      .fontColor(BookDisplayHelper.getTagTextColor(index, this.appDarkMode))
                      .margin({ left: 6 })
                  }
                  .padding({ left: 10, right: 8, top: 5, bottom: 5 })
                  .backgroundColor(BookDisplayHelper.getTagBackgroundColor(index, this.appDarkMode))
                  .borderRadius(14)
                  .margin({ right: 8, bottom: 8 })
                  .onClick(() => {
                    this.removeEditingTag(tag);
                  })
                })
              }
              .width('100%')
            }
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
            .scrollable(ScrollDirection.Vertical)
            .scrollBar(BarState.Auto)
            .width('100%')
            .constraintSize({ minHeight: 40, maxHeight: 220 })
            .margin({ bottom: 12 })

            Row() {
              TextInput({ placeholder: '输入标签', text: this.tagInput })
                .height(40)
                .layoutWeight(1)
                .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'popover'))
      .backdropBlur(ThemeRuntime.glassBlur('popover', 18))
                .border({ width: ThemeRuntime.glassBorderWidth('popover'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'popover') })
                .fontColor(this.primaryTextColor())
                .placeholderColor(this.subTextColor())
                .borderRadius(12)
                .onChange((value: string) => {
                  this.tagInput = value;
                })

              Button('添加')
                .height(40)
                .margin({ left: 8 })
                .onClick(() => {
                  this.addEditingTag();
                })
            }
            .width('100%')
            .margin({ bottom: 18 })

            Row() {
              Button('取消')
                .width('45%')
                .height(44)
                .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'popover'))
      .backdropBlur(ThemeRuntime.glassBlur('popover', 18))
                .border({ width: ThemeRuntime.glassBorderWidth('popover'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'popover') })
                .fontColor(this.primaryTextColor())
                .onClick(() => {
                  this.showTagDialog = false;
                  this.pendingActionBook = null;
                })

              Button('保存')
                .width('45%')
                .height(44)
                .onClick(() => {
                  this.saveCustomTags();
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
          .width('85%')
          .padding(18)
          .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
          .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
          .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
          .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
          .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#00000000')
        .justifyContent(FlexAlign.Center)
      }

      // 删除确认弹窗
      if (this.showDeleteDialog && this.pendingDeleteBook) {
        Column() {
          Column() {
            Text('确认删除')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ bottom: 12 })

            Text(`确定要将《${this.pendingDeleteBook.name}》从书架移除吗？`)
              .fontSize(15)
              .fontColor(this.secondaryTextColor())
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ bottom: 20 })

            Row() {
              Button('取消')
                .width('45%')
                .height(44)
                .backgroundColor(this.appDarkMode ? '#24272D' : '#F5F5F5')
                .fontColor(this.primaryTextColor())
                .onClick(() => {
                  this.showDeleteDialog = false;
                  this.pendingDeleteBook = null;
                })

              Button('删除')
                .width('45%')
                .height(44)
                .backgroundColor('#E53935')
                .onClick(() => {
                  if (this.pendingDeleteBook) {
                    const book = this.pendingDeleteBook;
                    this.showDeleteDialog = false;
                    this.pendingDeleteBook = null;
                    this.deleteBook(book);
                  }
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
          .width('85%')
          .padding(24)
          .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
          .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
          .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
          .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
          .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.showDeleteDialog = false;
          this.pendingDeleteBook = null;
        })
      }

      if (this.isBookMultiSelect) {
        this.bookMultiSelectBar()
      }
      if (this.showBookGroupPicker) {
        this.bookGroupPickerDialog()
      }
      if (this.showAddBookGroupDialog) {
        this.addBookGroupDialog()
      }
      if (this.showBookGroupActionMenu && this.pendingBookGroup) {
        this.bookGroupActionMenu()
      }
      if (this.showRenameBookGroupDialog && this.pendingBookGroup) {
        this.renameBookGroupDialog()
      }
      if (this.showDeleteBookGroupDialog && this.pendingDeleteBookGroup) {
        this.deleteBookGroupDialog()
      }
      if (this.showBatchDeleteDialog) {
        this.batchDeleteBooksDialog()
      }
      if (this.openingBook) {
        this.shelfBookOpeningOverlay(this.openingBook)
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_oldValue: Area, newValue: Area) => this.updateContextViewport(newValue))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  shelfGroupBar() {
    Scroll() {
      Row({ space: 8 }) {
        this.shelfGroupChip('全部', 0)
        ForEach(this.shelfGroups, (group: BookGroup) => {
          Text(group.groupName)
            .fontSize(13)
            .fontColor(this.activeShelfGroupId === group.groupId ? '#FFFFFF' : this.primaryTextColor())
            .padding({ left: 13, right: 13, top: 7, bottom: 7 })
            .borderRadius(16)
            .backgroundColor(this.activeShelfGroupId === group.groupId ? this.accentColor() : this.glassCardColor())
            .border({ width: this.activeShelfGroupId === group.groupId ? 0 : 1, color: this.glassBorderColor() })
            .onClick(() => {
              this.selectShelfGroup(group.groupId);
            })
            .gesture(
              LongPressGesture({ repeat: false })
                .onAction((event: GestureEvent) => {
                  this.captureContextMenuAnchor(event);
                  this.pendingBookGroup = group;
                  this.showBookGroupActionMenu = true;
                })
            )
        }, (group: BookGroup) => `${group.groupId}_${group.groupName}`)
        this.shelfGroupChip('未分组', -1)
        Text('＋')
          .fontSize(20)
          .fontColor(this.accentColor())
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .borderRadius(17)
          .backgroundColor(this.glassCardColor())
          .border({ width: ThemeRuntime.glassBorderWidth(), color: this.glassBorderColor() })
          .onClick(() => {
            this.newBookGroupName = '';
            this.showAddBookGroupDialog = true;
          })
      }
      .padding({ left: 16, right: 16, bottom: 8 })
    }
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .width('100%')
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .transition(this.shelfGroupBarTransition())
  }

  shelfGroupBarTransition(): TransitionEffect {
    const appear = TransitionEffect.translate({ y: -8 })
      .combine(TransitionEffect.opacity(0))
      .animation({ duration: 210, curve: Curve.Friction });
    const disappear = TransitionEffect.translate({ y: -5 })
      .combine(TransitionEffect.opacity(0))
      .animation({ duration: 140, curve: Curve.EaseIn });
    return TransitionEffect.asymmetric(appear, disappear);
  }

  @Builder
  shelfGroupChip(label: string, groupId: number) {
    Text(label)
      .fontSize(13)
      .fontColor(this.activeShelfGroupId === groupId ? '#FFFFFF' : this.primaryTextColor())
      .padding({ left: 13, right: 13, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor(this.activeShelfGroupId === groupId ? this.accentColor() : this.glassCardColor())
      .border({ width: this.activeShelfGroupId === groupId ? 0 : 1, color: this.glassBorderColor() })
      .onClick(() => {
        this.selectShelfGroup(groupId);
      })
  }

  @Builder
  bookSelectionStatusBar() {
    Row() {
      Text(this.areAllBooksSelected() ? '☑' : '☐')
        .fontSize(20)
        .fontColor(this.accentColor())
        .width(28)
        .textAlign(TextAlign.Center)
        .onClick(() => this.toggleAllBooks())

      Text(`已选择 ${this.selectedBookUrls.length}/${this.books.length}`)
        .fontSize(14)
        .fontColor(this.secondaryTextColor())
        .margin({ left: 8 })
        .layoutWeight(1)

      Text(this.areAllBooksSelected() ? '取消全选' : '全选')
        .fontSize(14)
        .fontColor(this.accentColor())
        .padding({ left: 12, right: 4, top: 8, bottom: 8 })
        .onClick(() => this.toggleAllBooks())
    }
    .width('100%')
    .height(42)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  bookMultiSelectBar() {
    Row({ space: 10 }) {
      Button('删除', { type: ButtonType.Normal })
        .layoutWeight(1)
        .height(42)
        .fontSize(14)
        .borderRadius(10)
        .backgroundColor('#E53935')
        .fontColor('#FFFFFF')
        .enabled(this.selectedBookUrls.length > 0)
        .onClick(() => {
          if (this.selectedBookUrls.length > 0) this.showBatchDeleteDialog = true;
        })
      Button('分组', { type: ButtonType.Normal })
        .layoutWeight(1)
        .height(42)
        .fontSize(14)
        .borderRadius(10)
        .backgroundColor(this.buttonColor())
        .fontColor('#FFFFFF')
        .enabled(this.selectedBookUrls.length > 0)
        .onClick(() => {
          if (this.selectedBookUrls.length > 0) {
            this.groupPickerSingleBookUrl = '';
            this.showBookGroupPicker = true;
          }
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: this.multiSelectBottomPadding() })
    .backgroundColor(this.glassCardColor())
    .border({ width: ThemeRuntime.glassBorderWidth(), color: this.glassBorderColor() })
    .alignSelf(ItemAlign.End)
  }

  @Builder
  bookGroupPickerDialog() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.appDarkMode ? '#36000000' : '#18000000')
        .onClick(() => this.closeBookGroupPicker())

      Column({ space: 6 }) {
        Text('移动到分组')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
          .width('100%')
          .height(32)
          .textAlign(TextAlign.Center)
        Scroll() {
          Column({ space: 4 }) {
            this.bookGroupPickerItem('未分组', 0)
            ForEach(this.shelfGroups, (group: BookGroup) => {
              this.bookGroupPickerItem(group.groupName, group.groupId)
            }, (group: BookGroup) => `picker_${group.groupId}`)
          }
          .width('100%')
        }
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .width('100%')
        .constraintSize({ maxHeight: 260 })
        .scrollBar(BarState.Off)
      }
      .width(230)
      .padding(10)
      .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
      .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
      .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'panel') })
      .borderRadius(ThemeRuntime.glassCornerRadius(14, 'panel'))
      .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'panel'), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
      .margin({ right: 16, bottom: this.bookGroupPickerBottomMargin() })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  bookGroupPickerItem(label: string, groupId: number) {
    Text(label)
      .fontSize(14)
      .fontColor(this.primaryTextColor())
      .width('100%')
      .height(38)
      .padding({ left: 12, right: 12 })
      .borderRadius(8)
      .backgroundColor(this.glassCardColor())
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .onClick(() => this.assignSelectedBooksToGroup(groupId))
  }

  @Builder
  addBookGroupDialog() {
    Column() {
      Column({ space: 16 }) {
        Text('新增书籍分组').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.primaryTextColor())
        TextInput({ placeholder: '输入分组名称', text: this.newBookGroupName })
          .width('100%').height(42).backgroundColor(this.inputColor()).fontColor(this.primaryTextColor())
          .borderRadius(10).onChange((value: string) => this.newBookGroupName = value)
        Row({ space: 12 }) {
          Button('取消', { type: ButtonType.Normal }).layoutWeight(1).height(42).borderRadius(10)
            .backgroundColor(this.glassCardColor()).fontColor(this.primaryTextColor())
            .onClick(() => this.showAddBookGroupDialog = false)
          Button('新增', { type: ButtonType.Normal }).layoutWeight(1).height(42).borderRadius(10)
            .backgroundColor(this.buttonColor()).fontColor('#FFFFFF').enabled(!!this.newBookGroupName.trim())
            .onClick(() => this.addShelfBookGroup())
        }.width('100%')
      }
      .width('85%').padding(22)
      .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
      .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
      .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
      .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .backgroundColor('#80000000')
  }

  @Builder
  bookGroupActionMenu() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%').height('100%')
        .backgroundColor(this.appDarkMode ? '#52000000' : '#26FFFFFF')
        .backdropBlur(ThemeRuntime.glassBlur('popover', 18))
        .onClick(() => this.closeBookGroupActionMenu())
      Column() {
        this.contextActionItem($r('sys.symbol.square_and_pencil'), '重命名', this.primaryTextColor(), () => {
            this.renameBookGroupName = this.pendingBookGroup?.groupName || '';
            this.showBookGroupActionMenu = false;
            this.showRenameBookGroupDialog = true;
          })
        this.contextActionItem($r('sys.symbol.trash'), '删除', '#E53935', () => {
            this.pendingDeleteBookGroup = this.pendingBookGroup;
            this.showBookGroupActionMenu = false;
            this.showDeleteBookGroupDialog = true;
          })
      }
      .width(148).padding({ top: 6, bottom: 6 })
      .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
      .borderRadius(ThemeRuntime.glassCornerRadius(14, 'panel')).backdropBlur(ThemeRuntime.glassBlur('panel', 22))
      .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'panel') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'panel'), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
      .position({ x: this.contextMenuLeft(148), y: this.contextMenuTop(100) })
    }
    .width('100%').height('100%')
  }

  @Builder
  renameBookGroupDialog() {
    Column() {
      Column({ space: 16 }) {
        Text('重命名分组').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.primaryTextColor())
        TextInput({ placeholder: '输入分组名称', text: this.renameBookGroupName })
          .width('100%').height(42).backgroundColor(this.inputColor()).fontColor(this.primaryTextColor())
          .borderRadius(10).onChange((value: string) => this.renameBookGroupName = value)
        Row({ space: 12 }) {
          Button('取消', { type: ButtonType.Normal }).layoutWeight(1).height(42).borderRadius(10)
            .backgroundColor(this.glassCardColor()).fontColor(this.primaryTextColor())
            .onClick(() => this.closeRenameBookGroupDialog())
          Button('保存', { type: ButtonType.Normal }).layoutWeight(1).height(42).borderRadius(10)
            .backgroundColor(this.buttonColor()).fontColor('#FFFFFF').enabled(!!this.renameBookGroupName.trim())
            .onClick(() => this.renameShelfBookGroup())
        }.width('100%')
      }
      .width('85%').padding(22)
      .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
      .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
      .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
      .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .backgroundColor('#80000000')
  }

  @Builder
  deleteBookGroupDialog() {
    Column() {
      Column({ space: 16 }) {
        Text('删除分组').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.primaryTextColor())
        Text(`删除“${this.pendingDeleteBookGroup?.groupName || ''}”后，分组内书籍将移到未分组。`)
          .fontSize(14).fontColor(this.secondaryTextColor()).textAlign(TextAlign.Center)
        Row({ space: 12 }) {
          Button('取消', { type: ButtonType.Normal }).layoutWeight(1).height(42).borderRadius(10)
            .backgroundColor(this.glassCardColor()).fontColor(this.primaryTextColor())
            .onClick(() => this.closeDeleteBookGroupDialog())
          Button('删除', { type: ButtonType.Normal }).layoutWeight(1).height(42).borderRadius(10)
            .backgroundColor('#E53935').fontColor('#FFFFFF').onClick(() => this.deleteShelfBookGroup())
        }.width('100%')
      }
      .width('85%').padding(22)
      .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
      .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
      .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
      .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .backgroundColor('#80000000')
  }

  @Builder
  batchDeleteBooksDialog() {
    Column() {
      Column({ space: 16 }) {
        Text('批量删除').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.primaryTextColor())
        Text(`确定从书架移除选中的 ${this.selectedBookUrls.length} 本书吗？`)
          .fontSize(14).fontColor(this.secondaryTextColor()).textAlign(TextAlign.Center)
        Row({ space: 12 }) {
          Button('取消', { type: ButtonType.Normal }).layoutWeight(1).height(42).borderRadius(10)
            .backgroundColor(this.glassCardColor()).fontColor(this.primaryTextColor())
            .onClick(() => this.showBatchDeleteDialog = false)
          Button('删除', { type: ButtonType.Normal }).layoutWeight(1).height(42).borderRadius(10)
            .backgroundColor('#E53935').fontColor('#FFFFFF').onClick(() => this.deleteSelectedBooks())
        }.width('100%')
      }
      .width('85%').padding(22)
      .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
      .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
      .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
      .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .backgroundColor('#80000000')
  }

  selectShelfGroup(groupId: number): void {
    if (this.activeShelfGroupId === groupId) {
      this.applyShelfScope();
      return;
    }
    if (this.shelfScopeSwitchAnimating) {
      return;
    }
    if (this.isTileLayout()) {
      this.activeShelfGroupId = groupId;
      return;
    }
    const currentIndex = this.shelfGroupOrderIndex(this.activeShelfGroupId);
    const nextIndex = this.shelfGroupOrderIndex(groupId);
    const outgoingX = nextIndex >= currentIndex ? -36 : 36;
    this.animateShelfContentUpdate(() => {
      this.activeShelfGroupId = groupId;
    }, outgoingX);
  }

  shelfGroupOrderIndex(groupId: number): number {
    if (groupId === 0) {
      return 0;
    }
    if (groupId === -1) {
      return this.shelfGroups.length + 1;
    }
    const index = this.shelfGroups.findIndex((group: BookGroup) => group.groupId === groupId);
    return index >= 0 ? index + 1 : 0;
  }

  isTileGroupPage(): boolean {
    return this.isTileLayout() && this.activeShelfGroupId > 0;
  }

  activeShelfGroupName(): string {
    const group = this.shelfGroups.find((item: BookGroup) => item.groupId === this.activeShelfGroupId);
    return group ? group.groupName : '书籍分组';
  }

  enterTileGroupPage(groupId: number): void {
    this.showShelfScopeOptions = false;
    this.showShelfGroups = false;
    this.showShelfSortMenu = false;
    this.showShelfLayoutMenu = false;
    this.selectShelfGroup(groupId);
  }

  exitTileGroupPage(): void {
    this.showShelfScopeOptions = false;
    this.showShelfGroups = false;
    this.showShelfSortMenu = false;
    this.selectShelfGroup(0);
  }

  enterBookMultiSelect(initialBookUrl: string): void {
    this.isBookMultiSelect = true;
    this.showShelfScopeOptions = false;
    this.selectedBookUrls = initialBookUrl ? [initialBookUrl] : [];
    this.showShelfSortMenu = false;
    this.showShelfLayoutMenu = false;
    this.showShelfGroups = false;
  }

  exitBookMultiSelect(): void {
    this.isBookMultiSelect = false;
    this.selectedBookUrls = [];
    this.showBookGroupPicker = false;
    this.groupPickerSingleBookUrl = '';
    this.showBatchDeleteDialog = false;
  }

  closeBookGroupPicker(): void {
    this.showBookGroupPicker = false;
    this.groupPickerSingleBookUrl = '';
  }

  toggleSelectedBook(bookUrl: string): void {
    this.setBookSelected(bookUrl, !this.isBookSelected(bookUrl));
  }

  isBookSelected(bookUrl: string): boolean {
    return this.selectedBookUrls.includes(bookUrl);
  }

  setBookSelected(bookUrl: string, selected: boolean): void {
    if (selected) {
      if (!this.isBookSelected(bookUrl)) {
        this.selectedBookUrls = this.selectedBookUrls.concat([bookUrl]);
      }
      return;
    }
    this.selectedBookUrls = this.selectedBookUrls.filter((url: string) => url !== bookUrl);
  }

  areAllBooksSelected(): boolean {
    return this.books.length > 0 && this.books.every((book: Book) => this.isBookSelected(book.bookUrl));
  }

  toggleAllBooks(): void {
    if (this.areAllBooksSelected()) {
      const visibleUrls = this.books.map((book: Book) => book.bookUrl);
      this.selectedBookUrls = this.selectedBookUrls.filter((url: string) => !visibleUrls.includes(url));
      return;
    }
    this.selectedBookUrls = this.books.map((book: Book) => book.bookUrl);
  }

  async addShelfBookGroup(): Promise<void> {
    const name = this.newBookGroupName.trim();
    if (!name) return;
    const db = AppDatabase.getInstance();
    const group = await db.addBookGroup(name);
    if (!group) {
      promptAction.showToast({ message: '分组名称已存在' });
      return;
    }
    this.showAddBookGroupDialog = false;
    this.newBookGroupName = '';
    this.shelfGroups = await db.getCustomBookGroups();
    this.selectShelfGroup(group.groupId);
  }

  closeBookGroupActionMenu(): void {
    this.showBookGroupActionMenu = false;
    this.pendingBookGroup = null;
  }

  closeRenameBookGroupDialog(): void {
    this.showRenameBookGroupDialog = false;
    this.renameBookGroupName = '';
    this.pendingBookGroup = null;
  }

  async renameShelfBookGroup(): Promise<void> {
    const group = this.pendingBookGroup;
    const name = this.renameBookGroupName.trim();
    if (!group || !name) return;
    const renamed = await AppDatabase.getInstance().renameBookGroup(group.groupId, name);
    if (!renamed) {
      promptAction.showToast({ message: '分组名称已存在' });
      return;
    }
    this.closeRenameBookGroupDialog();
    await this.loadBooks();
    promptAction.showToast({ message: '分组已重命名' });
  }

  closeDeleteBookGroupDialog(): void {
    this.showDeleteBookGroupDialog = false;
    this.pendingDeleteBookGroup = null;
    this.pendingBookGroup = null;
  }

  async deleteShelfBookGroup(): Promise<void> {
    const group = this.pendingDeleteBookGroup;
    if (!group) return;
    const db = AppDatabase.getInstance();
    await db.deleteBookGroup(group.groupId);
    if (this.activeShelfGroupId === group.groupId) this.activeShelfGroupId = -1;
    this.closeDeleteBookGroupDialog();
    await this.loadBooks();
    promptAction.showToast({ message: '分组已删除，书籍已移到未分组' });
  }

  async assignSelectedBooksToGroup(groupId: number): Promise<void> {
    const singleBookUrl = this.groupPickerSingleBookUrl;
    const targetUrls = singleBookUrl ? [singleBookUrl] : [...this.selectedBookUrls];
    if (targetUrls.length === 0) return;
    const count = targetUrls.length;
    const db = AppDatabase.getInstance();
    await db.updateBooksGroup(targetUrls, groupId);
    if (this.isBookMultiSelect) {
      this.exitBookMultiSelect();
    } else {
      this.closeBookGroupPicker();
    }
    await this.loadBooks();
    const groupName = groupId === 0 ? '未分组' :
      (this.shelfGroups.find((group: BookGroup) => group.groupId === groupId)?.groupName || '指定分组');
    promptAction.showToast({
      message: count === 1 ? `已移动到“${groupName}”` : `已将 ${count} 本书移动到“${groupName}”`
    });
  }

  async deleteSelectedBooks(): Promise<void> {
    const urls = [...this.selectedBookUrls];
    const targets = this.allBooks.filter((book: Book) => urls.includes(book.bookUrl));
    const db = AppDatabase.getInstance();
    for (const book of targets) {
      this.deleteBookCoverCache(book);
      LocalBookService.deleteLocalBookFiles(getContext(this), book);
      await db.deleteBook(book.bookUrl);
    }
    this.exitBookMultiSelect();
    AppStorage.setOrCreate('shelfUpdateTime', Date.now());
    await this.loadBooks();
    promptAction.showToast({ message: `已删除 ${targets.length} 本书` });
  }


  bookshelfTopOverlayHeight(): number {
    let height = this.statusBarHeight + 56;
    if (this.isBookMultiSelect) {
      height += 42;
    } else if (this.showShelfGroups) {
      height += 42;
    }
    return height;
  }

  bookshelfTileTopSpacerHeight(): number {
    const gridTopPadding = 10;
    const comfortableGap = 12;
    // Grid 会在顶部占位项与首行之间继续添加 rowsGap，需要从占位高度中抵消。
    return Math.max(0, this.bookshelfTopOverlayHeight() + comfortableGap -
      gridTopPadding - this.shelfTileRowGap());
  }

  bookshelfListBottomInset(): number {
    const comfortableGap = 20;
    const multiSelectBarHeight = this.isBookMultiSelect ? 104 : 0;
    if (deviceInfo.sdkApiVersion < 23) {
      return comfortableGap + multiSelectBarHeight;
    }
    if (this.isBookMultiSelect) {
      return Math.max(this.navBarHeight, 8) + comfortableGap + multiSelectBarHeight;
    }
    const floatingTabHeight = 56;
    return floatingTabHeight + Math.max(this.navBarHeight, 8) + comfortableGap;
  }

  getBookColor(name: string): string {
    if (!name) return '#007DFF';
    const colors = ['#007DFF', '#E53935', '#43A047', '#EF6C00', '#8E24AA', '#00ACC1', '#D81B60', '#5E35B1'];
    let hash = 0;
    for (let i = 0; i < name.length; i++) {
      hash = name.charCodeAt(i) + ((hash << 5) - hash);
    }
    return colors[Math.abs(hash) % colors.length];
  }

  getDisplayTags(book: Book): string[] {
    const tags = BookDisplayHelper.getBookTags(book);
    return tags;
  }

  getAuthorAndUpdateText(book: Book): string {
    const author = book.author || '作者未知';
    const updateText = BookDisplayHelper.getLastUpdateText(book);
    return updateText ? `${author} · 最后更新 ${updateText}` : author;
  }

  isCompactLayout(): boolean {
    return this.bookshelfLayoutMode !== 'loose';
  }

  isTileLayout(): boolean {
    return this.bookshelfLayoutMode === 'tile';
  }

  shouldUseTileGroupFolders(): boolean {
    return this.isTileLayout() && this.activeShelfGroupId === 0 && !this.isBookMultiSelect;
  }

  getUngroupedTileBooks(): Book[] {
    return this.books.filter((book: Book) => book.group <= 0 ||
      !this.shelfGroups.some((group: BookGroup) => group.groupId === book.group));
  }

  getLatestReadTileBook(): Book | null {
    let latest: Book | null = null;
    let latestReadTime = 0;
    this.booksForShelfScope(this.shelfScope).forEach((book: Book) => {
      const readTime = this.getBookReadTime(book);
      if (readTime > latestReadTime) {
        latest = book;
        latestReadTime = readTime;
      }
    });
    return latest;
  }

  getLatestReadTileBooks(): Book[] {
    const latest = this.getLatestReadTileBook();
    return latest ? [latest] : [];
  }

  shouldShowLatestExpandedTileBook(): boolean {
    return this.isTileLayout() && this.activeShelfGroupId === 0 && !this.isBookMultiSelect;
  }

  getTileBooksWithoutLatest(books: Book[]): Book[] {
    if (!this.shouldShowLatestExpandedTileBook()) {
      return books;
    }
    const latestBookUrl = this.getLatestReadTileBook()?.bookUrl || '';
    return latestBookUrl ? books.filter((book: Book) => book.bookUrl !== latestBookUrl) : books;
  }

  getTileFolderGroups(books: Book[] = this.books): BookGroup[] {
    const visibleGroupIds = new Set<number>();
    books.forEach((book: Book) => {
      if (book.group > 0) {
        visibleGroupIds.add(book.group);
      }
    });
    return this.shelfGroups.filter((group: BookGroup) => visibleGroupIds.has(group.groupId));
  }

  getSortedTileRootEntries(books: Book[] = this.books, mode: string = this.sortMode): ShelfTileSortEntry[] {
    const cacheKey = `${mode}_${this.shelfScope}_${this.activeShelfGroupId}_${this.isBookMultiSelect ? '1' : '0'}_` +
      `${books.map((book: Book) => `${book.bookUrl}:${book.name}:${this.getBookReadTime(book)}:${this.getBookAddTime(book)}:` +
        `${book.group}`).join('|')}_` +
      `${this.shelfGroups.map((group: BookGroup) => `${group.groupId}:${group.groupName}`).join('|')}`;
    if (cacheKey === this.shelfTileEntriesCacheKey) {
      return this.shelfTileEntriesCache;
    }
    const entries: ShelfTileSortEntry[] = [];
    const ungroupedBooks = this.getTileBooksWithoutLatest(books.filter((book: Book) => book.group <= 0 ||
      !this.shelfGroups.some((group: BookGroup) => group.groupId === book.group)));
    ungroupedBooks.forEach((book: Book, index: number) => {
      const entry = new ShelfTileSortEntry();
      entry.kind = 'book';
      entry.key = `book_${this.shelfScope}_${book.bookUrl}`;
      entry.book = book;
      entry.readTime = this.getBookReadTime(book);
      entry.addTime = this.getBookAddTime(book);
      entry.name = this.normalizeBookName(book.name);
      entry.originalOrder = index;
      entries.push(entry);
    });

    const bookOffset = ungroupedBooks.length;
    this.getTileFolderGroups(books).forEach((group: BookGroup, index: number) => {
      const groupBooks = books.filter((book: Book) => book.group === group.groupId);
      const entry = new ShelfTileSortEntry();
      entry.kind = 'group';
      entry.key = `group_${this.shelfScope}_${group.groupId}`;
      entry.group = group;
      entry.readTime = this.latestTileGroupReadTime(groupBooks);
      entry.addTime = this.latestTileGroupAddTime(groupBooks);
      entry.name = this.normalizeBookName(group.groupName);
      entry.originalOrder = bookOffset + index;
      entries.push(entry);
    });

    entries.sort((a: ShelfTileSortEntry, b: ShelfTileSortEntry) => this.compareTileRootEntry(a, b, mode));
    this.shelfTileEntriesCacheKey = cacheKey;
    this.shelfTileEntriesCache = entries;
    return entries;
  }

  shelfListBookDataSource(): ShelfBookDataSource {
    this.shelfListBooksSource.replace(this.books);
    return this.shelfListBooksSource;
  }

  shelfTileBookDataSource(): ShelfBookDataSource {
    this.shelfTileBooksSource.replace(this.getTileBooksWithoutLatest(this.books));
    return this.shelfTileBooksSource;
  }

  shelfTileEntryDataSource(): ShelfTileEntryDataSource {
    this.shelfTileEntriesSource.replace(this.getSortedTileRootEntries());
    return this.shelfTileEntriesSource;
  }

  latestTileGroupReadTime(books: Book[]): number {
    let latest = 0;
    books.forEach((book: Book) => {
      latest = Math.max(latest, this.getBookReadTime(book));
    });
    return latest;
  }

  latestTileGroupAddTime(books: Book[]): number {
    let latest = 0;
    books.forEach((book: Book) => {
      latest = Math.max(latest, this.getBookAddTime(book));
    });
    return latest;
  }

  compareTileRootEntry(a: ShelfTileSortEntry, b: ShelfTileSortEntry, mode: string = this.sortMode): number {
    if (mode === 'name') {
      const nameDiff = a.name.localeCompare(b.name, 'zh-Hans-CN-u-co-pinyin');
      return nameDiff !== 0 ? nameDiff : a.originalOrder - b.originalOrder;
    }
    const timeDiff = mode === 'recentAdd' ? b.addTime - a.addTime : b.readTime - a.readTime;
    if (timeDiff !== 0) {
      return timeDiff;
    }
    const nameDiff = a.name.localeCompare(b.name, 'zh-Hans-CN-u-co-pinyin');
    return nameDiff !== 0 ? nameDiff : a.originalOrder - b.originalOrder;
  }

  getTileGroupBooks(groupId: number): Book[] {
    return this.books.filter((book: Book) => book.group === groupId);
  }

  getTileGroupPreviewBooks(groupId: number): Book[] {
    return this.getTileGroupBooks(groupId).slice(0, 4);
  }

  shelfTileColumnCount(): number {
    const horizontalPadding = 40;
    const targetCoverWidth = 104;
    const preferredColumnGap = 20;
    const contentWidth = Math.max(1, this.shelfTileViewportWidth - horizontalPadding);
    // 以当前手机端约 104vp 的封面宽度为视觉基准，展开屏增加列数而不是放大封面。
    const fittedCount = Math.round(
      (contentWidth + preferredColumnGap) / (targetCoverWidth + preferredColumnGap)
    );
    return Math.max(3, Math.min(24, fittedCount));
  }

  shelfTileColumnsTemplate(): string {
    const columnCount = this.shelfTileColumnCount();
    let template = '1fr';
    for (let index = 1; index < columnCount; index++) {
      template += ' 1fr';
    }
    return template;
  }

  shelfTileColumnGap(): number {
    const horizontalPadding = 40;
    const targetCoverWidth = 104;
    const columnCount = this.shelfTileColumnCount();
    const contentWidth = Math.max(1, this.shelfTileViewportWidth - horizontalPadding);
    const fittedGap = columnCount > 1 ?
      (contentWidth - targetCoverWidth * columnCount) / (columnCount - 1) : 20;
    // 只在原 20vp 附近微调间距，避免宽屏上书籍过散或挤在一起。
    return Math.max(16, Math.min(24, fittedGap));
  }

  shelfTileRowGap(): number {
    return Math.max(24, Math.min(30, this.shelfTileColumnGap() + 8));
  }

  shelfTileExpandedCoverAspectRatio(): number {
    const columnCount = this.shelfTileColumnCount();
    const horizontalPadding = 40;
    const columnGap = this.shelfTileColumnGap();
    const contentWidth = Math.max(1, this.shelfTileViewportWidth - horizontalPadding);
    const columnWidth = Math.max(1, (contentWidth - columnGap * (columnCount - 1)) / columnCount);
    const expandedWidth = columnWidth * 2 + columnGap;
    // 普通封面的宽高比为 0.735；跨两列后根据实际列宽换算，确保上下边缘完全对齐。
    return expandedWidth * 0.735 / columnWidth;
  }

  @Builder
  shelfTileGrid() {
    Grid() {
      GridItem() {
        Row()
          .height(this.bookshelfTileTopSpacerHeight())
      }
      .columnStart(0)
      .columnEnd(this.shelfTileColumnCount() - 1)

      if (this.shouldShowLatestExpandedTileBook()) {
        ForEach(this.getLatestReadTileBooks(), (book: Book) => {
        GridItem() {
          this.shelfTileExpandedBook(book)
        }
        .columnStart(0)
        .columnEnd(1)
        }, (book: Book) => this.shelfBookRenderKey(book, `expanded_${this.shelfScope}`))
      }

      if (this.shouldUseTileGroupFolders()) {
        LazyForEach(this.shelfTileEntryDataSource(), (entry: ShelfTileSortEntry) => {
          GridItem() {
            if (entry.kind === 'group' && entry.group) {
              this.shelfTileGroupFolder(entry.group)
            } else if (entry.book) {
              this.shelfTileBook(entry.book)
            }
          }
        }, (entry: ShelfTileSortEntry) => entry.book ?
          this.shelfBookRenderKey(entry.book, entry.key) : entry.key)
      } else {
        LazyForEach(this.shelfTileBookDataSource(), (book: Book) => {
          GridItem() {
            this.shelfTileBook(book)
          }
        }, (book: Book) => this.shelfBookRenderKey(book, `tile_${this.shelfScope}`))
      }

      GridItem() {
        Column()
          .height(this.bookshelfListBottomInset())
      }
      .columnStart(0)
      .columnEnd(this.shelfTileColumnCount() - 1)
    }
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .width('100%')
    .height('100%')
    .columnsTemplate(this.shelfTileColumnsTemplate())
    .columnsGap(this.shelfTileColumnGap())
    .rowsGap(this.shelfTileRowGap())
    .padding({ left: 20, right: 20, top: 10 })
    .backgroundColor(this.pageColor())
    .scrollBar(BarState.Off)
    .cachedCount(4)
    .translate({ x: this.tileGroupTransitionX })
    .scale({ x: this.tileGroupTransitionScale, y: this.tileGroupTransitionScale })
    .opacity(this.tileGroupTransitionOpacity)
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const width = this.areaDimension(newValue.width);
      if (width > 0 && Math.abs(width - this.shelfTileViewportWidth) >= 1) {
        this.shelfTileViewportWidth = width;
      }
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder
  shelfTileExpandedBook(book: Book) {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        Row({ space: 2 }) {
          Stack() {
            this.coverView(book, '100%', '100%', ImageFit.Fill)
          }
          .layoutWeight(1)
          .height('100%')
          .borderRadius({ topLeft: 7, bottomLeft: 7 })
          .clip(true)

          Column() {
            this.shelfLastReadLeaf(book)
          }
          .layoutWeight(1)
          .height('100%')
          .padding({ left: 7, right: 7, top: 7, bottom: 6 })
          .backgroundColor(this.shelfTilePageColor())
          .borderRadius({ topRight: 7, bottomRight: 7 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .border({ width: ThemeRuntime.glassBorderWidth(), color: this.glassBorderColor() })
        .borderRadius(7)
        .shadow({ radius: ThemeRuntime.glassShadowRadius(), color: this.glassShadowColor(), offsetX: ThemeRuntime.glassShadowOffsetX(), offsetY: ThemeRuntime.glassShadowOffsetY() })
        .clip(true)

        if (this.isBookMultiSelect) {
          Stack({ alignContent: Alignment.Center }) {
            if (this.isBookSelected(book.bookUrl)) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(12)
                .fontColor(['#FFFFFF'])
            }
          }
          .width(22)
          .height(22)
          .backgroundColor(this.isBookSelected(book.bookUrl) ? this.buttonColor() :
            ThemeRuntime.glassPanelColor(this.appDarkMode))
          .border({ width: 1, color: this.isBookSelected(book.bookUrl) ? this.buttonColor() : this.glassBorderColor() })
          .borderRadius(11)
          .margin({ left: 6, top: 6 })
        }
      }
      .width('100%')
      .aspectRatio(this.shelfTileExpandedCoverAspectRatio())
      .border({ width: this.isBookSelected(book.bookUrl) ? 2 : 0, color: this.accentColor() })
      .borderRadius(7)

      Row({ space: 4 }) {
        this.bookTypeNameBadge(book, true)
        Text(this.shelfTileBookDisplayName(book))
          .fontSize(12)
          .lineHeight(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .height(18)
      .alignItems(VerticalAlign.Center)

      Row({ space: 5 }) {
        SymbolGlyph($r('sys.symbol.checkmark_circle'))
          .fontSize(13)
          .fontColor([this.subTextColor()])
        Text(this.bookshelfShowProgressBar ? this.getReadProgressPercentText(book) : this.getShelfProgressText(book))
          .fontSize(11)
          .fontColor(this.subTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .height(18)
      .alignItems(VerticalAlign.Center)

      if (this.bookshelfShowProgressBar) {
        Progress({ value: this.getReadProgressValue(book), total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(3)
          .color(this.accentColor())
          .backgroundColor(this.appDarkMode ? '#2D3138' : '#E8EAED')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .priorityGesture(
      GestureGroup(GestureMode.Exclusive,
        LongPressGesture({ repeat: false })
          .onAction((event: GestureEvent) => {
            if (!this.isBookMultiSelect) {
              this.showBookActions(book, event);
            }
          }),
        TapGesture()
          .onAction((event: GestureEvent) => {
            if (this.consumeShelfSwipeClick()) {
              return;
            }
            if (this.isBookMultiSelect) {
              this.toggleSelectedBook(book.bookUrl);
              return;
            }
            const finger = event.fingerList.length > 0 ? event.fingerList[0] : undefined;
            this.openShelfBook(book, finger ? finger.globalX : this.contextViewportWidth / 2,
              finger ? finger.globalY : this.contextViewportHeight / 2);
          })
      ),
      GestureMask.IgnoreInternal
    )
  }

  @Builder
  shelfTileGroupFolder(group: BookGroup) {
    Column({ space: 4 }) {
      if (this.shouldUseThemeBookCover()) {
        Stack() {
          Image(this.activeThemeShelfFolder())
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Fill)
        }
        .width('100%')
        .aspectRatio(0.735)
        .borderRadius(7)
        .clip(true)
      } else {
        Grid() {
          ForEach(this.getTileGroupPreviewBooks(group.groupId), (book: Book) => {
            GridItem() {
              this.coverView(book, '100%', '100%', ImageFit.Cover)
            }
          }, (book: Book) => this.shelfBookRenderKey(book, `group_${group.groupId}`))
        }
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .width('100%')
        .aspectRatio(0.735)
        .columnsTemplate('1fr 1fr')
        .rowsTemplate('1fr 1fr')
        .columnsGap(6)
        .rowsGap(6)
        .padding(8)
        .borderRadius(7)
        .backgroundColor(this.glassCardColor())
        .border({ width: ThemeRuntime.glassBorderWidth(), color: this.glassBorderColor() })
        .scrollBar(BarState.Off)
      }

      Text(group.groupName)
        .width('100%')
        .height(30)
        .fontSize(14)
        .lineHeight(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor())
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Row({ space: 5 }) {
        SymbolGlyph($r('sys.symbol.folder'))
          .fontSize(13)
          .fontColor([this.subTextColor()])
        Text(`共 ${this.getTileGroupBooks(group.groupId).length} 本`)
          .fontSize(11)
          .fontColor(this.subTextColor())
      }
      .width('100%')
      .height(13)
      .alignItems(VerticalAlign.Bottom)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .priorityGesture(
      GestureGroup(GestureMode.Exclusive,
        LongPressGesture({ repeat: false })
          .onAction((event: GestureEvent) => {
            this.captureContextMenuAnchor(event);
            this.pendingBookGroup = group;
            this.showBookGroupActionMenu = true;
          }),
        TapGesture()
          .onAction(() => {
            this.enterTileGroupPage(group.groupId);
          })
      ),
      GestureMask.IgnoreInternal
    )
  }

  @Builder
  shelfTileBook(book: Book) {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        this.coverView(book, '100%', '100%', ImageFit.Cover)

        if (this.isBookMultiSelect) {
          Stack({ alignContent: Alignment.Center }) {
            if (this.isBookSelected(book.bookUrl)) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(12)
                .fontColor(['#FFFFFF'])
            }
          }
            .width(22)
            .height(22)
            .backgroundColor(this.isBookSelected(book.bookUrl) ? this.buttonColor() :
              ThemeRuntime.glassPanelColor(this.appDarkMode))
            .border({ width: 1, color: this.isBookSelected(book.bookUrl) ? this.buttonColor() : this.glassBorderColor() })
            .borderRadius(11)
            .margin({ left: 6, top: 6 })
        }

        if (this.shouldShowBookSource(book)) {
          Text(this.getBookSourceText(book))
            .fontSize(10)
            .fontColor(this.sourceTagTextColor())
            .padding({ left: 6, right: 6, top: 3, bottom: 3 })
            .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode))
            .borderRadius(8)
            .position({ x: '100%', y: 0 })
            .translate({ x: -58, y: 7 })
            .constraintSize({ maxWidth: 52 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .aspectRatio(0.735)
      .border({
        width: this.isBookSelected(book.bookUrl) ? 2 : 0,
        color: this.accentColor()
      })
      .borderRadius(7)

      Row({ space: 4 }) {
        this.bookTypeNameBadge(book, true)
        Text(this.shelfTileBookDisplayName(book))
          .fontSize(12)
          .lineHeight(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .height(18)
      .alignItems(VerticalAlign.Center)

      Row({ space: 5 }) {
        SymbolGlyph($r('sys.symbol.checkmark_circle'))
          .fontSize(13)
          .fontColor([this.subTextColor()])
        Text(this.bookshelfShowProgressBar ? this.getReadProgressPercentText(book) : this.getShelfProgressText(book))
          .fontSize(11)
          .fontColor(this.subTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .height(18)
      .alignItems(VerticalAlign.Center)

      if (this.bookshelfShowProgressBar) {
        Progress({ value: this.getReadProgressValue(book), total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(3)
          .color(this.accentColor())
          .backgroundColor(this.appDarkMode ? '#2D3138' : '#E8EAED')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .priorityGesture(
      GestureGroup(GestureMode.Exclusive,
        LongPressGesture({ repeat: false })
          .onAction((event: GestureEvent) => {
            if (!this.isBookMultiSelect) {
              this.showBookActions(book, event);
            }
          }),
        TapGesture()
          .onAction((event: GestureEvent) => {
            if (this.consumeShelfSwipeClick()) {
              return;
            }
            if (this.isBookMultiSelect) {
              this.toggleSelectedBook(book.bookUrl);
              return;
            }
            const finger = event.fingerList.length > 0 ? event.fingerList[0] : undefined;
            this.openShelfBook(book, finger ? finger.globalX : this.contextViewportWidth / 2,
              finger ? finger.globalY : this.contextViewportHeight / 2);
          })
      ),
      GestureMask.IgnoreInternal
    )
  }

  openShelfBook(book: Book, touchX: number, touchY: number): void {
    if (this.openingBook) {
      return;
    }
    const centerX = this.contextViewportWidth / 2;
    const centerY = this.contextViewportHeight / 2;
    this.openingBookOriginX = touchX - centerX;
    this.openingBookOriginY = touchY - centerY;
    this.openingBookScale = 0.28;
    this.openingBookTranslateX = this.openingBookOriginX;
    this.openingBookTranslateY = this.openingBookOriginY;
    this.openingBookOpacity = 0;
    this.openingBookBackdropOpacity = 0;
    this.openingBookCoverAngle = 0;
    this.openingBook = book;

    this.openingBookGrowTimer = setTimeout(() => {
      this.openingBookGrowTimer = -1;
      animateTo({ duration: 260, curve: Curve.Friction }, () => {
        this.openingBookScale = 1;
        this.openingBookTranslateX = 0;
        this.openingBookTranslateY = 0;
        this.openingBookOpacity = 1;
        this.openingBookBackdropOpacity = 0.82;
      });
    }, 16);

    this.openingBookTurnTimer = setTimeout(() => {
      this.openingBookTurnTimer = -1;
      animateTo({ duration: 330, curve: Curve.EaseInOut }, () => {
        this.openingBookScale = 1.08;
        this.openingBookCoverAngle = -118;
        this.openingBookBackdropOpacity = 1;
      });
    }, 210);

    this.openingBookRouteTimer = setTimeout(() => {
      this.openingBookRouteTimer = -1;
      router.pushUrl({
        url: 'pages/ReadBook',
        params: { bookUrl: book.bookUrl, shelfBookOpening: 'true' }
      }).catch((error: Error) => {
        console.error('打开阅读页失败:', error);
        this.cancelShelfBookOpening();
      });
    }, 560);
  }

  closeShelfBook(bookUrl: string): void {
    const targetBook = this.openingBook && this.openingBook.bookUrl === bookUrl ? this.openingBook :
      this.allBooks.find((book: Book) => book.bookUrl === bookUrl);
    if (!targetBook) {
      this.cancelShelfBookOpening();
      return;
    }
    this.clearShelfBookAnimationTimers();
    this.openingBook = targetBook;
    this.openingBookScale = 1.08;
    this.openingBookTranslateX = 0;
    this.openingBookTranslateY = 0;
    this.openingBookOpacity = 1;
    this.openingBookBackdropOpacity = 1;
    this.openingBookCoverAngle = -118;

    this.openingBookTurnTimer = setTimeout(() => {
      this.openingBookTurnTimer = -1;
      animateTo({ duration: 280, curve: Curve.EaseInOut }, () => {
        this.openingBookScale = 1;
        this.openingBookCoverAngle = 0;
        this.openingBookBackdropOpacity = 0.82;
      });
    }, 80);

    this.openingBookGrowTimer = setTimeout(() => {
      this.openingBookGrowTimer = -1;
      animateTo({ duration: 250, curve: Curve.Friction }, () => {
        this.openingBookScale = 0.28;
        this.openingBookTranslateX = this.openingBookOriginX;
        this.openingBookTranslateY = this.openingBookOriginY;
        this.openingBookOpacity = 0;
        this.openingBookBackdropOpacity = 0;
      });
    }, 320);

    this.openingBookRouteTimer = setTimeout(() => {
      this.openingBookRouteTimer = -1;
      this.cancelShelfBookOpening();
    }, 600);
  }

  clearShelfBookAnimationTimers(): void {
    if (this.openingBookGrowTimer >= 0) {
      clearTimeout(this.openingBookGrowTimer);
      this.openingBookGrowTimer = -1;
    }
    if (this.openingBookTurnTimer >= 0) {
      clearTimeout(this.openingBookTurnTimer);
      this.openingBookTurnTimer = -1;
    }
    if (this.openingBookRouteTimer >= 0) {
      clearTimeout(this.openingBookRouteTimer);
      this.openingBookRouteTimer = -1;
    }
  }

  cancelShelfBookOpening(): void {
    this.clearShelfBookAnimationTimers();
    this.openingBook = null;
    this.openingBookScale = 0.28;
    this.openingBookTranslateX = 0;
    this.openingBookTranslateY = 0;
    this.openingBookOpacity = 0;
    this.openingBookBackdropOpacity = 0;
    this.openingBookCoverAngle = 0;
    this.openingBookOriginX = 0;
    this.openingBookOriginY = 0;
  }

  openingBookWidth(): number {
    return Math.min(228, Math.max(184, this.contextViewportWidth * 0.58));
  }

  openingBookHeight(): number {
    return this.openingBookWidth() / 0.735;
  }

  @Builder
  shelfBookOpeningOverlay(book: Book) {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.pageColor())
        .opacity(this.openingBookBackdropOpacity)

      Stack({ alignContent: Alignment.Center }) {
        Column() {
          Text(book.name)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.primaryTextColor())
            .maxLines(2)
            .textAlign(TextAlign.Center)
            .margin({ left: 22, right: 22, top: 34, bottom: 28 })

          ForEach([0, 1, 2, 3, 4, 5, 6], (_line: number) => {
            Divider()
              .width('72%')
              .color(this.appDarkMode ? '#24FFFFFF' : '#18000000')
              .margin({ bottom: 17 })
          })
        }
        .width(this.openingBookWidth())
        .height(this.openingBookHeight())
        .backgroundColor(this.inputColor())
        .borderRadius(8)
        .border({ width: ThemeRuntime.glassBorderWidth(), color: this.glassBorderColor() })
        .shadow({ radius: 24, color: this.appDarkMode ? '#90000000' : '#38000000', offsetX: 8, offsetY: 10 })

        Stack({ alignContent: Alignment.Center }) {
          this.coverView(book, '100%', '100%', ImageFit.Cover)

          Column()
            .width(8)
            .height('100%')
            .linearGradient({
              angle: 0,
              colors: [[this.appDarkMode ? '#66000000' : '#44000000', 0], ['#00000000', 1]]
            })
            .position({ x: 0, y: 0 })
        }
        .width(this.openingBookWidth())
        .height(this.openingBookHeight())
        .borderRadius(8)
        .rotate({
          x: 0,
          y: 1,
          z: 0,
          angle: this.openingBookCoverAngle,
          centerX: 0,
          centerY: '50%',
          perspective: 900
        })
        .shadow({ radius: 20, color: '#55000000', offsetX: 5, offsetY: 8 })
      }
      .width(this.openingBookWidth())
      .height(this.openingBookHeight())
      .clip(false)
      .scale({ x: this.openingBookScale, y: this.openingBookScale })
      .translate({ x: this.openingBookTranslateX, y: this.openingBookTranslateY })
      .opacity(this.openingBookOpacity)
    }
    .width('100%')
    .height('100%')
    .zIndex(100)
    .hitTestBehavior(HitTestMode.Block)
  }

  @Builder
  compactBookContent(book: Book) {
    Column({ space: 8 }) {
      Row() {
        this.coverView(book, 56, 72, ImageFit.Cover)

        Column({ space: 4 }) {
          Row({ space: 6 }) {
            this.bookTypeNameBadge(book, true)
            Text(this.shelfTileBookDisplayName(book))
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            if (this.shouldShowBookSource(book)) {
              Text(this.getBookSourceText(book))
                .fontSize(11)
                .fontColor(this.sourceTagTextColor())
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor(this.sourceTagBackgroundColor())
                .borderRadius(4)
                .margin({ left: 8 })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 104 })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(this.getAuthorAndUpdateText(book))
            .fontSize(14)
            .fontColor(this.secondaryTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          if (this.bookshelfShowProgressBar) {
            Blank()
            this.readProgressPanel(book)
          } else {
            Row() {
              Text(this.getShelfProgressText(book))
                .fontSize(12)
                .fontColor(this.subTextColor())
            }
          }
        }
        .layoutWeight(1)
        .height(72)
        .margin({ left: 12 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      this.bookExtraContent(book)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
  }

  @Builder
  looseBookContent(book: Book) {
    Column({ space: 8 }) {
      Row() {
        this.coverView(book, 56, 72, ImageFit.Cover)

        Column({ space: 4 }) {
          Row({ space: 6 }) {
            this.bookTypeNameBadge(book, true)
            Text(this.shelfTileBookDisplayName(book))
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(this.getAuthorAndUpdateText(book))
            .fontSize(14)
            .fontColor(this.secondaryTextColor())

          Row() {
            if (this.shouldShowBookSource(book)) {
              Text(this.getBookSourceText(book))
                .fontSize(12)
                .fontColor(this.sourceTagTextColor())
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                .backgroundColor(this.sourceTagBackgroundColor())
                .borderRadius(4)
                .margin({ right: 8 })
            }

            Text(this.getShelfProgressText(book))
              .fontSize(12)
              .fontColor(this.subTextColor())
          }
        }
        .layoutWeight(1)
        .margin({ left: 12 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      this.bookExtraContent(book)

      if (this.bookshelfShowProgressBar) {
        this.looseReadProgressPanel(book)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
  }

  @Builder
  bookExtraContent(book: Book) {
    if (this.bookshelfShowIntro && this.getBookIntroText(book)) {
      Text(this.getBookIntroText(book))
        .fontSize(12)
        .fontColor(this.subTextColor())
        .lineHeight(18)
        .maxLines(LocalBookService.isLocalBook(book) ? 2 : (this.bookshelfShowFullIntro ? 999 : 2))
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxHeight: LocalBookService.isLocalBook(book) ? 36 : 10000 })
        .clip(true)
        .width('100%')
    }

    if (this.bookshelfShowTags && this.getDisplayTags(book).length > 0) {
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(this.getDisplayTags(book), (tag: string, index: number) => {
          this.tagChip(tag, index, 11)
        })
      }
      .width('100%')
    }
  }

  shouldShowBookSource(book: Book): boolean {
    return this.bookshelfShowSource && book.origin !== 'local' && this.getBookSourceText(book).length > 0;
  }

  getBookSourceText(book: Book): string {
    return (book.originName || book.origin || '').trim();
  }

  getBookIntroText(book: Book): string {
    const rawIntro = LocalBookService.isLocalBook(book) ? book.intro : book.getDisplayIntro();
    const intro = (rawIntro || '')
      .replace(/\s+/g, ' ')
      .trim();
    if (LocalBookService.isLocalBook(book) && intro.length > 52) {
      return `${intro.substring(0, 52).trim()}…`;
    }
    return intro;
  }

  @Builder
  coverView(book: Book, width: Length, height: Length, imageFit: ImageFit) {
    Stack() {
      if (this.shouldUseThemeBookCover()) {
        if (this.activeThemeBookCovers(book).length === 1) {
          Image(this.activeThemeBookCovers(book)[0])
            .width(width)
            .height(height)
            .objectFit(ImageFit.Fill)
        } else {
          Swiper() {
            ForEach(this.activeThemeBookCovers(book), (cover: ResourceStr, index: number) => {
              Image(cover)
                .width(width)
                .height(height)
                .objectFit(ImageFit.Fill)
            }, (_cover: ResourceStr, index: number) => `${book.bookUrl}_theme_${index}`)
          }
          .width(width)
          .height(height)
          .autoPlay(true)
          .interval(this.themeBookCoverInterval(book))
          .indicator(false)
          .loop(true)
        }
        Image(this.activeThemeShelfFrame())
          .width(width)
          .height(height)
          .objectFit(ImageFit.Fill)
      } else if (this.getShelfCoverList(book).length === 0) {
        Column() {
          Text(book.name ? book.name.substring(0, 1) : '书')
            .fontSize(28)
            .fontColor('#FFFFFF')
        }
        .width(width)
        .height(height)
        .backgroundColor(this.getBookColor(book.name))
        .justifyContent(FlexAlign.Center)
      } else if (this.getShelfCoverList(book).length === 1) {
        Image(this.getShelfCover(book))
          .width(width)
          .height(height)
          .objectFit(imageFit)
      } else {
        Swiper() {
          ForEach(this.getShelfCoverList(book), (cover: string) => {
            Image(cover)
              .width(width)
              .height(height)
              .objectFit(imageFit)
          }, (cover: string) => cover)
        }
        .width(width)
        .height(height)
        .autoPlay(true)
        .interval(3500)
        .indicator(false)
        .loop(true)
      }
    }
    .width(width)
    .height(height)
    .borderRadius(6)
    .clip(true)
    .backgroundColor(this.inputColor())
    .onAppear(() => this.ensureShelfBookCoverCache(book))
  }

  @Builder
  bookTypeNameBadge(book: Book, compact: boolean = false) {
    if (this.bookshelfShowTypeBadge) {
      Text(this.bookTypeBadgeText(book))
        .fontSize(compact ? 8 : 9)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .textAlign(TextAlign.Center)
        .width(compact ? 16 : 18)
        .height(compact ? 14 : 16)
        .borderRadius(compact ? 4 : 5)
        .backgroundColor(this.bookTypeBadgeColor(book))
    }
  }

  bookTypeBadgeText(book: Book): string {
    if (BookTypeSupport.isAudio(book)) return '声';
    if (BookTypeSupport.isImage(book)) return '漫';
    return '书';
  }

  bookTypeBadgeColor(book: Book): string {
    if (BookTypeSupport.isAudio(book)) return '#D9822B';
    if (BookTypeSupport.isImage(book)) return '#8B5CF6';
    return '#3978C5';
  }

  activeThemeBookCovers(book: Book): ResourceStr[] {
    const covers = ThemeAssetRegistry.themeBookCovers(ThemeRuntime.bookTokens(this.appDarkMode).coverAssetId);
    if (covers.length <= 1) return covers;
    const result: ResourceStr[] = [];
    const seed = this.themeBookCoverSeed(book);
    const start = seed % covers.length;
    const direction = seed % 2 === 0 ? 1 : covers.length - 1;
    for (let index = 0; index < covers.length; index++) {
      result.push(covers[(start + index * direction) % covers.length]);
    }
    return result;
  }

  shouldUseThemeBookCover(): boolean {
    return this.themeBookCoverEnabled &&
      ThemeAssetRegistry.themeBookCovers(ThemeRuntime.bookTokens(this.appDarkMode).coverAssetId).length > 0;
  }

  themeBookCoverSeed(book: Book): number {
    const key = `${book.bookUrl}|${book.name}|${book.author}`;
    let hash = 17;
    for (let index = 0; index < key.length; index++) {
      hash = (hash * 31 + key.charCodeAt(index)) & 0x7FFFFFFF;
    }
    return hash;
  }

  themeBookCoverInterval(book: Book): number {
    return 3200 + this.themeBookCoverSeed(book) % 5 * 420;
  }

  activeThemeShelfFrame(): ResourceStr {
    return ThemeAssetRegistry.themeShelfFrame(ThemeRuntime.bookTokens(this.appDarkMode).shelfFrameAssetId);
  }

  activeThemeShelfFolder(): ResourceStr {
    return ThemeAssetRegistry.themeShelfFolder(ThemeRuntime.bookTokens(this.appDarkMode).shelfFolderAssetId);
  }

  getShelfCover(book: Book): string {
    const covers = this.getShelfCoverList(book);
    return covers.length > 0 ? BookDisplayHelper.pickCover(covers) : '';
  }

  getShelfCoverList(book: Book): string[] {
    const covers = CoverGallerySettings.getDisplayCoverList(
      book,
      this.appDarkMode,
      this.bookshelfCoverAlbums,
      this.bookshelfLightCoverAlbumId,
      this.bookshelfDarkCoverAlbumId,
      this.bookshelfCoverApplyScope,
      this.bookshelfCoverTargetBooks,
      this.bookshelfIgnoreSourceCover,
      this.bookshelfCoverMode
    );
    const displayCovers: string[] = [];
    for (let i = 0; i < covers.length; i++) {
      const raw = covers[i];
      const key = this.shelfCoverKey(book, i);
      const cached = this.shelfCoverRawUrls.get(key) === raw ? (this.shelfCoverMap.get(key) || '') : '';
      displayCovers.push(cached || raw);
    }
    return displayCovers;
  }

  shelfCoverKey(book: Book, index: number): string {
    return `${book.bookUrl}#${index}`;
  }

  @Builder
  tagChip(tag: string, index: number, fontSize: number) {
    Text(tag)
      .fontSize(fontSize)
      .fontColor(BookDisplayHelper.getTagTextColor(index, this.appDarkMode))
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .backgroundColor(BookDisplayHelper.getTagBackgroundColor(index, this.appDarkMode))
      .borderRadius(12)
      .margin({ left: 4, bottom: 6 })
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
  }

  @Builder
  actionItem(label: string, color: string, action: () => void) {
    Button(label)
      .width('100%')
      .height(44)
      .margin({ top: 6 })
      .backgroundColor(this.appDarkMode ? '#24272D' : '#F5F5F5')
      .fontColor(color)
      .onClick(action)
  }

  @Builder
  contextActionItem(icon: Resource, label: string, color: string, action: () => void) {
    Row({ space: 10 }) {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([color])
        .width(24)
      Text(label)
        .fontSize(15)
        .fontColor(color)
        .layoutWeight(1)
    }
    .width('100%')
    .height(44)
    .padding({ left: 12, right: 12 })
    .alignItems(VerticalAlign.Center)
    .onClick(action)
  }

  actionSheetBottomMargin(): number {
    return 82 + (this.navBarHeight > 0 ? this.navBarHeight : 0);
  }

  bookGroupPickerBottomMargin(): number {
    return 68 + Math.max(this.navBarHeight, 8);
  }

  multiSelectBottomPadding(): number {
    return Math.max(this.navBarHeight, 8) + 6;
  }

  addEditingTag(): void {
    const tag = this.tagInput.trim();
    if (!tag || this.editingTags.includes(tag)) {
      this.tagInput = '';
      return;
    }
    this.editingTags = [...this.editingTags, tag];
    this.tagInput = '';
  }

  removeEditingTag(tag: string): void {
    this.editingTags = this.editingTags.filter(item => item !== tag);
  }

  async saveCustomTags(): Promise<void> {
    if (!this.pendingActionBook) return;
    this.addEditingTag();
    const book = this.pendingActionBook;
    const sourceTags = BookDisplayHelper.splitTags(book.kind, '');
    const customTags = this.editingTags.filter(tag => !sourceTags.includes(tag));
    const hiddenTags = sourceTags
      .filter(tag => !this.editingTags.includes(tag))
      .map(tag => `!${tag}`);
    book.customTag = BookDisplayHelper.joinTags([...customTags, ...hiddenTags]);
    await this.updateShelfBook(book);
    this.showTagDialog = false;
    this.pendingActionBook = null;
    promptAction.showToast({ message: '标签已保存' });
  }

  closeEditBookInfoDialog(): void {
    this.showEditBookInfoDialog = false;
    this.editingBookName = '';
    this.editingBookAuthor = '';
    this.pendingActionBook = null;
  }

  async saveLocalBookInfo(): Promise<void> {
    const target = this.pendingActionBook;
    const name = this.editingBookName.trim();
    const author = this.editingBookAuthor.trim();
    if (!target || !LocalBookService.isLocalBook(target)) {
      this.closeEditBookInfoDialog();
      return;
    }
    if (!name) {
      promptAction.showToast({ message: '书名不能为空' });
      return;
    }
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      const book = await db.getBook(target.bookUrl);
      if (!book || !LocalBookService.isLocalBook(book)) {
        promptAction.showToast({ message: '书籍已不在书架中' });
        this.closeEditBookInfoDialog();
        return;
      }
      book.name = name;
      book.author = author;
      book.putVariable('localMetadataCustomized', '1');
      book.putVariable('localCustomName', name);
      book.putVariable('localCustomAuthor', author);
      await db.updateBook(book);
      await db.updateBookBookmarkMetadata(book.bookUrl, name, author);
      this.allBooks = this.allBooks.map((item: Book) => item.bookUrl === book.bookUrl ? book : item);
      this.applyShelfScope();
      this.closeEditBookInfoDialog();
      AppStorage.setOrCreate('shelfUpdateTime', Date.now());
      promptAction.showToast({ message: '书籍信息已保存' });
    } catch (e) {
      console.error('保存本地书籍信息失败:', e);
      promptAction.showToast({ message: '保存失败' });
    }
  }

  async openCacheDialog(book: Book): Promise<void> {
    this.cacheTargetBook = book;
    this.cacheChapters = [];
    this.cacheStatus = this.isBookCaching(book) ? this.currentFullTextCacheDialogStatus(book) : '正在加载目录...';
    this.cacheDialogOpenedAt = Date.now();
    this.showCacheDialog = true;
    if (!this.isBookCaching(book)) {
      this.loadCacheChapters(book);
    }
  }

  applyShelfScope(): void {
    this.books = this.sortBooks(this.booksForShelfScope(this.shelfScope));
    if (this.books.length === 0) {
      this.showShelfSortMenu = false;
    }
  }

  shelfScopeEmptyHint(): string {
    if (this.shelfScope === 'local') {
      return '请在书架设置中添加本地书籍';
    }
    if (this.shelfScope === 'network') {
      return '搜索并加入喜欢的书籍吧';
    }
    return '搜索书籍或添加本地书籍吧';
  }

  booksForShelfScope(scope: string): Book[] {
    return this.allBooks.filter((book: Book) => {
      const isLocal = LocalBookService.isLocalBook(book);
      const scopeMatches = scope === 'all' || (scope === 'local' ? isLocal : !isLocal);
      const groupMatches = this.activeShelfGroupId === 0 ||
        (this.activeShelfGroupId === -1 ? book.group <= 0 : book.group === this.activeShelfGroupId);
      return scopeMatches && groupMatches;
    });
  }

  setShelfScope(scope: string): void {
    const next = scope === 'local' ? 'local' : (scope === 'network' ? 'network' : 'all');
    this.showShelfScopeOptions = false;
    if (this.shelfScope === next) return;
    this.shelfScope = next;
    this.showShelfSortMenu = false;
    this.showShelfLayoutMenu = false;
    this.applyShelfScope();
    this.shelfTileEntriesCacheKey = '';
    this.shelfTileEntriesCache = [];
    this.shelfListBooksSource.replace(this.books, true);
    this.shelfTileBooksSource.replace(this.getTileBooksWithoutLatest(this.books), true);
    this.shelfTileEntriesSource.replace(this.getSortedTileRootEntries(this.books), true);
    this.refreshShelfCoverCache(this.books);
  }

  switchShelfScopeBySwipe(offsetX: number): void {
    this.markShelfScopePanGesture(160);
    if (this.isBookMultiSelect || this.isTileGroupPage() || this.shelfScopeSwitchAnimating ||
      Math.abs(offsetX) < 56) {
      return;
    }
    const scopes: string[] = ['all', 'network', 'local'];
    const currentIndex = scopes.indexOf(this.shelfScope);
    const nextIndex = offsetX < 0 ? currentIndex + 1 : currentIndex - 1;
    if (currentIndex < 0 || nextIndex < 0 || nextIndex >= scopes.length) {
      return;
    }
    this.animateShelfScopeSwitch(scopes[nextIndex], offsetX < 0 ? -1 : 1);
  }

  markShelfScopePanGesture(durationMs: number): void {
    this.suppressShelfBookClickUntil = Date.now() + durationMs;
  }

  consumeShelfSwipeClick(): boolean {
    if (Date.now() > this.suppressShelfBookClickUntil) {
      this.suppressShelfBookClickUntil = 0;
      return false;
    }
    this.suppressShelfBookClickUntil = 0;
    return true;
  }

  switchShelfScopeBySelection(scope: string): void {
    if (this.shelfScopeSwitchAnimating) {
      return;
    }
    const scopes: string[] = ['all', 'network', 'local'];
    const currentIndex = scopes.indexOf(this.shelfScope);
    const nextIndex = scopes.indexOf(scope);
    this.showShelfScopeOptions = false;
    if (currentIndex < 0 || nextIndex < 0 || currentIndex === nextIndex) {
      return;
    }
    this.animateShelfScopeSwitch(scope, nextIndex > currentIndex ? -1 : 1);
  }

  animateShelfScopeSwitch(scope: string, outgoingDirection: number): void {
    this.clearShelfScopeTransition(false);
    this.shelfScopeSwitchAnimating = true;
    animateTo({ duration: 130, curve: Curve.EaseIn }, () => {
      this.shelfScopeTransitionX = outgoingDirection * 48;
      this.shelfScopeTransitionScale = 0.985;
      this.shelfScopeTransitionOpacity = 0.12;
    });
    this.shelfScopeSwapTimer = setTimeout(() => {
      this.shelfScopeSwapTimer = -1;
      this.setShelfScope(scope);
      this.shelfScopeTransitionX = outgoingDirection * -48;
      this.shelfScopeTransitionScale = 0.985;
      this.shelfScopeTransitionOpacity = 0.12;
      animateTo({ duration: 230, curve: Curve.Friction }, () => {
        this.shelfScopeTransitionX = 0;
        this.shelfScopeTransitionScale = 1;
        this.shelfScopeTransitionOpacity = 1;
      });
      this.shelfScopeFinishTimer = setTimeout(() => {
        this.shelfScopeFinishTimer = -1;
        this.shelfScopeSwitchAnimating = false;
      }, 250);
    }, 135);
  }

  animateShelfContentUpdate(update: () => void, outgoingX: number): void {
    this.clearShelfScopeTransition(false);
    this.shelfScopeSwitchAnimating = true;
    animateTo({ duration: 110, curve: Curve.EaseIn }, () => {
      this.shelfScopeTransitionX = outgoingX;
      this.shelfScopeTransitionScale = 0.988;
      this.shelfScopeTransitionOpacity = 0.16;
    });
    this.shelfScopeSwapTimer = setTimeout(() => {
      this.shelfScopeSwapTimer = -1;
      update();
      this.shelfScopeTransitionX = -outgoingX;
      this.shelfScopeTransitionScale = 0.988;
      this.shelfScopeTransitionOpacity = 0.16;
      animateTo({ duration: 210, curve: Curve.Friction }, () => {
        this.shelfScopeTransitionX = 0;
        this.shelfScopeTransitionScale = 1;
        this.shelfScopeTransitionOpacity = 1;
      });
      this.shelfScopeFinishTimer = setTimeout(() => {
        this.shelfScopeFinishTimer = -1;
        this.shelfScopeSwitchAnimating = false;
      }, 230);
    }, 115);
  }

  clearShelfScopeTransition(resetVisuals: boolean = true): void {
    if (this.shelfScopeSwapTimer >= 0) {
      clearTimeout(this.shelfScopeSwapTimer);
      this.shelfScopeSwapTimer = -1;
    }
    if (this.shelfScopeFinishTimer >= 0) {
      clearTimeout(this.shelfScopeFinishTimer);
      this.shelfScopeFinishTimer = -1;
    }
    this.shelfScopeSwitchAnimating = false;
    if (resetVisuals) {
      this.shelfScopeTransitionX = 0;
      this.shelfScopeTransitionScale = 1;
      this.shelfScopeTransitionOpacity = 1;
    }
  }

  closeCacheDialog(resetCaching: boolean = true): void {
    this.showCacheDialog = false;
    this.showChapterCacheDialog = false;
    this.cacheTargetBook = null;
    this.cacheChapters = [];
    this.cacheStatus = '';
    this.isCacheTocLoading = false;
    this.cacheTocLoadToken++;
    this.cacheTocLoadBookUrl = '';
    this.cacheTocLoadPromise = null;
    this.pendingActionBook = null;
  }

  isCacheTargetBookCaching(): boolean {
    return this.isBookCaching(this.cacheTargetBook);
  }

  isBookCaching(book: Book | null): boolean {
    const bookUrl = book?.bookUrl || '';
    return !!bookUrl && this.fullTextCacheTasks.has(bookUrl);
  }

  currentFullTextCacheDialogStatus(book: Book): string {
    const task = this.getShelfFullTextCacheTask(book.bookUrl);
    if (task) {
      return task.status || this.shelfFullTextCacheProgressText(task);
    }
    return '正在加载目录...';
  }

  setFullTextCacheStatus(task: ShelfFullTextCacheTask, status: string): void {
    task.status = status;
    if (this.cacheTargetBook?.bookUrl && this.cacheTargetBook.bookUrl === task.bookUrl) {
      this.cacheStatus = status;
    }
  }

  onFullTextCacheCancelNonceChanged(): void {
    const nonce = this.fullTextCacheCancelNonce || 0;
    if (!this.isCaching || nonce <= 0) {
      return;
    }
    const signal = this.parseFullTextCacheCancelSignal();
    if (signal) {
      const task = this.findShelfFullTextCacheTaskBySignal(signal);
      if (!task || task.cancelSeenNonce === signal.nonce) {
        return;
      }
      task.cancelRequested = true;
      task.cancelSeenNonce = signal.nonce;
      promptAction.showToast({ message: '缓存已停止' });
      return;
    }
    let stopped = false;
    this.fullTextCacheTasks.forEach((task: ShelfFullTextCacheTask) => {
      if (task.cancelSeenNonce !== nonce) {
        task.cancelRequested = true;
        task.cancelSeenNonce = nonce;
        stopped = true;
      }
    });
    if (stopped) {
      promptAction.showToast({ message: '缓存已停止' });
    }
  }

  onFullTextCacheCancelSignalChanged(): void {
    const signal = this.parseFullTextCacheCancelSignal();
    if (!signal || !this.isCaching) {
      return;
    }
    const task = this.findShelfFullTextCacheTaskBySignal(signal);
    if (!task || task.cancelSeenNonce === signal.nonce) {
      return;
    }
    task.cancelRequested = true;
    task.cancelSeenNonce = signal.nonce;
    promptAction.showToast({ message: '缓存已停止' });
  }

  async loadCacheChapters(book: Book, forceRefresh: boolean = false): Promise<boolean> {
    if (!book.bookUrl) {
      this.cacheStatus = '书籍地址为空';
      return false;
    }
    if (!forceRefresh && this.cacheTocLoadPromise && this.cacheTocLoadBookUrl === book.bookUrl) {
      return await this.cacheTocLoadPromise;
    }
    if (!forceRefresh && this.cacheTargetBook?.bookUrl === book.bookUrl && this.cacheChapters.length > 0) {
      return true;
    }
    const token = ++this.cacheTocLoadToken;
    this.cacheTocLoadBookUrl = book.bookUrl;
    this.isCacheTocLoading = true;
    if (this.cacheChapters.length === 0) {
      this.cacheStatus = '正在加载目录...';
    }
    const task = this.loadCacheChaptersInternal(book, token);
    this.cacheTocLoadPromise = task;
    try {
      return await task;
    } finally {
      if (token === this.cacheTocLoadToken) {
        this.isCacheTocLoading = false;
        this.cacheTocLoadPromise = null;
      }
    }
  }

  async loadCacheChaptersInternal(book: Book, token: number): Promise<boolean> {
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      const engine = ReadBookEngine.get();
      await engine.openBook(book);
      await engine.syncChapterCacheDates();
      if (token !== this.cacheTocLoadToken || this.cacheTargetBook?.bookUrl !== book.bookUrl) {
        return false;
      }
      const chapters = [...engine.chapters];
      this.cacheChapters = chapters;
      if (chapters.length > 0) {
        const cachedCount = this.countCachedChapters(chapters);
        this.cacheStatus = `${cachedCount}章已缓存 ${chapters.length - cachedCount}章待缓存`;
      } else {
        this.cacheStatus = '暂未获取到目录';
      }
      return chapters.length > 0;
    } catch (e) {
      console.error('加载缓存目录失败:', e);
      if (token === this.cacheTocLoadToken && this.cacheTargetBook?.bookUrl === book.bookUrl) {
        this.cacheStatus = '目录加载失败，请稍后重试';
        promptAction.showToast({ message: '目录加载失败' });
      }
      return false;
    }
  }

  async cacheWholeBook(): Promise<void> {
    if (!this.cacheTargetBook || this.isCacheTargetBookCaching()) {
      return;
    }
    if (Date.now() - this.cacheDialogOpenedAt < 300) {
      return;
    }
    const book = this.cacheTargetBook;
    if (!book.origin || book.origin === 'local') {
      promptAction.showToast({ message: '本地书籍无需缓存' });
      return;
    }
    this.closeCacheDialog();
    promptAction.showToast({ message: '已转入后台缓存，可在通知栏取消' });
    const task = this.createShelfFullTextCacheTask(book, ++this.fullTextCacheTaskId);
    this.runShelfFullTextCache(book, task).catch((error: Error) => {
      console.error('书架全文缓存任务失败:', error);
      this.setFullTextCacheStatus(task, '全文缓存失败');
      promptAction.showToast({ message: '全文缓存失败' });
      this.publishShelfFullTextCacheNotification(task, '全文缓存失败', this.shelfFullTextCacheProgressText(task), false)
        .catch((e: Error) => {
          console.warn('更新书架缓存失败通知失败:', e);
        });
      this.finishShelfFullTextCacheTask(task);
      this.stopShelfFullTextCacheBackgroundRunning().catch((e: Error) => {
        console.warn('停止书架全文缓存后台任务失败:', e);
      });
    });
  }

  async runShelfFullTextCache(book: Book, task: ShelfFullTextCacheTask): Promise<void> {
    this.registerShelfFullTextCacheTask(task);
    this.setFullTextCacheStatus(task, '全文缓存后台进行中');
    try {
      await this.startShelfFullTextCacheBackgroundRunning(book);
      await this.refreshFullTextCacheCover(book, task);
      if (await this.prepareShelfFullTextCacheNotification()) {
        await this.publishShelfFullTextCacheNotification(task, '准备缓存章节',
          this.shelfFullTextCacheProgressText(task), true);
      }
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      const freshBook = await db.getBook(book.bookUrl) || book;
      const engine = ReadBookEngine.createBackgroundWorker();
      await engine.openBook(freshBook);
      await engine.syncChapterCacheDates();
      if (!this.isShelfFullTextCacheTaskActive(task)) {
        return;
      }
      const total = engine.chapters.length;
      task.total = total;
      task.done = this.countCachedChapters(engine.chapters);
      if (total === 0) {
        this.setFullTextCacheStatus(task, '暂无可缓存章节');
        await this.publishShelfFullTextCacheNotification(task, '暂无可缓存章节',
          this.shelfFullTextCacheProgressText(task), false);
        return;
      }

      await this.publishShelfFullTextCacheProgress(task, true);

      for (let i = 0; i < total; i++) {
        if (!this.isShelfFullTextCacheTaskActive(task) || this.shouldCancelShelfFullTextCache(task)) {
          break;
        }
        const chapter = engine.chapters[i];
        if (!chapter || chapter.cacheDate > 0) {
          continue;
        }
        this.setFullTextCacheStatus(task, `正在缓存 ${i + 1}/${total}`);
        try {
          if (await engine.cacheChapter(i)) {
            task.done = this.countCachedChapters(engine.chapters);
          }
        } catch (e) {
          console.error('缓存章节失败:', i, e);
        }
        await this.publishShelfFullTextCacheProgress(task, false);
        await this.sleep(0);
      }

      if (!this.isShelfFullTextCacheTaskActive(task)) {
        return;
      }
      const canceled = this.shouldCancelShelfFullTextCache(task);
      await engine.syncChapterCacheDates();
      task.done = this.countCachedChapters(engine.chapters);
      this.setFullTextCacheStatus(task, canceled ? '全文缓存已取消' : `缓存完成：${task.done}/${total}`);
      await this.publishShelfFullTextCacheNotification(
        task,
        canceled ? '缓存已停止' : '全文缓存完成',
        this.shelfFullTextCacheProgressText(task),
        false
      );
      promptAction.showToast({ message: canceled ? '缓存已停止' : `缓存完成 ${task.done}/${total}` });
      AppStorage.setOrCreate('shelfUpdateTime', Date.now());
    } finally {
      this.finishShelfFullTextCacheTask(task);
      await this.stopShelfFullTextCacheBackgroundRunning();
    }
  }

  createShelfFullTextCacheTask(book: Book, taskId: number): ShelfFullTextCacheTask {
    const bookUrl = book.bookUrl || '';
    return {
      taskId: taskId,
      bookUrl: bookUrl,
      bookName: book.name || '书籍',
      taskKey: this.buildFullTextCacheTaskKey(book, taskId),
      createdAt: Date.now(),
      cancelRequested: false,
      cancelSeenNonce: AppStorage.get<number>('fullTextCacheCancelNonce') || 0,
      notificationLastAt: 0,
      cancelAgent: null,
      done: 0,
      total: 0,
      status: '',
      coverPixelMap: null,
      notificationFailureHintShown: false
    };
  }

  registerShelfFullTextCacheTask(task: ShelfFullTextCacheTask): void {
    this.fullTextCacheTasks.set(task.bookUrl, task);
    this.syncShelfFullTextCacheTaskState();
  }

  async ensureShelfFullTextCacheCancelSubscriber(): Promise<void> {
    if (this.fullTextCacheCancelSubscriber) {
      return;
    }
    try {
      const subscriber = await commonEventManager.createSubscriber({
        events: [SHELF_FULL_TEXT_CACHE_CANCEL_EVENT]
      });
      this.fullTextCacheCancelSubscriber = subscriber;
      commonEventManager.subscribe(subscriber, (error: Error | null, data: commonEventManager.CommonEventData) => {
        if (error) {
          console.warn('接收书架缓存取消事件失败:', error);
          return;
        }
        this.handleShelfFullTextCacheCancelEvent(data);
      });
    } catch (error) {
      console.warn('注册书架缓存取消事件失败:', error);
    }
  }

  releaseShelfFullTextCacheCancelSubscriber(): void {
    if (!this.fullTextCacheCancelSubscriber) {
      return;
    }
    const subscriber = this.fullTextCacheCancelSubscriber;
    this.fullTextCacheCancelSubscriber = null;
    commonEventManager.unsubscribe(subscriber, (error: Error | null) => {
      if (error) {
        console.warn('注销书架缓存取消事件失败:', error);
      }
    });
  }

  handleShelfFullTextCacheCancelEvent(data: commonEventManager.CommonEventData): void {
    const params = data.parameters || {};
    const taskKey = typeof params['cacheTaskKey'] === 'string' ? params['cacheTaskKey'] as string : '';
    const bookUrl = typeof params['bookUrl'] === 'string' ? params['bookUrl'] as string : '';
    this.requestShelfFullTextCacheCancel({
      nonce: Date.now(),
      taskKey: taskKey,
      bookUrl: bookUrl
    });
  }

  finishShelfFullTextCacheTask(task: ShelfFullTextCacheTask): void {
    const current = this.fullTextCacheTasks.get(task.bookUrl);
    if (current && current.taskKey === task.taskKey) {
      this.fullTextCacheTasks.delete(task.bookUrl);
    }
    task.cancelRequested = false;
    this.releaseFullTextCacheCover(task);
    this.syncShelfFullTextCacheTaskState();
  }

  syncShelfFullTextCacheTaskState(): void {
    this.activeFullTextCacheBookUrls = Array.from(this.fullTextCacheTasks.keys());
    this.isCaching = this.activeFullTextCacheBookUrls.length > 0;
  }

  getShelfFullTextCacheTask(bookUrl: string): ShelfFullTextCacheTask | null {
    return bookUrl ? this.fullTextCacheTasks.get(bookUrl) || null : null;
  }

  isShelfFullTextCacheTaskActive(task: ShelfFullTextCacheTask): boolean {
    const current = this.fullTextCacheTasks.get(task.bookUrl);
    return !!current && current.taskKey === task.taskKey;
  }

  findShelfFullTextCacheTaskBySignal(signal: FullTextCacheCancelSignal): ShelfFullTextCacheTask | null {
    if (signal.taskKey) {
      for (const task of this.fullTextCacheTasks.values()) {
        if (task.taskKey === signal.taskKey) {
          return task;
        }
      }
    }
    return signal.bookUrl ? this.getShelfFullTextCacheTask(signal.bookUrl) : null;
  }

  requestShelfFullTextCacheCancel(signal: FullTextCacheCancelSignal): void {
    const task = this.findShelfFullTextCacheTaskBySignal(signal);
    if (!task || task.cancelSeenNonce === signal.nonce) {
      return;
    }
    task.cancelRequested = true;
    task.cancelSeenNonce = signal.nonce;
    AppStorage.setOrCreate('fullTextCacheCancelSignal', JSON.stringify(signal));
    AppStorage.setOrCreate('fullTextCacheCancelNonce', signal.nonce);
    promptAction.showToast({ message: '缓存已停止' });
  }

  shouldCancelShelfFullTextCache(task: ShelfFullTextCacheTask): boolean {
    if (task.cancelRequested) {
      return true;
    }
    const nonce = AppStorage.get<number>('fullTextCacheCancelNonce') || 0;
    if (nonce > 0 && nonce !== task.cancelSeenNonce) {
      const signal = this.parseFullTextCacheCancelSignal();
      if (signal && !this.isCurrentFullTextCacheSignal(task, signal)) {
        task.cancelSeenNonce = signal.nonce;
        return false;
      }
      if (!signal || this.isCurrentFullTextCacheSignal(task, signal)) {
        task.cancelRequested = true;
        task.cancelSeenNonce = signal ? signal.nonce : nonce;
        return true;
      }
    }
    return false;
  }

  parseFullTextCacheCancelSignal(): FullTextCacheCancelSignal | null {
    const raw = this.fullTextCacheCancelSignal || AppStorage.get<string>('fullTextCacheCancelSignal') || '';
    if (!raw.trim()) {
      return null;
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const signal: FullTextCacheCancelSignal = {
        nonce: typeof parsed['nonce'] === 'number' ? parsed['nonce'] as number : 0,
        taskKey: typeof parsed['taskKey'] === 'string' ? parsed['taskKey'] as string : '',
        bookUrl: typeof parsed['bookUrl'] === 'string' ? parsed['bookUrl'] as string : ''
      };
      return signal.nonce > 0 ? signal : null;
    } catch (e) {
      return null;
    }
  }

  isCurrentFullTextCacheSignal(task: ShelfFullTextCacheTask, signal: FullTextCacheCancelSignal): boolean {
    if (signal.taskKey && task.taskKey && signal.taskKey === task.taskKey) {
      return true;
    }
    return !!signal.bookUrl && signal.bookUrl === task.bookUrl;
  }

  countCachedChapters(chapters: BookChapter[]): number {
    let count = 0;
    for (const chapter of chapters) {
      if (chapter.cacheDate > 0) {
        count++;
      }
    }
    return count;
  }

  shelfFullTextCacheProgressText(task: ShelfFullTextCacheTask): string {
    const total = Math.max(task.total, 0);
    if (total === 0) {
      return '正在准备缓存章节（0%）';
    }
    const done = Math.max(0, Math.min(task.done, total));
    const percent = Math.floor((done / total) * 100);
    return `已缓存 ${done}/${total} 章（${percent}%）`;
  }

  shelfFullTextCacheNotificationTitle(task: ShelfFullTextCacheTask): string {
    return `缓存全文：${task.bookName || '书籍'}`;
  }

  shelfFullTextCacheDisplayText(text: string, additionalText: string, ongoing: boolean): string {
    if (!ongoing || !additionalText || text.includes(additionalText)) {
      return text;
    }
    return `${text} · ${additionalText}`;
  }

  shelfFullTextCacheNormalContent(task: ShelfFullTextCacheTask, text: string, additionalText: string,
    ongoing: boolean): notificationManager.NotificationBasicContent {
    const normalContent: notificationManager.NotificationBasicContent = {
      title: this.shelfFullTextCacheNotificationTitle(task),
      text: this.shelfFullTextCacheDisplayText(text, additionalText, ongoing),
      additionalText: additionalText
    };
    if (task.coverPixelMap) {
      normalContent.lockscreenPicture = task.coverPixelMap;
    }
    return normalContent;
  }

  applyShelfFullTextCacheCoverToRequest(task: ShelfFullTextCacheTask,
    request: notificationManager.NotificationRequest): void {
    if (!task.coverPixelMap) {
      return;
    }
    request.smallIcon = task.coverPixelMap;
    request.largeIcon = task.coverPixelMap;
  }

  async publishShelfFullTextCacheProgress(task: ShelfFullTextCacheTask, force: boolean): Promise<void> {
    const now = Date.now();
    if (!force && now - task.notificationLastAt < SHELF_FULL_TEXT_CACHE_NOTIFICATION_INTERVAL_MS) {
      return;
    }
    task.notificationLastAt = now;
    await this.publishShelfFullTextCacheNotification(task, '全文缓存后台进行中',
      this.shelfFullTextCacheProgressText(task), true);
  }

  async publishShelfFullTextCacheNotification(task: ShelfFullTextCacheTask, text: string, additionalText: string,
    ongoing: boolean): Promise<void> {
    try {
      const request: notificationManager.NotificationRequest = {
        id: this.fullTextCacheNotificationId(task.bookUrl),
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        isOngoing: ongoing,
        tapDismissed: false,
        isAlertOnce: true,
        deliveryTime: task.createdAt,
        showDeliveryTime: false,
        wantAgent: await this.getShelfFullTextCacheOpenWantAgent(task),
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: this.shelfFullTextCacheNormalContent(task, text, additionalText, ongoing)
        }
      };
      if (!ongoing) {
        request.autoDeletedTime = Date.now() + 5000;
      }
      request.label = this.fullTextCacheNotificationLabel(task.bookUrl);
      this.applyShelfFullTextCacheCoverToRequest(task, request);
      if (ongoing) {
        request.actionButtons = [{
          title: '停止缓存',
          wantAgent: await this.getShelfFullTextCacheCancelWantAgent(task)
        }];
      }
      await notificationManager.publish(request);
    } catch (error) {
      console.warn('发布书架全文缓存通知失败:', error);
      try {
        await this.publishBasicShelfFullTextCacheNotification(task, text, additionalText, ongoing);
      } catch (fallbackError) {
        console.warn('发布书架全文缓存基础通知失败:', fallbackError);
        try {
          await this.publishMinimalShelfFullTextCacheNotification(task, text, additionalText, ongoing);
        } catch (minimalError) {
          console.warn('发布书架全文缓存最小通知失败:', minimalError);
          this.showShelfFullTextCacheNotificationFailureHint(task, minimalError);
        }
      }
    }
  }

  async publishBasicShelfFullTextCacheNotification(task: ShelfFullTextCacheTask, text: string, additionalText: string,
    ongoing: boolean): Promise<void> {
    const request: notificationManager.NotificationRequest = {
      id: this.fullTextCacheNotificationId(task.bookUrl),
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      isOngoing: ongoing,
      tapDismissed: false,
      isAlertOnce: true,
      deliveryTime: task.createdAt,
      showDeliveryTime: false,
      wantAgent: await this.getShelfFullTextCacheOpenWantAgent(task),
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: this.shelfFullTextCacheNormalContent(task, text, additionalText, ongoing)
      }
    };
    if (!ongoing) {
      request.autoDeletedTime = Date.now() + 5000;
    }
    request.label = this.fullTextCacheNotificationLabel(task.bookUrl);
    if (ongoing) {
      request.actionButtons = [{
        title: '停止缓存',
        wantAgent: await this.getShelfFullTextCacheCancelWantAgent(task)
      }];
    }
    this.applyShelfFullTextCacheCoverToRequest(task, request);
    await notificationManager.publish(request);
  }

  async publishMinimalShelfFullTextCacheNotification(task: ShelfFullTextCacheTask, text: string, additionalText: string,
    ongoing: boolean): Promise<void> {
    const request: notificationManager.NotificationRequest = {
      id: this.fullTextCacheNotificationId(task.bookUrl),
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      isOngoing: ongoing,
      tapDismissed: false,
      isAlertOnce: true,
      deliveryTime: task.createdAt,
      showDeliveryTime: false,
      wantAgent: await this.getShelfFullTextCacheOpenWantAgent(task),
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: this.shelfFullTextCacheNormalContent(task, text, additionalText, ongoing)
      }
    };
    if (!ongoing) {
      request.autoDeletedTime = Date.now() + 5000;
    }
    request.label = this.fullTextCacheNotificationLabel(task.bookUrl);
    this.applyShelfFullTextCacheCoverToRequest(task, request);
    await notificationManager.publish(request);
  }

  async refreshFullTextCacheCover(book: Book, task: ShelfFullTextCacheTask): Promise<void> {
    this.releaseFullTextCacheCover(task);
    const raw = this.getShelfCover(book);
    if (!raw) {
      return;
    }
    try {
      const coverPath = await BookCoverCache.prepareCoverFile(getContext(this), raw);
      if (!coverPath) {
        return;
      }
      task.coverPixelMap = await this.createFullTextCacheCoverPixelMap(coverPath);
    } catch (error) {
      console.warn('解析缓存通知封面失败:', error);
    }
  }

  async createFullTextCacheCoverPixelMap(path: string): Promise<image.PixelMap | null> {
    let file: fs.File | null = null;
    let source: image.ImageSource | null = null;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      source = image.createImageSource(file.fd);
      return await source.createPixelMap({
        desiredSize: {
          width: 128,
          height: 128
        }
      });
    } catch (error) {
      console.warn('创建缓存通知封面 PixelMap 失败:', error);
      return null;
    } finally {
      if (source) {
        try {
          await source.release();
        } catch (e) {
        }
      }
      if (file) {
        try {
          fs.closeSync(file);
        } catch (e) {
        }
      }
    }
  }

  releaseFullTextCacheCover(task: ShelfFullTextCacheTask): void {
    if (!task.coverPixelMap) {
      return;
    }
    try {
      task.coverPixelMap.release().catch((e: Error) => {
        console.warn('释放缓存通知封面失败:', e);
      });
    } catch (e) {
      console.warn('释放缓存通知封面失败:', e);
    }
    task.coverPixelMap = null;
  }

  async prepareShelfFullTextCacheNotification(): Promise<boolean> {
    try {
      if (!await notificationManager.isNotificationEnabled()) {
        try {
          await notificationManager.requestEnableNotification(getContext(this) as common.UIAbilityContext);
        } catch (error) {
          console.warn('请求通知权限失败:', error);
          promptAction.showToast({ message: '通知权限未开启，缓存仍会继续' });
          return false;
        }
      }
      if (!await notificationManager.isNotificationEnabled()) {
        promptAction.showToast({ message: '通知权限未开启，缓存仍会继续' });
        return false;
      }
      if (!this.fullTextCacheNotificationSlotReady) {
        await notificationManager.addSlot(notificationManager.SlotType.SERVICE_INFORMATION);
        this.fullTextCacheNotificationSlotReady = true;
      }
      return true;
    } catch (error) {
      console.warn('准备书架缓存通知失败:', error);
      this.showShelfFullTextCacheNotificationFailureHint(null, error);
      return false;
    }
  }

  showShelfFullTextCacheNotificationFailureHint(task: ShelfFullTextCacheTask | null, error: Object): void {
    if (task) {
      if (task.notificationFailureHintShown) {
        return;
      }
      task.notificationFailureHintShown = true;
    } else if (this.fullTextCacheNotificationFailureHintShown) {
      return;
    } else {
      this.fullTextCacheNotificationFailureHintShown = true;
    }
    console.warn('书架缓存通知不可用:', error);
    promptAction.showToast({ message: this.shelfFullTextCacheNotificationFailureMessage(error) });
  }

  shelfFullTextCacheNotificationFailureMessage(error: Object): string {
    const code = this.notificationErrorCode(error);
    if (code === 1600004 || code === 1600020) {
      return '通知权限未开启，缓存仍会继续';
    }
    if (code === 1600005) {
      return '通知类别已关闭，请检查应用通知设置';
    }
    if (code === 1600009) {
      return '通知发送过快，缓存仍会继续';
    }
    return code > 0 ? `通知发布失败(${code})` : '通知发布失败，请检查应用通知权限';
  }

  notificationErrorCode(error: Object): number {
    const record = error as Record<string, Object>;
    const code = record['code'];
    return typeof code === 'number' ? code as number : 0;
  }

  async getShelfFullTextCacheCancelWantAgent(task: ShelfFullTextCacheTask): Promise<WantAgent> {
    if (task.cancelAgent) {
      return task.cancelAgent;
    }
    const context = getContext(this) as common.UIAbilityContext;
    task.cancelAgent = await wantAgent.getWantAgent({
      wants: [{
        action: SHELF_FULL_TEXT_CACHE_CANCEL_EVENT,
        parameters: {
          cacheAction: 'cancelFullTextCache',
          cacheTaskId: task.taskId,
          cacheTaskKey: task.taskKey,
          bookUrl: task.bookUrl
        }
      }],
      actionType: wantAgent.OperationType.SEND_COMMON_EVENT,
      requestCode: this.fullTextCacheCancelRequestCode(task.bookUrl),
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    return task.cancelAgent;
  }

  async getShelfFullTextCacheOpenWantAgent(task: ShelfFullTextCacheTask): Promise<WantAgent> {
    const context = getContext(this) as common.UIAbilityContext;
    return await wantAgent.getWantAgent({
      wants: [{
        bundleName: context.abilityInfo.bundleName,
        abilityName: 'EntryAbility',
        parameters: {
          bookUrl: task.bookUrl
        }
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: this.fullTextCacheOpenRequestCode(task.bookUrl),
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
  }

  async startShelfFullTextCacheBackgroundRunning(book: Book): Promise<void> {
    if (this.fullTextCacheBackgroundRunning) {
      return;
    }
    try {
      const agent = await this.createShelfFullTextCacheOpenWantAgent(book);
      await backgroundTaskManager.startBackgroundRunning(getContext(this), ['dataTransfer'], agent);
      this.fullTextCacheBackgroundRunning = true;
    } catch (error) {
      console.warn('启动书架全文缓存后台任务失败:', error);
    }
  }

  async stopShelfFullTextCacheBackgroundRunning(): Promise<void> {
    if (!this.fullTextCacheBackgroundRunning || this.fullTextCacheTasks.size > 0) {
      return;
    }
    this.fullTextCacheBackgroundRunning = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(getContext(this));
    } catch (error) {
      console.warn('停止书架全文缓存后台任务失败:', error);
    }
  }

  async createShelfFullTextCacheOpenWantAgent(book: Book): Promise<WantAgent> {
    const context = getContext(this) as common.UIAbilityContext;
    return await wantAgent.getWantAgent({
      wants: [{
        bundleName: context.abilityInfo.bundleName,
        abilityName: 'EntryAbility',
        parameters: {
          bookUrl: book.bookUrl || ''
        }
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: this.fullTextCacheOpenRequestCode(book.bookUrl || ''),
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
  }

  buildFullTextCacheTaskKey(book: Book, taskId: number): string {
    return `${this.fullTextCacheHash(book.bookUrl || book.name || 'book')}_${taskId}`;
  }

  fullTextCacheNotificationId(bookUrl: string): number {
    return 260100 + (this.fullTextCacheHash(bookUrl || this.fullTextCacheBookName || 'book') % 100000);
  }

  fullTextCacheCancelRequestCode(bookUrl: string): number {
    return 360100 + (this.fullTextCacheHash(bookUrl || this.fullTextCacheBookName || 'book') % 100000);
  }

  fullTextCacheOpenRequestCode(bookUrl: string): number {
    return 460100 + (this.fullTextCacheHash(bookUrl || this.fullTextCacheBookName || 'book') % 100000);
  }

  fullTextCacheNotificationLabel(bookUrl: string): string {
    return `full_text_cache_${this.fullTextCacheHash(bookUrl || this.fullTextCacheBookName || 'book')}`;
  }

  fullTextCacheHash(value: string): number {
    let hash = 0;
    for (let i = 0; i < value.length; i++) {
      hash = ((hash << 5) - hash) + value.charCodeAt(i);
      hash |= 0;
    }
    return Math.abs(hash);
  }

  sleep(ms: number): Promise<void> {
    return new Promise((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  async cacheSingleChapter(index: number): Promise<void> {
    if (!this.cacheTargetBook || this.isCacheTargetBookCaching()) {
      return;
    }
    if (this.isCaching) {
      promptAction.showToast({ message: '其他书籍正在缓存，请稍后再试' });
      return;
    }
    if (this.cacheTargetBook.origin === 'local') {
      promptAction.showToast({ message: '本地书籍无需缓存' });
      return;
    }
    this.activeCacheBookUrl = this.cacheTargetBook.bookUrl || '';
    this.isCaching = true;
    try {
      const engine = ReadBookEngine.get();
      if (engine.book?.bookUrl !== this.cacheTargetBook.bookUrl) {
        await engine.openBook(this.cacheTargetBook);
      }
      const chapter = this.cacheChapters[index];
      this.cacheStatus = chapter ? `正在缓存：${chapter.title}` : '正在缓存章节...';
      const ok = await engine.cacheChapter(index);
      await engine.syncChapterCacheDates();
      this.cacheChapters = [...engine.chapters];
      this.cacheStatus = ok ? '章节已缓存' : '章节缓存失败';
      promptAction.showToast({ message: ok ? '章节已缓存' : '章节缓存失败' });
      AppStorage.setOrCreate('shelfUpdateTime', Date.now());
    } catch (e) {
      console.error('缓存指定章节失败:', e);
      this.cacheStatus = '章节缓存失败';
      promptAction.showToast({ message: '章节缓存失败' });
    } finally {
      if (this.activeCacheBookUrl === (this.cacheTargetBook?.bookUrl || '')) {
        this.activeCacheBookUrl = '';
      }
      this.isCaching = false;
    }
  }

  async clearCachedChapters(): Promise<void> {
    if (!this.cacheTargetBook) {
      return;
    }
    if (this.isCacheTargetBookCaching()) {
      promptAction.showToast({ message: '缓存进行中，稍后再清除' });
      return;
    }
    const book = this.cacheTargetBook;
    if (!book.bookUrl) {
      promptAction.showToast({ message: '书籍地址为空' });
      return;
    }
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      await db.deleteBookCachedContent(book.bookUrl);
      const engine = ReadBookEngine.get();
      if (engine.book?.bookUrl === book.bookUrl) {
        engine.clearCurrentBookMemoryCache();
        await engine.syncChapterCacheDates();
        this.cacheChapters = [...engine.chapters];
      } else {
        for (const chapter of this.cacheChapters) {
          chapter.cacheDate = 0;
        }
        this.cacheChapters = [...this.cacheChapters];
      }
      this.cacheStatus = '已清除缓存章节';
      promptAction.showToast({ message: '已清除缓存章节' });
      AppStorage.setOrCreate('shelfUpdateTime', Date.now());
    } catch (e) {
      console.error('清除缓存章节失败:', e);
      this.cacheStatus = '清除缓存失败';
      promptAction.showToast({ message: '清除缓存失败' });
    }
  }

  async refreshBookshelfToc(): Promise<void> {
    if (this.shelfRefreshRunning) {
      this.shelfRefreshPrompt = '书架刷新中';
      this.isShelfRefreshing = true;
      return;
    }
    if (this.shelfScope === 'local') {
      await this.refreshLocalBooks();
      return;
    }
    if (this.books.length === 0) {
      this.isShelfRefreshing = false;
      return;
    }
    this.shelfRefreshRunning = true;
    this.isShelfRefreshing = true;
    promptAction.showToast({ message: '正在刷新书架...' });
    let attempted = 0;
    let skippedFinished = 0;
    let updated = 0;
    let failed = 0;
    let taskFailed = false;
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      const engine = ReadBookEngine.get();
      const shelfBooks = [...this.books];
      for (const shelfBook of shelfBooks) {
        if (!shelfBook.bookUrl || LocalBookService.isLocalBook(shelfBook) || !shelfBook.canUpdate) {
          continue;
        }
        if (this.isFinishedBook(shelfBook)) {
          skippedFinished++;
          continue;
        }
        attempted++;
        const beforeCount = shelfBook.totalChapterNum;
        const beforeLatest = shelfBook.latestChapterTitle;
        try {
          const freshBook = await db.getBook(shelfBook.bookUrl) || shelfBook;
          await engine.openBook(freshBook);
          await engine.refreshToc();
          const refreshedBook = await db.getBook(shelfBook.bookUrl);
          if (refreshedBook) {
            refreshedBook.lastCheckTime = Date.now();
            refreshedBook.lastCheckCount = engine.chapters.length;
            if (engine.chapters.length > 0) {
              refreshedBook.totalChapterNum = engine.chapters.length;
              refreshedBook.latestChapterTitle = engine.chapters[engine.chapters.length - 1].title;
            }
            await db.updateBook(refreshedBook);
            if (refreshedBook.totalChapterNum > beforeCount || refreshedBook.latestChapterTitle !== beforeLatest) {
              updated++;
            }
          }
        } catch (e) {
          failed++;
          console.error('刷新书架目录失败:', shelfBook.name, e);
        }
      }
      if (attempted > 0) {
        await this.loadBooks();
        const skippedText = skippedFinished > 0 ? `，跳过${skippedFinished}本完结` : '';
        const message = failed > 0 ?
          `书架刷新完成：${updated}本有更新，${failed}本失败${skippedText}` :
          `书架刷新完成：${updated}本有更新${skippedText}`;
        promptAction.showToast({ message });
        AppStorage.setOrCreate('shelfUpdateTime', Date.now());
      }
    } catch (e) {
      taskFailed = true;
      console.error('刷新书架失败:', e);
      promptAction.showToast({ message: '书架刷新失败' });
    } finally {
      this.shelfRefreshRunning = false;
      this.isShelfRefreshing = false;
      this.shelfRefreshPrompt = '下拉刷新书架';
      if (!taskFailed && attempted === 0) {
        const message = skippedFinished > 0 ? `没有可刷新的连载书籍，已跳过${skippedFinished}本完结` : '没有可刷新的网络书籍';
        promptAction.showToast({ message });
      }
    }
  }

  async refreshLocalBooks(): Promise<void> {
    this.shelfRefreshRunning = true;
    this.isShelfRefreshing = true;
    this.shelfRefreshPrompt = '正在刷新本地书籍...';
    try {
      await this.loadBooks();
      promptAction.showToast({ message: '本地书架已刷新' });
      AppStorage.setOrCreate('shelfUpdateTime', Date.now());
    } catch (e) {
      console.error('刷新本地书籍失败:', e);
      promptAction.showToast({ message: '本地书架刷新失败' });
    } finally {
      this.shelfRefreshRunning = false;
      this.isShelfRefreshing = false;
      this.shelfRefreshPrompt = '下拉刷新书架';
    }
  }

  isFinishedBook(book: Book): boolean {
    const text = `${book.kind || ''},${book.customTag || ''}`.replace(/\s+/g, '');
    if (!text) {
      return false;
    }
    if (/(连载中|連載中|连载|連載|未完结|未完結|更新中|ongoing|serializing)/i.test(text)) {
      return false;
    }
    return /(已完结|已完結|完结|完結|完本|全本|完$|completed|complete|finished)/i.test(text);
  }

  updateShelfRefreshPrompt(state: RefreshStatus): void {
    if (this.shelfRefreshRunning) {
      this.shelfRefreshPrompt = '书架刷新中';
      return;
    }
    if (state === RefreshStatus.OverDrag) {
      this.shelfRefreshPrompt = '松手刷新书架';
    } else if (state === RefreshStatus.Refresh) {
      this.shelfRefreshPrompt = '正在刷新书架...';
    } else if (state === RefreshStatus.Done) {
      this.shelfRefreshPrompt = '刷新完成';
    } else {
      this.shelfRefreshPrompt = '下拉刷新书架';
    }
  }

  async updateShelfBook(book: Book): Promise<void> {
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      await db.updateBook(book);
      this.books = this.books.map((item: Book) => item.bookUrl === book.bookUrl ? book : item);
      AppStorage.setOrCreate('shelfUpdateTime', Date.now());
    } catch (e) {
      console.error('更新书籍失败:', e);
      promptAction.showToast({ message: '保存失败' });
    }
  }

  cachedChapterTextColor(): string {
    return this.appDarkMode ? '#DDEFE5' : '#244B35';
  }

  @Builder
  shelfRefreshBuilder() {
    Row({ space: 8 }) {
      if (this.isShelfRefreshing) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color(this.accentColor())
      }
      Text(this.shelfRefreshPrompt)
        .fontSize(13)
        .fontColor(this.secondaryTextColor())
    }
    .height(48)
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  shelfScopeSegment() {
    Row({ space: 5 }) {
      Text(this.shelfScopeLabel())
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.accentColor())
      SymbolGlyph(this.showShelfScopeOptions ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
        .fontSize(12)
        .fontColor([this.secondaryTextColor()])
    }
    .width(72)
    .height(32)
    .borderRadius(18)
    .backgroundColor(this.showShelfScopeOptions ? this.selectedSoftBackgroundColor() : this.glassCardColor())
    .border({ width: ThemeRuntime.glassBorderWidth(), color: this.glassBorderColor() })
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.showShelfScopeOptions = !this.showShelfScopeOptions;
      this.showShelfGroups = false;
      this.showShelfSortMenu = false;
      this.showShelfLayoutMenu = false;
    })
  }

  @Builder
  shelfScopeFloatingMenu() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .onClick(() => {
          this.showShelfScopeOptions = false;
        })

      Column() {
        this.expandedShelfScopeSegment()
      }
      .width(116)
      .position({ x: 60, y: this.statusBarHeight + 52 })
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
    .zIndex(12)
  }

  @Builder
  expandedShelfScopeSegment() {
    Column({ space: 4 }) {
      this.scopeDropdownItem('全部', 'all')
      this.scopeDropdownItem('网络', 'network')
      this.scopeDropdownItem('本地', 'local')
    }
    .width(116)
    .padding(6)
    .borderRadius(ThemeRuntime.glassCornerRadius(14, 'panel'))
    .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
    .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
    .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'panel') })
    .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'panel'), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
  }

  @Builder
  scopeDropdownItem(label: string, scope: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontWeight(this.shelfScope === scope ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.shelfScope === scope ? this.accentColor() : this.primaryTextColor())
        .layoutWeight(1)

      if (this.shelfScope === scope) {
        Text('✓')
          .fontSize(13)
          .fontColor(this.accentColor())
      }
    }
    .width('100%')
    .height(34)
    .padding({ left: 10, right: 10 })
    .borderRadius(10)
    .backgroundColor(this.shelfScope === scope ? this.selectedSoftBackgroundColor() : '#00000000')
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.switchShelfScopeBySelection(scope);
    })
  }

  shelfScopeLabel(): string {
    if (this.shelfScope === 'network') {
      return '网络';
    }
    if (this.shelfScope === 'local') {
      return '本地';
    }
    return '全部';
  }

  @Builder
  shelfLayoutButton() {
    Row() {
      SymbolGlyph($r('sys.symbol.square_grid_2x2'))
        .fontSize(24)
        .fontColor([this.showShelfLayoutMenu ? this.accentColor() : this.primaryTextColor()])
    }
    .width(44)
    .height(44)
    .borderRadius(22)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.showShelfLayoutMenu ? this.selectedSoftBackgroundColor() : '#00000000')
    .accessibilityText('布局切换')
    .onClick(() => {
      this.showShelfLayoutMenu = !this.showShelfLayoutMenu;
      this.showShelfScopeOptions = false;
      this.showShelfSortMenu = false;
      this.showShelfGroups = false;
    })
  }

  @Builder
  shelfLayoutFloatingMenu() {
    Row() {
      this.shelfLayoutDropdown()
      Blank()
    }
    .width('100%')
    .padding({ left: 12 })
    .position({ x: 0, y: this.statusBarHeight + 52 })
    .zIndex(11)
  }

  @Builder
  shelfLayoutDropdown() {
    Column({ space: 4 }) {
      this.layoutDropdownItem('紧凑', 'compact', $r('sys.symbol.list_bullet'))
      this.layoutDropdownItem('宽松', 'loose', $r('sys.symbol.bookshelf'))
      this.layoutDropdownItem('平铺', 'tile', $r('sys.symbol.square_grid_2x2'))
    }
    .width(132)
    .padding(6)
    .borderRadius(ThemeRuntime.glassCornerRadius(14, 'panel'))
    .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
      .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
    .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'panel') })
    .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'panel'), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
  }

  @Builder
  layoutDropdownItem(label: string, mode: string, icon: Resource) {
    Row({ space: 10 }) {
      SymbolGlyph(icon)
        .fontSize(17)
        .fontColor([this.bookshelfLayoutMode === mode ? this.accentColor() : this.secondaryTextColor()])
      Text(label)
        .fontSize(14)
        .fontWeight(this.bookshelfLayoutMode === mode ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.bookshelfLayoutMode === mode ? this.accentColor() : this.primaryTextColor())
        .layoutWeight(1)

      if (this.bookshelfLayoutMode === mode) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(14)
          .fontColor([this.accentColor()])
      }
    }
    .width('100%')
    .height(38)
    .padding({ left: 10, right: 10 })
    .borderRadius(10)
    .backgroundColor(this.bookshelfLayoutMode === mode ? this.selectedSoftBackgroundColor() : '#00000000')
    .alignItems(VerticalAlign.Center)
    .onClick(() => this.applyBookshelfLayoutMode(mode))
  }

  applyBookshelfLayoutMode(mode: string): void {
    const next = mode === 'loose' || mode === 'tile' ? mode : 'compact';
    this.bookshelfLayoutMode = next;
    this.showShelfLayoutMenu = false;
    const settings = BookshelfDisplaySettingsStore.fromStorage();
    settings.layoutMode = next;
    BookshelfDisplaySettingsStore.applyToStorage(settings);
    BookshelfDisplaySettingsStore.save(getContext(this), settings).catch((e: Error) => {
      console.warn('保存书架布局失败:', e);
      promptAction.showToast({ message: '布局保存失败' });
    });
  }

  @Builder
  shelfSortButton() {
    Row({ space: 5 }) {
      Text('⇅')
        .fontSize(14)
        .fontColor(this.accentColor())
      Text(this.sortModeLabel())
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor())
      SymbolGlyph(this.showShelfSortMenu ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
        .fontSize(14)
        .fontColor([this.secondaryTextColor()])
    }
    .height(32)
    .padding({ left: 11, right: 9 })
    .borderRadius(16)
    .backgroundColor(this.glassCardColor())
    .border({ width: ThemeRuntime.glassBorderWidth(), color: this.glassBorderColor() })
    .alignItems(VerticalAlign.Center)
    .margin({ right: 10 })
    .onClick(() => {
      this.showShelfSortMenu = !this.showShelfSortMenu;
      this.showShelfScopeOptions = false;
      this.showShelfLayoutMenu = false;
    })
  }

  @Builder
  shelfSortFloatingMenu() {
    Row() {
      Blank()
      this.shelfSortDropdown()
    }
    .width('100%')
    .padding({ right: 56 })
    .position({ x: 0, y: this.statusBarHeight + 52 })
    .zIndex(10)
    .transition(this.shelfSortMenuTransition())
  }

  shelfSortMenuTransition(): TransitionEffect {
    const appear = TransitionEffect.translate({ y: -7 })
      .combine(TransitionEffect.scale({ x: 0.96, y: 0.96, centerX: '100%', centerY: '0%' }))
      .combine(TransitionEffect.opacity(0))
      .animation({ duration: 190, curve: Curve.Friction });
    const disappear = TransitionEffect.translate({ y: -4 })
      .combine(TransitionEffect.scale({ x: 0.98, y: 0.98, centerX: '100%', centerY: '0%' }))
      .combine(TransitionEffect.opacity(0))
      .animation({ duration: 125, curve: Curve.EaseIn });
    return TransitionEffect.asymmetric(appear, disappear);
  }

  @Builder
  shelfSortDropdown() {
    Column({ space: 4 }) {
      this.sortDropdownItem('新阅读', 'recentRead')
      this.sortDropdownItem('新加入', 'recentAdd')
      this.sortDropdownItem('名称', 'name')
    }
    .width(116)
    .padding(6)
    .borderRadius(ThemeRuntime.glassCornerRadius(14, 'panel'))
    .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
      .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
    .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'panel') })
    .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'panel'), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
  }

  @Builder
  sortDropdownItem(label: string, mode: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontWeight(this.sortMode === mode ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.sortMode === mode ? this.accentColor() : this.primaryTextColor())
        .layoutWeight(1)

      if (this.sortMode === mode) {
        Text('✓')
          .fontSize(13)
          .fontColor(this.accentColor())
      }
    }
    .width('100%')
    .height(34)
    .padding({ left: 10, right: 10 })
    .borderRadius(10)
    .backgroundColor(this.sortMode === mode ? this.selectedSoftBackgroundColor() : '#00000000')
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.applyShelfSortMode(mode);
    })
  }

  sortModeLabel(): string {
    if (this.sortMode === 'recentAdd') {
      return '新加入';
    }
    if (this.sortMode === 'name') {
      return '名称';
    }
    return '新阅读';
  }

  selectedSoftBackgroundColor(): string {
    const color = this.accentColor();
    return `#1A${color.substring(1)}`;
  }

  applyShelfSortMode(mode: string): void {
    const next = mode === 'recentAdd' || mode === 'name' ? mode : 'recentRead';
    this.showShelfSortMenu = false;
    if (this.sortMode === next) {
      if (this.pendingShelfSortTimer >= 0) {
        clearTimeout(this.pendingShelfSortTimer);
        this.pendingShelfSortTimer = -1;
      }
      this.pendingShelfSortMode = '';
      return;
    }
    if (this.shelfScopeSwitchAnimating) {
      this.pendingShelfSortMode = next;
      if (this.pendingShelfSortTimer >= 0) {
        clearTimeout(this.pendingShelfSortTimer);
      }
      this.pendingShelfSortTimer = setTimeout(() => {
        this.pendingShelfSortTimer = -1;
        const pending = this.pendingShelfSortMode;
        this.pendingShelfSortMode = '';
        if (pending) {
          this.applyShelfSortMode(pending);
        }
      }, 280);
      return;
    }
    if (this.pendingShelfSortTimer >= 0) {
      clearTimeout(this.pendingShelfSortTimer);
      this.pendingShelfSortTimer = -1;
    }
    this.pendingShelfSortMode = '';
    this.animateShelfContentUpdate(() => {
      this.sortMode = next;
      const sorted = this.sortBooks(this.books, next);
      this.books = sorted;
      this.shelfListBooksSource.replace(sorted);
      this.shelfTileBooksSource.replace(this.getTileBooksWithoutLatest(sorted));
      this.shelfTileEntriesCacheKey = '';
      this.shelfTileEntriesSource.replace(this.getSortedTileRootEntries(sorted, next));
    }, 0);
  }

  sortBooks(books: Book[], mode: string = this.sortMode): Book[] {
    if (mode === 'recentRead') {
      return BookshelfSortHelper.sortByRecentRead(books);
    }
    const sorted = [...books];
    if (mode === 'name') {
      sorted.sort((a: Book, b: Book) => this.compareBookName(a, b));
    } else {
      sorted.sort((a: Book, b: Book) => this.getBookAddTime(b) - this.getBookAddTime(a));
    }
    return sorted;
  }

  compareBookName(a: Book, b: Book): number {
    const nameA = this.normalizeBookName(a.name);
    const nameB = this.normalizeBookName(b.name);
    const nameDiff = nameA.localeCompare(nameB, 'zh-Hans-CN-u-co-pinyin');
    if (nameDiff !== 0) {
      return nameDiff;
    }
    return this.getBookAddTime(b) - this.getBookAddTime(a);
  }

  normalizeBookName(name?: string): string {
    if (!name) {
      return '';
    }
    return name
      .trim()
      .replace(/^[《〈「『“"'(\[【\s]+/g, '')
      .replace(/[》〉」』”"')\]】\s]+$/g, '');
  }

  shelfTileBookDisplayName(book: Book): string {
    const title = (book?.name || '').trim();
    if (title) {
      return title;
    }
    const bookUrl = (book?.bookUrl || '').trim();
    if (!bookUrl) {
      return '未知书名';
    }
    const candidate = bookUrl.split(/[/?#]/).filter((part: string) => part).pop() || '';
    if (!candidate) {
      return '未知书名';
    }
    const rawTitle = (() => {
      try {
        return decodeURIComponent(candidate);
      } catch (_error) {
        return candidate;
      }
    })();
    return rawTitle.replace(/\.[^./\\]*$/, '').trim() || '未知书名';
  }

  getBookAddTime(book: Book): number {
    return BookshelfSortHelper.getBookAddTime(book);
  }

  getBookReadTime(book: Book): number {
    return BookshelfSortHelper.getBookReadTime(book);
  }

  parseBookTime(value: string): number {
    return BookshelfSortHelper.parseBookTime(value);
  }

  getShelfProgressText(book: Book): string {
    if (!book.totalChapterNum || book.totalChapterNum <= 0) {
      return '未读';
    }
    if (!Book.hasStartedReading(book)) {
      return '未读';
    }
    const unread = book.getUnreadChapterNum();
    return unread > 0 ? `${unread}章未读` : '已读完';
  }

  getReadProgressValue(book: Book): number {
    if (!book.totalChapterNum || book.totalChapterNum <= 0) {
      return 0;
    }
    if (!Book.hasStartedReading(book)) {
      return 0;
    }
    const chapterIndex = Math.min(Math.max(book.durChapterIndex, 0), book.totalChapterNum - 1);
    const progressChapterIndex = Number.parseInt(book.getVariable('readProgressChapterIndex'));
    const currentChapterPageCount = Number.parseInt(book.getVariable('readProgressPageCount'));
    let currentChapterProgress = 1;
    if (progressChapterIndex === chapterIndex && currentChapterPageCount > 0) {
      const currentPageNumber = Math.min(Math.max(book.durChapterPos + 1, 1), currentChapterPageCount);
      currentChapterProgress = currentPageNumber / currentChapterPageCount;
    }
    const readChapterCount = Math.min(chapterIndex + currentChapterProgress, book.totalChapterNum);
    return Math.floor(readChapterCount * 1000 / book.totalChapterNum) / 10;
  }

  getReadProgressPercentText(book: Book): string {
    const progress = this.getReadProgressValue(book);
    if (progress <= 0) {
      return '已读0%';
    }
    if (progress >= 100) {
      return '已读100%';
    }
    return progress % 1 === 0 ? `已读${progress.toFixed(0)}%` : `已读${progress.toFixed(1)}%`;
  }

  getLastReadTimeText(book: Book): string {
    const readTime = this.getBookReadTime(book);
    if (readTime <= 0) {
      return '未读';
    }
    return this.formatShelfTime(readTime);
  }

  formatShelfTime(time: number): string {
    const date = new Date(time);
    if (Number.isNaN(date.getTime())) {
      return '未知';
    }
    const now = new Date();
    const dateStart = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
    const nowStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    const dayDiff = Math.floor((nowStart - dateStart) / 86400000);
    const timeText = `${this.padTime(date.getHours())}:${this.padTime(date.getMinutes())}`;
    if (dayDiff === 0) {
      return `今天 ${timeText}`;
    }
    if (dayDiff === 1) {
      return `昨天 ${timeText}`;
    }
    if (date.getFullYear() === now.getFullYear()) {
      return `${date.getMonth() + 1}-${this.padTime(date.getDate())} ${timeText}`;
    }
    return `${date.getFullYear()}-${this.padTime(date.getMonth() + 1)}-${this.padTime(date.getDate())} ${timeText}`;
  }

  padTime(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  @Builder
  readProgressPanel(book: Book) {
    Column({ space: 4 }) {
      Text(this.getReadProgressInfoText(book))
        .fontSize(12)
        .fontColor(this.subTextColor())
        .width('100%')
        .textAlign(TextAlign.Start)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Progress({ value: this.getReadProgressValue(book), total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(3)
        .color(this.accentColor())
        .backgroundColor(this.appDarkMode ? '#2D3138' : '#E8EAED')
    }
    .width('100%')
  }

  @Builder
  looseReadProgressPanel(book: Book) {
    Column({ space: 4 }) {
      Progress({ value: this.getReadProgressValue(book), total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(3)
        .color(this.accentColor())
        .backgroundColor(this.appDarkMode ? '#2D3138' : '#E8EAED')

      Text(this.getReadProgressInfoText(book))
        .fontSize(12)
        .fontColor(this.subTextColor())
        .width('100%')
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
  }

  getReadProgressInfoText(book: Book): string {
    if (!Book.hasStartedReading(book)) {
      return '未读';
    }
    const parts: string[] = [this.getReadProgressPercentText(book)];
    if (this.bookshelfShowLastReadTime) {
      parts.push(this.getLastReadTimeText(book));
    }
    if (this.bookshelfShowLastReadChapter) {
      const chapterText = this.getReadChapterText(book);
      if (chapterText) {
        parts.push(chapterText);
      }
    }
    return parts.join(' · ');
  }

  getReadChapterText(book: Book): string {
    if (!Book.hasStartedReading(book)) {
      return '';
    }
    return (book.durChapterTitle || '').trim();
  }

  getLastReadChapterText(book: Book): string {
    if (!Book.hasStartedReading(book)) {
      return '尚未阅读';
    }
    const chapterNumber = book.durChapterIndex >= 0 ? book.durChapterIndex + 1 : -1;
    const chapterTitle = this.getReadChapterText(book);
    if (chapterNumber > 0 && chapterTitle) {
      return `第${chapterNumber}章 · ${chapterTitle}`;
    }
    if (chapterNumber > 0) {
      return `第${chapterNumber}章`;
    }
    return chapterTitle || '尚未记录章节';
  }

  getLastReadChapterNumberText(book: Book): string {
    if (!Book.hasStartedReading(book)) {
      return '尚未阅读';
    }
    return book.durChapterIndex >= 0 ? `第${book.durChapterIndex + 1}章` : '章节号未知';
  }

  getLastReadChapterNameText(book: Book): string {
    if (!Book.hasStartedReading(book)) {
      return '尚未记录章节';
    }
    const originalTitle = this.getReadChapterText(book).replace(/\s+/g, ' ').trim();
    if (!originalTitle) {
      return '章节名未知';
    }
    let title = originalTitle;
    const chineseChapterPrefix =
      /^第\s*[0-9０-９零〇○一二三四五六七八九十百千万亿两壹贰叁肆伍陆柒捌玖拾佰仟]+\s*(?:章|回|节|話|话|集|篇|幕)\s*(?:[·•:：、.．\-—]+\s*)?/;
    const englishChapterPrefix =
      /^(?:chapter|chap\.?|ch\.?)\s*[0-9０-９]+\s*(?:[·•:：、.．\-—]+\s*)?/i;
    // Some sources return duplicated prefixes such as “第233章 第233章 寒山奇石”.
    // Strip at most a few leading ordinals while preserving the stored chapter title itself.
    for (let index = 0; index < 3; index++) {
      const stripped = title.replace(chineseChapterPrefix, '').replace(englishChapterPrefix, '').trim();
      if (stripped === title) break;
      title = stripped;
      if (!title) break;
    }
    return title || '章节名未知';
  }

  getLastReadPagePreviewText(book: Book): string {
    const text = book.getVariable('lastReadPageText').trim();
    return text || '再次阅读后，将在这里显示上次阅读页的正文内容。';
  }

  getLastReadPageNumberText(book: Book): string {
    const pageCount = Number.parseInt(book.getVariable('readProgressPageCount'));
    const pageNumber = Math.max(1, book.durChapterPos + 1);
    return pageCount > 0 ? `${Math.min(pageNumber, pageCount)}/${pageCount}` : `${pageNumber}`;
  }

  getLastReadLeafContentMode(book: Book): string {
    if (this.bookshelfLastReadLeafMode === 'bookInfo' || this.bookshelfLastReadLeafMode === 'contentPreview') {
      return this.bookshelfLastReadLeafMode;
    }
    if (BookTypeSupport.isAudio(book)) {
      return 'bookInfo';
    }
    if (this.isShelfComicBook(book) && this.getLastReadPageImage(book)) {
      return 'comicPreview';
    }
    return 'contentPreview';
  }

  isShelfComicBook(book: Book): boolean {
    if (book.origin === 'local') {
      return BookTypeSupport.isImage(book);
    }
    return BookTypeSupport.isImage(book) || book.getVariable('readerComicManualMode') === 'comic' ||
      book.getVariable('readerComicAutoDetected') === '1' || book.getVariable('readerComicMode') === '1';
  }

  getLastReadPageImage(book: Book): string {
    const source = book.getVariable('lastReadPageImage').trim();
    if (!source || /^(?:https?:|data:|file:)/i.test(source)) {
      return source;
    }
    try {
      return fileUri.getUriFromPath(source);
    } catch (_) {
      return source;
    }
  }

  @Builder
  shelfLastReadLeaf(book: Book) {
    if (this.getLastReadLeafContentMode(book) === 'bookInfo') {
      this.shelfLastReadBookInfo(book)
    } else if (this.getLastReadLeafContentMode(book) === 'comicPreview') {
      Image(this.getLastReadPageImage(book))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Contain)
        .draggable(false)
    } else {
      Text(this.getLastReadPagePreviewText(book))
        .width('100%')
        .layoutWeight(1)
        .fontSize(4.8)
        .lineHeight(7.5)
        .fontColor(this.shelfTilePageTextColor())
        .textAlign(TextAlign.JUSTIFY)
        .wordBreak(WordBreak.BREAK_WORD)
        .maxLines(16)
        .textOverflow({ overflow: TextOverflow.Clip })
        .margin({ top: 4 })

      Text(this.getLastReadPageNumberText(book))
        .width('100%')
        .fontSize(5)
        .fontColor(this.shelfTilePageSubTextColor())
        .textAlign(TextAlign.End)
    }
  }

  @Builder
  shelfLastReadBookInfo(book: Book) {
    Column() {
      Text(this.shelfTileBookDisplayName(book))
        .width('100%')
        .fontSize(10)
        .lineHeight(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.shelfTilePageTextColor())
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text((book.author || '').trim() || '作者未知')
        .width('100%')
        .fontSize(7)
        .lineHeight(10)
        .fontColor(this.shelfTilePageSubTextColor())
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 5 })

      Blank()
        .layoutWeight(1)

      Text(this.getLastReadChapterNumberText(book))
        .width('100%')
        .fontSize(8)
        .lineHeight(11)
        .fontColor(this.shelfTilePageTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(this.getLastReadChapterNameText(book))
        .width('100%')
        .fontSize(8)
        .lineHeight(11)
        .fontColor(this.shelfTilePageTextColor())
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 1 })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  shelfTilePageColor(): string {
    return this.appDarkMode ? '#242321' : '#F8F4E9';
  }

  shelfTilePageTextColor(): string {
    return this.appDarkMode ? '#D8D3C8' : '#3E3A33';
  }

  shelfTilePageSubTextColor(): string {
    return this.appDarkMode ? '#8F8A82' : '#8A8378';
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

  glassCardColor(): string {
    return ThemeRuntime.cardColor(this.appDarkMode);
  }

  glassBorderColor(): string {
    return this.appDarkMode ? '#262A31' : '#FFFFFF';
  }

  glassShadowColor(): string {
    return '#00000000';
  }

  sourceTagBackgroundColor(): string {
    return this.appDarkMode ? '#24272D' : '#E8F0FE';
  }

  sourceTagTextColor(): string {
    return this.appDarkMode ? '#8A8F98' : this.accentColor();
  }

  primaryTextColor(): string {
    return ThemeRuntime.primaryTextColor(this.appDarkMode);
  }

  secondaryTextColor(): string {
    return ThemeRuntime.subTextColor(this.appDarkMode);
  }

  subTextColor(): string {
    return ThemeRuntime.subTextColor(this.appDarkMode);
  }

  accentColor(): string {
    return ThemeRuntime.accentColor(this.appDarkMode);
  }

  buttonColor(): string {
    return ThemeRuntime.buttonColor(this.appDarkMode);
  }
}

@Component
struct ExplorePage {
  @Prop statusBarHeight: number = 0;
  @Prop navBarHeight: number = 0;
  @Prop @Watch('onActiveChanged') isActive: boolean = false;
  @State entries: ExploreEntry[] = [];
  @State sourceOptions: ExploreSourceOption[] = [];
  @State exploreSourceGroups: string[] = [];
  @State activeExploreSourceGroup: string = '__all__';
  @State platformNames: string[] = [];
  @State sourceNames: string[] = [];
  @State selectedSourceName: string = '';
  @State selectedIndex: number = 0;
  @State showExploreSourcePicker: boolean = false;
  @State showExploreSourceActionMenu: boolean = false;
  @State actionExploreSourceUrl: string = '';
  @State exploreContextMenuX: number = 16;
  @State exploreContextMenuY: number = 96;
  @State exploreSourceFilterInput: string = '';
  @State exploreSourceFilterKeyword: string = '';
  @State exploreViewportWidth: number = 360;
  @State exploreViewportHeight: number = 720;
  @State books: SearchBook[] = [];
  @State shelfBookKeys: string[] = [];
  @State addingShelfBookKeys: string[] = [];
  @State isLoading: boolean = false;
  @State isLoadingMore: boolean = false;
  @State hasMoreExploreBooks: boolean = true;
  @State status: string = '';
  @State verificationUrl: string = '';
  @State verificationTitle: string = '';
  @StorageLink('explorePlatform') selectedPlatform: string = '番茄';
  @StorageLink('exploreSourceUrl') selectedSourceUrl: string = '';
  @StorageLink('bookSourceExploreRefreshNonce') @Watch('onExploreRefreshRequested')
  bookSourceExploreRefreshNonce: number = 0;
  @StorageLink('shelfUpdateTime') @Watch('onShelfChanged') shelfUpdateTime: number = 0;
  @StorageLink('bookSourceOrderRevision') @Watch('onBookSourceOrderChanged') bookSourceOrderRevision: number = 0;
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;
  @StorageLink('searchExploreShowResultCover') searchExploreShowResultCover: boolean = true;
  @StorageLink('searchExploreUseBookshelfCoverGallery') searchExploreUseBookshelfCoverGallery: boolean = false;
  @StorageLink('searchExploreShowResultTags') searchExploreShowResultTags: boolean = true;
  @StorageLink('searchExplorePromptAddToShelfOnBack') searchExplorePromptAddToShelfOnBack: boolean = true;
  @StorageLink('appLightAccentColor') appLightAccentColor: string = '#007DFF';
  @StorageLink('appDarkAccentColor') appDarkAccentColor: string = '#4E9BFF';
  @StorageLink('appLightButtonColor') appLightButtonColor: string = '#007DFF';
  @StorageLink('appDarkButtonColor') appDarkButtonColor: string = '#3F8CFF';
  @StorageLink('readerActiveFontFamily') readerActiveFontFamily: string = '';
  private coordinator: ExploreCoordinator = new ExploreCoordinator();
  private hasLoaded: boolean = false;
  private hasRestoredExploreSelection: boolean = false;
  private shelfStatusVersion: number = 0;
  private exploreLoadVersion: number = 0;
  private exploreContentLoadedAt: number = 0;
  private explorePage: number = 1;

  aboutToAppear() {
    if (this.isActive) {
      this.ensureLoaded();
    }
  }

  onActiveChanged(): void {
    if (this.isActive) {
      this.ensureLoaded();
    } else {
      if (this.showExploreSourcePicker) {
        this.showExploreSourcePicker = false;
        this.clearExploreSourceFilter();
      }
      this.closeExploreSourceActions();
    }
  }

  ensureLoaded(): void {
    if ((!this.hasLoaded || !ExploreResultCache.isFresh(this.exploreContentLoadedAt)) && !this.isLoading) {
      this.loadEntries();
    }
  }

  onShelfChanged(): void {
    this.syncExploreShelfStatus(this.books);
  }

  onBookSourceOrderChanged(): void {
    if (this.isActive && this.hasLoaded && !this.isLoading) {
      this.loadEntries();
    }
  }

  onExploreRefreshRequested(): void {
    if (this.bookSourceExploreRefreshNonce <= 0) return;
    const sourceUrl = AppStorage.get<string>('bookSourceExploreRefreshSourceUrl') || '';
    if (sourceUrl) this.selectedSourceUrl = sourceUrl;
    this.exploreContentLoadedAt = 0;
    if (this.isActive && !this.isLoading) {
      this.loadEntries('', true);
    }
  }

  async loadEntries(platformOverride: string = '', forceRefresh: boolean = false) {
    const loadVersion = this.beginExploreLoad();
    this.hasLoaded = true;
    this.exploreContentLoadedAt = 0;
    this.status = '正在加载发现分类...';
    this.verificationUrl = '';
    this.verificationTitle = '';
    try {
      if (!this.hasRestoredExploreSelection) {
        this.hasRestoredExploreSelection = true;
        await this.restoreExploreSelectionFromSettings();
        if (!this.isCurrentExploreLoad(loadVersion)) return;
      }
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      if (!this.isCurrentExploreLoad(loadVersion)) return;
      const previousSourceName = this.selectedSourceName;
      const previousSourceUrl = this.selectedSourceUrl;
      const sourceOptions = await this.coordinator.getExploreSources();
      if (!this.isCurrentExploreLoad(loadVersion)) return;
      // 数据库查询已经按书源管理中的 customOrder 排序，同时只会返回已启用的书源。
      this.sourceOptions = sourceOptions;
      this.exploreSourceGroups = this.buildExploreSourceGroups();
      if (this.activeExploreSourceGroup !== '__all__' &&
        !this.exploreSourceGroups.includes(this.activeExploreSourceGroup)) {
        this.activeExploreSourceGroup = '__all__';
      }
      this.sourceNames = this.sourceOptions.map((option: ExploreSourceOption) => option.sourceName);
      const restoredOption = this.sourceOptions.find((option: ExploreSourceOption) =>
        option.sourceUrl === previousSourceUrl) ||
        this.sourceOptions.find((option: ExploreSourceOption) => option.sourceName === previousSourceName) ||
        (this.sourceOptions.length > 0 ? this.sourceOptions[0] : null);
      this.selectedSourceName = restoredOption ? restoredOption.sourceName : '';
      this.selectedSourceUrl = restoredOption ? restoredOption.sourceUrl : '';
      this.platformNames = this.getSelectedSourcePlatforms();
      if (platformOverride && this.platformNames.includes(platformOverride)) {
        this.selectedPlatform = platformOverride;
      }
      this.normalizeSelectedPlatform();
      const entries = await this.coordinator.getEntries(this.selectedPlatform, this.getSelectedSourceUrl());
      if (!this.isCurrentExploreLoad(loadVersion)) return;
      this.entries = entries;
      if (this.entries.length > 0) {
        this.selectedIndex = 0;
        await this.loadBooks(loadVersion, forceRefresh);
      } else {
        this.books = [];
        this.status = this.coordinator.getNoticeMessage() ||
          `${this.getSelectedSiteLabel()} 暂无可用发现分类`;
      }
    } catch (e) {
      if (!this.isCurrentExploreLoad(loadVersion)) return;
      console.error('加载发现失败:', e);
      this.status = '发现加载失败';
    } finally {
      this.finishExploreLoad(loadVersion);
    }
  }

  async loadBooks(loadVersion?: number, forceRefresh: boolean = false) {
    const currentLoadVersion = loadVersion ?? this.beginExploreLoad();
    this.exploreContentLoadedAt = 0;
    this.explorePage = 1;
    this.hasMoreExploreBooks = true;
    this.isLoadingMore = false;
    const activeEntries = this.getActiveEntries();
    if (activeEntries.length === 0) {
      this.finishExploreLoad(currentLoadVersion);
      return;
    }
    this.status = '';
    this.verificationUrl = '';
    this.verificationTitle = '';
    try {
      const entry = activeEntries[Math.min(this.selectedIndex, activeEntries.length - 1)];
      if (!forceRefresh) {
        try {
          const cached: ExploreCacheHit | null = await ExploreResultCache.load(
            getContext(this), entry.sourceUrl, this.selectedPlatform, entry.title, entry.url);
          if (!this.isCurrentExploreLoad(currentLoadVersion)) return;
          if (cached) {
            this.exploreContentLoadedAt = cached.updatedAt;
            this.explorePage = cached.pageCount;
            this.hasMoreExploreBooks = cached.hasMore;
            await this.applyExploreBooks(cached.books, entry, currentLoadVersion, true);
            return;
          }
        } catch (cacheError) {
          console.warn('读取发现内容缓存失败，改用网络加载:', cacheError);
        }
      }
      const books = await this.coordinator.explore(entry, 1);
      if (!this.isCurrentExploreLoad(currentLoadVersion)) return;
      this.hasMoreExploreBooks = books.length > 0;
      await this.applyExploreBooks(books, entry, currentLoadVersion, false);
      if (!this.isCurrentExploreLoad(currentLoadVersion)) return;
      if (books.length > 0) {
        this.exploreContentLoadedAt = Date.now();
        try {
          await ExploreResultCache.save(getContext(this), entry.sourceUrl, this.selectedPlatform,
            entry.title, entry.url, books, this.explorePage, this.hasMoreExploreBooks);
        } catch (cacheError) {
          console.warn('保存发现内容缓存失败:', cacheError);
        }
      }
    } catch (e) {
      if (!this.isCurrentExploreLoad(currentLoadVersion)) return;
      console.error('获取发现内容失败:', e);
      this.status = '发现内容获取失败';
    } finally {
      this.finishExploreLoad(currentLoadVersion);
    }
  }

  async loadMoreExploreBooks(): Promise<void> {
    if (this.isLoading || this.isLoadingMore || !this.hasMoreExploreBooks || this.books.length === 0) return;
    const activeEntries = this.getActiveEntries();
    if (activeEntries.length === 0) return;
    const entry = activeEntries[Math.min(this.selectedIndex, activeEntries.length - 1)];
    const loadVersion = this.exploreLoadVersion;
    const nextPage = this.explorePage + 1;
    this.isLoadingMore = true;
    try {
      const nextBooks = await this.coordinator.explore(entry, nextPage);
      if (!this.isCurrentExploreLoad(loadVersion)) return;
      const merged = this.mergeExploreBooks(this.books, nextBooks);
      const addedCount = merged.length - this.books.length;
      if (nextBooks.length === 0 || addedCount === 0) {
        const notice = this.coordinator.getNoticeMessage();
        // Network/verification failures should remain retryable; a genuinely empty or duplicate
        // next page means the source has reached its end (or does not implement pagination).
        this.hasMoreExploreBooks = nextBooks.length === 0 && this.isRetryableExploreNotice(notice);
        this.status = notice || `${this.getSelectedSiteLabel()} · ${entry.sourceName} · ${entry.title} · 已加载全部`;
      } else {
        this.books = merged;
        this.explorePage = nextPage;
        this.status = `${this.getSelectedSiteLabel()} · ${entry.sourceName} · ${entry.title} · ${this.books.length} 本`;
        await this.syncExploreShelfStatus(this.books);
      }
      this.exploreContentLoadedAt = Date.now();
      await ExploreResultCache.save(getContext(this), entry.sourceUrl, this.selectedPlatform,
        entry.title, entry.url, this.books, this.explorePage, this.hasMoreExploreBooks);
    } catch (e) {
      if (this.isCurrentExploreLoad(loadVersion)) {
        console.error('加载更多发现内容失败:', e);
        this.status = '加载更多发现内容失败，可继续上滑重试';
      }
    } finally {
      if (this.isCurrentExploreLoad(loadVersion)) this.isLoadingMore = false;
    }
  }

  mergeExploreBooks(current: SearchBook[], incoming: SearchBook[]): SearchBook[] {
    const merged = current.slice();
    for (const book of incoming) {
      if (!merged.some((item: SearchBook): boolean =>
        item.origin === book.origin && item.bookUrl === book.bookUrl)) {
        merged.push(book);
      }
    }
    return merged;
  }

  isRetryableExploreNotice(notice: string): boolean {
    return /请求失败|网络|超时|timeout|HTTP|网页验证|需要验证|接口返回空响应/i.test(notice || '');
  }

  shouldOfferExploreSourceLogin(): boolean {
    return !!this.selectedSourceUrl &&
      /请先登[录陆]|需要登[录陆]|未登[录陆]|令牌|token|无权限|登录设备数已达上限|设备管理/i.test(this.status || '');
  }

  exploreSourceLoginButtonLabel(): string {
    return /登录设备数已达上限|设备管理/i.test(this.status || '') ? '管理登录设备' : '登录书源';
  }

  openExploreSourceLogin(): void {
    if (!this.selectedSourceUrl) return;
    router.pushUrl({
      url: 'pages/BookSource',
      params: {
        openLoginSourceUrl: this.selectedSourceUrl
      }
    });
  }

  async applyExploreBooks(books: SearchBook[], entry: ExploreEntry, loadVersion: number,
    fromCache: boolean): Promise<void> {
    this.books = books;
    const shelfStatusVersion = this.shelfStatusVersion;
    const shelfKeys = await this.loadExploreShelfKeys(books);
    if (!this.isCurrentExploreLoad(loadVersion)) return;
    if (shelfStatusVersion === this.shelfStatusVersion) {
      this.shelfBookKeys = shelfKeys;
    }
    if (fromCache) {
      this.verificationUrl = '';
      this.verificationTitle = '';
    } else {
      this.verificationUrl = AppStorage.get<string>('pendingVerificationUrl') || '';
      this.verificationTitle = AppStorage.get<string>('pendingVerificationTitle') || '网页验证';
    }
    this.status = this.books.length > 0 ?
      `${this.getSelectedSiteLabel()} · ${entry.sourceName} · ${entry.title} · ${this.books.length} 本${fromCache ? ' · 缓存' : ''}` :
      (this.verificationUrl ? `${entry.sourceName} 可能需要网页验证` :
        (this.coordinator.getNoticeMessage() || `${this.getSelectedSiteLabel()} 当前分类暂无结果`));
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Column() {
        Row() {
        Row() {
          if (this.showExploreSourcePicker) {
            TextInput({ placeholder: '输入书源关键词', text: this.exploreSourceFilterInput })
              .fontSize(15)
              .fontFamily(this.readerActiveFontFamily)
              .fontColor(this.primaryTextColor())
              .placeholderColor(this.secondaryTextColor())
              .layoutWeight(1)
              .height(36)
              .padding(0)
              .backgroundColor(Color.Transparent)
              .onChange((value: string) => {
                this.exploreSourceFilterInput = value;
              })
              .onSubmit(() => {
                this.applyExploreSourceFilter();
              })
          } else {
            Text(this.selectedSourceName || '发现')
              .fontSize(16)
              .fontFamily(this.readerActiveFontFamily)
              .fontColor(this.primaryTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .onClick(() => {
                this.openExploreSourcePicker();
              })
          }

          SymbolGlyph(this.showExploreSourcePicker ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
            .fontSize(18)
            .fontColor([this.secondaryTextColor()])
            .margin({ left: 6 })
            .onClick(() => {
              this.toggleExploreSourcePicker();
            })

          if (this.showExploreSourcePicker) {
            Button('搜索')
              .height(30)
              .fontSize(12)
              .borderRadius(15)
              .backgroundColor(this.buttonColor())
              .fontColor('#FFFFFF')
              .padding({ left: 10, right: 10 })
              .margin({ left: 8 })
              .onClick(() => {
                this.applyExploreSourceFilter();
              })
          }
        }
          .layoutWeight(1)
          .height(40)
          .borderRadius(20)
          .backgroundColor(this.glassCardColor())
          .border({ width: ThemeRuntime.glassBorderWidth(), color: this.glassBorderColor() })
          .shadow({ radius: ThemeRuntime.glassShadowRadius(), color: this.glassShadowColor(), offsetX: ThemeRuntime.glassShadowOffsetX(), offsetY: ThemeRuntime.glassShadowOffsetY() })
          .padding({ left: 16, right: 10 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            if (!this.showExploreSourcePicker) {
              this.openExploreSourcePicker();
            }
          })

        ImmersiveBackButton({
          icon: $r('sys.symbol.arrow_clockwise'),
          iconOffsetX: 0,
          iconColor: this.primaryTextColor(),
          darkMode: this.appDarkMode,
          buttonSize: 40,
          containerWidth: 40,
          containerHeight: 40,
          startInset: 0,
          materialScale: 0.83,
          accessibilityLabel: '刷新发现内容',
          onBack: () => {
            this.loadEntries('', true);
          }
        })
          .margin({ left: 8, right: -24 })
      }
      .width('100%')
      .height(56 + this.statusBarHeight)
      .padding({ left: 16, right: 16, top: this.statusBarHeight })
      .alignItems(VerticalAlign.Center)

      if (this.platformNames.length > 0) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.platformNames, (name: string) => {
              Text(name)
                .fontSize(13)
                .fontColor(this.selectedPlatform === name ? '#FFFFFF' : this.primaryTextColor())
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .backgroundColor(this.selectedPlatform === name ? this.accentColor() : this.glassCardColor())
                .borderRadius(18)
                .border({ width: this.selectedPlatform === name ? 0 : 1, color: this.glassBorderColor() })
                .onClick(() => {
                  this.switchExplorePlatform(name);
                })
            })
          }
          .padding({ left: 16, right: 16 })
        }
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .width('100%')
        .height(48)
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
      }

      if (this.getActiveEntries().length > 0) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.getActiveEntries(), (entry: ExploreEntry, index: number) => {
              Text(entry.title)
                .fontSize(13)
                .fontColor(this.selectedIndex === index ? '#FFFFFF' : this.secondaryTextColor())
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .backgroundColor(this.selectedIndex === index ? this.accentColor() : this.glassCardColor())
                .borderRadius(17)
                .border({ width: this.selectedIndex === index ? 0 : 1, color: this.glassBorderColor() })
                .onClick(() => {
                  this.selectedIndex = index;
                  this.loadBooks();
                })
            })
          }
          .padding({ left: 16, right: 16 })
          .constraintSize({ minWidth: '100%' })
          .justifyContent(FlexAlign.Start)
        }
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .width('100%')
        .height(44)
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
      }

      if (this.shouldShowExploreStatus()) {
        Row() {
          Text(this.status)
            .fontSize(13)
            .fontColor(this.secondaryTextColor())
            .layoutWeight(1)

          if (this.verificationUrl) {
            Button('去验证')
              .height(28)
              .fontSize(12)
              .borderRadius(14)
              .backgroundColor(this.buttonColor())
              .fontColor('#FFFFFF')
              .margin({ left: 12 })
              .onClick(() => {
                this.openVerification();
              })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 6, bottom: 6 })
        .alignItems(VerticalAlign.Center)
      }
        }
        .width('100%')
        .position({ x: 0, y: 0 })
        .zIndex(4)
        .backgroundColor(ThemeRuntime.topBarColor(this.appDarkMode))
        .backdropBlur(ThemeRuntime.topBarBlur())

      if (this.isLoading) {
        Column() {
          LoadingProgress()
            .width(36)
            .height(36)
          Text('加载中...')
            .fontSize(14)
            .fontColor(this.subTextColor())
            .margin({ top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ top: this.exploreTopOverlayHeight() })
        .justifyContent(FlexAlign.Center)
      } else if (this.books.length > 0) {
        SearchBookResultList({
          books: this.books,
          shelfBookKeys: this.shelfBookKeys,
          busyBookKeys: this.addingShelfBookKeys,
          showLoadingMore: this.isLoadingMore,
          showKind: true,
          showResultCover: this.searchExploreShowResultCover,
          useBookshelfCoverGallery: this.searchExploreUseBookshelfCoverGallery,
          showResultTags: this.searchExploreShowResultTags,
          showSourceLine: false,
          pageColor: this.pageColor(),
          cardColor: this.glassCardColor(),
          itemBorderColor: this.glassBorderColor(),
          itemBorderWidth: 1,
          shadowColor: this.glassShadowColor(),
          primaryTextColor: this.primaryTextColor(),
          secondaryTextColor: this.secondaryTextColor(),
          subTextColor: this.subTextColor(),
          topPadding: this.exploreTopOverlayHeight(),
          bottomPadding: this.resultListBottomInset(),
          onOpenBook: (book: SearchBook) => {
            this.openSearchBookDetail(book);
          },
          onToggleShelf: (book: SearchBook) => {
            this.toggleSearchBookShelf(book);
          },
          onReachEnd: () => {
            this.loadMoreExploreBooks();
          }
        })
      } else {
        Column() {
          Text('没有发现内容')
            .fontSize(16)
            .fontColor(this.subTextColor())
          Text(this.verificationUrl ? '当前书源可能需要网页验证' : '请切换书源或网站，或检查已启用书源的发现地址')
            .fontSize(14)
            .fontColor(this.subTextColor())
            .margin({ top: 8 })
            .textAlign(TextAlign.Center)
            .padding({ left: 32, right: 32 })
          if (this.verificationUrl) {
            Button('去验证')
              .height(36)
              .fontSize(14)
              .borderRadius(18)
              .margin({ top: 14 })
              .backgroundColor(this.buttonColor())
              .fontColor('#FFFFFF')
              .onClick(() => {
                this.openVerification();
              })
          }
          if (this.shouldOfferExploreSourceLogin()) {
            Button(this.exploreSourceLoginButtonLabel())
              .height(36)
              .fontSize(14)
              .borderRadius(18)
              .margin({ top: 14 })
              .backgroundColor(this.buttonColor())
              .fontColor('#FFFFFF')
              .onClick(() => {
                this.openExploreSourceLogin();
              })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ top: this.exploreTopOverlayHeight() })
        .justifyContent(FlexAlign.Center)
      }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageColor())
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])

      if (this.showExploreSourcePicker) {
        Column()
          .width('100%')
          .height('100%')
          .position({ x: 0, y: this.statusBarHeight + 56 })
          .backgroundColor(Color.Transparent)
          .zIndex(9)
          .onClick(() => {
            this.showExploreSourcePicker = false;
            this.clearExploreSourceFilter();
          })

        this.exploreSourceDropdown()
      }

      if (this.showExploreSourceActionMenu) {
        this.exploreSourceActionMenu()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor())
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const width = typeof newValue.width === 'number' ? newValue.width : Number.parseFloat(`${newValue.width}`);
      if (Number.isFinite(width) && width > 0) {
        this.exploreViewportWidth = width;
      }
      const height = typeof newValue.height === 'number' ? newValue.height : Number.parseFloat(`${newValue.height}`);
      if (Number.isFinite(height) && height > 0) {
        this.exploreViewportHeight = height;
      }
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  openSearchBookDetail(book: SearchBook) {
    router.pushUrl({
      url: 'pages/SearchBookDetail',
      params: {
        bookUrl: book.bookUrl,
        tocUrl: book.tocUrl,
        origin: book.origin,
        originName: book.originName,
        name: book.name,
        author: book.author,
        kind: book.kind,
        coverUrl: book.coverUrl,
        intro: book.intro,
        latestChapterTitle: book.latestChapterTitle,
        wordCount: book.wordCount,
        type: String(book.type || 0),
        variable: book.variable || '',
        promptAddToShelfOnBack: this.searchExplorePromptAddToShelfOnBack ? 'true' : 'false'
      }
    });
  }

  @Builder
  exploreSourceDropdown() {
    Column() {
      this.exploreSourceGroupBar()

      Scroll() {
        Column() {
          if (this.getFilteredExploreSourceOptions().length === 0) {
            Text(this.activeExploreSourceGroup === '__all__' ? '没有匹配的书源' : '当前分组没有匹配的书源')
              .fontSize(14)
              .fontColor(this.secondaryTextColor())
              .width('100%')
              .height(52)
              .textAlign(TextAlign.Center)
          } else {
            ForEach(this.getFilteredExploreSourceOptions(), (option: ExploreSourceOption) => {
              Row() {
                Text(option.sourceName || '未命名书源')
                  .fontSize(16)
                  .fontFamily(this.readerActiveFontFamily)
                  .fontColor(option.sourceUrl === this.selectedSourceUrl ? this.accentColor() : this.primaryTextColor())
                  .fontWeight(option.sourceUrl === this.selectedSourceUrl ? FontWeight.Medium : FontWeight.Regular)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)

                if (this.activeExploreSourceGroup === '__all__') {
                  Text(this.exploreSourceGroupLabel(option.sourceGroup))
                    .fontSize(10)
                    .fontFamily(this.readerActiveFontFamily)
                    .fontColor(this.secondaryTextColor())
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .constraintSize({ maxWidth: 68 })
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .borderRadius(8)
                    .backgroundColor(this.inputColor())
                    .margin({ left: 8 })
                }

                if (option.sourceUrl === this.selectedSourceUrl) {
                  Text('✓')
                    .fontSize(15)
                    .fontFamily(this.readerActiveFontFamily)
                    .fontColor(this.accentColor())
                    .margin({ left: 10 })
                }
              }
              .width('100%')
              .height(44)
              .padding({ left: 14, right: 14 })
              .borderRadius(12)
              .backgroundColor(option.sourceUrl === this.selectedSourceUrl ? this.exploreSelectedBackgroundColor() : '#00000000')
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                if (this.showExploreSourceActionMenu) return;
                this.showExploreSourcePicker = false;
                this.clearExploreSourceFilter();
                this.switchExploreSource(option);
              })
              .gesture(
                LongPressGesture({ repeat: false })
                  .onAction((event: GestureEvent) => {
                    this.openExploreSourceActions(option, event);
                  })
              )
            })
          }
        }
        .width('100%')
      }
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .width('100%')
      .constraintSize({ maxHeight: 320 })
      .scrollBar(BarState.Auto)
    }
    .width(this.exploreSourceDropdownWidth())
    .padding(8)
    .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
    .clip(true)
    .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
    .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
    .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
    .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
    .position({ x: 16, y: this.statusBarHeight + 52 })
    .zIndex(10)
    .parallelGesture(
      PanGesture({ direction: PanDirection.Horizontal, distance: 18 })
        .onActionEnd((event: GestureEvent) => {
          this.switchExploreSourceGroupBySwipe(event.offsetX);
        })
    )
  }

  @Builder
  exploreSourceActionMenu() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.appDarkMode ? '#52000000' : '#26FFFFFF')
        .backdropBlur(ThemeRuntime.glassBlur('popover', 18))
        .onClick(() => this.closeExploreSourceActions())

      Column() {
        Row() {
          SymbolGlyph($r('sys.symbol.square_and_pencil'))
            .fontSize(19)
            .fontColor([this.primaryTextColor()])
            .width(34)
          Text('编辑')
            .fontSize(15)
            .fontColor(this.primaryTextColor())
            .layoutWeight(1)
        }
        .width('100%')
        .height(44)
        .padding({ left: 10, right: 10 })
        .onClick(() => this.editActionExploreSource())
      }
      .width(132)
      .padding({ top: 6, bottom: 6 })
      .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
      .borderRadius(ThemeRuntime.glassCornerRadius(14, 'panel'))
      .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
      .border({ width: ThemeRuntime.glassBorderWidth('panel'),
        color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'panel') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'),
        color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'panel'),
        offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
      .position({ x: this.exploreContextMenuLeft(132), y: this.exploreContextMenuTop(56) })
    }
    .width('100%')
    .height('100%')
    .zIndex(12)
  }

  @Builder
  exploreSourceGroupBar() {
    Scroll() {
      Row({ space: 7 }) {
        this.exploreSourceGroupChip('全部', '__all__')
        ForEach(this.exploreSourceGroups, (group: string) => {
          this.exploreSourceGroupChip(group, group)
        }, (group: string) => group)
      }
      .padding({ left: 4, right: 4, bottom: 8 })
      .constraintSize({ minWidth: '100%' })
    }
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .width('100%')
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .clip(true)
  }

  @Builder
  exploreSourceGroupChip(label: string, groupKey: string) {
    Text(label)
      .fontSize(12)
      .fontFamily(this.readerActiveFontFamily)
      .fontColor(this.activeExploreSourceGroup === groupKey ? '#FFFFFF' : this.secondaryTextColor())
      .height(30)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .constraintSize({ maxWidth: 128 })
      .padding({ left: 11, right: 11 })
      .textAlign(TextAlign.Center)
      .borderRadius(15)
      .backgroundColor(this.activeExploreSourceGroup === groupKey ? this.accentColor() : this.inputColor())
      .onClick(() => this.selectExploreSourceGroup(groupKey))
  }

  exploreSourceDropdownWidth(): number {
    // 常规设备保持稳定的 320vp；窄屏只按安全边距收窄，不再随书源或分组内容变化。
    return Math.min(320, Math.max(1, this.exploreViewportWidth - 32));
  }

  async addSearchBookToShelf(searchBook: SearchBook): Promise<void> {
    const searchKey = SearchBookShelfHelper.keyOf(searchBook);
    this.markSearchBookJoining(searchKey);
    try {
      const change = await SearchBookShelfHelper.addToShelf(getContext(this), searchBook);
      this.markSearchBookInShelf(change.shelfKey || change.requestKey);
    } catch (e) {
      console.error('加入书架失败:', e);
      promptAction.showToast({ message: '加入书架失败' });
    } finally {
      this.unmarkSearchBookJoining(searchKey);
    }
  }

  openExploreSourcePicker(): void {
    if (this.sourceOptions.length === 0) {
      return;
    }
    this.exploreSourceFilterInput = '';
    this.exploreSourceFilterKeyword = '';
    this.activeExploreSourceGroup = '__all__';
    this.showExploreSourcePicker = true;
  }

  toggleExploreSourcePicker(): void {
    if (this.showExploreSourcePicker) {
      this.showExploreSourcePicker = false;
      this.clearExploreSourceFilter();
      return;
    }
    this.openExploreSourcePicker();
  }

  applyExploreSourceFilter(): void {
    this.exploreSourceFilterKeyword = this.exploreSourceFilterInput.trim().toLowerCase();
    if (this.sourceOptions.length > 0) {
      this.showExploreSourcePicker = true;
    }
  }

  clearExploreSourceFilter(): void {
    this.exploreSourceFilterInput = '';
    this.exploreSourceFilterKeyword = '';
  }

  openExploreSourceActions(option: ExploreSourceOption, event?: GestureEvent): void {
    const finger = event && event.fingerList.length > 0 ? event.fingerList[0] : undefined;
    if (finger) {
      this.exploreContextMenuX = finger.globalX;
      this.exploreContextMenuY = finger.globalY;
    }
    this.actionExploreSourceUrl = option.sourceUrl;
    this.showExploreSourcePicker = false;
    this.clearExploreSourceFilter();
    this.showExploreSourceActionMenu = true;
  }

  closeExploreSourceActions(): void {
    this.showExploreSourceActionMenu = false;
    this.actionExploreSourceUrl = '';
  }

  editActionExploreSource(): void {
    const sourceUrl = this.actionExploreSourceUrl;
    if (!sourceUrl) return;
    this.closeExploreSourceActions();
    router.pushUrl({
      url: 'pages/BookSourceEdit',
      params: { bookSourceUrl: sourceUrl }
    });
  }

  exploreContextMenuLeft(menuWidth: number): number {
    return Math.max(12, Math.min(this.exploreContextMenuX - 18,
      this.exploreViewportWidth - menuWidth - 12));
  }

  exploreContextMenuTop(menuHeight: number): number {
    const below = this.exploreContextMenuY + 12;
    if (below + menuHeight <= this.exploreViewportHeight - 12) return below;
    return Math.max(this.statusBarHeight + 8, this.exploreContextMenuY - menuHeight - 12);
  }

  getFilteredExploreSourceOptions(): ExploreSourceOption[] {
    let options = this.sourceOptions;
    if (this.activeExploreSourceGroup !== '__all__') {
      options = options.filter((option: ExploreSourceOption) =>
        this.exploreSourceGroupLabel(option.sourceGroup) === this.activeExploreSourceGroup);
    }
    const keyword = this.exploreSourceFilterKeyword;
    if (!keyword) {
      return options;
    }
    return options.filter((option: ExploreSourceOption) => {
      const searchable = `${option.sourceName || ''}\n${option.sourceUrl || ''}\n${option.sourceGroup || ''}\n${(option.platforms || []).join(' ')}`
        .toLowerCase();
      return searchable.includes(keyword);
    });
  }

  buildExploreSourceGroups(): string[] {
    const groups: string[] = [];
    for (const option of this.sourceOptions) {
      const group = this.exploreSourceGroupLabel(option.sourceGroup);
      if (!groups.includes(group)) groups.push(group);
    }
    return groups;
  }

  exploreSourceGroupLabel(group: string): string {
    const normalized = (group || '').trim();
    return normalized || '未分组';
  }

  selectExploreSourceGroup(groupKey: string): void {
    if (groupKey === '__all__' || this.exploreSourceGroups.includes(groupKey)) {
      this.activeExploreSourceGroup = groupKey;
    }
  }

  switchExploreSourceGroupBySwipe(offsetX: number): void {
    if (Math.abs(offsetX) < 36) return;
    const groups = ['__all__'].concat(this.exploreSourceGroups);
    const currentIndex = Math.max(0, groups.indexOf(this.activeExploreSourceGroup));
    const direction = offsetX < 0 ? 1 : -1;
    const targetIndex = Math.max(0, Math.min(groups.length - 1, currentIndex + direction));
    if (targetIndex !== currentIndex) {
      this.activeExploreSourceGroup = groups[targetIndex];
    }
  }

  switchExplorePlatform(platform: string): void {
    if (this.selectedPlatform === platform) {
      return;
    }
    this.selectedPlatform = platform;
    this.selectedIndex = 0;
    this.books = [];
    this.status = `正在切换到 ${platform}...`;
    AppStorage.setOrCreate('explorePlatform', platform);
    this.saveExploreSelection();
    this.loadEntries(platform);
  }

  switchExploreSource(option: ExploreSourceOption): void {
    if (this.selectedSourceUrl === option.sourceUrl) {
      return;
    }
    this.selectedSourceName = option.sourceName;
    this.selectedSourceUrl = option.sourceUrl;
    this.platformNames = this.getSelectedSourcePlatforms();
    this.normalizeSelectedPlatform();
    this.selectedIndex = 0;
    this.books = [];
    this.status = `正在切换到 ${option.sourceName}...`;
    AppStorage.setOrCreate('exploreSourceUrl', option.sourceUrl);
    this.saveExploreSelection();
    this.loadEntries();
  }

  beginExploreLoad(): number {
    this.exploreLoadVersion++;
    this.isLoading = true;
    return this.exploreLoadVersion;
  }

  isCurrentExploreLoad(loadVersion: number): boolean {
    return loadVersion === this.exploreLoadVersion;
  }

  finishExploreLoad(loadVersion: number): void {
    if (this.isCurrentExploreLoad(loadVersion)) {
      this.isLoading = false;
    }
  }

  normalizeSelectedPlatform(): void {
    if (this.platformNames.length === 0) {
      return;
    }
    if (!this.platformNames.includes(this.selectedPlatform)) {
      this.selectedPlatform = this.platformNames.length > 0 ? this.platformNames[0] : '番茄';
      AppStorage.setOrCreate('explorePlatform', this.selectedPlatform);
      this.saveExploreSelection();
    }
  }

  async restoreExploreSelectionFromSettings(): Promise<void> {
    try {
      const settings = await SearchExploreSettingsStore.load(getContext(this));
      const storedSourceUrl = settings.exploreSourceUrl || AppStorage.get<string>('exploreSourceUrl') || '';
      const storedPlatform = settings.explorePlatform || AppStorage.get<string>('explorePlatform') || '';
      if (storedSourceUrl) {
        this.selectedSourceUrl = storedSourceUrl;
        settings.exploreSourceUrl = storedSourceUrl;
      }
      if (storedPlatform) {
        this.selectedPlatform = storedPlatform;
        settings.explorePlatform = storedPlatform;
      }
      SearchExploreSettingsStore.applyToStorage(settings);
    } catch (e) {
      console.warn('恢复发现页选择失败:', e);
    }
  }

  saveExploreSelection(): void {
    AppStorage.setOrCreate('exploreSourceUrl', this.selectedSourceUrl);
    AppStorage.setOrCreate('explorePlatform', this.selectedPlatform);
    SearchExploreSettingsStore.saveExploreSelection(
      getContext(this),
      this.selectedSourceUrl,
      this.selectedPlatform
    ).catch((e: Error) => {
      console.warn('保存发现页选择失败:', e);
    });
  }

  async syncExploreShelfStatus(books: SearchBook[]): Promise<void> {
    try {
      const version = this.shelfStatusVersion;
      const keys = await this.loadExploreShelfKeys(books);
      if (version === this.shelfStatusVersion) {
        this.shelfBookKeys = keys;
      }
    } catch (e) {
      console.error('同步发现书架状态失败:', e);
    }
  }

  async loadExploreShelfKeys(books: SearchBook[]): Promise<string[]> {
    return await SearchBookShelfHelper.syncShelfKeys(getContext(this), books);
  }

  isSearchBookInShelf(book: SearchBook): boolean {
    return SearchBookShelfHelper.isInShelf(book, this.shelfBookKeys);
  }

  isSearchBookJoiningShelf(book: SearchBook): boolean {
    return SearchBookShelfHelper.isBusy(book, this.addingShelfBookKeys);
  }

  async toggleSearchBookShelf(searchBook: SearchBook): Promise<void> {
    if (this.isSearchBookJoiningShelf(searchBook)) {
      return;
    }

    if (this.isSearchBookInShelf(searchBook)) {
      await this.removeSearchBookFromShelf(searchBook);
    } else {
      await this.addSearchBookToShelf(searchBook);
    }
  }

  async removeSearchBookFromShelf(searchBook: SearchBook): Promise<void> {
    try {
      const change = await SearchBookShelfHelper.removeFromShelf(getContext(this), searchBook);
      this.shelfStatusVersion++;
      this.shelfBookKeys = SearchBookShelfHelper.withoutKey(this.shelfBookKeys, change.requestKey);
    } catch (e) {
      console.error('移出书架失败:', e);
      promptAction.showToast({ message: '移出书架失败' });
    }
  }

  markSearchBookInShelf(bookKey: string): void {
    const next = SearchBookShelfHelper.withAddedKey(this.shelfBookKeys, bookKey);
    if (next !== this.shelfBookKeys) {
      this.shelfStatusVersion++;
      this.shelfBookKeys = next;
    }
  }

  markSearchBookJoining(bookKey: string): void {
    const next = SearchBookShelfHelper.withAddedKey(this.addingShelfBookKeys, bookKey);
    if (next !== this.addingShelfBookKeys) {
      this.addingShelfBookKeys = next;
    }
  }

  unmarkSearchBookJoining(bookKey: string): void {
    const next = SearchBookShelfHelper.withoutKey(this.addingShelfBookKeys, bookKey);
    if (next !== this.addingShelfBookKeys) {
      this.addingShelfBookKeys = next;
    }
  }

  shouldShowExploreStatus(): boolean {
    if (!this.status) {
      return false;
    }
    if (this.verificationUrl) {
      return true;
    }
    return this.books.length === 0;
  }

  getSelectedSourcePlatforms(): string[] {
    const option = this.getSelectedSourceOption();
    return option ? option.platforms : [];
  }

  getSelectedSourceUrl(): string {
    const option = this.getSelectedSourceOption();
    return option ? option.sourceUrl : '';
  }

  getSelectedSourceOption(): ExploreSourceOption | null {
    for (const option of this.sourceOptions) {
      if (option.sourceUrl === this.selectedSourceUrl) return option;
    }
    return null;
  }

  getSelectedSiteLabel(): string {
    return this.platformNames.length > 0 ? this.selectedPlatform : this.selectedSourceName;
  }

  openVerification(): void {
    const url = this.verificationUrl || AppStorage.get<string>('pendingVerificationUrl') || '';
    if (!url) {
      promptAction.showToast({ message: '暂无需要验证的网页' });
      return;
    }
    router.pushUrl({
      url: 'pages/VerifyWeb',
      params: {
        url: url,
        title: this.verificationTitle || '网页验证'
      }
    });
  }

  getActiveEntries(): ExploreEntry[] {
    if (!this.selectedSourceUrl) return this.entries;
    return this.entries.filter(entry => entry.sourceUrl === this.selectedSourceUrl);
  }

  exploreTopOverlayHeight(): number {
    let height = this.statusBarHeight + 56;
    if (this.platformNames.length > 0) {
      height += 48;
    }
    if (this.getActiveEntries().length > 0) {
      height += 44;
    }
    if (this.shouldShowExploreStatus()) {
      height += 40;
    }
    return height;
  }

  resultListBottomInset(): number {
    const comfortableGap = 20;
    if (deviceInfo.sdkApiVersion < 23) {
      return comfortableGap;
    }
    const floatingTabHeight = 56;
    return floatingTabHeight + Math.max(this.navBarHeight, 8) + comfortableGap;
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

  glassCardColor(): string {
    return ThemeRuntime.cardColor(this.appDarkMode);
  }

  glassBorderColor(): string {
    return this.appDarkMode ? '#262A31' : '#FFFFFF';
  }

  glassShadowColor(): string {
    return '#00000000';
  }

  primaryTextColor(): string {
    return ThemeRuntime.primaryTextColor(this.appDarkMode);
  }

  secondaryTextColor(): string {
    return ThemeRuntime.subTextColor(this.appDarkMode);
  }

  subTextColor(): string {
    return ThemeRuntime.subTextColor(this.appDarkMode);
  }

  accentColor(): string {
    return ThemeRuntime.accentColor(this.appDarkMode);
  }

  buttonColor(): string {
    return ThemeRuntime.buttonColor(this.appDarkMode);
  }

  exploreSelectedBackgroundColor(): string {
    const color = this.accentColor();
    if (/^#[0-9A-Fa-f]{6}$/.test(color)) {
      return `#11${color.substring(1)}`;
    }
    return this.appDarkMode ? '#112A6FCC' : '#11007DFF';
  }
}

@Component
struct SearchPage {
  @Prop statusBarHeight: number = 0;
  @Prop navBarHeight: number = 0;
  @Prop @Watch('onActiveChanged') isActive: boolean = false;
  @State keyword: string = '';
  @State searchResults: SearchBook[] = [];
  @State shelfBookKeys: string[] = [];
  @State addingShelfBookKeys: string[] = [];
  @State isSearching: boolean = false;
  @State searchHistory: string[] = [];
  @State searchHistoryExpanded: boolean = false;
  @State searchHistoryEditing: boolean = false;
  @State showSearchHistoryDropdown: boolean = false;
  @State showResult: boolean = false;
  @State statusMessage: string = '';
  @State verificationUrl: string = '';
  @State verificationTitle: string = '';
  @State showSearchSettingsDialog: boolean = false;
  @State sourceGroups: string[] = [];
  @State searchViewportWidth: number = 360;
  @StorageLink('shelfUpdateTime') @Watch('onShelfChanged') shelfUpdateTime: number = 0;
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;
  @StorageLink('searchExploreShowResultCover') searchExploreShowResultCover: boolean = true;
  @StorageLink('searchExploreUseBookshelfCoverGallery') searchExploreUseBookshelfCoverGallery: boolean = false;
  @StorageLink('searchExploreShowResultTags') searchExploreShowResultTags: boolean = true;
  @StorageLink('searchExplorePromptAddToShelfOnBack') searchExplorePromptAddToShelfOnBack: boolean = true;
  @StorageLink('searchExploreExactSearch') exactSearch: boolean = false;
  @StorageLink('searchExploreExactSearchMatchAuthor') exactSearchMatchAuthor: boolean = true;
  @StorageLink('searchExploreShowSearchProgress') showSearchProgress: boolean = true;
  @StorageLink('searchExploreSearchConcurrency') searchConcurrency: number = 6;
  @StorageLink('searchExploreSelectedSourceGroups') selectedSourceGroupsRaw: string = '';
  @StorageLink('singleSourceSearchUrl') singleSourceSearchUrl: string = '';
  @StorageLink('singleSourceSearchName') singleSourceSearchName: string = '';
  @StorageLink('appLightButtonColor') appLightButtonColor: string = '#007DFF';
  @StorageLink('appDarkButtonColor') appDarkButtonColor: string = '#3F8CFF';
  private coordinator: SearchCoordinator | null = null;
  private hasInitialized: boolean = false;
  private shelfStatusVersion: number = 0;
  private shelfSyncRunning: boolean = false;
  private pendingShelfSyncBooks: SearchBook[] = [];
  private searchResultKeySet: Set<string> = new Set<string>();
  private searchResultScroller: ListScroller = new ListScroller();
  private searchSessionId: number = 0;
  private readonly NO_SOURCE_GROUPS_SELECTED: string = '__NO_SOURCE_GROUPS_SELECTED__';

  aboutToAppear() {
    if (this.isActive) {
      this.initPage();
    }
  }

  onActiveChanged(): void {
    if (this.isActive) {
      this.initPage();
      this.refreshSearchShelfStatus();
    }
  }

  async initPage() {
    if (this.hasInitialized) {
      return;
    }
    this.hasInitialized = true;
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      const keywords = await db.getSearchKeywords();
      this.searchHistory = keywords.map(k => k.keyword);
      await this.loadSourceGroups(db);
      const pendingKeyword = AppStorage.get<string>('singleSourceSearchKeyword') || '';
      if (pendingKeyword && this.singleSourceSearchUrl) {
        AppStorage.setOrCreate('singleSourceSearchKeyword', '');
        this.keyword = pendingKeyword;
        setTimeout((): void => {
          this.doSearch();
        }, 0);
      }
    } catch (e) {
      console.error('初始化搜索页失败:', e);
    }
  }

  build() {
    Stack() {
      Column() {
        Column() {
        Row() {
          Row() {
            TextInput({ placeholder: '搜索书籍', text: this.keyword })
              .layoutWeight(1)
              .height(40)
              .enterKeyType(EnterKeyType.Search)
              .backgroundColor('#00000000')
              .fontColor(this.primaryTextColor())
              .placeholderColor(this.subTextColor())
              .padding({ left: 16, right: 4 })
              .onFocus(() => {
                this.showSearchHistoryDropdown = this.keyword.trim().length === 0 && this.searchHistory.length > 0;
              })
              .onClick(() => {
                this.showSearchHistoryDropdown = this.keyword.trim().length === 0 && this.searchHistory.length > 0;
              })
              .onChange((value: string) => {
                this.keyword = value;
                this.showSearchHistoryDropdown = value.trim().length === 0 && this.searchHistory.length > 0;
              })
              .onSubmit(() => {
                this.submitKeywordSearch();
              })

            this.searchSettingIcon()
          }
          .layoutWeight(1)
          .height(40)
          .borderRadius(20)
          .backgroundColor(this.glassCardColor())
          .border({ width: ThemeRuntime.glassBorderWidth(), color: this.glassBorderColor() })
          .shadow({ radius: ThemeRuntime.glassShadowRadius(), color: this.glassShadowColor(), offsetX: ThemeRuntime.glassShadowOffsetX(), offsetY: ThemeRuntime.glassShadowOffsetY() })
          .alignItems(VerticalAlign.Center)

          ImmersiveBackButton({
            icon: this.isSearching ? $r('sys.symbol.xmark') : $r('sys.symbol.magnifyingglass'),
            iconOffsetX: 0,
            iconColor: this.isSearching ? '#E53935' : this.primaryTextColor(),
            darkMode: this.appDarkMode,
            buttonSize: 40,
            containerWidth: 40,
            containerHeight: 40,
            startInset: 0,
            materialScale: 0.83,
            accessibilityLabel: this.isSearching ? '停止搜索' : '搜索',
            onBack: () => {
              if (this.isSearching) {
                this.showSearchHistoryDropdown = false;
                this.searchSessionId++;
                this.coordinator?.cancel();
                this.coordinator = null;
                this.isSearching = false;
                this.statusMessage = '搜索已停止';
              } else {
                this.showSearchHistoryDropdown = false;
                this.hideKeyboard();
                this.doSearch();
              }
            }
          })
            .margin({ left: 8, right: -24 })
        }
        .width('100%')
        .height(56 + this.statusBarHeight)
        .padding({ left: 16, right: 16, top: this.statusBarHeight })
        .alignItems(VerticalAlign.Center)

        if (this.singleSourceSearchUrl) {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(14)
              .fontColor([this.buttonColor()])
            Text(`仅搜索：${this.singleSourceSearchName || this.singleSourceSearchUrl}`)
              .fontSize(13)
              .fontColor(this.primaryTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text('×')
              .fontSize(18)
              .fontColor(this.secondaryTextColor())
              .width(28)
              .height(28)
              .textAlign(TextAlign.Center)
              .onClick(() => this.clearSingleSourceSearch())
          }
          .width('calc(100% - 32vp)')
          .height(36)
          .padding({ left: 12, right: 4 })
          .margin({ left: 16, right: 16, bottom: 6 })
          .borderRadius(18)
          .backgroundColor(this.glassCardColor())
          .border({ width: 1, color: this.buttonColor() })
          .alignItems(VerticalAlign.Center)
        }

        if (this.statusMessage) {
          Row() {
            Text(this.statusMessage)
              .fontSize(14)
              .fontColor(this.secondaryTextColor())
              .layoutWeight(1)
              .textAlign(TextAlign.Center)

            if (this.verificationUrl) {
              Button('去验证')
                .height(28)
                .fontSize(12)
                .borderRadius(14)
                .backgroundColor(this.buttonColor())
                .fontColor('#FFFFFF')
                .margin({ right: 12 })
                .onClick(() => {
                  this.openVerification();
                })
            }
          }
          .width('100%')
          .height(40)
          .backgroundColor(this.statusMessageColor())
          .alignItems(VerticalAlign.Center)
        }
        }
        .width('100%')
        .position({ x: 0, y: 0 })
        .zIndex(4)
        .backgroundColor(ThemeRuntime.topBarColor(this.appDarkMode))
        .backdropBlur(ThemeRuntime.topBarBlur())

        if (this.showResult && this.searchResults.length > 0) {
          SearchBookResultList({
            books: this.searchResults,
            scroller: this.searchResultScroller,
            shelfBookKeys: this.shelfBookKeys,
            busyBookKeys: this.addingShelfBookKeys,
            showLoadingMore: this.isSearching,
            showResultCover: this.searchExploreShowResultCover,
            useBookshelfCoverGallery: this.searchExploreUseBookshelfCoverGallery,
            showResultTags: this.searchExploreShowResultTags,
            pageColor: this.pageColor(),
            cardColor: this.glassCardColor(),
            itemBorderColor: this.glassBorderColor(),
            itemBorderWidth: 1,
            shadowColor: this.glassShadowColor(),
            primaryTextColor: this.primaryTextColor(),
            secondaryTextColor: this.secondaryTextColor(),
            subTextColor: this.subTextColor(),
            topPadding: this.searchTopOverlayHeight(),
            bottomPadding: this.resultListBottomInset(),
            onOpenBook: (book: SearchBook) => {
              this.openSearchBookDetail(book);
            },
            onToggleShelf: (book: SearchBook) => {
              this.toggleSearchBookShelf(book);
            }
          })
        } else if (this.isSearching) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
            Text('搜索中...')
              .fontSize(14)
              .fontColor(this.subTextColor())
              .margin({ top: 8 })
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ top: this.searchTopOverlayHeight() })
          .justifyContent(FlexAlign.Center)
        } else if (this.showResult && this.searchResults.length === 0) {
          Column() {
            Text('未找到相关书籍')
              .fontSize(16)
              .fontColor(this.subTextColor())
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ top: this.searchTopOverlayHeight() })
          .justifyContent(FlexAlign.Center)
        } else {
          Column() {
            Text('输入关键词搜索书籍')
              .fontSize(16)
              .fontColor(this.subTextColor())
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ top: this.searchTopOverlayHeight() })
          .justifyContent(FlexAlign.Center)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageColor())
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])

      if (this.showSearchHistoryDropdown && this.searchHistory.length > 0) {
        this.searchHistoryDropdown()
      }

      if (this.showSearchSettingsDialog) {
        this.searchSettingsDialog()
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const width = typeof newValue.width === 'number' ? newValue.width : Number.parseFloat(`${newValue.width}`);
      if (Number.isFinite(width) && width > 0) {
        this.searchViewportWidth = width;
      }
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  searchHistoryPopupPanelWidth(): number {
    return Math.min(420, Math.max(200, this.searchViewportWidth - 32));
  }

  searchSettingsPopupPanelWidth(): number {
    return Math.min(272, Math.max(200, this.searchViewportWidth - 32));
  }

  searchSettingsPopupPanelLeft(): number {
    const panelWidth = this.searchSettingsPopupPanelWidth();
    return Math.max(16, this.searchViewportWidth - panelWidth - 40);
  }

  @Builder
  searchHistoryDropdown() {
    Column() {
      Row() {
        Text('搜索历史')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
          .layoutWeight(1)

        Text('清除')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.secondaryTextColor())
          .height(32)
          .padding({ left: 12, right: 4 })
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.clearSearchHistory();
          })
      }
      .width('100%')
      .height(46)
      .padding({ left: 14, right: 10 })
      .alignItems(VerticalAlign.Center)

      Divider()
        .color(this.glassBorderColor())
        .margin({ left: 14, right: 14 })

      Scroll() {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.searchHistory, (keyword: string) => {
            Row() {
              Text(keyword)
                .fontSize(14)
                .fontColor(this.secondaryTextColor())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .constraintSize({ maxWidth: '72%' })
            .height(34)
            .padding({ left: 12, right: 12 })
            .margin({ right: 8, bottom: 8 })
            .borderRadius(17)
            .backgroundColor(this.buttonBackgroundColor())
            .alignItems(VerticalAlign.Center)
            .priorityGesture(
              GestureGroup(GestureMode.Exclusive,
                LongPressGesture({ repeat: false })
                  .onAction(() => {
                    this.deleteSearchHistoryItem(keyword);
                  }),
                TapGesture()
                  .onAction(() => {
                    this.showSearchHistoryDropdown = false;
                    this.searchFromHistory(keyword);
                  })
              ),
              GestureMask.IgnoreInternal
            )
          }, (keyword: string) => keyword)
        }
        .width('100%')
        .padding({ left: 14, right: 6, top: 12, bottom: 4 })
      }
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .width('100%')
      .constraintSize({ maxHeight: 260 })
    }
    .width(this.searchHistoryPopupPanelWidth())
    .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
    .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
    .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
    .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
    .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
    .position({
      x: 16,
      y: this.statusBarHeight + (this.singleSourceSearchUrl ? 92 : 52)
    })
    .zIndex(10)
  }

  searchFromHistory(keyword: string): void {
    this.keyword = keyword;
    this.hideKeyboard();
    this.doSearch();
  }

  submitKeywordSearch(): void {
    this.showSearchHistoryDropdown = false;
    this.hideKeyboard();
    this.doSearch();
  }

  async deleteSearchHistoryItem(keyword: string): Promise<void> {
    try {
      await AppDatabase.getInstance().deleteSearchKeyword(keyword);
      this.searchHistory = this.searchHistory.filter((item: string) => item !== keyword);
      promptAction.showToast({ message: '已删除该条搜索记录' });
      if (this.searchHistory.length === 0) {
        this.searchHistoryEditing = false;
        this.searchHistoryExpanded = false;
        this.showSearchHistoryDropdown = false;
      }
    } catch (e) {
      console.error('删除搜索历史失败:', e);
      promptAction.showToast({ message: '删除失败' });
    }
  }

  async clearSearchHistory(): Promise<void> {
    try {
      await AppDatabase.getInstance().clearSearchKeywords();
      this.searchHistory = [];
      this.searchHistoryEditing = false;
      this.searchHistoryExpanded = false;
      this.showSearchHistoryDropdown = false;
    } catch (e) {
      console.error('清空搜索历史失败:', e);
      promptAction.showToast({ message: '清空失败' });
    }
  }

  clearSingleSourceSearch(): void {
    this.searchSessionId++;
    this.coordinator?.cancel();
    this.coordinator = null;
    this.isSearching = false;
    this.singleSourceSearchUrl = '';
    this.singleSourceSearchName = '';
    this.searchResults = [];
    this.searchResultKeySet.clear();
    this.showResult = false;
    this.statusMessage = '';
    this.verificationUrl = '';
    this.verificationTitle = '';
  }

  async doSearch() {
    const keyword = this.keyword.trim();
    if (!keyword) {
      promptAction.showToast({ message: '请输入搜索关键词' });
      return;
    }

    let sessionId = 0;
    let activeCoordinator: SearchCoordinator | null = null;
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      const targetSources: BookSource[] = [];
      if (this.singleSourceSearchUrl) {
        const targetSource = await db.getBookSource(this.singleSourceSearchUrl);
        if (!targetSource) {
          promptAction.showToast({ message: '指定书源不存在或已被删除' });
          this.clearSingleSourceSearch();
          return;
        }
        targetSources.push(targetSource);
      }

      // 点击搜索后立即保存，不再等待搜索任务完成。
      await db.saveSearchKeyword(keyword);
      const keywords = await db.getSearchKeywords();
      this.searchHistory = keywords.map(k => k.keyword);

      this.isSearching = true;
      this.showResult = true;
      this.searchResults = [];
      this.searchResultKeySet.clear();
      this.statusMessage = targetSources.length > 0 ?
        `正在通过 ${this.singleSourceSearchName || targetSources[0].bookSourceName} 搜索...` : '正在搜索...';
      this.verificationUrl = '';
      this.verificationTitle = '';
      this.coordinator?.cancel();
      sessionId = ++this.searchSessionId;
      const coordinator = new SearchCoordinator(SearchExploreSettingsStore.getSearchConcurrency());
      activeCoordinator = coordinator;
      this.coordinator = coordinator;

      const callback: SearchCallback = (p: SearchProgress) => {
        if (sessionId !== this.searchSessionId || this.coordinator !== coordinator) {
          return;
        }
        if (p.finished) {
          this.searchResults = p.results;
          this.rebuildSearchResultKeys(p.results);
        } else if (p.deltaResults && p.deltaResults.length > 0) {
          this.searchResults = this.appendSearchResults(this.searchResults, p.deltaResults);
        }
        if (this.showSearchProgress) {
          this.statusMessage = p.status;
        }
        this.verificationUrl = p.verificationUrl || AppStorage.get<string>('pendingVerificationUrl') || '';
        this.verificationTitle = p.verificationTitle || AppStorage.get<string>('pendingVerificationTitle') || '网页验证';
        if (p.finished) {
          this.requestSearchShelfStatusSync(this.searchResults);
        }
        if (p.finished) {
          this.isSearching = false;
        }
      };

      const allBooks = await coordinator.search(keyword, callback, {
        exactMatch: this.exactSearch,
        exactMatchAuthor: this.exactSearchMatchAuthor,
        sourceGroups: targetSources.length > 0 ? [] : this.searchSourceGroups(),
        targetSources: targetSources
      });
      if (sessionId !== this.searchSessionId || this.coordinator !== coordinator) {
        return;
      }
      const verifyUrl = this.verificationUrl || AppStorage.get<string>('pendingVerificationUrl') || '';
      if (!this.showSearchProgress || !this.isSearching) {
        const failureReason = coordinator.getLastFailureReason();
        const resultText = allBooks.length > 0 ? `搜索完成，共找到 ${allBooks.length} 本书` :
          (failureReason ? `搜索完成：${failureReason}` : '搜索完成，未找到相关书籍');
        this.statusMessage = verifyUrl ? `${resultText}；有书源需要网页验证` : resultText;
      }
    } catch (e) {
      if (sessionId !== this.searchSessionId || this.coordinator !== activeCoordinator) {
        return;
      }
      console.error('搜索失败:', e);
      this.isSearching = false;
      this.statusMessage = '搜索失败';
    } finally {
      if (sessionId === this.searchSessionId && this.coordinator === activeCoordinator && !this.isSearching) {
        this.coordinator = null;
      }
    }
  }

  hideKeyboard(): void {
    try {
      this.getUIContext().getFocusController().clearFocus();
    } catch (e) {
    }
  }

  onShelfChanged(): void {
    this.refreshSearchShelfStatus();
  }

  refreshSearchShelfStatus(): void {
    if (this.searchResults.length > 0) {
      this.requestSearchShelfStatusSync(this.searchResults);
    }
  }

  requestSearchShelfStatusSync(books: SearchBook[]): void {
    this.pendingShelfSyncBooks = books;
    if (!this.shelfSyncRunning) {
      this.drainSearchShelfStatusSync();
    }
  }

  appendSearchResults(existing: SearchBook[], incoming: SearchBook[]): SearchBook[] {
    const merged = existing.slice();
    for (const book of incoming) {
      const key = `${book.origin || ''}::${book.bookUrl || ''}`;
      if (!book.name || !book.bookUrl) continue;
      if (this.searchResultKeySet.has(key)) continue;
      this.searchResultKeySet.add(key);
      merged.push(book);
    }
    return merged;
  }

  rebuildSearchResultKeys(books: SearchBook[]): void {
    this.searchResultKeySet.clear();
    for (const book of books) {
      if (!book.name || !book.bookUrl) continue;
      this.searchResultKeySet.add(`${book.origin || ''}::${book.bookUrl || ''}`);
    }
  }

  async drainSearchShelfStatusSync(): Promise<void> {
    this.shelfSyncRunning = true;
    while (this.pendingShelfSyncBooks.length > 0) {
      const books = this.pendingShelfSyncBooks;
      this.pendingShelfSyncBooks = [];
      await this.syncSearchShelfStatus(books);
    }
    this.shelfSyncRunning = false;
  }

  async syncSearchShelfStatus(books: SearchBook[]): Promise<void> {
    try {
      const version = this.shelfStatusVersion;
      const keys = await SearchBookShelfHelper.syncShelfKeys(getContext(this), books);
      if (version === this.shelfStatusVersion) {
        this.shelfBookKeys = keys;
      }
    } catch (e) {
      console.error('同步搜索书架状态失败:', e);
    }
  }

  isSearchBookInShelf(book: SearchBook): boolean {
    return SearchBookShelfHelper.isInShelf(book, this.shelfBookKeys);
  }

  isSearchBookJoiningShelf(book: SearchBook): boolean {
    return SearchBookShelfHelper.isBusy(book, this.addingShelfBookKeys);
  }

  async toggleSearchBookShelf(searchBook: SearchBook): Promise<void> {
    if (this.isSearchBookJoiningShelf(searchBook)) {
      return;
    }

    if (this.isSearchBookInShelf(searchBook)) {
      await this.removeSearchBookFromShelf(searchBook);
    } else {
      await this.addSearchBookToShelf(searchBook);
    }
  }

  async addSearchBookToShelf(searchBook: SearchBook): Promise<void> {
    const searchKey = SearchBookShelfHelper.keyOf(searchBook);
    this.markSearchBookJoining(searchKey);

    try {
      const change = await SearchBookShelfHelper.addToShelf(getContext(this), searchBook);
      this.markSearchBookInShelf(change.shelfKey || change.requestKey);
    } catch (e) {
      console.error('加入书架失败:', e);
      promptAction.showToast({ message: '加入书架失败' });
    } finally {
      this.unmarkSearchBookJoining(searchKey);
    }
  }

  async removeSearchBookFromShelf(searchBook: SearchBook): Promise<void> {
    try {
      const change = await SearchBookShelfHelper.removeFromShelf(getContext(this), searchBook);
      this.shelfStatusVersion++;
      this.shelfBookKeys = SearchBookShelfHelper.withoutKey(this.shelfBookKeys, change.requestKey);
    } catch (e) {
      console.error('移出书架失败:', e);
      promptAction.showToast({ message: '移出书架失败' });
    }
  }

  markSearchBookInShelf(bookKey: string): void {
    const next = SearchBookShelfHelper.withAddedKey(this.shelfBookKeys, bookKey);
    if (next !== this.shelfBookKeys) {
      this.shelfStatusVersion++;
      this.shelfBookKeys = next;
    }
  }

  markSearchBookJoining(bookKey: string): void {
    const next = SearchBookShelfHelper.withAddedKey(this.addingShelfBookKeys, bookKey);
    if (next !== this.addingShelfBookKeys) {
      this.addingShelfBookKeys = next;
    }
  }

  unmarkSearchBookJoining(bookKey: string): void {
    const next = SearchBookShelfHelper.withoutKey(this.addingShelfBookKeys, bookKey);
    if (next !== this.addingShelfBookKeys) {
      this.addingShelfBookKeys = next;
    }
  }

  openSearchBookDetail(book: SearchBook) {
    router.pushUrl({
      url: 'pages/SearchBookDetail',
      params: {
        bookUrl: book.bookUrl,
        tocUrl: book.tocUrl,
        origin: book.origin,
        originName: book.originName,
        name: book.name,
        author: book.author,
        kind: book.kind,
        coverUrl: book.coverUrl,
        intro: book.intro,
        latestChapterTitle: book.latestChapterTitle,
        wordCount: book.wordCount,
        type: String(book.type || 0),
        variable: book.variable || '',
        promptAddToShelfOnBack: this.searchExplorePromptAddToShelfOnBack ? 'true' : 'false'
      }
    });
  }

  async loadSourceGroups(db: AppDatabase = AppDatabase.getInstance()): Promise<void> {
    const sources = await db.getAllBookSources();
    const groups: string[] = [];
    for (const source of sources) {
      const group = this.normalizeSourceGroup(source);
      if (!groups.includes(group)) {
        groups.push(group);
      }
    }
    this.sourceGroups = groups.sort((a: string, b: string) => a.localeCompare(b));
    if (!this.isAllSourceGroupsSelected() && !this.isNoSourceGroupsSelected()) {
      this.saveSelectedSourceGroups(this.selectedSourceGroups().filter((group: string) => this.sourceGroups.includes(group)));
    }
  }

  normalizeSourceGroup(source: BookSource): string {
    const group = (source.bookSourceGroup || '').trim();
    return group || '未分组';
  }

  isAllSourceGroupsSelected(): boolean {
    const selectedGroups = this.selectedSourceGroups();
    return !this.isNoSourceGroupsSelected() &&
      (this.selectedSourceGroupsRaw.trim() === '' || selectedGroups.length >= this.sourceGroups.length);
  }

  isNoSourceGroupsSelected(): boolean {
    return this.selectedSourceGroupsRaw.trim() === this.NO_SOURCE_GROUPS_SELECTED;
  }

  isSourceGroupSelected(group: string): boolean {
    return !this.isNoSourceGroupsSelected() &&
      (this.isAllSourceGroupsSelected() || this.selectedSourceGroups().includes(group));
  }

  setSourceGroupSelected(group: string, selected: boolean): void {
    const selectedGroups = this.isAllSourceGroupsSelected() ? this.sourceGroups : this.selectedSourceGroups();
    if (selected) {
      if (!selectedGroups.includes(group)) {
        this.saveSelectedSourceGroups(selectedGroups.concat([group]));
      }
      return;
    }
    this.saveSelectedSourceGroups(selectedGroups.filter((item: string) => item !== group));
  }

  searchSourceGroupSummary(): string {
    if (this.isAllSourceGroupsSelected()) {
      return '全部书源';
    }
    if (this.isNoSourceGroupsSelected()) {
      return '未选择书源';
    }
    return `已选 ${this.selectedSourceGroups().length} 个分组`;
  }

  selectedSourceGroups(): string[] {
    const raw = this.selectedSourceGroupsRaw.trim();
    if (!raw || raw === this.NO_SOURCE_GROUPS_SELECTED) {
      return [];
    }
    return raw.split('\n').map((group: string) => group.trim()).filter((group: string) => group);
  }

  searchSourceGroups(): string[] {
    if (this.isNoSourceGroupsSelected()) {
      return [this.NO_SOURCE_GROUPS_SELECTED];
    }
    return this.isAllSourceGroupsSelected() ? [] : this.selectedSourceGroups();
  }

  saveSelectedSourceGroups(groups: string[]): void {
    const normalized: string[] = [];
    for (const group of groups) {
      const value = (group || '').trim();
      if (value && !normalized.includes(value)) {
        normalized.push(value);
      }
    }
    this.selectedSourceGroupsRaw = normalized.length > 0 ? normalized.join('\n') : this.NO_SOURCE_GROUPS_SELECTED;
    if (normalized.length >= this.sourceGroups.length) {
      this.selectedSourceGroupsRaw = '';
    }
    this.saveSearchExploreSettings();
  }

  saveAllSourceGroupsSelected(selected: boolean): void {
    this.selectedSourceGroupsRaw = selected ? '' : this.NO_SOURCE_GROUPS_SELECTED;
    this.saveSearchExploreSettings();
  }

  saveSearchExploreSettings(): void {
    SearchExploreSettingsStore.load(getContext(this)).then((settings: SearchExploreSettings) => {
      settings.showResultCover = this.searchExploreShowResultCover;
      settings.useBookshelfCoverGallery = this.searchExploreUseBookshelfCoverGallery;
      settings.showResultTags = this.searchExploreShowResultTags;
      settings.promptAddToShelfOnBack = this.searchExplorePromptAddToShelfOnBack;
      settings.exactSearch = this.exactSearch;
      settings.exactSearchMatchAuthor = this.exactSearchMatchAuthor;
      settings.showSearchProgress = this.showSearchProgress;
      settings.searchConcurrency = SearchExploreSettingsStore.normalizeSearchConcurrency(this.searchConcurrency);
      settings.selectedSourceGroupsRaw = this.selectedSourceGroupsRaw;
      settings.sourceSortRaw = AppStorage.get<string>('searchExploreSourceSort') || '';
      SearchExploreSettingsStore.applyToStorage(settings);
      return SearchExploreSettingsStore.save(getContext(this), settings);
    }).catch((e: Error) => {
      console.warn('保存搜索设置失败:', e);
    });
  }

  @Builder
  searchSettingsDialog() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .onClick(() => {
          this.showSearchSettingsDialog = false;
        })

      Column() {
        Text('搜索设置')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: 16 })

        this.switchSettingRow('精准搜索', this.exactSearch, (checked: boolean) => {
          this.exactSearch = checked;
          this.saveSearchExploreSettings();
        })

        this.switchSettingRow('匹配作者', this.exactSearchMatchAuthor, (checked: boolean) => {
          this.exactSearchMatchAuthor = checked;
          this.saveSearchExploreSettings();
        })

        this.switchSettingRow('显示搜索进度', this.showSearchProgress, (checked: boolean) => {
          this.showSearchProgress = checked;
          this.saveSearchExploreSettings();
        })

        this.numberSettingRow('搜索并发数', this.searchConcurrency, 1, 12, (value: number) => {
          this.searchConcurrency = SearchExploreSettingsStore.normalizeSearchConcurrency(value);
          this.saveSearchExploreSettings();
        })

        Row() {
          Text('搜索书源设置')
            .fontSize(15)
            .fontColor(this.primaryTextColor())
            .layoutWeight(1)

          Text(this.searchSourceGroupSummary())
            .fontSize(13)
            .fontColor(this.subTextColor())
        }
        .width('100%')
        .height(42)
        .alignItems(VerticalAlign.Center)
        .margin({ top: 8 })

        Row() {
          Toggle({ type: ToggleType.Checkbox, isOn: this.isAllSourceGroupsSelected() })
            .selectedColor(this.buttonColor())
            .onChange((isOn: boolean) => {
              this.saveAllSourceGroupsSelected(isOn);
            })
          Text('全部书源')
            .fontSize(14)
            .fontColor(this.secondaryTextColor())
            .margin({ left: 8 })
            .layoutWeight(1)
        }
        .width('100%')
        .height(38)
        .alignItems(VerticalAlign.Center)

        Scroll() {
          Column() {
            ForEach(this.sourceGroups, (group: string) => {
              Row() {
                Toggle({ type: ToggleType.Checkbox, isOn: this.isSourceGroupSelected(group) })
                  .selectedColor(this.buttonColor())
                  .onChange((isOn: boolean) => {
                    if (this.isAllSourceGroupsSelected() && !isOn) {
                      this.saveSelectedSourceGroups(this.sourceGroups.filter((item: string) => item !== group));
                      return;
                    }
                    this.setSourceGroupSelected(group, isOn);
                  })
                Text(group)
                  .fontSize(14)
                  .fontColor(this.secondaryTextColor())
                  .margin({ left: 8 })
                  .layoutWeight(1)
              }
              .width('100%')
              .height(36)
              .alignItems(VerticalAlign.Center)
            })
          }
          .width('100%')
        }
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .width('100%')
        .constraintSize({ maxHeight: 180 })
        .margin({ top: 4 })

        Button('完成')
          .width('100%')
          .height(44)
          .margin({ top: 16 })
          .backgroundColor(this.buttonColor())
          .fontColor('#FFFFFF')
          .onClick(() => {
            this.showSearchSettingsDialog = false;
          })
      }
      .width(this.searchSettingsPopupPanelWidth())
      .constraintSize({ maxHeight: 620 })
      .padding(18)
      .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
      .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
      .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
      .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
      .position({
        x: this.searchSettingsPopupPanelLeft(),
        y: this.statusBarHeight + (this.singleSourceSearchUrl ? 92 : 52)
      })
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  searchSettingIcon() {
    SymbolGlyph($r('sys.symbol.gearshape'))
      .fontSize(20)
      .fontColor([this.secondaryTextColor()])
      .width(36)
      .height(36)
      .margin({ right: 2 })
      .onClick(() => {
        this.showSearchHistoryDropdown = false;
        this.hideKeyboard();
        this.loadSourceGroups().catch((e: Error) => {
          console.warn('加载搜索书源分组失败:', e);
        });
        this.showSearchSettingsDialog = !this.showSearchSettingsDialog;
      })
  }

  @Builder
  switchSettingRow(title: string, checked: boolean, onChange: (checked: boolean) => void) {
    Row() {
      Text(title)
        .fontSize(15)
        .fontColor(this.primaryTextColor())
        .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: checked })
        .selectedColor(this.buttonColor())
        .onChange(onChange)
    }
    .width('100%')
    .height(42)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  numberSettingRow(title: string, value: number, minValue: number, maxValue: number, onChange: (value: number) => void) {
    Row() {
      Text(title)
        .fontSize(15)
        .fontColor(this.primaryTextColor())
        .layoutWeight(1)

      Row() {
        Text('−')
          .fontSize(18)
          .fontColor(this.primaryTextColor())
          .width(30)
          .height(30)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            onChange(Math.max(minValue, this.searchConcurrency - 1));
          })
        Text(`${this.searchConcurrency}`)
          .fontSize(15)
          .fontColor(this.primaryTextColor())
          .width(42)
          .textAlign(TextAlign.Center)
        Text('+')
          .fontSize(18)
          .fontColor(this.primaryTextColor())
          .width(30)
          .height(30)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            onChange(Math.min(maxValue, this.searchConcurrency + 1));
          })
      }
      .height(30)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(42)
    .alignItems(VerticalAlign.Center)
  }

  openVerification(): void {
    const url = this.verificationUrl || AppStorage.get<string>('pendingVerificationUrl') || '';
    if (!url) {
      promptAction.showToast({ message: '暂无需要验证的网页' });
      return;
    }
    router.pushUrl({
      url: 'pages/VerifyWeb',
      params: {
        url: url,
        title: this.verificationTitle || '网页验证'
      }
    });
  }

  pageColor(): string {
    return ThemeRuntime.pageColor(this.appDarkMode);
  }

  cardColor(): string {
    return ThemeRuntime.cardColor(this.appDarkMode);
  }

  glassCardColor(): string {
    return this.cardColor();
  }

  glassBorderColor(): string {
    return this.appDarkMode ? '#262A31' : '#FFFFFF';
  }

  glassShadowColor(): string {
    return '#00000000';
  }

  primaryTextColor(): string {
    return ThemeRuntime.primaryTextColor(this.appDarkMode);
  }

  secondaryTextColor(): string {
    return ThemeRuntime.subTextColor(this.appDarkMode);
  }

  subTextColor(): string {
    return ThemeRuntime.subTextColor(this.appDarkMode);
  }

  statusMessageColor(): string {
    return this.appDarkMode ? '#14251B' : '#E8F5E9';
  }

  buttonColor(): string {
    return ThemeRuntime.buttonColor(this.appDarkMode);
  }

  buttonBackgroundColor(): string {
    const normalized = AppThemeSettingsStore.normalizeColor(this.buttonColor(), AppThemeSettingsStore.DEFAULT_LIGHT_BUTTON_COLOR);
    return `#${this.appDarkMode ? '33' : '1A'}${normalized.substring(1)}`;
  }

  searchTopOverlayHeight(): number {
    let height = this.statusBarHeight + 56;
    if (this.singleSourceSearchUrl) {
      height += 42;
    }
    if (this.statusMessage) {
      height += 40;
    }
    return height;
  }

  resultListBottomInset(): number {
    const comfortableGap = 20;
    if (deviceInfo.sdkApiVersion < 23) {
      return comfortableGap;
    }
    const floatingTabHeight = 56;
    return floatingTabHeight + Math.max(this.navBarHeight, 8) + comfortableGap;
  }
}

@Component
struct SettingsPage {
  @Prop statusBarHeight: number = 0;
  @Prop navBarHeight: number = 0;
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;
  @StorageLink('accountLoggedIn') accountLoggedIn: boolean = false;
  @StorageLink('accountDisplayName') accountDisplayName: string = '';
  @StorageLink('accountAvatarUrl') accountAvatarUrl: string = '';
  @StorageLink('accountPoints') accountPoints: number = 0;
  @StorageLink('cloudSyncEnabled') cloudSyncEnabled: boolean = false;
  @StorageLink('cloudSyncLastSuccessAt') cloudSyncLastSuccessAt: number = 0;
  @StorageLink('cloudSyncPendingCount') cloudSyncPendingCount: number = 0;
  @StorageLink('cloudSyncStatus') cloudSyncStatus: string = CloudSyncSettingsStore.STATUS_DISABLED;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Scroll() {
        Column({ space: 12 }) {
          Row()
            .width('100%')
            .height(56 + this.statusBarHeight)

          this.accountSummaryCard()
          Column() {
            this.syncMenuItem()
            this.menuItem($r('sys.symbol.externaldrive'), '书源管理', true, () => {
              router.pushUrl({ url: 'pages/BookSource' });
            })
            this.menuItem($r('sys.symbol.book'), '阅读设置', true, () => {
              router.pushUrl({ url: 'pages/Settings' });
            })
            this.menuItem($r('sys.symbol.speaker_wave_3'), '朗读设置', true, () => {
              router.pushUrl({ url: 'pages/TtsSettings' });
            })
            this.menuItem($r('sys.symbol.bookshelf'), '书架设置', true, () => {
              router.pushUrl({ url: 'pages/BookshelfSettings' });
            })
            this.menuItem($r('sys.symbol.magnifyingglass'), '搜索/发现配置', true, () => {
              router.pushUrl({ url: 'pages/SearchExploreSettings' });
            })
            this.menuItem($r('sys.symbol.circle_lefthalf_inset_filled'), '主题', true, () => {
              router.pushUrl({ url: 'pages/ThemeSettings' });
            })
            this.menuItem($r('sys.symbol.gearshape'), '其他设置', true, () => {
              router.pushUrl({ url: 'pages/OtherSettings' });
            })
            this.menuItem($r('sys.symbol.info_circle'), '关于', false, () => {
              router.pushUrl({ url: 'pages/About' });
            })
          }
          .width('100%')
          .borderRadius(16)
          .clip(true)
          .backgroundColor(this.glassCardColor())

          Row()
            .width('100%')
            .height(56 + Math.max(this.navBarHeight, 8) + 20)
        }
        .width('calc(100% - 24vp)')
        .margin({ left: 12, right: 12, top: 12 })
        .justifyContent(FlexAlign.Start)
      }
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .width('100%')
      .height('100%')
      .align(Alignment.TopStart)
      .backgroundColor(this.pageColor())
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])

      Row() {
        Text('我的')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
          .layoutWeight(1)
      }
      .width('100%')
      .height(56 + this.statusBarHeight)
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, top: this.statusBarHeight })
      .backgroundColor(ThemeRuntime.topBarColor(this.appDarkMode))
      .backdropBlur(ThemeRuntime.topBarBlur())
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  accountSummaryCard() {
    Row({ space: 12 }) {
      if (this.accountLoggedIn && this.accountAvatarUrl) {
        Image(this.accountAvatarUrl)
          .width(48)
          .height(48)
          .borderRadius(24)
          .objectFit(ImageFit.Cover)
      } else {
        Image($r('app.media.ic_default_reader_avatar'))
          .width(48)
          .height(48)
          .borderRadius(24)
          .objectFit(ImageFit.Cover)
      }

      Column({ space: 4 }) {
        Text(this.accountLoggedIn ? this.accountDisplayName : '登录华为账号')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
        Text(this.accountLoggedIn ? `${this.accountPoints} 点` : '首次登录免费送 300 点')
          .fontSize(12)
          .fontColor(this.subTextColor())
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([this.subTextColor()])
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor(this.glassCardColor())
    .onClick(() => {
      router.pushUrl({ url: 'pages/AccountCenter' });
    })
  }

  @Builder
  syncMenuItem() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(22)
          .fontColor([this.subTextColor()])
          .width(32)

        Column({ space: 3 }) {
          Text('数据同步')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
          Text(CloudSyncSettingsStore.statusSummary(this.accountLoggedIn, this.cloudSyncEnabled,
            this.cloudSyncStatus, this.cloudSyncPendingCount, this.cloudSyncLastSuccessAt))
            .fontSize(12)
            .fontColor(this.cloudSyncEnabled && this.accountLoggedIn ? this.accentColor() : this.subTextColor())
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(18)
          .fontColor([this.subTextColor()])
      }
      .width('100%')
      .height(64)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      Divider()
        .strokeWidth(0.5)
        .color(this.dividerColor())
        .width('calc(100% - 60vp)')
        .margin({ left: 60 })
    }
    .width('100%')
    .onClick(() => {
      router.pushUrl({ url: 'pages/DataSync' });
    })
  }

  @Builder
  menuItem(icon: Resource, title: string, showDivider: boolean, onClick: () => void) {
    Column() {
      Row() {
        SymbolGlyph(icon)
          .fontSize(22)
          .fontColor([this.subTextColor()])
          .width(32)

        Text(title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
          .layoutWeight(1)
          .margin({ left: 12 })

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(18)
          .fontColor([this.subTextColor()])
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      if (showDivider) {
        Divider()
          .strokeWidth(0.5)
          .color(this.dividerColor())
          .margin({ left: 60, right: 16 })
      }
    }
    .width('100%')
    .onClick(onClick)
  }

  pageColor(): string {
    return ThemeRuntime.pageColor(this.appDarkMode);
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

  glassCardColor(): string {
    return ThemeRuntime.cardColor(this.appDarkMode);
  }

  dividerColor(): string {
    return this.appDarkMode ? '#24FFFFFF' : '#14000000';
  }

}
