class CardRouteParams {
  shortcutAction: string = 'open_book';
  bookUrl: string = '';

  constructor(bookUrl: string) {
    this.bookUrl = bookUrl;
  }
}

class CardRouteAction {
  action: string = 'router';
  abilityName: string = 'EntryAbility';
  params: CardRouteParams;

  constructor(bookUrl: string) {
    this.params = new CardRouteParams(bookUrl);
  }
}

class CardOpenAppParams {
  source: string = 'recentReadCard';
}

/** 空状态点「打开书架」：只拉起应用，不带 shortcutAction。 */
class CardOpenAppAction {
  action: string = 'router';
  abilityName: string = 'EntryAbility';
  params: CardOpenAppParams = new CardOpenAppParams();
}

class CardBook {
  name: string = '';
  chapter: string = '';
  brief: string = '';
  progress: string = '';
  percent: number = -1;
  time: string = '';
  url: string = '';
  cover: string = '';
}

// 与 RecentReadCardData 中的 RECENT_READ_DIMENSION_* 一致（formInfo.FormDimension 的取值）。
const DIMENSION_2_2 = 2;
const DIMENSION_4_4 = 4;
const COVER_RATIO = 0.72;

let storage = new LocalStorage();

@Entry(storage)
@Component
struct RecentReadCard {
  @LocalStorageProp('version') version: number = 0;
  @LocalStorageProp('orderSignature') orderSignature: string = '';
  @LocalStorageProp('dimension') dimension: number = 3;
  @LocalStorageProp('darkMode') darkMode: boolean = false;
  @LocalStorageProp('count') count: number = 0;
  @LocalStorageProp('emptyTitle') emptyTitle: string = '暂无最近阅读';
  @LocalStorageProp('emptySubtitle') emptySubtitle: string = '打开书架阅读后会显示在这里';
  @LocalStorageProp('accentColor') accentColor: string = '#007DFF';
  @LocalStorageProp('accentBackgroundColor') accentBackgroundColor: string = '#1A007DFF';
  @LocalStorageProp('cardBackgroundColor') cardBackgroundColor: string = '';

  @LocalStorageProp('book0Name') book0Name: string = '';
  @LocalStorageProp('book0Chapter') book0Chapter: string = '';
  @LocalStorageProp('book0Brief') book0Brief: string = '';
  @LocalStorageProp('book0Progress') book0Progress: string = '';
  @LocalStorageProp('book0Percent') book0Percent: number = -1;
  @LocalStorageProp('book0Time') book0Time: string = '';
  @LocalStorageProp('book0Url') book0Url: string = '';
  @LocalStorageProp('book0Cover') book0Cover: string = '';

  @LocalStorageProp('book1Name') book1Name: string = '';
  @LocalStorageProp('book1Chapter') book1Chapter: string = '';
  @LocalStorageProp('book1Brief') book1Brief: string = '';
  @LocalStorageProp('book1Progress') book1Progress: string = '';
  @LocalStorageProp('book1Percent') book1Percent: number = -1;
  @LocalStorageProp('book1Time') book1Time: string = '';
  @LocalStorageProp('book1Url') book1Url: string = '';
  @LocalStorageProp('book1Cover') book1Cover: string = '';

  @LocalStorageProp('book2Name') book2Name: string = '';
  @LocalStorageProp('book2Chapter') book2Chapter: string = '';
  @LocalStorageProp('book2Brief') book2Brief: string = '';
  @LocalStorageProp('book2Progress') book2Progress: string = '';
  @LocalStorageProp('book2Percent') book2Percent: number = -1;
  @LocalStorageProp('book2Time') book2Time: string = '';
  @LocalStorageProp('book2Url') book2Url: string = '';
  @LocalStorageProp('book2Cover') book2Cover: string = '';

  @LocalStorageProp('book3Name') book3Name: string = '';
  @LocalStorageProp('book3Chapter') book3Chapter: string = '';
  @LocalStorageProp('book3Brief') book3Brief: string = '';
  @LocalStorageProp('book3Progress') book3Progress: string = '';
  @LocalStorageProp('book3Percent') book3Percent: number = -1;
  @LocalStorageProp('book3Time') book3Time: string = '';
  @LocalStorageProp('book3Url') book3Url: string = '';
  @LocalStorageProp('book3Cover') book3Cover: string = '';

  @LocalStorageProp('book4Name') book4Name: string = '';
  @LocalStorageProp('book4Chapter') book4Chapter: string = '';
  @LocalStorageProp('book4Brief') book4Brief: string = '';
  @LocalStorageProp('book4Progress') book4Progress: string = '';
  @LocalStorageProp('book4Percent') book4Percent: number = -1;
  @LocalStorageProp('book4Time') book4Time: string = '';
  @LocalStorageProp('book4Url') book4Url: string = '';
  @LocalStorageProp('book4Cover') book4Cover: string = '';

  build() {
    Column() {
      Text(`${this.version}|${this.orderSignature}`)
        .height(0)
        .opacity(0)
        .fontSize(1)

      // @Builder 按值传参不会随数据刷新，按 version 重建整棵内容树，保证每次 updateForm 都是新数据。
      ForEach([this.version], (_version: number) => {
        if (this.count <= 0 || !this.book0Url) {
          this.emptyState()
        } else if (this.dimension === DIMENSION_2_2) {
          this.smallLayout(this.book(0))
        } else if (this.dimension === DIMENSION_4_4) {
          this.largeLayout()
        } else {
          this.mediumLayout()
        }
      }, (version: number) => `${version}`)
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor(this.cardBackgroundColor || this.defaultBackgroundColor())
  }

  // ---------- 2×2：只放最近一本 ----------

  @Builder
  smallLayout(item: CardBook) {
    Column() {
      Row({ space: 10 }) {
        this.cover(item, 6)
        Column() {
          Text(item.name)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(item.chapter)
            .fontSize(10)
            .fontColor(this.secondaryTextColor())
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
          Blank()
          Text(item.time)
            .fontSize(10)
            .fontColor(this.secondaryTextColor())
            .maxLines(1)
        }
        .layoutWeight(1)
        .height('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)

      this.progressBlock(item, false)
    }
    .width('100%')
    .height('100%')
    .onClick(() => this.openBook(item.url))
  }

  // ---------- 2×4：主推最近一本 + 两本小图 ----------

  @Builder
  mediumLayout() {
    Row({ space: 12 }) {
      this.hero(this.book(0), true)
      if (this.book1Url) {
        Divider()
          .vertical(true)
          .height('100%')
          .color(this.dividerColor())
        Column({ space: 8 }) {
          this.sideTile(this.book(1))
          if (this.book2Url) {
            this.sideTile(this.book(2))
          } else {
            Blank()
              .layoutWeight(1)
          }
        }
        .width('34%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  sideTile(item: CardBook) {
    Row({ space: 8 }) {
      this.cover(item, 4)
      Column() {
        Text(item.name)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.chapter)
          .fontSize(10)
          .fontColor(this.secondaryTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .height('100%')
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .onClick(() => this.openBook(item.url))
  }

  // ---------- 4×4：顶部主推 + 下方四行列表 ----------

  @Builder
  largeLayout() {
    Column() {
      Row() {
        Text('最近阅读')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
          .layoutWeight(1)
        this.refreshButton()
      }
      .width('100%')
      .height(24)

      Row() {
        this.hero(this.book(0), false)
      }
      .width('100%')
      .height('42%')
      .margin({ top: 8 })

      Divider()
        .color(this.dividerColor())
        .margin({ top: 10, bottom: 4 })

      Column() {
        if (this.book1Url) {
          this.listRow(this.book(1))
        }
        if (this.book2Url) {
          this.listRow(this.book(2))
        }
        if (this.book3Url) {
          this.listRow(this.book(3))
        }
        if (this.book4Url) {
          this.listRow(this.book(4))
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  listRow(item: CardBook) {
    Row({ space: 10 }) {
      this.cover(item, 3)
      Column() {
        Text(item.name)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.progress ? `${item.brief} · ${item.progress}` : item.chapter)
          .fontSize(10)
          .fontColor(this.secondaryTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text(item.time)
        .fontSize(10)
        .fontColor(this.secondaryTextColor())
        .maxLines(1)
    }
    .width('100%')
    .height('25%')
    .padding({ top: 4, bottom: 4 })
    .onClick(() => this.openBook(item.url))
  }

  // ---------- 公共部件 ----------

  @Builder
  hero(item: CardBook, showRefresh: boolean) {
    Row({ space: 12 }) {
      this.cover(item, 7)
      Column() {
        Row() {
          Text(item.time ? `上次阅读 ${item.time}` : '继续阅读')
            .fontSize(10)
            .fontColor(this.secondaryTextColor())
            .maxLines(1)
            .layoutWeight(1)
          if (showRefresh) {
            this.refreshButton()
          }
        }
        .width('100%')
        .height(16)

        Text(item.name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
        Text(item.chapter)
          .fontSize(11)
          .fontColor(this.secondaryTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })

        Blank()

        this.progressBlock(item, true)

        Text('继续阅读')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.accentColor)
          .backgroundColor(this.accentBackgroundColor)
          .borderRadius(12)
          .padding({ left: 12, right: 12, top: 3, bottom: 3 })
          .margin({ top: 5 })
      }
      .layoutWeight(1)
      .height('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .height('100%')
    .onClick(() => this.openBook(item.url))
  }

  /** 进度条 + 「8 / 420 章 · 2%」；章节数未知时只留文字。 */
  @Builder
  progressBlock(item: CardBook, verbose: boolean) {
    Column() {
      if (item.percent >= 0) {
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(3)
            .borderRadius(2)
            .backgroundColor(this.trackColor())
          Row()
            .width(`${Math.max(item.percent, 2)}%`)
            .height(3)
            .borderRadius(2)
            .backgroundColor(this.accentColor)
        }
        .width('100%')
        .height(3)
      }
      Text(this.progressLabel(item, verbose))
        .fontSize(10)
        .fontColor(this.secondaryTextColor())
        .maxLines(1)
        .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 6 })
  }

  @Builder
  cover(item: CardBook, radius: number) {
    Stack() {
      Column() {
        Text(item.name ? item.name.substring(0, 1) : '书')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.accentColor)

      if (item.cover) {
        Image(item.cover)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      }
    }
    .height('100%')
    .aspectRatio(COVER_RATIO)
    .borderRadius(radius)
    .clip(true)
  }

  @Builder
  refreshButton() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph($r('sys.symbol.arrow_clockwise'))
        .fontSize(13)
        .fontWeight(FontWeight.Regular)
        .fontColor([this.secondaryTextColor()])
    }
    .width(22)
    .height(22)
    .backgroundColor(Color.Transparent)
    .accessibilityText('刷新最近阅读')
    .onClick(() => {
      postCardAction(this, {
        action: 'message',
        params: {
          action: 'refresh',
          nonce: Date.now()
        }
      });
    })
  }

  @Builder
  emptyState() {
    Column() {
      Text(this.emptyTitle || '暂无最近阅读')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor())
        .maxLines(1)
      Text(this.emptySubtitle || '打开书架阅读后会显示在这里')
        .fontSize(11)
        .fontColor(this.secondaryTextColor())
        .margin({ top: 5 })
        .maxLines(2)
        .textAlign(TextAlign.Center)
      Text('打开书架')
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.accentColor)
        .backgroundColor(this.accentBackgroundColor)
        .borderRadius(12)
        .padding({ left: 12, right: 12, top: 4, bottom: 4 })
        .margin({ top: 10 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      postCardAction(this, new CardOpenAppAction());
    })
  }

  private openBook(bookUrl: string): void {
    if (bookUrl) {
      postCardAction(this, new CardRouteAction(bookUrl));
    }
  }

  private progressLabel(item: CardBook, verbose: boolean): string {
    if (!item.progress) {
      return item.percent > 0 ? `已读 ${item.percent}%` : item.chapter;
    }
    if (!verbose) {
      return `${item.progress} · ${item.percent}%`;
    }
    const parts = item.progress.split('/');
    return `${parts[0]} / ${parts[1]} 章 · ${item.percent}%`;
  }

  private book(index: number): CardBook {
    const item = new CardBook();
    if (index === 0) {
      item.name = this.book0Name;
      item.chapter = this.book0Chapter;
      item.brief = this.book0Brief;
      item.progress = this.book0Progress;
      item.percent = this.book0Percent;
      item.time = this.book0Time;
      item.url = this.book0Url;
      item.cover = this.book0Cover;
    } else if (index === 1) {
      item.name = this.book1Name;
      item.chapter = this.book1Chapter;
      item.brief = this.book1Brief;
      item.progress = this.book1Progress;
      item.percent = this.book1Percent;
      item.time = this.book1Time;
      item.url = this.book1Url;
      item.cover = this.book1Cover;
    } else if (index === 2) {
      item.name = this.book2Name;
      item.chapter = this.book2Chapter;
      item.brief = this.book2Brief;
      item.progress = this.book2Progress;
      item.percent = this.book2Percent;
      item.time = this.book2Time;
      item.url = this.book2Url;
      item.cover = this.book2Cover;
    } else if (index === 3) {
      item.name = this.book3Name;
      item.chapter = this.book3Chapter;
      item.brief = this.book3Brief;
      item.progress = this.book3Progress;
      item.percent = this.book3Percent;
      item.time = this.book3Time;
      item.url = this.book3Url;
      item.cover = this.book3Cover;
    } else {
      item.name = this.book4Name;
      item.chapter = this.book4Chapter;
      item.brief = this.book4Brief;
      item.progress = this.book4Progress;
      item.percent = this.book4Percent;
      item.time = this.book4Time;
      item.url = this.book4Url;
      item.cover = this.book4Cover;
    }
    item.name = item.name || '未命名书籍';
    return item;
  }

  private defaultBackgroundColor(): string {
    return this.darkMode ? '#191B1F' : '#F7F8FA';
  }

  private primaryTextColor(): string {
    return this.darkMode ? '#F2F3F5' : '#1F1F1F';
  }

  private secondaryTextColor(): string {
    return this.darkMode ? '#8A8F98' : '#69717A';
  }

  private trackColor(): string {
    return this.darkMode ? '#33373E' : '#E2E5EA';
  }

  private dividerColor(): string {
    return this.darkMode ? '#2A2E34' : '#E6E8EC';
  }
}
