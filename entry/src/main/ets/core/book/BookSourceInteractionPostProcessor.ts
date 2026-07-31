import { Book, BookChapter, BookSource } from '../../model/data/Book';
import { BookUrlResolver } from './BookUrlResolver';
import { EncodedJsonMap, EncodedSourceUrl } from './EncodedSourceUrl';
import { BookSourceStageWebRuntime, StageWebRuntimeRequest } from './BookSourceStageWebRuntime';
import { ReaderActionMarker } from './ReaderActionMarker';
import { CookieStore } from '../http/CookieStore';

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
    const commentPlan = this.buildCommentPlan(chapter);
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
    const plan = this.buildCommentPlan(chapter);
    if (!plan) return false;
    return ['fq', 'qm', 'td', 'qq'].includes(plan.sourceType);
  }

  static shouldRequestGodComments(source: BookSource, chapter: BookChapter): boolean {
    const plan = this.buildCommentPlan(chapter);
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

  private static buildCommentPlan(chapter: BookChapter): ParagraphCommentPlan | null {
    const payload = EncodedSourceUrl.decode(chapter.url);
    if (!payload) return null;
    const data = payload.data;
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
    } else {
      return null;
    }
    return plan.bookId && plan.chapterId ? plan : null;
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
