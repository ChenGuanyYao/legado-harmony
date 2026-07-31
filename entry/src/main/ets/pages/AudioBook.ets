import { promptAction, router } from '@kit.ArkUI';
import { common, WantAgent, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { avSession } from '@kit.AVSessionKit';
import { Book, BookChapter, BookSource } from '../model/data/Book';
import { AppDatabase } from '../model/data/AppDatabase';
import { ReadBookEngine } from '../core/book/ReadBookEngine';
import { BookTypeSupport } from '../core/book/BookTypeSupport';
import { BookUrlResolver } from '../core/book/BookUrlResolver';
import { VerificationSupport } from '../core/http/VerificationSupport';
import { RemoteAudioPlayback, RemoteAudioPlaybackListener } from '../utils/RemoteAudioPlayback';
import { CoverUrlNormalizer } from '../utils/CoverUrlNormalizer';
import { ImmersiveBackButton } from '../components/ImmersiveBackButton';
import { syncSystemBars } from '../utils/SystemBars';
import { ThemeRuntime } from '../theme/ThemeRuntime';

class AudioBookPlaybackListener implements RemoteAudioPlaybackListener {
  private readonly stateCallback: (state: string) => void;
  private readonly positionCallback: (positionMs: number, durationMs: number) => void;
  private readonly completedCallback: () => void;
  private readonly errorCallback: (message: string) => void;

  constructor(stateCallback: (state: string) => void,
    positionCallback: (positionMs: number, durationMs: number) => void,
    completedCallback: () => void, errorCallback: (message: string) => void) {
    this.stateCallback = stateCallback;
    this.positionCallback = positionCallback;
    this.completedCallback = completedCallback;
    this.errorCallback = errorCallback;
  }

  onStateChanged(state: string): void { this.stateCallback(state); }
  onPositionChanged(positionMs: number, durationMs: number): void {
    this.positionCallback(positionMs, durationMs);
  }
  onPlaybackCompleted(): void { this.completedCallback(); }
  onPlaybackError(message: string): void { this.errorCallback(message); }
}

class AudioChapterDataSource implements IDataSource {
  private chapters: BookChapter[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number { return this.chapters.length; }
  getData(index: number): BookChapter { return this.chapters[index]; }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) this.listeners.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) this.listeners.splice(index, 1);
  }

  replace(chapters: BookChapter[]): void {
    this.chapters = [...chapters];
    for (const listener of this.listeners) listener.onDataReloaded();
  }
}

@Entry
@Component
struct AudioBookPage {
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;
  @StorageLink('appLightAccentColor') appLightAccentColor: string = '#007DFF';
  @StorageLink('appDarkAccentColor') appDarkAccentColor: string = '#4E9BFF';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State book: Book | null = null;
  @State chapters: BookChapter[] = [];
  @State chapterIndex: number = 0;
  @State positionMs: number = 0;
  @State durationMs: number = 0;
  @State playbackState: string = 'idle';
  @State speed: number = 1;
  @State statusText: string = '正在加载听书信息...';
  @State showChapterList: boolean = false;
  @State showVoiceDialog: boolean = false;
  @State voiceCodeInput: string = '';
  @State sleepMinutes: number = 0;
  @State sleepRemainingSeconds: number = 0;
  private bookUrl: string = '';
  private source: BookSource | null = null;
  private openedWithShelfAnimation: boolean = false;
  private openedFromShortcut: boolean = false;
  private shortcutReplacedPreviousPage: boolean = false;
  private playback: RemoteAudioPlayback = RemoteAudioPlayback.get();
  private playbackListener: RemoteAudioPlaybackListener = new AudioBookPlaybackListener(
    (state: string): void => this.onPlaybackStateChanged(state),
    (positionMs: number, durationMs: number): void => this.onPlaybackPositionChanged(positionMs, durationMs),
    (): void => this.onPlaybackCompleted(),
    (message: string): void => this.onPlaybackError(message));
  private progressSaveTimerId: number = -1;
  private sleepTimerId: number = -1;
  private playbackRetryCount: number = 0;
  private chapterDataSource: AudioChapterDataSource = new AudioChapterDataSource();
  private loadingSerial: number = 0;
  private audioBackgroundRunning: boolean = false;
  private audioBackgroundStarting: boolean = false;
  private audioAvSession: avSession.AVSession | null = null;
  private audioAvSessionStarting: boolean = false;
  private lastAvSessionPositionUpdateAt: number = 0;

  aboutToAppear(): void {
    this.syncBars();
    const params = router.getParams() as Record<string, string>;
    this.bookUrl = params?.['bookUrl'] || '';
    this.openedWithShelfAnimation = params?.['shelfBookOpening'] === 'true';
    this.openedFromShortcut = params?.['shortcutEntry'] === 'true';
    this.shortcutReplacedPreviousPage = params?.['shortcutReplace'] === 'true';
    this.playback.attach(this.playbackListener);
    this.loadBook();
  }

  onPageShow(): void {
    this.syncBars();
    this.playback.attach(this.playbackListener);
    this.restoreSleepTimerUi();
  }

  onBackPress(): boolean {
    this.closePage();
    return true;
  }

  aboutToDisappear(): void {
    this.saveProgressNow();
    this.playback.detach(this.playbackListener);
    this.clearProgressSaveTimer();
    this.clearSleepTimer();
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Scroll() {
          Column() {
            this.coverSection()
            this.chapterSection()
            this.progressSection()
            this.playbackControls()
            this.speedSection()
            this.sleepSection()
            Text(this.statusText)
              .fontSize(13)
              .fontColor(this.subTextColor())
              .textAlign(TextAlign.Center)
              .width('100%')
              .padding({ left: 20, right: 20, top: 18, bottom: 28 + this.navBarHeight })
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 20 })
        }
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .padding({ top: 56 + this.statusBarHeight })

      Row() {
        ImmersiveBackButton({ iconColor: this.primaryTextColor(), darkMode: this.appDarkMode,
          buttonSize: 40, containerWidth: 56, materialScale: 0.83, compactLayout: true,
          onBack: () => this.closePage() })
        Text('听书')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
          .layoutWeight(1)
        Text('音色')
          .fontSize(15)
          .fontColor(this.accentColor())
          .width(56)
          .height(48)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.voiceCodeInput = this.book?.getVariable('custom') || '6001';
            this.showVoiceDialog = true;
          })
        Text('目录')
          .fontSize(15)
          .fontColor(this.accentColor())
          .width(64)
          .height(48)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.showChapterList = true;
          })
      }
      .width('100%')
      .height(56 + this.statusBarHeight)
      .padding({ top: this.statusBarHeight })
      .backgroundColor(ThemeRuntime.topBarColor(this.appDarkMode))
      .backdropBlur(ThemeRuntime.topBarBlur())
      .alignItems(VerticalAlign.Center)

      if (this.showChapterList) {
        this.chapterListOverlay()
      }
      if (this.showVoiceDialog) {
        this.voiceCodeDialog()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  voiceCodeDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')
        .onClick(() => {
          this.showVoiceDialog = false;
        })
      Column({ space: 14 }) {
        Text('听书音色代码')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
        Text('填写书源详情中列出的数字音色代码，例如 6001')
          .fontSize(13)
          .fontColor(this.subTextColor())
        TextInput({ text: this.voiceCodeInput, placeholder: '6001' })
          .type(InputType.Number)
          .height(44)
          .width('100%')
          .backgroundColor(this.inputColor())
          .fontColor(this.primaryTextColor())
          .onChange((value: string) => {
            this.voiceCodeInput = value;
          })
        Row({ space: 10 }) {
          Button('取消')
            .layoutWeight(1)
            .backgroundColor(this.inputColor())
            .fontColor(this.primaryTextColor())
            .onClick(() => {
              this.showVoiceDialog = false;
            })
          Button('保存并重新加载')
            .layoutWeight(1)
            .backgroundColor(this.accentColor())
            .fontColor('#FFFFFF')
            .onClick(() => this.saveVoiceCode())
        }
        .width('100%')
      }
      .width('86%')
      .padding(20)
      .borderRadius(16)
      .backgroundColor(this.cardColor())
    }
    .width('100%')
    .height('100%')
    .zIndex(30)
  }

  @Builder
  coverSection() {
    Column() {
      if (this.displayCover()) {
        Image(this.displayCover())
          .width(190)
          .height(250)
          .borderRadius(14)
          .objectFit(ImageFit.Cover)
      } else {
        Column() {
          Text('🎧')
            .fontSize(72)
        }
        .width(190)
        .height(250)
        .borderRadius(14)
        .backgroundColor(this.cardColor())
        .justifyContent(FlexAlign.Center)
      }
      Text(this.book?.name || '正在加载')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryTextColor())
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .margin({ top: 18 })
      Text(this.book?.author || this.book?.originName || '')
        .fontSize(14)
        .fontColor(this.subTextColor())
        .maxLines(1)
        .margin({ top: 7 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  chapterSection() {
    Column() {
      Text(this.currentChapter()?.title || '正在获取目录...')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor())
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
      Text(this.chapters.length > 0 ? `${this.chapterIndex + 1} / ${this.chapters.length}` : '- / -')
        .fontSize(12)
        .fontColor(this.subTextColor())
        .margin({ top: 6 })
    }
    .width('100%')
    .margin({ top: 24 })
  }

  @Builder
  progressSection() {
    Column() {
      Slider({ value: this.positionMs, min: 0, max: Math.max(1, this.durationMs), step: 1000 })
        .width('100%')
        .selectedColor(this.accentColor())
        .trackColor(this.inputColor())
        .onChange((value: number, mode: SliderChangeMode) => {
          this.positionMs = value;
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.playback.seek(value);
            this.scheduleProgressSave();
          }
        })
      Row() {
        Text(this.formatDuration(this.positionMs))
          .fontSize(12)
          .fontColor(this.subTextColor())
        Blank()
        Text(this.formatDuration(this.durationMs))
          .fontSize(12)
          .fontColor(this.subTextColor())
      }
      .width('100%')
    }
    .width('100%')
    .margin({ top: 18 })
  }

  @Builder
  playbackControls() {
    Row() {
      Button('上一章')
        .height(44)
        .fontSize(14)
        .enabled(this.chapterIndex > 0 && this.playbackState !== 'loading')
        .backgroundColor(this.inputColor())
        .fontColor(this.primaryTextColor())
        .onClick(() => this.changeChapter(-1))
      Button(this.isPlaying() ? '暂停' : (this.playbackState === 'loading' ? '加载中' : '播放'))
        .width(100)
        .height(52)
        .fontSize(17)
        .enabled(this.chapters.length > 0 && this.playbackState !== 'loading')
        .backgroundColor(this.accentColor())
        .fontColor('#FFFFFF')
        .onClick(() => this.togglePlayback())
      Button('下一章')
        .height(44)
        .fontSize(14)
        .enabled(this.chapterIndex < this.chapters.length - 1 && this.playbackState !== 'loading')
        .backgroundColor(this.inputColor())
        .fontColor(this.primaryTextColor())
        .onClick(() => this.changeChapter(1))
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceAround)
    .alignItems(VerticalAlign.Center)
    .margin({ top: 20 })
  }

  @Builder
  speedSection() {
    Column() {
      Text(`播放倍速 · ${this.speed.toFixed(2)}x`)
        .fontSize(14)
        .fontColor(this.secondaryTextColor())
        .width('100%')
      Row() {
        ForEach([0.75, 1, 1.25, 1.5, 2], (value: number) => {
          Text(`${value}x`)
            .fontSize(13)
            .fontColor(Math.abs(this.speed - value) < 0.01 ? '#FFFFFF' : this.primaryTextColor())
            .height(34)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .backgroundColor(Math.abs(this.speed - value) < 0.01 ? this.accentColor() : this.inputColor())
            .borderRadius(17)
            .margin({ right: value === 2 ? 0 : 6 })
            .onClick(() => this.changeSpeed(value))
        })
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.cardColor())
    .borderRadius(12)
    .margin({ top: 24 })
  }

  @Builder
  sleepSection() {
    Column() {
      Text(this.sleepRemainingSeconds > 0 ?
        `定时停止 · ${this.formatDuration(this.sleepRemainingSeconds * 1000)}` : '定时停止')
        .fontSize(14)
        .fontColor(this.secondaryTextColor())
        .width('100%')
      Row() {
        ForEach([0, 15, 30, 60], (minutes: number) => {
          Text(minutes === 0 ? '关闭' : `${minutes}分钟`)
            .fontSize(13)
            .fontColor(this.sleepMinutes === minutes ? '#FFFFFF' : this.primaryTextColor())
            .height(34)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.sleepMinutes === minutes ? this.accentColor() : this.inputColor())
            .borderRadius(17)
            .margin({ right: minutes === 60 ? 0 : 6 })
            .onClick(() => this.setSleepTimer(minutes))
        })
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.cardColor())
    .borderRadius(12)
    .margin({ top: 12 })
  }

  @Builder
  chapterListOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')
        .onClick(() => {
          this.showChapterList = false;
        })
      Column() {
        Row() {
          Text('章节目录')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.primaryTextColor())
            .layoutWeight(1)
          Text('关闭')
            .fontSize(14)
            .fontColor(this.accentColor())
            .onClick(() => {
              this.showChapterList = false;
            })
        }
        .width('100%')
        .height(52)
        .padding({ left: 18, right: 18 })
        .alignItems(VerticalAlign.Center)
        List() {
          LazyForEach(this.chapterDataSource, (chapter: BookChapter, index: number) => {
            ListItem() {
              Text(chapter.title)
                .fontSize(15)
                .fontColor(index === this.chapterIndex ? this.accentColor() : this.primaryTextColor())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .height(48)
                .padding({ left: 18, right: 18 })
                .onClick(() => this.selectChapter(index))
            }
          }, (chapter: BookChapter, index: number) => `${index}_${chapter.url}`)
        }
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('72%')
      .padding({ bottom: this.navBarHeight })
      .backgroundColor(this.pageColor())
      .borderRadius({ topLeft: 18, topRight: 18 })
    }
    .width('100%')
    .height('100%')
    .zIndex(20)
  }

  async loadBook(): Promise<void> {
    const serial = ++this.loadingSerial;
    if (!this.bookUrl) {
      this.statusText = '书籍地址为空';
      return;
    }
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      const storedBook = await db.getBook(this.bookUrl);
      if (!storedBook || serial !== this.loadingSerial) {
        if (!storedBook) this.statusText = '书籍不存在，请重新从搜索结果打开';
        return;
      }
      this.source = storedBook.origin ? await db.getBookSource(storedBook.origin) : null;
      BookTypeSupport.applyBookType(storedBook, this.source);
      storedBook.type = storedBook.type || BookTypeSupport.AUDIO;
      this.book = storedBook;
      this.speed = this.savedSpeed(storedBook);
      const engine = ReadBookEngine.get();
      await engine.openBook(storedBook);
      if (serial !== this.loadingSerial) return;
      this.book = engine.book || storedBook;
      BookTypeSupport.applyBookType(this.book, this.source);
      if (BookTypeSupport.isAudio(this.book) && this.book.type !== BookTypeSupport.AUDIO) {
        this.book.type |= BookTypeSupport.AUDIO;
      }
      this.chapters = engine.chapters;
      this.chapterDataSource.replace(this.chapters);
      this.chapterIndex = this.clampChapterIndex(this.book.durChapterIndex);
      await db.updateBook(this.book, false);
      if (this.chapters.length === 0) {
        this.statusText = '未获取到听书目录';
        return;
      }
      if (this.playback.matches(this.book.bookUrl, this.chapterIndex)) {
        this.positionMs = this.playback.positionMs;
        this.durationMs = this.playback.durationMs;
        this.playbackState = this.playback.state;
        this.speed = this.playback.speed;
        this.statusText = this.stateLabel(this.playback.state);
      } else {
        await this.playCurrentChapter(this.book.durChapterPos);
      }
    } catch (error) {
      this.statusText = `打开听书失败：${this.errorMessage(error)}`;
      console.error('打开听书失败:', error);
    }
  }

  async saveVoiceCode(): Promise<void> {
    const book = this.book;
    if (!book) return;
    const value = (this.voiceCodeInput || '').trim() || '6001';
    book.putVariable('custom', value);
    this.book = book;
    await AppDatabase.getInstance().updateBook(book, false);
    this.showVoiceDialog = false;
    this.statusText = `正在切换音色 ${value}...`;
    await this.playCurrentChapter(0, true);
  }

  async playCurrentChapter(startPositionMs: number = 0, forceRefresh: boolean = false): Promise<void> {
    const book = this.book;
    const chapter = this.currentChapter();
    if (!book || !chapter) return;
    const serial = ++this.loadingSerial;
    this.playbackRetryCount = forceRefresh ? this.playbackRetryCount : 0;
    this.statusText = forceRefresh ? '正在刷新音频地址...' : '正在获取音频地址...';
    this.playbackState = 'loading';
    try {
      const engine = ReadBookEngine.get();
      const content = forceRefresh ? await engine.reloadContent(this.chapterIndex) : await engine.loadContent(this.chapterIndex);
      if (serial !== this.loadingSerial) return;
      const url = this.resolveAudioUrl(content, chapter.url || book.bookUrl || this.source?.bookSourceUrl || '');
      if (!url) throw new Error('正文规则没有返回有效音频地址');
      const headers = this.audioHeaders(url, this.source);
      await this.playback.play(book.bookUrl, this.chapterIndex, url, headers, startPositionMs, this.speed);
      if (serial !== this.loadingSerial) return;
      this.statusText = '正在播放';
      this.saveProgressNow();
    } catch (error) {
      if (serial !== this.loadingSerial) return;
      this.onPlaybackError(this.errorMessage(error));
    }
  }

  async togglePlayback(): Promise<void> {
    try {
      if (this.isPlaying()) await this.playback.pause();
      else if (this.playback.matches(this.book?.bookUrl || '', this.chapterIndex)) await this.playback.resume();
      else await this.playCurrentChapter(this.positionMs);
    } catch (error) {
      this.onPlaybackError(this.errorMessage(error));
    }
  }

  async changeChapter(offset: number): Promise<void> {
    await this.selectChapter(this.chapterIndex + offset);
  }

  async selectChapter(index: number): Promise<void> {
    if (index < 0 || index >= this.chapters.length || index === this.chapterIndex) {
      this.showChapterList = false;
      return;
    }
    await this.saveProgressNow();
    this.chapterIndex = index;
    this.positionMs = 0;
    this.durationMs = 0;
    this.showChapterList = false;
    await this.playCurrentChapter(0);
  }

  onPlaybackStateChanged(state: string): void {
    this.playbackState = state;
    this.statusText = this.stateLabel(state);
    if (state === 'playing') {
      this.startAudioBackground().catch((error: Error) => {
        console.warn('启动听书后台播放失败:', error);
      });
    } else if (state === 'paused') {
      this.updateAudioAvSessionState(avSession.PlaybackState.PLAYBACK_STATE_PAUSE).catch(() => {});
    } else if (state === 'loading' || state === 'initialized' || state === 'prepared') {
      this.updateAudioAvSessionState(avSession.PlaybackState.PLAYBACK_STATE_BUFFERING).catch(() => {});
    } else if (state === 'completed' || state === 'error' || state === 'idle') {
      this.updateAudioAvSessionState(avSession.PlaybackState.PLAYBACK_STATE_STOP).catch(() => {});
    }
  }

  onPlaybackPositionChanged(positionMs: number, durationMs: number): void {
    this.positionMs = positionMs;
    this.durationMs = durationMs;
    this.scheduleProgressSave();
    const now = Date.now();
    if (now - this.lastAvSessionPositionUpdateAt >= 5000) {
      this.lastAvSessionPositionUpdateAt = now;
      this.updateAudioAvSessionState(this.isPlaying() ? avSession.PlaybackState.PLAYBACK_STATE_PLAY :
        avSession.PlaybackState.PLAYBACK_STATE_PAUSE).catch(() => {});
    }
  }

  onPlaybackCompleted(): void {
    this.saveProgressNow();
    if (this.chapterIndex < this.chapters.length - 1) {
      this.selectChapter(this.chapterIndex + 1);
    } else {
      this.statusText = '已播放完全部章节';
      this.stopAudioBackground().catch(() => {});
    }
  }

  onPlaybackError(message: string): void {
    if (this.playbackRetryCount < 1 && this.book && this.currentChapter()) {
      this.playbackRetryCount++;
      this.playCurrentChapter(this.positionMs, true);
      return;
    }
    this.playbackState = 'error';
    this.statusText = `播放失败：${message}`;
    promptAction.showToast({ message: this.statusText });
  }

  changeSpeed(value: number): void {
    this.speed = value;
    this.playback.setSpeed(value);
    if (this.book) {
      this.book.putVariable('audioSpeed', String(value));
      AppDatabase.getInstance().updateBook(this.book, false).catch(() => {});
    }
  }

  setSleepTimer(minutes: number): void {
    this.clearSleepTimer();
    this.sleepMinutes = minutes;
    this.playback.setSleepTimer(minutes);
    this.sleepRemainingSeconds = this.playback.sleepRemainingSeconds();
    if (minutes <= 0) return;
    this.startSleepTimerUi();
  }

  startSleepTimerUi(): void {
    this.sleepTimerId = setInterval(() => {
      this.sleepRemainingSeconds = this.playback.sleepRemainingSeconds();
      if (this.sleepRemainingSeconds <= 0) {
        this.clearSleepTimer();
        this.sleepMinutes = 0;
        promptAction.showToast({ message: '定时停止已生效' });
      }
    }, 1000);
  }

  restoreSleepTimerUi(): void {
    const remaining = this.playback.sleepRemainingSeconds();
    if (remaining <= 0) return;
    this.sleepRemainingSeconds = remaining;
    this.sleepMinutes = Math.max(1, Math.ceil(remaining / 60));
    this.clearSleepTimer();
    this.sleepRemainingSeconds = remaining;
    this.startSleepTimerUi();
  }

  async closePage(): Promise<void> {
    await this.saveProgressNow();
    await this.playback.stop();
    await this.stopAudioBackground();
    if (this.openedWithShelfAnimation) {
      AppStorage.setOrCreate('shelfBookCloseAnimationUrl', this.bookUrl);
      AppStorage.setOrCreate('shelfBookCloseAnimationNonce', Date.now());
    }
    try {
      if (this.openedFromShortcut && this.shortcutReplacedPreviousPage) {
        await router.replaceUrl({ url: 'pages/Index' });
      } else {
        router.back();
      }
    } catch (error) {
      console.error('退出听书页失败:', error);
    }
  }

  scheduleProgressSave(): void {
    if (this.progressSaveTimerId >= 0) return;
    this.progressSaveTimerId = setTimeout(() => {
      this.progressSaveTimerId = -1;
      this.saveProgressNow();
    }, 5000);
  }

  async saveProgressNow(): Promise<void> {
    const book = this.book;
    const chapter = this.currentChapter();
    if (!book || !chapter) return;
    book.durChapterIndex = this.chapterIndex;
    book.durChapterPos = Math.max(0, Math.floor(this.positionMs));
    book.durChapterTitle = chapter.title;
    book.durChapterTime = Date.now();
    book.putVariable('readStarted', '1');
    book.putVariable('lastReadTime', String(Date.now()));
    try {
      await AppDatabase.getInstance().updateBook(book);
      AppStorage.setOrCreate('shelfUpdateTime', Date.now());
    } catch (error) {
      console.warn('保存听书进度失败:', error);
    }
  }

  resolveAudioUrl(raw: string, baseUrl: string = ''): string {
    let value = String(raw || '').trim();
    if (!value) return '';
    if (value.startsWith('"') && value.endsWith('"')) {
      try { value = String(JSON.parse(value)); } catch (_) {}
    }
    value = this.decodeAudioRuleValue(value);
    try {
      const parsed = JSON.parse(value) as Record<string, Object>;
      const candidate = this.audioUrlFromObject(parsed, baseUrl);
      if (candidate) return candidate;
    } catch (_) {}

    const tagMatch = value.match(/<(?:audio|source)\b[^>]*\b(?:src|data-src|data-url)\s*=\s*["']([^"']+)["'][^>]*>/i) ||
      value.match(/<(?:audio|source)\b[^>]*\b(?:src|data-src|data-url)\s*=\s*([^\s>]+)[^>]*>/i);
    if (tagMatch && tagMatch[1]) {
      const taggedUrl = this.normalizeAudioCandidate(tagMatch[1], baseUrl, true);
      if (taggedUrl) return taggedUrl;
    }

    const fieldMatch = value.match(/["']?(?:audio_url|audioUrl|play_url|playUrl|playurl|listenUrl|streamUrl|mediaUrl|src|file|path|url)["']?\s*[:=]\s*["']([^"']+)["']/i);
    if (fieldMatch && fieldMatch[1]) {
      const fieldUrl = this.normalizeAudioCandidate(fieldMatch[1], baseUrl, true);
      if (fieldUrl) return fieldUrl;
    }

    const absoluteMatch = value.match(/https?:\/\/[^\s"'<>]+/i);
    if (absoluteMatch) {
      const absoluteUrl = this.normalizeAudioCandidate(absoluteMatch[0], baseUrl, true);
      if (absoluteUrl) return absoluteUrl;
    }
    const protocolRelativeMatch = value.match(/\/\/[A-Za-z0-9.-]+(?::\d+)?\/[^\s"'<>]*/);
    if (protocolRelativeMatch) {
      const protocolRelativeUrl = this.normalizeAudioCandidate(protocolRelativeMatch[0], baseUrl, true);
      if (protocolRelativeUrl) return protocolRelativeUrl;
    }
    return this.normalizeAudioCandidate(value, baseUrl, false);
  }

  audioUrlFromObject(value: Record<string, Object>, baseUrl: string): string {
    const keys = ['audio_url', 'audioUrl', 'play_url', 'playUrl', 'playurl', 'listenUrl', 'downloadUrl',
      'streamUrl', 'mediaUrl', 'src', 'file', 'path', 'url', 'content', 'data', 'audio', 'media'];
    for (const key of keys) {
      const item = value[key];
      if (typeof item === 'string') {
        const candidate = this.resolveAudioUrl(item, baseUrl);
        if (candidate) return candidate;
      } else if (item && typeof item === 'object' && !Array.isArray(item)) {
        const nested = this.audioUrlFromObject(item as Record<string, Object>, baseUrl);
        if (nested) return nested;
      } else if (Array.isArray(item)) {
        for (const entry of item as Object[]) {
          if (typeof entry === 'string') {
            const candidate = this.resolveAudioUrl(entry, baseUrl);
            if (candidate) return candidate;
          }
          if (entry && typeof entry === 'object') {
            const nested = this.audioUrlFromObject(entry as Record<string, Object>, baseUrl);
            if (nested) return nested;
          }
        }
      }
    }
    return '';
  }

  decodeAudioRuleValue(raw: string): string {
    return String(raw || '').trim()
      .replace(/&amp;/gi, '&')
      .replace(/&quot;/gi, '"')
      .replace(/&#39;|&apos;/gi, "'")
      .replace(/\\u002[fF]|\\x2[fF]/g, '/')
      .replace(/\\u003[aA]|\\x3[aA]/g, ':')
      .replace(/\\u0026|\\x26/gi, '&')
      .replace(/\\u003[dD]|\\x3[dD]/g, '=')
      .replace(/\\\//g, '/');
  }

  normalizeAudioCandidate(raw: string, baseUrl: string, trustPlainValue: boolean): string {
    let value = this.decodeAudioRuleValue(raw)
      .replace(/^url\(\s*|\s*\)$/gi, '')
      .replace(/^["']|["']$/g, '')
      .trim();
    value = value.replace(/,\s*\{[\s\S]*$/, '').replace(/[),.;\]}]+$/, '');
    if (!value || /\s/.test(value) || /^(?:javascript:|data:|about:|#)/i.test(value)) return '';

    const isExplicitUrl = /^(?:https?:)?\/\//i.test(value) || /^\.?\.?\//.test(value);
    const isLikelyMediaPath = /\.(?:aac|flac|m3u8|m4a|mp3|mp4|ogg|opus|wav)(?:[?#].*)?$/i.test(value);
    const isLikelyRelativeEndpoint = /^[A-Za-z0-9._~-]+(?:\/|\?)[^\s<>{}\[\]"']+$/.test(value);
    if (!isExplicitUrl && !isLikelyMediaPath && !isLikelyRelativeEndpoint && !trustPlainValue) return '';
    const resolved = BookUrlResolver.resolve(value, baseUrl);
    return /^https?:\/\//i.test(resolved) ? resolved : '';
  }

  audioHeaders(url: string, source: BookSource | null): Record<string, string> {
    const headers: Record<string, string> = {
      'User-Agent': 'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36'
    };
    if (!source) return headers;
    const rawHeader = source.header || '';
    try {
      const parsed = JSON.parse(rawHeader.replace(/'/g, '"')) as Record<string, string>;
      for (const key of Object.keys(parsed)) {
        const value = String(parsed[key] || '');
        if (key && value && !value.includes('java.')) headers[key] = value;
      }
    } catch (_) {
      const regex = /["']([A-Za-z0-9_-]+)["']\s*:\s*["']([^"']+)["']/g;
      let match: RegExpExecArray | null;
      while ((match = regex.exec(rawHeader)) !== null) {
        const key = match[1] || '';
        const value = match[2] || '';
        if (key && value && !value.includes('java.')) headers[key] = value;
      }
    }
    const cookie = VerificationSupport.sourceCookieHeader(source, url);
    if (cookie) headers['Cookie'] = cookie;
    return headers;
  }

  currentChapter(): BookChapter | null {
    return this.chapterIndex >= 0 && this.chapterIndex < this.chapters.length ? this.chapters[this.chapterIndex] : null;
  }

  clampChapterIndex(index: number): number {
    if (this.chapters.length === 0) return 0;
    return Math.max(0, Math.min(index || 0, this.chapters.length - 1));
  }

  isPlaying(): boolean {
    return this.playbackState === 'playing';
  }

  savedSpeed(book: Book): number {
    const value = Number(book.getVariable('audioSpeed') || 1);
    return Number.isFinite(value) ? Math.max(0.5, Math.min(2.5, value)) : 1;
  }

  displayCover(): string {
    return this.book ? CoverUrlNormalizer.normalize(this.book.getDisplayCover()) : '';
  }

  formatDuration(valueMs: number): string {
    const totalSeconds = Math.max(0, Math.floor((valueMs || 0) / 1000));
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const seconds = totalSeconds % 60;
    const mm = minutes.toString().padStart(2, '0');
    const ss = seconds.toString().padStart(2, '0');
    return hours > 0 ? `${hours}:${mm}:${ss}` : `${minutes}:${ss}`;
  }

  stateLabel(state: string): string {
    if (state === 'playing') return '正在播放';
    if (state === 'paused') return '已暂停';
    if (state === 'loading' || state === 'initialized' || state === 'prepared') return '正在加载音频...';
    if (state === 'completed') return '本章播放完成';
    if (state === 'error') return '播放失败，可点击播放重试';
    return '准备播放';
  }

  errorMessage(error: Object): string {
    if (error instanceof Error) return error.message || String(error);
    return String(error || '未知错误');
  }

  async startAudioBackground(): Promise<void> {
    if (this.audioBackgroundRunning) {
      await this.updateAudioAvSessionState(avSession.PlaybackState.PLAYBACK_STATE_PLAY);
      return;
    }
    if (this.audioBackgroundStarting) return;
    this.audioBackgroundStarting = true;
    try {
      const agent = await this.createAudioWantAgent();
      await this.startAudioAvSession(agent);
      await backgroundTaskManager.startBackgroundRunning(getContext(this), ['audioPlayback'], agent);
      this.audioBackgroundRunning = true;
    } catch (error) {
      console.warn('申请听书后台任务失败:', error);
    } finally {
      this.audioBackgroundStarting = false;
    }
  }

  async stopAudioBackground(): Promise<void> {
    const session = this.audioAvSession;
    this.audioAvSession = null;
    if (session) {
      try {
        await session.setAVPlaybackState({ state: avSession.PlaybackState.PLAYBACK_STATE_STOP });
        await session.deactivate();
        await session.destroy();
      } catch (error) {
        console.warn('关闭听书媒体会话失败:', error);
      }
    }
    if (!this.audioBackgroundRunning && !this.audioBackgroundStarting) return;
    this.audioBackgroundRunning = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(getContext(this));
    } catch (error) {
      console.warn('停止听书后台任务失败:', error);
    }
  }

  async startAudioAvSession(agent: WantAgent): Promise<void> {
    if (this.audioAvSessionStarting) return;
    this.audioAvSessionStarting = true;
    try {
      if (!this.audioAvSession) {
        this.audioAvSession = await avSession.createAVSession(getContext(this), 'LegadoAudioBook', 'audio');
        this.registerAudioAvSessionCommands(this.audioAvSession);
      }
      await this.audioAvSession.setLaunchAbility(agent);
      await this.audioAvSession.setAVQueueTitle(this.book?.name || '听书');
      await this.audioAvSession.setAVMetadata(this.audioAvMetadata());
      await this.audioAvSession.setExtras({
        bookUrl: this.bookUrl,
        chapterIndex: this.chapterIndex,
        chapterTitle: this.currentChapter()?.title || ''
      });
      await this.updateAudioAvSessionState(avSession.PlaybackState.PLAYBACK_STATE_PLAY);
      await this.audioAvSession.activate();
    } finally {
      this.audioAvSessionStarting = false;
    }
  }

  registerAudioAvSessionCommands(session: avSession.AVSession): void {
    session.on('play', (): void => {
      this.playback.resume().catch(() => {});
    });
    session.on('pause', (): void => {
      this.playback.pause().catch(() => {});
    });
    session.on('stop', (): void => {
      this.playback.stop().then(() => this.stopAudioBackground()).catch(() => {});
    });
    session.on('playNext', (): void => {
      this.changeChapter(1);
    });
    session.on('playPrevious', (): void => {
      this.changeChapter(-1);
    });
    session.on('seek', (time: number): void => {
      this.playback.seek(time);
    });
    session.on('setSpeed', (speed: number): void => {
      this.changeSpeed(speed);
    });
  }

  async updateAudioAvSessionState(state: avSession.PlaybackState): Promise<void> {
    const session = this.audioAvSession;
    if (!session) return;
    try {
      await session.setAVMetadata(this.audioAvMetadata());
      await session.setAVPlaybackState({
        state: state,
        speed: this.speed,
        position: { elapsedTime: this.positionMs, updateTime: Date.now() },
        bufferedTime: this.durationMs,
        loopMode: avSession.LoopMode.LOOP_MODE_SEQUENCE,
        activeItemId: this.chapterIndex
      });
      if (state === avSession.PlaybackState.PLAYBACK_STATE_PLAY ||
        state === avSession.PlaybackState.PLAYBACK_STATE_BUFFERING) await session.activate();
    } catch (error) {
      console.warn('更新听书媒体控制状态失败:', error);
    }
  }

  audioAvMetadata(): avSession.AVMetadata {
    const chapter = this.currentChapter();
    const metadata: avSession.AVMetadata = {
      assetId: `${this.bookUrl}_${this.chapterIndex}`,
      title: chapter?.title || this.book?.name || '听书',
      subtitle: this.book?.name || '',
      artist: this.book?.author || this.book?.originName || '听书',
      author: this.book?.author || '',
      album: this.book?.name || '听书',
      duration: this.durationMs,
      previousAssetId: this.chapterIndex > 0 ? `${this.bookUrl}_${this.chapterIndex - 1}` : '',
      nextAssetId: this.chapterIndex < this.chapters.length - 1 ? `${this.bookUrl}_${this.chapterIndex + 1}` : '',
      avQueueName: this.book?.name || '听书',
      avQueueId: this.bookUrl || 'audio_book'
    };
    const cover = this.displayCover();
    if (cover) {
      metadata.mediaImage = cover;
      metadata.avQueueImage = cover;
    }
    return metadata;
  }

  async createAudioWantAgent(): Promise<WantAgent> {
    const context = getContext(this) as common.UIAbilityContext;
    return await wantAgent.getWantAgent({
      wants: [{
        bundleName: context.abilityInfo.bundleName,
        abilityName: 'EntryAbility'
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 1101,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
  }

  clearProgressSaveTimer(): void {
    if (this.progressSaveTimerId >= 0) clearTimeout(this.progressSaveTimerId);
    this.progressSaveTimerId = -1;
  }

  clearSleepTimer(): void {
    if (this.sleepTimerId >= 0) clearInterval(this.sleepTimerId);
    this.sleepTimerId = -1;
    this.sleepRemainingSeconds = 0;
  }

  pageColor(): string { return ThemeRuntime.pageColor(this.appDarkMode); }
  cardColor(): string { return ThemeRuntime.cardColor(this.appDarkMode); }
  inputColor(): string { return ThemeRuntime.inputColor(this.appDarkMode); }
  primaryTextColor(): string { return ThemeRuntime.primaryTextColor(this.appDarkMode); }
  secondaryTextColor(): string { return ThemeRuntime.subTextColor(this.appDarkMode); }
  subTextColor(): string { return ThemeRuntime.subTextColor(this.appDarkMode); }
  accentColor(): string { return ThemeRuntime.accentColor(this.appDarkMode); }

  syncBars(): void {
    syncSystemBars(getContext(this), this.appDarkMode, this.pageColor());
  }
}
