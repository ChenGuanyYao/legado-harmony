import { SearchBook } from '../model/data/Book';

export class SearchResultGroupSnapshot {
  token: string = '';
  title: string = '';
  books: SearchBook[] = [];
}

/**
 * Search aggregation is presentation-only. Raw SearchBook results stay intact so opening a group
 * can still select the exact source result, including its URL and runtime variables.
 */
export class SearchResultAggregationStore {
  private static readonly MAX_SNAPSHOTS: number = 12;
  private static serial: number = 0;
  private static snapshots: Map<string, SearchResultGroupSnapshot> = new Map();
  private static order: string[] = [];

  static aggregate(books: SearchBook[]): SearchBook[] {
    const groups: Map<string, SearchBook[]> = new Map();
    const order: string[] = [];
    for (const book of books) {
      const key = SearchResultAggregationStore.keyOf(book);
      const members = groups.get(key);
      if (members) {
        members.push(book);
      } else {
        groups.set(key, [book]);
        order.push(key);
      }
    }
    const result: SearchBook[] = [];
    for (const key of order) {
      const members = groups.get(key) || [];
      if (members.length === 0) continue;
      const representative = SearchResultAggregationStore.cloneBook(members[0]);
      representative.aggregationKey = key;
      representative.aggregationCount = members.length;
      result.push(representative);
    }
    return result;
  }

  static members(books: SearchBook[], aggregationKey: string): SearchBook[] {
    if (!aggregationKey) return [];
    return books.filter((book: SearchBook): boolean =>
      SearchResultAggregationStore.keyOf(book) === aggregationKey);
  }

  static publish(title: string, books: SearchBook[]): string {
    const token = `search_group_${Date.now()}_${++SearchResultAggregationStore.serial}`;
    const snapshot = new SearchResultGroupSnapshot();
    snapshot.token = token;
    snapshot.title = title || books[0]?.name || '同名书籍';
    snapshot.books = books.map((book: SearchBook): SearchBook => SearchResultAggregationStore.cloneBook(book));
    SearchResultAggregationStore.snapshots.set(token, snapshot);
    SearchResultAggregationStore.order.push(token);
    while (SearchResultAggregationStore.order.length > SearchResultAggregationStore.MAX_SNAPSHOTS) {
      const removed = SearchResultAggregationStore.order.shift() || '';
      if (removed) SearchResultAggregationStore.snapshots.delete(removed);
    }
    return token;
  }

  static get(token: string): SearchResultGroupSnapshot | null {
    return SearchResultAggregationStore.snapshots.get(token) || null;
  }

  static keyOf(book: SearchBook): string {
    const title = SearchResultAggregationStore.normalizeTitle(book.name);
    if (title) return `title:${title}`;
    return `item:${book.origin || ''}::${book.bookUrl || ''}`;
  }

  private static normalizeTitle(value: string): string {
    return (value || '').trim().toLowerCase()
      .replace(/[\u200B-\u200D\uFEFF]/g, '')
      .replace(/\s+/g, '')
      .replace(/[《》【】\[\]（）()「」『』"“”'‘’.,，。:：;；!！?？、·_\-]/g, '');
  }

  private static cloneBook(source: SearchBook): SearchBook {
    const target = new SearchBook();
    target.bookUrl = source.bookUrl || '';
    target.origin = source.origin || '';
    target.originName = source.originName || '';
    target.type = source.type || 0;
    target.name = source.name || '';
    target.author = source.author || '';
    target.kind = source.kind || '';
    target.coverUrl = source.coverUrl || '';
    target.intro = source.intro || '';
    target.latestChapterTitle = source.latestChapterTitle || '';
    target.wordCount = source.wordCount || '';
    target.tocUrl = source.tocUrl || '';
    target.variable = source.variable || '';
    target.bookSourceComment = source.bookSourceComment || '';
    target.customOrder = source.customOrder || 0;
    target.weight = source.weight || 0;
    target.aggregationKey = source.aggregationKey || '';
    target.aggregationCount = Math.max(1, source.aggregationCount || 1);
    return target;
  }
}
