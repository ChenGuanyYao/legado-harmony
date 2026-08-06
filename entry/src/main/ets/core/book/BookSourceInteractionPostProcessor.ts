import { Book, BookChapter, BookSource } from '../../model/data/Book';
import { BookUrlResolver } from './BookUrlResolver';
import { EncodedJsonMap, EncodedSourceUrl } from './EncodedSourceUrl';
import { BookSourceStageWebRuntime, StageWebRuntimeRequest } from './BookSourceStageWebRuntime';
import { ReaderActionMarker } from './ReaderActionMarker';
import { CookieStore } from '../http/CookieStore';
import { HttpClient } from '../http/HttpClient';

class ParagraphCommentPlan {
  sourceType: string = '';
  sourceName: string = '';
  bookId: string = '';
  chapterId: string = '';
  contentMd5: string = '';
  extra: Record<string, string> = {};
}

/**
 * Optional interaction layer for content already fetched/decrypted by a native shortcut protocol.
 * Failures here always return the readable body so comments, images or media actions can never
 * make the chapter itself unavailable.
 */
export class BookSourceInteractionPostProcessor {
  static async process(source: BookSource, book: Book, chapter: BookChapter, content: string): Promise<string> {
    if (!content) return '';
    let result = content;
    const commentsEnabled = this.isParagraphCommentsEnabled(source);
    const commentPlan = this.buildCommentPlan(source, chapter, book);
    if (commentPlan?.sourceType === 'sq' &&
      (commentsEnabled || this.isNamedSettingEnabled(source, '章评开关'))) {
      result = await this.applyShuqiComments(source, result, commentPlan);
    }
    if (commentPlan?.sourceType === 'qd' && this.hasQidianCommentsEnabled(source)) {
      result = await this.applyQidianComments(source, result, commentPlan);
    }
    if (commentPlan && /<(?:comment|img)\b[^>]*\bident\s*=/i.test(result)) {
      result = this.normalizeReviewMarkup(source, chapter, result, commentPlan);
    }
    if (!/<comment\b/i.test(result) && commentsEnabled &&
      /\bfunction\s+getComments\s*\(/.test(source.jsLib || '')) {
      if (commentPlan && BookSourceStageWebRuntime.get().isAvailable()) {
        result = await this.runCommentHelper(source, book, chapter, result, commentPlan);
        result = this.normalizeReviewMarkup(source, chapter, result, commentPlan);
      }
    }
    if (!/<comment\b/i.test(result) && commentsEnabled && commentPlan) {
      result = this.appendQingtianChapterCommentFallback(source, chapter, result, commentPlan);
    }
    if (commentPlan && this.isChapterCommentsEnabled(source)) {
      result = this.appendChapterCommentAction(source, chapter, result, commentPlan);
    }
    return this.appendMediaAction(chapter, result);
  }

  static shouldRequestParagraphComments(source: BookSource, chapter: BookChapter): boolean {
    if (!this.isParagraphCommentsEnabled(source)) return false;
    const plan = this.buildCommentPlan(source, chapter);
    if (!plan) return false;
    return ['fq', 'qm', 'td', 'qq'].includes(plan.sourceType);
  }

  static interactionCacheIdentity(source: BookSource): string {
    const script = `${source.contentRule?.content || ''}\n${source.jsLib || ''}`;
    if (!/段评|章评|评论|comment|review|showSqComments/i.test(script)) return '';
    const keys = ['段评开关', '章评开关', '章名段评', '本章讨论', '作者评论', '热门评论',
      '本章说开关', '神评论开关', '书旗评论 API Key'];
    const values: string[] = [];
    for (const key of keys) values.push(`${key}=${this.sourceSetting(source, key)}`);
    if (/\bSQ_COMMENT_API_BASE\b/.test(script)) values.push('shuqiMarker=compact-v2');
    return values.join('&');
  }

  static shouldRequestGodComments(source: BookSource, chapter: BookChapter): boolean {
    const plan = this.buildCommentPlan(source, chapter);
    return !!plan && plan.sourceType === 'fq' && this.isGodCommentsEnabled(source);
  }

  private static appendQingtianChapterCommentFallback(source: BookSource, chapter: BookChapter, content: string,
    plan: ParagraphCommentPlan): string {
    const payload = EncodedSourceUrl.decode(chapter.url);
    const isQingtian = payload?.type === 'qingtian3' || (source.bookSourceName || '').includes('晴天');
    if (!isQingtian || plan.sourceType !== 'fq') return content;
    const optionScript = payload ? EncodedSourceUrl.str(payload.options['js']) : '';
    const scriptedUrl = this.firstReviewUrl(optionScript);
    const host = this.sourceSetting(source, 'server') || this.firstHttpHost(source.jsLib || '');
    const sessionId = this.sourceSetting(source, 'fqssionid') || this.sourceSetting(source, 'sessionid');
    const url = scriptedUrl || (host ? `${host.replace(/\/+$/, '')}/get_review?book_id=` +
      `${encodeURIComponent(plan.bookId)}&item_id=${encodeURIComponent(plan.chapterId)}` +
      `&ssionid=${encodeURIComponent(sessionId)}` : '');
    const marker = ReaderActionMarker.create('本章段评', url, '本章段评');
    if (!marker) return content;
    const lines = (content || '').split('\n');
    for (let index = 0; index < lines.length; index++) {
      if (!lines[index].trim()) continue;
      lines[index] = `${lines[index]}${marker}`;
      console.info('[InteractionPostProcessor] qingtian chapter comment fallback:', source.bookSourceName,
        `chapter=${chapter.index}:${chapter.title}`);
      return lines.join('\n');
    }
    return content;
  }

  private static firstReviewUrl(script: string): string {
    const match = (script || '').match(/https?:\/\/[^'"`\s]+\/(?:get_review|get_para_review)[^'"`\s]*/i);
    return match && match[0] ? this.decodeHtmlEntities(match[0]) : '';
  }

  private static normalizeReviewMarkup(source: BookSource, chapter: BookChapter, content: string,
    plan: ParagraphCommentPlan): string {
    return (content || '').replace(/(\bident\s*=\s*)(["'])([\s\S]*?)\2/gi,
      (_all: string, prefix: string, quote: string, rawUrl: string): string => {
        const url = this.normalizeReviewUrl(source, chapter, rawUrl, plan);
        return `${prefix}${quote}${this.encodeHtmlAttribute(url)}${quote}`;
      });
  }

  private static normalizeReviewUrl(source: BookSource, chapter: BookChapter, rawUrl: string,
    plan: ParagraphCommentPlan): string {
    let url = this.decodeHtmlEntities(rawUrl || '').trim();
    const host = this.reviewHost(source, chapter);
    if (url.startsWith('//')) {
      url = `${host.startsWith('http://') ? 'http:' : 'https:'}${url}`;
    } else if (url.startsWith('/') && host) {
      url = `${host.replace(/\/+$/, '')}${url}`;
    } else if (url && !/^https?:\/\//i.test(url) && host) {
      url = `${host.replace(/\/+$/, '')}/${url.replace(/^\/+/, '')}`;
    }
    url = this.fillEmptyQueryValue(url, 'book_id', plan.bookId);
    url = this.fillEmptyQueryValue(url, 'item_id', plan.chapterId);
    url = this.appendQueryValue(url, 'book_id', plan.bookId);
    url = this.appendQueryValue(url, 'item_id', plan.chapterId);
    const sessionId = this.fanqieSessionId(source);
    if (plan.sourceType === 'fq' && sessionId) url = this.appendQueryValue(url, 'ssionid', sessionId);
    if (plan.sourceName) url = this.appendQueryValue(url, 'source', plan.sourceName.replace(/^svip_/, ''));
    return url;
  }

  private static fillEmptyQueryValue(url: string, key: string, value: string): string {
    if (!url || !key || !value) return url;
    const pattern = new RegExp(`([?&]${key}=)(?=&|$)`, 'i');
    return pattern.test(url) ? url.replace(pattern, `$1${encodeURIComponent(value)}`) : url;
  }

  private static appendQueryValue(url: string, key: string, value: string): string {
    if (!url || !key || !value || new RegExp(`(?:[?&])${key}=[^&]+`, 'i').test(url)) return url;
    return `${url}${url.includes('?') ? '&' : '?'}${key}=${encodeURIComponent(value)}`;
  }

  private static encodeHtmlAttribute(value: string): string {
    return (value || '').replace(/&/g, '&amp;').replace(/"/g, '&quot;');
  }

  private static reviewHost(source: BookSource, chapter: BookChapter): string {
    const payload = EncodedSourceUrl.decode(chapter.url);
    const payloadHost = payload ? EncodedSourceUrl.str(payload.data['host']) ||
      EncodedSourceUrl.str(payload.options['host']) : '';
    if (payloadHost) return payloadHost.replace(/\/+$/, '');
    try {
      const variable = JSON.parse(chapter.variable || '{}') as Record<string, Object>;
      if (variable['host']) return String(variable['host']).replace(/\/+$/, '');
    } catch (_) {}
    return (this.sourceSetting(source, '线路') || this.sourceSetting(source, 'server') ||
      this.firstHttpHost(source.jsLib || '')).replace(/\/+$/, '');
  }

  private static fanqieSessionId(source: BookSource): string {
    const stored = this.sourceSetting(source, 'fqssionid') || this.sourceSetting(source, 'sessionid');
    if (stored) return stored;
    return CookieStore.getCookieValue('https://fanqienovel.com', 'sessionid') ||
      CookieStore.getCookieValue('fanqienovel.com', 'sessionid');
  }

  private static appendChapterCommentAction(source: BookSource, chapter: BookChapter, content: string,
    plan: ParagraphCommentPlan): string {
    if (plan.sourceType !== 'fq' || /\[\[LEGADO_READER_ACTION_V3:[^\]]*%E6%9C%AC%E7%AB%A0/i.test(content)) {
      return content;
    }
    const payload = EncodedSourceUrl.decode(chapter.url);
    const optionScript = payload ? EncodedSourceUrl.str(payload.options['js']) : '';
    const scriptedUrl = this.firstReviewUrl(optionScript);
    const host = this.reviewHost(source, chapter);
    let url = scriptedUrl || (host ? `${host}/get_review` : '');
    url = this.normalizeReviewUrl(source, chapter, url, plan);
    const marker = ReaderActionMarker.create('本章说', url, '本章说');
    if (!marker) return content;
    const lines = (content || '').split('\n');
    for (let index = lines.length - 1; index >= 0; index--) {
      if (!lines[index].trim()) continue;
      lines[index] = `${lines[index]}${marker}`;
      return lines.join('\n');
    }
    return content;
  }

  private static async runCommentHelper(source: BookSource, book: Book, chapter: BookChapter,
    content: string, plan: ParagraphCommentPlan): Promise<string> {
    const request = new StageWebRuntimeRequest();
    request.source = source;
    request.book = book;
    request.content = content;
    request.contextContent = content;
    request.baseUrl = chapter.url || book.bookUrl || source.bookSourceUrl;
    request.readerActionMode = true;
    request.networkTimeoutMs = 6000;
    request.code = `if(typeof getComments==='function'){result=getComments.call(globalThis,result,` +
      `${JSON.stringify(plan.bookId)},${JSON.stringify(plan.chapterId)},${JSON.stringify(plan.sourceType)},` +
      `${JSON.stringify(plan.contentMd5)},${JSON.stringify(plan.extra)});}result;`;
    try {
      const runtimeResult = await BookSourceStageWebRuntime.get().execute(request);
      let value = runtimeResult.value || content;
      if (!/<comment\b/i.test(value) && this.usesPortableFanqieComments(source)) {
        value = await this.runPortableFanqieComments(source, book, chapter, content, plan);
      }
      if (!this.commentResultMatchesPlan(value, plan)) {
        console.warn('[InteractionPostProcessor] stale paragraph comments skipped:', source.bookSourceName,
          `chapter=${chapter.index}:${chapter.title}`, `bookId=${plan.bookId}`, `chapterId=${plan.chapterId}`);
        return content;
      }
      console.info('[InteractionPostProcessor] paragraph comments ready:', source.bookSourceName,
        `chapter=${chapter.index}:${chapter.title}`, `bookId=${plan.bookId}`, `chapterId=${plan.chapterId}`);
      return value;
    } catch (error) {
      console.warn('[InteractionPostProcessor] paragraph comments skipped:', source.bookSourceName, error);
      return content;
    }
  }

  private static async runPortableFanqieComments(source: BookSource, book: Book, chapter: BookChapter,
    content: string, plan: ParagraphCommentPlan): Promise<string> {
    const host = this.sourceSetting(source, 'server') || this.firstHttpHost(source.jsLib || '');
    if (!host) return content;
    const sessionId = this.sourceSetting(source, 'fqssionid') || this.sourceSetting(source, 'sessionid');
    const apiUrl = `${host.replace(/\/+$/, '')}/para_idea?item_id=${encodeURIComponent(plan.chapterId)}` +
      `&ssionid=${encodeURIComponent(sessionId)}`;
    const request = new StageWebRuntimeRequest();
    request.source = source;
    request.book = book;
    request.content = content;
    request.contextContent = content;
    request.baseUrl = chapter.url || book.bookUrl || source.bookSourceUrl;
    request.readerActionMode = true;
    request.networkTimeoutMs = 6000;
    request.code = `const __lines=String(result||'').split('\\n');` +
      `const __root=JSON.parse(java.ajax(${JSON.stringify(apiUrl)}));` +
      `const __raw=((__root.data||{}).data)||{};` +
      `Object.keys(__raw).forEach(function(__key){const __index=parseInt(__key);` +
      `if(__index<0||__index>=__lines.length)return;const __count=String((__raw[__key]||{}).count||'');` +
      `if(!__count||__count==='0')return;const __url=${JSON.stringify(host.replace(/\/+$/, ''))}+` +
      `'/get_para_review?item_id='+encodeURIComponent(${JSON.stringify(plan.chapterId)})+` +
      `'&book_id='+encodeURIComponent(${JSON.stringify(plan.bookId)})+'&para='+encodeURIComponent(__key)+` +
      `'&ssionid='+encodeURIComponent(${JSON.stringify(sessionId)});` +
      `__lines[__index]='<div rs-native>'+__lines[__index]+'<comment count="'+__count+` +
      `'" onPress="java.startBrowser(\\''+__url+'\\',\\'\u6bb5\u8bc4\\')"></div>';});` +
      `result=__lines.join('\\n');result;`;
    try {
      const runtimeResult = await BookSourceStageWebRuntime.get().execute(request);
      return runtimeResult.value || content;
    } catch (error) {
      console.warn('[InteractionPostProcessor] portable paragraph comments skipped:', source.bookSourceName, error);
      return content;
    }
  }

  private static usesPortableFanqieComments(source: BookSource): boolean {
    const script = source.jsLib || '';
    return script.includes('/para_idea') && script.includes('/get_para_review');
  }

  private static sourceSetting(source: BookSource, key: string): string {
    for (const raw of [source.variable || '', source.loginInfo || '']) {
      try {
        const value = JSON.parse(raw || '{}') as Object;
        const found = this.deepStringValue(value, key);
        if (found) return found;
      } catch (_) {}
    }
    return '';
  }

  private static deepStringValue(value: Object, key: string): string {
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
    for (const name of Object.keys(record)) {
      if (record[name] && typeof record[name] === 'object') {
        const found = this.deepStringValue(record[name], key);
        if (found) return found;
      }
    }
    return '';
  }

  private static firstHttpHost(script: string): string {
    const match = (script || '').match(/https?:\/\/[^'"`\s,)]+/i);
    if (!match || !match[0]) return '';
    const origin = match[0].match(/^(https?:\/\/[^/]+)/i);
    return origin && origin[1] ? origin[1] : '';
  }

  private static buildCommentPlan(source: BookSource, chapter: BookChapter,
    book: Book | null = null): ParagraphCommentPlan | null {
    const payload = EncodedSourceUrl.decode(chapter.url);
    const isShuqi = /\bSQ_COMMENT_API_BASE\b/.test(source.jsLib || '') &&
      /\b(?:sqDecorateContent|showSqComments)\b/.test(source.jsLib || '');
    if (!payload && !isShuqi) return null;
    const data: EncodedJsonMap = payload ? { ...payload.data, ...payload.options } : {};
    const sourceName = this.value(data, ['source', 'sources']);
    const normalizedSourceName = sourceName.replace(/^svip_/, '');
    const plan = new ParagraphCommentPlan();
    plan.sourceName = sourceName;
    if (normalizedSourceName === '番茄小说' || normalizedSourceName === '番茄') {
      plan.sourceType = 'fq';
      plan.bookId = this.value(data, ['book_id', 'bookId']);
      plan.chapterId = this.chapterValue(data, ['item_id', 'itemId'], ['cid']);
    } else if (normalizedSourceName === '七猫') {
      plan.sourceType = 'qm';
      plan.bookId = this.value(data, ['book_id', 'bookId']);
      plan.chapterId = this.value(data, ['item_id', 'itemId', 'cid']);
      plan.contentMd5 = this.value(data, ['content_md5', 'contentMd5']);
    } else if (normalizedSourceName === '塔读') {
      plan.sourceType = 'td';
      plan.bookId = this.value(data, ['book_id', 'bookId']);
      plan.chapterId = this.value(data, ['item_id', 'itemId', 'chapter_id', 'chapterId', 'cid']);
    } else if (normalizedSourceName === 'QQ阅读' || normalizedSourceName === 'QQ' ||
      normalizedSourceName === '企鹅看书') {
      plan.sourceType = 'qq';
      plan.bookId = this.value(data, ['bookid', 'book_id', 'bookId']);
      plan.chapterId = this.value(data, ['chapterid', 'chapter_id', 'chapterId', 'cid']);
    } else if (normalizedSourceName === '晋江' || normalizedSourceName === '半夏') {
      plan.sourceType = 'jj';
      plan.bookId = this.value(data, ['novelId', 'novel_id', 'book_id', 'bookId']);
      plan.chapterId = this.value(data, ['chapterId', 'chapter_id', 'cid']);
      plan.extra = {
        bookid: this.value(data, ['bookid']),
        chapterid: this.value(data, ['chapterid'])
      };
    } else if (EncodedSourceUrl.str(data['type']) === 'novel' &&
      /\bfunction\s+qdApi\s*\(|\bfunction\s+getComments\s*\(/.test(source.jsLib || '')) {
      plan.sourceType = 'qd';
      plan.bookId = this.value(data, ['novelId', 'novel_id', 'book_id', 'bookId']);
      plan.chapterId = (payload ? payload.text : '') ||
        this.value(data, ['chapId', 'chapterId', 'chapter_id', 'cid']);
    } else if (isShuqi) {
      const meta = this.shuqiChapterMeta(source, book, chapter);
      plan.sourceType = 'sq';
      plan.bookId = meta['bookId'] || '';
      plan.chapterId = meta['chapterId'] || '';
      const baseMatch = (source.jsLib || '').match(/\bSQ_COMMENT_API_BASE\s*=\s*['"](https?:\/\/[^'"]+)['"]/i);
      const keyMatch = (source.jsLib || '').match(/\bSQ_COMMENT_API_KEY\s*=\s*['"]([^'"]*)['"]/i);
      plan.extra = {
        apiBase: baseMatch && baseMatch[1] ? baseMatch[1].replace(/\/+$/, '') : '',
        apiKey: this.sourceSetting(source, '书旗评论 API Key') ||
          (keyMatch && keyMatch[1] ? keyMatch[1] : '')
      };
    } else {
      return null;
    }
    return plan.bookId && plan.chapterId ? plan : null;
  }

  private static shuqiChapterMeta(source: BookSource, book: Book | null,
    chapter: BookChapter): Record<string, string> {
    const result: Record<string, string> = {
      bookId: this.urlQueryValue(book?.tocUrl || book?.bookUrl || chapter.bookUrl || '', 'bookId') ||
        this.urlQueryValue(book?.tocUrl || book?.bookUrl || chapter.bookUrl || '', 'book_id'),
      chapterId: this.urlQueryValue(chapter.url || '', 'chapterId') ||
        this.urlQueryValue(chapter.url || '', 'chapter_id')
    };
    for (const raw of [chapter.variable || '', source.loginInfo || '', source.variable || '']) {
      let value: Object | null = null;
      try { value = JSON.parse(raw || '{}') as Object; } catch (_) {}
      if (!value) continue;
      const directBookId = this.deepNamedString(value, ['shuqiBookId', 'sqBookId']);
      const directChapterId = this.deepNamedString(value, ['shuqiChapterId', 'sqChapterId']);
      if (directBookId) result['bookId'] = directBookId;
      if (directChapterId) result['chapterId'] = directChapterId;
      const mapValue = this.deepNamedValue(value, 'sqMetaMap');
      const map = this.objectRecord(this.parseNestedObject(mapValue));
      for (const suffix of Object.keys(map)) {
        if (!suffix || !(chapter.url || '').includes(suffix)) continue;
        const record = this.objectRecord(this.parseNestedObject(map[suffix]));
        const bookId = String(record['bookId'] || record['book_id'] || '').trim();
        const chapterId = String(record['chapterId'] || record['chapter_id'] || '').trim();
        if (bookId) result['bookId'] = bookId;
        if (chapterId) result['chapterId'] = chapterId;
        break;
      }
    }
    return result;
  }

  private static deepNamedString(value: Object, keys: string[]): string {
    for (const key of keys) {
      const found = this.deepNamedValue(value, key);
      if (found !== null && found !== undefined && typeof found !== 'object') {
        const text = String(found).trim();
        if (text) return text;
      }
    }
    return '';
  }

  private static deepNamedValue(value: Object, key: string): Object | null {
    const parsed = this.parseNestedObject(value);
    if (!parsed || typeof parsed !== 'object') return null;
    if (Array.isArray(parsed)) {
      for (const item of parsed as Object[]) {
        const found = this.deepNamedValue(item, key);
        if (found !== null) return found;
      }
      return null;
    }
    const record = parsed as Record<string, Object>;
    if (record[key] !== undefined && record[key] !== null) return record[key];
    for (const name of Object.keys(record)) {
      const child = record[name];
      if (child && (typeof child === 'object' || typeof child === 'string')) {
        const found = this.deepNamedValue(child, key);
        if (found !== null) return found;
      }
    }
    return null;
  }

  private static parseNestedObject(value: Object | null | undefined): Object {
    if (typeof value !== 'string') return value || {};
    const text = (value as string).trim();
    if (!text || (!text.startsWith('{') && !text.startsWith('['))) return value;
    try { return JSON.parse(text) as Object; } catch (_) { return value; }
  }

  private static urlQueryValue(url: string, key: string): string {
    const match = (url || '').match(new RegExp(`(?:^|[?&])${key}=([^&#]+)`, 'i'));
    if (!match || !match[1]) return '';
    try { return decodeURIComponent(match[1]); } catch (_) { return match[1]; }
  }

  private static value(data: EncodedJsonMap, keys: string[]): string {
    for (const key of keys) {
      const value = EncodedSourceUrl.str(data[key]);
      if (value) return value;
    }
    const raw = EncodedSourceUrl.str(data['url']);
    for (const key of keys) {
      const match = raw.match(new RegExp(`(?:^|[?&#])${key}=([^&#]+)`, 'i'));
      if (!match || !match[1]) continue;
      try {
        return decodeURIComponent(match[1]);
      } catch (_) {
        return match[1];
      }
    }
    return '';
  }

  private static chapterValue(data: EncodedJsonMap, primaryKeys: string[], fallbackKeys: string[]): string {
    for (const key of primaryKeys) {
      const value = EncodedSourceUrl.str(data[key]);
      if (value) return value;
    }
    const raw = EncodedSourceUrl.str(data['url']);
    for (const key of primaryKeys) {
      const match = raw.match(new RegExp(`(?:^|[?&#])${key}=([^&#]+)`, 'i'));
      if (!match || !match[1]) continue;
      try {
        return decodeURIComponent(match[1]);
      } catch (_) {
        return match[1];
      }
    }
    return this.value(data, fallbackKeys);
  }

  private static commentResultMatchesPlan(content: string, plan: ParagraphCommentPlan): boolean {
    if (!/<comment\b/i.test(content || '')) return true;
    const decoded = this.decodeHtmlEntities(content || '');
    return decoded.includes(plan.bookId) && decoded.includes(plan.chapterId);
  }

  private static decodeHtmlEntities(value: string): string {
    return (value || '').replace(/&amp;/gi, '&').replace(/&#38;/g, '&');
  }

  static isParagraphCommentsEnabled(source: BookSource): boolean {
    const state = this.sourceSettingState(source, ['yunpara', 'paras', 'fqpara', '段评开关']);
    if (state !== 0) return state > 0;
    const script = source.contentRule?.content || '';
    return script.includes('/content?review=1') && script.includes('段评开关');
  }

  static isNamedSettingEnabled(source: BookSource, key: string, fallback: boolean = false): boolean {
    const state = this.sourceSettingState(source, [key]);
    return state === 0 ? fallback : state > 0;
  }

  private static hasQidianCommentsEnabled(source: BookSource): boolean {
    return this.isParagraphCommentsEnabled(source) ||
      this.isNamedSettingEnabled(source, '章名段评') ||
      this.isNamedSettingEnabled(source, '本章讨论') ||
      this.isNamedSettingEnabled(source, '作者评论') ||
      this.isNamedSettingEnabled(source, '热门评论');
  }

  private static async applyQidianComments(source: BookSource, content: string,
    plan: ParagraphCommentPlan): Promise<string> {
    const paragraphEnabled = this.isParagraphCommentsEnabled(source);
    const titleEnabled = this.isNamedSettingEnabled(source, '章名段评');
    const discussionEnabled = this.isNamedSettingEnabled(source, '本章讨论');
    const authorEnabled = this.isNamedSettingEnabled(source, '作者评论');
    const hotEnabled = this.isNamedSettingEnabled(source, '热门评论');
    let result = content;
    try {
      if (paragraphEnabled || titleEnabled || hotEnabled) {
        const summaryRoot = await this.requestQidianApi('paragraph_summary', plan);
        const summaryData = this.objectRecord(summaryRoot['data']);
        const summary = this.objectList(summaryData['summary'] || summaryData['Summary']);
        const reviews = this.objectList(summaryData['reviews'] || summaryData['Reviews']);
        result = this.attachQidianParagraphMarkers(result, plan, summary, reviews,
          paragraphEnabled, titleEnabled, hotEnabled);
      }
      if (discussionEnabled) {
        const chapterRoot = await this.requestQidianApi('chapter_comments', plan, { page: '1', page_size: '20' });
        const chapterData = this.objectRecord(chapterRoot['data']);
        const total = Number(chapterData['total'] || chapterData['Total'] ||
          this.objectList(chapterData['comments'] || chapterData['Comments']).length || 0);
        if (total > 0) {
          result += `\n${this.qidianCommentMarkup('本章讨论', this.qidianCommentUrl('chapter_comments', plan, '-1'),
            String(total))}`;
        }
      }
      if (authorEnabled) {
        const activityRoot = await this.requestQidianApi('chapter_activity', plan);
        const authorText = this.qidianAuthorText(activityRoot['data']);
        if (authorText) result += `\n作者说：${authorText}`;
      }
      return result;
    } catch (error) {
      console.warn('[InteractionPostProcessor] qidian comments skipped:', source.bookSourceName, error);
      return content;
    }
  }

  private static async applyShuqiComments(source: BookSource, content: string,
    plan: ParagraphCommentPlan): Promise<string> {
    if (!content || content.includes('legado_reader_shuqi=1') ||
      content.includes('legado_reader_shuqi%3D1') || /\bshowSqComments\s*\(/.test(content)) {
      return content;
    }
    const apiBase = plan.extra['apiBase'] || '';
    const apiKey = plan.extra['apiKey'] || '';
    if (!apiBase || !apiKey) return content;
    try {
      const response = await new HttpClient(8000).execute({
        url: `${apiBase}/v1/reader/render-ext`,
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
        body: JSON.stringify({ bookId: plan.bookId, chapterId: plan.chapterId, apiKey: apiKey }),
        maxResponseBytes: 2 * 1024 * 1024
      });
      if (!response.body) throw new Error(response.error || `书旗评论接口请求失败：${response.statusCode}`);
      const root = this.objectRecord(JSON.parse(response.body.replace(/^\uFEFF/, '')) as Object);
      if (root['ok'] !== true && String(root['ok'] || '') !== 'true') {
        throw new Error(String(root['error'] || '书旗评论接口返回异常'));
      }
      const outer = this.objectRecord(root['data']);
      const data = this.objectRecord(outer['data'] || outer['Data']);
      const ext = this.objectRecord(data['bookChapterExtInfo'] || data['BookChapterExtInfo']);
      const paragraphs = this.objectList(ext['paragraphList'] || ext['ParagraphList']);
      if (paragraphs.length === 0) return content;
      return this.attachShuqiCommentMarkers(source, content, plan, paragraphs);
    } catch (error) {
      console.warn('[InteractionPostProcessor] shuqi comments skipped:', source.bookSourceName,
        `bookId=${plan.bookId}`, `chapterId=${plan.chapterId}`, error);
      return content;
    }
  }

  private static attachShuqiCommentMarkers(source: BookSource, content: string,
    plan: ParagraphCommentPlan, paragraphs: Object[]): string {
    const paragraphEnabled = this.isParagraphCommentsEnabled(source);
    const chapterEnabled = this.isNamedSettingEnabled(source, '章评开关');
    const lines = (content || '').replace(/<br\s*\/?>/gi, '\n').replace(/\r\n?/g, '\n').split('\n');
    const textIndexes: number[] = [];
    let chapterMarker = '';
    let attached = 0;
    for (let index = 0; index < lines.length; index++) {
      const plain = lines[index].replace(/<[^>]+>/g, '').trim();
      if (plain && !/^\[\[LEGADO_READER_(?:IMAGE|ACTION)/.test(plain)) textIndexes.push(index);
    }
    for (const value of paragraphs) {
      const record = this.objectRecord(value);
      const order = Number(record['orderId'] ?? record['OrderId'] ?? -1);
      const count = Number(record['commentCount'] || record['CommentCount'] || 0);
      if (count <= 0 || order < 0) continue;
      const paragraphId = String(record['paragraphId'] || record['ParagraphId'] || `p${order}`);
      if (order === 0) {
        if (!chapterEnabled || textIndexes.length === 0) continue;
        const marker = ReaderActionMarker.createShuqiComment(`章评 ${count}`, plan.bookId,
          plan.chapterId, paragraphId, 'chapterTitle');
        if (marker) {
          // The fetched body does not contain the reader-generated chapter title. Keep the title action as a
          // standalone leading marker; the common reader layer relocates it after the real title. Appending it
          // to the first body line would put two actions in one paragraph and expose a raw marker in ArkUI.
          chapterMarker = marker;
          attached++;
        }
        continue;
      }
      if (!paragraphEnabled) continue;
      const lineIndex = textIndexes[order - 1];
      if (lineIndex === undefined || lineIndex < 0 || lineIndex >= lines.length) continue;
      const marker = ReaderActionMarker.createShuqiComment(`段评 ${count}`, plan.bookId,
        plan.chapterId, paragraphId, 'paragraph');
      if (marker) {
        lines[lineIndex] = `${lines[lineIndex]}${marker}`;
        attached++;
      }
    }
    console.info('[InteractionPostProcessor] shuqi comments ready:', source.bookSourceName,
      `bookId=${plan.bookId}`, `chapterId=${plan.chapterId}`, `markers=${attached}`);
    const body = lines.join('\n');
    return chapterMarker ? `${chapterMarker}\n${body}` : body;
  }

  private static attachQidianParagraphMarkers(content: string, plan: ParagraphCommentPlan, summary: Object[],
    reviews: Object[], paragraphEnabled: boolean, titleEnabled: boolean, hotEnabled: boolean): string {
    const lines = (content || '').replace(/\r\n?/g, '\n').split('\n');
    const textIndexes: number[] = [];
    for (let index = 0; index < lines.length; index++) {
      const line = lines[index].trim();
      if (line && !/^<\s*img\b/i.test(line) && !line.includes('data:image/')) textIndexes.push(index);
    }
    let titleCount = 0;
    const paragraphLines = new Map<number, number>();
    for (const value of summary) {
      const record = this.objectRecord(value);
      const paragraphId = Number(record['ParagraphId'] || record['paragraphId'] || record['paragraph_id'] ||
        record['ParaId'] || record['paraId'] || 0);
      const count = Number(record['CommentCount'] || record['commentCount'] || record['TextCount'] ||
        record['textCount'] || record['Count'] || record['count'] || 0);
      if (paragraphId === -1) {
        titleCount = Math.max(titleCount, count);
        continue;
      }
      if (!paragraphEnabled || paragraphId <= 0 || count <= 0) continue;
      const lineIndex = textIndexes[paragraphId - 1];
      if (lineIndex === undefined || lineIndex < 0 || lineIndex >= lines.length) continue;
      paragraphLines.set(paragraphId, lineIndex);
      lines[lineIndex] = this.qidianCommentMarkup(lines[lineIndex],
        this.qidianCommentUrl('paragraph_comments', plan, String(paragraphId)), String(count));
    }
    if (hotEnabled) {
      const additions = new Map<number, string[]>();
      for (const value of reviews) {
        const record = this.objectRecord(value);
        const paragraphId = Number(record['paragraph_id'] || record['ParagraphId'] || record['paragraphId'] || 0);
        const lineIndex = paragraphLines.get(paragraphId) ?? textIndexes[paragraphId - 1];
        if (lineIndex === undefined || lineIndex < 0 || lineIndex >= lines.length) continue;
        const items = additions.get(lineIndex) || [];
        items.push(this.qidianCommentMarkup('热门评论',
          this.qidianCommentUrl('paragraph_comments', plan, String(paragraphId)), '热评'));
        additions.set(lineIndex, items);
      }
      const ordered = Array.from(additions.keys()).sort((a: number, b: number): number => b - a);
      for (const lineIndex of ordered) lines.splice(lineIndex + 1, 0, ...(additions.get(lineIndex) || []));
    }
    if (titleEnabled && titleCount > 0) {
      lines.unshift(this.qidianCommentMarkup('章名段评',
        this.qidianCommentUrl('paragraph_comments', plan, '-1'), String(titleCount)));
    }
    return lines.join('\n');
  }

  private static qidianCommentMarkup(text: string, url: string, count: string): string {
    const safeText = (text || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    const safeUrl = this.encodeHtmlAttribute(url);
    const safeCount = this.encodeHtmlAttribute(count || '');
    return `<div rs-native>${safeText}<comment ident="${safeUrl}" count="${safeCount}" /></div>`;
  }

  private static qidianCommentUrl(action: string, plan: ParagraphCommentPlan, paragraphId: string): string {
    return `https://pl.001122.top/api/qidian_full_api.php?action=${encodeURIComponent(action)}` +
      `&book_id=${encodeURIComponent(plan.bookId)}&chapter_id=${encodeURIComponent(plan.chapterId)}` +
      `${action.startsWith('paragraph_') ? `&paragraph_id=${encodeURIComponent(paragraphId)}` : ''}` +
      '&page=1&page_size=20&legado_reader_comment=1';
  }

  private static async requestQidianApi(action: string, plan: ParagraphCommentPlan,
    extra: Record<string, string> = {}): Promise<Record<string, Object>> {
    let url = this.qidianCommentUrl(action, plan, '');
    for (const key in extra) {
      url += `&${encodeURIComponent(key)}=${encodeURIComponent(extra[key])}`;
    }
    const response = await new HttpClient(8000).execute({
      url: url,
      method: 'GET',
      headers: {},
      maxResponseBytes: 2 * 1024 * 1024
    });
    if (!response.body) throw new Error(response.error || `起点评论接口请求失败：${response.statusCode}`);
    const parsed = JSON.parse(response.body.replace(/^\uFEFF/, '')) as Object;
    const root = this.objectRecord(parsed);
    if (Number(root['code'] || 0) !== 0) throw new Error(String(root['message'] || '起点评论接口返回异常'));
    return root;
  }

  private static objectRecord(value: Object | null | undefined): Record<string, Object> {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
    return value as Record<string, Object>;
  }

  private static objectList(value: Object | null | undefined): Object[] {
    return Array.isArray(value) ? value as Object[] : [];
  }

  private static qidianAuthorText(value: Object | null | undefined): string {
    const record = this.objectRecord(value);
    const candidates: Object[] = [record['author_say'], record['authorSay'], record['AuthorSay'],
      record['author_comment'], record['authorComment'], record['AuthorComment'], record['ChapterAuthorSay'],
      record['chapterAuthorSay'], record['authorWords'], record['writerSay']];
    for (const candidate of candidates) {
      if (typeof candidate === 'string' && candidate.trim()) return candidate.trim();
      const nested = this.objectRecord(candidate);
      const text = String(nested['Text'] || nested['text'] || nested['Content'] || nested['content'] || '').trim();
      if (text) return text;
    }
    return '';
  }

  static isGodCommentsEnabled(source: BookSource): boolean {
    const state = this.sourceSettingState(source, ['神评论开关', 'godComment', 'godComments']);
    if (state !== 0) return state > 0;
    const script = source.contentRule?.content || '';
    return script.includes('神评论开关') && /\bgod\b/.test(script);
  }

  static isChapterCommentsEnabled(source: BookSource): boolean {
    const state = this.sourceSettingState(source, ['本章说开关', 'chapterComment', 'chapterReview']);
    if (state !== 0) return state > 0;
    const script = source.contentRule?.content || '';
    return script.includes('本章说开关') && (script.includes('/get_review') || script.includes('chapter_review_svg'));
  }

  private static sourceSettingState(source: BookSource, keys: string[]): number {
    for (const key of keys) {
      const runtimeValue = this.runtimeJavaValue(source, key);
      if (this.isEnabledSettingValue(runtimeValue)) return 1;
      if (this.isDisabledSettingValue(runtimeValue)) return -1;
    }
    for (const raw of [source.variable || '', source.loginInfo || '']) {
      try {
        const state = this.deepSettingState(JSON.parse(raw || '{}') as Object, keys);
        if (state !== 0) return state;
      } catch (_) {}
    }
    return 0;
  }

  private static runtimeJavaValue(source: BookSource, key: string): string {
    try {
      const loginInfo = JSON.parse(source.loginInfo || '{}') as Record<string, Object>;
      let runtime = loginInfo['__legadoHarmonyRuntime'];
      if (typeof runtime === 'string') runtime = JSON.parse(runtime) as Object;
      if (!runtime || typeof runtime !== 'object' || Array.isArray(runtime)) return '';
      const javaState = (runtime as Record<string, Object>)['java'];
      if (!javaState || typeof javaState !== 'object' || Array.isArray(javaState)) return '';
      return String((javaState as Record<string, Object>)[key] || '').toLowerCase();
    } catch (_) {
      return '';
    }
  }

  private static deepSettingState(value: Object, keys: string[]): number {
    if (!value || typeof value !== 'object') return 0;
    if (Array.isArray(value)) {
      for (const item of value) {
        const state = this.deepSettingState(item as Object, keys);
        if (state !== 0) return state;
      }
      return 0;
    }
    const record = value as Record<string, Object>;
    for (const key of Object.keys(record)) {
      if (keys.includes(key)) {
        if (this.isEnabledSettingValue(record[key])) return 1;
        if (this.isDisabledSettingValue(record[key])) return -1;
      }
      if (record[key] && typeof record[key] === 'object') {
        const state = this.deepSettingState(record[key], keys);
        if (state !== 0) return state;
      }
    }
    return 0;
  }

  private static isEnabledSettingValue(value: Object | string | undefined | null): boolean {
    const normalized = String(value ?? '').trim().toLowerCase();
    return normalized === 'on' || normalized === 'true' || normalized === '1' || normalized === 'yes' ||
      normalized === 'enabled' || normalized === '✅';
  }

  private static isDisabledSettingValue(value: Object | string | undefined | null): boolean {
    const normalized = String(value ?? '').trim().toLowerCase();
    return normalized === 'off' || normalized === 'false' || normalized === '0' || normalized === 'no' ||
      normalized === 'disabled' || normalized === '❌';
  }

  private static appendMediaAction(chapter: BookChapter, content: string): string {
    const mediaType = BookUrlResolver.getVariableJson(chapter.variable, 'shortcutMediaType');
    const videoUrl = BookUrlResolver.getVariableJson(chapter.variable, 'shortcutVideoUrl');
    if (!videoUrl || !/^https?:\/\//i.test(videoUrl)) return content;
    const label = mediaType === 'video' ? '播放视频' : '打开媒体';
    const marker = ReaderActionMarker.create(label, videoUrl, label);
    return marker ? `${content}\n\n${marker}` : content;
  }
}
