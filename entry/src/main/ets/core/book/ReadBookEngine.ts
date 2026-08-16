import { Book, BookChapter, BookSource, SearchBook } from '../../model/data/Book';
import { appDb } from '../../model/data/AppDatabase';
import { WebBookService } from './WebBookService';
import { SearchCoordinator } from './SearchCoordinator';
import { CoverUrlNormalizer } from '../../utils/CoverUrlNormalizer';
import { LocalChapterContentLoader } from './LocalChapterContentLoader';
import { ReaderActionMarker } from './ReaderActionMarker';
import { BookSourceInteractionPostProcessor } from './BookSourceInteractionPostProcessor';

export class ReadBookEngine {
  private static inst: ReadBookEngine | null = null;
  private webBook: WebBookService;

  book: Book | null = null;
  source: BookSource | null = null;
  chapters: BookChapter[] = [];
  curIdx: number = 0;
  curPos: number = 0;
  content: string = '';
  isLoading: boolean = false;

  private chapterCache: Map<number, string> = new Map();
  private chapterLoading: Map<number, Promise<string>> = new Map();
  private readonly chapterCacheLimit: number = 7;
  private preloadGeneration: number = 0;
  private bookGeneration: number = 0;
  private sourceInteractionIdentity: string = '';
  private static readonly SOURCE_INTERACTION_IDENTITY_KEY: string = '__readerSourceInteractionIdentity';

  private constructor() { this.webBook = new WebBookService(); }

  static get(): ReadBookEngine {
    if (!ReadBookEngine.inst) ReadBookEngine.inst = new ReadBookEngine();
    return ReadBookEngine.inst;
  }

  static createBackgroundWorker(): ReadBookEngine {
    return new ReadBookEngine();
  }

  async openBook(book: Book): Promise<void> {
    const generation = ++this.bookGeneration;
    console.log('[RE] openBook:', book.name, 'origin:', book.origin);
    this.book = book;
    this.curIdx = book.durChapterIndex;
    this.curPos = book.durChapterPos;
    this.content = '';
    this.chapterCache.clear();
    this.chapterLoading.clear();
    this.preloadGeneration++;
    this.source = null;

    if (book.origin && book.origin !== 'local') {
      const source = await appDb.getBookSource(book.origin);
      if (!this.isCurrentBookSession(generation, book.bookUrl)) return;
      this.source = source;
      console.log('[RE] source loaded:', this.source ? this.source.bookSourceName : 'none');
    }

    await this.initializeSourceInteractionIdentity(generation, book);
    if (!this.isCurrentBookSession(generation, book.bookUrl)) return;

    const cachedChapters = await appDb.getBookChapters(book.bookUrl);
    if (!this.isCurrentBookSession(generation, book.bookUrl)) return;
    this.chapters = cachedChapters;
    console.log('[RE] cached chapters:', this.chapters.length);

    // 检查缓存章节是否有未解析的变量（旧版本残留）
    const hasBrokenUrls = book.origin !== 'local' && this.chapters.some(c => this.isBrokenChapterUrl(c.url));
    if (hasBrokenUrls ||
      (this.chapters.length === 0 && this.source && book.origin !== 'local')) {
      if (hasBrokenUrls) {
        console.log('[RE] 检测到过期缓存，清除并重新获取');
        await appDb.deleteBookChapters(book.bookUrl);
        if (!this.isCurrentBookSession(generation, book.bookUrl)) return;
        this.chapters = [];
      }
      console.log('[RE] no valid chapters, refreshing toc...');
      await this.refreshToc(generation);
    }
  }

  async refreshToc(expectedGeneration: number = this.bookGeneration): Promise<void> {
    if (!this.book || !this.source) return;
    const sessionBook = this.book;
    const sessionSource = this.source;
    const sessionBookUrl = sessionBook.bookUrl;
    console.log('[RE] refreshToc start');
    this.isLoading = true;
    try {
      const oldBook = sessionBook;
      const oldTocUrl = oldBook.tocUrl;
      const oldLatestChapter = oldBook.latestChapterTitle;
      const oldCoverUrl = oldBook.coverUrl;
      const canReuseResolvedInfo = !!oldBook.tocUrl && oldBook.lastCheckTime > 0 &&
        Date.now() - oldBook.lastCheckTime < 2 * 60 * 1000;
      if (!canReuseResolvedInfo) {
        const infoBook = await this.webBook.getBookInfo(sessionSource, sessionBook);
        if (!this.isCurrentBookSession(expectedGeneration, sessionBookUrl)) return;
        this.book = infoBook;
        this.book.lastCheckTime = Date.now();
        this.book.coverUrl = CoverUrlNormalizer.prefer(oldCoverUrl, this.book.coverUrl);
        this.preserveReadingState(this.book, oldBook);
        console.log('[RE] getBookInfo done, tocUrl:', this.book.tocUrl);
      } else {
        console.log('[RE] reuse recently resolved book info, tocUrl:', this.book.tocUrl);
      }
      if (!this.book.tocUrl && oldTocUrl) {
        this.book.tocUrl = oldTocUrl;
      }

      const resolvedBook = this.book;
      if (!resolvedBook || !this.isCurrentBookSession(expectedGeneration, sessionBookUrl)) return;
      let chapters = await this.webBook.getChapterList(sessionSource, resolvedBook);
      if (!this.isCurrentBookSession(expectedGeneration, sessionBookUrl)) return;
      if (chapters.length === 0) {
        const recoveredBook = await this.tryRecoverStaleBookAddress(sessionSource, resolvedBook,
          expectedGeneration, sessionBookUrl);
        if (!this.isCurrentBookSession(expectedGeneration, sessionBookUrl)) return;
        if (recoveredBook) {
          this.book = recoveredBook;
          chapters = await this.webBook.getChapterList(sessionSource, recoveredBook);
          if (!this.isCurrentBookSession(expectedGeneration, sessionBookUrl)) return;
        }
      }
      console.log('[RE] getChapterList done, count:', chapters.length);
      if (chapters.length > 0) {
        const targetBook = this.book;
        await appDb.updateBook(targetBook);
        if (!this.isCurrentBookSession(expectedGeneration, sessionBookUrl)) return;
        await appDb.deleteBookChapters(targetBook.bookUrl);
        if (!this.isCurrentBookSession(expectedGeneration, sessionBookUrl)) return;
        await appDb.insertBookChapters(chapters);
        if (!this.isCurrentBookSession(expectedGeneration, sessionBookUrl)) return;
        this.chapters = chapters;
        this.chapterCache.clear();
        this.chapterLoading.clear();
        await this.syncChapterCacheDates(expectedGeneration, sessionBookUrl);
        if (!this.isCurrentBookSession(expectedGeneration, sessionBookUrl)) return;
        targetBook.totalChapterNum = chapters.length;
        targetBook.latestChapterTitle = chapters[chapters.length - 1].title;
        await appDb.updateBook(targetBook);
      } else {
        this.book.latestChapterTitle = this.book.latestChapterTitle || oldLatestChapter;
        this.book.tocUrl = this.book.tocUrl || oldTocUrl;
        console.warn('[RE] refreshToc returned no chapters, keep existing chapters:', this.chapters.length);
      }
    } finally {
      if (this.isCurrentBookSession(expectedGeneration, sessionBookUrl)) {
        this.isLoading = false;
      }
    }
  }

  private isCurrentBookSession(generation: number, bookUrl: string): boolean {
    return generation === this.bookGeneration && !!this.book && this.book.bookUrl === bookUrl;
  }

  /**
   * Imported sources sometimes move their detail endpoint while books already on the shelf retain
   * the old URL. If both the current detail/catalog attempt and the cached catalog URL fail, search
   * the same source for an exact title match and use its current detail URL as the catalog entry.
   * Keep the shelf bookUrl unchanged so reading progress, bookmarks and caches retain their identity.
   */
  private async tryRecoverStaleBookAddress(source: BookSource, staleBook: Book,
    expectedGeneration: number, sessionBookUrl: string): Promise<Book | null> {
    const keyword = (staleBook.name || '').trim();
    if (!keyword || !this.isCurrentBookSession(expectedGeneration, sessionBookUrl)) return null;

    try {
      const coordinator = new SearchCoordinator(1);
      const results = await coordinator.search(keyword, () => {}, {
        exactMatch: true,
        targetSources: [source],
        maxResultsPerSource: 10,
        maxTotalResults: 10,
        stopAfterResults: 10
      });
      console.info('[RE] stale source recovery search:', results.length,
        coordinator.getLastFailureReason());
      if (!this.isCurrentBookSession(expectedGeneration, sessionBookUrl)) return null;
      const candidate = this.selectRecoveryCandidate(results, staleBook);
      if (!candidate || !candidate.bookUrl || candidate.bookUrl === sessionBookUrl) return null;

      const probe = this.buildRecoveryProbe(candidate, staleBook);
      const resolved = await this.webBook.getBookInfo(source, probe);
      if (!this.isCurrentBookSession(expectedGeneration, sessionBookUrl)) return null;
      const currentDetailUrl = resolved.bookUrl || candidate.bookUrl;
      this.preserveReadingState(resolved, staleBook);
      resolved.tocUrl = resolved.tocUrl || candidate.tocUrl || currentDetailUrl;
      resolved.coverUrl = CoverUrlNormalizer.prefer(staleBook.coverUrl, resolved.coverUrl);
      console.info('[RE] recovered stale source address:', sessionBookUrl, '->', currentDetailUrl);
      return resolved;
    } catch (error) {
      console.warn('[RE] stale source address recovery failed:', error);
      return null;
    }
  }

  private selectRecoveryCandidate(results: SearchBook[], staleBook: Book): SearchBook | null {
    const expectedName = this.normalizeBookIdentity(staleBook.name);
    const expectedAuthor = this.normalizeBookIdentity(staleBook.author);
    let titleMatch: SearchBook | null = null;
    let authorlessMatch: SearchBook | null = null;
    for (const candidate of results) {
      if (this.normalizeBookIdentity(candidate.name) !== expectedName) continue;
      if (!titleMatch) titleMatch = candidate;
      const candidateAuthor = this.normalizeBookIdentity(candidate.author);
      if (!expectedAuthor) return candidate;
      if (candidateAuthor === expectedAuthor) return candidate;
      if (!candidateAuthor && !authorlessMatch) authorlessMatch = candidate;
    }
    return expectedAuthor ? authorlessMatch : titleMatch;
  }

  private normalizeBookIdentity(value: string): string {
    return (value || '').trim().toLowerCase()
      .replace(/[\u200B-\u200D\uFEFF]/g, '')
      .replace(/\s+/g, '')
      .replace(/[《》【】\[\]（）()「」『』"“”'‘’.,，。:：;；!！?？、·_\-]/g, '');
  }

  private buildRecoveryProbe(candidate: SearchBook, staleBook: Book): Book {
    const probe = new Book();
    probe.bookUrl = candidate.bookUrl;
    probe.tocUrl = candidate.tocUrl;
    probe.origin = staleBook.origin;
    probe.originName = candidate.originName || staleBook.originName;
    probe.name = candidate.name || staleBook.name;
    probe.author = candidate.author || staleBook.author;
    probe.kind = candidate.kind || staleBook.kind;
    probe.coverUrl = CoverUrlNormalizer.prefer(staleBook.coverUrl, candidate.coverUrl);
    probe.customCoverUrl = staleBook.customCoverUrl;
    probe.intro = candidate.intro || staleBook.intro;
    probe.customIntro = staleBook.customIntro;
    probe.customTag = staleBook.customTag;
    probe.type = candidate.type || staleBook.type;
    probe.group = staleBook.group;
    probe.latestChapterTitle = candidate.latestChapterTitle || staleBook.latestChapterTitle;
    probe.wordCount = candidate.wordCount || staleBook.wordCount;
    probe.canUpdate = staleBook.canUpdate;
    probe.order = staleBook.order;
    probe.originOrder = staleBook.originOrder;
    probe.variable = candidate.variable || staleBook.variable;
    probe.readConfig = staleBook.readConfig;
    probe.syncTime = staleBook.syncTime;
    return probe;
  }

  private preserveReadingState(target: Book, source: Book): void {
    target.bookUrl = source.bookUrl;
    target.origin = target.origin || source.origin;
    target.originName = target.originName || source.originName;
    target.group = source.group;
    target.order = source.order;
    target.originOrder = source.originOrder;
    target.durChapterIndex = source.durChapterIndex;
    target.durChapterPos = source.durChapterPos;
    target.durChapterTitle = source.durChapterTitle;
    target.durChapterTime = source.durChapterTime;
    target.readConfig = source.readConfig;
    target.syncTime = source.syncTime;
    this.preserveVariableTime(target, source, 'lastReadTime');
  }

  private preserveVariableTime(target: Book, source: Book, key: string): void {
    const sourceTime = this.parsePositiveTime(source.getVariable(key));
    const targetTime = this.parsePositiveTime(target.getVariable(key));
    if (sourceTime > targetTime) {
      target.putVariable(key, `${sourceTime}`);
    }
  }

  private parsePositiveTime(value: string): number {
    const time = Number(value);
    return time > 0 ? time : 0;
  }

  private isBrokenChapterUrl(url: string): boolean {
    if (!url) return true;
    if (url.includes('@get:') || url.includes('{{')) return true;
    if (url.includes('@js:') || url.includes('java.')) return true;
    if (url.startsWith('data:')) return false;
    if (!url.startsWith('http://') && !url.startsWith('https://')) return true;
    return /https?:\/\/[^/]+\/{2,}/.test(url);
  }

  async loadContent(idx: number): Promise<string> {
    if (idx < 0 || idx >= this.chapters.length || !this.book) return '';

    this.curIdx = idx;
    this.preloadGeneration++;
    return await this.fetchContent(idx);
  }

  async peekContent(idx: number): Promise<string> {
    if (idx < 0 || idx >= this.chapters.length || !this.book) return '';

    return await this.fetchContent(idx);
  }

  getCachedContent(idx: number): string {
    if (idx < 0 || idx >= this.chapters.length) return '';

    return this.chapterCache.get(idx) || '';
  }

  async reloadContent(idx: number): Promise<string> {
    if (idx < 0 || idx >= this.chapters.length || !this.book) return '';

    this.curIdx = idx;
    if (this.book.origin === 'local') {
      this.chapterCache.delete(idx);
      this.chapterLoading.delete(idx);
      return await this.fetchContent(idx);
    }
    this.chapterCache.delete(idx);
    this.chapterLoading.delete(idx);
    await appDb.deleteCachedChapterContent(this.book.bookUrl, idx);
    const chapter = this.chapters[idx];
    if (chapter) {
      chapter.cacheDate = 0;
    }
    return await this.fetchContent(idx);
  }

  private async fetchContent(idx: number): Promise<string> {
    if (idx < 0 || idx >= this.chapters.length || !this.book) return '';

    const generation = this.bookGeneration;
    const sessionBook = this.book;
    const sessionBookUrl = sessionBook.bookUrl;
    const chapter = this.chapters[idx];
    if (this.chapterCache.has(idx)) {
      const memoryContent = this.chapterCache.get(idx)!;
      this.chapterCache.delete(idx);
      this.chapterCache.set(idx, memoryContent);
      return memoryContent;
    }
    if (this.chapterLoading.has(idx)) return await this.chapterLoading.get(idx)!;

    const cached = await appDb.getCachedChapterContent(sessionBookUrl, idx);
    if (!this.isCurrentBookSession(generation, sessionBookUrl)) return '';
    if (cached && !this.isInvalidChapterContent(cached)) {
      this.putChapterCache(idx, cached);
      chapter.cacheDate = chapter.cacheDate || Date.now();
      return cached;
    }

    if (this.book.origin === 'local') {
      let task: Promise<string>;
      task = LocalChapterContentLoader.load(sessionBook, chapter)
        .then((text: string) => {
          if (!this.isCurrentBookSession(generation, sessionBookUrl)) return '';
          if (!text) return text;
          this.putChapterCache(idx, text);
          chapter.cacheDate = Date.now();
          appDb.saveCachedChapterContent(sessionBookUrl, chapter, text).catch((err: Error) => {
            console.error('[RE] save local chapter cache failed:', idx, err);
          });
          return text;
        })
        .finally(() => {
          if (this.chapterLoading.get(idx) === task) this.chapterLoading.delete(idx);
        });
      this.chapterLoading.set(idx, task);
      return await task;
    }

    if (!this.source) return '';

    await this.refreshSourceForContent(generation, sessionBookUrl);
    if (!this.isCurrentBookSession(generation, sessionBookUrl) || !this.source) return '';
    const sessionSource = this.source;
    let task: Promise<string>;
    task = this.webBook.getContent(sessionSource, sessionBook, chapter)
      .then((text: string) => {
        if (!this.isCurrentBookSession(generation, sessionBookUrl)) return '';
        if (text && !this.isInvalidChapterContent(text)) {
          this.putChapterCache(idx, text);
          chapter.cacheDate = Date.now();
          appDb.saveCachedChapterContent(sessionBookUrl, chapter, text).catch((err: Error) => {
            console.error('[RE] save chapter cache failed:', idx, err);
          });
        }
        return text;
      })
      .finally(() => {
        if (this.chapterLoading.get(idx) === task) this.chapterLoading.delete(idx);
      });
    this.chapterLoading.set(idx, task);
    return await task;
  }

  private async refreshSourceForContent(expectedGeneration: number = this.bookGeneration,
    expectedBookUrl: string = this.book?.bookUrl || ''): Promise<void> {
    if (!this.book || !this.source || !this.book.origin || this.book.origin === 'local') {
      return;
    }
    const origin = this.book.origin;
    const latestSource = await appDb.getBookSource(origin);
    if (latestSource && this.isCurrentBookSession(expectedGeneration, expectedBookUrl)) {
      this.source = latestSource;
    }
  }

  hasCachedContent(idx: number): boolean {
    return this.chapterCache.has(idx);
  }

  private isInvalidChapterContent(text: string): boolean {
    if (!text) return false;
    return ReaderActionMarker.hasLegacy(text) || text.includes('免登录访问次数已达上限') || text.includes('继续阅读请登录') ||
      text.includes('请登录后刷新') || text.includes('今日免登录访问次数') ||
      text.includes('当前书源需要登录') || text.includes('该书源需要先完成网页验证') ||
      text.includes('登录信息已失效') || text.includes('账号信息异常') ||
      text.includes('请重新登录') || text.includes('请重新登陆') ||
      text.includes('JSON.parse(undefined)') || text.includes('企点正文接口返回异常') ||
      text.includes('企点正文暂时不可用') || text.includes('请先在企点书源登录面板') ||
      text.includes('访问速度过快') || text.includes('普通用户限制') ||
      text.includes('升级VIP可享受不限速访问');
  }

  async cacheChapter(idx: number): Promise<boolean> {
    const text = await this.fetchContent(idx);
    return !!text;
  }

  async syncChapterCacheDates(expectedGeneration: number = this.bookGeneration,
    expectedBookUrl: string = this.book?.bookUrl || ''): Promise<void> {
    if (!this.book || this.chapters.length === 0) {
      return;
    }
    const cacheDates = await appDb.getBookChapterCacheDateMap(expectedBookUrl);
    if (!this.isCurrentBookSession(expectedGeneration, expectedBookUrl)) return;
    for (const chapter of this.chapters) {
      chapter.cacheDate = cacheDates.get(chapter.index) || 0;
    }
  }

  clearCurrentBookMemoryCache(): void {
    this.chapterCache.clear();
    this.chapterLoading.clear();
    for (const chapter of this.chapters) {
      chapter.cacheDate = 0;
    }
    this.content = '';
    this.preloadGeneration++;
  }

  async refreshSourceInteractionState(): Promise<boolean> {
    if (!this.book || !this.source || !this.book.origin || this.book.origin === 'local') return false;
    const generation = this.bookGeneration;
    const sessionBook = this.book;
    const sessionBookUrl = sessionBook.bookUrl;
    const latestSource = await appDb.getBookSource(sessionBook.origin);
    if (!this.isCurrentBookSession(generation, sessionBookUrl)) return false;
    if (!latestSource) return false;
    const nextIdentity = this.buildSourceInteractionIdentity(latestSource);
    this.source = latestSource;
    if (nextIdentity === this.sourceInteractionIdentity) return false;
    this.sourceInteractionIdentity = nextIdentity;
    this.chapterCache.clear();
    this.chapterLoading.clear();
    this.content = '';
    this.preloadGeneration++;
    await appDb.deleteBookCachedContent(sessionBookUrl);
    if (!this.isCurrentBookSession(generation, sessionBookUrl)) return false;
    sessionBook.putVariable(ReadBookEngine.SOURCE_INTERACTION_IDENTITY_KEY, nextIdentity);
    await appDb.updateBook(sessionBook, false);
    if (!this.isCurrentBookSession(generation, sessionBookUrl)) return false;
    console.info('[RE] source interaction settings changed, chapter cache cleared:',
      this.source.bookSourceName);
    return true;
  }

  private async initializeSourceInteractionIdentity(expectedGeneration: number = this.bookGeneration,
    expectedBook: Book | null = this.book): Promise<void> {
    if (!expectedBook || !this.source || expectedBook.origin === 'local') {
      this.sourceInteractionIdentity = '';
      return;
    }
    const expectedBookUrl = expectedBook.bookUrl;
    const nextIdentity = this.buildSourceInteractionIdentity(this.source);
    const storedIdentity = expectedBook.getVariable(ReadBookEngine.SOURCE_INTERACTION_IDENTITY_KEY);
    this.sourceInteractionIdentity = nextIdentity;
    if (storedIdentity === nextIdentity) return;
    await appDb.deleteBookCachedContent(expectedBookUrl);
    if (!this.isCurrentBookSession(expectedGeneration, expectedBookUrl)) return;
    expectedBook.putVariable(ReadBookEngine.SOURCE_INTERACTION_IDENTITY_KEY, nextIdentity);
    await appDb.updateBook(expectedBook, false);
    if (!this.isCurrentBookSession(expectedGeneration, expectedBookUrl)) return;
    console.info('[RE] source interaction cache identity initialized:', this.source.bookSourceName);
  }

  private buildSourceInteractionIdentity(source: BookSource): string {
    const raw = BookSourceInteractionPostProcessor.interactionCacheIdentity(source);
    if (!raw) return '';
    let hash = 2166136261;
    for (let index = 0; index < raw.length; index++) {
      hash ^= raw.charCodeAt(index);
      hash = Math.imul(hash, 16777619);
    }
    return `${source.bookSourceUrl || ''}:${(hash >>> 0).toString(16)}`;
  }

  preloadAround(idx: number, forwardCount: number = 2, backwardCount: number = 1): void {
    if (this.chapters.length === 0 || !this.book) {
      return;
    }
    const generation = ++this.preloadGeneration;
    for (let offset = 1; offset <= forwardCount; offset++) {
      this.schedulePreloadContent(idx + offset, idx, generation, offset * 80);
    }
    for (let offset = 1; offset <= backwardCount; offset++) {
      this.schedulePreloadContent(idx - offset, idx, generation, (forwardCount + offset) * 80);
    }
  }

  private schedulePreloadContent(idx: number, anchorIndex: number, generation: number, delayMs: number): void {
    setTimeout(() => {
      if (generation !== this.preloadGeneration || this.curIdx !== anchorIndex) return;
      this.preloadContent(idx);
    }, Math.max(0, delayMs));
  }

  private preloadContent(idx: number): void {
    if (idx < 0 || idx >= this.chapters.length) {
      return;
    }
    if (this.chapterCache.has(idx) || this.chapterLoading.has(idx)) {
      return;
    }
    this.fetchContent(idx).catch((err: Error) => {
      console.error('[RE] preload chapter failed:', idx, err);
    });
  }

  async loadNextChapter(): Promise<string> {
    if (this.curIdx < this.chapters.length - 1) {
      this.curIdx++;
      return this.loadContent(this.curIdx);
    }
    return '';
  }

  async loadPrevChapter(): Promise<string> {
    if (this.curIdx > 0) {
      this.curIdx--;
      return this.loadContent(this.curIdx);
    }
    return '';
  }

  async saveProgress(): Promise<void> {
    if (!this.book) return;
    if (!Book.hasStartedReading(this.book) && this.curIdx <= 0 && this.curPos <= 0) {
      return;
    }
    const now = Date.now();
    this.book.durChapterIndex = this.curIdx;
    this.book.durChapterPos = this.curPos;
    this.book.durChapterTime = now;
    this.book.putVariable('readStarted', '1');
    this.book.putVariable('lastReadTime', `${now}`);
    await appDb.updateBook(this.book);
  }

  private putChapterCache(idx: number, content: string): void {
    if (!content) return;
    this.chapterCache.delete(idx);
    this.chapterCache.set(idx, content);
    while (this.chapterCache.size > this.chapterCacheLimit) {
      let evicted = false;
      const keys = this.chapterCache.keys();
      let next = keys.next();
      while (!next.done) {
        const key = next.value as number;
        if (key !== this.curIdx) {
          this.chapterCache.delete(key);
          evicted = true;
          break;
        }
        next = keys.next();
      }
      if (!evicted) break;
    }
  }

  getChapterTitle(): string {
    const c = this.chapters[this.curIdx];
    return c ? c.title : '';
  }
}
