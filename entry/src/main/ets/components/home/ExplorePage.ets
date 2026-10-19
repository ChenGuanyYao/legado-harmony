import { router } from '@kit.ArkUI';
import deviceInfo from '@ohos.deviceInfo';
import { Book, BookSource, SearchBook, BookFieldSanitizer } from '@legado/sourceengine';
import { AppDatabase } from '../../model/data/AppDatabase';
import {
  ExploreCoordinator,
  ExploreEntry,
  ExploreFilterGroup,
  ExploreSourceOption
} from '../../core/book/ExploreCoordinator';
import { SearchBookResultList } from '../../components/book/SearchBookResultList';
import { ImmersiveMaterialSurface } from '../../components/ImmersiveMaterialSurface';
import { ImmersiveMaterialRuntime } from '../../utils/ImmersiveMaterialRuntime';
import { HdsFeedback } from '../../utils/HdsFeedback';
import { SearchBookShelfHelper } from '../../utils/SearchBookShelfHelper';
import { SearchExploreSettingsStore } from '../../utils/SearchExploreSettingsStore';
import { ExploreCacheHit, ExploreResultCache } from '../../utils/ExploreResultCache';
import { ThemeRuntime } from '../../theme/ThemeRuntime';
import { WebBookService } from '../../core/book/WebBookService';
import { SystemDialogSession } from '../../utils/SystemDialogSession';
import { CoverUrlNormalizer } from '../../utils/CoverUrlNormalizer';
import { ExploreSourceOptionDataSource, ExploreMetadataTask } from '../../core/book/ShelfDataSources';
import { AppFontSize } from '../../theme/AppFontSize';
import { AppSpacing } from '../../theme/AppSpacing';

/** 首页"发现"页签：发现源、筛选条件与结果列表。 */
@Component
export struct ExplorePage {
  /** 顶部书源标签、筛选与刷新按钮的高度。 */
  static readonly HEADER_CONTROL_SIZE: number = 40;
  /** 标题下方频道栏的高度。 */
  static readonly CHANNEL_BAR_HEIGHT: number = 44;
  static readonly MENU_ITEM_HEIGHT: number = 44;
  @Prop statusBarHeight: number = 0;
  @Prop navBarHeight: number = 0;
  @Prop @Watch('onActiveChanged') isActive: boolean = false;
  @State entries: ExploreEntry[] = [];
  @State sourceOptions: ExploreSourceOption[] = [];
  private exploreSourceDataSource: ExploreSourceOptionDataSource = new ExploreSourceOptionDataSource();
  @State exploreSourceGroups: string[] = [];
  @State activeExploreSourceGroup: string = '__all__';
  @State platformNames: string[] = [];
  @State exploreFilters: ExploreFilterGroup[] = [];
  @State exploreFilterDrafts: ExploreFilterGroup[] = [];
  @State showExploreFilterPanel: boolean = false;
  @State sourceNames: string[] = [];
  @State selectedSourceName: string = '';
  @State selectedIndex: number = 0;
  @State showExploreSourcePicker: boolean = false;
  /** 频道栏左侧“模式”的下拉。 */
  @State showExplorePlatformMenu: boolean = false;
  /** 频道栏的实际宽度：沉浸材质底板需要具体数值。 */
  @State exploreChannelBarWidth: number = 0;
  @State showExploreSourceActionMenu: boolean = false;
  @State actionExploreSourceUrl: string = '';
  @State actionExploreSourceNative: boolean = false;
  private exploreSourceVariableDialogSession: SystemDialogSession = new SystemDialogSession();
  @State showExploreSourceVariableDialog: boolean = false;
  @State exploreSourceVariableUrl: string = '';
  @State exploreSourceVariableName: string = '';
  @State exploreSourceVariableValue: string = '';
  @State exploreSourceVariableComment: string = '';
  @State savingExploreSourceVariable: boolean = false;
  private exploreSourceDeleteDialogSession: SystemDialogSession = new SystemDialogSession();
  @State showExploreSourceDeleteDialog: boolean = false;
  @State exploreSourceDeleteUrl: string = '';
  @State exploreSourceDeleteName: string = '';
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
  @StorageLink('explorePlatform') selectedPlatform: string = '';
  @StorageLink('exploreSourceUrl') selectedSourceUrl: string = '';
  @StorageLink('bookSourceExploreRefreshNonce') @Watch('onExploreRefreshRequested')
  bookSourceExploreRefreshNonce: number = 0;
  @StorageProp('exploreSourceCacheRevision') @Watch('onExploreSourceCacheInvalidated')
  exploreSourceCacheRevision: number = 0;
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
  private coordinator: ExploreCoordinator = new ExploreCoordinator();
  private exploreSourceScroller: Scroller = new Scroller();
  private exploreChannelScroller: Scroller = new Scroller();
  private hasLoaded: boolean = false;
  private hasRestoredExploreSelection: boolean = false;
  private shelfStatusVersion: number = 0;
  private exploreLoadVersion: number = 0;
  private exploreContentLoadedAt: number = 0;
  private explorePage: number = 1;
  private exploreMetadataQueue: ExploreMetadataTask[] = [];
  private exploreMetadataQueued: Set<string> = new Set<string>();
  private exploreMetadataInFlight: Set<string> = new Set<string>();
  private exploreMetadataUnavailable: Set<string> = new Set<string>();
  private exploreMetadataActive: number = 0;

  aboutToAppear() {
    if (this.isActive) {
      this.ensureLoaded();
    }
  }

  onActiveChanged(): void {
    if (this.isActive) {
      this.ensureLoaded();
    } else {
      this.closeExploreFilterPanel();
      this.showExplorePlatformMenu = false;
      if (this.showExploreSourcePicker) {
        this.showExploreSourcePicker = false;
        this.clearExploreSourceFilter();
      }
      this.closeExploreSourceActions();
      this.closeExploreSourceVariableEditor();
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
    this.coordinator.clearExploreMenuCache();
    if (this.isActive && !this.isLoading) {
      this.loadEntries('', true);
    }
  }

  onExploreSourceCacheInvalidated(): void {
    // 书源在书源管理中被删除、导入或编辑：已加载的分类和列表不再可信，下次进入发现页时重新加载。
    this.exploreContentLoadedAt = 0;
    this.coordinator.clearExploreMenuCache();
    if (this.isActive && this.hasLoaded) {
      this.loadEntries();
    }
  }

  async loadEntries(platformOverride: string = '', forceRefresh: boolean = false) {
    const loadVersion = this.beginExploreLoad();
    const previousActiveEntries = this.getActiveEntries();
    const previousEntry = previousActiveEntries.length > 0 ?
      previousActiveEntries[Math.min(this.selectedIndex, previousActiveEntries.length - 1)] : null;
    const previousEntryKey = previousEntry ? `${previousEntry.title}\n${previousEntry.url}` : '';
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
      this.refreshExploreSourceDataSource();
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
      const entries = await this.coordinator.getEntries(
        this.platformNames.length > 0 ? this.selectedPlatform : '', this.getSelectedSourceUrl());
      if (!this.isCurrentExploreLoad(loadVersion)) return;
      this.entries = entries;
      const dynamicPlatforms = this.coordinator.getDiscoveredPlatforms(this.selectedSourceUrl);
      const inferredGroups = this.getEntryGroupNames(entries);
      const activeOption = this.getSelectedSourceOption();
      this.exploreFilters = this.coordinator.getDiscoveredFilters(this.selectedSourceUrl);
      if (activeOption && this.exploreFilters.length > 0) {
        activeOption.platforms = [];
      } else if (activeOption && dynamicPlatforms.length > 0) {
        activeOption.platforms = dynamicPlatforms;
      } else if (activeOption && activeOption.platforms.length === 0 && inferredGroups.length > 1) {
        activeOption.platforms = inferredGroups;
      }
      this.platformNames = this.getSelectedSourcePlatforms();
      this.normalizeSelectedPlatform();
      if (this.entries.length > 0) {
        // Keep the group that was visible before refresh. Resetting to index 0 made a refresh
        // from (for example) “玄幻” reload the first group and leave the visible group stale.
        const refreshedActiveEntries = this.getActiveEntries();
        const restoredIndex = previousEntryKey ? refreshedActiveEntries.findIndex((entry: ExploreEntry): boolean =>
          `${entry.title}\n${entry.url}` === previousEntryKey) : -1;
        this.selectedIndex = restoredIndex >= 0 ? restoredIndex : 0;
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
      if (forceRefresh) {
        // A manual refresh must not leave a failed request able to resurrect stale discovery
        // results on the next normal load. Clear the source cache before requesting new data.
        this.coordinator.clearExploreMenuCache();
        await ExploreResultCache.clearSource(getContext(this), entry.sourceUrl);
      }
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
            Text('发现')
              .fontSize(AppFontSize.DISPLAY)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
              .flexShrink(0)

            Blank()

            this.exploreSourceLabel()

            if (this.exploreFilters.length > 0) {
              this.exploreFilterButton()
            }

            this.exploreHeaderCircleButton($r('sys.symbol.arrow_clockwise'), false, '刷新发现内容', () => {
              this.loadEntries('', true);
            })
          }
          .width('100%')
          .height(56 + this.statusBarHeight)
          .padding({ left: AppSpacing.XL, right: AppSpacing.XL, top: this.statusBarHeight })
          .alignItems(VerticalAlign.Center)

          if (this.showsExploreChannelBar()) {
            this.exploreChannelBar()
          }

          if (this.shouldShowExploreStatus()) {
            Row() {
              Text(this.status)
                .fontSize(AppFontSize.BODY)
                .fontColor(this.secondaryTextColor())
                .layoutWeight(1)

              if (this.verificationUrl) {
                Button('去验证')
                  .height(28)
                  .fontSize(AppFontSize.CAPTION)
                  .borderRadius(14)
                  .backgroundColor(this.buttonColor())
                  .fontColor(ThemeRuntime.onAccentColor())
                  .margin({ left: AppSpacing.LG })
                  .onClick(() => {
                    this.openVerification();
                  })
              }
            }
            .width('100%')
            .padding({ left: AppSpacing.XL, right: AppSpacing.XL, top: AppSpacing.SM, bottom: AppSpacing.SM })
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
            .fontSize(AppFontSize.BODY)
            .fontColor(this.subTextColor())
            .margin({ top: AppSpacing.MD })
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
          onReadBook: (book: SearchBook) => {
            this.readSearchBook(book);
          },
          onToggleShelf: (book: SearchBook) => {
            this.toggleSearchBookShelf(book);
          },
          onNeedMetadata: (book: SearchBook) => {
            this.requestExploreMetadata(book);
          },
          onReachEnd: () => {
            this.loadMoreExploreBooks();
          }
        })
      } else {
        Column() {
          Text('没有发现内容')
            .fontSize(AppFontSize.BODY_LARGE)
            .fontColor(this.subTextColor())
          Text(this.verificationUrl ? '当前书源可能需要网页验证' : '请切换书源或网站，或检查已启用书源的发现地址')
            .fontSize(AppFontSize.BODY)
            .fontColor(this.subTextColor())
            .margin({ top: AppSpacing.MD })
            .textAlign(TextAlign.Center)
            .padding({ left: 32, right: 32 })
          if (this.verificationUrl) {
            Button('去验证')
              .height(36)
              .fontSize(AppFontSize.BODY)
              .borderRadius(18)
              .margin({ top: AppSpacing.LG })
              .backgroundColor(this.buttonColor())
              .fontColor(ThemeRuntime.onAccentColor())
              .onClick(() => {
                this.openVerification();
              })
          }
          if (this.shouldOfferExploreSourceLogin()) {
            Button(this.exploreSourceLoginButtonLabel())
              .height(36)
              .fontSize(AppFontSize.BODY)
              .borderRadius(18)
              .margin({ top: AppSpacing.LG })
              .backgroundColor(this.buttonColor())
              .fontColor(ThemeRuntime.onAccentColor())
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

  openSearchBookDetail(book: SearchBook, autoStartRead: boolean = false) {
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
        status: book.status,
        coverUrl: book.coverUrl,
        intro: book.intro,
        latestChapterTitle: book.latestChapterTitle,
        updateTime: book.updateTime,
        wordCount: book.wordCount,
        type: String(book.type || 0),
        variable: book.variable || '',
        promptAddToShelfOnBack: !autoStartRead && this.searchExplorePromptAddToShelfOnBack ? 'true' : 'false',
        autoStartRead: autoStartRead ? 'true' : 'false'
      }
    });
  }

  /** 书源选择弹出层：顶部搜索框，下面是分组小标签和书源列表；长按书源打开操作菜单。 */
  @Builder
  exploreSourcePickerContent() {
    Column({ space: AppSpacing.XS }) {
      Row({ space: AppSpacing.SM }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(16)
          .fontColor([this.secondaryTextColor()])
        TextInput({ placeholder: '搜索书源名称、地址或分组', text: this.exploreSourceFilterInput })
          .fontSize(AppFontSize.BODY)
          .fontColor(this.primaryTextColor())
          .placeholderColor(this.secondaryTextColor())
          .placeholderFont({ size: AppFontSize.BODY })
          .layoutWeight(1)
          .height(36)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .onChange((value: string) => {
            this.exploreSourceFilterInput = value;
            this.applyExploreSourceFilter();
          })
      }
      .width('100%')
      .height(40)
      .padding({ left: 12, right: 12 })
      .borderRadius(this.exploreMenuItemRadius())
      .backgroundColor(ThemeRuntime.softFillColor(this.appDarkMode))

      if (this.exploreSourceGroups.length > 1) {
        this.exploreSourceGroupTabs()
      }

      if (this.getFilteredExploreSourceOptions().length === 0) {
        Text(this.activeExploreSourceGroup === '__all__' ? '没有匹配的书源' : '当前分组没有匹配的书源')
          .fontSize(AppFontSize.BODY)
          .fontColor(this.secondaryTextColor())
          .width('100%')
          .height(52)
          .textAlign(TextAlign.Center)
      } else {
        List({ scroller: this.exploreSourceScroller, space: 0 }) {
          LazyForEach(this.exploreSourceDataSource, (option: ExploreSourceOption) => {
            ListItem() {
              Row() {
                Text(this.exploreSourceDisplayName(option))
                  .fontSize(AppFontSize.BODY_LARGE)
                  .fontColor(option.sourceUrl === this.selectedSourceUrl ? this.accentColor() : this.primaryTextColor())
                  .fontWeight(option.sourceUrl === this.selectedSourceUrl ? FontWeight.Medium : FontWeight.Regular)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)

                if (this.activeExploreSourceGroup === '__all__') {
                  Text(this.exploreSourceGroupLabel(option.sourceGroup))
                    .fontSize(AppFontSize.MICRO)
                    .fontColor(this.secondaryTextColor())
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .constraintSize({ maxWidth: 68 })
                    .padding({ left: AppSpacing.SM, right: AppSpacing.SM, top: AppSpacing.XXS, bottom: AppSpacing.XXS })
                    .borderRadius(ThemeRuntime.mediumRadius())
                    .backgroundColor(this.inputColor())
                    .margin({ left: AppSpacing.MD })
                }

                if (option.sourceUrl === this.selectedSourceUrl) {
                  Text('✓')
                    .fontSize(AppFontSize.BODY_LARGE)
                    .fontColor(this.accentColor())
                    .margin({ left: AppSpacing.MD })
                }
              }
              .width('100%')
              .height(ExplorePage.MENU_ITEM_HEIGHT)
              .padding({ left: 12, right: 12 })
              .borderRadius(this.exploreMenuItemRadius())
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
            }
          }, (option: ExploreSourceOption): string => option.sourceUrl || option.sourceName)
        }
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .width('100%')
        .constraintSize({ maxHeight: 320 })
        .scrollBar(BarState.Auto)
        .cachedCount(8)
        .onAppear(() => { setTimeout(() => this.scrollExploreSourceToCurrent(), 0); })
      }
    }
    .width(this.exploreSourceDropdownWidth())
    .padding(ImmersiveMaterialRuntime.POPUP_MENU_PADDING)
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
          SymbolGlyph($r('sys.symbol.arrow_right_up_and_square'))
            .fontSize(19)
            .fontColor([this.primaryTextColor()])
            .width(34)
          Text('登录')
            .fontSize(AppFontSize.BODY_LARGE)
            .fontColor(this.primaryTextColor())
            .layoutWeight(1)
        }
        .width('100%')
        .height(44)
        .padding({ left: AppSpacing.MD, right: AppSpacing.MD })
        .onClick(() => this.loginActionExploreSource())

        Row() {
          SymbolGlyph($r('sys.symbol.list_bullet'))
            .fontSize(19)
            .fontColor([this.primaryTextColor()])
            .width(34)
          Text('源变量')
            .fontSize(AppFontSize.BODY_LARGE)
            .fontColor(this.primaryTextColor())
            .layoutWeight(1)
        }
        .width('100%')
        .height(44)
        .padding({ left: AppSpacing.MD, right: AppSpacing.MD })
        .onClick(() => this.openExploreSourceVariableEditor())

        if (this.actionExploreSourceNative) {
          Row() {
            SymbolGlyph($r('sys.symbol.gearshape'))
              .fontSize(19)
              .fontColor([this.primaryTextColor()])
              .width(34)
            Text('书源设置')
              .fontSize(AppFontSize.BODY_LARGE)
              .fontColor(this.primaryTextColor())
              .layoutWeight(1)
          }
          .width('100%')
          .height(44)
          .padding({ left: AppSpacing.MD, right: AppSpacing.MD })
          .onClick(() => this.openExploreSourceSettings())
        }

        Row() {
          SymbolGlyph($r('sys.symbol.square_and_pencil'))
            .fontSize(19)
            .fontColor([this.primaryTextColor()])
            .width(34)
          Text('编辑')
            .fontSize(AppFontSize.BODY_LARGE)
            .fontColor(this.primaryTextColor())
            .layoutWeight(1)
        }
        .width('100%')
        .height(44)
        .padding({ left: AppSpacing.MD, right: AppSpacing.MD })
        .onClick(() => this.editActionExploreSource())

        Row() {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(19)
            .fontColor([ThemeRuntime.dangerColor(this.appDarkMode)])
            .width(34)
          Text('删除')
            .fontSize(AppFontSize.BODY_LARGE)
            .fontColor(ThemeRuntime.dangerColor(this.appDarkMode))
            .layoutWeight(1)
        }
        .width('100%')
        .height(44)
        .padding({ left: AppSpacing.MD, right: AppSpacing.MD })
        .onClick(() => this.deleteActionExploreSource())
      }
      .width(132)
      .padding({ top: AppSpacing.SM, bottom: AppSpacing.SM })
      .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
      .borderRadius(ThemeRuntime.glassCornerRadius(14, 'panel'))
      .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
      .border({ width: ThemeRuntime.glassBorderWidth('panel'),
        color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'panel') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'),
        color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'panel'),
        offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
      .position({ x: this.exploreContextMenuLeft(132),
        y: this.exploreContextMenuTop(this.actionExploreSourceNative ? 236 : 192) })
    }
    .width('100%')
    .height('100%')
    .zIndex(12)
  }

  @Builder
  exploreSourceVariableDialogContent() {
    Column({ space: AppSpacing.LG }) {
      Text('编辑源变量')
        .fontSize(AppFontSize.TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryTextColor())
        .width('100%')
        .textAlign(TextAlign.Center)

      Text(this.exploreSourceVariableName || this.exploreSourceVariableUrl)
        .fontSize(AppFontSize.BODY)
        .fontColor(this.secondaryTextColor())
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)

      if (this.exploreSourceVariableComment) {
        Text(this.exploreSourceVariableComment)
          .fontSize(AppFontSize.CAPTION)
          .lineHeight(18)
          .fontColor(this.secondaryTextColor())
          .width('100%')
          .padding(AppSpacing.MD)
          .borderRadius(ThemeRuntime.mediumRadius())
          .backgroundColor(this.inputColor())
      }

      TextArea({
        text: this.exploreSourceVariableValue,
        placeholder: this.exploreSourceVariableComment || '请输入书源变量'
      })
        .width('100%')
        .height(180)
        .fontSize(AppFontSize.BODY)
        .fontColor(this.primaryTextColor())
        .placeholderColor(this.secondaryTextColor())
        .backgroundColor(this.inputColor())
        .borderRadius(ThemeRuntime.mediumRadius())
        .padding(AppSpacing.LG)
        .enabled(!this.savingExploreSourceVariable)
        .onChange((value: string) => {
          this.exploreSourceVariableValue = value;
        })

      Row({ space: AppSpacing.MD }) {
        Button('取消')
          .layoutWeight(1)
          .height(40)
          .fontColor(this.primaryTextColor())
          .backgroundColor(this.inputColor())
          .enabled(!this.savingExploreSourceVariable)
          .onClick(() => this.closeExploreSourceVariableEditor())
        Button(this.savingExploreSourceVariable ? '保存中…' : '保存')
          .layoutWeight(1)
          .height(40)
          .fontColor(ThemeRuntime.onAccentColor())
          .backgroundColor(this.buttonColor())
          .enabled(!this.savingExploreSourceVariable)
          .onClick(() => this.saveExploreSourceVariable())
      }
      .width('100%')
    }    .padding(AppSpacing.XL)
  }

  openExploreSourceVariableDialog(): void {
    this.showExploreSourceVariableDialog = true;
    // 保存中禁止蒙层关闭，避免丢入输入。
    this.exploreSourceVariableDialogSession.open(this.getUIContext(), (): void => {
      this.exploreSourceVariableDialogContent();
    }, {
      autoCancel: false,
      maskColor: ThemeRuntime.scrimColor(this.appDarkMode),
      warnTag: '显示编辑源变量弹窗失败:'
    });
  }

  @Builder
  exploreSourceDeleteDialogContent() {
    Column() {
      Text('删除书源')
        .fontSize(AppFontSize.SUBTITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryTextColor())
        .width('100%')
        .textAlign(TextAlign.Center)

      Text(`确定删除“${this.exploreSourceDeleteName || this.exploreSourceDeleteUrl}”吗？删除后不可恢复。`)
        .fontSize(AppFontSize.BODY)
        .fontColor(this.secondaryTextColor())
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: AppSpacing.LG, bottom: AppSpacing.XXL })

      Row({ space: AppSpacing.MD }) {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .backgroundColor(this.inputColor())
          .fontColor(this.primaryTextColor())
          .onClick(() => this.closeExploreSourceDeleteDialog())

        Button('删除')
          .layoutWeight(1)
          .height(44)
          .backgroundColor('#B71C1C')
          .fontColor('#FFFFFF')
          .onClick(() => this.confirmDeleteExploreSource())
      }
      .width('100%')
    }
    .padding(AppSpacing.XXL)
  }

  openExploreSourceDeleteDialog(): void {
    this.showExploreSourceDeleteDialog = true;
    this.exploreSourceDeleteDialogSession.open(this.getUIContext(), (): void => {
      this.exploreSourceDeleteDialogContent();
    }, {
      autoCancel: true,
      maskColor: ThemeRuntime.scrimColor(this.appDarkMode),
      warnTag: '显示删除书源弹窗失败:'
    });
  }


  @Builder
  exploreSourceGroupTabs() {
    Scroll() {
      Row() {
        this.exploreSourceGroupTab('全部', '__all__')
        ForEach(this.exploreSourceGroups, (group: string) => {
          this.exploreSourceGroupTab(group, group)
        }, (group: string) => group)
      }
      .constraintSize({ minWidth: '100%' })
    }
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .width('100%')
    .height(ExplorePage.MENU_ITEM_HEIGHT)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
  }

  /** 字号与下面的书源列表、书架分类栏一致，选中项强调色加下划线。 */
  @Builder
  exploreSourceGroupTab(label: string, groupKey: string) {
    Column({ space: 3 }) {
      Text(label)
        .fontSize(AppFontSize.BODY_LARGE)
        .fontWeight(this.activeExploreSourceGroup === groupKey ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.activeExploreSourceGroup === groupKey ? this.accentColor() : this.secondaryTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 128 })
      Row()
        .width(16)
        .height(3)
        .borderRadius(1.5)
        .backgroundColor(this.accentColor())
        .opacity(this.activeExploreSourceGroup === groupKey ? 1 : 0)
    }
    .height('100%')
    .padding({ left: 12, right: 12, top: 6 })
    .justifyContent(FlexAlign.Center)
    .onClick(() => this.selectExploreSourceGroup(groupKey))
  }

  /** 标题右侧的书源名标签：按名称估宽，最多占屏宽 45%，点开书源选择弹出层。 */
  @Builder
  exploreSourceLabel() {
    Row() {
      ImmersiveMaterialSurface({
        surfaceWidth: this.exploreSourceLabelWidth(),
        surfaceHeight: ExplorePage.HEADER_CONTROL_SIZE,
        darkMode: this.appDarkMode,
        fallbackColor: this.cardColor(),
        glowColor: this.accentGlowColor()
      }) {
        Row({ space: AppSpacing.XS }) {
          Text(this.selectedSourceName || '选择书源')
            .fontSize(AppFontSize.BODY)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.accentColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .flexShrink(1)
          SymbolGlyph(this.showExploreSourcePicker ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
            .fontSize(14)
            .fontColor([this.secondaryTextColor()])
        }
        .width('100%')
        .height('100%')
        .padding({ left: 14, right: 10 })
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .accessibilityText(`当前书源${this.selectedSourceName}，切换书源`)
        .onClick(() => {
          this.showExploreFilterPanel = false;
          this.showExplorePlatformMenu = false;
          this.toggleExploreSourcePicker();
        })
      }
    }
    .margin({ left: AppSpacing.MD, right: 10 })
    .bindPopup(this.showExploreSourcePicker, ImmersiveMaterialRuntime.popupMenuOptions((): void => {
      this.exploreSourcePickerContent()
    }, Placement.BottomRight, this.appDarkMode, this.accentColor(), () => {
      this.showExploreSourcePicker = false;
      this.clearExploreSourceFilter();
    }))
  }

  exploreSourceLabelWidth(): number {
    const name = this.selectedSourceName || '选择书源';
    let textWidth = 0;
    for (let index = 0; index < name.length; index++) {
      textWidth += name.charCodeAt(index) > 0x2E80 ? AppFontSize.BODY : AppFontSize.BODY * 0.6;
    }
    // 左右留白 24、箭头 14、间隔 4。
    const desired = Math.ceil(textWidth) + 42;
    return Math.max(72, Math.min(desired, Math.floor(this.exploreViewportWidth * 0.45)));
  }

  @Builder
  exploreHeaderCircleButton(icon: Resource, active: boolean, label: string, onTap: () => void) {
    ImmersiveMaterialSurface({
      surfaceWidth: ExplorePage.HEADER_CONTROL_SIZE,
      surfaceHeight: ExplorePage.HEADER_CONTROL_SIZE,
      darkMode: this.appDarkMode,
      fallbackColor: this.cardColor(),
      glowColor: this.accentGlowColor()
    }) {
      Stack() {
        SymbolGlyph(icon)
          .fontSize(20)
          .fontColor([active ? this.accentColor() : this.primaryTextColor()])
      }
      .width('100%')
      .height('100%')
      .accessibilityText(label)
      .onClick(() => onTap())
    }
  }

  @Builder
  exploreFilterButton() {
    Row() {
      this.exploreHeaderCircleButton($r('sys.symbol.funnel'), this.showExploreFilterPanel,
        `筛选条件：${this.exploreFilterSummary()}`, () => {
          this.showExploreSourcePicker = false;
          this.showExplorePlatformMenu = false;
          this.toggleExploreFilterPanel();
        })
    }
    .margin({ right: 10 })
    .bindPopup(this.showExploreFilterPanel, ImmersiveMaterialRuntime.popupMenuOptions((): void => {
      this.exploreFilterPopupContent()
    }, Placement.BottomRight, this.appDarkMode, this.accentColor(), () => {
      this.closeExploreFilterPanel();
    }))
  }

  exploreFilterSummary(): string {
    return this.exploreFilters.map((filter: ExploreFilterGroup) => `${filter.title}${filter.selected || '未选'}`)
      .join('，');
  }

  /** 书源提供的筛选条件（分类、状态、排序等）：分组排列，选好后点“完成”一次生效。 */
  @Builder
  exploreFilterPopupContent() {
    Column() {
      Row() {
        Text('筛选条件')
          .fontSize(AppFontSize.BODY_LARGE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
          .layoutWeight(1)
        Text('完成')
          .fontSize(AppFontSize.BODY_LARGE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.accentColor())
          .padding({ left: AppSpacing.LG, right: AppSpacing.XS, top: AppSpacing.MD, bottom: AppSpacing.MD })
          .onClick(() => {
            this.applyExploreFilterDrafts();
          })
      }
      .width('100%')
      .height(ExplorePage.MENU_ITEM_HEIGHT)
      .padding({ left: 12, right: 8 })

      Scroll() {
        Column({ space: AppSpacing.LG }) {
          ForEach(this.exploreFilterDrafts, (filter: ExploreFilterGroup) => {
            Column({ space: AppSpacing.SM }) {
              Text(filter.title)
                .fontSize(AppFontSize.CAPTION)
                .fontColor(this.secondaryTextColor())
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(filter.options, (name: string) => {
                  this.exploreFilterDraftOptionChip(filter, name)
                }, (name: string): string => `${filter.title}:${name}`)
              }
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }, (filter: ExploreFilterGroup): string =>
            `${filter.title}:${filter.selected}:${filter.options.join('|')}`)
        }
        .width('100%')
        .padding({ left: 12, right: 4, top: AppSpacing.XS, bottom: AppSpacing.LG })
      }
      .width('100%')
      .constraintSize({ maxHeight: Math.min(420, Math.floor(this.exploreViewportHeight * 0.6)) })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width(Math.min(340, Math.max(1, this.exploreViewportWidth - 32)))
    .padding(ImmersiveMaterialRuntime.POPUP_MENU_PADDING)
  }

  showsExploreChannelBar(): boolean {
    return this.getActiveEntries().length > 0 || this.showsExplorePlatformSelector();
  }

  /** 书源有多个模式（站点）时，频道栏左侧固定显示当前模式；有筛选条件的书源不走模式。 */
  showsExplorePlatformSelector(): boolean {
    return this.exploreFilters.length === 0 && this.platformNames.length > 1;
  }

  /** 标题下方唯一的一行：左侧可选的模式，右侧横滑频道，选中项强调色加下划线。 */
  @Builder
  exploreChannelBar() {
    Row() {
      if (this.exploreChannelBarWidth > 0) {
        ImmersiveMaterialSurface({
          surfaceWidth: this.exploreChannelBarWidth,
          surfaceHeight: ExplorePage.CHANNEL_BAR_HEIGHT,
          darkMode: this.appDarkMode,
          fallbackColor: this.cardColor(),
          glowColor: this.accentGlowColor()
        }) {
          Row() {
            if (this.showsExplorePlatformSelector()) {
              Row({ space: AppSpacing.XXS }) {
                Text(this.selectedPlatform || this.platformNames[0])
                  .fontSize(AppFontSize.BODY)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.primaryTextColor())
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: 96 })
                SymbolGlyph(this.showExplorePlatformMenu ? $r('sys.symbol.chevron_up') :
                  $r('sys.symbol.chevron_down'))
                  .fontSize(12)
                  .fontColor([this.secondaryTextColor()])
              }
              .height('100%')
              .padding({ left: 16, right: 10 })
              .alignItems(VerticalAlign.Center)
              .accessibilityText(`当前模式${this.selectedPlatform}，切换模式`)
              .bindPopup(this.showExplorePlatformMenu, ImmersiveMaterialRuntime.popupMenuOptions((): void => {
                this.explorePlatformMenuContent()
              }, Placement.BottomLeft, this.appDarkMode, this.accentColor(), () => {
                this.showExplorePlatformMenu = false;
              }))
              .onClick(() => {
                this.showExploreSourcePicker = false;
                this.showExploreFilterPanel = false;
                this.showExplorePlatformMenu = !this.showExplorePlatformMenu;
              })

              Divider()
                .vertical(true)
                .height(18)
                .strokeWidth(1)
                .color(ThemeRuntime.hairlineColor(this.appDarkMode))
            }

            List({ scroller: this.exploreChannelScroller }) {
              ForEach(this.getActiveEntries(), (entry: ExploreEntry, index: number) => {
                ListItem() {
                  Column({ space: 3 }) {
                    Text(entry.title)
                      .fontSize(AppFontSize.BODY_LARGE)
                      .fontWeight(this.selectedIndex === index ? FontWeight.Medium : FontWeight.Regular)
                      .fontColor(this.selectedIndex === index ? this.accentColor() : this.secondaryTextColor())
                      .maxLines(1)
                    Row()
                      .width(16)
                      .height(3)
                      .borderRadius(1.5)
                      .backgroundColor(this.accentColor())
                      .opacity(this.selectedIndex === index ? 1 : 0)
                      .scale({ x: this.selectedIndex === index ? 1 : 0.4, y: 1 })
                      .animation({ duration: 220, curve: Curve.Friction })
                  }
                  .height('100%')
                  .padding({ left: 10, right: 10, top: 6 })
                  .justifyContent(FlexAlign.Center)
                  .accessibilityText(entry.title)
                  .accessibilitySelected(this.selectedIndex === index)
                  .onClick(() => this.selectExploreEntry(index))
                }
              }, (entry: ExploreEntry, index: number): string => `${index}_${entry.title}`)
            }
            .listDirection(Axis.Horizontal)
            .layoutWeight(1)
            .height('100%')
            .padding({ left: this.showsExplorePlatformSelector() ? 2 : 6, right: 6 })
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          }
          .width('100%')
          .height('100%')
          .alignItems(VerticalAlign.Center)
        }
      }
    }
    .width(`calc(100% - ${AppSpacing.XL * 2}vp)`)
    .height(ExplorePage.CHANNEL_BAR_HEIGHT)
    .margin({ left: AppSpacing.XL, right: AppSpacing.XL, bottom: AppSpacing.MD })
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const width = Math.floor(Number(newValue.width));
      if (Number.isFinite(width) && width > 0 && width !== this.exploreChannelBarWidth) {
        this.exploreChannelBarWidth = width;
      }
    })
  }

  selectExploreEntry(index: number): void {
    this.selectedIndex = index;
    this.loadBooks();
    try {
      this.exploreChannelScroller.scrollToIndex(index, true, ScrollAlign.CENTER);
    } catch (error) {
      console.warn('定位当前发现频道失败:', error);
    }
  }

  @Builder
  explorePlatformMenuContent() {
    Column({ space: AppSpacing.XXS }) {
      ForEach(this.platformNames, (name: string) => {
        Row() {
          Text(name)
            .fontSize(AppFontSize.BODY_LARGE)
            .fontWeight(this.selectedPlatform === name ? FontWeight.Medium : FontWeight.Regular)
            .fontColor(this.selectedPlatform === name ? this.accentColor() : this.primaryTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.selectedPlatform === name) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(14)
              .fontColor([this.accentColor()])
          }
        }
        .width('100%')
        .height(ExplorePage.MENU_ITEM_HEIGHT)
        .padding({ left: 12, right: 12 })
        .borderRadius(this.exploreMenuItemRadius())
        .backgroundColor(this.selectedPlatform === name ? this.exploreSelectedBackgroundColor() : '#00000000')
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.showExplorePlatformMenu = false;
          this.switchExplorePlatform(name);
        })
      }, (name: string) => name)
    }
    .width(180)
    .padding(ImmersiveMaterialRuntime.POPUP_MENU_PADDING)
  }

  exploreMenuItemRadius(): number {
    return ImmersiveMaterialRuntime.POPUP_MENU_RADIUS - ImmersiveMaterialRuntime.POPUP_MENU_PADDING;
  }

  accentGlowColor(): string {
    return `#40${this.accentColor().substring(1)}`;
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
      HdsFeedback.showToast('加入书架失败');
    } finally {
      this.unmarkSearchBookJoining(searchKey);
    }
  }

  async readSearchBook(searchBook: SearchBook): Promise<void> {
    if (this.isSearchBookJoiningShelf(searchBook)) return;
    if (!this.isSearchBookInShelf(searchBook)) {
      // Use the transient reader flow; reading a search result must not add it to the shelf.
      this.openSearchBookDetail(searchBook, true);
      return;
    }
    const shelfBook = await SearchBookShelfHelper.findShelfBookByKey(
      SearchBookShelfHelper.keyOf(searchBook), true);
    if (!shelfBook?.bookUrl) {
      HdsFeedback.showToast('书籍准备失败，请稍后重试');
      return;
    }
    router.pushUrl({ url: 'pages/ReadBook', params: { bookUrl: shelfBook.bookUrl } });
  }

  openExploreSourcePicker(): void {
    if (this.sourceOptions.length === 0) {
      return;
    }
    this.exploreSourceFilterInput = '';
    this.exploreSourceFilterKeyword = '';
    this.activeExploreSourceGroup = '__all__';
    this.refreshExploreSourceDataSource();
    this.showExploreSourcePicker = true;
  }

  scrollExploreSourceToCurrent(): void {
    if (!this.showExploreSourcePicker || !this.selectedSourceUrl) return;
    const options = this.getFilteredExploreSourceOptions();
    const selectedIndex = options.findIndex((option: ExploreSourceOption) =>
      option.sourceUrl === this.selectedSourceUrl);
    if (selectedIndex < 0) return;
    const rowHeight = 44;
    const visibleHeight = 320;
    const targetOffset = Math.max(0, selectedIndex * rowHeight - (visibleHeight - rowHeight) / 2);
    try {
      this.exploreSourceScroller.scrollTo({ xOffset: 0, yOffset: targetOffset, animation: false });
    } catch (error) {
      console.warn('定位当前发现书源失败:', error);
    }
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
    this.refreshExploreSourceDataSource();
    if (this.sourceOptions.length > 0) {
      this.showExploreSourcePicker = true;
    }
  }

  clearExploreSourceFilter(): void {
    this.exploreSourceFilterInput = '';
    this.exploreSourceFilterKeyword = '';
    this.refreshExploreSourceDataSource();
  }

  openExploreSourceActions(option: ExploreSourceOption, event?: GestureEvent): void {
    const finger = event && event.fingerList.length > 0 ? event.fingerList[0] : undefined;
    if (finger) {
      this.exploreContextMenuX = finger.globalX;
      this.exploreContextMenuY = finger.globalY;
    }
    this.actionExploreSourceUrl = option.sourceUrl;
    this.actionExploreSourceNative = option.isNative === true;
    // 操作菜单画在页面上，书源弹出层在系统浮层里，先收起弹出层免得挡住菜单。
    this.showExploreSourcePicker = false;
    this.showExploreSourceActionMenu = true;
  }

  closeExploreSourceActions(): void {
    this.showExploreSourceActionMenu = false;
    this.actionExploreSourceUrl = '';
    this.actionExploreSourceNative = false;
  }

  openExploreSourceSettings(): void {
    const sourceUrl = this.actionExploreSourceUrl;
    if (!sourceUrl) return;
    this.closeExploreSourceActions();
    router.pushUrl({
      url: 'pages/NativeSourceSettings',
      params: { bookSourceUrl: sourceUrl }
    });
  }

  async openExploreSourceVariableEditor(): Promise<void> {
    const sourceUrl = this.actionExploreSourceUrl;
    if (!sourceUrl) return;
    this.closeExploreSourceActions();
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      const source = await db.getBookSource(sourceUrl);
      if (!source) {
        HdsFeedback.showToast('书源不存在');
        return;
      }
      this.exploreSourceVariableUrl = source.bookSourceUrl;
      this.exploreSourceVariableName = source.bookSourceName || source.bookSourceUrl;
      this.exploreSourceVariableValue = source.variable || '';
      this.exploreSourceVariableComment = (source.variableComment || '').trim();
      this.openExploreSourceVariableDialog();
    } catch (error) {
      console.error('读取书源变量失败:', error);
      HdsFeedback.showToast('读取书源变量失败');
    }
  }

  closeExploreSourceVariableEditor(): void {
    if (this.savingExploreSourceVariable) return;
    this.showExploreSourceVariableDialog = false;
    this.exploreSourceVariableDialogSession.close(this.getUIContext());
    this.exploreSourceVariableUrl = '';
    this.exploreSourceVariableName = '';
    this.exploreSourceVariableValue = '';
    this.exploreSourceVariableComment = '';
  }

  async saveExploreSourceVariable(): Promise<void> {
    const sourceUrl = this.exploreSourceVariableUrl;
    if (!sourceUrl || this.savingExploreSourceVariable) return;
    this.savingExploreSourceVariable = true;
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      await db.updateBookSourceVariable(sourceUrl, this.exploreSourceVariableValue);
      await ExploreResultCache.clearSource(getContext(this), sourceUrl);
      this.savingExploreSourceVariable = false;
      this.closeExploreSourceVariableEditor();
      HdsFeedback.showToast('源变量已保存');
      if (this.isActive && !this.isLoading && this.selectedSourceUrl === sourceUrl) {
        await this.loadEntries('', true);
      }
    } catch (error) {
      this.savingExploreSourceVariable = false;
      console.error('保存书源变量失败:', error);
      HdsFeedback.showToast('保存源变量失败');
    }
  }

  editActionExploreSource(): void {
    const sourceUrl = this.actionExploreSourceUrl;
    if (!sourceUrl) return;
    const isNative = this.actionExploreSourceNative;
    this.closeExploreSourceActions();
    router.pushUrl({
      url: isNative ? 'pages/NativeSourceEdit' : 'pages/BookSourceEdit',
      params: { bookSourceUrl: sourceUrl }
    });
  }

  loginActionExploreSource(): void {
    const sourceUrl = this.actionExploreSourceUrl;
    if (!sourceUrl) return;
    this.closeExploreSourceActions();
    router.pushUrl({
      url: 'pages/BookSource',
      params: { openLoginSourceUrl: sourceUrl }
    });
  }

  async deleteActionExploreSource(): Promise<void> {
    const sourceUrl = this.actionExploreSourceUrl;
    if (!sourceUrl) return;
    this.closeExploreSourceActions();
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      const source = await db.getBookSource(sourceUrl);
      if (!source) {
        HdsFeedback.showToast('书源不存在');
        return;
      }
      if (source.isLocked) {
        HdsFeedback.showToast('锁定的书源不能删除');
        return;
      }
      this.exploreSourceDeleteUrl = source.bookSourceUrl;
      this.exploreSourceDeleteName = source.bookSourceName || source.bookSourceUrl;
      this.openExploreSourceDeleteDialog();
    } catch (error) {
      console.error('读取书源失败:', error);
      HdsFeedback.showToast('读取书源失败');
    }
  }

  closeExploreSourceDeleteDialog(): void {
    this.showExploreSourceDeleteDialog = false;
    this.exploreSourceDeleteDialogSession.close(this.getUIContext());
    this.exploreSourceDeleteUrl = '';
    this.exploreSourceDeleteName = '';
  }

  async confirmDeleteExploreSource(): Promise<void> {
    const sourceUrl = this.exploreSourceDeleteUrl;
    if (!sourceUrl) return;
    this.showExploreSourceDeleteDialog = false;
    this.exploreSourceDeleteDialogSession.close(this.getUIContext());
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      await db.deleteBookSource(sourceUrl);
      await ExploreResultCache.clearSource(getContext(this), sourceUrl);
      this.exploreSourceDeleteUrl = '';
      this.exploreSourceDeleteName = '';
      HdsFeedback.showToast('书源已删除');
      // 删除后重载发现页：若删的是当前源，loadEntries 会自动回退到首个可用源。
      if (this.isActive) {
        await this.loadEntries('', true);
      }
    } catch (e) {
      console.error('删除书源失败:', e);
      HdsFeedback.showToast('删除书源失败');
    }
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

  refreshExploreSourceDataSource(): void {
    this.exploreSourceDataSource.replace(this.getFilteredExploreSourceOptions());
  }

  exploreSourceDisplayName(option: ExploreSourceOption): string {
    const name = option.sourceName || '未命名书源';
    const duplicateCount = this.sourceOptions.filter((candidate: ExploreSourceOption): boolean =>
      (candidate.sourceName || '未命名书源') === name).length;
    if (duplicateCount <= 1) return name;
    const sourceKey = (option.sourceUrl || '无地址').replace(/^https?:\/\//i, '').replace(/\/$/, '');
    return `${name} · ${sourceKey}`;
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
      this.refreshExploreSourceDataSource();
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
      this.refreshExploreSourceDataSource();
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
    this.closeExploreFilterPanel();
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
    this.exploreMetadataQueue = [];
    this.exploreMetadataQueued.clear();
    this.exploreMetadataUnavailable.clear();
    this.isLoading = true;
    return this.exploreLoadVersion;
  }

  requestExploreMetadata(book: SearchBook): void {
    if (!book || (!book.bookUrl || !book.origin) || (book.author && book.coverUrl)) return;
    const key = this.exploreMetadataKey(book);
    if (!key || this.exploreMetadataQueued.has(key) || this.exploreMetadataInFlight.has(key) ||
      this.exploreMetadataUnavailable.has(key)) return;
    const task = new ExploreMetadataTask();
    task.book = book;
    task.loadVersion = this.exploreLoadVersion;
    this.exploreMetadataQueue.push(task);
    this.exploreMetadataQueued.add(key);
    this.drainExploreMetadataQueue();
  }

  private drainExploreMetadataQueue(): void {
    while (this.exploreMetadataActive < 3 && this.exploreMetadataQueue.length > 0) {
      const task = this.exploreMetadataQueue.shift();
      if (!task) return;
      const key = this.exploreMetadataKey(task.book);
      this.exploreMetadataQueued.delete(key);
      if (!key || task.loadVersion !== this.exploreLoadVersion || this.exploreMetadataInFlight.has(key)) continue;
      this.exploreMetadataInFlight.add(key);
      this.exploreMetadataActive++;
      this.enrichExploreMetadata(task).catch((error: Object): void => {
        console.warn('[ExploreMetadata] detail enrichment failed:', task.book.originName || task.book.origin,
          error instanceof Error ? error.message : String(error || 'unknown error'));
      }).finally((): void => {
        this.exploreMetadataInFlight.delete(key);
        this.exploreMetadataActive = Math.max(0, this.exploreMetadataActive - 1);
        this.drainExploreMetadataQueue();
      });
    }
  }

  private async enrichExploreMetadata(task: ExploreMetadataTask): Promise<void> {
    if (task.loadVersion !== this.exploreLoadVersion) return;
    const source = await AppDatabase.getInstance().getBookSource(task.book.origin);
    if (!source || task.loadVersion !== this.exploreLoadVersion) return;
    const needsAuthor = !task.book.author && !!(source.bookInfoRule.author || '').trim();
    const needsCover = !task.book.coverUrl && !!(source.bookInfoRule.coverUrl || '').trim();
    const key = this.exploreMetadataKey(task.book);
    if (!needsAuthor && !needsCover) {
      this.exploreMetadataUnavailable.add(key);
      return;
    }

    const detail = new Book();
    detail.bookUrl = task.book.bookUrl;
    detail.tocUrl = task.book.tocUrl;
    detail.origin = task.book.origin;
    detail.originName = task.book.originName;
    detail.name = task.book.name;
    detail.author = task.book.author;
    detail.kind = task.book.kind;
    detail.status = task.book.status;
    detail.coverUrl = task.book.coverUrl;
    detail.intro = task.book.intro;
    detail.latestChapterTitle = task.book.latestChapterTitle;
    detail.updateTime = task.book.updateTime;
    detail.wordCount = task.book.wordCount;
    detail.type = task.book.type;
    detail.variable = task.book.variable;
    const enriched = await new WebBookService().getBookInfo(source, detail);
    if (task.loadVersion !== this.exploreLoadVersion) return;
    const index = this.books.findIndex((item: SearchBook): boolean =>
      item.origin === task.book.origin && item.bookUrl === task.book.bookUrl);
    if (index < 0) return;
    const current = this.books[index];
    let changed = false;
    if (!current.author && enriched.author) {
      current.author = BookFieldSanitizer.clean(enriched.author);
      changed = !!current.author || changed;
    }
    if (!current.coverUrl && enriched.coverUrl) {
      current.coverUrl = CoverUrlNormalizer.normalize(enriched.coverUrl);
      changed = !!current.coverUrl || changed;
    }
    if (!current.status && enriched.status) {
      current.status = BookFieldSanitizer.clean(enriched.status);
      changed = !!current.status || changed;
    }
    if (!current.updateTime && enriched.updateTime) {
      current.updateTime = BookFieldSanitizer.clean(enriched.updateTime);
      changed = !!current.updateTime || changed;
    }
    if (changed) this.books = this.books.slice();
    if ((!needsAuthor || !!current.author) && (!needsCover || !!current.coverUrl)) {
      this.exploreMetadataUnavailable.add(key);
    }
  }

  private exploreMetadataKey(book: SearchBook): string {
    return `${book.origin || ''}|${book.bookUrl || ''}`;
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
      this.selectedPlatform = this.platformNames.length > 0 ? this.platformNames[0] : '';
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
      HdsFeedback.showToast('移出书架失败');
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
      HdsFeedback.showToast('暂无需要验证的网页');
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
    const sourceEntries = !this.selectedSourceUrl ? this.entries :
      this.entries.filter(entry => entry.sourceUrl === this.selectedSourceUrl);
    if (!this.selectedPlatform) return sourceEntries;
    const hasSelectedGroup = sourceEntries.some((entry: ExploreEntry): boolean =>
      (entry.groupTitle || '') === this.selectedPlatform);
    return hasSelectedGroup ? sourceEntries.filter((entry: ExploreEntry): boolean =>
      (entry.groupTitle || '') === this.selectedPlatform) : sourceEntries;
  }

  getEntryGroupNames(entries: ExploreEntry[]): string[] {
    const names: string[] = [];
    for (const entry of entries) {
      const name = (entry.groupTitle || '').trim();
      if (name && !names.includes(name)) names.push(name);
    }
    return names;
  }

  exploreTopOverlayHeight(): number {
    let height = this.statusBarHeight + 56;
    if (this.showsExploreChannelBar()) {
      height += ExplorePage.CHANNEL_BAR_HEIGHT + AppSpacing.MD;
    }
    if (this.shouldShowExploreStatus()) {
      height += 40;
    }
    return height;
  }

  copyExploreFilterGroups(filters: ExploreFilterGroup[]): ExploreFilterGroup[] {
    const copies: ExploreFilterGroup[] = [];
    for (const filter of filters) {
      copies.push({
        title: filter.title,
        options: filter.options.slice(),
        selected: filter.selected
      });
    }
    return copies;
  }

  openExploreFilterPanel(): void {
    this.exploreFilterDrafts = this.copyExploreFilterGroups(this.exploreFilters);
    this.showExploreFilterPanel = true;
  }

  closeExploreFilterPanel(): void {
    this.showExploreFilterPanel = false;
    this.exploreFilterDrafts = [];
  }

  toggleExploreFilterPanel(): void {
    if (this.showExploreFilterPanel) {
      this.closeExploreFilterPanel();
    } else {
      this.openExploreFilterPanel();
    }
  }

  selectExploreFilterDraft(title: string, selection: string): void {
    const next: ExploreFilterGroup[] = [];
    for (const filter of this.exploreFilterDrafts) {
      next.push({
        title: filter.title,
        options: filter.options.slice(),
        selected: filter.title === title ? selection : filter.selected
      });
    }
    this.exploreFilterDrafts = next;
  }

  async applyExploreFilterDrafts(): Promise<void> {
    const drafts = this.copyExploreFilterGroups(this.exploreFilterDrafts);
    const changed: ExploreFilterGroup[] = [];
    for (const draft of drafts) {
      const applied = this.exploreFilters.find((filter: ExploreFilterGroup): boolean =>
        filter.title === draft.title);
      if (applied && applied.selected !== draft.selected) changed.push(draft);
    }
    this.closeExploreFilterPanel();
    if (changed.length === 0 || this.isLoading || !this.selectedSourceUrl) return;

    this.status = '正在应用筛选条件...';
    this.books = [];
    this.isLoading = true;
    const failedTitles: string[] = [];
    for (const filter of changed) {
      const applied = await this.coordinator.applyExploreFilter(
        this.selectedSourceUrl, filter.title, filter.selected);
      if (!applied) failedTitles.push(filter.title);
    }
    this.isLoading = false;
    this.selectedPlatform = '';
    await this.loadEntries('', true);
    if (failedTitles.length > 0) {
      this.status = `${failedTitles.join('、')}筛选条件应用失败`;
    }
  }

  @Builder
  exploreFilterDraftOptionChip(filter: ExploreFilterGroup, name: string) {
    Text(name)
      .fontSize(AppFontSize.BODY)
      .fontWeight(filter.selected === name ? FontWeight.Medium : FontWeight.Regular)
      .fontColor(filter.selected === name ? this.accentColor() : this.primaryTextColor())
      .height(32)
      .maxLines(1)
      .padding({ left: AppSpacing.LG, right: AppSpacing.LG })
      .backgroundColor(filter.selected === name ? this.exploreSelectedBackgroundColor() :
        ThemeRuntime.softFillColor(this.appDarkMode))
      .borderRadius(16)
      .margin({ right: AppSpacing.SM, bottom: AppSpacing.SM })
      .onClick(() => {
        if (filter.selected !== name) this.selectExploreFilterDraft(filter.title, name);
      })
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
