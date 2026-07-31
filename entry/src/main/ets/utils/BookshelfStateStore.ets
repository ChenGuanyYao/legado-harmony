import { Context } from '@kit.AbilityKit';
import preferences from '@ohos.data.preferences';

export class BookshelfStateStore {
  private static readonly STORE_NAME: string = 'bookshelf_state';
  private static readonly KEY_ACTIVE_GROUP_ID: string = 'activeGroupId';

  static async loadActiveGroupId(context: Context): Promise<number> {
    const store = await preferences.getPreferences(context, BookshelfStateStore.STORE_NAME);
    const value = await store.get(BookshelfStateStore.KEY_ACTIVE_GROUP_ID, 0);
    return typeof value === 'number' && Number.isInteger(value) ? value : 0;
  }

  static async saveActiveGroupId(context: Context, groupId: number): Promise<void> {
    const store = await preferences.getPreferences(context, BookshelfStateStore.STORE_NAME);
    await store.put(BookshelfStateStore.KEY_ACTIVE_GROUP_ID, groupId);
    await store.flush();
  }
}
