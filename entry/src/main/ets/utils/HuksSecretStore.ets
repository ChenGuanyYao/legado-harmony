import { Context } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { huks } from '@kit.UniversalKeystoreKit';
import { util } from '@kit.ArkTS';
import preferences from '@ohos.data.preferences';

class HuksEncryptedSecret {
  version: number = 1;
  iv: string = '';
  data: string = '';
}

/** What a stored secret looks like when it is read back. */
export class HuksSecretReadResult {
  value: string = '';
  // a record exists on disk but could not be decrypted (key lost, data damaged)
  unreadable: boolean = false;
}

/**
 * Small secrets kept in app preferences, encrypted with an AES-256 key that never leaves the system keystore
 * (HUKS). Same scheme as the WebDAV and OPDS credential stores; one instance per preferences file and key alias.
 */
export class HuksSecretStore {
  private readonly storeName: string;
  private readonly keyAlias: string;
  private keyReady: Promise<void> | null = null;

  constructor(storeName: string, keyAlias: string) {
    this.storeName = storeName;
    this.keyAlias = keyAlias;
  }

  /** An empty value removes the record. */
  async save(context: Context, name: string, value: string): Promise<void> {
    const store = await preferences.getPreferences(context, this.storeName);
    if (!value) {
      await store.delete(name);
      await store.flush();
      return;
    }
    await this.ensureKey();
    const iv = (await cryptoFramework.createRandom().generateRandom(16)).data;
    const plaintext = new util.TextEncoder().encodeInto(value);
    try {
      const encrypted = await this.transform(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, plaintext, iv);
      const helper = new util.Base64Helper();
      const record = new HuksEncryptedSecret();
      record.iv = helper.encodeToStringSync(iv);
      record.data = helper.encodeToStringSync(encrypted);
      await store.put(name, JSON.stringify(record));
      await store.flush();
    } finally {
      plaintext.fill(0);
    }
  }

  async read(context: Context, name: string): Promise<HuksSecretReadResult> {
    const result = new HuksSecretReadResult();
    const store = await preferences.getPreferences(context, this.storeName);
    const raw = await store.get(name, '');
    if (typeof raw !== 'string' || !raw) return result;
    try {
      const record = JSON.parse(raw) as HuksEncryptedSecret;
      if (!record || record.version !== 1 || !record.iv || !record.data) throw new Error('invalid record');
      await this.ensureKey();
      const helper = new util.Base64Helper();
      const plaintext = await this.transform(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT,
        helper.decodeSync(record.data), helper.decodeSync(record.iv));
      result.value = util.TextDecoder.create('utf-8').decodeToString(plaintext);
      plaintext.fill(0);
    } catch (error) {
      console.warn(`[HuksSecretStore] 无法读取已保存的密文 ${this.storeName}/${name}:`,
        HuksSecretStore.errorMessage(error as Object));
      result.unreadable = true;
    }
    return result;
  }

  private async ensureKey(): Promise<void> {
    if (!this.keyReady) {
      this.keyReady = this.createKeyIfMissing();
    }
    try {
      await this.keyReady;
    } catch (error) {
      this.keyReady = null;
      throw new Error(HuksSecretStore.errorMessage(error as Object));
    }
  }

  private async createKeyIfMissing(): Promise<void> {
    let exists = false;
    try {
      exists = await huks.isKeyItemExist(this.keyAlias, { properties: [] });
    } catch (error) {
      if (!HuksSecretStore.hasCode(error as Object, [12000011, 12000013])) throw error as Error;
    }
    if (exists) return;
    try {
      await huks.generateKeyItem(this.keyAlias, {
        properties: [
          { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
          { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
          { tag: huks.HuksTag.HUKS_TAG_PURPOSE,
            value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
          { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_CBC },
          { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_PKCS7 }
        ]
      });
    } catch (error) {
      // Created by a concurrent caller in the meantime.
      if (!HuksSecretStore.hasCode(error as Object, [12000017])) throw error as Error;
    }
  }

  private async transform(purpose: huks.HuksKeyPurpose, input: Uint8Array, iv: Uint8Array): Promise<Uint8Array> {
    const properties: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_CBC },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_PKCS7 },
      { tag: huks.HuksTag.HUKS_TAG_IV, value: iv }
    ];
    const session = await huks.initSession(this.keyAlias, { properties: properties });
    const result = await huks.finishSession(session.handle, { properties: properties, inData: input });
    if (!result.outData) throw new Error('系统密钥服务未返回数据');
    return result.outData;
  }

  private static hasCode(error: Object, codes: number[]): boolean {
    const value = error as Record<string, Object>;
    return codes.includes(Number(value?.['code'] || value?.['errorCode'] || 0));
  }

  private static errorMessage(error: Object): string {
    if (error instanceof Error && error.message) return error.message;
    const value = error as Record<string, Object>;
    return String(value?.['message'] || value?.['code'] || error || '未知错误');
  }
}
