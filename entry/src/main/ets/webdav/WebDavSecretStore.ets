import { Context } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { huks } from '@kit.UniversalKeystoreKit';
import { util } from '@kit.ArkTS';
import preferences from '@ohos.data.preferences';
import { WebDavError } from './WebDavError';

class WebDavEncryptedSecret {
  version: number = 1;
  iv: string = '';
  data: string = '';
}

export class WebDavSecretStore {
  private static readonly STORE_NAME: string = 'webdav_secrets';
  private static readonly KEY_PREFIX: string = 'password_';
  private static readonly KEY_ALIAS: string = 'legado_harmony_webdav_secret_v1';
  private static runtimePasswords: Record<string, string> = {};
  private static keyReady: Promise<void> | null = null;

  static async savePassword(context: Context, connectionId: string, password: string,
    persistent: boolean): Promise<void> {
    if (!connectionId) return;
    WebDavSecretStore.runtimePasswords[connectionId] = password || '';
    const store = await preferences.getPreferences(context, WebDavSecretStore.STORE_NAME);
    if (!persistent || !password) {
      await store.delete(WebDavSecretStore.preferenceKey(connectionId));
      await store.flush();
      return;
    }
    await WebDavSecretStore.ensureKey();
    const random = cryptoFramework.createRandom();
    const iv = (await random.generateRandom(16)).data;
    const plaintext = new util.TextEncoder().encodeInto(password);
    try {
      const encrypted = await WebDavSecretStore.transform(
        huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, plaintext, iv);
      const helper = new util.Base64Helper();
      const record = new WebDavEncryptedSecret();
      record.iv = helper.encodeToStringSync(iv);
      record.data = helper.encodeToStringSync(encrypted);
      await store.put(WebDavSecretStore.preferenceKey(connectionId), JSON.stringify(record));
      await store.flush();
    } finally {
      WebDavSecretStore.clearBytes(plaintext);
    }
  }

  static async password(context: Context, connectionId: string): Promise<string> {
    if (!connectionId) return '';
    const runtime = WebDavSecretStore.runtimePasswords[connectionId];
    if (runtime !== undefined) return runtime;
    const store = await preferences.getPreferences(context, WebDavSecretStore.STORE_NAME);
    const raw = await store.get(WebDavSecretStore.preferenceKey(connectionId), '');
    if (typeof raw !== 'string' || !raw) return '';
    try {
      const record = JSON.parse(raw) as WebDavEncryptedSecret;
      if (!record || record.version !== 1 || !record.iv || !record.data) return '';
      await WebDavSecretStore.ensureKey();
      const helper = new util.Base64Helper();
      const iv = helper.decodeSync(record.iv);
      const encrypted = helper.decodeSync(record.data);
      const plaintext = await WebDavSecretStore.transform(
        huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT, encrypted, iv);
      const value = util.TextDecoder.create('utf-8').decodeWithStream(plaintext, { stream: false });
      WebDavSecretStore.clearBytes(plaintext);
      WebDavSecretStore.runtimePasswords[connectionId] = value;
      return value;
    } catch (error) {
      console.warn('[WebDAV] 无法读取已保存的凭据:', WebDavSecretStore.errorMessage(error as Object));
      return '';
    }
  }

  static async deletePassword(context: Context, connectionId: string): Promise<void> {
    WebDavSecretStore.runtimePasswords[connectionId] = '';
    const store = await preferences.getPreferences(context, WebDavSecretStore.STORE_NAME);
    await store.delete(WebDavSecretStore.preferenceKey(connectionId));
    await store.flush();
  }

  private static async ensureKey(): Promise<void> {
    if (WebDavSecretStore.keyReady) return await WebDavSecretStore.keyReady;
    WebDavSecretStore.keyReady = (async (): Promise<void> => {
      let exists = false;
      try {
        exists = await huks.isKeyItemExist(WebDavSecretStore.KEY_ALIAS, { properties: [] });
      } catch (error) {
        if (!WebDavSecretStore.isMissingEntity(error as Object)) {
          throw new Error(WebDavSecretStore.errorMessage(error as Object));
        }
      }
      if (exists) return;
      try {
        await huks.generateKeyItem(WebDavSecretStore.KEY_ALIAS, {
          properties: WebDavSecretStore.keyProperties()
        });
      } catch (error) {
        if (!WebDavSecretStore.isAlreadyExists(error as Object)) {
          throw new Error(WebDavSecretStore.errorMessage(error as Object));
        }
      }
    })();
    try {
      await WebDavSecretStore.keyReady;
    } catch (error) {
      WebDavSecretStore.keyReady = null;
      throw new Error(WebDavSecretStore.errorMessage(error as Object));
    }
  }

  private static keyProperties(): huks.HuksParam[] {
    return [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE,
        value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT |
          huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_CBC },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_PKCS7 }
    ];
  }

  private static operationProperties(purpose: huks.HuksKeyPurpose, iv: Uint8Array): huks.HuksParam[] {
    return [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_CBC },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_PKCS7 },
      { tag: huks.HuksTag.HUKS_TAG_IV, value: iv }
    ];
  }

  private static async transform(purpose: huks.HuksKeyPurpose, input: Uint8Array,
    iv: Uint8Array): Promise<Uint8Array> {
    const properties = WebDavSecretStore.operationProperties(purpose, iv);
    const session = await huks.initSession(WebDavSecretStore.KEY_ALIAS, { properties: properties });
    const result = await huks.finishSession(session.handle, { properties: properties, inData: input });
    if (!result.outData) throw new Error('系统密钥服务未返回数据');
    return result.outData;
  }

  private static preferenceKey(connectionId: string): string {
    return `${WebDavSecretStore.KEY_PREFIX}${connectionId.replace(/[^a-zA-Z0-9_-]/g, '_')}`;
  }

  private static clearBytes(value: Uint8Array): void {
    value.fill(0);
  }

  private static errorMessage(error: Object): string {
    return WebDavError.message(error);
  }

  private static isMissingEntity(error: Object): boolean {
    const value = error as Record<string, Object>;
    const code = Number(value?.['code'] || value?.['errorCode'] || 0);
    const message = WebDavSecretStore.errorMessage(error).toLowerCase();
    return code === 12000011 || code === 12000013 ||
      message.includes('entity does not exist') || message.includes('credential does not exist');
  }

  private static isAlreadyExists(error: Object): boolean {
    const value = error as Record<string, Object>;
    const code = Number(value?.['code'] || value?.['errorCode'] || 0);
    const message = WebDavSecretStore.errorMessage(error).toLowerCase();
    return code === 12000017 || message.includes('already exist');
  }
}
