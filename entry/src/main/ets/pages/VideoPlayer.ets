import { router, window } from '@kit.ArkUI';
import { Book, BookChapter, BookSource } from '@legado/sourceengine';
import { AppDatabase } from '../model/data/AppDatabase';
import { ReadBookEngine } from '../core/book/ReadBookEngine';
import { WebBookService } from '../core/book/WebBookService';
import { HdsFeedback } from '../utils/HdsFeedback';
import { ReaderTtsFloatingSession } from '../utils/ReaderTtsFloatingSession';
import { syncSystemBars } from '../utils/SystemBars';
import { AppFontSize } from '../theme/AppFontSize';
import { AppSpacing } from '../theme/AppSpacing';
import { ThemeRuntime } from '../theme/ThemeRuntime';

interface VideoPlayerParams {
  bookUrl?: string;
  chapterIndex?: string;
}

/** 选集列表的数据源：集数可能上千，用懒加载避免一次创建全部条目。 */
class EpisodeDataSource implements IDataSource {
  private titles: string[] = [];
  private listeners: DataChangeListener[] = [];

  replace(titles: string[]): void {
    this.titles = titles;
    for (const listener of this.listeners) listener.onDataReloaded();
  }

  totalCount(): number {
    return this.titles.length;
  }

  getData(index: number): string {
    return this.titles[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) this.listeners.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) this.listeners.splice(index, 1);
  }
}

// Video 组件的 currentProgressRate 只接受 0.75、1、1.25、1.75、2 这几档，别的值不生效。
const SPEEDS: number[] = [1, 1.25, 1.75, 2, 0.75];
const CONTROLS_HIDE_DELAY_MS: number = 4000;

// 操作栏按钮的统一外观。用 @Extend 而不是带参数的 @Builder：按值传参的 @Builder 不会随状态刷新，
// 「连播 开/关」「播放/暂停」、倍速这些会变的文字就停在创建时的样子。
@Extend(Text)
function playerRoundButton() {
  .fontSize(AppFontSize.BODY)
  .fontColor('#FFFFFF')
  .height(36)
  .padding({ left: AppSpacing.LG, right: AppSpacing.LG })
  .borderRadius(18)
  .backgroundColor('#33FFFFFF')
  .textAlign(TextAlign.Center)
}

/**
 * 视频类书籍（短剧等）的播放页：全屏播放，页内切换集数。
 * 播放地址由书源的 content.video 给出，每次切集都重新取，避免带时效的地址过期。
 */
@Entry
@Component
struct VideoPlayerPage {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @State bookName: string = '';
  @State episodeTitle: string = '';
  @State episodeIndex: number = 0;
  @State episodeCount: number = 0;
  @State videoUrl: string = '';
  @State statusText: string = '正在加载...';
  @State isPlaying: boolean = false;
  @State positionSec: number = 0;
  @State durationSec: number = 0;
  @State speed: number = 1;
  @State showControls: boolean = true;
  @State showEpisodes: boolean = false;
  @State autoNext: boolean = true;
  @State landscape: boolean = false;
  @State seeking: boolean = false;
  private controller: VideoController = new VideoController();
  private episodeScroller: Scroller = new Scroller();
  private episodeData: EpisodeDataSource = new EpisodeDataSource();
  private book: Book | null = null;
  private source: BookSource | null = null;
  private chapters: BookChapter[] = [];
  private loadSerial: number = 0;
  private hideTimerId: number = -1;
  private resumeSec: number = 0;
  private retried: boolean = false;
  private lastSavedSec: number = -1;

  aboutToAppear(): void {
    const params = router.getParams() as VideoPlayerParams;
    const bookUrl = params && params.bookUrl ? params.bookUrl : '';
    const requestedIndex = params && params.chapterIndex !== undefined && params.chapterIndex !== '' ?
      Number(params.chapterIndex) : -1;
    this.enterImmersive();
    this.loadBook(bookUrl, requestedIndex);
  }

  aboutToDisappear(): void {
    this.loadSerial++;
    this.clearHideTimer();
    this.saveProgress(true);
    this.leaveImmersive();
  }

  onPageHide(): void {
    this.controller.pause();
    this.saveProgress(true);
  }

  onBackPress(): boolean {
    if (this.showEpisodes) {
      this.showEpisodes = false;
      return true;
    }
    if (this.landscape) {
      this.setLandscape(false);
      return true;
    }
    return false;
  }

  private enterImmersive(): void {
    window.getLastWindow(getContext(this)).then((mainWindow: window.Window): void => {
      mainWindow.setWindowLayoutFullScreen(true);
      mainWindow.setWindowSystemBarEnable([]);
      mainWindow.setWindowKeepScreenOn(true);
    }).catch((error: Error): void => {
      console.warn('[VideoPlayer] enter immersive failed:', error.message);
    });
  }

  private leaveImmersive(): void {
    const dark = this.appDarkMode;
    window.getLastWindow(getContext(this)).then((mainWindow: window.Window): void => {
      mainWindow.setWindowKeepScreenOn(false);
      mainWindow.setPreferredOrientation(window.Orientation.UNSPECIFIED);
      syncSystemBars(getContext(this), dark, ThemeRuntime.pageColor(dark));
    }).catch((error: Error): void => {
      console.warn('[VideoPlayer] leave immersive failed:', error.message);
    });
  }

  private setLandscape(enabled: boolean): void {
    this.landscape = enabled;
    window.getLastWindow(getContext(this)).then((mainWindow: window.Window): void => {
      mainWindow.setPreferredOrientation(enabled ? window.Orientation.AUTO_ROTATION_LANDSCAPE :
        window.Orientation.UNSPECIFIED);
    }).catch((error: Error): void => {
      console.warn('[VideoPlayer] rotate failed:', error.message);
    });
    this.scheduleHideControls();
  }

  private async loadBook(bookUrl: string, requestedIndex: number): Promise<void> {
    const serial = ++this.loadSerial;
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      const stored = await db.getBook(bookUrl);
      if (!stored) {
        this.statusText = '没有找到这部剧，请重新从详情页打开';
        return;
      }
      this.bookName = stored.name;
      this.source = stored.origin ? await db.getBookSource(stored.origin) : null;
      if (!this.source) {
        this.statusText = '对应的书源已被删除';
        return;
      }
      // 选集沿用阅读引擎的目录加载与缓存；首次打开时由它去取并保存。
      const engine = ReadBookEngine.get();
      await engine.openBook(stored);
      if (serial !== this.loadSerial) return;
      this.book = engine.book && engine.book.bookUrl === stored.bookUrl ? engine.book : stored;
      this.chapters = engine.chapters.slice();
      this.episodeCount = this.chapters.length;
      this.episodeData.replace(this.chapters.map((chapter: BookChapter): string => chapter.title || ''));
      if (this.chapters.length === 0) {
        this.statusText = AppStorage.get<string>('bookSourceStageLastError') || '没有取到选集';
        return;
      }
      const sameEpisode = requestedIndex < 0 || requestedIndex === this.book.durChapterIndex;
      const index = requestedIndex >= 0 ? requestedIndex : this.book.durChapterIndex;
      // durChapterPos 对视频类书籍记的是播放到的秒数。
      await this.playEpisode(index, sameEpisode ? Math.max(0, this.book.durChapterPos) : 0);
    } catch (e) {
      if (serial !== this.loadSerial) return;
      console.warn('[VideoPlayer] load failed:', (e as Error).message);
      this.statusText = `加载失败：${(e as Error).message || '未知错误'}`;
    }
  }

  private async playEpisode(index: number, resumeSec: number = 0, isRetry: boolean = false): Promise<void> {
    const book = this.book;
    const source = this.source;
    if (!book || !source || this.chapters.length === 0) return;
    const target = Math.max(0, Math.min(index, this.chapters.length - 1));
    const chapter = this.chapters[target];
    const serial = ++this.loadSerial;
    this.retried = isRetry;
    this.episodeIndex = target;
    this.episodeTitle = chapter.title;
    this.positionSec = 0;
    this.durationSec = 0;
    this.isPlaying = false;
    this.videoUrl = '';
    this.resumeSec = resumeSec;
    this.statusText = '正在获取播放地址...';
    let url = '';
    try {
      url = (await new WebBookService().getContent(source, book, chapter)).trim();
    } catch (e) {
      console.warn('[VideoPlayer] resolve failed:', (e as Error).message);
    }
    if (serial !== this.loadSerial) return;
    if (!/^https?:\/\//i.test(url)) {
      this.statusText = AppStorage.get<string>('bookSourceStageLastError') || '没有取到播放地址';
      this.showControls = true;
      return;
    }
    this.statusText = '正在缓冲...';
    this.videoUrl = url;
    book.durChapterIndex = target;
    book.durChapterTitle = chapter.title;
    book.durChapterPos = Math.floor(resumeSec);
    this.lastSavedSec = -1;
    this.saveProgress(true);
    this.scheduleHideControls();
  }

  private saveProgress(force: boolean = false): void {
    const book = this.book;
    if (!book) return;
    const second = Math.floor(this.positionSec);
    // 播放中每 10 秒落一次库，切集、离开页面时立即保存。
    if (!force && Math.abs(second - this.lastSavedSec) < 10) return;
    this.lastSavedSec = second;
    if (this.videoUrl) book.durChapterPos = second;
    book.durChapterTime = Date.now();
    AppDatabase.getInstance().updateBook(book, false).catch((error: Error): void => {
      console.warn('[VideoPlayer] save progress failed:', error.message);
    });
  }

  private onVideoPrepared(duration: number): void {
    this.durationSec = Math.max(0, duration);
    this.statusText = '';
    if (this.resumeSec > 1 && (this.durationSec <= 0 || this.resumeSec < this.durationSec - 3)) {
      this.controller.setCurrentTime(this.resumeSec, SeekMode.Accurate);
    }
    this.resumeSec = 0;
    this.controller.start();
  }

  private onVideoFinished(): void {
    this.isPlaying = false;
    if (this.autoNext && this.episodeIndex < this.chapters.length - 1) {
      this.playEpisode(this.episodeIndex + 1);
      return;
    }
    this.showControls = true;
    this.statusText = this.episodeIndex >= this.chapters.length - 1 ? '已播完最后一集' : '';
  }

  private onVideoError(): void {
    // 播放地址有时效，失败时先重新取一次地址，再失败才提示。
    if (!this.retried) {
      this.playEpisode(this.episodeIndex, this.positionSec, true);
      return;
    }
    this.isPlaying = false;
    this.statusText = '播放失败，可点击重试';
    this.showControls = true;
  }

  private togglePlay(): void {
    if (!this.videoUrl) {
      this.playEpisode(this.episodeIndex, this.positionSec);
      return;
    }
    if (this.isPlaying) this.controller.pause();
    else this.controller.start();
    this.scheduleHideControls();
  }

  private toggleControls(): void {
    this.showControls = !this.showControls;
    if (this.showControls) this.scheduleHideControls();
    else this.clearHideTimer();
  }

  private clearHideTimer(): void {
    if (this.hideTimerId >= 0) {
      clearTimeout(this.hideTimerId);
      this.hideTimerId = -1;
    }
  }

  private scheduleHideControls(): void {
    this.clearHideTimer();
    this.hideTimerId = setTimeout((): void => {
      this.hideTimerId = -1;
      if (this.isPlaying && !this.showEpisodes && !this.seeking) this.showControls = false;
    }, CONTROLS_HIDE_DELAY_MS);
  }

  private nextSpeed(): void {
    const index = SPEEDS.indexOf(this.speed);
    this.speed = SPEEDS[(index + 1) % SPEEDS.length];
    this.scheduleHideControls();
  }

  private openEpisodes(): void {
    this.showEpisodes = true;
    this.clearHideTimer();
    setTimeout((): void => {
      this.episodeScroller.scrollToIndex(Math.max(0, this.episodeIndex - 8));
    }, 60);
  }

  private formatTime(seconds: number): string {
    const total = Math.max(0, Math.floor(seconds));
    const minute = Math.floor(total / 60);
    const second = total % 60;
    return `${minute < 10 ? '0' : ''}${minute}:${second < 10 ? '0' : ''}${second}`;
  }

  @Builder
  topBar() {
    Row({ space: AppSpacing.MD }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(24)
        .fontColor(['#FFFFFF'])
        .width(40)
        .height(40)
        .onClick(() => {
          if (this.landscape) this.setLandscape(false);
          else router.back();
        })
      Column() {
        Text(this.bookName)
          .fontSize(AppFontSize.BODY_LARGE)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${this.episodeTitle}${this.episodeCount > 0 ? ` · 共 ${this.episodeCount} 集` : ''}`)
          .fontSize(AppFontSize.CAPTION)
          .fontColor('#CCFFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(this.autoNext ? '连播 开' : '连播 关')
        .playerRoundButton()
        .onClick(() => {
          this.autoNext = !this.autoNext;
          this.scheduleHideControls();
        })
      Text('选集')
        .playerRoundButton()
        .onClick(() => this.openEpisodes())
    }
    .width('100%')
    .padding({ left: AppSpacing.LG, right: AppSpacing.LG, top: this.statusBarHeight + AppSpacing.MD,
      bottom: AppSpacing.XL })
    .linearGradient({ direction: GradientDirection.Bottom, colors: [['#B3000000', 0], ['#00000000', 1]] })
    .position({ left: 0, top: 0 })
  }

  @Builder
  bottomBar() {
    Column({ space: AppSpacing.SM }) {
      Row({ space: AppSpacing.MD }) {
        Text(this.formatTime(this.positionSec))
          .fontSize(AppFontSize.CAPTION)
          .fontColor('#FFFFFF')
        Slider({ value: this.positionSec, min: 0, max: Math.max(1, this.durationSec), step: 1 })
          .layoutWeight(1)
          .trackColor('#55FFFFFF')
          .selectedColor('#FFFFFF')
          .blockColor('#FFFFFF')
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
              this.seeking = true;
              this.positionSec = value;
              return;
            }
            this.seeking = false;
            this.positionSec = value;
            this.controller.setCurrentTime(value, SeekMode.Accurate);
            this.scheduleHideControls();
          })
        Text(this.formatTime(this.durationSec))
          .fontSize(AppFontSize.CAPTION)
          .fontColor('#FFFFFF')
      }
      .width('100%')

      Row({ space: AppSpacing.MD }) {
        Text('上一集')
          .playerRoundButton()
          .onClick(() => {
            if (this.episodeIndex > 0) this.playEpisode(this.episodeIndex - 1);
            else HdsFeedback.showToast('已经是第一集');
          })
        Text(this.isPlaying ? '暂停' : '播放')
          .playerRoundButton()
          .onClick(() => this.togglePlay())
        Text('下一集')
          .playerRoundButton()
          .onClick(() => {
            if (this.episodeIndex < this.chapters.length - 1) this.playEpisode(this.episodeIndex + 1);
            else HdsFeedback.showToast('已经是最后一集');
          })
        Blank()
        Text(`${this.speed}x`)
          .playerRoundButton()
          .onClick(() => this.nextSpeed())
        Text(this.landscape ? '竖屏' : '横屏')
          .playerRoundButton()
          .onClick(() => this.setLandscape(!this.landscape))
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: AppSpacing.LG, right: AppSpacing.LG, top: AppSpacing.XL,
      bottom: this.navBarHeight + AppSpacing.LG })
    .linearGradient({ direction: GradientDirection.Top, colors: [['#B3000000', 0], ['#00000000', 1]] })
    .position({ left: 0, bottom: 0 })
  }

  @Builder
  episodePanel() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => {
          this.showEpisodes = false;
          this.scheduleHideControls();
        })
      Column() {
        Text(`选集 · 共 ${this.episodeCount} 集`)
          .fontSize(AppFontSize.BODY_LARGE)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .width('100%')
          .padding({ left: AppSpacing.XL, right: AppSpacing.XL, top: AppSpacing.XL, bottom: AppSpacing.LG })
        List({ space: AppSpacing.MD, scroller: this.episodeScroller }) {
          LazyForEach(this.episodeData, (title: string, index: number) => {
            ListItem() {
              Text(title || `第${index + 1}集`)
                .fontSize(AppFontSize.BODY)
                .fontColor('#FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .textAlign(TextAlign.Center)
                .width('100%')
                .height(40)
                .borderRadius(10)
                .backgroundColor(index === this.episodeIndex ? '#7A5AF8' : '#26FFFFFF')
                .onClick(() => {
                  this.showEpisodes = false;
                  if (index !== this.episodeIndex) this.playEpisode(index);
                  else this.scheduleHideControls();
                })
            }
          }, (title: string, index: number): string => `${index}_${title}_${index === this.episodeIndex ? 'on' : 'off'}`)
        }
        .lanes(this.landscape ? 6 : 4, AppSpacing.MD)
        .width('100%')
        .layoutWeight(1)
        .padding({ left: AppSpacing.XL, right: AppSpacing.XL })
        .scrollBar(BarState.Auto)
      }
      .width('100%')
      .height('55%')
      .padding({ bottom: this.navBarHeight + AppSpacing.LG })
      .backgroundColor('#F01C1C1E')
      .borderRadius({ topLeft: 18, topRight: 18 })
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      if (this.videoUrl) {
        Video({ src: this.videoUrl, controller: this.controller, currentProgressRate: this.speed })
          .width('100%')
          .height('100%')
          .controls(false)
          .autoPlay(true)
          .loop(false)
          .objectFit(ImageFit.Contain)
          .backgroundColor(Color.Black)
          .onPrepared((event: PreparedInfo) => {
            this.onVideoPrepared(event.duration);
          })
          .onStart(() => {
            // 同一应用内的音频流系统不会互相打断，朗读/听书要自己停下，免得和视频声音叠在一起。
            ReaderTtsFloatingSession.pause().catch((error: Error) => {
              console.warn('[VideoPlayer] pause tts failed:', error.message);
            });
            this.isPlaying = true;
            this.statusText = '';
            this.scheduleHideControls();
          })
          .onPause(() => {
            this.isPlaying = false;
            this.showControls = true;
          })
          .onUpdate((event: PlaybackInfo) => {
            if (!this.seeking) this.positionSec = event.time;
            this.saveProgress();
          })
          .onFinish(() => {
            this.onVideoFinished();
          })
          .onError(() => {
            this.onVideoError();
          })
      }

      // 点画面显示或隐藏操作栏，双击暂停或继续。
      Column()
        .width('100%')
        .height('100%')
        .gesture(GestureGroup(GestureMode.Exclusive,
          TapGesture({ count: 2 }).onAction(() => this.togglePlay()),
          TapGesture({ count: 1 }).onAction(() => this.toggleControls())))

      if (this.statusText) {
        Text(this.statusText)
          .fontSize(AppFontSize.BODY)
          .fontColor('#FFFFFF')
          .padding({ left: AppSpacing.XL, right: AppSpacing.XL, top: AppSpacing.MD, bottom: AppSpacing.MD })
          .borderRadius(12)
          .backgroundColor('#80000000')
          .onClick(() => {
            if (!this.videoUrl || !this.isPlaying) this.playEpisode(this.episodeIndex, this.positionSec);
          })
      }

      // 两条操作栏各自贴边放在点按层之上：栏内按钮能收到点击，栏外的画面区域仍由点按层处理。
      // 不能给操作栏设 HitTestMode.Block，它会连栏内的按钮一起挡掉。
      if (this.showControls) {
        this.topBar()
        this.bottomBar()
      }

      if (this.showEpisodes) {
        this.episodePanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
