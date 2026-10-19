import { router, uiMaterial } from '@kit.ArkUI';
import deviceInfo from '@ohos.deviceInfo';
import { BookSource, SearchBook, SearchKeyword, BookTypeSupport } from '@legado/sourceengine';
import { AppDatabase } from '../../model/data/AppDatabase';
import { SearchCoordinator, SearchCallback, SearchProgress } from '../../core/book/SearchCoordinator';
import { SearchBookResultList } from '../../components/book/SearchBookResultList';
import { ImmersiveMaterialSurface } from '../../components/ImmersiveMaterialSurface';
import { GlassTagModifier, ImmersiveMaterialRuntime, ImmersiveTagModifier } from '../../utils/ImmersiveMaterialRuntime';
import { HdsFeedback } from '../../utils/HdsFeedback';
import { SearchBookShelfHelper } from '../../utils/SearchBookShelfHelper';
import { SearchExploreSettings, SearchExploreSettingsStore } from '../../utils/SearchExploreSettingsStore';
import { SearchResultAggregationStore } from '../../utils/SearchResultAggregationStore';
import { AppThemeSettingsStore } from '../../utils/AppThemeSettingsStore';
import { ThemeRuntime } from '../../theme/ThemeRuntime';
import { AdaptiveSwitch } from '../AdaptiveSwitch';
import { AppFontSize } from '../../theme/AppFontSize';
import { AppSpacing } from '../../theme/AppSpacing';

const SEARCH_CATEGORY_ALL = 'all';
// 小说、漫画、有声、视频各自的结果上限，互不挤占。
const SEARCH_RESULTS_PER_CATEGORY = 150;

class SearchCategoryChip {
  key: string = '';
  label: string = '';
  count: number = 0;
}

/** 首页"搜索"页签：搜索输入、历史、多源搜索进度与结果。 */
@Component
export struct SearchPage {
  /** 标题行里搜索范围标签、设置按钮，以及搜索框与搜索按钮的高度。 */
  static readonly HEADER_CONTROL_SIZE: number = 40;
  /** 结果分类栏的高度、两侧留白与选中指示条宽度。 */
  static readonly CATEGORY_BAR_HEIGHT: number = 44;
  static readonly CATEGORY_BAR_PADDING: number = 6;
  static readonly CATEGORY_INDICATOR_WIDTH: number = 18;
  static readonly STATUS_ROW_HEIGHT: number = 32;
  @Prop statusBarHeight: number = 0;
  @Prop navBarHeight: number = 0;
  @Prop @Watch('onActiveChanged') isActive: boolean = false;
  @State keyword: string = '';
  @State searchResults: SearchBook[] = [];
  @State displayedSearchResults: SearchBook[] = [];
  // 与 BookTypeSupport.MEDIA_CATEGORIES 同序：小说、漫画、有声、视频。
  @State searchCategoryCounts: number[] = [0, 0, 0, 0];
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
  /** 结果分类栏的实际宽度：沉浸材质底板需要具体数值。 */
  @State searchCategoryBarWidth: number = 0;
  @StorageLink('shelfUpdateTime') @Watch('onShelfChanged') shelfUpdateTime: number = 0;
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;
  @StorageLink('searchExploreShowResultCover') searchExploreShowResultCover: boolean = true;
  @StorageLink('searchExploreUseBookshelfCoverGallery') searchExploreUseBookshelfCoverGallery: boolean = false;
  @StorageLink('searchExploreShowResultTags') searchExploreShowResultTags: boolean = true;
  @StorageLink('searchExploreAggregateResults') @Watch('onSearchAggregationChanged')
  searchExploreAggregateResults: boolean = true;
  @StorageLink('searchResultCategory') searchResultCategory: string = SEARCH_CATEGORY_ALL;
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
    const counts = SearchResultAggregationStore.countByCategory(books);
    this.searchCategoryCounts = BookTypeSupport.MEDIA_CATEGORIES.map((category: string): number =>
      counts.get(category) || 0);
    const visible = SearchResultAggregationStore.filterByCategory(books, this.effectiveSearchCategory());
    this.displayedSearchResults = this.searchExploreAggregateResults ?
      SearchResultAggregationStore.aggregate(visible) : visible.slice();
  }

  searchCategoryCount(category: string): number {
    const index = BookTypeSupport.MEDIA_CATEGORIES.indexOf(category);
    return index >= 0 ? (this.searchCategoryCounts[index] || 0) : this.searchResults.length;
  }

  // 记住的分段在本次搜索里没有结果时，搜索结束后按"全部"展示，但不改写用户的选择。
  effectiveSearchCategory(): string {
    const selected = this.searchResultCategory;
    if (!BookTypeSupport.MEDIA_CATEGORIES.includes(selected)) return SEARCH_CATEGORY_ALL;
    if (!this.isSearching && this.searchCategoryCount(selected) === 0) return SEARCH_CATEGORY_ALL;
    return selected;
  }

  searchCategoryChips(): SearchCategoryChip[] {
    const labels: string[] = ['小说', '漫画', '有声', '视频'];
    const effective = this.effectiveSearchCategory();
    const chips: SearchCategoryChip[] = [];
    BookTypeSupport.MEDIA_CATEGORIES.forEach((category: string, index: number): void => {
      const count = this.searchCategoryCount(category);
      if (count === 0 && category !== effective) return;
      const chip = new SearchCategoryChip();
      chip.key = category;
      chip.label = labels[index];
      chip.count = count;
      chips.push(chip);
    });
    // 只有一种类型且未筛选时，分段栏没有可切换的内容。
    if (chips.length < 2 && effective === SEARCH_CATEGORY_ALL) return [];
    const all = new SearchCategoryChip();
    all.key = SEARCH_CATEGORY_ALL;
    all.label = '全部';
    all.count = this.searchResults.length;
    chips.unshift(all);
    return chips;
  }

  showSearchCategoryBar(): boolean {
    return this.showResult && this.searchResults.length > 0 && this.searchCategoryChips().length > 0;
  }

  selectSearchCategory(category: string): void {
    if (category === this.effectiveSearchCategory()) return;
    this.searchResultCategory = category;
    this.applySearchResultsSnapshot(this.searchResults);
    this.searchResultScroller.scrollToIndex(0);
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
    this.searchCategoryCounts = [0, 0, 0, 0];
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
            Text('搜索')
              .fontSize(AppFontSize.DISPLAY)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
              .flexShrink(0)

            Blank()

            this.searchScopeLabel()

            Row() {
              this.searchHeaderCircleButton($r('sys.symbol.gearshape'), this.showSearchSettingsDialog, '搜索设置', () => {
                this.showSearchHistoryDropdown = false;
                this.hideKeyboard();
                this.showSearchSettingsDialog = !this.showSearchSettingsDialog;
              })
            }
            .bindPopup(this.showSearchSettingsDialog, ImmersiveMaterialRuntime.popupMenuOptions((): void => {
              this.searchSettingsContent()
            }, Placement.BottomRight, this.appDarkMode, this.accentColor(), () => {
              this.showSearchSettingsDialog = false;
            }))
          }
          .width('100%')
          .height(56 + this.statusBarHeight)
          .padding({ left: AppSpacing.XL, right: AppSpacing.XL, top: this.statusBarHeight })
          .alignItems(VerticalAlign.Center)

          Row() {
            if (ImmersiveMaterialRuntime.supportsHds()) {
              Row() {
                this.searchFieldContent()
              }
              .layoutWeight(1)
              .height(SearchPage.HEADER_CONTROL_SIZE)
              .borderRadius(SearchPage.HEADER_CONTROL_SIZE / 2)
              .systemMaterial(this.searchFieldMaterial())
              .border({ width: 1, color: this.glassBorderColor() })
              .alignItems(VerticalAlign.Center)
            } else {
              Row() {
                this.searchFieldContent()
              }
              .layoutWeight(1)
              .height(SearchPage.HEADER_CONTROL_SIZE)
              .borderRadius(SearchPage.HEADER_CONTROL_SIZE / 2)
              .backgroundColor(this.glassCardColor())
              .shadow(ThemeRuntime.floatingControlShadow(this.appDarkMode))
              .alignItems(VerticalAlign.Center)
            }

            Row() {
              this.searchHeaderCircleButton(this.isSearching ? $r('sys.symbol.xmark') : $r('sys.symbol.magnifyingglass'),
                false, this.isSearching ? '停止搜索' : '搜索', () => {
                  this.onSearchButtonTap();
                })
            }
            .margin({ left: 10 })
          }
          .width('100%')
          .padding({ left: AppSpacing.XL, right: AppSpacing.XL, bottom: AppSpacing.MD })
          .alignItems(VerticalAlign.Center)
          .bindPopup(this.showSearchHistoryDropdown && this.showResult && this.searchHistory.length > 0,
            ImmersiveMaterialRuntime.popupMenuOptions((): void => {
              this.searchHistoryPopupContent()
            }, Placement.Bottom, this.appDarkMode, this.accentColor(), () => {
              this.showSearchHistoryDropdown = false;
            }, false))

          if (this.statusMessage) {
            Row({ space: AppSpacing.SM }) {
              if (this.isSearching) {
                LoadingProgress()
                  .width(16)
                  .height(16)
                  .color(this.secondaryTextColor())
              }
              Text(this.statusMessage)
                .fontSize(AppFontSize.CAPTION)
                .fontColor(this.secondaryTextColor())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)

              if (this.verificationUrl) {
                Text('去验证')
                  .fontSize(AppFontSize.CAPTION)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.accentColor())
                  .padding({ left: AppSpacing.MD, top: AppSpacing.XS, bottom: AppSpacing.XS })
                  .onClick(() => {
                    this.openVerification();
                  })
              }
            }
            .width('100%')
            .height(SearchPage.STATUS_ROW_HEIGHT)
            .padding({ left: AppSpacing.XL + AppSpacing.XS, right: AppSpacing.XL })
            .alignItems(VerticalAlign.Center)
          }

          if (this.showSearchCategoryBar()) {
            this.searchCategoryBar()
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
            Text(this.searchResults.length > 0 ? '该类型下没有结果' : '未找到相关书籍')
              .fontSize(AppFontSize.BODY_LARGE)
              .fontColor(this.subTextColor())
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ top: this.searchTopOverlayHeight() })
          .justifyContent(FlexAlign.Center)
        } else {
          this.searchIdleContent()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageColor())
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])


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

  onSearchButtonTap(): void {
    if (this.isSearching) {
      this.showSearchHistoryDropdown = false;
      this.searchSessionId++;
      this.coordinator?.cancel();
      this.coordinator = null;
      this.isSearching = false;
      this.applySearchResultsSnapshot(this.searchResults);
      this.statusMessage = '搜索已停止';
    } else {
      this.showSearchHistoryDropdown = false;
      this.hideKeyboard();
      this.doSearch();
    }
  }

  /** 标题右侧的搜索范围标签：按文字估宽，最多占屏宽 45%，点开书源选择。范围收窄时用强调色。 */
  @Builder
  searchScopeLabel() {
    Row() {
      ImmersiveMaterialSurface({
        surfaceWidth: this.searchScopeLabelWidth(),
        surfaceHeight: SearchPage.HEADER_CONTROL_SIZE,
        darkMode: this.appDarkMode,
        fallbackColor: this.cardColor(),
        glowColor: this.accentGlowColor()
      }) {
        Row({ space: AppSpacing.XS }) {
          Text(this.searchScopeSummary())
            .fontSize(AppFontSize.BODY)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.isSearchScopeNarrowed() ? this.accentColor() : this.primaryTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .flexShrink(1)
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(14)
            .fontColor([this.secondaryTextColor()])
        }
        .width('100%')
        .height('100%')
        .padding({ left: 14, right: 10 })
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .accessibilityText(`搜索范围：${this.searchScopeSummary()}，选择书源`)
        .onClick(() => {
          this.showSearchHistoryDropdown = false;
          this.openSearchSourcePicker();
        })
      }
    }
    .margin({ left: AppSpacing.MD, right: 10 })
  }

  isSearchScopeNarrowed(): boolean {
    return !!this.singleSourceSearchUrl || !this.isAllSearchSourcesSelected();
  }

  searchScopeLabelWidth(): number {
    const text = this.searchScopeSummary();
    let textWidth = 0;
    for (let index = 0; index < text.length; index++) {
      textWidth += text.charCodeAt(index) > 0x2E80 ? AppFontSize.BODY : AppFontSize.BODY * 0.6;
    }
    // 左右留白 24、箭头 14、间隔 4。
    const desired = Math.ceil(textWidth) + 42;
    return Math.max(72, Math.min(desired, Math.floor(this.searchViewportWidth * 0.45)));
  }

  @Builder
  searchHeaderCircleButton(icon: Resource, active: boolean, label: string, onTap: () => void) {
    ImmersiveMaterialSurface({
      surfaceWidth: SearchPage.HEADER_CONTROL_SIZE,
      surfaceHeight: SearchPage.HEADER_CONTROL_SIZE,
      darkMode: this.appDarkMode,
      fallbackColor: this.cardColor(),
      glowColor: this.accentGlowColor()
    }) {
      Stack() {
        SymbolGlyph(icon)
          .fontSize(20)
          .fontColor([this.isSearching && label === '停止搜索' ? ThemeRuntime.dangerColor(this.appDarkMode) :
            (active ? this.accentColor() : this.primaryTextColor())])
      }
      .width('100%')
      .height('100%')
      .accessibilityText(label)
      .onClick(() => onTap())
    }
  }

  /** 没搜索时页面上直接显示的搜索历史；没有历史时给出引导和当前范围。 */
  @Builder
  searchIdleContent() {
    Scroll() {
      Column() {
        if (this.searchHistory.length > 0) {
          Row() {
            Text('搜索历史')
              .fontSize(AppFontSize.BODY_LARGE)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.primaryTextColor())
              .layoutWeight(1)
            Text('清空')
              .fontSize(AppFontSize.BODY)
              .fontColor(this.secondaryTextColor())
              .padding({ left: AppSpacing.LG, top: AppSpacing.SM, bottom: AppSpacing.SM })
              .onClick(() => {
                this.clearSearchHistory();
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.searchHistory, (keyword: string) => {
              this.searchHistoryTag(keyword)
            }, (keyword: string) => keyword)
          }
          .width('100%')
          .margin({ top: AppSpacing.MD })

          Text('长按单条可删除')
            .fontSize(AppFontSize.CAPTION)
            .fontColor(this.secondaryTextColor())
            .opacity(0.8)
            .margin({ top: AppSpacing.XS })
        } else {
          Column({ space: AppSpacing.MD }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(48)
              .fontColor([this.secondaryTextColor()])
              .opacity(0.5)
            Text('输入书名或作者搜索')
              .fontSize(AppFontSize.BODY_LARGE)
              .fontColor(this.secondaryTextColor())
            Text(`当前范围：${this.searchScopeSummary()}`)
              .fontSize(AppFontSize.CAPTION)
              .fontColor(this.secondaryTextColor())
              .opacity(0.8)
          }
          .width('100%')
          .padding({ top: 96 })
          .alignItems(HorizontalAlign.Center)
        }
      }
      .width('100%')
      .padding({
        left: AppSpacing.XL,
        right: AppSpacing.XL,
        top: this.searchTopOverlayHeight() + AppSpacing.SM,
        bottom: this.resultListBottomInset()
      })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .align(Alignment.TopStart)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
  }

  @Builder
  searchHistoryTag(keyword: string) {
    Text(keyword)
      .fontSize(AppFontSize.BODY)
      .fontColor(this.primaryTextColor())
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .constraintSize({ maxWidth: '72%' })
      .height(34)
      .padding({ left: AppSpacing.LG, right: AppSpacing.LG })
      .margin({ right: AppSpacing.SM, bottom: AppSpacing.SM })
      .attributeModifier(new ImmersiveTagModifier(ThemeRuntime.cardColor(this.appDarkMode),
        this.secondaryTextColor(), this.appDarkMode))
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
  }

  @Builder
  searchCategoryBar() {
    Row() {
      if (this.searchCategoryBarWidth > 0) {
        ImmersiveMaterialSurface({
          surfaceWidth: this.searchCategoryBarWidth,
          surfaceHeight: SearchPage.CATEGORY_BAR_HEIGHT,
          darkMode: this.appDarkMode,
          fallbackColor: this.cardColor(),
          glowColor: this.accentGlowColor()
        }) {
          Stack({ alignContent: Alignment.BottomStart }) {
            Row() {
              ForEach(this.searchCategoryChips(), (chip: SearchCategoryChip) => {
                Text() {
                  Span(chip.label)
                    .fontSize(AppFontSize.BODY_LARGE)
                  Span(` ${chip.count}`)
                    .fontSize(AppFontSize.CAPTION)
                }
                .fontWeight(chip.key === this.effectiveSearchCategory() ? FontWeight.Medium : FontWeight.Regular)
                .fontColor(chip.key === this.effectiveSearchCategory() ? this.accentColor() : this.secondaryTextColor())
                .maxLines(1)
                .textAlign(TextAlign.Center)
                .layoutWeight(1)
                .height('100%')
                .accessibilityText(`${chip.label} ${chip.count} 条`)
                .accessibilitySelected(chip.key === this.effectiveSearchCategory())
                .onClick(() => this.selectSearchCategory(chip.key))
              }, (chip: SearchCategoryChip) =>
                `${chip.key}:${chip.count}:${chip.key === this.effectiveSearchCategory() ? 1 : 0}`)
            }
            .width('100%')
            .height('100%')
            .padding({ left: SearchPage.CATEGORY_BAR_PADDING, right: SearchPage.CATEGORY_BAR_PADDING })

            Row()
              .width(SearchPage.CATEGORY_INDICATOR_WIDTH)
              .height(3)
              .borderRadius(1.5)
              .backgroundColor(this.accentColor())
              .translate({ x: this.searchCategoryIndicatorX(), y: -5 })
              .animation({ duration: 280, curve: Curve.Friction })
              .hitTestBehavior(HitTestMode.None)
          }
          .width('100%')
          .height('100%')
        }
      }
    }
    .width(`calc(100% - ${AppSpacing.XL * 2}vp)`)
    .height(SearchPage.CATEGORY_BAR_HEIGHT)
    .margin({ left: AppSpacing.XL, right: AppSpacing.XL, bottom: AppSpacing.MD })
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const width = Math.floor(Number(newValue.width));
      if (Number.isFinite(width) && width > 0 && width !== this.searchCategoryBarWidth) {
        this.searchCategoryBarWidth = width;
      }
    })
  }

  /** 指示条居中在选中分类下方；各分类等宽平分去掉两侧留白后的宽度。 */
  searchCategoryIndicatorX(): number {
    const chips = this.searchCategoryChips();
    const count = Math.max(1, chips.length);
    const index = Math.max(0, chips.findIndex((chip: SearchCategoryChip) => chip.key === this.effectiveSearchCategory()));
    const itemWidth = (this.searchCategoryBarWidth - SearchPage.CATEGORY_BAR_PADDING * 2) / count;
    return SearchPage.CATEGORY_BAR_PADDING + itemWidth * index + (itemWidth - SearchPage.CATEGORY_INDICATOR_WIDTH) / 2;
  }

  @Builder
  searchFieldContent() {
    SymbolGlyph($r('sys.symbol.magnifyingglass'))
      .fontSize(18)
      .fontColor([this.secondaryTextColor()])
      .margin({ left: 14 })
    TextInput({ placeholder: '书名或作者', text: this.keyword })
      .layoutWeight(1)
      .height(SearchPage.HEADER_CONTROL_SIZE)
      .enterKeyType(EnterKeyType.Search)
      .backgroundColor(Color.Transparent)
      .fontColor(this.primaryTextColor())
      .placeholderColor(this.subTextColor())
      .padding({ left: AppSpacing.SM, right: AppSpacing.XS })
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

    if (this.keyword.length > 0) {
      SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
        .fontSize(18)
        .fontColor([this.secondaryTextColor()])
        .width(36)
        .height(36)
        .margin({ right: AppSpacing.XS })
        .accessibilityText('清除输入')
        .onClick(() => {
          this.keyword = '';
          this.showSearchHistoryDropdown = this.showResult && this.searchHistory.length > 0;
        })
    }
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

  /** 已有结果时聚焦空输入框弹出的搜索历史：沉浸光感弹出层，历史词为玻璃标签，点按搜索、长按删除。 */
  @Builder
  searchHistoryPopupContent() {
    Column() {
      Row() {
        Text('搜索历史')
          .fontSize(AppFontSize.BODY_LARGE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
          .layoutWeight(1)
        Text('清空')
          .fontSize(AppFontSize.BODY)
          .fontColor(this.secondaryTextColor())
          .padding({ left: AppSpacing.LG, top: AppSpacing.SM, bottom: AppSpacing.SM })
          .onClick(() => {
            this.showSearchHistoryDropdown = false;
            this.clearSearchHistory();
          })
      }
      .width('100%')
      .padding({ left: AppSpacing.MD, right: AppSpacing.SM })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.searchHistory, (keyword: string) => {
            Text(keyword)
              .fontSize(AppFontSize.BODY)
              .fontColor(this.primaryTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: '72%' })
              .height(34)
              .padding({ left: AppSpacing.LG, right: AppSpacing.LG })
              .margin({ right: AppSpacing.SM, bottom: AppSpacing.SM })
              .attributeModifier(new GlassTagModifier(this.accentColor(), this.appDarkMode))
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
        .padding({ left: AppSpacing.MD, right: AppSpacing.XS, top: AppSpacing.SM })
      }
      .width('100%')
      .constraintSize({ maxHeight: 260 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width(this.searchHistoryPopupPanelWidth())
    .padding({ top: AppSpacing.SM, bottom: AppSpacing.XS })
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
    this.searchCategoryCounts = [0, 0, 0, 0];
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
      this.searchCategoryCounts = [0, 0, 0, 0];
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
          // 结束后分段的回退规则生效，按最终状态重排一次。
          this.applySearchResultsSnapshot(this.searchResults);
        }
      };

      const allBooks = await coordinator.search(keyword, callback, {
        exactMatch: this.exactSearch,
        exactMatchAuthor: this.exactSearchMatchAuthor,
        targetSources: targetSources,
        maxResultsPerCategory: SEARCH_RESULTS_PER_CATEGORY
      });
      if (sessionId !== this.searchSessionId || this.coordinator !== coordinator) {
        return;
      }
      const verifyUrl = this.verificationUrl || AppStorage.get<string>('pendingVerificationUrl') || '';
      if (!this.showSearchProgress || !this.isSearching) {
        const failureReason = coordinator.getLastFailureReason();
        const groupCount = this.searchExploreAggregateResults ?
          SearchResultAggregationStore.aggregate(allBooks).length : allBooks.length;
        const resultText = allBooks.length > 0 ?
          (groupCount < allBooks.length ?
            `搜索完成，共找到 ${allBooks.length} 个结果，聚合为 ${groupCount} 组` :
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

  /** 搜索设置弹出层：开关即时生效，点弹出层外收起。 */
  @Builder
  searchSettingsContent() {
    Column() {
      Text('搜索设置')
        .fontSize(AppFontSize.BODY_LARGE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor())
        .width('100%')
        .margin({ bottom: AppSpacing.SM })

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

    }
    .width(this.searchSettingsPopupPanelWidth())
    .padding({ left: AppSpacing.LG, right: AppSpacing.LG, top: AppSpacing.LG, bottom: AppSpacing.SM })
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

  buttonColor(): string {
    return ThemeRuntime.buttonColor(this.appDarkMode);
  }

  accentColor(): string {
    return ThemeRuntime.accentColor(this.appDarkMode);
  }

  accentGlowColor(): string {
    return `#40${this.accentColor().substring(1)}`;
  }

  buttonBackgroundColor(): string {
    const normalized = AppThemeSettingsStore.normalizeColor(this.buttonColor(), AppThemeSettingsStore.DEFAULT_LIGHT_BUTTON_COLOR);
    return `#${this.appDarkMode ? '33' : '1A'}${normalized.substring(1)}`;
  }

  searchTopOverlayHeight(): number {
    let height = this.statusBarHeight + 56 + SearchPage.HEADER_CONTROL_SIZE + AppSpacing.MD;
    if (this.statusMessage) {
      height += SearchPage.STATUS_ROW_HEIGHT;
    }
    if (this.showSearchCategoryBar()) {
      height += SearchPage.CATEGORY_BAR_HEIGHT + AppSpacing.MD;
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
