import { router, uiMaterial } from '@kit.ArkUI';
import deviceInfo from '@ohos.deviceInfo';
import { BookSource, SearchBook, SearchKeyword } from '../../model/data/Book';
import { AppDatabase } from '../../model/data/AppDatabase';
import { SearchCoordinator, SearchCallback, SearchProgress } from '../../core/book/SearchCoordinator';
import { SearchBookResultList } from '../../components/book/SearchBookResultList';
import { ImmersiveBackButton } from '../../components/ImmersiveBackButton';
import { ImmersiveMaterialRuntime } from '../../utils/ImmersiveMaterialRuntime';
import { HdsFeedback } from '../../utils/HdsFeedback';
import { SearchBookShelfHelper } from '../../utils/SearchBookShelfHelper';
import { SearchExploreSettings, SearchExploreSettingsStore } from '../../utils/SearchExploreSettingsStore';
import { SearchResultAggregationStore } from '../../utils/SearchResultAggregationStore';
import { AppThemeSettingsStore } from '../../utils/AppThemeSettingsStore';
import { ThemeRuntime } from '../../theme/ThemeRuntime';
import { AdaptiveSwitch } from '../AdaptiveSwitch';
import { AppFontSize } from '../../theme/AppFontSize';
import { AppSpacing } from '../../theme/AppSpacing';

/** 首页"搜索"页签：搜索输入、历史、多源搜索进度与结果。 */
@Component
export struct SearchPage {
  @Prop statusBarHeight: number = 0;
  @Prop navBarHeight: number = 0;
  @Prop @Watch('onActiveChanged') isActive: boolean = false;
  @State keyword: string = '';
  @State searchResults: SearchBook[] = [];
  @State displayedSearchResults: SearchBook[] = [];
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
  @State showSearchSourcePicker: boolean = false;
  @State searchSourcePickerQuery: string = '';
  @State searchableSources: BookSource[] = [];
  @State sourceGroups: string[] = [];
  @State pendingSelectedSourceUrlsRaw: string = '';
  @State expandedSearchSourceGroups: string[] = [];
  @State searchViewportWidth: number = 360;
  @StorageLink('shelfUpdateTime') @Watch('onShelfChanged') shelfUpdateTime: number = 0;
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;
  @StorageLink('searchExploreShowResultCover') searchExploreShowResultCover: boolean = true;
  @StorageLink('searchExploreUseBookshelfCoverGallery') searchExploreUseBookshelfCoverGallery: boolean = false;
  @StorageLink('searchExploreShowResultTags') searchExploreShowResultTags: boolean = true;
  @StorageLink('searchExploreAggregateResults') @Watch('onSearchAggregationChanged')
  searchExploreAggregateResults: boolean = true;
  @StorageLink('searchExplorePromptAddToShelfOnBack') searchExplorePromptAddToShelfOnBack: boolean = true;
  @StorageLink('searchExploreExactSearch') exactSearch: boolean = false;
  @StorageLink('searchExploreExactSearchMatchAuthor') exactSearchMatchAuthor: boolean = true;
  @StorageLink('searchExploreShowSearchProgress') showSearchProgress: boolean = true;
  @StorageLink('searchExploreSearchConcurrency') searchConcurrency: number = 6;
  @StorageLink('searchExploreSelectedSourceGroups') selectedSourceGroupsRaw: string = '';
  @StorageLink('searchExploreSelectedSourceUrls') selectedSourceUrlsRaw: string =
    SearchExploreSettingsStore.LEGACY_SOURCE_SELECTION;
  @StorageLink('singleSourceSearchUrl') singleSourceSearchUrl: string = '';
  @StorageLink('singleSourceSearchName') singleSourceSearchName: string = '';
  @StorageLink('globalSearchPendingNonce') @Watch('onGlobalSearchPendingNonceChanged') globalSearchPendingNonce: number = 0;
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
  private readonly NO_SOURCES_SELECTED: string = '__NO_SOURCES_SELECTED__';

  aboutToAppear() {
    if (this.isActive) {
      this.initPage();
    }
  }

  onActiveChanged(): void {
    if (this.isActive) {
      this.initPage();
      this.refreshSearchShelfStatus();
      this.consumePendingGlobalSearch();
    }
  }

  onGlobalSearchPendingNonceChanged(): void {
    this.consumePendingGlobalSearch();
  }

  // 外部页面（书籍详情等）通过 AppStorage 请求全局搜索：nonce 先到时页面可能尚未切换为
  // 激活态，因此这里与 onActiveChanged 双入口消费，后到的一方负责填词并发起搜索。
  consumePendingGlobalSearch(): void {
    if (!this.isActive) return;
    const keyword = (AppStorage.get<string>('globalSearchPendingKeyword') || '').trim();
    if (!keyword) return;
    AppStorage.setOrCreate('globalSearchPendingKeyword', '');
    if (this.singleSourceSearchUrl) {
      // 全局检索必须退出单书源搜索模式，否则会被限定在旧书源内。
      this.clearSingleSourceSearch();
    }
    this.keyword = keyword;
    this.submitKeywordSearch();
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
      await this.loadSearchableSources(db);
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

  onSearchAggregationChanged(): void {
    this.applySearchResultsSnapshot(this.searchResults);
  }

  applySearchResultsSnapshot(books: SearchBook[]): void {
    this.searchResults = books;
    this.displayedSearchResults = this.searchExploreAggregateResults ?
      SearchResultAggregationStore.aggregate(books) : books.slice();
  }

  openSearchBookOrGroup(book: SearchBook): void {
    if (!this.searchExploreAggregateResults || book.aggregationCount <= 1 || !book.aggregationKey) {
      this.openSearchBookDetail(book);
      return;
    }
    const members = SearchResultAggregationStore.members(this.searchResults, book.aggregationKey);
    if (members.length <= 1) {
      this.openSearchBookDetail(members[0] || book);
      return;
    }
    const token = SearchResultAggregationStore.publish(book.name, members);
    router.pushUrl({
      url: 'pages/SearchResultGroup',
      params: { token: token, title: book.name }
    });
  }

  async loadSearchableSources(db: AppDatabase = AppDatabase.getInstance()): Promise<void> {
    try {
      const sources = await db.getEnabledBookSourcesForSearch();
      this.searchableSources = sources.filter((source: BookSource): boolean =>
        !!(source.bookSourceUrl && source.bookSourceName && source.searchUrl && source.searchRule?.bookList));
      const groups: string[] = [];
      for (const source of this.searchableSources) {
        const group = this.normalizeSourceGroup(source);
        if (!groups.includes(group)) groups.push(group);
      }
      this.sourceGroups = groups.sort((left: string, right: string): number => left.localeCompare(right));
      this.migrateLegacySearchSourceSelection();
      this.pruneSearchSourceSelection();
    } catch (e) {
      console.warn('加载可搜索书源失败:', e);
      this.searchableSources = [];
    }
  }

  async openSearchSourcePicker(): Promise<void> {
    this.showSearchHistoryDropdown = false;
    this.showSearchSettingsDialog = false;
    this.searchSourcePickerQuery = '';
    try {
      await this.loadSearchableSources();
    } catch (e) {
      console.warn('刷新可搜索书源失败:', e);
    }
    this.pendingSelectedSourceUrlsRaw = (this.singleSourceSearchUrl ? [this.singleSourceSearchUrl] :
      this.effectiveSelectedSourceUrls()).join('\n');
    this.expandedSearchSourceGroups = this.sourceGroups.length === 1 ? this.sourceGroups.slice() : [];
    this.showSearchSourcePicker = true;
  }

  filteredSearchableSources(): BookSource[] {
    const keyword = this.searchSourcePickerQuery.trim().toLowerCase().replace(/\s+/g, '');
    if (!keyword) return this.searchableSources;
    return this.searchableSources.filter((source: BookSource): boolean => {
      const text = `${source.bookSourceName}\n${source.bookSourceGroup}`.toLowerCase().replace(/\s+/g, '');
      return text.includes(keyword);
    });
  }

  filteredSearchSourceGroups(): string[] {
    const result: string[] = [];
    for (const source of this.filteredSearchableSources()) {
      const group = this.normalizeSourceGroup(source);
      if (!result.includes(group)) result.push(group);
    }
    return result.sort((left: string, right: string): number => left.localeCompare(right));
  }

  searchSourcesInGroup(group: string, filtered: boolean = false): BookSource[] {
    const sources = filtered ? this.filteredSearchableSources() : this.searchableSources;
    return sources.filter((source: BookSource): boolean => this.normalizeSourceGroup(source) === group);
  }

  searchableSourceUrls(): string[] {
    return this.searchableSources.map((source: BookSource): string => source.bookSourceUrl)
      .filter((url: string): boolean => !!url);
  }

  uniqueSourceUrls(urls: string[]): string[] {
    const result: string[] = [];
    for (const rawUrl of urls) {
      const url = (rawUrl || '').trim();
      if (url && !result.includes(url)) result.push(url);
    }
    return result;
  }

  pendingSelectedSourceUrls(): string[] {
    return this.uniqueSourceUrls(this.pendingSelectedSourceUrlsRaw.split('\n'));
  }

  setPendingSelectedSourceUrls(urls: string[]): void {
    this.pendingSelectedSourceUrlsRaw = this.uniqueSourceUrls(urls).join('\n');
  }

  selectedSourceUrls(): string[] {
    const raw = this.selectedSourceUrlsRaw.trim();
    if (!raw || raw === this.NO_SOURCES_SELECTED ||
      raw === SearchExploreSettingsStore.LEGACY_SOURCE_SELECTION) return [];
    return this.uniqueSourceUrls(raw.split('\n'));
  }

  isAllSearchSourcesSelected(): boolean {
    const raw = this.selectedSourceUrlsRaw.trim();
    return raw === '' || raw === SearchExploreSettingsStore.LEGACY_SOURCE_SELECTION;
  }

  isNoSearchSourcesSelected(): boolean {
    return this.selectedSourceUrlsRaw.trim() === this.NO_SOURCES_SELECTED;
  }

  effectiveSelectedSourceUrls(): string[] {
    if (this.isAllSearchSourcesSelected()) return this.searchableSourceUrls();
    if (this.isNoSearchSourcesSelected()) return [];
    const available = this.searchableSourceUrls();
    return this.selectedSourceUrls().filter((url: string): boolean => available.includes(url));
  }

  pendingSourceSelectionState(urls: string[]): number {
    const normalized = this.uniqueSourceUrls(urls);
    if (normalized.length === 0) return 0;
    let selectedCount = 0;
    for (const url of normalized) {
      if (this.pendingSelectedSourceUrls().includes(url)) selectedCount++;
    }
    if (selectedCount === 0) return 0;
    return selectedCount === normalized.length ? 2 : 1;
  }

  togglePendingAllSources(): void {
    this.setPendingSelectedSourceUrls(this.pendingSourceSelectionState(this.searchableSourceUrls()) === 2 ?
      [] : this.searchableSourceUrls());
  }

  togglePendingSourceGroup(group: string): void {
    const groupUrls = this.searchSourcesInGroup(group)
      .map((source: BookSource): string => source.bookSourceUrl);
    if (this.pendingSourceSelectionState(groupUrls) === 2) {
      this.setPendingSelectedSourceUrls(this.pendingSelectedSourceUrls()
        .filter((url: string): boolean => !groupUrls.includes(url)));
      return;
    }
    this.setPendingSelectedSourceUrls(this.pendingSelectedSourceUrls().concat(groupUrls));
  }

  togglePendingSource(source: BookSource): void {
    const url = source.bookSourceUrl;
    if (!url) return;
    if (this.pendingSelectedSourceUrls().includes(url)) {
      this.setPendingSelectedSourceUrls(this.pendingSelectedSourceUrls()
        .filter((item: string): boolean => item !== url));
    } else {
      this.setPendingSelectedSourceUrls(this.pendingSelectedSourceUrls().concat([url]));
    }
  }

  isSearchSourceGroupExpanded(group: string): boolean {
    return !!this.searchSourcePickerQuery.trim() || this.expandedSearchSourceGroups.includes(group);
  }

  toggleSearchSourceGroupExpanded(group: string): void {
    if (this.expandedSearchSourceGroups.includes(group)) {
      this.expandedSearchSourceGroups = this.expandedSearchSourceGroups
        .filter((item: string): boolean => item !== group);
    } else {
      this.expandedSearchSourceGroups = this.expandedSearchSourceGroups.concat([group]);
    }
  }

  selectedSourceGroupCount(urls: string[]): number {
    const groups: string[] = [];
    for (const source of this.searchableSources) {
      if (!urls.includes(source.bookSourceUrl)) continue;
      const group = this.normalizeSourceGroup(source);
      if (!groups.includes(group)) groups.push(group);
    }
    return groups.length;
  }

  searchScopeSummary(): string {
    if (this.singleSourceSearchUrl) {
      return this.singleSourceSearchName || this.singleSourceSearchUrl;
    }
    if (this.isAllSearchSourcesSelected()) {
      return this.searchableSources.length > 0 ? `全部书源 · ${this.searchableSources.length}` : '全部书源';
    }
    const selected = this.effectiveSelectedSourceUrls();
    if (selected.length === 0) return '未选择书源';
    if (selected.length === 1) {
      const source = this.searchableSources.find((item: BookSource): boolean => item.bookSourceUrl === selected[0]);
      return source?.bookSourceName || '1 个书源';
    }
    return `${selected.length} 个书源 · ${this.selectedSourceGroupCount(selected)} 个分组`;
  }

  migrateLegacySearchSourceSelection(): void {
    if (this.selectedSourceUrlsRaw.trim() !== SearchExploreSettingsStore.LEGACY_SOURCE_SELECTION) return;
    const legacyRaw = this.selectedSourceGroupsRaw.trim();
    if (!legacyRaw) {
      this.selectedSourceUrlsRaw = '';
    } else if (legacyRaw === this.NO_SOURCE_GROUPS_SELECTED) {
      this.selectedSourceUrlsRaw = this.NO_SOURCES_SELECTED;
    } else {
      const legacyGroups = legacyRaw.split('\n').map((group: string): string => group.trim())
        .filter((group: string): boolean => !!group);
      const urls = this.searchableSources.filter((source: BookSource): boolean =>
        legacyGroups.includes(this.normalizeSourceGroup(source)))
        .map((source: BookSource): string => source.bookSourceUrl);
      this.selectedSourceUrlsRaw = urls.length > 0 ? this.uniqueSourceUrls(urls).join('\n') : this.NO_SOURCES_SELECTED;
    }
    this.saveSearchExploreSettings();
  }

  pruneSearchSourceSelection(): void {
    if (this.isAllSearchSourcesSelected() || this.isNoSearchSourcesSelected()) return;
    const available = this.searchableSourceUrls();
    const selected = this.selectedSourceUrls().filter((url: string): boolean => available.includes(url));
    const normalized = selected.length > 0 ? selected.join('\n') : this.NO_SOURCES_SELECTED;
    if (normalized !== this.selectedSourceUrlsRaw) {
      this.selectedSourceUrlsRaw = normalized;
      this.saveSearchExploreSettings();
    }
  }

  applySearchSourceSelection(): void {
    const available = this.searchableSourceUrls();
    const selected = this.pendingSelectedSourceUrls()
      .filter((url: string): boolean => available.includes(url));
    this.selectedSourceUrlsRaw = selected.length === available.length ? '' :
      (selected.length > 0 ? selected.join('\n') : this.NO_SOURCES_SELECTED);
    this.selectedSourceGroupsRaw = '';
    this.singleSourceSearchUrl = '';
    this.singleSourceSearchName = '';
    this.saveSearchExploreSettings();
    this.resetSearchForScopeChange();
    this.showSearchSourcePicker = false;
  }

  resetSearchForScopeChange(): void {
    this.searchSessionId++;
    this.coordinator?.cancel();
    this.coordinator = null;
    this.isSearching = false;
    this.searchResults = [];
    this.displayedSearchResults = [];
    this.searchResultKeySet.clear();
    this.showResult = false;
    this.statusMessage = '';
    this.verificationUrl = '';
    this.verificationTitle = '';
  }

  build() {
    Stack() {
      Column() {
        Column() {
        Row() {
        if (ImmersiveMaterialRuntime.supportsHds()) {
          Row() {
            this.searchFieldContent()
          }
          .layoutWeight(1)
          .height(40)
          .borderRadius(20)
          .systemMaterial(this.searchFieldMaterial())
          .border({ width: 1, color: this.glassBorderColor() })
          .alignItems(VerticalAlign.Center)
        } else {
          Row() {
            this.searchFieldContent()
          }
          .layoutWeight(1)
          .height(40)
          .borderRadius(20)
          .backgroundColor(this.glassCardColor())
          .border({ width: ThemeRuntime.glassBorderWidth(), color: this.glassBorderColor() })
          .shadow({ radius: ThemeRuntime.glassShadowRadius(), color: this.glassShadowColor(), offsetX: ThemeRuntime.glassShadowOffsetX(), offsetY: ThemeRuntime.glassShadowOffsetY() })
          .alignItems(VerticalAlign.Center)
        }

        ImmersiveBackButton({
            icon: this.isSearching ? $r('sys.symbol.xmark') : $r('sys.symbol.magnifyingglass'),
            iconOffsetX: 0,
            iconColor: this.isSearching ? ThemeRuntime.dangerColor(this.appDarkMode) : this.primaryTextColor(),
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
          .margin({ left: AppSpacing.MD, right: -24 })
        }
        .width('100%')
        .height(56 + this.statusBarHeight)
        .padding({ left: AppSpacing.XL, right: AppSpacing.XL, top: this.statusBarHeight })
        .alignItems(VerticalAlign.Center)

        Row({ space: AppSpacing.SM }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(14)
            .fontColor([this.buttonColor()])
          Text(`搜索范围：${this.searchScopeSummary()}`)
            .fontSize(AppFontSize.BODY)
            .fontColor(this.primaryTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text('选择')
            .fontSize(AppFontSize.CAPTION)
            .fontColor(this.buttonColor())
        }
        .width('calc(100% - 32vp)')
        .height(36)
        .padding({ left: AppSpacing.LG, right: AppSpacing.LG })
        .margin({ left: AppSpacing.XL, right: AppSpacing.XL, bottom: AppSpacing.SM })
        .borderRadius(18)
        .backgroundColor(this.glassCardColor())
        .border({ width: 1, color: (this.singleSourceSearchUrl || !this.isAllSearchSourcesSelected()) ?
          this.buttonColor() : this.glassBorderColor() })
        .alignItems(VerticalAlign.Center)
        .onClick(() => this.openSearchSourcePicker())

        if (this.statusMessage) {
          Row() {
            Text(this.statusMessage)
              .fontSize(AppFontSize.BODY)
              .fontColor(this.secondaryTextColor())
              .layoutWeight(1)
              .textAlign(TextAlign.Center)

            if (this.verificationUrl) {
              Button('去验证')
                .height(28)
                .fontSize(AppFontSize.CAPTION)
                .borderRadius(14)
                .backgroundColor(this.buttonColor())
                .fontColor(ThemeRuntime.onAccentColor())
                .margin({ right: AppSpacing.LG })
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

        if (this.showResult && this.displayedSearchResults.length > 0) {
          SearchBookResultList({
            books: this.displayedSearchResults,
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
              this.openSearchBookOrGroup(book);
            },
            onReadBook: (book: SearchBook) => {
              this.readSearchBook(book);
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
              .fontSize(AppFontSize.BODY)
              .fontColor(this.subTextColor())
              .margin({ top: AppSpacing.MD })
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ top: this.searchTopOverlayHeight() })
          .justifyContent(FlexAlign.Center)
        } else if (this.showResult && this.displayedSearchResults.length === 0) {
          Column() {
            Text('未找到相关书籍')
              .fontSize(AppFontSize.BODY_LARGE)
              .fontColor(this.subTextColor())
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ top: this.searchTopOverlayHeight() })
          .justifyContent(FlexAlign.Center)
        } else {
          Column() {
            Text('输入关键词搜索书籍')
              .fontSize(AppFontSize.BODY_LARGE)
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

      if (this.showSearchSourcePicker) {
        this.searchSourcePickerDialog()
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

  @Builder
  searchFieldContent() {
    TextInput({ placeholder: '搜索书籍', text: this.keyword })
      .layoutWeight(1)
      .height(40)
      .enterKeyType(EnterKeyType.Search)
      .backgroundColor(Color.Transparent)
      .fontColor(this.primaryTextColor())
      .placeholderColor(this.subTextColor())
      .padding({ left: AppSpacing.XL, right: AppSpacing.XS })
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

  private searchFieldMaterial(): uiMaterial.ImmersiveMaterial {
    return new uiMaterial.ImmersiveMaterial({
      style: ImmersiveMaterialRuntime.materialStyle(),
      materialColor: this.appDarkMode ? '#351B1D22' : '#35FFFFFF',
      applyShadow: true,
      interactive: ImmersiveMaterialRuntime.configuredLightLevel() !== 'weak',
      lightEffect: ImmersiveMaterialRuntime.lightEffect()
    });
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
          .fontSize(AppFontSize.BODY_LARGE)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
          .layoutWeight(1)

        Text('清除')
          .fontSize(AppFontSize.BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.secondaryTextColor())
          .height(32)
          .padding({ left: AppSpacing.LG, right: AppSpacing.XS })
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.clearSearchHistory();
          })
      }
      .width('100%')
      .height(46)
      .padding({ left: AppSpacing.LG, right: AppSpacing.MD })
      .alignItems(VerticalAlign.Center)

      Divider()
        .color(this.glassBorderColor())
        .margin({ left: AppSpacing.LG, right: AppSpacing.LG })

      Scroll() {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.searchHistory, (keyword: string) => {
            Row() {
              Text(keyword)
                .fontSize(AppFontSize.BODY)
                .fontColor(this.secondaryTextColor())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .constraintSize({ maxWidth: '72%' })
            .height(34)
            .padding({ left: AppSpacing.LG, right: AppSpacing.LG })
            .margin({ right: AppSpacing.MD, bottom: AppSpacing.MD })
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
        .padding({ left: AppSpacing.LG, right: AppSpacing.SM, top: AppSpacing.LG, bottom: AppSpacing.XS })
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
      y: this.statusBarHeight + 92
    })
    .zIndex(10)
  }

  @Builder
  searchSourcePickerDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.appDarkMode ? '#52000000' : '#26FFFFFF')
        .backdropBlur(ThemeRuntime.glassBlur('popover', 18))
        .onClick(() => {
          this.showSearchSourcePicker = false;
        })

      Column() {
      Row() {
        Column({ space: AppSpacing.XXS }) {
          Text('搜索范围')
            .fontSize(AppFontSize.SUBTITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.primaryTextColor())
          Text(`已选 ${this.pendingSelectedSourceUrls().length} / ${this.searchableSources.length} 个书源`)
            .fontSize(AppFontSize.CAPTION)
            .fontColor(this.subTextColor())
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('完成')
          .fontSize(AppFontSize.BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.buttonColor())
          .height(36)
          .padding({ left: AppSpacing.XL, right: AppSpacing.XS })
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.applySearchSourceSelection();
          })
      }
      .width('100%')
      .height(44)
      .alignItems(VerticalAlign.Center)

      TextInput({ placeholder: '搜索书源或分组', text: this.searchSourcePickerQuery })
        .width('100%')
        .height(40)
        .fontSize(AppFontSize.BODY)
        .fontColor(this.primaryTextColor())
        .placeholderColor(this.subTextColor())
        .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode,
          ThemeRuntime.inputColor(this.appDarkMode), 'button'))
        .backdropBlur(ThemeRuntime.glassBlur('button', 12))
        .border({ width: ThemeRuntime.glassBorderWidth('button'),
          color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'button') })
        .borderRadius(20)
        .padding({ left: AppSpacing.LG, right: AppSpacing.LG })
        .onChange((value: string) => {
          this.searchSourcePickerQuery = value;
        })

      Row() {
        Toggle({ type: ToggleType.Checkbox, isOn: this.pendingSourceSelectionState(this.searchableSourceUrls()) === 2 })
          .selectedColor(this.buttonColor())
          .hitTestBehavior(HitTestMode.None)
        Column({ space: AppSpacing.XXS }) {
          Text('全部书源')
            .fontSize(AppFontSize.BODY_LARGE)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
          Text(`已启用且支持搜索的 ${this.searchableSources.length} 个书源`)
            .fontSize(AppFontSize.CAPTION)
            .fontColor(this.subTextColor())
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(this.pendingSourceSelectionState(this.searchableSourceUrls()) === 2 ? '取消全选' : '全选')
          .fontSize(AppFontSize.CAPTION)
          .fontColor(this.buttonColor())
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ left: AppSpacing.LG, right: AppSpacing.LG, top: AppSpacing.MD, bottom: AppSpacing.MD })
      .margin({ top: AppSpacing.MD, bottom: AppSpacing.MD })
      .alignItems(VerticalAlign.Center)
      .onClick(() => this.togglePendingAllSources())

      List({ space: AppSpacing.MD }) {
        ForEach(this.filteredSearchSourceGroups(), (group: string) => {
          ListItem() {
            Column() {
              Row() {
                Row() {
                  Toggle({ type: ToggleType.Checkbox, isOn: this.pendingSourceSelectionState(this.searchSourcesInGroup(group)
                    .map((source: BookSource): string => source.bookSourceUrl)) === 2 })
                    .selectedColor(this.buttonColor())
                    .hitTestBehavior(HitTestMode.None)
                }
                .height(48)
                .padding({ left: AppSpacing.LG, right: AppSpacing.MD })
                .onClick(() => this.togglePendingSourceGroup(group))

                Column({ space: AppSpacing.XXS }) {
                  Text(group)
                    .fontSize(AppFontSize.BODY_LARGE)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.primaryTextColor())
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${this.searchSourcesInGroup(group).filter((source: BookSource): boolean =>
                    this.pendingSelectedSourceUrls().includes(source.bookSourceUrl)).length} / ` +
                    `${this.searchSourcesInGroup(group).length} 个书源`)
                    .fontSize(AppFontSize.CAPTION)
                    .fontColor(this.subTextColor())
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                SymbolGlyph(this.isSearchSourceGroupExpanded(group) ?
                  $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
                  .fontSize(16)
                  .fontColor([this.subTextColor()])
                  .width(44)
                  .height(48)
                  .onClick(() => this.toggleSearchSourceGroupExpanded(group))
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              if (this.isSearchSourceGroupExpanded(group)) {
                Divider()
                  .color(this.glassBorderColor())
                  .margin({ left: 44, right: AppSpacing.LG })

                ForEach(this.searchSourcesInGroup(group, !!this.searchSourcePickerQuery.trim()),
                  (source: BookSource) => {
                  Row() {
                    Toggle({ type: ToggleType.Checkbox, isOn: this.pendingSourceSelectionState([source.bookSourceUrl]) === 2 })
                      .selectedColor(this.buttonColor())
                      .hitTestBehavior(HitTestMode.None)
                    Text(source.bookSourceName || source.bookSourceUrl)
                      .fontSize(AppFontSize.BODY)
                      .fontColor(this.secondaryTextColor())
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                      .margin({ left: AppSpacing.MD })
                  }
                  .width('100%')
                  .height(44)
                  .padding({ left: 30, right: AppSpacing.LG })
                  .alignItems(VerticalAlign.Center)
                  .onClick(() => this.togglePendingSource(source))
                }, (source: BookSource) => source.bookSourceUrl)
              }
            }
            .width('100%')
          }
        }, (group: string) => group)

        if (this.filteredSearchSourceGroups().length === 0) {
          ListItem() {
            Text('没有匹配的书源')
              .fontSize(AppFontSize.BODY)
              .fontColor(this.subTextColor())
              .width('100%')
              .height(96)
              .textAlign(TextAlign.Center)
          }
        }
      }
      .width('100%')
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    }
      .width(Math.min(520, Math.max(280, this.searchViewportWidth - 32)))
      .height('66%')
      .padding(AppSpacing.XL)
      .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
      .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
      .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
      .border({ width: ThemeRuntime.glassBorderWidth('overlay'),
        color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
    .zIndex(20)
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
      HdsFeedback.showToast('已删除该条搜索记录');
      if (this.searchHistory.length === 0) {
        this.searchHistoryEditing = false;
        this.searchHistoryExpanded = false;
        this.showSearchHistoryDropdown = false;
      }
    } catch (e) {
      console.error('删除搜索历史失败:', e);
      HdsFeedback.showToast('删除失败');
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
      HdsFeedback.showToast('清空失败');
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
    this.displayedSearchResults = [];
    this.searchResultKeySet.clear();
    this.showResult = false;
    this.statusMessage = '';
    this.verificationUrl = '';
    this.verificationTitle = '';
  }

  async doSearch() {
    const keyword = this.keyword.trim();
    if (!keyword) {
      HdsFeedback.showToast('请输入搜索关键词');
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
          HdsFeedback.showToast('指定书源不存在或已被删除');
          this.clearSingleSourceSearch();
          return;
        }
        targetSources.push(targetSource);
      } else {
        await this.loadSearchableSources(db);
        if (this.isNoSearchSourcesSelected() || this.effectiveSelectedSourceUrls().length === 0) {
          HdsFeedback.showToast('请先在搜索范围中选择书源');
          return;
        }
        if (!this.isAllSearchSourcesSelected()) {
          const selectedUrls = this.effectiveSelectedSourceUrls();
          targetSources.push(...this.searchableSources.filter((source: BookSource): boolean =>
            selectedUrls.includes(source.bookSourceUrl)));
        }
      }

      this.isSearching = true;
      this.showResult = true;
      this.searchResults = [];
      this.displayedSearchResults = [];
      this.searchResultKeySet.clear();
      this.statusMessage = targetSources.length === 1 ?
        `正在通过 ${this.singleSourceSearchName || targetSources[0].bookSourceName} 搜索...` :
        (targetSources.length > 1 ? `正在通过 ${targetSources.length} 个书源搜索...` : '正在搜索...');
      this.verificationUrl = '';
      this.verificationTitle = '';
      this.coordinator?.cancel();
      sessionId = ++this.searchSessionId;
      const coordinator = new SearchCoordinator(SearchExploreSettingsStore.getSearchConcurrency());
      activeCoordinator = coordinator;
      this.coordinator = coordinator;
      this.saveSearchHistoryLater(db, keyword);

      const callback: SearchCallback = (p: SearchProgress) => {
        if (sessionId !== this.searchSessionId || this.coordinator !== coordinator) {
          return;
        }
        if (p.sortedResults && (p.finished || (p.deltaResults && p.deltaResults.length > 0))) {
          // 搜索过程中直接采用协调器提供的完整稳定排序快照，避免按网络返回先后追加。
          this.applySearchResultsSnapshot(p.sortedResults);
          this.rebuildSearchResultKeys(p.sortedResults);
        } else if (p.finished) {
          this.applySearchResultsSnapshot(p.results);
          this.rebuildSearchResultKeys(p.results);
        } else if (p.deltaResults && p.deltaResults.length > 0) {
          this.applySearchResultsSnapshot(this.appendSearchResults(this.searchResults, p.deltaResults));
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
        targetSources: targetSources
      });
      if (sessionId !== this.searchSessionId || this.coordinator !== coordinator) {
        return;
      }
      const verifyUrl = this.verificationUrl || AppStorage.get<string>('pendingVerificationUrl') || '';
      if (!this.showSearchProgress || !this.isSearching) {
        const failureReason = coordinator.getLastFailureReason();
        const resultText = allBooks.length > 0 ?
          (this.searchExploreAggregateResults && this.displayedSearchResults.length < allBooks.length ?
            `搜索完成，共找到 ${allBooks.length} 个结果，聚合为 ${this.displayedSearchResults.length} 组` :
            `搜索完成，共找到 ${allBooks.length} 本书`) :
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

  async saveSearchHistoryLater(db: AppDatabase, keyword: string): Promise<void> {
    try {
      await db.saveSearchKeyword(keyword);
      const keywords = await db.getSearchKeywords();
      this.searchHistory = keywords.map((item: SearchKeyword): string => item.keyword);
    } catch (error) {
      console.warn('保存搜索历史失败:', error);
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

  normalizeSourceGroup(source: BookSource): string {
    const group = (source.bookSourceGroup || '').trim();
    return group || '未分组';
  }

  saveSearchExploreSettings(): void {
    SearchExploreSettingsStore.load(getContext(this)).then((settings: SearchExploreSettings) => {
      settings.showResultCover = this.searchExploreShowResultCover;
      settings.useBookshelfCoverGallery = this.searchExploreUseBookshelfCoverGallery;
      settings.showResultTags = this.searchExploreShowResultTags;
      settings.aggregateSearchResults = this.searchExploreAggregateResults;
      settings.promptAddToShelfOnBack = this.searchExplorePromptAddToShelfOnBack;
      settings.exactSearch = this.exactSearch;
      settings.exactSearchMatchAuthor = this.exactSearchMatchAuthor;
      settings.showSearchProgress = this.showSearchProgress;
      settings.searchConcurrency = SearchExploreSettingsStore.normalizeSearchConcurrency(this.searchConcurrency);
      settings.selectedSourceGroupsRaw = this.selectedSourceGroupsRaw;
      settings.selectedSourceUrlsRaw = this.selectedSourceUrlsRaw;
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
          .fontSize(AppFontSize.SUBTITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: AppSpacing.XL })

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

        this.switchSettingRow('聚合同名结果', this.searchExploreAggregateResults, (checked: boolean) => {
          this.searchExploreAggregateResults = checked;
          this.applySearchResultsSnapshot(this.searchResults);
          this.saveSearchExploreSettings();
        })

        this.numberSettingRow('搜索并发数', this.searchConcurrency, 1, 12, (value: number) => {
          this.searchConcurrency = SearchExploreSettingsStore.normalizeSearchConcurrency(value);
          this.saveSearchExploreSettings();
        })

        Button('完成')
          .width('100%')
          .height(44)
          .margin({ top: AppSpacing.XL })
          .backgroundColor(this.buttonColor())
          .fontColor(ThemeRuntime.onAccentColor())
          .onClick(() => {
            this.showSearchSettingsDialog = false;
          })
      }
      .width(this.searchSettingsPopupPanelWidth())
      .constraintSize({ maxHeight: 430 })
      .padding(AppSpacing.XL)
      .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
      .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
      .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
      .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
      .position({
        x: this.searchSettingsPopupPanelLeft(),
        y: this.statusBarHeight + 92
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
      .margin({ right: AppSpacing.XXS })
      .onClick(() => {
        this.showSearchHistoryDropdown = false;
        this.hideKeyboard();
        this.showSearchSettingsDialog = !this.showSearchSettingsDialog;
      })
  }

  @Builder
  switchSettingRow(title: string, checked: boolean, onChange: (checked: boolean) => void) {
    Row() {
      Text(title)
        .fontSize(AppFontSize.BODY_LARGE)
        .fontColor(this.primaryTextColor())
        .layoutWeight(1)

      AdaptiveSwitch({
        isOn: checked,
        onChange: onChange
      })
    }
    .width('100%')
    .height(42)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  numberSettingRow(title: string, value: number, minValue: number, maxValue: number, onChange: (value: number) => void) {
    Row() {
      Text(title)
        .fontSize(AppFontSize.BODY_LARGE)
        .fontColor(this.primaryTextColor())
        .layoutWeight(1)

      Row() {
        Text('−')
          .fontSize(AppFontSize.SUBTITLE)
          .fontColor(this.primaryTextColor())
          .width(30)
          .height(30)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            onChange(Math.max(minValue, this.searchConcurrency - 1));
          })
        Text(`${this.searchConcurrency}`)
          .fontSize(AppFontSize.BODY_LARGE)
          .fontColor(this.primaryTextColor())
          .width(42)
          .textAlign(TextAlign.Center)
        Text('+')
          .fontSize(AppFontSize.SUBTITLE)
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
    let height = this.statusBarHeight + 98;
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
