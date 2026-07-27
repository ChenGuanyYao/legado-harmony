import fs from '@ohos.file.fs';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import util from '@ohos.util';

export class BackupEncryptionMetadata {
  format: string = 'legado-harmony-encrypted-backup';
  version: number = 2;
  algorithm: string = 'AES256|GCM|PKCS7';
  kdf: string = 'PBKDF2|SHA256';
  iterations: number = 210000;
  salt: number[] = [];
  iv: number[] = [];
  authTag: number[] = [];
  chunkSize: number = 0;
  plainSize: number = 0;
  authTags: number[][] = [];
  payloadFile: string = 'payload.bin';
}

export class BackupCrypto {
  private static readonly SALT_LENGTH: number = 16;
  private static readonly IV_LENGTH: number = 12;
  private static readonly AUTH_TAG_LENGTH: number = 16;
  private static readonly KEY_LENGTH: number = 32;
  private static readonly LEGACY_IO_CHUNK_SIZE: number = 256 * 1024;
  private static readonly AUTH_CHUNK_SIZE: number = 256 * 1024;
  private static readonly PREVIOUS_AUTH_CHUNK_SIZE: number = 1024 * 1024;
  private static readonly MIN_ITERATIONS: number = 10000;
  private static readonly MAX_ITERATIONS: number = 2000000;
  private static readonly AAD_TEXT: string = 'legado-harmony-encrypted-backup|1';

  static async encryptFile(sourcePath: string, targetPath: string, password: string,
    onProgress?: (processed: number, total: number) => void):
    Promise<BackupEncryptionMetadata> {
    if ((password || '').length < 8) throw new Error('备份密码至少需要 8 个字符');
    const random = cryptoFramework.createRandom();
    const salt = (await random.generateRandom(BackupCrypto.SALT_LENGTH)).data;
    const iv = (await random.generateRandom(BackupCrypto.IV_LENGTH)).data;
    const key = await BackupCrypto.deriveKey(password, salt, 210000);
    try {
      const metadata = new BackupEncryptionMetadata();
      metadata.salt = BackupCrypto.toNumberArray(salt);
      metadata.iv = BackupCrypto.toNumberArray(iv);
      metadata.chunkSize = BackupCrypto.AUTH_CHUNK_SIZE;
      await BackupCrypto.encryptChunks(sourcePath, targetPath, key, iv, metadata, onProgress);
      return metadata;
    } catch (error) {
      await BackupCrypto.removeFile(targetPath);
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`备份加密失败：${message}`);
    } finally {
      key.clearMem();
      BackupCrypto.clearBytes(salt);
    }
  }

  static async decryptFile(sourcePath: string, targetPath: string, password: string,
    metadata: BackupEncryptionMetadata, onProgress?: (processed: number, total: number) => void): Promise<void> {
    BackupCrypto.validateMetadata(metadata);
    if (!password) throw new Error('备份已加密，请输入密码');
    const salt = BackupCrypto.toUint8Array(metadata.salt);
    const iv = BackupCrypto.toUint8Array(metadata.iv);
    const tag = metadata.version === 1 ? BackupCrypto.toUint8Array(metadata.authTag) : new Uint8Array();
    const key = await BackupCrypto.deriveKey(password, salt, metadata.iterations);
    try {
      if (metadata.version === 2) {
        await BackupCrypto.decryptChunks(sourcePath, targetPath, key, iv, metadata, onProgress);
      } else {
        const params = BackupCrypto.gcmParams(iv, tag, BackupCrypto.AAD_TEXT);
        const cipher = cryptoFramework.createCipher(metadata.algorithm);
        await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, params);
        await BackupCrypto.transformFile(sourcePath, targetPath, cipher, onProgress);
        await cipher.doFinal(null);
      }
    } catch (_) {
      await BackupCrypto.removeFile(targetPath);
      throw new Error('密码错误或备份文件已损坏');
    } finally {
      key.clearMem();
      BackupCrypto.clearBytes(salt);
    }
  }

  static parseMetadata(raw: string): BackupEncryptionMetadata {
    let metadata: BackupEncryptionMetadata;
    try {
      metadata = JSON.parse(raw) as BackupEncryptionMetadata;
    } catch (_) {
      throw new Error('备份加密信息无效');
    }
    BackupCrypto.validateMetadata(metadata);
    return metadata;
  }

  private static async deriveKey(password: string, salt: Uint8Array, iterations: number):
    Promise<cryptoFramework.SymKey> {
    const spec: cryptoFramework.PBKDF2Spec = {
      algName: 'PBKDF2',
      password: password,
      salt: salt,
      iterations: iterations,
      keySize: BackupCrypto.KEY_LENGTH
    };
    const secret = await cryptoFramework.createKdf('PBKDF2|SHA256').generateSecret(spec);
    try {
      return await cryptoFramework.createSymKeyGenerator('AES256').convertKey(secret);
    } finally {
      BackupCrypto.clearBytes(secret.data);
    }
  }

  private static gcmParams(iv: Uint8Array, tag: Uint8Array, aadText: string): cryptoFramework.GcmParamsSpec {
    return {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: new util.TextEncoder().encodeInto(aadText) },
      authTag: { data: tag }
    };
  }

  private static async encryptChunks(sourcePath: string, targetPath: string, key: cryptoFramework.SymKey,
    baseIv: Uint8Array, metadata: BackupEncryptionMetadata,
    onProgress?: (processed: number, total: number) => void): Promise<void> {
    const stat = await fs.stat(sourcePath);
    const total = stat.size;
    const totalChunks = Math.max(1, Math.ceil(total / BackupCrypto.AUTH_CHUNK_SIZE));
    metadata.plainSize = total;
    const source = await fs.open(sourcePath, fs.OpenMode.READ_ONLY);
    const target = await fs.open(targetPath,
      fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    let processed = 0;
    try {
      if (onProgress) onProgress(0, total);
      for (let index = 0; index < totalChunks; index++) {
        const expected = total > 0 ? Math.min(BackupCrypto.AUTH_CHUNK_SIZE, total - processed) : 0;
        const input = await BackupCrypto.readChunk(source.fd, expected);
        if (input.length !== expected) throw new Error('读取待加密备份失败');
        const chunkIv = BackupCrypto.chunkIv(baseIv, index);
        const aad = BackupCrypto.chunkAad(index, totalChunks, total);
        const params = BackupCrypto.gcmParams(
          chunkIv, new Uint8Array(BackupCrypto.AUTH_TAG_LENGTH), aad);
        const cipher = cryptoFramework.createCipher(metadata.algorithm);
        await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params);
        if (input.length > 0) {
          const output = await cipher.update({ data: input });
          if (output && output.data.length > 0) await BackupCrypto.writeAll(target.fd, output.data);
        }
        const tag = await cipher.doFinal(null);
        if (!tag || tag.data.length !== BackupCrypto.AUTH_TAG_LENGTH) {
          throw new Error('生成备份认证信息失败');
        }
        metadata.authTags.push(BackupCrypto.toNumberArray(tag.data));
        processed += input.length;
        if (onProgress) onProgress(processed, total);
      }
    } finally {
      await fs.close(source);
      await fs.close(target);
    }
  }

  private static async decryptChunks(sourcePath: string, targetPath: string, key: cryptoFramework.SymKey,
    baseIv: Uint8Array, metadata: BackupEncryptionMetadata,
    onProgress?: (processed: number, total: number) => void): Promise<void> {
    const total = metadata.plainSize;
    const totalChunks = metadata.authTags.length;
    const source = await fs.open(sourcePath, fs.OpenMode.READ_ONLY);
    const target = await fs.open(targetPath,
      fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    let processed = 0;
    try {
      if (onProgress) onProgress(0, total);
      for (let index = 0; index < totalChunks; index++) {
        const expected = total > 0 ? Math.min(metadata.chunkSize, total - processed) : 0;
        const input = await BackupCrypto.readChunk(source.fd, expected);
        if (input.length !== expected) throw new Error('加密备份载荷长度无效');
        const chunkIv = BackupCrypto.chunkIv(baseIv, index);
        const aad = BackupCrypto.chunkAad(index, totalChunks, total);
        const tag = BackupCrypto.toUint8Array(metadata.authTags[index]);
        const params = BackupCrypto.gcmParams(chunkIv, tag, aad);
        const cipher = cryptoFramework.createCipher(metadata.algorithm);
        await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, params);
        if (input.length > 0) {
          const output = await cipher.update({ data: input });
          if (output && output.data.length > 0) await BackupCrypto.writeAll(target.fd, output.data);
        }
        await cipher.doFinal(null);
        processed += input.length;
        if (onProgress) onProgress(processed, total);
      }
      const sourceStat = await fs.stat(sourcePath);
      if (processed !== total || sourceStat.size !== total) throw new Error('加密备份载荷长度无效');
    } finally {
      await fs.close(source);
      await fs.close(target);
    }
  }

  private static async readChunk(fd: number, length: number): Promise<Uint8Array> {
    if (length === 0) return new Uint8Array();
    const result = new Uint8Array(length);
    let readLength = 0;
    while (readLength < length) {
      const buffer = new ArrayBuffer(length - readLength);
      const count = await fs.read(fd, buffer);
      if (count <= 0) break;
      result.set(new Uint8Array(buffer, 0, count), readLength);
      readLength += count;
    }
    return result.subarray(0, readLength);
  }

  private static chunkIv(baseIv: Uint8Array, index: number): Uint8Array {
    const iv = new Uint8Array(BackupCrypto.IV_LENGTH);
    iv.set(baseIv);
    iv[8] = (index >>> 24) & 0xFF;
    iv[9] = (index >>> 16) & 0xFF;
    iv[10] = (index >>> 8) & 0xFF;
    iv[11] = index & 0xFF;
    return iv;
  }

  private static chunkAad(index: number, totalChunks: number, total: number): string {
    return `${BackupCrypto.AAD_TEXT}|2|${index}|${totalChunks}|${total}`;
  }

  private static async transformFile(sourcePath: string, targetPath: string,
    cipher: cryptoFramework.Cipher, onProgress?: (processed: number, total: number) => void): Promise<void> {
    const stat = await fs.stat(sourcePath);
    const total = stat.size;
    const source = await fs.open(sourcePath, fs.OpenMode.READ_ONLY);
    const target = await fs.open(targetPath,
      fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    let processed = 0;
    let lastPercent = -1;
    try {
      if (onProgress) onProgress(0, total);
      while (true) {
        const buffer = new ArrayBuffer(BackupCrypto.LEGACY_IO_CHUNK_SIZE);
        const length = await fs.read(source.fd, buffer);
        if (length <= 0) break;
        const input = new Uint8Array(buffer, 0, length);
        const output = await cipher.update({ data: input });
        if (output && output.data.length > 0) await BackupCrypto.writeAll(target.fd, output.data);
        processed += length;
        const percent = total > 0 ? Math.floor(processed * 100 / total) : 100;
        if (onProgress && percent !== lastPercent) {
          lastPercent = percent;
          onProgress(processed, total);
        }
      }
      if (onProgress && processed === 0) onProgress(0, 0);
    } finally {
      await fs.close(source);
      await fs.close(target);
    }
  }

  private static async writeAll(fd: number, data: Uint8Array): Promise<void> {
    let written = 0;
    while (written < data.length) {
      const remaining = data.subarray(written);
      const owned = new Uint8Array(remaining.length);
      owned.set(remaining);
      const count = await fs.write(fd, owned.buffer);
      if (count <= 0) throw new Error('写入加密备份失败');
      written += count;
    }
  }

  private static validateMetadata(metadata: BackupEncryptionMetadata): void {
    if (!metadata || metadata.format !== 'legado-harmony-encrypted-backup' ||
      (metadata.version !== 1 && metadata.version !== 2)) {
      throw new Error('备份加密格式不支持');
    }
    if (metadata.algorithm !== 'AES256|GCM|PKCS7' || metadata.kdf !== 'PBKDF2|SHA256') {
      throw new Error('备份加密算法不支持');
    }
    if (metadata.iterations < BackupCrypto.MIN_ITERATIONS ||
      metadata.iterations > BackupCrypto.MAX_ITERATIONS ||
      (metadata.salt || []).length !== BackupCrypto.SALT_LENGTH ||
      (metadata.iv || []).length !== BackupCrypto.IV_LENGTH ||
      metadata.payloadFile !== 'payload.bin') {
      throw new Error('备份加密参数无效');
    }
    BackupCrypto.validateByteArray(metadata.salt);
    BackupCrypto.validateByteArray(metadata.iv);
    if (metadata.version === 1) {
      if ((metadata.authTag || []).length !== BackupCrypto.AUTH_TAG_LENGTH) {
        throw new Error('备份加密参数无效');
      }
      BackupCrypto.validateByteArray(metadata.authTag);
      return;
    }
    if ((metadata.chunkSize !== BackupCrypto.AUTH_CHUNK_SIZE &&
      metadata.chunkSize !== BackupCrypto.PREVIOUS_AUTH_CHUNK_SIZE) ||
      !Number.isSafeInteger(metadata.plainSize) || metadata.plainSize < 0) {
      throw new Error('备份加密参数无效');
    }
    const expectedChunks = Math.max(1, Math.ceil(metadata.plainSize / metadata.chunkSize));
    if (!metadata.authTags || metadata.authTags.length !== expectedChunks) {
      throw new Error('备份加密参数无效');
    }
    for (const tag of metadata.authTags) {
      if (!tag || tag.length !== BackupCrypto.AUTH_TAG_LENGTH) throw new Error('备份加密参数无效');
      BackupCrypto.validateByteArray(tag);
    }
  }

  private static validateByteArray(value: number[]): void {
    for (const item of value) {
      if (!Number.isInteger(item) || item < 0 || item > 255) throw new Error('备份加密参数无效');
    }
  }

  private static toNumberArray(value: Uint8Array): number[] {
    const result: number[] = [];
    for (let index = 0; index < value.length; index++) result.push(value[index]);
    return result;
  }

  private static toUint8Array(value: number[]): Uint8Array {
    const result = new Uint8Array(value.length);
    for (let index = 0; index < value.length; index++) {
      const item = value[index];
      if (!Number.isInteger(item) || item < 0 || item > 255) throw new Error('备份加密参数无效');
      result[index] = item;
    }
    return result;
  }

  private static clearBytes(value: Uint8Array): void {
    value.fill(0);
  }

  private static async removeFile(path: string): Promise<void> {
    try {
      if (fs.accessSync(path)) await fs.unlink(path);
    } catch (_) {}
  }
}
