import { Book, BookChapter, BookSource } from '../../model/data/Book';
import { HttpClient } from '../http/HttpClient';
import { AnalyzeUrl } from '../rule/AnalyzeUrl';
import { AnalyzeRule } from '../rule/AnalyzeRule';
import { RuleContext } from '../rule/RuleContext';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { VerificationSupport } from '../http/VerificationSupport';
import { EncodedSourceUrl } from './EncodedSourceUrl';
import { BookSourceDataUrlSupport } from './BookSourceDataUrlSupport';
import { BookUrlResolver } from './BookUrlResolver';
import { BookFieldSanitizer } from '../../utils/BookFieldSanitizer';
import { AjaxRuleCompat } from '../rule/AjaxRuleCompat';
import { ReaderImageMarker } from './ReaderImageMarker';
import { JsRuntime } from '../rule/JsRuntime';
import { ScriptEngine, ScriptEngineContext } from '../rule/ScriptEngine';
import { ComicImagePipeline } from './ComicImagePipeline';
import { BookSourceRuntimeRouter, SourceRuntimeStage } from './BookSourceRuntimeRouter';
import { BookSourceStageWebRuntime, StageWebRuntimeRequest } from './BookSourceStageWebRuntime';
import { ReaderActionMarker } from './ReaderActionMarker';
import { BookSourceInteractionPostProcessor } from './BookSourceInteractionPostProcessor';
import { CookieStore } from '../http/CookieStore';

class ContentPageData {
  content: string = '';
  nextUrl: string = '';
}

class QtqdContentData {
  handled: boolean = false;
  audio: boolean = false;
  content: string = '';
}

export class WebBookService {
  private http: HttpClient;

  constructor() {
    this.http = new HttpClient(10000);
  }

  async getBookInfo(source: BookSource, book: Book): Promise<Book> {
    if (BookSourceDataUrlSupport.isEncodedSource(book.bookUrl)) {
      return await BookSourceDataUrlSupport.getBookInfo(this.http, source, book);
    }
    const sourceApiBook = await this.tryGetSourceApiBookInfo(source, book);
    if (sourceApiBook) return sourceApiBook;
    console.log('[WS] getBookInfo, URL:', book.bookUrl);
    const au = new AnalyzeUrl(source, this.http);
    const resp = EncodedSourceUrl.canHandle(book.bookUrl) ?
      await this.fetchEncodedDataUrl(book.bookUrl, source) : await au.fetch(book.bookUrl);
    console.log('[WS] getBookInfo resp:', resp.success, 'len:', resp.body.length);
    if (this.requestVerificationIfNeeded(source, book.bookUrl, resp.body, resp.statusCode, source.bookInfoRule.init)) {
      return book;
    }
    if (!resp.success || !resp.body) return book;
    const baseUrl = BookUrlResolver.effectiveBase(resp, book.bookUrl, source.bookSourceUrl);

    const ctx = new RuleContext();
    ctx.loadFromJson(book.variable);
    this.seedBookVariables(ctx, book.bookUrl);

    // init 规则
    let content = resp.body;
    const infoRule = source.bookInfoRule;
    if (infoRule.init) {
      let initResult = await this.runStageRule(source, book, infoRule.init, content, baseUrl,
        SourceRuntimeStage.BOOK_INFO);
      if (!initResult) {
        const ir = new AnalyzeRule(content, baseUrl, ctx);
        this.seedSourceVariables(ctx, source);
        initResult = ir.getString(infoRule.init);
      }
      if (initResult) content = initResult;
    }

    const ir = new AnalyzeRule(content, baseUrl, ctx);
    this.seedSourceVariables(ctx, source);
    book.name = await this.getBookInfoFieldValue(source, book, ir, infoRule.name, content, baseUrl) || book.name;
    book.author = await this.getBookInfoFieldValue(source, book, ir, infoRule.author, content, baseUrl) || book.author;
    const infoCoverUrl = BookSourceDataUrlSupport.normalizeCoverUrl(source,
      await this.getBookInfoFieldValue(source, book, ir, infoRule.coverUrl, content, baseUrl), baseUrl);
    book.coverUrl = book.coverUrl || infoCoverUrl;
    book.intro = BookFieldSanitizer.prefer(
      await this.getBookInfoFieldValue(source, book, ir, infoRule.intro, content, baseUrl), book.intro);
    book.kind = BookFieldSanitizer.prefer(
      await this.getBookInfoFieldValue(source, book, ir, infoRule.kind, content, baseUrl), book.kind);
    book.latestChapterTitle = BookFieldSanitizer.prefer(
      await this.getBookInfoFieldValue(source, book, ir, infoRule.lastChapter, content, baseUrl),
      book.latestChapterTitle);
    book.wordCount = BookFieldSanitizer.prefer(
      await this.getBookInfoFieldValue(source, book, ir, infoRule.wordCount, content, baseUrl), book.wordCount);

    const tocUrl = await this.getBookInfoFieldValue(source, book, ir, infoRule.tocUrl, content, baseUrl, true);
    if (tocUrl) book.tocUrl = this.repairUrlWithBookId(tocUrl, book.bookUrl);

    // 保存变量
    book.variable = ctx.toJson();

    // 如果 tocUrl 为空，尝试从 bookUrl 构造
    if (!book.tocUrl) {
      book.tocUrl = this.fallbackTocUrl(book.bookUrl, infoRule.tocUrl, baseUrl);
    }

    return book;
  }

  private fallbackTocUrl(bookUrl: string, tocRule: string, baseUrl: string): string {
    // 从 bookUrl 提取 novelId
    let novelId = this.extractQueryParam(bookUrl, 'book_id') || this.extractQueryParam(bookUrl, 'bookid') ||
      this.extractQueryParam(bookUrl, 'bookId') || this.extractQueryParam(bookUrl, 'id');
    const segs = bookUrl.replace(/\?.*$/, '').split('/').filter(s => s.length > 0);
    if (!novelId) {
      for (let i = segs.length - 1; i >= 0; i--) {
        if (segs[i].match(/^[a-zA-Z0-9_-]{3,40}$/)) { novelId = segs[i]; break; }
      }
    }
    if (!novelId || !tocRule) return bookUrl;
    const url = tocRule
      .replace(/\{\{\s*\$\.\.?\w+\s*\}\}/g, novelId)
      .replace(/\{\{\s*\w+\s*\}\}/g, novelId);
    if (url.startsWith('http')) return url;
    return BookUrlResolver.resolve(url, baseUrl);
  }

  private resolveTocUrl(source: BookSource, book: Book): string {
    const current = book.tocUrl || book.bookUrl;
    const fanqieUrl = this.buildFanqieDirectoryUrl(source, book);
    if (!fanqieUrl) return current;
    if (!current || this.isBookInfoUrl(current) || this.isBadFanqieDirectoryUrl(current)) {
      book.tocUrl = fanqieUrl;
      return fanqieUrl;
    }
    return current;
  }

  private buildFanqieDirectoryUrl(source: BookSource, book: Book): string {
    const chapterListRule = source.tocRule?.chapterList || '';
    const infoTocRule = source.bookInfoRule?.tocUrl || '';
    if (!chapterListRule.includes('chapterListWithVolume') && !infoTocRule.includes('fanqienovel.com/api/reader/directory/detail')) {
      return '';
    }
    const id = this.extractQueryParam(book.tocUrl || '', 'bookId') || this.extractQueryParam(book.tocUrl || '', 'book_id') ||
      this.extractQueryParam(book.bookUrl || '', 'book_id') || this.extractQueryParam(book.bookUrl || '', 'bookId') ||
      this.extractQueryParam(book.bookUrl || '', 'id') || this.extractBookId(book.bookUrl || '');
    if (!id) return '';
    return `https://fanqienovel.com/api/reader/directory/detail?bookId=${encodeURIComponent(id)}`;
  }

  private isBookInfoUrl(url: string): boolean {
    if (!url) return false;
    return /\/info(?:[?#]|$)/.test(url) && (!!this.extractQueryParam(url, 'book_id') || !!this.extractQueryParam(url, 'bookId'));
  }

  private isBadFanqieDirectoryUrl(url: string): boolean {
    if (!url.includes('fanqienovel.com/api/reader/directory/detail')) return false;
    const bookId = this.extractQueryParam(url, 'bookId') || this.extractQueryParam(url, 'book_id');
    return !bookId || bookId.includes('{{') || bookId.includes('$');
  }

  private repairUrlWithBookId(url: string, bookUrl: string): string {
    if (!url || !bookUrl) return url;
    if (!url.includes('/book/chapters') && !url.includes('/book//')) return url;
    const bookId = this.extractBookId(bookUrl);
    if (!bookId) return url;

    return url
      .replace(/\/{2,}/g, '/')
      .replace(/^http:\//, 'http://')
      .replace(/^https:\//, 'https://')
      .replace(/\/book\/chapters/g, `/book/${bookId}/chapters`)
      .replace(/\/book\/\//g, `/book/${bookId}/`);
  }

  private extractBookId(bookUrl: string): string {
    const clean = bookUrl.replace(/\?.*$/, '');
    const match = clean.match(/\/book\/([^/]+)$/);
    if (match) return match[1];

    const segs = clean.split('/').filter(s => s.length > 0);
    for (let i = segs.length - 1; i >= 0; i--) {
      if (/^[a-zA-Z0-9_-]{3,40}$/.test(segs[i])) return segs[i];
    }
    return '';
  }

  async getChapterList(source: BookSource, book: Book): Promise<BookChapter[]> {
    AppStorage.setOrCreate('bookSourceStageLastError', '');
    if (BookSourceDataUrlSupport.isEncodedSource(book.tocUrl) || BookSourceDataUrlSupport.isEncodedSource(book.bookUrl)) {
      return await BookSourceDataUrlSupport.getChapterList(this.http, source, book);
    }
    const qtqdChapters = await this.tryBuildQtqdChapterList(source, book);
    if (qtqdChapters.length > 0) return qtqdChapters;
    const sourceApiChapters = await this.tryBuildSourceApiChapterList(source, book);
    if (sourceApiChapters.length > 0) return sourceApiChapters;
    console.log('[WS] getChapterList, tocUrl:', book.tocUrl);
    const tocUrl = this.resolveTocUrl(source, book);
    const au = new AnalyzeUrl(source, this.http);
    let resp = EncodedSourceUrl.canHandle(tocUrl) ?
      await this.fetchEncodedDataUrl(tocUrl, source) : await au.fetch(tocUrl);
    if ((resp.statusCode >= 400 || !resp.success || !resp.body) && this.shouldFallbackChaoxingToc(source, tocUrl, book.bookUrl)) {
      console.warn('[WS] Chaoxing toc api failed, fallback to detail page:', tocUrl);
      resp = await au.fetch(book.bookUrl);
    }
    if (!resp.success || !resp.body) return [];
    const ctx = new RuleContext();
    ctx.loadFromJson(book.variable);
    this.seedBookVariables(ctx, book.bookUrl);
    this.seedSourceVariables(ctx, source);
    const tocRule = source.tocRule;
    const chapters: BookChapter[] = [];
    const seenChapterUrls = new Set<string>();
    const seenPageUrls = new Set<string>();
    let currentUrl = resp.url || tocUrl;
    let currentResp = resp;
    let firstBody = resp.body;
    let firstBaseUrl = BookUrlResolver.effectiveBase(resp, tocUrl, book.bookUrl || source.bookSourceUrl);
    for (let page = 0; page < 100; page++) {
      if (!currentResp.success || !currentResp.body) break;
      const pageKey = this.urlWithoutFragment(currentResp.url || currentUrl);
      if (seenPageUrls.has(pageKey)) break;
      seenPageUrls.add(pageKey);
      if (this.requestVerificationIfNeeded(source, currentUrl, currentResp.body, currentResp.statusCode, tocRule.chapterList)) {
        break;
      }
      const baseUrl = BookUrlResolver.effectiveBase(currentResp, currentUrl, book.bookUrl || source.bookSourceUrl);
      if (page === 0) {
        firstBody = currentResp.body;
        firstBaseUrl = baseUrl;
        const runtimeInput = this.stageDataUrlInput(tocRule.chapterList, currentUrl, currentResp.body);
        const runtimeList = await this.runStageRule(source, book, tocRule.chapterList,
          runtimeInput, baseUrl, SourceRuntimeStage.TOC);
        if (runtimeList) {
          const runtimeChapters = this.parseStageChapterList(source, book, runtimeList, baseUrl);
          if (runtimeChapters.length > 0) {
            return runtimeChapters;
          }
          AppStorage.setOrCreate('bookSourceStageLastError',
            `目录脚本已返回内容，但没有转换出章节（返回 ${runtimeList.length} 字符）`);
        } else if (this.stageRuleCode(tocRule.chapterList || '')) {
          const lastError = AppStorage.get<string>('bookSourceStageLastError') || '';
          if (!lastError) AppStorage.setOrCreate('bookSourceStageLastError', '目录脚本返回空结果');
        }
        const specialChapters = await this.tryBuildSpecialChapterList(source, book, currentResp.body);
        if (specialChapters.length > 0) {
          book.variable = ctx.toJson();
          return specialChapters;
        }
      }
      const pageChapters = this.parseChapterPage(source, book, currentResp.body, baseUrl, ctx, chapters.length);
      for (const chapter of pageChapters) {
        const chapterKey = this.urlWithoutFragment(chapter.url);
        if (seenChapterUrls.has(chapterKey)) continue;
        seenChapterUrls.add(chapterKey);
        chapter.index = chapters.length;
        chapters.push(chapter);
      }
      if (!tocRule.nextTocUrl) break;
      const pageRule = new AnalyzeRule(currentResp.body, baseUrl, ctx);
      const nextUrl = pageRule.getString(tocRule.nextTocUrl, true);
      const nextKey = this.urlWithoutFragment(nextUrl);
      if (!nextUrl || seenPageUrls.has(nextKey)) break;
      currentUrl = nextUrl;
      currentResp = EncodedSourceUrl.canHandle(currentUrl) ?
        await this.fetchEncodedDataUrl(currentUrl, source) : await au.fetch(currentUrl);
    }

    book.variable = ctx.toJson();
    if (chapters.length > 0) return chapters;

    const chaoxingDetailChapter = this.tryBuildChaoxingDetailChapter(source, book, firstBody, firstBaseUrl);
    if (chaoxingDetailChapter.length > 0) return chaoxingDetailChapter;

    const fallbackChapters = this.tryBuildGenericChapterList(book, firstBody, firstBaseUrl);
    if (fallbackChapters.length > 0) return fallbackChapters;
    return chapters;
  }

  private parseChapterPage(source: BookSource, book: Book, body: string, baseUrl: string,
    ctx: RuleContext, startIndex: number): BookChapter[] {
    const tocRule = source.tocRule;
    const rule = new AnalyzeRule(body, baseUrl, ctx);
    const items = rule.getElements(tocRule.chapterList || '');
    console.log('[WS] getChapterList page items:', items.length, 'from resp:', body.length);
    const chapters: BookChapter[] = [];
    for (let i = 0; i < items.length; i++) {
      const ir = new AnalyzeRule(items[i], baseUrl, ctx);
      this.seedSourceVariables(ctx, source);
      const chap = new BookChapter();
      chap.title = this.cleanChapterTitle(ir.getString(tocRule.chapterName) || `第${startIndex + i + 1}章`);
      let rawUrl = ir.getString(tocRule.chapterUrl);
      if (rawUrl && (rawUrl.startsWith('@js:') || rawUrl.includes('$..') || rawUrl.includes('$.'))) {
        const repairedUrl = ir.getString(tocRule.chapterUrl, true);
        if (repairedUrl && !repairedUrl.includes('@js:') && !repairedUrl.includes('$..') && !repairedUrl.includes('$.')) {
          rawUrl = repairedUrl;
        }
      }
      if (rawUrl && (rawUrl.startsWith('@js:') || rawUrl.includes('$..') || rawUrl.includes('$.'))) {
        let itemData: Record<string, Object> | null = null;
        try { itemData = JSON.parse(items[i]) as Record<string, Object>; } catch (_) {}
        let tocData: Record<string, Object> | null = null;
        try { tocData = JSON.parse(body) as Record<string, Object>; } catch (_) {}
        rawUrl = rawUrl.replace(/^@js:\s*/, '').replace(/\s*,\s*\{[^}]*\}\s*$/, '');
        rawUrl = rawUrl.replace(/\$\.\.(\w+)/g, (_: string, key: string) => {
          return this.resolveJsonKey(itemData, tocData, key, true) || '';
        });
        rawUrl = rawUrl.replace(/\$\.(\w+)/g, (_: string, key: string) => {
          return this.resolveJsonKey(itemData, tocData, key, false) || '';
        });
        rawUrl = rawUrl.replace(/\s*\+\s*/g, '').replace(/^['"]|['"]$/g, '').trim();
      }
      const resolvedChapterUrl = this.resolveVars(BookUrlResolver.resolve(rawUrl, baseUrl), ctx);
      chap.url = this.normalizeChaoxingUrl(source, this.repairUrlWithBookId(resolvedChapterUrl, book.bookUrl));
      chap.bookUrl = book.bookUrl;
      chap.index = startIndex + i;
      chap.isVip = ir.getString(tocRule.isVip) === 'true';
      chap.variable = BookUrlResolver.setVariableJson(chap.variable, 'baseUrl', baseUrl);
      if (chap.title && chap.url) chapters.push(chap);
    }
    return chapters;
  }

  async getContent(source: BookSource, book: Book, chapter: BookChapter): Promise<string> {
    const qtqdContent = await this.tryGetQtqdContent(source, book, chapter);
    if (qtqdContent.handled) {
      if (qtqdContent.audio) return qtqdContent.content.trim();
      const interactiveContent = await BookSourceInteractionPostProcessor.process(source, book, chapter,
        qtqdContent.content);
      const qtqdContext = new RuleContext();
      qtqdContext.loadFromJson(book.variable);
      this.seedBookVariables(qtqdContext, book.bookUrl);
      this.seedSourceVariables(qtqdContext, source);
      this.seedChapterVariables(qtqdContext, chapter);
      return await this.normalizeReaderContent(source,
        this.applyContentReplaceRule(interactiveContent, source.contentRule.replaceRegex, qtqdContext, chapter),
        this.getChapterBaseUrl(chapter, book, source));
    }
    const sourceApiContent = await this.tryGetSourceApiContent(source, book, chapter);
    if (sourceApiContent.handled) {
      if (sourceApiContent.audio) return sourceApiContent.content.trim();
      const interactiveContent = await BookSourceInteractionPostProcessor.process(source, book, chapter,
        sourceApiContent.content);
      const sourceApiContext = new RuleContext();
      sourceApiContext.loadFromJson(book.variable);
      this.seedBookVariables(sourceApiContext, book.bookUrl);
      this.seedSourceVariables(sourceApiContext, source);
      this.seedChapterVariables(sourceApiContext, chapter);
      return await this.normalizeReaderContent(source,
        this.applyContentReplaceRule(interactiveContent, source.contentRule.replaceRegex, sourceApiContext, chapter),
        chapter.url || book.tocUrl || book.bookUrl || source.bookSourceUrl);
    }
    if (BookSourceDataUrlSupport.isEncodedSource(chapter.url)) {
      const shortcutContent = await BookSourceDataUrlSupport.getContent(this.http, source, book, chapter);
      const shortcutAudio = source.bookSourceType === 1 || (Number(book.type) & 32) !== 0;
      if (!shortcutContent || shortcutAudio) return shortcutContent.trim();
      const interactiveContent = await BookSourceInteractionPostProcessor.process(source, book, chapter,
        shortcutContent);
      const shortcutContext = new RuleContext();
      shortcutContext.loadFromJson(book.variable);
      this.seedBookVariables(shortcutContext, book.bookUrl);
      this.seedSourceVariables(shortcutContext, source);
      this.seedChapterVariables(shortcutContext, chapter);
      return await this.normalizeReaderContent(source,
        this.applyContentReplaceRule(interactiveContent, source.contentRule.replaceRegex, shortcutContext, chapter),
        chapter.url || book.bookUrl || source.bookSourceUrl);
    }
    const isAudioContent = source.bookSourceType === 1 || (Number(book.type) & 32) !== 0;
    if (isAudioContent && !source.contentRule.content &&
      /\.(?:aac|flac|m3u8|m4a|mp3|mp4|ogg|opus|wav)(?:[?#]|$)/i.test(chapter.url)) {
      return BookUrlResolver.resolve(chapter.url, book.bookUrl || source.bookSourceUrl);
    }
    const stageContent = await this.tryGetStageContent(source, book, chapter);
    if (stageContent) {
      if (isAudioContent) return stageContent.trim();
      return await this.normalizeReaderContent(source,
        this.applyContentReplaceRule(stageContent, source.contentRule.replaceRegex,
          new RuleContext(), chapter), chapter.url);
    }
    const normalizedContentUrl = this.normalizeChaoxingUrl(source, chapter.url);
    if (normalizedContentUrl !== chapter.url) {
      chapter.url = normalizedContentUrl;
    }
    console.log('[WS] getContent, url:', chapter.url);
    const specialContent = await this.tryGetSpecialContent(source, chapter);
    if (specialContent) {
      const specialCtx = new RuleContext();
      specialCtx.loadFromJson(book.variable);
      this.seedBookVariables(specialCtx, book.bookUrl);
      this.seedSourceVariables(specialCtx, source);
      this.seedChapterVariables(specialCtx, chapter);
      return await this.normalizeReaderContent(source,
        this.applyContentReplaceRule(specialContent, source.contentRule.replaceRegex, specialCtx, chapter), chapter.url);
    }
    const au = new AnalyzeUrl(source, this.http);
    let resp = EncodedSourceUrl.canHandle(chapter.url) ?
      await this.fetchEncodedDataUrl(chapter.url, source) : await au.fetch(chapter.url);
    if ((!resp.success || !resp.body) && this.shouldRetryChaoxingHttps(source, chapter.url)) {
      const httpsUrl = this.normalizeChaoxingUrl(source, chapter.url);
      console.warn('[WS] Chaoxing content http failed, retry https:', httpsUrl);
      resp = await au.fetch(httpsUrl);
      chapter.url = httpsUrl;
    }
    console.log('[WS] getContent resp:', resp.success, 'len:', resp.body.length);
    if (!resp.success || !resp.body) return '';
    const ctx = new RuleContext();
    ctx.loadFromJson(book.variable);
    this.seedBookVariables(ctx, book.bookUrl);
    this.seedSourceVariables(ctx, source);
    this.seedChapterVariables(ctx, chapter);
    const contentRule = source.contentRule;
    const parts: string[] = [];
    const seenPageUrls = new Set<string>();
    let currentUrl = resp.url || chapter.url;
    let currentResp = resp;
    let totalLength = 0;
    for (let page = 0; page < 50; page++) {
      if (!currentResp.success || !currentResp.body) break;
      const pageKey = this.urlWithoutFragment(currentResp.url || currentUrl);
      if (seenPageUrls.has(pageKey)) break;
      seenPageUrls.add(pageKey);
      if (this.requestVerificationIfNeeded(source, currentUrl, currentResp.body, currentResp.statusCode, contentRule.content)) {
        break;
      }
      const baseUrl = BookUrlResolver.effectiveBase(currentResp,
        page === 0 ? this.getChapterBaseUrl(chapter, book, source) : currentUrl,
        book.bookUrl || source.bookSourceUrl);
      const pageData = await this.parseContentPage(source, book, chapter, currentResp.body, baseUrl, ctx);
      if (pageData.content) {
        totalLength += pageData.content.length;
        if (totalLength > 8 * 1024 * 1024) break;
        parts.push(pageData.content);
      }
      if (!contentRule.nextContentUrl || !pageData.nextUrl) break;
      const nextKey = this.urlWithoutFragment(pageData.nextUrl);
      if (seenPageUrls.has(nextKey)) break;
      currentUrl = pageData.nextUrl;
      currentResp = EncodedSourceUrl.canHandle(currentUrl) ?
        await this.fetchEncodedDataUrl(currentUrl, source) : await au.fetch(currentUrl);
    }
    book.variable = ctx.toJson();
    return parts.join('\n\n');
  }

  private async parseContentPage(source: BookSource, book: Book, chapter: BookChapter, body: string,
    baseUrl: string, ctx: RuleContext): Promise<ContentPageData> {
    const data = new ContentPageData();
    const rule = new AnalyzeRule(body, baseUrl, ctx);
    const contentRule = source.contentRule;
    const isAudioContent = source.bookSourceType === 1 || (Number(book.type) & 32) !== 0;
    if (contentRule.nextContentUrl) {
      data.nextUrl = rule.getString(contentRule.nextContentUrl, true);
    }
    let imageRuleValues = contentRule.images ? rule.getStringList(contentRule.images) : [];
    if (imageRuleValues.length === 0) {
      imageRuleValues = this.tryExtractScriptedComicImages(body);
    }
    let content = await this.tryGetDirectAjaxRuleContent(source, body, baseUrl, ctx, contentRule.content);
    if (!content) content = rule.getString(contentRule.content);
    // Audio rules return a media address (or JSON/HTML containing one), not reader text.
    // Preserve that value so the audio page can resolve relative, escaped and tagged URLs.
    if (isAudioContent) {
      if (!content) return data;
      data.content = this.applyContentReplaceRule(content, contentRule.replaceRegex, ctx, chapter).trim();
      return data;
    }
    if (!content || this.isBadExtractedContent(content)) {
      const fallbackContent = this.tryExtractReadableContentFromHtml(body);
      if (fallbackContent) content = fallbackContent;
    }
    if ((!content || this.isBadExtractedContent(content)) && this.isChaoxingSource(source, chapter.url)) {
      const chaoxingContent = this.tryExtractChaoxingDetailContent(book, body);
      if (chaoxingContent) content = chaoxingContent;
    }
    if (!content && imageRuleValues.length === 0) return data;
    content = this.applyContentReplaceRule(content, contentRule.replaceRegex, ctx, chapter);
    data.content = await this.normalizeReaderContent(source, content, baseUrl, imageRuleValues);
    return data;
  }

  /**
   * Some lightweight comic sites create their image tags in an inline script
   * instead of including them in the returned HTML.  The common shape is a
   * base path plus a page count.  Supporting that shape here avoids executing
   * arbitrary imported JavaScript while still allowing the chapter to stream
   * through the normal reader image pipeline.
   */
  private tryExtractScriptedComicImages(body: string): string[] {
    if (!body) return [];
    const pathMatch = body.match(/\b(?:pasd|imagePath|image_path)\s*=\s*["']([^"']+)["']/i);
    const countMatch = body.match(/\b(?:num|imageCount|image_count)\s*=\s*(?:eval\s*\(\s*)?["']?(\d{1,4})/i);
    if (!pathMatch || !pathMatch[1] || !countMatch || !countMatch[1]) return [];

    const count = Math.min(parseInt(countMatch[1]), 500);
    if (!Number.isFinite(count) || count <= 0) return [];
    const extensionMatch = body.match(/(?:pasd|imagePath|image_path)\s*\+\s*[^+;]+\+\s*["'](\.(?:avif|gif|jpe?g|png|webp))["']/i);
    const extension = extensionMatch && extensionMatch[1] ? extensionMatch[1] : '.webp';
    const images: string[] = [];
    for (let index = 1; index <= count; index++) {
      images.push(`${pathMatch[1]}${index}${extension}`);
    }
    return images;
  }

  private async tryGetDirectAjaxRuleContent(source: BookSource, body: string, baseUrl: string,
    ctx: RuleContext, contentRule: string): Promise<string> {
    const plan = AjaxRuleCompat.directResultPlan(contentRule);
    if (!plan) return '';

    const urlAnalyze = new AnalyzeRule(body, baseUrl, ctx);
    const requestUrl = urlAnalyze.getString(plan.urlRule, true);
    if (!requestUrl || !/^https?:\/\//.test(requestUrl)) return '';

    const response = await new AnalyzeUrl(source, this.http).fetch(requestUrl);
    if (!response.success || !response.body) return '';

    return AjaxRuleCompat.applyReplaceChain(response.body, plan.jsCode);
  }

  private async fetchEncodedDataUrl(url: string, source: BookSource): Promise<{ url: string, statusCode: number, headers: Record<string, string>, body: string, success: boolean, error?: string }> {
    const root = await EncodedSourceUrl.requestJsonForDataUrl(this.http, url,
      BookSourceDataUrlSupport.sourceBackendHost(source));
    if (!root) {
      return { url: url, statusCode: 0, headers: {}, body: '', success: false, error: 'encoded data url request failed' };
    }
    return { url: url, statusCode: 200, headers: {}, body: JSON.stringify(root), success: true };
  }

  private requestVerificationIfNeeded(source: BookSource, requestUrl: string, body: string, statusCode: number, rule: string): boolean {
    if (!VerificationSupport.shouldRequestBrowserVerification(source, body, statusCode, rule)) {
      return false;
    }
    const verifyUrl = VerificationSupport.pickVerificationUrl(source, requestUrl, rule);
    VerificationSupport.requestVerification(verifyUrl, `${source.bookSourceName} 验证`, source);
    console.warn('[WS] source needs browser verification:', source.bookSourceName, verifyUrl);
    return true;
  }

  private shouldFallbackChaoxingToc(source: BookSource, tocUrl: string, bookUrl: string): boolean {
    if (!bookUrl || !this.isChaoxingSource(source, tocUrl || bookUrl)) return false;
    return (tocUrl || '').includes('/api/book/getChapters');
  }

  private isChaoxingSource(source: BookSource, requestUrl: string): boolean {
    const raw = `${requestUrl || ''}\n${source.bookSourceUrl || ''}\n${source.loginUrl || ''}\n` +
      `${source.searchUrl || ''}\n${source.exploreUrl || ''}`.toLowerCase();
    return raw.includes('chaoxing.com');
  }

  private normalizeChaoxingUrl(source: BookSource, url: string): string {
    if (!url || !this.isChaoxingSource(source, url)) return url;
    return url.replace(/^http:\/\/((?:qikan|www)\.chaoxing\.com)(?=\/)/i, 'https://$1');
  }

  private shouldRetryChaoxingHttps(source: BookSource, url: string): boolean {
    return /^http:\/\/(?:qikan|www)\.chaoxing\.com\//i.test(url || '') && this.isChaoxingSource(source, url);
  }

  private tryBuildChaoxingDetailChapter(source: BookSource, book: Book, body: string, baseUrl: string): BookChapter[] {
    if (!this.isChaoxingSource(source, book.bookUrl || baseUrl) || !body || !book.bookUrl.includes('/detail_')) return [];
    if (!this.looksLikeChaoxingDetailPage(body)) return [];
    const chapter = new BookChapter();
    chapter.title = this.cleanChapterTitle(book.latestChapterTitle || book.name || '详情');
    chapter.url = this.normalizeChaoxingUrl(source, book.bookUrl);
    chapter.bookUrl = book.bookUrl;
    chapter.index = 0;
    chapter.variable = BookUrlResolver.setVariableJson(chapter.variable, 'baseUrl', chapter.url);
    console.log('[WS] Chaoxing detail fallback chapter:', chapter.title, chapter.url);
    return chapter.title && chapter.url ? [chapter] : [];
  }

  private looksLikeChaoxingDetailPage(body: string): boolean {
    const sample = (body || '').substring(0, Math.min(body.length, 200000));
    return sample.includes('qikan.chaoxing.com') || sample.includes('chaoxing.com') ||
      sample.includes('超星') || sample.includes('读秀') || sample.includes('文献') ||
      /\/detail_[A-Za-z0-9]+/.test(sample);
  }

  private tryExtractChaoxingDetailContent(book: Book, body: string): string {
    if (!body) return '';
    const title = this.cleanInlineText(book.name || this.extractFirstMetaContent(body, ['citation_title', 'DC.title']) ||
      this.extractTitleText(body));
    const author = this.cleanInlineText(book.author || this.extractFirstMetaContent(body, ['citation_author', 'DC.creator']));
    const abstractText = this.cleanInlineText(this.extractChaoxingField(body, ['摘要', '简介', '内容提要']) ||
      this.extractFirstMetaContent(body, ['description', 'DC.description']));
    const keywords = this.cleanInlineText(this.extractChaoxingField(body, ['关键词', '关键字']) ||
      this.extractFirstMetaContent(body, ['keywords', 'citation_keywords']));
    const sourceName = this.cleanInlineText(this.extractChaoxingField(body, ['来源', '刊名', '期刊']) ||
      this.extractFirstMetaContent(body, ['citation_journal_title']));
    const year = this.cleanInlineText(this.extractChaoxingField(body, ['年份', '出版日期']) ||
      this.extractFirstMetaContent(body, ['citation_publication_date', 'DC.date']));

    const lines: string[] = [];
    if (title) lines.push(title);
    if (author) lines.push(`作者：${author}`);
    if (sourceName) lines.push(`来源：${sourceName}`);
    if (year) lines.push(`日期：${year}`);
    if (keywords) lines.push(`关键词：${keywords}`);
    if (abstractText) lines.push(`摘要：${abstractText}`);
    if (lines.length <= 1) return '';
    lines.push('该超星条目未解析到可直接阅读的全文，已显示详情页信息。');
    return lines.join('\n\n');
  }

  private extractFirstMetaContent(body: string, names: string[]): string {
    for (const name of names) {
      const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const re = new RegExp(`<meta\\b[^>]*(?:name|property)\\s*=\\s*["']${escaped}["'][^>]*content\\s*=\\s*["']([\\s\\S]*?)["'][^>]*>`, 'i');
      const match = body.match(re);
      if (match && match[1]) return this.decodeHtmlEntities(match[1]);
    }
    return '';
  }

  private extractTitleText(body: string): string {
    const match = (body || '').match(/<title[^>]*>([\s\S]*?)<\/title>/i);
    return match && match[1] ? this.decodeHtmlEntities(match[1]).replace(/[-_].*$/, '') : '';
  }

  private extractChaoxingField(body: string, labels: string[]): string {
    for (const label of labels) {
      const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const re = new RegExp(`${escaped}\\s*[：:]\\s*</?[^>]*>??\\s*([\\s\\S]{0,800}?)(?:</p>|</li>|</div>|<br\\s*/?>|\\n)`, 'i');
      const match = (body || '').match(re);
      if (match && match[1]) return this.decodeHtmlEntities(match[1].replace(/<[^>]+>/g, ' '));
    }
    return '';
  }

  private isBadExtractedContent(content: string): boolean {
    if (!content) return false;
    const sample = content.substring(0, Math.min(content.length, 1200));
    return sample.includes('font-family:') || sample.includes('-webkit-text-size-adjust') ||
      sample.includes('.nuxt-progress') || sample.includes('box-sizing:border-box') ||
      sample.includes('<!doctype html') || sample.includes('<html');
  }

  private tryBuildGenericChapterList(book: Book, body: string, baseUrl: string): BookChapter[] {
    if (!body) return [];
    const bookKey = this.extractGenericBookKey(book.tocUrl || book.bookUrl || baseUrl);
    const catalogHtml = this.pickGenericCatalogBlock(body, baseUrl, bookKey);
    let links = this.collectGenericChapterLinks(catalogHtml, baseUrl, bookKey, catalogHtml !== body);
    if (links.length < 3 && catalogHtml !== body) {
      links = this.collectGenericChapterLinks(body, baseUrl, bookKey, false);
    }
    links = this.trimLeadingTeaserLinks(links);
    if (links.length < 3) return [];

    const chapters: BookChapter[] = [];
    for (const link of links) {
      const chapter = new BookChapter();
      chapter.title = this.cleanChapterTitle(link['title'] || `第${chapters.length + 1}章`);
      chapter.url = link['url'] || '';
      chapter.bookUrl = book.bookUrl;
      chapter.index = chapters.length;
      chapter.variable = BookUrlResolver.setVariableJson(chapter.variable, 'baseUrl', chapter.url || baseUrl);
      if (chapter.title && chapter.url) chapters.push(chapter);
    }
    console.log('[WS] 通用目录兜底:', chapters.length, 'from:', book.name || book.bookUrl);
    return chapters;
  }

  private tryExtractReadableContentFromHtml(body: string): string {
    if (!body) return '';
    const names = [
      'nr1',
      'chaptercontent',
      'chapter-content',
      'chapter_content',
      'reader-content',
      'read-content',
      'article-content',
      'article_content',
      'TxtContent',
      'txtcontent',
      'word_read',
      'readtxt',
      'booktext',
      'BookText',
      'content',
      'post'
    ];
    const blocks: string[] = [];
    for (const name of names) {
      blocks.push(this.extractIdBlock(body, name));
      blocks.push(this.extractClassBlock(body, name));
    }
    blocks.push(this.extractTagBlock(body, 'article'));

    let best = '';
    let bestScore = 0;
    for (const block of blocks) {
      const text = this.cleanReadableContentText(block);
      const score = this.scoreReadableContent(text);
      if (score > bestScore) {
        best = text;
        bestScore = score;
      }
    }

    if (!best) {
      const text = this.cleanReadableContentText(body);
      if (this.isUsableReadableContent(text)) best = text;
    }
    return best;
  }

  private pickGenericCatalogBlock(body: string, baseUrl: string, bookKey: string): string {
    const names = [
      'book-list',
      'chapter-list',
      'chapterlist',
      'catalog-list',
      'catalog',
      'directory',
      'book-chapter-list',
      'chapters',
      'listmain',
      'list',
      'play_0',
      'volume-list',
      'chapter'
    ];
    let best = '';
    let bestCount = 0;
    for (const name of names) {
      const block = this.extractClassBlock(body, name) || this.extractIdBlock(body, name);
      if (!block) continue;
      const count = this.collectGenericChapterLinks(block, baseUrl, bookKey, true).length;
      if (count > bestCount) {
        best = block;
        bestCount = count;
      }
    }
    return bestCount >= 3 ? best : body;
  }

  private collectGenericChapterLinks(html: string, baseUrl: string, bookKey: string, inCatalogBlock: boolean):
    Record<string, string>[] {
    const links: Record<string, string>[] = [];
    const seen: string[] = [];
    const re = /<a\b([^>]*)>([\s\S]*?)<\/a>/gi;
    let match: RegExpExecArray | null;
    while ((match = re.exec(html || '')) !== null) {
      const attrs = match[1] || '';
      const hrefMatch = attrs.match(/\shref\s*=\s*["']([^"']+)["']/i);
      if (!hrefMatch || !hrefMatch[1]) continue;
      const url = BookUrlResolver.resolve(this.decodeHtmlEntities(hrefMatch[1]), baseUrl);
      const chapterKey = this.normalizeChapterLinkKey(url);
      if (!chapterKey || seen.includes(chapterKey)) continue;
      const titleMatch = attrs.match(/\stitle\s*=\s*["']([^"']+)["']/i);
      const title = this.cleanInlineText(titleMatch && titleMatch[1] ? titleMatch[1] : match[2]);
      if (!title || this.isNavigationTitle(title)) continue;
      const likelyChapter = this.isLikelyChapterTitle(title) || this.isLikelyChapterUrl(url, baseUrl, bookKey);
      if (!inCatalogBlock && !likelyChapter) continue;
      seen.push(chapterKey);
      links.push({
        title: title,
        url: url,
        key: chapterKey
      });
      if (links.length > 20000) break;
    }
    return links;
  }

  private trimLeadingTeaserLinks(links: Record<string, string>[]): Record<string, string>[] {
    if (links.length < 6) return links;
    for (let i = 0; i < links.length; i++) {
      if (this.isLikelyFirstChapterTitle(links[i]['title'] || '')) {
        const remain = links.length - i;
        if (i > 0 && remain >= 3) return links.slice(i);
        return links;
      }
    }
    return links;
  }

  private isLikelyFirstChapterTitle(title: string): boolean {
    const compact = (title || '').replace(/\s+/g, '').toLowerCase();
    return /^chapter0/.test(compact) || /^chapter1/.test(compact) ||
      /^第(一|1|１|壹)[章节節回]/.test(compact) || /^第0[章节節回]/.test(compact) ||
      compact.startsWith('序章') || compact.startsWith('楔子') ||
      compact.startsWith('引子') || compact.startsWith('前言');
  }

  private isLikelyChapterTitle(title: string): boolean {
    const compact = (title || '').replace(/\s+/g, '').toLowerCase();
    return /^chapter\d+/.test(compact) || /^ch\.\d+/.test(compact) ||
      /^第[\d一二三四五六七八九十百千万零〇壹贰叁肆伍陆柒捌玖拾兩两]+[章节節回卷]/.test(compact) ||
      compact.startsWith('序章') || compact.startsWith('楔子') || compact.startsWith('引子') ||
      compact.startsWith('前言') || compact.startsWith('番外');
  }

  private isNavigationTitle(title: string): boolean {
    const compact = (title || '').replace(/\s+/g, '');
    return !compact || compact === '開始閱讀' || compact === '开始阅读' || compact === '最近閱讀' ||
      compact === '最近阅读' || compact === '上次閱讀' || compact === '上次阅读' ||
      compact === '阅读记录' || compact === '書頁/目錄' || compact === '书页/目录' ||
      compact === '上一章' || compact === '下一章' || compact === '上一頁' || compact === '下一頁' ||
      compact === '上一页' || compact === '下一页' || compact === '首頁' || compact === '首页' ||
      compact === '返回目录' || compact === '返回目錄' || compact === '書庫' || compact === '书库' ||
      compact === '作者' || compact === '目录' || compact === '目錄' || compact === '首页';
  }

  private cleanChapterTitle(title: string): string {
    const original = this.cleanInlineText(title || '');
    const cleaned = original
      .replace(/\s+/g, ' ')
      .replace(/[\s·|｜/／-]*上次(?:阅读|閱讀)(?:[\s:：，,。]*.*)?$/g, '')
      .replace(/^上次(?:阅读|閱讀)[\s:：，,。]*/g, '')
      .trim();
    return cleaned || original;
  }

  private extractGenericBookKey(url: string): string {
    const clean = (url || '').replace(/[?#].*$/, '').replace(/\.html?$/i, '');
    const segments = clean.split('/').filter(part => part.length > 0);
    if (segments.length === 0) return '';
    const last = segments[segments.length - 1];
    if (/^[A-Za-z0-9_-]{2,60}$/.test(last)) return last;
    return '';
  }

  private normalizeChapterLinkKey(url: string): string {
    const clean = (url || '').replace(/#[\s\S]*$/, '').replace(/[?&](?:from|spm|utm_[^=]+)=[^&]*/g, '');
    return clean.replace(/[?&]$/g, '').replace(/\/$/g, '');
  }

  private isLikelyChapterUrl(url: string, baseUrl: string, bookKey: string): boolean {
    const clean = (url || '').replace(/[?#].*$/, '').toLowerCase();
    if (!clean || clean === (baseUrl || '').replace(/[?#].*$/, '').toLowerCase()) return false;
    if (bookKey && clean.includes(`/${bookKey.toLowerCase()}/`)) return true;
    if (/\/(?:chapter|read|content|book)\/[^/]+\/[^/]+/.test(clean)) return true;
    const last = clean.split('/').filter(part => part.length > 0).pop() || '';
    return /^(?:\d+|chapter[_-]?\d+|ch[_-]?\d+|read[_-]?\d+)\.html?$/.test(last);
  }

  private cleanInlineText(value: string): string {
    return this.decodeHtmlEntities(value || '')
      .replace(/<script[\s\S]*?<\/script>/gi, '')
      .replace(/<style[\s\S]*?<\/style>/gi, '')
      .replace(/<[^>]+>/g, '')
      .replace(/\s+/g, ' ')
      .trim();
  }

  private cleanReadableContentText(html: string): string {
    if (!html) return '';
    const raw = this.decodeHtmlEntities(html)
      .replace(/<script[\s\S]*?<\/script>/gi, '')
      .replace(/<style[\s\S]*?<\/style>/gi, '')
      .replace(/<iframe[\s\S]*?<\/iframe>/gi, '')
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<\/p>/gi, '\n')
      .replace(/<\/div>/gi, '\n')
      .replace(/<\/li>/gi, '\n')
      .replace(/<h[1-6][^>]*>[\s\S]*?<\/h[1-6]>/gi, '\n')
      .replace(/<[^>]+>/g, '\n')
      .replace(/\r\n?/g, '\n');
    const lines: string[] = [];
    for (const sourceLine of raw.split('\n')) {
      let line = sourceLine.replace(/\s+/g, ' ').trim();
      if (!line || this.isNoiseLine(line)) continue;
      line = this.repairReversedLine(line);
      if (line && !this.isNoiseLine(line)) lines.push(line);
      if (lines.length > 4000) break;
    }
    return lines.join('\n\n')
      .replace(/\(本章完\)/g, '')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
  }

  private repairReversedLine(line: string): string {
    const value = line.trim();
    if (!/^[。！？!?，,、；;：:）」』”]/.test(value)) return value;
    let reversed = '';
    for (let i = value.length - 1; i >= 0; i--) {
      reversed += value.charAt(i);
    }
    return reversed
      .replace(/([\u3400-\u9fff])\s+(?=[\u3400-\u9fff])/g, '$1')
      .replace(/\s+/g, ' ')
      .trim();
  }

  private isNoiseLine(line: string): boolean {
    const compact = (line || '').replace(/\s+/g, '');
    return !compact || compact === 'A-AA+' || compact === '默認米黃護眼' || compact === '默认米黄护眼' ||
      compact.includes('檢舉本章錯誤') || compact.includes('检举本章错误') ||
      compact.includes('猜你喜歡') || compact.includes('猜你喜欢') ||
      compact.includes('確認檢舉') || compact.includes('确认检举') ||
      compact.includes('請選擇檢舉原因') || compact.includes('请选择检举原因') ||
      compact.includes('版權所有') || compact.includes('版权所有') ||
      compact.includes('如果被转码') || compact.includes('如果被轉碼') ||
      compact.includes('阅读模式') || compact.includes('閱讀模式') ||
      compact.includes('本章没完') || compact.includes('本章未完') ||
      compact.includes('继续阅读') || compact.includes('繼續閱讀') ||
      compact.includes('上一章') || compact.includes('下一章') ||
      compact.includes('上一頁') || compact.includes('下一頁') ||
      compact.includes('书页/目录') || compact.includes('書頁/目錄');
  }

  private scoreReadableContent(text: string): number {
    if (!this.isUsableReadableContent(text)) return 0;
    const lines = text.split('\n').filter(line => line.trim().length > 0).length;
    return text.length + lines * 80;
  }

  private isUsableReadableContent(text: string): boolean {
    if (!text || text.length < 30) return false;
    const compact = text.replace(/\s+/g, '');
    if (compact.includes('搜尋書名或作者') && compact.length < 200) return false;
    if (compact.includes('請輸入書名') && compact.length < 300) return false;
    if (compact.includes('请输入书名') && compact.length < 300) return false;
    return true;
  }

  private extractClassBlock(html: string, className: string): string {
    return this.extractAttrBlock(html, 'class', className);
  }

  private extractIdBlock(html: string, id: string): string {
    return this.extractAttrBlock(html, 'id', id);
  }

  private extractAttrBlock(html: string, attrName: string, attrValue: string): string {
    const re = new RegExp(`<([a-zA-Z][\\w-]*)([^>]*\\s${attrName}=["'][^"']*\\b` +
      `${this.escapeRegex(attrValue)}\\b[^"']*["'][^>]*)>`, 'i');
    const m = re.exec(html);
    if (!m) return '';
    const start = m.index;
    const tag = m[1];
    const tagRe = new RegExp(`<\\/?${this.escapeRegex(tag)}(?:\\s[^>]*)?>`, 'gi');
    tagRe.lastIndex = start;
    let depth = 0;
    let tm: RegExpExecArray | null;
    while ((tm = tagRe.exec(html)) !== null) {
      if (tm[0].startsWith('</')) {
        depth--;
        if (depth === 0) return html.substring(start, tagRe.lastIndex);
      } else if (!tm[0].endsWith('/>')) {
        depth++;
      }
    }
    return html.substring(start);
  }

  private extractTagBlock(html: string, tagName: string): string {
    if (!html || !tagName) return '';
    const tag = this.escapeRegex(tagName);
    const re = new RegExp(`<${tag}(?:\\s[^>]*)?>`, 'i');
    const m = re.exec(html);
    if (!m) return '';
    const start = m.index;
    const tagRe = new RegExp(`<\\/?${tag}(?:\\s[^>]*)?>`, 'gi');
    tagRe.lastIndex = start;
    let depth = 0;
    let tm: RegExpExecArray | null;
    while ((tm = tagRe.exec(html)) !== null) {
      if (tm[0].startsWith('</')) {
        depth--;
        if (depth === 0) return html.substring(start, tagRe.lastIndex);
      } else if (!tm[0].endsWith('/>')) {
        depth++;
      }
    }
    return html.substring(start);
  }

  private decodeHtmlEntities(value: string): string {
    return (value || '')
      .replace(/&#x([0-9a-fA-F]+);/g, (_: string, hex: string) => String.fromCharCode(parseInt(hex, 16)))
      .replace(/&#(\d+);/g, (_: string, num: string) => String.fromCharCode(parseInt(num, 10)))
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&apos;/g, "'")
      .replace(/&#39;/g, "'");
  }

  private async normalizeReaderContent(source: BookSource, content: string, baseUrl: string,
    imageRuleValues: string[] = []): Promise<string> {
    const explicitImages = this.collectReaderImageUrls(imageRuleValues, baseUrl, true);
    if (explicitImages.length > 0) {
      return await this.materializeReaderImageMarkers(source,
        explicitImages.map((url: string): string => ReaderImageMarker.create(url)).join('\n\n'));
    }

    let value = content || '';
    value = this.convertReaderNativeActions(source, value, baseUrl);
    value = value.replace(/<(?:img|image)\b[^>]*>/gi, (tag: string): string => {
      const images = this.collectReaderImageUrls([tag], baseUrl, false);
      return images.length > 0 ? `\n\n${ReaderImageMarker.create(images[0])}\n\n` : ' ';
    });
    value = value.replace(/!\[[^\]]*\]\(([^)\s]+)(?:\s+["'][^"']*["'])?\)/g,
      (_all: string, rawUrl: string): string => {
        const url = this.normalizeReaderImageUrl(rawUrl, baseUrl, true);
        return url ? `\n\n${ReaderImageMarker.create(url)}\n\n` : ' ';
      });

    const lines: string[] = [];
    for (const rawLine of value.replace(/\r\n?/g, '\n').split('\n')) {
      const line = rawLine.trim();
      const imageUrl = this.normalizeReaderImageUrl(line, baseUrl, false);
      if (imageUrl && this.isLikelyReaderImageUrl(line)) {
        lines.push(ReaderImageMarker.create(imageUrl));
      } else {
        lines.push(rawLine);
      }
    }

    const normalized = lines.join('\n')
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<\/p>/gi, '\n\n')
      .replace(/<\/div>/gi, '\n')
      .replace(/<[^>]+>/g, '')
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
    return await this.materializeReaderImageMarkers(source, normalized);
  }

  private convertReaderNativeActions(source: BookSource, content: string, baseUrl: string): string {
    if (!content) return content;
    let value = content.replace(/<img\b[^>]*>/gi, (tag: string): string => {
      return this.readerActionMarkerFromLegacyImage(source, tag, baseUrl) || tag;
    });
    value = value.replace(/<p\b[^>]*>\s*<img\b([^>]*\bident\s*=\s*["'][^"']+["'][^>]*)\/?\s*>\s*<\/p>/gi,
      (_all: string, attrs: string): string => {
        const identMatch = /\bident\s*=\s*["']([^"']+)["']/i.exec(attrs || '');
        const url = this.decodeHtmlEntities(identMatch && identMatch[1] ? identMatch[1] : '');
        const marker = ReaderActionMarker.create('神评论', url, '神评论');
        return marker ? `${marker}\n` : '';
      });
    value = value.replace(/<p\b[^>]*>([\s\S]*?)<comment\b([^>]*)\/?>([\s\S]*?)<\/p>/gi,
      (_all: string, before: string, attrs: string, after: string): string => {
        const text = this.decodeHtmlEntities(`${before || ''}${after || ''}`.replace(/<[^>]+>/g, '')).trim();
        const marker = this.readerActionMarkerFromCommentAttributes(attrs || '');
        return `${text}${marker}\n`;
      });
    if (!/<(?:div|span)\b[^>]*\brs-native\b/i.test(value)) return value;
    return value.replace(/<(div|span)\b[^>]*\brs-native\b[^>]*>([\s\S]*?)<\/\1>/gi,
      (_all: string, _tagName: string, inner: string): string => {
        const comment = /<comment\b([^>]*)>/i.exec(inner || '');
        const text = this.decodeHtmlEntities((inner || '').replace(/<comment\b[^>]*>/gi, '')
          .replace(/<[^>]+>/g, '')).trim();
        if (!comment) return text ? `${text}\n` : '';
        const marker = this.readerActionMarkerFromCommentAttributes(comment[1] || '');
        return `${text}${marker}\n`;
      });
  }

  private readerActionMarkerFromCommentAttributes(attrs: string): string {
    const countMatch = /\bcount\s*=\s*["']([^"']*)["']/i.exec(attrs || '');
    const identMatch = /\bident\s*=\s*["']([^"']*)["']/i.exec(attrs || '');
    const pressMatch = /\b(?:onPress|onClick|click)\s*=\s*(["'])([\s\S]*?)\1/i.exec(attrs || '');
    const actionMatch = pressMatch ?
      /java\.(?:showReadingBrowser|startBrowserDp|startBrowser|showBrowser)\(\s*(["'])([\s\S]*?)\1(?:\s*,\s*(["'])([\s\S]*?)\3)?/i.exec(pressMatch[2]) : null;
    const url = this.decodeHtmlEntities(actionMatch && actionMatch[2] ? actionMatch[2] :
      (identMatch && identMatch[1] ? identMatch[1] : ''));
    if (!url) return '';
    const rawTitle = this.decodeHtmlEntities(actionMatch && actionMatch[4] ? actionMatch[4] : '');
    const count = this.decodeHtmlEntities(countMatch && countMatch[1] ? countMatch[1] : '');
    const isComment = /\/comments(?:[/?#]|$)|\/idea_comment(?:[/?#]|$)|\/get_review(?:[/?#]|$)/i.test(url);
    const title = isComment ? (rawTitle ? `段评 · ${rawTitle}` : '段评') : (rawTitle || '打开');
    const label = isComment ? (count ? `段评 ${count}` : '段评') : (count ? `${title} ${count}` : title);
    return ReaderActionMarker.create(label, url, title);
  }

  /**
   * Older Legado-compatible sources attach a JavaScript click action to an SVG data URL. The
   * reader image pipeline deliberately strips those options, so translate the well-known
   * paragraph-comment action into a native marker before normal image handling runs.
   */
  private readerActionMarkerFromLegacyImage(source: BookSource, tag: string, baseUrl: string): string {
    const rawSource = this.decodeHtmlEntities(this.findReaderImageAttribute(tag));
    const optionIndex = this.readerImageOptionIndex(rawSource);
    if (optionIndex < 0) return '';
    const rawOptions = rawSource.substring(optionIndex + 1).trim();
    let options: Record<string, Object> = {};
    try {
      options = JSON.parse(rawOptions) as Record<string, Object>;
    } catch (_) {
      return '';
    }
    const action = String(options['click'] || options['js'] || '');
    const actionMatch = /\b((?:fq)?(?:android)?showCmt)\s*\(\s*['"]?([^,'"\s)]+)['"]?\s*,\s*['"]?([^,'"\s)]+)['"]?\s*,\s*['"]?([^,'"\s)]+)['"]?/i.exec(action);
    if (!actionMatch || !actionMatch[2] || !actionMatch[3] || !actionMatch[4]) return '';
    const host = this.readerActionHost(source, baseUrl);
    if (!host) return '';
    const isFanqie = /^fq/i.test(actionMatch[1] || '');
    const bookId = encodeURIComponent(actionMatch[2]);
    const chapterId = encodeURIComponent(actionMatch[3]);
    const paragraphId = encodeURIComponent(actionMatch[4]);
    let url = `${host}/comments?bookId=${bookId}&chapterId=${chapterId}&paragraphId=${paragraphId}`;
    if (isFanqie) url += '&source=fanqie';

    const svgText = this.decodeLegacySvg(rawSource.substring(0, optionIndex));
    const kind = /作家说/.test(svgText) ? '作家说评论' :
      (/本章说/.test(svgText) ? '本章说' : (/热评|热门评论|神评论/.test(svgText) ? '神评论' : '段评'));
    const countMatch = /<text\b[^>]*>([^<>]{1,20})<\/text>/gi;
    let count = '';
    let textMatch: RegExpExecArray | null;
    while ((textMatch = countMatch.exec(svgText)) !== null) {
      const candidate = this.decodeHtmlEntities(textMatch[1] || '').trim();
      if (/^\d{1,4}$/.test(candidate)) count = candidate;
    }
    const label = count && kind === '段评' ? `${kind} ${count}` : kind;
    const marker = ReaderActionMarker.create(label, url, kind);
    if (!marker) return '';
    // Rich chapter/author cards retain their artwork and receive a native action beside it.
    return kind === '段评' ? marker : `${tag}\n${marker}`;
  }

  private decodeLegacySvg(dataUrl: string): string {
    const match = /^data:image\/svg\+xml;base64,([^,]+)/i.exec(dataUrl || '');
    if (!match || !match[1]) return '';
    try {
      const bytes = new util.Base64Helper().decodeSync(match[1]);
      return util.TextDecoder.create('utf-8').decodeWithStream(bytes, { stream: false });
    } catch (_) {
      return '';
    }
  }

  private readerActionHost(source: BookSource, baseUrl: string): string {
    let preferred = '';
    try {
      const loginInfo = JSON.parse(source.loginInfo || '{}') as Record<string, Object>;
      const rawRuntime = loginInfo['__legadoHarmonyRuntime'];
      let runtime: Record<string, Object> = {};
      if (typeof rawRuntime === 'string') {
        runtime = JSON.parse(rawRuntime || '{}') as Record<string, Object>;
      } else if (rawRuntime && typeof rawRuntime === 'object' && !Array.isArray(rawRuntime)) {
        runtime = rawRuntime as Record<string, Object>;
      }
      const rawSource = runtime['source'];
      if (rawSource && typeof rawSource === 'object' && !Array.isArray(rawSource)) {
        const sourceState = rawSource as Record<string, Object>;
        preferred = String(sourceState['qd_base'] || '');
      }
    } catch (_) {
      preferred = '';
    }
    const candidate = preferred || baseUrl || source.bookSourceUrl || '';
    const origin = /^https?:\/\/[^/]+/i.exec(candidate);
    return origin && origin[0] ? origin[0].replace(/\/+$/, '') : '';
  }

  private async materializeReaderImageMarkers(source: BookSource, content: string): Promise<string> {
    if (!content || !content.includes(ReaderImageMarker.PREFIX)) return content;
    const pattern = new RegExp(`${this.escapeRegex(ReaderImageMarker.PREFIX)}([^\\]]+)` +
      `${this.escapeRegex(ReaderImageMarker.SUFFIX)}`, 'g');
    const values: string[] = [];
    let match: RegExpExecArray | null;
    while ((match = pattern.exec(content)) !== null) {
      try {
        const raw = decodeURIComponent(match[1]);
        if (raw && !values.includes(raw)) values.push(raw);
      } catch (_) {
      }
    }
    if (values.length === 0) return content;
    const resolved: Record<string, string> = {};
    for (let start = 0; start < values.length; start += 4) {
      const batch = values.slice(start, start + 4);
      const paths = await Promise.all(batch.map((value: string): Promise<string> =>
        ComicImagePipeline.materialize(this.http, source, value)));
      for (let index = 0; index < batch.length; index++) {
        resolved[batch[index]] = paths[index] || batch[index];
      }
    }
    return content.replace(pattern, (_all: string, encoded: string): string => {
      try {
        const raw = decodeURIComponent(encoded);
        return ReaderImageMarker.create(resolved[raw] || raw);
      } catch (_) {
        return _all;
      }
    });
  }

  private collectReaderImageUrls(values: string[], baseUrl: string, trustPlainValue: boolean): string[] {
    const result: string[] = [];
    const seen = new Set<string>();
    for (const rawValue of values) {
      const value = this.decodeHtmlEntities(rawValue || '').trim();
      if (!value) continue;
      const tags = value.match(/<(?:img|image|source|object)\b[^>]*>/gi) || [];
      for (const tag of tags) {
        const attrValue = this.findReaderImageAttribute(tag);
        this.appendReaderImageUrl(result, seen, attrValue, baseUrl, true);
      }
      const markdown = /!\[[^\]]*\]\(([^)\s]+)(?:\s+["'][^"']*["'])?\)/g;
      let markdownMatch: RegExpExecArray | null;
      while ((markdownMatch = markdown.exec(value)) !== null) {
        this.appendReaderImageUrl(result, seen, markdownMatch[1], baseUrl, true);
      }
      if (tags.length === 0 && trustPlainValue) {
        const parts = this.splitReaderImageRuleValue(value);
        for (const part of parts) {
          this.appendReaderImageUrl(result, seen, part, baseUrl, true);
        }
      }
    }
    return result;
  }

  private appendReaderImageUrl(result: string[], seen: Set<string>, rawUrl: string, baseUrl: string,
    trustValue: boolean): void {
    const url = this.normalizeReaderImageUrl(rawUrl, baseUrl, trustValue);
    if (!url || seen.has(url)) return;
    seen.add(url);
    result.push(url);
  }

  private findReaderImageAttribute(tag: string): string {
    const protectedSource = /(?:^|\s)(?:src|data-r-src|data-src)\s*=\s*["']([\s\S]*,\s*\{[\s\S]*\})["']/i.exec(tag);
    if (protectedSource && protectedSource[1]) return protectedSource[1];
    const names = ['data-original', 'data-src', 'data-url', 'data-lazy-src', 'data-echo', 'src',
      'data-r-src', 'xlink:href', 'href', 'srcset'];
    for (const name of names) {
      const escaped = name.replace(':', '\\:');
      const quoted = new RegExp(`(?:^|\\s)${escaped}\\s*=\\s*["']([^"']+)["']`, 'i').exec(tag);
      if (quoted && quoted[1]) return name === 'srcset' ? quoted[1].split(',')[0].trim().split(/\s+/)[0] : quoted[1];
      const unquoted = new RegExp(`(?:^|\\s)${escaped}\\s*=\\s*([^\\s>]+)`, 'i').exec(tag);
      if (unquoted && unquoted[1]) return name === 'srcset' ? unquoted[1].split(',')[0].trim().split(/\s+/)[0] : unquoted[1];
    }
    return '';
  }

  private splitReaderImageRuleValue(value: string): string[] {
    const trimmed = value.trim().replace(/^\[|\]$/g, '');
    if (!trimmed) return [];
    return trimmed.split(/(?:\r?\n|\|\||,\s*(?=["']?(?:https?:|\/|\.\.?\/)))/)
      .map((item: string): string => item.trim().replace(/^['"]|['"]$/g, ''))
      .filter((item: string): boolean => item.length > 0);
  }

  private normalizeReaderImageUrl(rawUrl: string, baseUrl: string, trustValue: boolean): string {
    let value = this.decodeHtmlEntities(rawUrl || '').trim()
      .replace(/^url\(\s*|\s*\)$/gi, '')
      .replace(/^['"]|['"]$/g, '');
    if (!value || /^(?:javascript:|about:|#)/i.test(value)) return '';
    const optionIndex = this.readerImageOptionIndex(value);
    const options = optionIndex >= 0 ? value.substring(optionIndex) : '';
    if (optionIndex >= 0) value = value.substring(0, optionIndex).trim();
    if (!trustValue && !this.isLikelyReaderImageUrl(value)) return '';
    if (/^data:image\//i.test(value)) return value;
    if (/^(?:https?:)?\/\//i.test(value) || /^\.?\.?\//.test(value)) {
      const resolved = BookUrlResolver.resolve(value, baseUrl);
      return resolved ? `${resolved}${options}` : '';
    }
    if (trustValue && !/\s/.test(value) && !value.startsWith('<') && !value.startsWith('{')) {
      const resolved = BookUrlResolver.resolve(value, baseUrl);
      return resolved ? `${resolved}${options}` : '';
    }
    return '';
  }

  private readerImageOptionIndex(value: string): number {
    for (let index = value.length - 1; index >= 0; index--) {
      if (value.charAt(index) !== ',') continue;
      const tail = value.substring(index + 1).trim();
      if (tail.startsWith('{') && tail.endsWith('}')) return index;
    }
    return -1;
  }

  private isLikelyReaderImageUrl(value: string): boolean {
    const clean = (value || '').trim();
    return /^data:image\//i.test(clean) ||
      /\.(?:avif|bmp|gif|jpe?g|png|svg|webp)(?:[?#].*)?$/i.test(clean);
  }

  private escapeRegex(value: string): string {
    return (value || '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  private applyContentReplaceRule(content: string, replaceRule: string, ctx: RuleContext,
    chapter: BookChapter): string {
    if (!content || !replaceRule) return content;
    let value = content
      .replace(/<\/p>\s*<p/gi, '</p>\n<p')
      .replace(/<br\s*\/?>/gi, (match: string) => `${match}\n`);
    const jsIndex = replaceRule.indexOf('@js:');
    const regexPart = (jsIndex >= 0 ? replaceRule.substring(0, jsIndex) : replaceRule).trim();
    const jsPart = jsIndex >= 0 ? replaceRule.substring(jsIndex + 4).trim() : '';
    if (regexPart) {
      let pattern = '';
      let replacement = '';
      if (regexPart.startsWith('##')) {
        pattern = regexPart.substring(2);
      } else {
        const delimiter = this.findUnescapedDoubleHash(regexPart);
        if (delimiter >= 0) {
          pattern = regexPart.substring(0, delimiter);
          replacement = regexPart.substring(delimiter + 2);
        } else {
          pattern = regexPart;
        }
      }
      pattern = this.expandRuleTemplate(pattern.replace(/\\##/g, '##'), ctx);
      replacement = this.expandRuleTemplate(replacement.replace(/\\##/g, '##'), ctx);
      if (pattern) {
        try {
          value = value.replace(new RegExp(pattern, 'g'), replacement);
        } catch (_) {
        }
      }
    }
    if (jsPart) {
      const env = new ScriptEngineContext();
      env.content = value;
      env.baseUrl = chapter.url;
      env.ctx = ctx;
      const result = new ScriptEngine(new JsRuntime()).evalResultJs(jsPart, value, env);
      if (result.handled) value = result.value;
    }
    return value;
  }

  private findUnescapedDoubleHash(value: string): number {
    for (let i = 0; i < value.length - 1; i++) {
      if (value.charAt(i) === '#' && value.charAt(i + 1) === '#' && value.charAt(i - 1) !== '\\') {
        return i;
      }
    }
    return -1;
  }

  private expandRuleTemplate(value: string, ctx: RuleContext): string {
    return (value || '').replace(/\{\{\s*([^}]+?)\s*\}\}/g, (_: string, key: string) => {
      return ctx.get(key.trim());
    });
  }

  private async runStageRule(source: BookSource, book: Book, rawRule: string, content: string,
    baseUrl: string, stage: string, chapter: BookChapter | null = null): Promise<string> {
    const code = this.stageRuleCode(rawRule);
    if (!code) return '';
    const decision = BookSourceRuntimeRouter.decide(stage, `${source.jsLib || ''}\n${code}`);
    if (decision.runtime !== 'arkweb') {
      AppStorage.setOrCreate('bookSourceStageLastError', `${stage} 阶段未路由到完整脚本运行层`);
      return '';
    }
    const runtime = BookSourceStageWebRuntime.get();
    if (!await runtime.waitUntilAvailable()) {
      AppStorage.setOrCreate('bookSourceStageLastError', `${stage} 阶段脚本运行环境未就绪`);
      return '';
    }
    const request = new StageWebRuntimeRequest();
    request.source = source;
    request.book = book;
    request.chapter = chapter;
    request.readerActionMode = stage === SourceRuntimeStage.CONTENT;
    request.code = code;
    request.content = content || '';
    request.contextContent = content || '';
    request.baseUrl = baseUrl || book.bookUrl || source.bookSourceUrl;
    try {
      const result = await runtime.execute(request);
      return result.value || '';
    } catch (error) {
      console.warn('[WS] stage runtime failed, fallback legacy:', source.bookSourceName, stage, error);
      const message = error instanceof Error ? error.message : String(error || '');
      AppStorage.setOrCreate('bookSourceStageLastError', `${stage} 阶段：${message || '脚本执行失败'}`);
      return '';
    }
  }

  private async tryBuildSourceApiChapterList(source: BookSource, book: Book): Promise<BookChapter[]> {
    const apiBase = this.sourceApiBase(source);
    const tocScript = source.tocRule?.chapterList || '';
    if (!apiBase || !tocScript.includes('requestApiUrl') || !tocScript.includes('/catalog')) return [];
    const payload = EncodedSourceUrl.decode(book.tocUrl || '');
    if (!payload || !payload.text) return [];
    const novelId = payload.text.trim();
    const type = String(payload.options['type'] || 'novel').trim() || 'novel';
    const catalogValue = await this.fetchSourceApiData(source, apiBase, `/${type}/catalog`, {
      novelId: novelId
    });
    if (!Array.isArray(catalogValue)) return [];

    const cachedIds = new Set<string>();
    const cacheValue = await this.fetchSourceApiData(source, apiBase, `/${type}/cache`, {
      novelId: novelId
    });
    if (Array.isArray(cacheValue)) {
      for (const cacheItem of cacheValue as Object[]) {
        if (!cacheItem || typeof cacheItem !== 'object' || Array.isArray(cacheItem)) continue;
        const cacheRecord = cacheItem as Record<string, Object>;
        const cacheId = String(cacheRecord['chapId'] || cacheRecord['chapterId'] || cacheRecord['id'] || '');
        if (cacheId) cachedIds.add(cacheId);
      }
    }

    const chapters: BookChapter[] = [];
    for (const volumeItem of catalogValue as Object[]) {
      if (!volumeItem || typeof volumeItem !== 'object' || Array.isArray(volumeItem)) continue;
      const volume = volumeItem as Record<string, Object>;
      const rawChapters = volume['chapters'];
      const chapterValues = Array.isArray(rawChapters) ? rawChapters as Object[] : [volumeItem];
      for (const chapterItem of chapterValues) {
        if (!chapterItem || typeof chapterItem !== 'object' || Array.isArray(chapterItem)) continue;
        const record = chapterItem as Record<string, Object>;
        const chapterId = String(record['chapId'] || record['chapterId'] || record['id'] || '');
        const chapterName = String(record['chapName'] || record['chapterName'] || record['name'] || record['title'] || '');
        if (!chapterId || !chapterName) continue;
        const isVip = record['isVip'] === true || String(record['isVip'] || '') === 'true';
        const isBuy = record['isBuy'] === true || record['isPay'] === true ||
          String(record['isBuy'] || record['isPay'] || '') === 'true';
        const cached = cachedIds.has(chapterId);
        const chapter = new BookChapter();
        chapter.title = this.cleanChapterTitle((isVip ? (isBuy ? ' 🔑 ' : cached ? ' 🍋 ' : '') : '') + chapterName);
        chapter.url = `data:;base64,${this.base64Encode(chapterId)},{"type":"${type}","novelId":"${novelId}"}`;
        chapter.bookUrl = book.bookUrl;
        chapter.index = chapters.length;
        chapter.isVip = isVip && !cached;
        chapter.isPay = isBuy;
        const displayTime = String(record['displayTime'] || record['updateTime'] || '');
        const charCount = String(record['charCount'] || record['wordCount'] || '');
        if (displayTime || charCount) {
          chapter.variable = BookUrlResolver.setVariableJson(chapter.variable, 'updateTime',
            `${displayTime}${displayTime && charCount ? ' | ' : ''}${charCount}${charCount ? '字' : ''}`);
        }
        chapter.variable = BookUrlResolver.setVariableJson(chapter.variable, 'baseUrl', chapter.url);
        chapters.push(chapter);
      }
    }
    if (chapters.length > 0) {
      if (type === 'novel') book.type = 8;
      else if (type === 'audio') book.type = 32;
      else if (type === 'comic') book.type = 64;
      AppStorage.setOrCreate('bookSourceStageLastError', '');
    }
    return chapters;
  }

  private async tryGetSourceApiBookInfo(source: BookSource, book: Book): Promise<Book | null> {
    const apiBase = this.sourceApiBase(source);
    if (!apiBase || !book.bookUrl.startsWith(apiBase)) return null;
    const pathMatch = book.bookUrl.match(/\/(novel|audio|comic)\/info(?:\?|$)/);
    if (!pathMatch) return null;
    const type = String(pathMatch[1] || 'novel');
    const novelId = this.extractQueryParam(book.bookUrl, 'novelId') ||
      this.extractQueryParam(book.bookUrl, 'bookId') || this.extractQueryParam(book.bookUrl, 'id');
    if (!novelId) return null;
    const value = await this.fetchSourceApiData(source, apiBase, `/${type}/info`, { novelId: novelId });
    if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
    const data = value as Record<string, Object>;
    book.name = String(data['name'] || data['bookName'] || book.name || '');
    book.author = String(data['author'] || data['writer'] || book.author || '');
    book.coverUrl = String(data['cover'] || data['coverUrl'] || book.coverUrl || '');
    book.intro = BookFieldSanitizer.prefer(String(data['desc'] || data['intro'] || ''), book.intro);
    book.kind = BookFieldSanitizer.prefer([data['status'], data['category'], data['subCategory'], data['tag']]
      .map((entry: Object): string => String(entry || '').trim()).filter((entry: string): boolean => !!entry)
      .join(' '), book.kind);
    book.latestChapterTitle = BookFieldSanitizer.prefer(String(data['lastChapter'] ||
      data['latestChapterTitle'] || ''), book.latestChapterTitle);
    book.wordCount = BookFieldSanitizer.prefer(String(data['wordsCount'] || data['wordCount'] || ''), book.wordCount);
    const resolvedId = String(data['id'] || data['novelId'] || novelId);
    const resolvedType = String(data['type'] || type);
    book.tocUrl = `data:;base64,${this.base64Encode(resolvedId)},{"type":"${resolvedType}"}`;
    if (resolvedType === 'novel') book.type = 8;
    else if (resolvedType === 'audio') book.type = 32;
    else if (resolvedType === 'comic') book.type = 64;
    AppStorage.setOrCreate('bookSourceStageLastError', '');
    return book;
  }

  private async tryGetSourceApiContent(source: BookSource, book: Book,
    chapter: BookChapter): Promise<QtqdContentData> {
    const result = new QtqdContentData();
    const apiBase = this.sourceApiBase(source);
    const contentScript = source.contentRule?.content || '';
    if (!apiBase || !contentScript.includes('requestApiUrl') || !contentScript.includes('/chap')) return result;
    const payload = EncodedSourceUrl.decode(chapter.url || '');
    if (!payload || !payload.text) return result;
    const type = String(payload.options['type'] || '').trim();
    const novelId = String(payload.options['novelId'] || '').trim();
    if (!type || !novelId || type === 'volume') return result;
    const dataValue = await this.fetchSourceApiData(source, apiBase, `/${type}/chap`, {
      novelId: novelId,
      chapId: payload.text.trim()
    });
    if (!dataValue || typeof dataValue !== 'object' || Array.isArray(dataValue)) return result;
    const data = dataValue as Record<string, Object>;
    result.handled = true;
    result.audio = type === 'audio';
    if (type === 'audio') result.content = String(data['url'] || data['audioUrl'] || '');
    else if (type === 'comic') {
      const images = data['images'];
      result.content = Array.isArray(images) ? (images as Object[]).map((value: Object): string =>
        `<img src="${String(value || '')}">`).join('\n') : '';
    } else {
      result.content = String(data['content'] || data['text'] || '');
    }
    return result;
  }

  private sourceApiBase(source: BookSource): string {
    const library = source.jsLib || '';
    if (!/function\s+getApiUrl\s*\(|function\s+requestApiUrl\s*\(/.test(library)) return '';
    const match = library.match(/\b(?:const|let|var)\s+api\s*=\s*['"](https?:\/\/[^'"]+)['"]/);
    return match ? String(match[1] || '').replace(/\/$/, '') : '';
  }

  private async fetchSourceApiData(source: BookSource, apiBase: string, path: string,
    params: Record<string, string>): Promise<Object | null> {
    const query: string[] = [];
    for (const key in params) {
      const value = params[key];
      if (value !== '') query.push(`${encodeURIComponent(key)}=${encodeURIComponent(value)}`);
    }
    const option = JSON.stringify({
      method: 'GET',
      headers: { authorization: `Bearer ${source.variable || ''}` }
    });
    const response = await new AnalyzeUrl(source, this.http).fetch(`${apiBase}${path}?${query.join('&')},${option}`);
    if (!response.success || !response.body) return null;
    try {
      const root = JSON.parse(response.body) as Record<string, Object>;
      const message = String(root['msg'] || root['message'] || '');
      if (message && message !== 'success') return null;
      return root['data'] || null;
    } catch (_) {
      return null;
    }
  }

  private async getBookInfoFieldValue(source: BookSource, book: Book, rule: AnalyzeRule,
    rawRule: string, content: string, baseUrl: string, resolveUrl: boolean = false): Promise<string> {
    if (!rawRule) return '';
    const stageValue = await this.runStageRule(source, book, rawRule, content, baseUrl,
      SourceRuntimeStage.BOOK_INFO);
    if (stageValue) return resolveUrl ? BookUrlResolver.resolve(stageValue, baseUrl) : stageValue;
    return rule.getString(rawRule, resolveUrl);
  }

  private stageRuleCode(rawRule: string): string {
    const raw = (rawRule || '').trim();
    if (/^@?js:/i.test(raw)) return raw.replace(/^@?js:\s*/i, '');
    const leadingBlock = raw.match(/^<js>\s*([\s\S]*?)<\/js>/i);
    if (leadingBlock) return leadingBlock[1] || '';
    return '';
  }

  private parseStageChapterList(source: BookSource, book: Book, raw: string, baseUrl: string): BookChapter[] {
    let values: Object[] = [];
    try {
      const parsed = JSON.parse(raw || '[]') as Object;
      if (Array.isArray(parsed)) values = parsed;
    } catch (_) {
      return [];
    }
    const chapters: BookChapter[] = [];
    const tocRule = source.tocRule;
    for (const value of values) {
      if (!value || typeof value !== 'object' || Array.isArray(value)) continue;
      const item = JSON.stringify(value);
      const rule = new AnalyzeRule(item, baseUrl);
      const record = value as Record<string, Object>;
      const isVolume = record['isVolume'] === true || String(record['isVolume'] || '') === 'true';
      const title = this.cleanChapterTitle(rule.getString(tocRule.chapterName) || String(record['title'] || ''));
      let url = rule.getString(tocRule.chapterUrl) || String(record['url'] || '');
      if (!title || isVolume || !url) continue;
      if (!url.startsWith('data:')) url = BookUrlResolver.resolve(url, baseUrl);
      const chapter = new BookChapter();
      chapter.title = title;
      chapter.url = url;
      chapter.bookUrl = book.bookUrl;
      chapter.index = chapters.length;
      chapter.isVip = rule.getString(tocRule.isVip) === 'true' || record['v'] === true;
      chapter.variable = BookUrlResolver.setVariableJson(chapter.variable, 'baseUrl', baseUrl);
      const updateTime = rule.getString(tocRule.updateTime) || String(record['t'] || '');
      if (updateTime) chapter.variable = BookUrlResolver.setVariableJson(chapter.variable, 'updateTime', updateTime);
      chapters.push(chapter);
    }
    return chapters;
  }

  private async tryGetStageContent(source: BookSource, book: Book, chapter: BookChapter): Promise<string> {
    const rawRule = source.contentRule.content || '';
    const code = this.stageRuleCode(rawRule);
    if (!code) return '';
    const decision = BookSourceRuntimeRouter.decide(SourceRuntimeStage.CONTENT,
      `${source.jsLib || ''}\n${code}`);
    if (decision.runtime !== 'arkweb') return '';
    const runtime = BookSourceStageWebRuntime.get();
    if (!await runtime.waitUntilAvailable()) return '';
    let content = '';
    let baseUrl = chapter.url || book.bookUrl || source.bookSourceUrl;
    const payload = EncodedSourceUrl.decode(chapter.url);
    if (payload && (payload.type === 'qtqd' || this.ruleExpectsHexDataUrlInput(rawRule))) {
      content = this.textToHex(payload.text);
    } else {
      const response = await new AnalyzeUrl(source, this.http).fetch(chapter.url);
      if (!response.success || !response.body) return '';
      content = response.body;
      baseUrl = BookUrlResolver.effectiveBase(response, chapter.url, book.bookUrl || source.bookSourceUrl);
    }
    return await this.runStageRule(source, book, rawRule, content, baseUrl, SourceRuntimeStage.CONTENT, chapter);
  }

  private stageDataUrlInput(rawRule: string, url: string, fallback: string): string {
    if (!this.ruleExpectsHexDataUrlInput(rawRule)) return fallback;
    const payload = EncodedSourceUrl.decode(url);
    return payload ? this.textToHex(payload.text) : fallback;
  }

  private ruleExpectsHexDataUrlInput(rawRule: string): boolean {
    return /\bjava\s*\.\s*hexDecodeToString\s*\(\s*(?:String\s*\(\s*)?result\b/.test(rawRule || '');
  }

  private textToHex(value: string): string {
    const bytes = new util.TextEncoder().encodeInto(value || '');
    let result = '';
    for (const byte of bytes) result += Number(byte).toString(16).padStart(2, '0');
    return result;
  }

  private resolveVars(url: string, ctx: RuleContext): string {
    // 替换 @get:{key} 模式
    return url.replace(/@get:\{(\w+)\}/g, (_: string, key: string) => {
      return ctx.get(key);
    });
  }

  private getChapterBaseUrl(chapter: BookChapter, book: Book, source: BookSource): string {
    return BookUrlResolver.getVariableJson(chapter.variable, 'baseUrl') || chapter.url || book.tocUrl || book.bookUrl || source.bookSourceUrl;
  }

  private seedBookVariables(ctx: RuleContext, bookUrl: string): void {
    if (!bookUrl) return;
    ctx.put('book.bookUrl', bookUrl);
    ctx.put('bookUrl', bookUrl);
    const id = this.extractQueryParam(bookUrl, 'book_id') || this.extractQueryParam(bookUrl, 'bookid') ||
      this.extractQueryParam(bookUrl, 'id') || this.extractBookId(bookUrl);
    if (id) {
      if (!ctx.get('book')) ctx.put('book', id);
      if (!ctx.get('book_id')) ctx.put('book_id', id);
      if (!ctx.get('id')) ctx.put('id', id);
    }
  }

  private seedChapterVariables(ctx: RuleContext, chapter: BookChapter): void {
    ctx.put('chapter.title', chapter.title || '');
    ctx.put('chapter.url', chapter.url || '');
    ctx.put('chapter.index', String(chapter.index));
    ctx.put('chapterTitle', chapter.title || '');
  }

  private urlWithoutFragment(url: string): string {
    const index = (url || '').indexOf('#');
    return index >= 0 ? url.substring(0, index) : (url || '');
  }

  private seedSourceVariables(ctx: RuleContext, source: BookSource): void {
    ctx.put('source.bookSourceUrl', source.bookSourceUrl || '');
    ctx.put('bookSourceUrl', source.bookSourceUrl || '');
    ctx.put('source.bookSourceName', source.bookSourceName || '');
    ctx.put('bookSourceName', source.bookSourceName || '');
    ctx.put('source.bookSourceGroup', source.bookSourceGroup || '');
    ctx.put('bookSourceGroup', source.bookSourceGroup || '');
    ctx.put('source.bookSourceComment', source.bookSourceComment || '');
    ctx.put('bookSourceComment', source.bookSourceComment || '');
    ctx.put('source.jsLib', source.jsLib || '');
    ctx.put('jsLib', source.jsLib || '');
    if (!ctx.has('source.variable')) ctx.put('source.variable', source.variable || '');
  }

  private extractQueryParam(url: string, key: string): string {
    const re = new RegExp(`[?&]${key}=([^&]+)`, 'i');
    const m = url.match(re);
    return m ? decodeURIComponent(m[1]) : '';
  }

  private resolveJsonKey(itemData: Record<string, Object> | null, tocData: Record<string, Object> | null, key: string, deep: boolean): string {
    // 优先从 item 数据查找
    if (itemData) {
      const v = deep ? this.deepSearch(itemData, key) : String(itemData[key] ?? '');
      if (v) return v;
    }
    // 回退到 TOC 完整数据
    if (tocData) {
      const v = deep ? this.deepSearch(tocData, key) : String(tocData[key] ?? '');
      if (v) return v;
    }
    return '';
  }

  private deepSearch(obj: Object, key: string): string {
    if (!obj || typeof obj !== 'object') return '';
    if (Array.isArray(obj)) {
      for (const item of obj) {
        const r = this.deepSearch(item as Object, key);
        if (r) return r;
      }
    } else {
      const rec = obj as Record<string, Object>;
      if (rec[key] !== undefined) return String(rec[key]);
      for (const k in rec) {
        const r = this.deepSearch(rec[k] as Object, key);
        if (r) return r;
      }
    }
    return '';
  }

  private async tryBuildSpecialChapterList(source: BookSource, book: Book, body: string): Promise<BookChapter[]> {
    const fanqieVolumeChapters = this.tryBuildFanqieVolumeChapterList(source, book, body);
    if (fanqieVolumeChapters.length > 0) return fanqieVolumeChapters;

    if (!source.tocRule.chapterList.includes('allItemIds') && !source.tocRule.chapterList.includes('directory/detail')) {
      return [];
    }
    try {
      const root = JSON.parse(body) as Record<string, Object>;
      const data = root['data'] as Record<string, Object>;
      const ids = data?.['allItemIds'] as Object[];
      if (!Array.isArray(ids) || ids.length === 0) return [];

      const chapters: BookChapter[] = [];
      for (let i = 0; i < ids.length; i += 100) {
        const part = ids.slice(i, Math.min(i + 100, ids.length)).map(v => String(v)).join(',');
        const detailUrl = `https://novel.snssdk.com/api/novel/book/directory/detail/v1/?item_ids=${part}`;
        const detailHeaders: Record<string, string> = {};
        const detailCookie = VerificationSupport.sourceCookieHeader(source, detailUrl);
        if (detailCookie) detailHeaders['Cookie'] = detailCookie;
        const resp = await this.http.execute({
          url: detailUrl,
          method: 'GET',
          headers: detailHeaders
        });
        if (this.requestVerificationIfNeeded(source, resp.url || source.bookSourceUrl, resp.body, resp.statusCode, source.tocRule.chapterList)) {
          return [];
        }
        if (!resp.success || !resp.body) continue;
        const detail = JSON.parse(resp.body) as Record<string, Object>;
        const list = detail['data'] as Object[];
        if (!Array.isArray(list)) continue;
        for (const item of list) {
          const rec = item as Record<string, Object>;
          const itemId = String(rec['item_id'] || rec['id'] || '');
          if (!itemId) continue;
          const chapter = new BookChapter();
          chapter.title = this.cleanChapterTitle(String(rec['title'] || `第${chapters.length + 1}章`));
          chapter.url = `data:;base64,${this.base64Encode(itemId)},{"type":"pyfqc"}`;
          chapter.bookUrl = book.bookUrl;
          chapter.index = chapters.length;
          chapters.push(chapter);
        }
      }
      return chapters;
    } catch (e) {
      console.warn('[WS] 特殊目录拼装失败:', e);
      return [];
    }
  }

  /**
   * Some Legado sources generate their whole catalog in a JavaScript-only rule and encode each
   * chapter as a `type: qtqd` data URL. Keep that protocol usable even when the shared ArkWeb
   * runtime is temporarily unavailable after a page navigation.
   */
  private async tryBuildQtqdChapterList(source: BookSource, book: Book): Promise<BookChapter[]> {
    const tocScript = source.tocRule?.chapterList || '';
    if (!tocScript.includes('/catalog') || !tocScript.includes('qtqd') || !tocScript.includes('bookId')) return [];

    const location = book.tocUrl || book.bookUrl || '';
    const bookId = this.extractQueryParam(location, 'bookId') || this.extractQueryParam(location, 'book_id') ||
      this.extractQueryParam(book.bookUrl || '', 'bookId') || this.extractQueryParam(book.bookUrl || '', 'book_id');
    const host = this.qtqdBackendHost(source, location || book.bookUrl);
    if (!bookId || !host) return [];

    const account = this.qtqdSourceSection(source.variable, '账户设置');
    const settings = this.qtqdSourceSection(source.variable, '书源设置');
    const key = String(account['key'] || '');
    const dttoken = String(account['dttoken'] || '');
    const midpage = String(settings['彩蛋章节'] ?? 'true').toLowerCase() !== 'false';
    let requestUrl = `${host}/catalog?cached=true&bookId=${encodeURIComponent(bookId)}`;
    if (tocScript.includes('midpage=')) requestUrl += `&midpage=${midpage ? 'true' : 'false'}`;
    const safeCatalogUrl = requestUrl;
    requestUrl += `&key=${encodeURIComponent(key)}&device=harmony&dttoken=${encodeURIComponent(dttoken)}`;

    try {
      const response = await new AnalyzeUrl(source, this.http).fetch(requestUrl, 8 * 1024 * 1024);
      if (!response.success || !response.body) return [];
      const root = JSON.parse(response.body) as Record<string, Object>;
      const data = root['Data'];
      if (!data || typeof data !== 'object' || Array.isArray(data)) return [];
      const recordsValue = (data as Record<string, Object>)['Chapters'];
      if (!Array.isArray(recordsValue)) return [];

      const cleanLocks = String(settings['净化目录标题'] ?? 'false').toLowerCase() !== 'false';
      const audio = source.bookSourceType === 1 || (source.contentRule?.content || '').includes('/chapter/tts');
      const chapters: BookChapter[] = [];
      const records = recordsValue as Object[];
      for (const value of records) {
        if (!value || typeof value !== 'object' || Array.isArray(value)) continue;
        const record = value as Record<string, Object>;
        const chapterId = String(record['C'] ?? '');
        if (!(Number(chapterId) > 0 || chapterId.includes('_'))) continue;
        let title = String(record['N'] || '');
        if (cleanLocks) title = title.replace(/🔒|🔑/g, '');
        title = this.cleanChapterTitle(title || `第${chapters.length + 1}章`);
        if (!title) continue;

        const payload: Record<string, Object> = {
          bookId: bookId,
          timestamp: record['T'] ?? 0,
          id: record['C'] ?? chapterId,
          v: Number(record['V'] || 0) === 1,
          index: record['index'] ?? chapters.length
        };
        if (audio) payload['t'] = 1;
        const chapter = new BookChapter();
        chapter.title = title;
        chapter.url = EncodedSourceUrl.encodeRaw(JSON.stringify(payload), 'qtqd');
        chapter.bookUrl = book.bookUrl;
        chapter.index = chapters.length;
        chapter.isVip = Number(record['V'] || 0) === 1;
        chapter.variable = BookUrlResolver.setVariableJson(chapter.variable, 'baseUrl', safeCatalogUrl);
        const updateTime = `${record['cached'] === true ? '🔅 ' : ''}${String(record['T'] || '')}` +
          `${record['W'] === undefined ? '' : ` ${String(record['W'])}字`}`;
        if (updateTime.trim()) {
          chapter.variable = BookUrlResolver.setVariableJson(chapter.variable, 'updateTime', updateTime.trim());
        }
        chapters.push(chapter);
      }
      if (chapters.length > 0) {
        console.info('[WS] qtqd native catalog:', chapters.length, 'from:', book.name || book.bookUrl);
      }
      return chapters;
    } catch (error) {
      console.warn('[WS] qtqd native catalog failed, keep scripted path:', source.bookSourceName, error);
      return [];
    }
  }

  private async tryGetQtqdContent(source: BookSource, book: Book, chapter: BookChapter): Promise<QtqdContentData> {
    const result = new QtqdContentData();
    const payload = EncodedSourceUrl.decode(chapter.url);
    if (!payload || payload.type !== 'qtqd') return result;
    result.handled = true;

    const data = payload.data;
    const bookId = EncodedSourceUrl.str(data['bookId']) || EncodedSourceUrl.str(data['book_id']);
    const chapterId = EncodedSourceUrl.str(data['id']) || EncodedSourceUrl.str(data['chapterId']);
    const timestamp = EncodedSourceUrl.str(data['timestamp']);
    const index = EncodedSourceUrl.str(data['index']);
    const isVip = String(data['v'] || '').toLowerCase() === 'true' || String(data['v'] || '') === '1';
    const contentScript = source.contentRule?.content || '';
    result.audio = String(data['t'] || '') === '1' || source.bookSourceType === 1 ||
      contentScript.includes('/chapter/tts');
    const host = this.qtqdBackendHost(source, book.bookUrl || book.tocUrl);
    if (!bookId || !chapterId || !host) {
      result.content = result.audio ? '' : '企点章节参数不完整，请刷新目录后重试。';
      return result;
    }

    const account = this.qtqdSourceSection(source.variable, '账户设置');
    const settings = this.qtqdSourceSection(source.variable, '书源设置');
    const key = this.qtqdCredential(source, host, account, 'key');
    const dttoken = this.qtqdCredential(source, host, account, 'dttoken');
    const para = this.qtqdBooleanSetting(settings, '段评开关', true) ? '1' : '0';
    const god = this.qtqdBooleanSetting(settings, '神评论', true) ? 'true' : 'false';
    const img = this.qtqdBooleanSetting(settings, '文内配图', true) ? '1' : '0';
    const chapterComments = this.qtqdBooleanSetting(settings, '本章说', true);
    const path = result.audio ? '/chapter/tts' : (isVip ? '/chapter/vip' : '/chapter/free');
    let requestUrl = `${host}${path}?bookId=${encodeURIComponent(bookId)}` +
      `&chapterId=${encodeURIComponent(chapterId)}&para=${para}&god=${god}&img=${img}` +
      `&timestamp=${encodeURIComponent(timestamp)}`;
    if (isVip && index) requestUrl += `&index=${encodeURIComponent(index)}`;
    if (result.audio) requestUrl += `&type=${encodeURIComponent(book.getVariable('custom') || '6001')}`;
    requestUrl += `&key=${encodeURIComponent(key)}&device=harmony&dttoken=${encodeURIComponent(dttoken)}`;

    try {
      const response = await new AnalyzeUrl(source, this.http).fetch(requestUrl, 8 * 1024 * 1024);
      if (!response.body) {
        result.handled = false;
        return result;
      }
      const root = JSON.parse(response.body) as Record<string, Object>;
      if (result.audio) {
        const audioData = root['data'];
        if (audioData && typeof audioData === 'object' && !Array.isArray(audioData)) {
          result.content = String((audioData as Record<string, Object>)['playUrl'] || '');
        }
      } else {
        result.content = String(root['content'] || '');
      }
      if (result.content) {
        if (!result.audio) {
          result.content = this.normalizeQtqdInteractionUrls(result.content, host);
          const videoUrl = this.qtqdAbsoluteUrl(host, String(root['videoUrl'] || ''));
          if (videoUrl) {
            const videoMarker = ReaderActionMarker.create('播放视频', videoUrl, '视频');
            if (videoMarker) result.content += `\n${videoMarker}`;
          }
          if (chapterComments && !chapterId.includes('_')) {
            const commentUrl = `${host}/chapterComments?bookId=${encodeURIComponent(bookId)}` +
              `&chapterId=${encodeURIComponent(chapterId)}`;
            const commentMarker = ReaderActionMarker.create('本章说', commentUrl, '本章说');
            if (commentMarker) result.content += `\n${commentMarker}`;
          }
        }
        return result;
      }

      const message = String(root['message'] || root['Message'] || '');
      if (!response.success || response.statusCode === 401 || message.includes('登录')) {
        result.content = result.audio ? '' : '请先在企点书源登录面板填写密钥和口令，然后刷新本章。';
      } else if (/JSON\.parse\s*\(\s*undefined\s*\)/i.test(message)) {
        result.content = result.audio ? '' : '企点正文接口返回异常，请刷新本章重试。';
      } else {
        result.content = result.audio ? '' : (message || '企点正文暂时不可用，请稍后刷新本章。');
      }
      return result;
    } catch (error) {
      console.warn('[WS] qtqd native content failed, keep scripted path:', source.bookSourceName, error);
      result.handled = false;
      result.content = '';
      return result;
    }
  }

  private qtqdBooleanSetting(settings: Record<string, Object>, key: string, fallback: boolean): boolean {
    if (settings[key] === undefined || settings[key] === null || String(settings[key]).trim() === '') return fallback;
    const value = String(settings[key]).trim().toLowerCase();
    return value !== 'false' && value !== '0' && value !== 'off' && value !== '❌';
  }

  private qtqdCredential(source: BookSource, host: string, account: Record<string, Object>, key: string): string {
    const stored = String(account[key] || '');
    if (stored) return stored;
    try {
      const loginInfo = JSON.parse(source.loginInfo || '{}') as Record<string, Object>;
      const direct = String(loginInfo[key] || '');
      if (direct) return direct;
    } catch (_) {}
    return CookieStore.getCookieValue(host, key);
  }

  private normalizeQtqdInteractionUrls(content: string, host: string): string {
    return (content || '').replace(/(\bident\s*=\s*)(["'])([^"']*)\2/gi,
      (_all: string, prefix: string, quote: string, rawUrl: string): string => {
        const url = this.qtqdAbsoluteUrl(host, this.decodeHtmlEntities(rawUrl || ''));
        const escaped = url.replace(/&/g, '&amp;').replace(/"/g, '&quot;');
        return `${prefix}${quote}${escaped}${quote}`;
      });
  }

  private qtqdAbsoluteUrl(host: string, rawUrl: string): string {
    const url = (rawUrl || '').trim();
    if (!url) return '';
    if (/^https?:\/\//i.test(url)) return url;
    if (url.startsWith('//')) return `${host.startsWith('http://') ? 'http:' : 'https:'}${url}`;
    return `${host.replace(/\/$/, '')}/${url.replace(/^\/+/, '')}`;
  }

  private qtqdBackendHost(source: BookSource, location: string): string {
    const scriptMatch = (source.jsLib || '').match(/\b(?:const|let|var)\s+sb\s*=\s*['"](https?:\/\/[^'"/]+(?:\:\d+)?)['"]/);
    if (scriptMatch && scriptMatch[1]) return scriptMatch[1].replace(/\/$/, '');
    const locationMatch = (location || '').match(/^(https?:\/\/[^/]+)/);
    if (locationMatch && locationMatch[1] && /\/detail(?:[?#]|$)/.test(location || '')) return locationMatch[1];
    return '';
  }

  private qtqdSourceSection(raw: string, section: string): Record<string, Object> {
    try {
      const value = JSON.parse(raw || '{}') as Record<string, Object>;
      const nested = value[section];
      if (nested && typeof nested === 'object' && !Array.isArray(nested)) {
        return nested as Record<string, Object>;
      }
    } catch (_) {}
    return {};
  }

  private tryBuildFanqieVolumeChapterList(source: BookSource, book: Book, body: string): BookChapter[] {
    if (!source.tocRule.chapterList.includes('chapterListWithVolume')) return [];
    try {
      const root = JSON.parse(body) as Record<string, Object>;
      const data = root['data'] as Record<string, Object>;
      const volumeList = data?.['chapterListWithVolume'] as Object[];
      if (!Array.isArray(volumeList) || volumeList.length === 0) return [];

      const chapters: BookChapter[] = [];
      const base = BookUrlResolver.cleanBaseUrl(source.bookSourceUrl);
      for (const volume of volumeList) {
        if (!Array.isArray(volume)) continue;
        for (const item of volume) {
          const rec = item as Record<string, Object>;
          const itemId = String(rec['itemId'] || rec['item_id'] || rec['id'] || '');
          if (!itemId) continue;
          const chapter = new BookChapter();
          chapter.title = this.cleanChapterTitle(String(rec['title'] || `第${chapters.length + 1}章`));
          chapter.url = `${base}/content?item_id=${encodeURIComponent(itemId)}`;
          chapter.bookUrl = book.bookUrl;
          chapter.index = chapters.length;
          chapter.isVip = String(rec['isVip'] || rec['is_vip'] || '') === 'true';
          chapter.variable = BookUrlResolver.setVariableJson(chapter.variable, 'baseUrl', chapter.url);
          chapters.push(chapter);
        }
      }
      if (chapters.length > 0) {
        console.log('[WS] 番茄卷目录拼装:', chapters.length, 'from:', book.name || book.bookUrl);
      }
      return chapters;
    } catch (e) {
      console.warn('[WS] 番茄卷目录拼装失败:', e);
      return [];
    }
  }

  private async tryGetSpecialContent(source: BookSource, chapter: BookChapter): Promise<string> {
    const signedContent = await this.tryGetJsLibSignedContent(source, chapter);
    if (signedContent) return signedContent;
    if (!chapter.url.startsWith('data:;base64,') || !source.contentRule.content.includes('item_id')) {
      return '';
    }
    try {
      const idPart = chapter.url.substring('data:;base64,'.length).split(',')[0];
      const itemId = this.base64Decode(idPart);
      const contentUrl = `${source.bookSourceUrl.replace(/##[\s\S]*$/, '')}/content?item_id=${encodeURIComponent(itemId)}&key=`;
      const headers: Record<string, string> = {
        'Accept': 'application/json, text/plain, */*',
        'Content-Type': 'application/json'
      };
      const cookie = VerificationSupport.sourceCookieHeader(source, contentUrl);
      if (cookie) headers['Cookie'] = cookie;
      const resp = await this.http.execute({
        url: contentUrl,
        method: 'GET',
        headers: headers
      });
      if (this.requestVerificationIfNeeded(source, resp.url || chapter.url, resp.body, resp.statusCode, source.contentRule.content)) {
        return '';
      }
      if (!resp.success || !resp.body) return '';
      const json = JSON.parse(resp.body) as Record<string, Object>;
      const data = json['data'] as Record<string, Object>;
      return String(data?.['content'] || '');
    } catch (e) {
      console.warn('[WS] 特殊正文获取失败:', e);
      return '';
    }
  }

  private async tryGetJsLibSignedContent(source: BookSource, chapter: BookChapter): Promise<string> {
    const script = source.jsLib || '';
    if (!chapter.url.includes('chapter_ids=') || !chapter.url.includes('nid=') ||
      !script.includes('requestKey') || !script.includes('digestHex')) return '';
    try {
      const nid = this.extractQueryParam(chapter.url, 'nid');
      const chapterIds = this.extractQueryParam(chapter.url, 'chapter_ids');
      if (!nid || !chapterIds) return '';
      const version = this.extractJsLiteral(script, 'ver') || 'android_02050803';
      const salt = this.extractJsLiteral(script, 'f');
      if (!salt) return '';
      const timestamp = String(Math.floor(Date.now() / 1000));
      const digest = this.digestHex(`chapter_ids=${chapterIds}&nid=${nid}${timestamp}${version}${salt}`, 'SHA256');
      const range = script.match(/digestHex\([\s\S]*?\)\.substring\(\s*(\d+)\s*,\s*(\d+)\s*\)/);
      const start = range ? parseInt(range[1]) : 10;
      const end = range ? parseInt(range[2]) : 42;
      const requestKey = digest.substring(start, end);
      if (!requestKey) return '';

      const token = this.extractLoginToken(source.loginHeader || '');
      const headers: Record<string, string> = {
        'User-Agent': this.extractHeaderLiteral(script, 'User-Agent') ||
          'chang pei yue du/2.5.8.3 (Android 13; HarmonyOS; Mobile)',
        'randStr': timestamp,
        'version': version,
        'requestKey': requestKey,
        'client': this.extractHeaderLiteral(script, 'client') || 'android',
        'imei': this.extractHeaderLiteral(script, 'imei') || '455321005bc9cd38',
        'referer': this.extractHeaderLiteral(script, 'referer') || source.bookSourceUrl,
        'token': token
      };
      const response = await this.http.execute({ url: chapter.url, method: 'GET', headers: headers });
      if (!response.success || !response.body) return '';
      const root = JSON.parse(response.body) as Object;
      return this.deepStringValue(root, 'content');
    } catch (e) {
      console.warn('[WS] JS 签名正文请求失败:', e);
      return '';
    }
  }

  private extractJsLiteral(script: string, name: string): string {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const match = script.match(new RegExp(`\\b${escaped}\\s*=\\s*(["'])([\\s\\S]*?)\\1`));
    return match ? match[2] : '';
  }

  private extractHeaderLiteral(script: string, name: string): string {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const match = script.match(new RegExp(`["']?${escaped}["']?\\s*:\\s*(["'])([\\s\\S]*?)\\1`, 'i'));
    return match ? match[2] : '';
  }

  private extractLoginToken(loginHeader: string): string {
    const value = (loginHeader || '').trim().replace(/^&/, '');
    if (!value) return '';
    try {
      const data = JSON.parse(value) as Record<string, Object>;
      return String(data['token'] || '');
    } catch (_) {
      return '';
    }
  }

  private digestHex(input: string, algorithm: string): string {
    const digest = cryptoFramework.createMd(algorithm);
    digest.updateSync({ data: new util.TextEncoder().encodeInto(input) });
    const result = digest.digestSync().data;
    let hex = '';
    for (let i = 0; i < result.length; i++) hex += result[i].toString(16).padStart(2, '0');
    return hex;
  }

  private deepStringValue(value: Object, key: string): string {
    if (!value || typeof value !== 'object') return '';
    if (Array.isArray(value)) {
      for (const item of value) {
        const found = this.deepStringValue(item as Object, key);
        if (found) return found;
      }
      return '';
    }
    const record = value as Record<string, Object>;
    if (record[key] !== undefined && record[key] !== null) return String(record[key]);
    for (const name in record) {
      const found = this.deepStringValue(record[name], key);
      if (found) return found;
    }
    return '';
  }

  private base64Encode(input: string): string {
    try {
      const e = new util.TextEncoder();
      return new util.Base64Helper().encodeToStringSync(e.encodeInto(input));
    } catch (_) {
      return input;
    }
  }

  private base64Decode(input: string): string {
    try {
      const data = new util.Base64Helper().decodeSync(input);
      return util.TextDecoder.create('utf-8').decodeWithStream(data, { stream: false });
    } catch (_) {
      return input;
    }
  }
}
