import { Book, BookChapter, BookSource } from '../../model/data/Book';
import { HttpClient } from '../http/HttpClient';
import { AnalyzeUrl } from '../rule/AnalyzeUrl';
import { JsRuntime } from '../rule/JsRuntime';
import { CookieStore } from '../http/CookieStore';
import { appDb } from '../../model/data/AppDatabase';
import { BookUrlResolver } from './BookUrlResolver';

export class ShuqiExploreMenuItem {
  title: string = '';
  url: string = '';
}

export class BookSourceShuqiSupport {
  private static readonly HOST = 'https://ocean.shuqireader.com';
  private static readonly EXPLORE_PREFIX = 'legado-shuqi://category?';
  private static readonly INFO_KEY = '37e81a9d8f02596e1b895d07c171d5c9';
  private static readonly GATEWAY_KEY = 'eefc4798f28ea41622487ad80ef7e81c';

  static canHandle(source: BookSource): boolean {
    const code = `${source.bookSourceUrl || ''}\n${source.jsLib || ''}\n${source.exploreUrl || ''}`;
    return /ocean\.shuqireader\.com/i.test(code) &&
      /\/webapi\/bcspub\/openapi\/book\/info|sq_h5_gateway/i.test(code);
  }

  static async ensureAuthorization(client: HttpClient, source: BookSource): Promise<boolean> {
    if (!BookSourceShuqiSupport.canHandle(source)) return false;
    const headerToken = BookSourceShuqiSupport.loginHeaderToken(source.loginHeader || '');
    let token = BookSourceShuqiSupport.cookieToken();
    if (!token) {
      // t.shuqi.com issues the short-lived gateway token as an ordinary first-party cookie.
      // Loading it natively is equivalent to the source's java.get(origin).cookies() call and
      // avoids sending the user to a non-existent ocean.shuqireader.com/login.html page.
      await new AnalyzeUrl(null, client).fetch('https://t.shuqi.com/', 2 * 1024 * 1024);
      token = BookSourceShuqiSupport.cookieToken();
    }
    if (!token) return !!headerToken;
    if (token === headerToken) return true;
    source.loginHeader = JSON.stringify({ authorization: `Bearer ${token}` });
    try {
      await appDb.updateBookSourceLoginRuntime(source.bookSourceUrl,
        source.variable || '', source.loginHeader, source.loginInfo || '');
    } catch (_) {
      // The current request can still use the in-memory header; persistence is best effort.
    }
    return true;
  }

  static buildSearchUrl(source: BookSource, keyword: string, page: number = 1): string {
    if (!BookSourceShuqiSupport.canHandle(source)) return '';
    const template = source.searchUrl || '';
    if (!/^https?:\/\//i.test(template)) return '';
    return template
      .replace(/\{\{\s*key\s*\}\}/g, encodeURIComponent(keyword || ''))
      .replace(/\{\{\s*(?:page|pageIndex)\s*\}\}/g, String(Math.max(1, page)))
      .replace(/\{\{\s*~~\s*\(\s*Date\.now\(\)\s*\/\s*1e3\s*\)\s*\}\}/g,
        String(Math.floor(Date.now() / 1000)));
  }

  static buildBookInfoUrl(source: BookSource, record: Record<string, Object>): string {
    if (!BookSourceShuqiSupport.canHandle(source)) return '';
    const bookId = String(record['bookId'] || record['bid'] || record['book_id'] || '').trim();
    if (!bookId) return '';
    return BookSourceShuqiSupport.buildSignedUrl(source,
      '/webapi/bcspub/openapi/book/info', `bookId=${encodeURIComponent(bookId)}`);
  }

  static buildTocUrl(source: BookSource, content: string): string {
    if (!BookSourceShuqiSupport.canHandle(source)) return '';
    try {
      const parsed = JSON.parse(content || '{}') as Object;
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return '';
      const root = parsed as Record<string, Object>;
      const rawData = root['data'];
      const data = rawData && typeof rawData === 'object' && !Array.isArray(rawData) ?
        rawData as Record<string, Object> : root;
      const bookId = String(data['bookId'] || data['bid'] || data['book_id'] || '').trim();
      if (!bookId) return '';
      return BookSourceShuqiSupport.buildSignedUrl(source,
        '/webapi/bcspub/openapi/book/chapterlist', `bookId=${encodeURIComponent(bookId)}`);
    } catch (_) {
      return '';
    }
  }

  static buildExploreUrl(source: BookSource, encodedUrl: string, page: number): string {
    if (!BookSourceShuqiSupport.canHandle(source) ||
      !(encodedUrl || '').startsWith(BookSourceShuqiSupport.EXPLORE_PREFIX)) return '';
    const key = BookSourceShuqiSupport.queryValue(encodedUrl, 'key');
    const id = BookSourceShuqiSupport.queryValue(encodedUrl, 'id');
    if (!key || !id) return '';
    const params = `curPage=${Math.max(1, page)}&pageSize=10&${key}=${encodeURIComponent(id)}`;
    return BookSourceShuqiSupport.buildSignedUrl(source,
      '/api/bcsbizai/xapi/categoryAndTag/books/h5', params);
  }

  static async getExploreMenuItems(client: HttpClient, source: BookSource): Promise<ShuqiExploreMenuItem[]> {
    if (!BookSourceShuqiSupport.canHandle(source)) return [];
    const groupKey = BookSourceShuqiSupport.groupKey(source);
    const requestUrl = BookSourceShuqiSupport.buildSignedUrl(source,
      '/api/bcsbizai/category/column/allitems',
      `groupKey=${encodeURIComponent(groupKey)}&source=1`);
    const response = await new AnalyzeUrl(source, client).fetch(requestUrl, 8 * 1024 * 1024);
    if (!response.success || !response.body) return [];
    let values: Object[] = [];
    try {
      const root = JSON.parse(response.body) as Record<string, Object>;
      const rawData = root['data'];
      if (!rawData || typeof rawData !== 'object' || Array.isArray(rawData)) return [];
      const rawItems = (rawData as Record<string, Object>)['items'];
      if (!Array.isArray(rawItems)) return [];
      values = rawItems as Object[];
    } catch (_) {
      return [];
    }
    const result: ShuqiExploreMenuItem[] = [];
    for (const value of values) {
      if (!value || typeof value !== 'object' || Array.isArray(value)) continue;
      const item = value as Record<string, Object>;
      const itemId = String(item['itemId'] || '').trim();
      const itemName = String(item['itemName'] || '').trim();
      const itemKey = String(item['itemKey'] || '').trim();
      const itemSubType = String(item['itemSubType'] || '').trim();
      if (!itemId || !itemName) continue;
      const queryKey = itemKey === 'TAG' ? 'tagIds' :
        (itemSubType.includes('SECOND') ? 'secondCategoryId' : 'firstCategoryId');
      const groupName = BookSourceShuqiSupport.categoryName(itemKey, itemSubType);
      const menu = new ShuqiExploreMenuItem();
      menu.title = groupName ? `${groupName} · ${itemName}` : itemName;
      menu.url = `${BookSourceShuqiSupport.EXPLORE_PREFIX}key=${encodeURIComponent(queryKey)}` +
        `&id=${encodeURIComponent(itemId)}`;
      result.push(menu);
    }
    return result;
  }

  static parseBookRecords(source: BookSource, body: string, includeAladdin: boolean = false): Record<string, Object>[] {
    if (!BookSourceShuqiSupport.canHandle(source)) return [];
    try {
      const parsed = JSON.parse(body || '{}') as Object;
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return [];
      const root = parsed as Record<string, Object>;
      const values: Object[] = [];
      if (includeAladdin && root['aladdin'] && typeof root['aladdin'] === 'object' &&
        !Array.isArray(root['aladdin'])) values.push(root['aladdin']);
      const rawData = root['data'];
      if (Array.isArray(rawData)) {
        values.push(...rawData as Object[]);
      } else if (rawData && typeof rawData === 'object') {
        const books = (rawData as Record<string, Object>)['books'];
        if (Array.isArray(books)) values.push(...books as Object[]);
      }
      const result: Record<string, Object>[] = [];
      const seen = new Set<string>();
      for (const value of values) {
        if (!value || typeof value !== 'object' || Array.isArray(value)) continue;
        const record = value as Record<string, Object>;
        const id = String(record['bookId'] || record['bid'] || record['book_id'] || '').trim();
        if (!id || seen.has(id)) continue;
        seen.add(id);
        result.push(record);
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  static attachChapterMetadata(source: BookSource, book: Book, chapters: BookChapter[], tocBody: string): void {
    if (!BookSourceShuqiSupport.canHandle(source) || chapters.length === 0 || !tocBody) return;
    let root: Record<string, Object> = {};
    try { root = JSON.parse(tocBody) as Record<string, Object>; } catch (_) { return; }
    const data = root['data'] && typeof root['data'] === 'object' && !Array.isArray(root['data']) ?
      root['data'] as Record<string, Object> : root;
    const bookId = String(data['bookId'] || data['book_id'] ||
      BookSourceShuqiSupport.queryValue(book.tocUrl || book.bookUrl || '', 'bookId') || '').trim();
    const rawVolumes = data['chapterList'];
    if (!Array.isArray(rawVolumes)) return;
    const metadata: Record<string, string>[] = [];
    for (const rawVolume of rawVolumes as Object[]) {
      if (!rawVolume || typeof rawVolume !== 'object' || Array.isArray(rawVolume)) continue;
      const rawItems = (rawVolume as Record<string, Object>)['volumeList'];
      if (!Array.isArray(rawItems)) continue;
      for (const rawItem of rawItems as Object[]) {
        if (!rawItem || typeof rawItem !== 'object' || Array.isArray(rawItem)) continue;
        const item = rawItem as Record<string, Object>;
        metadata.push({
          bookId: bookId,
          chapterId: String(item['chapterId'] || item['chapter_id'] || '').trim(),
          suffix: String(item['contUrlSuffix'] || '').trim()
        });
      }
    }
    for (let index = 0; index < chapters.length; index++) {
      const chapter = chapters[index];
      let meta = index < metadata.length ? metadata[index] : null;
      for (const candidate of metadata) {
        if (candidate['suffix'] && (chapter.url || '').includes(candidate['suffix'])) {
          meta = candidate;
          break;
        }
      }
      if (!meta) continue;
      if (meta['bookId']) {
        chapter.variable = BookUrlResolver.setVariableJson(chapter.variable, 'shuqiBookId', meta['bookId']);
      }
      if (meta['chapterId']) {
        chapter.variable = BookUrlResolver.setVariableJson(chapter.variable, 'shuqiChapterId', meta['chapterId']);
      }
    }
  }

  static needsChapterMetadataRefresh(source: BookSource, chapters: BookChapter[]): boolean {
    if (!BookSourceShuqiSupport.canHandle(source) || chapters.length === 0) return false;
    for (const chapter of chapters) {
      const bookId = BookUrlResolver.getVariableJson(chapter.variable, 'shuqiBookId');
      const chapterId = BookUrlResolver.getVariableJson(chapter.variable, 'shuqiChapterId');
      if (!bookId || !chapterId) return true;
    }
    return false;
  }

  private static buildSignedUrl(source: BookSource, path: string, extraParams: string): string {
    const timestamp = String(Math.floor(Date.now() / 1000));
    const userId = BookSourceShuqiSupport.userId(source);
    let body = '';
    if (/info/i.test(path)) {
      const params = `user_id=${encodeURIComponent(userId)}&timestamp=${timestamp}&${extraParams}`;
      // The source's sortedStr() deliberately switches formats: info requests do not yet contain
      // platform=0, so only sorted values participate in the signature. Gateway requests already
      // contain platform=0 and therefore sign the full key=value string.
      const sign = new JsRuntime().md5Encode(BookSourceShuqiSupport.sortedValues(params) +
        BookSourceShuqiSupport.INFO_KEY);
      body = `${params}&platform=0&needFreeStack=1&sign=${sign}`;
    } else {
      const params = `sqSv=1.0&user_id=${encodeURIComponent(userId)}&timestamp=${timestamp}` +
        `&platform=0&${extraParams}`;
      const sign = new JsRuntime().md5Encode(BookSourceShuqiSupport.sortedParams(params) +
        `&skey=${BookSourceShuqiSupport.GATEWAY_KEY}`);
      body = `${params}&key=sq_h5_gateway&sign=${sign}`;
    }
    return `${BookSourceShuqiSupport.HOST}${path},${JSON.stringify({ body: body, method: 'POST' })}`;
  }

  private static sortedParams(params: string): string {
    return params.split('&').filter((value: string): boolean => !!value)
      .sort((left: string, right: string): number => {
        const leftKey = left.split('=', 1)[0];
        const rightKey = right.split('=', 1)[0];
        return leftKey < rightKey ? -1 : (leftKey > rightKey ? 1 : 0);
      }).join('&');
  }

  private static sortedValues(params: string): string {
    return params.split('&').filter((value: string): boolean => !!value)
      .sort((left: string, right: string): number => {
        const leftKey = left.split('=', 1)[0];
        const rightKey = right.split('=', 1)[0];
        return leftKey < rightKey ? -1 : (leftKey > rightKey ? 1 : 0);
      }).map((value: string): string => {
        const index = value.indexOf('=');
        return index >= 0 ? value.substring(index + 1) : '';
      }).join('');
  }

  private static userId(source: BookSource): string {
    try {
      const parsed = JSON.parse(source.variable || '[]') as Object;
      if (!Array.isArray(parsed) || parsed.length === 0) return '12345678';
      const first = parsed[0] as Record<string, Object>;
      const rawUid = first['uid'];
      if (!Array.isArray(rawUid) || rawUid.length === 0) return '12345678';
      const uid = rawUid[0] as Record<string, Object>;
      const value = String(uid['userId'] || '').trim();
      return /^\d+$/.test(value) ? value : '12345678';
    } catch (_) {
      return '12345678';
    }
  }

  private static groupKey(source: BookSource): string {
    try {
      const parsed = JSON.parse(source.variable || '[]') as Object;
      if (!Array.isArray(parsed) || parsed.length === 0) return 'male';
      const first = parsed[0] as Record<string, Object>;
      const rawFl = first['fl'];
      if (!Array.isArray(rawFl) || rawFl.length === 0) return 'male';
      const setting = rawFl[0] as Record<string, Object>;
      const keys = Object.keys(setting);
      if (keys.length === 0) return 'male';
      const value = String(setting[keys[0]] || '').trim();
      return value || 'male';
    } catch (_) {
      return 'male';
    }
  }

  private static categoryName(itemKey: string, itemSubType: string): string {
    if (itemSubType.includes(itemKey)) return itemKey === 'CATEGORY' ? '分类' : itemKey;
    if (itemSubType === 'MAIN_LINE') return '题材';
    if (itemSubType === 'PLOT') return '情节';
    if (itemSubType === 'ROLE') return '角色';
    if (itemSubType === 'STYLE') return '风格';
    return itemSubType;
  }

  private static queryValue(url: string, key: string): string {
    const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const match = (url || '').match(new RegExp(`[?&]${escaped}=([^&#]*)`, 'i'));
    if (!match || !match[1]) return '';
    try { return decodeURIComponent(match[1]); } catch (_) { return match[1]; }
  }

  private static cookieToken(): string {
    const targets = ['https://t.shuqi.com/', 'https://t.shuqi.com', 'https://www.shuqi.com/'];
    for (const target of targets) {
      const token = CookieStore.getCookieValue(target, 'shuqi_token');
      if (token) return token;
    }
    return '';
  }

  private static loginHeaderToken(loginHeader: string): string {
    const raw = (loginHeader || '').trim();
    if (!raw) return '';
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const value = String(parsed['authorization'] || parsed['Authorization'] || '').trim();
      return value.replace(/^Bearer\s+/i, '').trim();
    } catch (_) {
      const match = raw.match(/Bearer\s+([^\s"',}]+)/i);
      return match && match[1] ? match[1] : '';
    }
  }
}
