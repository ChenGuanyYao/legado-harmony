import { Context } from '@kit.AbilityKit';
import preferences from '@ohos.data.preferences';

interface ExploreCategoryHistoryItem {
  sourceUrl: string;
  last: string;
  recent: string[];
}

/**
 * 发现页按书源记住的分类：最近点过的几个（全部分类面板顶部的“最近”）和上次停留的那个（再次进入该书源时回到这里）。
 * 分类用 `分类名\n地址` 标识；只存本机，不参与同步。
 */
export class ExploreCategoryHistoryStore {
  static readonly MAX_RECENT: number = 6;
  private static readonly STORE_NAME: string = 'explore_category_history';
  private static readonly KEY_HISTORY: string = 'history';
  /** 只保留最近用过的这么多个书源，避免长期使用后无限增长。 */
  private static readonly MAX_SOURCES: number = 80;
  private static items: ExploreCategoryHistoryItem[] = [];
  private static loaded: boolean = false;

  static entryKey(title: string, url: string): string {
    return `${title}\n${url}`;
  }

  static async load(context: Context): Promise<void> {
    if (ExploreCategoryHistoryStore.loaded) {
      return;
    }
    ExploreCategoryHistoryStore.loaded = true;
    try {
      const store = await preferences.getPreferences(context, ExploreCategoryHistoryStore.STORE_NAME);
      const raw = await store.get(ExploreCategoryHistoryStore.KEY_HISTORY, '') as string;
      if (!raw) {
        return;
      }
      const parsed = JSON.parse(raw) as ExploreCategoryHistoryItem[];
      if (!Array.isArray(parsed)) {
        return;
      }
      ExploreCategoryHistoryStore.items = parsed.filter((item: ExploreCategoryHistoryItem): boolean =>
        !!item && typeof item.sourceUrl === 'string' && !!item.sourceUrl)
        .map((item: ExploreCategoryHistoryItem): ExploreCategoryHistoryItem => {
          const normalized: ExploreCategoryHistoryItem = {
            sourceUrl: item.sourceUrl,
            last: typeof item.last === 'string' ? item.last : '',
            recent: Array.isArray(item.recent) ?
              item.recent.filter((key: string): boolean => typeof key === 'string' && !!key)
                .slice(0, ExploreCategoryHistoryStore.MAX_RECENT) : []
          };
          return normalized;
        });
    } catch (e) {
      console.warn('读取发现分类记录失败:', e);
    }
  }

  static last(sourceUrl: string): string {
    const item = ExploreCategoryHistoryStore.find(sourceUrl);
    return item ? item.last : '';
  }

  static recent(sourceUrl: string): string[] {
    const item = ExploreCategoryHistoryStore.find(sourceUrl);
    return item ? [...item.recent] : [];
  }

  /** 用户点选了某个分类：记为上次停留，并移到“最近”最前面。 */
  static record(context: Context, sourceUrl: string, key: string): void {
    if (!sourceUrl || !key) {
      return;
    }
    const previous = ExploreCategoryHistoryStore.find(sourceUrl);
    const recent = [key, ...(previous ? previous.recent : []).filter((item: string): boolean => item !== key)]
      .slice(0, ExploreCategoryHistoryStore.MAX_RECENT);
    const next: ExploreCategoryHistoryItem = { sourceUrl: sourceUrl, last: key, recent: recent };
    ExploreCategoryHistoryStore.items = [next, ...ExploreCategoryHistoryStore.items.filter(
      (item: ExploreCategoryHistoryItem): boolean => item.sourceUrl !== sourceUrl)]
      .slice(0, ExploreCategoryHistoryStore.MAX_SOURCES);
    ExploreCategoryHistoryStore.persist(context).catch((e: Error) => {
      console.warn('保存发现分类记录失败:', e);
    });
  }

  private static find(sourceUrl: string): ExploreCategoryHistoryItem | undefined {
    return ExploreCategoryHistoryStore.items.find((item: ExploreCategoryHistoryItem): boolean =>
      item.sourceUrl === sourceUrl);
  }

  private static async persist(context: Context): Promise<void> {
    const store = await preferences.getPreferences(context, ExploreCategoryHistoryStore.STORE_NAME);
    await store.put(ExploreCategoryHistoryStore.KEY_HISTORY, JSON.stringify(ExploreCategoryHistoryStore.items));
    await store.flush();
  }
}
