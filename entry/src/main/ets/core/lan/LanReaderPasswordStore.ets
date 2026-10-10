import { Context } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { HuksSecretStore } from '../../utils/HuksSecretStore';

/**
 * The browser-reading access password. It is stored encrypted with a system keystore key; the AppStorage entry
 * `lanReaderPassword` only mirrors it in memory for the running app and the settings page.
 *
 * Older versions persisted that AppStorage entry as plain text. restore() moves such a value into the encrypted
 * store and removes the plain copy.
 */
export class LanReaderPasswordStore {
  static readonly STORAGE_KEY: string = 'lanReaderPassword';
  // true when a password was saved but can no longer be decrypted; the settings page asks for a new one
  static readonly UNREADABLE_KEY: string = 'lanReaderPasswordUnreadable';
  private static readonly RECORD_NAME: string = 'access_password';
  private static readonly store: HuksSecretStore =
    new HuksSecretStore('lan_reader_secrets', 'legado_harmony_lan_reader_secret_v1');
  private static restoring: Promise<void> | null = null;

  /** Loads the password into memory once per process. The server waits for this before accepting requests. */
  static restore(context: Context): Promise<void> {
    if (!LanReaderPasswordStore.restoring) {
      LanReaderPasswordStore.restoring = LanReaderPasswordStore.runRestore(context).catch((error: Error) => {
        // Let a later start try again instead of failing for the rest of the process.
        LanReaderPasswordStore.restoring = null;
        throw error;
      });
    }
    return LanReaderPasswordStore.restoring;
  }

  static async save(context: Context, password: string): Promise<void> {
    await LanReaderPasswordStore.store.save(context, LanReaderPasswordStore.RECORD_NAME, password);
    AppStorage.setOrCreate<boolean>(LanReaderPasswordStore.UNREADABLE_KEY, false);
  }

  private static async runRestore(context: Context): Promise<void> {
    AppStorage.setOrCreate<boolean>(LanReaderPasswordStore.UNREADABLE_KEY, false);
    const legacy = (AppStorage.get<string>(LanReaderPasswordStore.STORAGE_KEY) || '').trim();
    if (legacy) {
      try {
        await LanReaderPasswordStore.store.save(context, LanReaderPasswordStore.RECORD_NAME, legacy);
      } catch (error) {
        // Keep the old copy rather than lose the password; the move is retried on the next launch.
        console.warn('[LanReader] 访问密码迁移到加密存储失败，下次启动重试:', (error as Error).message);
        return;
      }
      LanReaderPasswordStore.dropPlainCopy(legacy);
      return;
    }
    const saved = await LanReaderPasswordStore.store.read(context, LanReaderPasswordStore.RECORD_NAME);
    if (saved.unreadable) {
      // Never fall back to "no password": that would open the bookshelf to the whole network. Lock the service
      // behind a value nobody knows until the owner sets a new password.
      AppStorage.setOrCreate<boolean>(LanReaderPasswordStore.UNREADABLE_KEY, true);
      LanReaderPasswordStore.dropPlainCopy(LanReaderPasswordStore.randomLock());
      return;
    }
    LanReaderPasswordStore.dropPlainCopy(saved.value);
  }

  /** Stops persisting the AppStorage entry and leaves `value` there for this run only. */
  private static dropPlainCopy(value: string): void {
    PersistentStorage.deleteProp(LanReaderPasswordStore.STORAGE_KEY);
    AppStorage.setOrCreate<string>(LanReaderPasswordStore.STORAGE_KEY, value);
  }

  private static randomLock(): string {
    const bytes = cryptoFramework.createRandom().generateRandomSync(24).data;
    let text = '';
    for (let i = 0; i < bytes.length; i++) text += bytes[i].toString(16).padStart(2, '0');
    return text;
  }
}
