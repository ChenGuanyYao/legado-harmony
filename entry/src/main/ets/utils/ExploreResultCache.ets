import { Context } from '@kit.AbilityKit';
import preferences from '@ohos.data.preferences';
import { SearchBook } from '@legado/sourceengine';

class ExploreCacheEntry {
  key: string = '';
  updatedAt: number = 0;
  pageCount: number = 1;
  hasMore: boolean = true;
  books: SearchBook[] = [];
}

class ExploreCachePayload {
  version: number = 4;
  entries: ExploreCacheEntry[] = [];
}

export class ExploreCacheHit {
  updatedAt: number = 0;
  pageCount: number = 1;
  hasMore: boolean = true;
  books: SearchBook[] = [];
}

export class ExploreResultCache {
  // v4 invalidates entries created before discovery metadata was recovered from
  // the raw API item. Older entries can have an empty intro even though the
  // current source response contains one.
  private static readonly SCHEMA_VERSION: number = 4;
  private static readonly STORE_NAME: string = 'explore_result_cache';
  private static readonly CACHE_KEY: string = 'entries';
  private static readonly TTL_MS: number = 24 * 60 * 60 * 1000;
  private static readonly MAX_ENTRIES: number = 80;
  private static readonly MAX_RESULTS_PER_ENTRY: number = 200;
  static readonly INVALIDATION_REVISION_KEY: string = 'exploreSourceCacheRevision';

  static isFresh(updatedAt: number): boolean {
    return updatedAt > 0 && Date.now() - updatedAt < ExploreResultCache.TTL_MS;
  }

  static async load(context: Context, sourceUrl: string, platform: string, entryTitle: string,
    entryUrl: string): Promise<ExploreCacheHit | null> {
    const key = ExploreResultCache.buildKey(sourceUrl, platform, entryTitle, entryUrl);
    if (!key) return null;
    const payload = await ExploreResultCache.loadPayload(context);
    const now = Date.now();
    const entry = payload.entries.find((item: ExploreCacheEntry) => item.key === key);
    if (!entry || !Array.isArray(entry.books) || entry.books.length === 0) return null;
    if (!ExploreResultCache.isFresh(entry.updatedAt)) {
      payload.entries = payload.entries.filter((item: ExploreCacheEntry) =>
        item.key !== key && now - item.updatedAt < ExploreResultCache.TTL_MS);
      await ExploreResultCache.savePayload(context, payload);
      return null;
    }
    const hit = new ExploreCacheHit();
    hit.updatedAt = entry.updatedAt;
    hit.pageCount = Math.max(1, Number(entry.pageCount) || 1);
    hit.hasMore = entry.hasMore !== false;
    hit.books = entry.books.map((book: SearchBook) => ExploreResultCache.cloneSearchBook(book));
    return hit;
  }

  static async save(context: Context, sourceUrl: string, platform: string, entryTitle: string,
    entryUrl: string, books: SearchBook[], pageCount: number = 1, hasMore: boolean = true): Promise<void> {
    const key = ExploreResultCache.buildKey(sourceUrl, platform, entryTitle, entryUrl);
    if (!key || books.length === 0) return;
    const payload = await ExploreResultCache.loadPayload(context);
    const now = Date.now();
    const entry = new ExploreCacheEntry();
    entry.key = key;
    entry.updatedAt = now;
    entry.pageCount = Math.max(1, pageCount);
    entry.hasMore = hasMore;
    entry.books = books.slice(0, ExploreResultCache.MAX_RESULTS_PER_ENTRY)
      .map((book: SearchBook) => ExploreResultCache.cloneSearchBook(book));
    payload.entries = [entry].concat(payload.entries.filter((item: ExploreCacheEntry) =>
      item.key !== key && now - item.updatedAt < ExploreResultCache.TTL_MS))
      .slice(0, ExploreResultCache.MAX_ENTRIES);
    await ExploreResultCache.savePayload(context, payload);
  }

  static async clearSource(context: Context, sourceUrl: string): Promise<void> {
    const normalizedSource = (sourceUrl || '').trim();
    if (!normalizedSource) return;
    const payload = await ExploreResultCache.loadPayload(context);
    const prefix = `${normalizedSource}\n`;
    const remaining = payload.entries.filter((item: ExploreCacheEntry): boolean =>
      !item.key.startsWith(prefix));
    if (remaining.length === payload.entries.length) return;
    payload.entries = remaining;
    await ExploreResultCache.savePayload(context, payload);
  }

  /**
   * Drops the cached results of sources that were deleted, imported or edited outside the explore tab and
   * tells the tab to forget what it already loaded for them.
   */
  static async invalidateSources(context: Context, sourceUrls: string[]): Promise<void> {
    const prefixes = sourceUrls.map((url: string): string => (url || '').trim())
      .filter((url: string): boolean => url.length > 0)
      .map((url: string): string => `${url}\n`);
    if (prefixes.length === 0) return;
    try {
      const payload = await ExploreResultCache.loadPayload(context);
      const remaining = payload.entries.filter((item: ExploreCacheEntry): boolean =>
        !prefixes.some((prefix: string): boolean => item.key.startsWith(prefix)));
      if (remaining.length !== payload.entries.length) {
        payload.entries = remaining;
        await ExploreResultCache.savePayload(context, payload);
      }
    } catch (e) {
      console.warn('清理发现内容缓存失败:', e);
    }
    const revision = AppStorage.get<number>(ExploreResultCache.INVALIDATION_REVISION_KEY) || 0;
    AppStorage.setOrCreate(ExploreResultCache.INVALIDATION_REVISION_KEY, revision + 1);
  }

  private static async loadPayload(context: Context): Promise<ExploreCachePayload> {
    const store = await preferences.getPreferences(context, ExploreResultCache.STORE_NAME);
    const value = await store.get(ExploreResultCache.CACHE_KEY, '');
    if (typeof value !== 'string' || !value) return new ExploreCachePayload();
    try {
      const payload = JSON.parse(value) as ExploreCachePayload;
      if (payload && Number(payload.version) === ExploreResultCache.SCHEMA_VERSION &&
        Array.isArray(payload.entries)) return payload;
    } catch (e) {
      console.warn('读取发现内容缓存失败:', e);
    }
    return new ExploreCachePayload();
  }

  private static async savePayload(context: Context, payload: ExploreCachePayload): Promise<void> {
    const store = await preferences.getPreferences(context, ExploreResultCache.STORE_NAME);
    await store.put(ExploreResultCache.CACHE_KEY, JSON.stringify(payload));
    await store.flush();
  }

  private static buildKey(sourceUrl: string, platform: string, entryTitle: string, entryUrl: string): string {
    const normalizedSource = (sourceUrl || '').trim();
    const normalizedEntryUrl = (entryUrl || '').trim();
    if (!normalizedSource || !normalizedEntryUrl) return '';
    return `${normalizedSource}\n${(platform || '').trim()}\n${(entryTitle || '').trim()}\n${normalizedEntryUrl}`;
  }

  private static cloneSearchBook(source: SearchBook): SearchBook {
    const target = new SearchBook();
    target.bookUrl = source.bookUrl || '';
    target.origin = source.origin || '';
    target.originName = source.originName || '';
    target.type = source.type || 0;
    target.name = source.name || '';
    target.author = source.author || '';
    target.kind = source.kind || '';
    target.status = source.status || '';
    target.coverUrl = source.coverUrl || '';
    target.intro = source.intro || '';
    target.latestChapterTitle = source.latestChapterTitle || '';
    target.wordCount = source.wordCount || '';
    target.updateTime = source.updateTime || '';
    target.tocUrl = source.tocUrl || '';
    target.variable = source.variable || '';
    target.bookSourceComment = source.bookSourceComment || '';
    target.customOrder = source.customOrder || 0;
    target.weight = source.weight || 0;
    return target;
  }
}
