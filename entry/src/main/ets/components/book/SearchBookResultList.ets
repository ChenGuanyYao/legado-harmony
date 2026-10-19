import { Book, SearchBook, BookTypeSupport } from '@legado/sourceengine';
import { ThemeRuntime } from '../../theme/ThemeRuntime';
import { BookDisplayHelper } from '../../utils/BookDisplayHelper';
import { CoverGallerySettings } from '../../utils/CoverGallerySettings';
import { BookCoverCache } from '../../utils/BookCoverCache';
import { SearchBookShelfHelper } from '../../utils/SearchBookShelfHelper';
import deviceInfo from '@ohos.deviceInfo';
import { HdsListItem, HdsSwipeActionOptions } from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { AppFontSize } from '../../theme/AppFontSize';
import { AppSpacing } from '../../theme/AppSpacing';

export type SearchBookAction = (book: SearchBook) => void;

class SearchBookResultDataSource implements IDataSource {
  private books: SearchBook[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number { return this.books.length; }

  getData(index: number): SearchBook { return this.books[index]; }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) this.listeners.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) this.listeners.splice(index, 1);
  }

  replace(books: SearchBook[]): void {
    this.books = books.slice();
    for (const listener of this.listeners) listener.onDataReloaded();
  }
}

@Component
export struct SearchBookResultList {
  // 加密的书源封面解密完成后递增，读取它的封面会重新取到本地文件地址。
  @StorageProp('sourceCoverRevision') sourceCoverRevision: number = 0;
  @StorageLink('appLightAccentColor') appLightAccentColor: string = '#007DFF';
  @StorageLink('appDarkAccentColor') appDarkAccentColor: string = '#4E9BFF';
  @StorageLink('bookshelfCoverAlbums') bookshelfCoverAlbums: string = '';
  @StorageLink('bookshelfLightCoverAlbumId') bookshelfLightCoverAlbumId: string = '';
  @StorageLink('bookshelfDarkCoverAlbumId') bookshelfDarkCoverAlbumId: string = '';
  @StorageLink('bookshelfCoverMode') bookshelfCoverMode: string = 'sequence';
  @Prop @Watch('onBooksChanged') books: SearchBook[] = [];
  @Prop @Watch('onShelfBookKeysChanged') shelfBookKeys: string[] = [];
  @Prop busyBookKeys: string[] = [];
  @Prop showLoadingMore: boolean = false;
  @Prop showKind: boolean = false;
  @Prop showResultCover: boolean = true;
  @Prop useBookshelfCoverGallery: boolean = false;
  @Prop showResultTags: boolean = true;
  @Prop showSourceLine: boolean = true;
  @Prop pageColor: string = '#F5F5F5';
  @Prop cardColor: string = '#FFFFFF';
  @Prop itemBorderColor: string = '#00000000';
  @Prop itemBorderWidth: number = 0;
  @Prop shadowColor: string = '#00000000';
  @Prop primaryTextColor: string = '#1F1F1F';
  @Prop secondaryTextColor: string = '#666666';
  @Prop subTextColor: string = '#999999';
  @Prop topPadding: number = 0;
  @Prop bottomPadding: number = 12;
  /** 'list' 为卡片列表，'grid' 为三列封面平铺。 */
  @Prop layoutMode: string = 'list';
  scroller: ListScroller = new ListScroller();
  private dataSource: SearchBookResultDataSource = new SearchBookResultDataSource();
  private tagCache: Map<string, string[]> = new Map<string, string[]>();
  private coverCache: Map<string, string> = new Map<string, string>();
  onOpenBook: SearchBookAction = (_book: SearchBook) => {};
  onReadBook: SearchBookAction = (_book: SearchBook) => {};
  onToggleShelf: SearchBookAction = (_book: SearchBook) => {};
  onNeedMetadata: SearchBookAction = (_book: SearchBook) => {};
  onReachEnd: () => void = () => {};

  aboutToAppear(): void {
    this.onBooksChanged();
  }

  onBooksChanged(): void {
    this.dataSource.replace(this.books);
    this.tagCache.clear();
    this.coverCache.clear();
  }

  onShelfBookKeysChanged(): void {
    // HdsListItem caches its swipe action options when the item is created.
    // Rebuild the data source when shelf membership changes so the action icon
    // and accessibility label are regenerated from the current state.
    this.dataSource.replace(this.books);
  }

  build() {
    if (this.layoutMode === 'grid') {
      this.resultGrid()
    } else {
      this.resultList()
    }
  }

  /** 三列封面平铺：多列 List 保留懒加载；顶部留白与底部加载提示放在分组页眉页脚里，不占格子。 */
  @Builder
  resultGrid() {
    List({ scroller: this.scroller }) {
      ListItemGroup({ header: this.gridHeader(), footer: this.gridFooter(), space: AppSpacing.LG }) {
        LazyForEach(this.dataSource, (book: SearchBook) => {
          ListItem() {
            this.searchResultGridItem(book)
          }
        }, (book: SearchBook) => `grid_${this.listItemKey(book)}`)
      }
    }
    .lanes(3, AppSpacing.MD)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .width('100%')
    .layoutWeight(1)
    .padding({ left: AppSpacing.XL, right: AppSpacing.XL })
    .backgroundColor(this.pageColor)
    .scrollBar(BarState.Auto)
    .onReachEnd(() => {
      this.onReachEnd();
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder
  gridHeader() {
    Row()
      .width('100%')
      .height(this.topPadding + AppSpacing.XS)
  }

  @Builder
  gridFooter() {
    Column() {
      if (this.showLoadingMore) {
        Row() {
          LoadingProgress()
            .width(20)
            .height(20)
          Text('继续加载中...')
            .fontSize(AppFontSize.BODY)
            .fontColor(this.subTextColor)
            .margin({ left: AppSpacing.MD })
        }
        .width('100%')
        .height(44)
        .justifyContent(FlexAlign.Center)
      }
      Column()
        .height(this.bottomPadding)
    }
    .width('100%')
  }

  @Builder
  searchResultGridItem(book: SearchBook) {
    Column({ space: AppSpacing.XS }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Stack() {
          Column() {
            Text(this.safeText(book.name, '书').substring(0, 1))
              .fontSize(AppFontSize.HEADLINE)
              .fontColor('#FFFFFF')
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.accentColor())

          if (this.showResultCover && this.displayCover(book)) {
            Image(this.displayCover(book))
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
          }
        }
        .width('100%')
        .aspectRatio(0.75)
        .borderRadius(8)
        .clip(true)

        if (book.aggregationCount > 1) {
          Text(`${book.aggregationCount} 个结果`)
            .fontSize(AppFontSize.MICRO)
            .fontColor('#FFFFFF')
            .padding({ left: AppSpacing.SM, right: AppSpacing.SM, top: AppSpacing.XXS, bottom: AppSpacing.XXS })
            .backgroundColor('#99000000')
            .borderRadius(8)
            .margin({ top: AppSpacing.XS, right: AppSpacing.XS })
        } else if (this.mediaBadge(book)) {
          Text(this.mediaBadge(book))
            .fontSize(AppFontSize.MICRO)
            .fontColor('#FFFFFF')
            .padding({ left: AppSpacing.SM, right: AppSpacing.SM, top: AppSpacing.XXS, bottom: AppSpacing.XXS })
            .backgroundColor(this.accentColor())
            .borderRadius(8)
            .margin({ top: AppSpacing.XS, right: AppSpacing.XS })
        }
      }
      .width('100%')
      .shadow({ radius: 8, color: this.isDarkMode() ? '#55000000' : '#22000000', offsetX: 0, offsetY: 3 })

      Text(this.safeText(book.name, '未知书名'))
        .fontSize(AppFontSize.BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: AppSpacing.XS })
      Text(this.safeText(book.author, '作者未知'))
        .fontSize(AppFontSize.CAPTION)
        .fontColor(this.subTextColor)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onOpenBook(book);
    })
    .onAppear(() => {
      if (book.aggregationCount <= 1 &&
        (!this.safeText(book.author, '') || (this.showResultCover && !this.safeText(book.coverUrl, '')))) {
        this.onNeedMetadata(book);
      }
    })
  }

  @Builder
  resultList() {
    List({ scroller: this.scroller, space: AppSpacing.MD }) {
      if (this.topPadding > 0) {
        ListItem() {
          Row()
            .height(this.topPadding)
        }
      }

      LazyForEach(this.dataSource, (book: SearchBook) => {
        this.searchResultItem(book)
      }, (book: SearchBook) => this.listItemKey(book))

      if (this.showLoadingMore) {
        ListItem() {
          Row() {
            LoadingProgress()
              .width(20)
              .height(20)
            Text('继续加载中...')
              .fontSize(AppFontSize.BODY)
              .fontColor(this.subTextColor)
              .margin({ left: AppSpacing.MD })
          }
          .width('100%')
          .height(44)
          .justifyContent(FlexAlign.Center)
        }
      }

      ListItem() {
        Column()
          .height(this.bottomPadding)
      }
    }
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .width('100%')
    .layoutWeight(1)
    .padding({ left: AppSpacing.XL, right: AppSpacing.XL })
    .backgroundColor(this.pageColor)
    .scrollBar(BarState.Auto)
    .onReachEnd(() => {
      this.onReachEnd();
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  private supportsHdsListItem(): boolean {
    return deviceInfo.sdkApiVersion >= 26;
  }

  @Builder
  searchResultItem(book: SearchBook) {
    if (this.supportsHdsListItem()) {
      HdsListItem({
        customItemBuilder: () => {
          this.searchResultCard(book)
        },
        // 聚合项只是进入同名结果页，不能直接执行某个来源书籍的操作。
        swipeActionOptions: book.aggregationCount > 1 ? undefined : this.searchResultSwipeActions(book)
      })
    } else {
      // API 25 及以下保留原生 ListItem，避免加载 HDS 滑动容器。
      ListItem() {
        this.searchResultCard(book)
      }
      .swipeAction(book.aggregationCount > 1 ? {} : {
        end: {
          builder: () => {
            this.searchResultFallbackSwipeActions(book)
          },
          actionAreaDistance: 128,
          onAction: () => this.onReadBook(book)
        },
        edgeEffect: SwipeEdgeEffect.Spring
      })
    }
  }

  /**
   * 结果行背景：封面按极低分辨率解码后拉伸铺满，得到模糊效果而不做实时模糊；
   * 上面盖一层半透明卡片色保证文字可读，标签的玻璃材质也因此有内容可透出。最底层垫主题色。
   */
  @Builder
  resultCardBackdrop(book: SearchBook) {
    Stack() {
      // 主题色始终垫在最底层：封面加载失败或还没加载出来时露出主题色，而不是一片白。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.accentColor())
      if (this.showResultCover && this.displayCover(book)) {
        Image(this.displayCover(book))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .sourceSize({ width: 12, height: 16 })
          .interpolation(ImageInterpolation.High)
      }
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.resultCardScrimColor())
    }
    .width('100%')
    .height('100%')
  }

  resultCardScrimColor(): string {
    const card = /^#[0-9A-Fa-f]{6}$/.test(this.cardColor) ? this.cardColor : (this.isDarkMode() ? '#191B1F' : '#FFFFFF');
    return `${this.isDarkMode() ? '#C2' : '#B8'}${card.substring(1)}`;
  }

  @Builder
  searchResultCard(book: SearchBook) {
    Row() {
      if (this.showResultCover) {
        this.coverView(book)
      }

      Column() {
        Row({ space: AppSpacing.SM }) {
          Text(this.safeText(book.name, '未知书名'))
            .fontSize(AppFontSize.BODY_LARGE)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.primaryTextColor)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .flexShrink(1)

          if (this.mediaBadge(book)) {
            Text(this.mediaBadge(book))
              .fontSize(AppFontSize.CAPTION)
              .fontColor(this.accentColor())
              .padding({ left: AppSpacing.SM, right: AppSpacing.SM, top: 1, bottom: 1 })
              .border({ width: 1, color: this.accentColor() })
              .borderRadius(ThemeRuntime.mediumRadius())
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(this.safeText(book.author, '作者未知'))
          .fontSize(AppFontSize.BODY)
          .fontColor(this.secondaryTextColor)
          .margin({ top: AppSpacing.XS })

        if (this.showResultTags && this.getTags(book).length > 0) {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.getTags(book), (tag: string, index: number) => {
              this.tagChip(tag, index)
            })
          }
          .width('100%')
          .margin({ top: AppSpacing.SM })
        }

        if (this.metadataLine(book)) {
          Text(this.metadataLine(book))
            .fontSize(AppFontSize.CAPTION)
            .fontColor(this.subTextColor)
            .margin({ top: AppSpacing.XXS })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }

        if (this.showSourceLine) {
          Text(this.sourceLine(book))
            .fontSize(AppFontSize.CAPTION)
            .fontColor(this.subTextColor)
            .margin({ top: this.showResultTags && this.getTags(book).length > 0 ? 6 : 4 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .margin({ left: this.showResultCover ? 12 : 0 })
      .alignItems(HorizontalAlign.Start)

      if (book.aggregationCount > 1) {
        this.aggregationIndicator(book)
      }
    }
    .width('100%')
    .padding(AppSpacing.LG)
    .backgroundColor(this.cardColor)
    .background(this.resultCardBackdrop(book))
    .borderRadius(ThemeRuntime.cardRadius())
    .clip(true)
    .border({ width: this.itemBorderWidth, color: this.itemBorderColor })
    .shadow({ radius: 10, color: this.shadowColor, offsetX: 0, offsetY: 4 })
    .onClick(() => {
      this.onOpenBook(book);
    })
    .onAppear(() => {
      if (book.aggregationCount <= 1 &&
        (!this.safeText(book.author, '') || (this.showResultCover && !this.safeText(book.coverUrl, '')))) {
        this.onNeedMetadata(book);
      }
    })
  }

  private searchResultSwipeActions(book: SearchBook): HdsSwipeActionOptions {
    const options: HdsSwipeActionOptions = {
      icons: [
        {
          icon: new SymbolGlyphModifier(this.searchResultShelfActionIcon(book)),
          // 使用主题按钮色，随当前主题保持一致并确保图标有足够对比度。
          backgroundColor: ThemeRuntime.buttonColor(this.isDarkMode()),
          iconOptions: {
            accessibilityText: SearchBookShelfHelper.isInShelf(book, this.shelfBookKeys) ? '移出书架' : '加入书架'
          },
          onAction: () => {
            this.onToggleShelf(book);
          }
        },
        {
          icon: new SymbolGlyphModifier($r('sys.symbol.book')),
          backgroundColor: ThemeRuntime.accentColor(this.isDarkMode()),
          iconOptions: {
            accessibilityText: '阅读'
          },
          onAction: () => {
            this.onReadBook(book);
          }
        }
      ]
    };
    return options;
  }

  searchResultShelfActionIcon(book: SearchBook): Resource {
    return SearchBookShelfHelper.isInShelf(book, this.shelfBookKeys) ?
      $r('sys.symbol.bookshelf_badge_checkmark') : $r('sys.symbol.bookshelf_badge_plus');
  }

  @Builder
  searchResultFallbackSwipeActions(book: SearchBook) {
    Row() {
      Column({ space: AppSpacing.XS }) {
        SymbolGlyph(this.searchResultShelfActionIcon(book))
          .fontSize(22)
          .fontColor(['#FFFFFF'])
        Text(SearchBookShelfHelper.isInShelf(book, this.shelfBookKeys) ? '移出书架' : '加入书架')
          .fontSize(AppFontSize.CAPTION)
          .fontColor('#FFFFFF')
      }
      .width(82)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(ThemeRuntime.buttonColor(this.isDarkMode()))
      .onClick(() => this.onToggleShelf(book))

      Column({ space: AppSpacing.XS }) {
        SymbolGlyph($r('sys.symbol.book'))
          .fontSize(22)
          .fontColor(['#FFFFFF'])
        Text('阅读')
          .fontSize(AppFontSize.CAPTION)
          .fontColor('#FFFFFF')
      }
      .width(64)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(ThemeRuntime.accentColor(this.isDarkMode()))
      .onClick(() => this.onReadBook(book))
    }
    .height('100%')
  }

  @Builder
  aggregationIndicator(book: SearchBook) {
    Column({ space: AppSpacing.XXS }) {
      Text(`${book.aggregationCount}`)
        .fontSize(AppFontSize.BODY_LARGE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.accentColor())
      Text('结果')
        .fontSize(AppFontSize.CAPTION)
        .fontColor(this.subTextColor)
    }
    .width(64)
    .height(44)
    .margin({ left: AppSpacing.LG })
    .justifyContent(FlexAlign.Center)
  }


  // 小说是默认类型，不加角标。
  mediaBadge(book: SearchBook): string {
    const category = BookTypeSupport.mediaCategoryOf(book);
    if (category === BookTypeSupport.CATEGORY_COMIC) return '漫画';
    if (category === BookTypeSupport.CATEGORY_AUDIO) return '有声';
    if (category === BookTypeSupport.CATEGORY_VIDEO) return '视频';
    return '';
  }

  sourceLine(book: SearchBook): string {
    if (book.aggregationCount > 1) {
      return `已聚合 ${book.aggregationCount} 个同名结果，点击展开`;
    }
    return this.safeText(book.originName, '');
  }

  getTags(book: SearchBook): string[] {
    if (!this.showResultTags) {
      return [];
    }
    const key = `${this.itemKey(book)}\n${book.kind || ''}\n${book.status || ''}`;
    const cached = this.tagCache.get(key);
    if (cached) return cached;
    const tags = BookDisplayHelper.splitTags(this.safeText(book.kind, ''), this.safeText(book.status, ''));
    this.tagCache.set(key, tags);
    return tags;
  }

  @Builder
  tagChip(tag: string, index: number) {
    Text(tag)
      .fontSize(AppFontSize.CAPTION)
      .fontColor(BookDisplayHelper.getTagTextColor(index, this.isDarkMode()))
      .padding({ left: AppSpacing.SM, right: AppSpacing.SM, top: AppSpacing.XXS, bottom: AppSpacing.XXS })
      .attributeModifier(BookDisplayHelper.getGlassTagModifier(index, this.isDarkMode()))
      .margin({ right: AppSpacing.SM, bottom: AppSpacing.XS })
  }

  @Builder
  coverView(book: SearchBook) {
    Stack() {
      Column() {
        Text(this.safeText(book.name, '书').substring(0, 1))
          .fontSize(AppFontSize.HEADLINE)
          .fontColor('#FFFFFF')
      }
      .width(54)
      .height(72)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.accentColor())

      if (this.displayCover(book)) {
        Image(this.displayCover(book))
          .width(54)
          .height(72)
          .objectFit(ImageFit.Cover)
      }
    }
    .width(54)
    .height(72)
    .borderRadius(6)
    .clip(true)
    .backgroundColor(this.subTextColor)
  }

  isDarkMode(): boolean {
    return this.pageColor === '#101113' || this.cardColor === '#191B1F';
  }

  accentColor(): string {
    return this.isDarkMode() ? this.appDarkAccentColor : this.appLightAccentColor;
  }

  displayCover(book: SearchBook): string {
    const key = `${this.itemKey(book)}\n${book.coverUrl || ''}`;
    const cached = this.coverCache.get(key);
    if (cached !== undefined) return this.imageCover(cached);
    let result = '';
    if (this.useBookshelfCoverGallery) {
      const galleryCover = this.bookshelfGalleryCover(book);
      if (galleryCover) {
        result = galleryCover;
      }
    }
    if (!result) result = this.safeText(book.coverUrl, '');
    this.coverCache.set(key, result);
    return this.imageCover(result);
  }

  imageCover(raw: string): string {
    return this.sourceCoverRevision >= 0 ? BookCoverCache.displayCover(getContext(this), raw) : raw;
  }

  metadataLine(book: SearchBook): string {
    const parts: string[] = [];
    if (this.safeText(book.wordCount, '')) parts.push(`字数：${this.safeText(book.wordCount, '')}`);
    if (this.safeText(book.latestChapterTitle, '')) parts.push(`最新：${this.safeText(book.latestChapterTitle, '')}`);
    if (this.safeText(book.updateTime, '')) parts.push(`更新：${this.safeText(book.updateTime, '')}`);
    return parts.join(' · ');
  }

  bookshelfGalleryCover(searchBook: SearchBook): string {
    const book = new Book();
    book.name = this.safeText(searchBook.name, '');
    book.author = this.safeText(searchBook.author, '');
    book.bookUrl = this.safeText(searchBook.bookUrl, '');
    book.coverUrl = this.safeText(searchBook.coverUrl, '');
    const covers = CoverGallerySettings.getDisplayCoverList(
      book,
      this.isDarkMode(),
      this.bookshelfCoverAlbums,
      this.bookshelfLightCoverAlbumId,
      this.bookshelfDarkCoverAlbumId,
      'all',
      '',
      true,
      this.bookshelfCoverMode
    );
    return BookDisplayHelper.pickCover(covers);
  }

  itemKey(book: SearchBook): string {
    if (book.aggregationCount > 1 && book.aggregationKey) {
      // LazyForEach reuses a child when its key is unchanged. Search results arrive incrementally,
      // so include the current member count to rebuild the card when a group grows.
      return `aggregation:${book.aggregationKey}:${book.aggregationCount}`;
    }
    const key = SearchBookShelfHelper.keyOf(book);
    return `${key || this.safeText(book.bookUrl, '')}|${this.safeText(book.originName, '')}|${this.safeText(book.name, '')}`;
  }

  listItemKey(book: SearchBook): string {
    const baseKey = this.itemKey(book);
    if (book.aggregationCount > 1) return baseKey;
    const shelfState = SearchBookShelfHelper.isInShelf(book, this.shelfBookKeys) ? 'shelf' : 'not_shelf';
    return `${baseKey}|${shelfState}`;
  }

  safeText(value: string, fallback: string): string {
    const text = (value || '').trim();
    return text || fallback;
  }
}
