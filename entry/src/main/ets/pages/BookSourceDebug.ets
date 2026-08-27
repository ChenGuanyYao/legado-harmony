import { router } from '@kit.ArkUI';
import { Context } from '@kit.AbilityKit';
import { Book, BookChapter, BookSource, SearchBook } from '../model/data/Book';
import { AppDatabase } from '../model/data/AppDatabase';
import { SearchCoordinator } from '../core/book/SearchCoordinator';
import { ExploreCoordinator, ExploreEntry } from '../core/book/ExploreCoordinator';
import { WebBookService } from '../core/book/WebBookService';
import { SourceRuntimeStage } from '../core/book/BookSourceRuntimeRouter';
import { BookSourceDebugContext, BookSourceDebugSession, BookSourceDebugStep,
  BookSourceDebugNetworkTrace, BookSourceDebugRuleTrace, BookSourceDebugLog } from '../core/book/BookSourceDebugModels';
import { ImmersiveBackButton } from '../components/ImmersiveBackButton';
import { ThemeRuntime } from '../theme/ThemeRuntime';
import { syncSystemBars } from '../utils/SystemBars';

@Entry
@Component
struct BookSourceDebugPage {
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State source: BookSource = new BookSource();
  @State sourceUrl: string = '';
  @State keyword: string = '';
  @State stage: string = SourceRuntimeStage.SEARCH;
  @State running: boolean = false;
  @State status: string = '准备就绪';
  @State session: BookSourceDebugSession = new BookSourceDebugSession();
  private coordinator: SearchCoordinator | null = null;
  private initialized: boolean = false;

  aboutToAppear(): void {
    this.syncBars();
    if (this.initialized) return;
    this.initialized = true;
    const params = router.getParams() as Record<string, string>;
    this.sourceUrl = params && params['bookSourceUrl'] ? params['bookSourceUrl'] : '';
    const draft = AppStorage.get<string>('bookSourceDebugDraftJson') || '';
    if (draft) {
      try {
        const draftSource = JSON.parse(draft) as BookSource;
        if (draftSource.bookSourceUrl === this.sourceUrl) this.source = draftSource;
      } catch (_) {
      }
    }
    this.loadSource();
  }

  onPageShow(): void {
    this.syncBars();
  }

  onPageHide(): void {
    if (this.running) this.coordinator?.cancel();
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Scroll() {
        Column({ space: 12 }) {
          this.sourceCard()
          this.inputCard()
          this.resultCard()
        }
        .width('100%')
        .padding({ top: 68 + this.statusBarHeight, bottom: 32 + this.navBarHeight })
      }
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .width('100%')
      .height('100%')
      this.titleBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  titleBar() {
    Row() {
      ImmersiveBackButton({ iconColor: this.primaryTextColor(), darkMode: this.appDarkMode,
        buttonSize: 40, containerWidth: 56, materialScale: 0.83, compactLayout: true,
        onBack: () => router.back() })
      Text('书源调试').fontSize(20).fontWeight(FontWeight.Bold)
        .fontColor(this.primaryTextColor()).layoutWeight(1)
    }
    .width('100%').height(56 + this.statusBarHeight).padding({ top: this.statusBarHeight })
    .backgroundColor(ThemeRuntime.topBarColor(this.appDarkMode))
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  sourceCard() {
    Column({ space: 5 }) {
      Text(this.source.bookSourceName || '正在加载书源').fontSize(17).fontWeight(FontWeight.Bold)
        .fontColor(this.primaryTextColor()).width('100%')
      Text(this.source.bookSourceUrl || this.sourceUrl || '未指定书源')
        .fontSize(12).fontColor(this.subTextColor()).width('100%').maxLines(2)
      Text(`状态：${this.status}`).fontSize(13).fontColor(this.running ? '#E89725' : this.accentColor())
        .width('100%')
    }
    .width('calc(100% - 24vp)').padding(16).borderRadius(16).backgroundColor(this.cardColor())
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  inputCard() {
    Column({ space: 10 }) {
      Text('调试阶段').fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor()).width('100%')
      Row({ space: 6 }) {
        this.stageButton(SourceRuntimeStage.SEARCH, '搜索')
        this.stageButton(SourceRuntimeStage.EXPLORE, '发现')
        this.stageButton(SourceRuntimeStage.BOOK_INFO, '详情')
        this.stageButton(SourceRuntimeStage.TOC, '目录')
        this.stageButton(SourceRuntimeStage.CONTENT, '正文')
        this.stageButton('full', '全链路')
      }.width('100%')
      TextInput({ text: this.keyword, placeholder: this.stageInputPlaceholder() })
        .height(44).width('100%').fontColor(this.primaryTextColor())
        .backgroundColor(this.inputColor()).onChange((value: string) => this.keyword = value)
      Row({ space: 10 }) {
        Button(this.running ? '取消调试' : '开始调试', { type: ButtonType.Capsule })
          .layoutWeight(1).height(44).enabled(this.running || !!this.source.bookSourceUrl)
          .backgroundColor(this.accentColor()).fontColor('#FFFFFF').onClick(() => this.runDebug())
        Button('清空', { type: ButtonType.Capsule }).height(44).width(82)
          .backgroundColor(this.inputColor()).fontColor(this.primaryTextColor())
          .onClick(() => this.session = new BookSourceDebugSession())
      }.width('100%')
    }
    .width('calc(100% - 24vp)').padding(16).borderRadius(16).backgroundColor(this.cardColor())
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  stageButton(value: string, label: string) {
    Text(label)
      .fontSize(12).height(32).layoutWeight(1).textAlign(TextAlign.Center)
      .fontColor(this.stage === value ? '#FFFFFF' : this.primaryTextColor())
      .padding({ left: 5, right: 5 })
      .borderRadius(16)
      .backgroundColor(this.stage === value ? this.accentColor() : this.inputColor())
      .border({ width: this.stage === value ? 0 : 1, color: this.appDarkMode ? '#454545' : '#D9DDE3' })
      .onClick(() => this.stage = value)
  }

  @Builder
  resultCard() {
    Column({ space: 10 }) {
      Text('执行明细').fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor()).width('100%')
      if (this.session.steps.length === 0 && this.session.logs.length === 0) {
        Text('运行后显示请求、规则匹配和错误详情').fontSize(13).fontColor(this.subTextColor()).width('100%')
      }
      ForEach(this.session.steps, (step: BookSourceDebugStep) => {
        this.stepView(step)
      }, (step: BookSourceDebugStep) => `${step.stage}_${step.startedAt}`)
      ForEach(this.session.logs, (log: BookSourceDebugLog) => {
        Text(`[${log.level}] ${log.message}`).fontSize(12).fontColor(this.subTextColor()).width('100%')
      }, (log: BookSourceDebugLog) => `${log.timestamp}_${log.message}`)
    }
    .width('calc(100% - 24vp)').padding(16).borderRadius(16).backgroundColor(this.cardColor())
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  stepView(step: BookSourceDebugStep) {
    Column({ space: 8 }) {
      Row() {
        Text(step.name).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.primaryTextColor())
          .layoutWeight(1)
        Text(`${step.status} · ${step.elapsedMs}ms`).fontSize(12)
          .fontColor(step.status === 'passed' ? '#20A464' : '#E84040')
      }.width('100%')
      if (step.error) Text(`错误：${step.error}`).fontSize(12).fontColor('#E84040').width('100%')
      ForEach(step.requests, (item: BookSourceDebugNetworkTrace) => {
        Text(`${item.method} ${item.url}\nHTTP ${item.statusCode} · ${item.responseBytes} 字符 · ${item.elapsedMs}ms${item.error ? `\n${item.error}` : ''}`)
          .fontSize(12).fontColor(this.subTextColor()).width('100%')
        if (item.bodyPreview) {
          Text(`响应预览：${item.bodyPreview}`).fontSize(11).fontColor(this.subTextColor())
            .width('100%').maxLines(8)
        }
      }, (item: BookSourceDebugNetworkTrace) => `${item.method}_${item.url}_${item.elapsedMs}`)
      ForEach(step.rules, (item: BookSourceDebugRuleTrace) => {
        Text(`${item.field} [${item.ruleType}] 匹配 ${item.matchedCount}/${item.inputCount} · ${item.elapsedMs}ms\n规则：${item.rule}${item.error ? `\n${item.error}` : ''}${item.outputPreview ? `\n结果：${item.outputPreview}` : ''}`)
          .fontSize(12).fontColor(this.subTextColor()).width('100%')
      }, (item: BookSourceDebugRuleTrace) => `${item.field}_${item.elapsedMs}`)
      ForEach(Object.keys(step.outputs), (key: string) => {
        Text(`${key}：${step.outputs[key]}`).fontSize(12).fontColor(this.subTextColor()).width('100%')
      }, (key: string) => key)
    }
    .width('100%').padding(12).borderRadius(10).backgroundColor(this.inputColor())
    .alignItems(HorizontalAlign.Start)
  }

  private async loadSource(): Promise<void> {
    if (!this.sourceUrl) return;
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this) as Context);
      const source = await db.getBookSource(this.sourceUrl);
      const draft = AppStorage.get<string>('bookSourceDebugDraftJson') || '';
      if (draft) {
        try {
          const draftSource = JSON.parse(draft) as BookSource;
          if (draftSource.bookSourceUrl === this.sourceUrl) {
            this.source = draftSource;
            return;
          }
        } catch (_) {
        }
      }
      if (source) this.source = source;
      else this.status = '找不到书源';
    } catch (_) {
      this.status = '加载书源失败';
    }
  }

  private async runDebug(): Promise<void> {
    if (this.running) {
      this.coordinator?.cancel();
      this.status = '正在取消';
      return;
    }
    if (!this.source.bookSourceUrl) return;
    this.running = true;
    this.status = '执行中';
    const debug = new BookSourceDebugContext(this.source.bookSourceUrl, this.source.bookSourceName, this.stage);
    this.session = debug.session;
    try {
      if (this.stage === SourceRuntimeStage.SEARCH) {
        this.coordinator = new SearchCoordinator(1);
        await this.coordinator.search(this.keyword.trim(), (progress) => {
          this.status = progress.finished ? progress.status : progress.status;
          this.publishSession(debug);
        }, { targetSources: [this.source], validationOnly: false, maxResultsPerSource: 5,
          maxTotalResults: 5, debugContext: debug, onSourceComplete: async (_source, result) => {
            debug.addLog(result.validationStatus === BookSource.VALIDATION_PASSED ? 'info' : 'error',
              result.reason || `返回 ${result.books.length} 本书`);
          } });
      } else if (this.stage === SourceRuntimeStage.EXPLORE) {
        await this.runExploreDebug(debug);
      } else if (this.stage === SourceRuntimeStage.BOOK_INFO) {
        await this.runBookInfoDebug(debug);
      } else if (this.stage === SourceRuntimeStage.TOC) {
        await this.runTocDebug(debug);
      } else if (this.stage === SourceRuntimeStage.CONTENT) {
        await this.runContentDebug(debug);
      } else {
        await this.runFullDebug(debug);
      }
      debug.finish(this.session.steps.some((step: BookSourceDebugStep): boolean => step.status === 'passed') ? 'passed' : 'failed');
      this.publishSession(debug);
    } catch (error) {
      debug.addLog('error', error instanceof Error ? error.message : String(error));
      debug.finish('failed');
      this.publishSession(debug);
      this.status = '执行失败';
    } finally {
      this.running = false;
      this.coordinator = null;
    }
  }

  private async runExploreDebug(debug: BookSourceDebugContext): Promise<void> {
    debug.beginStep(SourceRuntimeStage.EXPLORE, '发现分类');
    const coordinator = new ExploreCoordinator();
    const entries = await coordinator.getEntries('', this.source.bookSourceUrl, debug);
    debug.setOutput('entryCount', String(entries.length));
    debug.finishStep(entries.length > 0 ? 'passed' : 'failed', coordinator.getNoticeMessage());
    if (entries.length === 0) return;
    debug.beginStep(SourceRuntimeStage.EXPLORE, `发现列表：${entries[0].title}`);
    const books = await coordinator.explore(entries[0], 1, 5, debug);
    debug.setOutput('resultCount', String(books.length));
    debug.finishStep(books.length > 0 ? 'passed' : 'failed', coordinator.getNoticeMessage());
  }

  private createDebugBook(): Book {
    const book = new Book();
    book.bookUrl = this.keyword.trim();
    book.tocUrl = this.keyword.trim();
    book.origin = this.source.bookSourceUrl;
    book.originName = this.source.bookSourceName;
    return book;
  }

  private async runBookInfoDebug(debug: BookSourceDebugContext): Promise<void> {
    const book = this.createDebugBook();
    debug.beginStep(SourceRuntimeStage.BOOK_INFO, '书籍详情');
    const result = await new WebBookService().getBookInfo(this.source, book, debug);
    debug.setOutput('name', result.name);
    debug.setOutput('author', result.author);
    debug.setOutput('updateTime', result.updateTime);
    debug.setOutput('tocUrl', result.tocUrl);
    debug.finishStep(result.name || result.tocUrl ? 'passed' : 'failed', result.name ? '' : '详情规则没有提取出书名');
  }

  private async runTocDebug(debug: BookSourceDebugContext): Promise<void> {
    const book = this.createDebugBook();
    debug.beginStep(SourceRuntimeStage.TOC, '书籍目录');
    const chapters = await new WebBookService().getChapterList(this.source, book, 32, false, debug);
    debug.setOutput('chapterCount', String(chapters.length));
    if (chapters.length > 0) {
      debug.setOutput('firstChapter', chapters[0].title);
      debug.setOutput('firstChapterUrl', chapters[0].url);
    }
    debug.finishStep(chapters.length > 0 ? 'passed' : 'failed', chapters.length > 0 ? '' : '目录规则没有提取出章节');
  }

  private async runContentDebug(debug: BookSourceDebugContext): Promise<void> {
    const book = this.createDebugBook();
    const chapter = new BookChapter();
    chapter.url = this.keyword.trim();
    chapter.bookUrl = book.bookUrl;
    chapter.title = '调试章节';
    debug.beginStep(SourceRuntimeStage.CONTENT, '章节正文');
    const content = await new WebBookService().getContent(this.source, book, chapter, null, debug);
    debug.setOutput('contentLength', String(content.length));
    debug.finishStep(content.length > 0 ? 'passed' : 'failed', content.length > 0 ? '' : '正文规则返回空结果');
  }

  private async runFullDebug(debug: BookSourceDebugContext): Promise<void> {
    let candidates: SearchBook[] = [];
    const searchCoordinator = new SearchCoordinator(1);
    candidates = await searchCoordinator.search(this.keyword.trim(), (progress) => {
      this.status = progress.status;
      this.publishSession(debug);
    }, { targetSources: [this.source], maxResultsPerSource: 1, maxTotalResults: 1,
      debugContext: debug });
    if (candidates.length === 0 && !this.source.enabledExplore) {
      debug.addLog('error', '该书源未启用发现，完整链路无法自动取得候选书');
      return;
    }
    if (candidates.length > 0) {
      debug.addLog('info', `搜索阶段取得 ${candidates.length} 本候选书`);
    }
    if (candidates.length === 0) {
    const coordinator = new ExploreCoordinator();
    debug.beginStep(SourceRuntimeStage.EXPLORE, '发现分类');
    const entries = await coordinator.getEntries('', this.source.bookSourceUrl, debug);
    debug.setOutput('entryCount', String(entries.length));
    debug.finishStep(entries.length > 0 ? 'passed' : 'failed', coordinator.getNoticeMessage());
    if (entries.length === 0) return;
    debug.beginStep(SourceRuntimeStage.EXPLORE, `发现列表：${entries[0].title}`);
    candidates = await coordinator.explore(entries[0], 1, 1, debug);
    debug.setOutput('resultCount', String(candidates.length));
    debug.finishStep(candidates.length > 0 ? 'passed' : 'failed', coordinator.getNoticeMessage());
    if (candidates.length === 0) return;
    }
    const book = this.searchBookToBook(candidates[0]);
    debug.beginStep(SourceRuntimeStage.BOOK_INFO, '书籍详情');
    const service = new WebBookService();
    const fullBook = await service.getBookInfo(this.source, book, debug);
    debug.setOutput('name', fullBook.name);
    debug.finishStep(fullBook.name || fullBook.tocUrl ? 'passed' : 'failed',
      fullBook.name || fullBook.tocUrl ? '' : '详情未提取出书籍信息');
    debug.beginStep(SourceRuntimeStage.TOC, '书籍目录');
    const chapters = await service.getChapterList(this.source, fullBook, 32, false, debug);
    debug.setOutput('chapterCount', String(chapters.length));
    debug.finishStep(chapters.length > 0 ? 'passed' : 'failed', chapters.length > 0 ? '' : '目录为空');
    if (chapters.length === 0) return;
    debug.beginStep(SourceRuntimeStage.CONTENT, '章节正文');
    const content = await service.getContent(this.source, fullBook, chapters[0], null, debug);
    debug.setOutput('contentLength', String(content.length));
    debug.finishStep(content.length > 0 ? 'passed' : 'failed', content.length > 0 ? '' : '正文为空');
  }

  private searchBookToBook(item: SearchBook): Book {
    const book = new Book();
    book.bookUrl = item.bookUrl;
    book.tocUrl = item.tocUrl;
    book.origin = item.origin;
    book.originName = item.originName;
    book.name = item.name;
    book.author = item.author;
    book.variable = item.variable;
    return book;
  }

  private syncBars(): void { syncSystemBars(getContext(this) as Context, this.appDarkMode); }
  private publishSession(debug: BookSourceDebugContext): void {
    this.session = JSON.parse(JSON.stringify(debug.session)) as BookSourceDebugSession;
  }
  private pageColor(): string { return ThemeRuntime.pageColor(this.appDarkMode); }
  private cardColor(): string { return ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'); }
  private inputColor(): string { return this.appDarkMode ? '#252525' : '#F2F3F5'; }
  private primaryTextColor(): string { return this.appDarkMode ? '#F5F5F5' : '#1F2329'; }
  private subTextColor(): string { return this.appDarkMode ? '#B8B8B8' : '#697586'; }
  private accentColor(): string { return ThemeRuntime.accentColor(this.appDarkMode); }
  private stageInputPlaceholder(): string {
    if (this.stage === SourceRuntimeStage.SEARCH || this.stage === 'full') return '输入测试关键词';
    if (this.stage === SourceRuntimeStage.EXPLORE) return '输入关键词（发现阶段将使用第一个分类）';
    if (this.stage === SourceRuntimeStage.CONTENT) return '输入章节 URL';
    return '输入书籍或目录 URL';
  }
}
