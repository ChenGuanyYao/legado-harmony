import { Context } from '@kit.AbilityKit';
import preferences from '@ohos.data.preferences';

/**
 * Keeps non-sensitive unsaved form values alive across page rebuilds and app
 * foreground/background transitions. Credential drafts use their dedicated
 * encrypted secret store instead of this preferences-backed store.
 */
export class FormDraftStore {
  private static readonly STORE_NAME: string = 'form_drafts';
  private static drafts: Map<string, string> = new Map<string, string>();
  private static knownKeys: Set<string> = new Set<string>();
  private static saveTimers: Map<string, number> = new Map<string, number>();
  private static writeQueues: Map<string, Promise<void>> = new Map<string, Promise<void>>();

  static get(key: string): string {
    return FormDraftStore.drafts.get(key) || '';
  }

  static put(key: string, value: string): void {
    if (!key) return;
    FormDraftStore.knownKeys.add(key);
    if (!value) {
      FormDraftStore.drafts.delete(key);
      return;
    }
    FormDraftStore.drafts.set(key, value);
  }

  static remove(key: string): void {
    if (!key) return;
    FormDraftStore.knownKeys.add(key);
    FormDraftStore.drafts.delete(key);
  }

  static async load(context: Context, key: string): Promise<string> {
    // An explicitly removed key is different from a key that has not been read
    // yet. Do not resurrect an old disk value while its queued delete is pending.
    if (FormDraftStore.knownKeys.has(key)) return FormDraftStore.get(key);
    try {
      const store = await preferences.getPreferences(
        FormDraftStore.preferencesContext(context), FormDraftStore.STORE_NAME);
      const raw = await store.get(key, '');
      const value = typeof raw === 'string' ? raw : '';
      FormDraftStore.put(key, value);
      return value;
    } catch (_) {
      return '';
    }
  }

  static persistSoon(context: Context, key: string, value: string): void {
    FormDraftStore.put(key, value);
    const current = FormDraftStore.saveTimers.get(key);
    if (current !== undefined) clearTimeout(current);
    const timerId = setTimeout(() => {
      FormDraftStore.saveTimers.delete(key);
      FormDraftStore.persist(context, key, value);
    }, 120);
    FormDraftStore.saveTimers.set(key, timerId);
  }

  static async persist(context: Context, key: string, value: string): Promise<void> {
    FormDraftStore.put(key, value);
    const current = FormDraftStore.saveTimers.get(key);
    if (current !== undefined) {
      clearTimeout(current);
      FormDraftStore.saveTimers.delete(key);
    }
    const previous = FormDraftStore.writeQueues.get(key) || Promise.resolve();
    const next = previous.then(async () => {
      try {
        const store = await preferences.getPreferences(
          FormDraftStore.preferencesContext(context), FormDraftStore.STORE_NAME);
        if (value) await store.put(key, value);
        else await store.delete(key);
        await store.flush();
      } catch (error) {
        console.warn('保存表单草稿失败:', error);
      }
    });
    FormDraftStore.writeQueues.set(key, next);
    await next;
    if (FormDraftStore.writeQueues.get(key) === next) {
      FormDraftStore.writeQueues.delete(key);
    }
  }

  static async removePersistent(context: Context, key: string): Promise<void> {
    FormDraftStore.remove(key);
    const current = FormDraftStore.saveTimers.get(key);
    if (current !== undefined) {
      clearTimeout(current);
      FormDraftStore.saveTimers.delete(key);
    }
    await FormDraftStore.persist(context, key, '');
  }

  private static preferencesContext(context: Context): Context {
    try {
      return context.getApplicationContext();
    } catch (_) {
      return context;
    }
  }
}
