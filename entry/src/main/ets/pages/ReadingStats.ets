import { router } from '@kit.ArkUI';
import { ImmersiveBackButton } from '../components/ImmersiveBackButton';
import { ThemeRuntime } from '../theme/ThemeRuntime';
import { syncSystemBars } from '../utils/SystemBars';
import { appDb } from '../model/data/AppDatabase';
import { ReadStatsTracker, readStatsTracker } from '../core/stats/ReadStatsTracker';

const STATS_MODES: string[] = ['day', 'week', 'month'];
const STATS_MODE_LABELS: string[] = ['日', '周', '月'];
const WEEKDAY_LABELS: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
const DAY_MS: number = 86400000;

class StatsRange {
  startTs: number = 0;
  endTs: number = 0;
}

class StatBookItem {
  bookUrl: string = '';
  name: string = '';
  author: string = '';
  coverUrl: string = '';
  durationMs: number = 0;
  percent: number = 0;
}

@Entry
@Component
struct ReadingStatsPage {
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State mode: string = 'week';
  @State anchorTs: number = Date.now();
  @State loading: boolean = true;
  @State totalMs: number = 0;
  @State activeDays: number = 0;
  @State items: StatBookItem[] = [];

  aboutToAppear(): void {
    // 用户可能正听着书进本页，先结算一次未落库的时长再查询。
    readStatsTracker.flush();
    this.loadStats();
    this.syncBars();
  }

  onPageShow(): void {
    this.syncBars();
  }

  async loadStats(): Promise<void> {
    this.loading = true;
    try {
      await appDb.init(getContext(this));
      const range = this.currentRange();
      const startKey = ReadStatsTracker.dayKeyOf(range.startTs);
      const endKey = ReadStatsTracker.dayKeyOf(range.endTs);
      const rows = await appDb.getReadStatsByDayRange(startKey, endKey);

      const durationByBook = new Map<string, number>();
      const activeDayKeys = new Set<string>();
      let total = 0;
      rows.forEach((row) => {
        if (row.durationMs <= 0) return;
        durationByBook.set(row.bookUrl, (durationByBook.get(row.bookUrl) || 0) + row.durationMs);
        activeDayKeys.add(row.dayKey);
        total += row.durationMs;
      });

      const items: StatBookItem[] = [];
      durationByBook.forEach((duration: number, bookUrl: string) => {
        const item = new StatBookItem();
        item.bookUrl = bookUrl;
        item.durationMs = duration;
        item.percent = total > 0 ? Math.max(1, Math.round(duration * 100 / total)) : 0;
        items.push(item);
      });
      items.sort((a: StatBookItem, b: StatBookItem): number => b.durationMs - a.durationMs);

      const bookUrls: string[] = [];
      durationByBook.forEach((_duration: number, bookUrl: string) => {
        bookUrls.push(bookUrl);
      });
      if (bookUrls.length > 0) {
        const metaMap = await appDb.getReadStatsBookMeta(bookUrls);
        items.forEach((item: StatBookItem) => {
          const meta = metaMap.get(item.bookUrl);
          if (meta) {
            item.name = meta.name || '未命名书籍';
            item.author = meta.author || '';
            item.coverUrl = meta.coverUrl || '';
          } else {
            item.name = '已删除书籍';
            item.author = '';
            item.coverUrl = '';
          }
        });
      }

      this.totalMs = total;
      this.activeDays = activeDayKeys.size;
      this.items = items;
    } catch (e) {
      console.warn('读取阅读统计失败:', e);
      this.totalMs = 0;
      this.activeDays = 0;
      this.items = [];
    } finally {
      this.loading = false;
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Scroll() {
        Column() {
          Row()
            .height(56 + this.statusBarHeight)

          this.summaryCard()

          this.sectionTitle('书籍排行')
          if (this.loading) {
            this.loadingCard()
          } else if (this.items.length === 0) {
            this.emptyCard()
          } else {
            Column({ space: 14 }) {
              ForEach(this.items, (item: StatBookItem) => {
                this.bookRow(item)
              }, (item: StatBookItem) => item.bookUrl)
            }
            .width('calc(100% - 24vp)')
            .padding(16)
            .margin({ left: 12, right: 12 })
            .borderRadius(16)
            .backgroundColor(this.cardColor())
          }

          Row()
            .width('100%')
            .height(32 + this.navBarHeight)
        }
        .width('100%')
      }
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .width('100%')
      .height('100%')
      .align(Alignment.TopStart)

      this.titleBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  summaryCard() {
    Column({ space: 14 }) {
      Row() {
        Row({ space: 4 }) {
          ForEach(STATS_MODES, (value: string, index: number) => {
            Text(STATS_MODE_LABELS[index])
              .fontSize(13)
              .fontWeight(this.mode === value ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.mode === value ? Color.White : this.subTextColor())
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .borderRadius(14)
              .backgroundColor(this.mode === value ? this.accentColor() : Color.Transparent)
              .onClick(() => {
                if (this.mode === value) return;
                this.mode = value;
                this.loadStats();
              })
          }, (value: string) => value)
        }
        .padding(3)
        .borderRadius(17)
        .backgroundColor(this.softColor())
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)

      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(18)
          .fontColor([this.subTextColor()])
          .padding(8)
          .onClick(() => {
            this.shiftPeriod(-1);
          })

        Text(this.periodTitle())
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.canGoForward()) {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(18)
            .fontColor([this.subTextColor()])
            .padding(8)
            .onClick(() => {
              this.shiftPeriod(1);
            })
        } else {
          Row()
            .width(34)
            .height(34)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Column({ space: 6 }) {
        Text(this.formatDuration(this.totalMs))
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
        Text(this.summarySubtitle())
          .fontSize(13)
          .fontColor(this.subTextColor())
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('calc(100% - 24vp)')
    .padding(16)
    .margin({ left: 12, right: 12, top: 12 })
    .borderRadius(16)
    .backgroundColor(this.cardColor())
  }

  @Builder
  bookRow(item: StatBookItem) {
    Row({ space: 12 }) {
      Stack() {
        Column() {
          Text(item.name ? item.name.substring(0, 1) : '书')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.accentColor())

        if (item.coverUrl) {
          Image(item.coverUrl)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
        }
      }
      .width(40)
      .height(56)
      .borderRadius(6)
      .clip(true)

      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text(item.name)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.formatDuration(item.durationMs))
            .fontSize(13)
            .fontColor(this.primaryTextColor())
        }
        .width('100%')

        Row() {
          Text(`${item.percent}%`)
            .fontSize(11)
            .fontColor(this.subTextColor())
            .layoutWeight(1)
          if (item.author) {
            Text(item.author)
              .fontSize(11)
              .fontColor(this.subTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')

        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(4)
            .borderRadius(2)
            .backgroundColor(this.softColor())
          Row()
            .width(`${item.percent}%`)
            .height(4)
            .borderRadius(2)
            .backgroundColor(this.accentColor())
        }
        .width('100%')
        .clip(true)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  loadingCard() {
    Row({ space: 10 }) {
      LoadingProgress()
        .width(22)
        .height(22)
        .color(this.accentColor())
      Text('正在统计阅读时长')
        .fontSize(14)
        .fontColor(this.subTextColor())
    }
    .width('calc(100% - 24vp)')
    .height(88)
    .padding({ left: 16, right: 16 })
    .margin({ left: 12, right: 12 })
    .borderRadius(16)
    .backgroundColor(this.cardColor())
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  emptyCard() {
    Column({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.timer'))
        .fontSize(28)
        .fontColor([this.subTextColor()])
      Text('该时段暂无阅读记录')
        .fontSize(14)
        .fontColor(this.subTextColor())
    }
    .width('calc(100% - 24vp)')
    .constraintSize({ minHeight: 120 })
    .padding({ top: 20, bottom: 20 })
    .margin({ left: 12, right: 12 })
    .borderRadius(16)
    .backgroundColor(this.cardColor())
    .justifyContent(FlexAlign.Center)
  }

  private shiftPeriod(direction: number): void {
    const d = new Date(this.anchorTs);
    if (this.mode === 'day') {
      this.anchorTs = new Date(d.getFullYear(), d.getMonth(), d.getDate() + direction).getTime();
    } else if (this.mode === 'week') {
      this.anchorTs = new Date(d.getFullYear(), d.getMonth(), d.getDate() + direction * 7).getTime();
    } else {
      this.anchorTs = new Date(d.getFullYear(), d.getMonth() + direction, 1).getTime();
    }
    this.loadStats();
  }

  private currentRange(): StatsRange {
    const range = new StatsRange();
    const d = new Date(this.anchorTs);
    if (this.mode === 'day') {
      range.startTs = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
      range.endTs = range.startTs;
    } else if (this.mode === 'week') {
      const mondayOffset = (d.getDay() + 6) % 7;
      range.startTs = new Date(d.getFullYear(), d.getMonth(), d.getDate() - mondayOffset).getTime();
      range.endTs = range.startTs + 6 * DAY_MS;
    } else {
      range.startTs = new Date(d.getFullYear(), d.getMonth(), 1).getTime();
      range.endTs = new Date(d.getFullYear(), d.getMonth() + 1, 0).getTime();
    }
    return range;
  }

  private canGoForward(): boolean {
    const d = new Date(this.anchorTs);
    let nextStart = 0;
    if (this.mode === 'day') {
      nextStart = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1).getTime();
    } else if (this.mode === 'week') {
      const mondayOffset = (d.getDay() + 6) % 7;
      nextStart = new Date(d.getFullYear(), d.getMonth(), d.getDate() - mondayOffset + 7).getTime();
    } else {
      nextStart = new Date(d.getFullYear(), d.getMonth() + 1, 1).getTime();
    }
    const todayStart = new Date().setHours(0, 0, 0, 0);
    return nextStart <= todayStart;
  }

  private periodTitle(): string {
    const d = new Date(this.anchorTs);
    if (this.mode === 'day') {
      const isToday = ReadStatsTracker.dayKeyOf(this.anchorTs) === ReadStatsTracker.dayKeyOf(Date.now());
      return `${isToday ? '今天 · ' : ''}${d.getMonth() + 1}月${d.getDate()}日 ${WEEKDAY_LABELS[d.getDay()]}`;
    }
    if (this.mode === 'week') {
      const range = this.currentRange();
      const s = new Date(range.startTs);
      const e = new Date(range.endTs);
      return `${s.getMonth() + 1}月${s.getDate()}日 - ${e.getMonth() + 1}月${e.getDate()}日`;
    }
    return `${d.getFullYear()}年${d.getMonth() + 1}月`;
  }

  private summarySubtitle(): string {
    if (this.mode === 'day') {
      if (this.totalMs > 0) {
        return `共阅读 ${this.items.length} 本书`;
      }
      const isToday = ReadStatsTracker.dayKeyOf(this.anchorTs) === ReadStatsTracker.dayKeyOf(Date.now());
      return isToday ? '今天还没有开始阅读' : '当日没有阅读记录';
    }
    const days = this.elapsedDays();
    const avg = this.formatDuration(Math.round(this.totalMs / days));
    return `日均 ${avg} · 有阅读 ${this.activeDays} 天`;
  }

  private elapsedDays(): number {
    const range = this.currentRange();
    const todayStart = new Date().setHours(0, 0, 0, 0);
    if (range.endTs <= todayStart) {
      return Math.round((range.endTs - range.startTs) / DAY_MS) + 1;
    }
    return Math.max(1, Math.round((todayStart - range.startTs) / DAY_MS) + 1);
  }

  private formatDuration(ms: number): string {
    const totalMinutes = Math.floor(ms / 60000);
    if (totalMinutes <= 0) {
      return '0分钟';
    }
    const hours = Math.floor(totalMinutes / 60);
    const minutes = totalMinutes % 60;
    if (hours <= 0) {
      return `${minutes}分钟`;
    }
    if (minutes === 0) {
      return `${hours}小时`;
    }
    return `${hours}小时${minutes}分钟`;
  }

  pageColor(): string {
    return ThemeRuntime.pageColor(this.appDarkMode);
  }

  cardColor(): string {
    return ThemeRuntime.cardColor(this.appDarkMode);
  }

  softColor(): string {
    return ThemeRuntime.inputColor(this.appDarkMode);
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
  sectionTitle(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor(this.subTextColor())
      .width('100%')
      .padding({ left: 16, right: 16, top: 20, bottom: 8 })
  }

  @Builder
  titleBar() {
    Row() {
      ImmersiveBackButton({ iconColor: this.primaryTextColor(), darkMode: this.appDarkMode,
        buttonSize: 40, containerWidth: 56, materialScale: 0.83, compactLayout: true,
        onBack: () => router.back() })
      Text('阅读统计')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryTextColor())
        .layoutWeight(1)
    }
    .width('100%')
    .height(56 + this.statusBarHeight)
    .padding({ top: this.statusBarHeight })
    .backgroundColor(ThemeRuntime.topBarColor(this.appDarkMode))
    .backdropBlur(ThemeRuntime.topBarBlur())
    .alignItems(VerticalAlign.Center)
  }
}
