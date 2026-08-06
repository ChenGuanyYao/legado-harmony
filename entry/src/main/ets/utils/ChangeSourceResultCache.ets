import { Context } from '@kit.AbilityKit';
import preferences from '@ohos.data.preferences';
import { SearchBook } from '../model/data/Book';

class ChangeSourceCacheEntry {
  key: string = '';
  updatedAt: number = 0;
  results: SearchBook[] = [];
}

class ChangeSourceCachePayload {
  entries: ChangeSourceCacheEntry[] = [];
}

class ChangeSourceCacheIndexEntry {
  key: string = '';
  updatedAt: number = 0;
}

export class ChangeSourceResultCache {
  private static readonly STORE_NAME: string = 'change_source_result_cache';
  private static readonly CACHE_KEY: string = 'entries';
  private static readonly INDEX_KEY: string = 'entry_index_v2';
  private static readonly ENTRY_PREFIX: string = 'entry_v2_';
  private static readonly MAX_BOOKS: number = 30;
  private static readonly MAX_RESULTS_PER_BOOK: number = 50;
  private static readonly MAX_AGE_MS: number = 24 * 60 * 60 * 1000;

  static async load(context: Context, bookName: string, bookAuthor: string = ''): Promise<SearchBook[]> {
    const store = await preferences.getPreferences(context, ChangeSourceResultCache.STORE_NAME);
    const key = ChangeSourceResultCache.buildBookKey(bookName, bookAuthor);
    const raw = await store.get(ChangeSourceResultCache.entryPreferenceKey(key), '');
    const entry = ChangeSourceResultCache.parseEntry(typeof raw === 'string' ? raw : '');
    if (entry && Date.now() - entry.updatedAt <= ChangeSourceResultCache.MAX_AGE_MS) {
      return entry.results.map((item: SearchBook) => ChangeSourceResultCache.cloneSearchBook(item));
    }

    // One-time compatibility read for caches written by the former monolithic payload.
    const payload = await ChangeSourceResultCache.loadLegacyPayload(context);
    const legacyKey = ChangeSourceResultCache.buildLegacyBookKey(bookName);
    const legacyEntry = payload.entries.find((item: ChangeSourceCacheEntry) => item.key === legacyKey);
    if (!legacyEntry || !Array.isArray(legacyEntry.results) ||
      Date.now() - legacyEntry.updatedAt > ChangeSourceResultCache.MAX_AGE_MS) return [];
    return legacyEntry.results.slice(0, ChangeSourceResultCache.MAX_RESULTS_PER_BOOK)
      .map((item: SearchBook) => ChangeSourceResultCache.cloneSearchBook(item));
  }

  static async save(context: Context, bookName: string, results: SearchBook[], bookAuthor: string = ''): Promise<void> {
    const key = ChangeSourceResultCache.buildBookKey(bookName, bookAuthor);
    if (!key) {
      return;
    }
    const entry = new ChangeSourceCacheEntry();
    entry.key = key;
    entry.updatedAt = Date.now();
    entry.results = results.slice(0, ChangeSourceResultCache.MAX_RESULTS_PER_BOOK)
      .map((item: SearchBook) => ChangeSourceResultCache.cloneSearchBook(item));

    const store = await preferences.getPreferences(context, ChangeSourceResultCache.STORE_NAME);
    await store.put(ChangeSourceResultCache.entryPreferenceKey(key), JSON.stringify(entry));
    const index = await ChangeSourceResultCache.loadIndex(context);
    const next = new ChangeSourceCacheIndexEntry();
    next.key = key;
    next.updatedAt = entry.updatedAt;
    const merged = [next].concat(index.filter((item: ChangeSourceCacheIndexEntry): boolean => item.key !== key));
    const kept = merged.slice(0, ChangeSourceResultCache.MAX_BOOKS);
    for (const removed of merged.slice(ChangeSourceResultCache.MAX_BOOKS)) {
      await store.delete(ChangeSourceResultCache.entryPreferenceKey(removed.key));
    }
    await store.put(ChangeSourceResultCache.INDEX_KEY, JSON.stringify(kept));
    await store.flush();
  }

  private static async loadLegacyPayload(context: Context): Promise<ChangeSourceCachePayload> {
    const store = await preferences.getPreferences(context, ChangeSourceResultCache.STORE_NAME);
    const value = await store.get(ChangeSourceResultCache.CACHE_KEY, '');
    if (typeof value !== 'string' || !value) {
      return new ChangeSourceCachePayload();
    }
    try {
      const payload = JSON.parse(value) as ChangeSourceCachePayload;
      if (payload && Array.isArray(payload.entries)) {
        return payload;
      }
    } catch (e) {
      console.warn('读取换源结果缓存失败:', e);
    }
    return new ChangeSourceCachePayload();
  }

  private static async loadIndex(context: Context): Promise<ChangeSourceCacheIndexEntry[]> {
    const store = await preferences.getPreferences(context, ChangeSourceResultCache.STORE_NAME);
    const raw = await store.get(ChangeSourceResultCache.INDEX_KEY, '');
    if (typeof raw !== 'string' || !raw) return [];
    try {
      const parsed = JSON.parse(raw) as Object;
      if (!Array.isArray(parsed)) return [];
      const result: ChangeSourceCacheIndexEntry[] = [];
      const items: Object[] = parsed as Object[];
      for (const item of items) {
        if (!item || typeof item !== 'object' || Array.isArray(item)) continue;
        const record = item as Record<string, Object>;
        const entry = new ChangeSourceCacheIndexEntry();
        entry.key = String(record['key'] || '');
        entry.updatedAt = Number(record['updatedAt'] || 0);
        if (entry.key) result.push(entry);
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  private static parseEntry(raw: string): ChangeSourceCacheEntry | null {
    if (!raw) return null;
    try {
      const parsed = JSON.parse(raw) as ChangeSourceCacheEntry;
      if (!parsed || !Array.isArray(parsed.results)) return null;
      return parsed;
    } catch (_) {
      return null;
    }
  }

  private static buildBookKey(bookName: string, bookAuthor: string): string {
    const normalized = `${ChangeSourceResultCache.normalize(bookName)}\n${ChangeSourceResultCache.normalize(bookAuthor)}`;
    return normalized.trim() ? ChangeSourceResultCache.hashKey(normalized) : '';
  }

  private static buildLegacyBookKey(bookName: string): string {
    return (bookName || '').trim().replace(/\s+/g, '').toLowerCase();
  }

  private static normalize(value: string): string {
    return (value || '').trim().replace(/\s+/g, '').toLowerCase();
  }

  private static hashKey(value: string): string {
    let hash = 2166136261;
    for (let index = 0; index < value.length; index++) {
      hash ^= value.charCodeAt(index);
      hash = Math.imul(hash, 16777619);
    }
    return (hash >>> 0).toString(16).padStart(8, '0');
  }

  private static entryPreferenceKey(key: string): string {
    return `${ChangeSourceResultCache.ENTRY_PREFIX}${key}`;
  }

  private static cloneSearchBook(source: SearchBook): SearchBook {
    const target = new SearchBook();
    target.bookUrl = source.bookUrl || '';
    target.origin = source.origin || '';
    target.originName = source.originName || '';
    target.type = source.type || 0;
    target.name = source.name || '';
    target.author = source.author || '';
    target.kind = '';
    target.coverUrl = '';
    target.intro = '';
    target.latestChapterTitle = '';
    target.wordCount = '';
    target.tocUrl = source.tocUrl || '';
    target.variable = source.variable || '';
    target.bookSourceComment = '';
    target.customOrder = source.customOrder || 0;
    target.weight = source.weight || 0;
    return target;
  }
}
