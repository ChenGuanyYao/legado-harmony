import { util } from '@kit.ArkTS';
import http from '@ohos.net.http';
import fs from '@ohos.file.fs';
import { AccountCommerceConfig } from './AccountCommerceConfig';
import { AccountApiError } from './AccountCommerceModels';
import { AccountSessionStore } from './AccountSessionStore';
import { HttpTtsAudio } from '../utils/HttpTtsReader';

class CloudTtsErrorBody {
  code: string = '';
  message: string = '';
}

export class CloudTtsTiming {
  startTime: number = 0;
  endTime: number = 0;
  text: string = '';
  wordIndex: number = 0;
  startOffset: number = 0;
  endOffset: number = 0;
}

export class CloudTtsAudio extends HttpTtsAudio {
  timingMode: string = 'SILENCE_ALIGNED';
  timings: CloudTtsTiming[] = [];
}

class CloudTtsTimedResponse {
  version: number = 0;
  audioBase64: string = '';
  sampleRate: number = 16000;
  timingMode: string = 'SILENCE_ALIGNED';
  timings: CloudTtsTiming[] = [];
}

export class CloudTtsClient {
  private static readonly CACHE_DIR_NAME: string = 'sis_tts';
  private static readonly MAX_CACHE_FILES: number = 120;
  private generation: number = 0;
  private clients: http.HttpRequest[] = [];

  async synthesize(voiceId: string, text: string, speed: number): Promise<CloudTtsAudio> {
    if (!AccountSessionStore.isLoggedIn()) {
      throw new AccountApiError('请先登录华为账号后使用在线音色', 401, 'UNAUTHORIZED');
    }
    if (!AccountCommerceConfig.isServerConfigured()) {
      throw new AccountApiError('在线朗读服务端尚未配置', 0, 'SERVER_NOT_CONFIGURED');
    }
    const generation = this.generation;
    const normalizedSpeed = Math.max(0.5, Math.min(2, speed || 1));
    const cachePath = this.cachePath(voiceId, text, normalizedSpeed);
    if (cachePath && this.fileExists(cachePath)) {
      try {
        return this.audioFromFile(cachePath);
      } catch (error) {
        console.warn('[TTS] discard invalid timed cloud cache:', error);
        try {
          fs.unlinkSync(cachePath);
        } catch (_) {
        }
      }
    }

    const requestId = util.generateRandomUUID();
    let lastError: Error = new Error('在线语音合成失败');
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const responseBuffer = await this.requestAudio(requestId, voiceId, text, normalizedSpeed);
        if (generation !== this.generation) {
          throw new Error('在线语音合成已停止');
        }
        if (!cachePath) {
          throw new Error('应用缓存目录不可用');
        }
        this.writeCacheFile(cachePath, responseBuffer);
        this.pruneCache();
        return this.audioFromBuffer(responseBuffer);
      } catch (error) {
        lastError = error as Error;
        const apiError = error as AccountApiError;
        const retryable = apiError.errorCode === 'TTS_REQUEST_IN_PROGRESS' ||
          apiError.statusCode === 0 || apiError.statusCode >= 500;
        if (!retryable || attempt >= 2 || generation !== this.generation) {
          break;
        }
        await this.delay(600 + attempt * 600);
      }
    }
    throw lastError;
  }

  stop(): void {
    this.generation++;
    const clients = this.clients.slice();
    this.clients = [];
    for (const client of clients) {
      try {
        client.destroy();
      } catch (_) {
      }
    }
  }

  private async requestAudio(requestId: string, voiceId: string, text: string,
    speed: number): Promise<ArrayBuffer> {
    const client = http.createHttp();
    this.clients.push(client);
    try {
      const response = await client.request(
        `${AccountCommerceConfig.API_BASE_URL}/v1/tts/synthesize`,
        {
          method: http.RequestMethod.POST,
          header: {
            'Accept': 'application/json',
            'Content-Type': 'application/json;charset=UTF-8',
            'Authorization': `Bearer ${AccountSessionStore.token()}`
          },
          extraData: JSON.stringify({
            requestId: requestId,
            voiceId: voiceId,
            text: text,
            speed: this.toSisSpeed(speed),
            pitch: 0,
            volume: 100,
            timed: true
          }),
          connectTimeout: 10000,
          readTimeout: 60000,
          expectDataType: http.HttpDataType.ARRAY_BUFFER
        }
      );
      const buffer = this.responseBuffer(response.result);
      const statusCode = Number(response.responseCode);
      if (statusCode < 200 || statusCode >= 300) {
        const body = this.parseError(buffer);
        throw new AccountApiError(
          body.message || `在线语音请求失败（${statusCode}）`,
          statusCode,
          body.code
        );
      }
      if (!buffer.byteLength) {
        throw new AccountApiError('在线语音响应为空', 502, 'EMPTY_TTS_AUDIO');
      }
      return buffer;
    } finally {
      this.clients = this.clients.filter((item: http.HttpRequest) => item !== client);
      try {
        client.destroy();
      } catch (_) {
      }
    }
  }

  private cachePath(voiceId: string, text: string, speed: number): string {
    const root = AppStorage.get<string>('appCacheDir') || '';
    if (!root) return '';
    const dir = `${root}/${CloudTtsClient.CACHE_DIR_NAME}`;
    this.ensureDir(dir);
    const userId = AccountSessionStore.account().userId;
    const key = `${userId}\n${voiceId}\n${speed.toFixed(1)}\n${text}`;
    return `${dir}/${this.hashText(key)}.json`;
  }

  private audioFromFile(path: string): CloudTtsAudio {
    const stat = fs.statSync(path);
    const size = Number(stat.size);
    if (!Number.isSafeInteger(size) || size <= 0 || size > 30 * 1024 * 1024) {
      throw new Error('在线语音缓存无效');
    }
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const buffer = new ArrayBuffer(size);
      const readLength = fs.readSync(file.fd, buffer, { offset: 0, length: size });
      if (readLength !== size) {
        throw new Error('读取在线语音缓存失败');
      }
      return this.audioFromBuffer(buffer);
    } finally {
      fs.closeSync(file);
    }
  }

  private audioFromBuffer(buffer: ArrayBuffer): CloudTtsAudio {
    let body: CloudTtsTimedResponse;
    try {
      const value = util.TextDecoder.create('utf-8')
        .decodeWithStream(new Uint8Array(buffer), { stream: false });
      body = JSON.parse(value) as CloudTtsTimedResponse;
    } catch (_) {
      throw new AccountApiError('在线朗读服务端版本过旧，请先更新服务端', 502, 'INVALID_TIMED_TTS_RESPONSE');
    }
    if (
      body.version !== 1
      || !body.audioBase64
      || body.audioBase64.length > 28 * 1024 * 1024
      || !Number.isFinite(body.sampleRate)
      || body.sampleRate < 8000
      || body.sampleRate > 48000
    ) {
      throw new AccountApiError('在线语音响应无效', 502, 'INVALID_TIMED_TTS_RESPONSE');
    }
    let decoded: Uint8Array;
    try {
      decoded = new util.Base64Helper().decodeSync(body.audioBase64);
    } catch (_) {
      throw new AccountApiError('在线语音音频无效', 502, 'INVALID_TIMED_TTS_AUDIO');
    }
    if (decoded.byteLength <= 0 || decoded.byteLength > 20 * 1024 * 1024 ||
      decoded.byteLength % 2 !== 0) {
      throw new AccountApiError('在线语音音频无效', 502, 'INVALID_TIMED_TTS_AUDIO');
    }
    const audio = new CloudTtsAudio();
    audio.pcm = this.copyBytes(decoded);
    audio.sampleRate = Math.round(body.sampleRate);
    audio.contentType = 'audio/pcm';
    audio.speed = 1;
    audio.timingMode = body.timingMode === 'WORD' ? 'WORD' : 'SILENCE_ALIGNED';
    audio.timings = this.validTimings(body.timings, audio);
    return audio;
  }

  private writeCacheFile(path: string, buffer: ArrayBuffer): void {
    const temporaryPath = `${path}.${Date.now()}.part`;
    const file = fs.openSync(temporaryPath,
      fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, buffer);
    } finally {
      fs.closeSync(file);
    }
    try {
      fs.renameSync(temporaryPath, path);
    } catch (error) {
      try {
        fs.unlinkSync(temporaryPath);
      } catch (_) {
      }
      if (!this.fileExists(path)) {
        throw new Error(`保存在线语音缓存失败：${String(error)}`);
      }
    }
  }

  private pruneCache(): void {
    const root = AppStorage.get<string>('appCacheDir') || '';
    const dir = root ? `${root}/${CloudTtsClient.CACHE_DIR_NAME}` : '';
    if (!dir) return;
    try {
      const files = fs.listFileSync(dir).filter((name: string) => name.endsWith('.json'));
      const removeCount = Math.max(0, files.length - CloudTtsClient.MAX_CACHE_FILES);
      for (let index = 0; index < removeCount; index++) {
        try {
          fs.unlinkSync(`${dir}/${files[index]}`);
        } catch (_) {
        }
      }
    } catch (_) {
    }
  }

  private ensureDir(path: string): void {
    try {
      if (!fs.accessSync(path)) fs.mkdirSync(path, true);
    } catch (_) {
      try {
        fs.mkdirSync(path, true);
      } catch (_) {
      }
    }
  }

  private fileExists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (_) {
      return false;
    }
  }

  private toSisSpeed(speed: number): number {
    if (speed <= 1) {
      return Math.round((speed - 1) * 1000);
    }
    return Math.round((speed - 1) * 500);
  }

  private responseBuffer(result: string | Object): ArrayBuffer {
    if (result instanceof ArrayBuffer) return result as ArrayBuffer;
    if (typeof result === 'string') {
      return new util.TextEncoder().encodeInto(result as string).buffer as ArrayBuffer;
    }
    return new ArrayBuffer(0);
  }

  private validTimings(values: CloudTtsTiming[] | undefined, audio: CloudTtsAudio): CloudTtsTiming[] {
    if (!values || !Array.isArray(values)) {
      return [];
    }
    const durationMs = audio.pcm.byteLength * 1000 / (audio.sampleRate * 2);
    const result: CloudTtsTiming[] = [];
    let lastStart = -1;
    for (const value of values) {
      const startTime = Math.round(Number(value.startTime));
      const endTime = Math.round(Number(value.endTime));
      const startOffset = Math.round(Number(value.startOffset));
      const endOffset = Math.round(Number(value.endOffset));
      if (
        !Number.isFinite(startTime)
        || !Number.isFinite(endTime)
        || startTime < lastStart
        || startTime < 0
        || endTime < startTime
        || endTime > durationMs + 1000
        || startOffset < 0
        || endOffset <= startOffset
      ) {
        continue;
      }
      const timing = new CloudTtsTiming();
      timing.startTime = startTime;
      timing.endTime = endTime;
      timing.text = String(value.text || '');
      timing.wordIndex = Math.round(Number(value.wordIndex) || result.length);
      timing.startOffset = startOffset;
      timing.endOffset = endOffset;
      result.push(timing);
      lastStart = startTime;
    }
    return result;
  }

  private copyBytes(bytes: Uint8Array): ArrayBuffer {
    const result = new ArrayBuffer(bytes.byteLength);
    new Uint8Array(result).set(bytes);
    return result;
  }

  private parseError(buffer: ArrayBuffer): CloudTtsErrorBody {
    try {
      const value = util.TextDecoder.create('utf-8')
        .decodeWithStream(new Uint8Array(buffer), { stream: false });
      return JSON.parse(value) as CloudTtsErrorBody;
    } catch (_) {
      return new CloudTtsErrorBody();
    }
  }

  private hashText(input: string): string {
    let first = 2166136261;
    let second = 2246822519;
    for (let index = 0; index < input.length; index++) {
      const code = input.charCodeAt(index);
      first = Math.imul(first ^ code, 16777619);
      second = Math.imul(second ^ code, 3266489917);
    }
    return (first >>> 0).toString(16).padStart(8, '0') +
      (second >>> 0).toString(16).padStart(8, '0');
  }

  private delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
