import http from '@ohos.net.http';
import fs from '@ohos.file.fs';
import { util } from '@kit.ArkTS';
import { HttpClient, HttpRequest } from '../core/http/HttpClient';
import { CookieStore } from '../core/http/CookieStore';
import { TlsTrustStore } from '../core/http/TlsTrustStore';
import {
  OpdsEntry,
  OpdsFeed,
  OpdsSearchTemplate,
  OpdsServerConfig
} from './OpdsModels';
import { OpdsXmlParser } from './OpdsXmlParser';
import { OpdsError } from './OpdsError';

export interface OpdsDownloadHandle {
  promise: Promise<void>;
  cancel(): void;
}

export class OpdsClient {
  private static readonly MAX_REDIRECTS: number = 5;
  private static readonly MAX_FEED_BYTES: number = 10 * 1024 * 1024;
  private readonly server: OpdsServerConfig;
  private readonly password: string;
  private readonly timeout: number;
  private readonly httpClient: HttpClient;

  constructor(server: OpdsServerConfig, password: string) {
    this.server = server;
    this.password = password || '';
    this.timeout = 30000;
    this.httpClient = new HttpClient(this.timeout);
  }

  async fetchFeed(url: string): Promise<OpdsFeed> {
    const body = await this.fetchText(url);
    try {
      return OpdsXmlParser.parseFeed(body, url);
    } catch (error) {
      throw new OpdsError('not-opds', `OPDS 目录解析失败：${OpdsError.message(error as Object)}`);
    }
  }

  async fetchEntry(url: string): Promise<OpdsEntry> {
    const body = await this.fetchText(url);
    try {
      return OpdsXmlParser.parseEntry(body, url);
    } catch (error) {
      throw new OpdsError('not-opds', `OPDS 条目解析失败：${OpdsError.message(error as Object)}`);
    }
  }

  async search(template: OpdsSearchTemplate, query: string): Promise<OpdsFeed> {
    const url = OpdsClient.searchUrlFromTemplate(template, query);
    console.info('[OPDS] 搜索请求:', this.hostForLog(url));
    return await this.fetchFeed(url);
  }

  static searchUrlFromTemplate(template: OpdsSearchTemplate, query: string): string {
    const encoded = encodeURIComponent(query);
    const indexOffset = Math.floor(template.indexOffset || 1);
    const pageOffset = Math.floor(template.pageOffset || 1);
    let url = OpdsClient.replaceOpenSearchPlaceholder(
      (template.urlTemplate || '').split('{searchTerms}').join(encoded),
      'startIndex', `${indexOffset}`);
    url = OpdsClient.replaceOpenSearchPlaceholder(url, 'page', `${pageOffset}`);
    url = OpdsClient.replaceOpenSearchPlaceholder(url, 'count', '');
    url = OpdsClient.replaceOpenSearchPlaceholder(url, 'searchRel', '');
    return url;
  }

  async resolveSearchTemplate(feedUrl: string, feed: OpdsFeed): Promise<OpdsSearchTemplate | null> {
    const link = feed.searchLink();
    if (!link || !link.href) return null;
    try {
      const descriptionUrl = this.resolveUrl(feedUrl, link.href);
      const body = await this.fetchXml(descriptionUrl);
      const template = OpdsXmlParser.parseSearchTemplate(body);
      if (!template || !template.urlTemplate) return null;
      template.urlTemplate = this.resolveUrl(descriptionUrl, template.urlTemplate);
      return template;
    } catch (_) {
      return null;
    }
  }

  downloadBook(url: string, destPath: string,
    onProgress?: (received: number, total: number) => void): OpdsDownloadHandle {
    if (fs.accessSync(destPath)) fs.unlinkSync(destPath);
    this.ensureParent(destPath);
    const target = fs.openSync(destPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    const client = http.createHttp();
    let received = 0;
    let total = 0;
    let writeError = '';
    let cancelled = false;
    let rejectRef: (error: OpdsError) => void = (error: OpdsError): void => {};
    let onHeaders: (value: Object) => void = (value: Object): void => {};
    let onData: (chunk: ArrayBuffer) => void = (chunk: ArrayBuffer): void => {};
    const cleanup = (keepFile: boolean): void => {
      try { client.off('headersReceive', onHeaders); } catch (_) {}
      try { client.off('dataReceive', onData); } catch (_) {}
      try { client.destroy(); } catch (_) {}
      try { fs.closeSync(target); } catch (_) {}
      if (!keepFile) {
        try { fs.unlinkSync(destPath); } catch (_) {}
      }
    };
    const promise = new Promise<void>((resolve, reject): void => {
      rejectRef = reject;
      onHeaders = (value: Object): void => {
        const headers = (value || {}) as Record<string, string>;
        total = Math.max(0, Number(this.headerValue(headers, 'content-length')) || 0);
        if (onProgress) onProgress(0, total);
      };
      onData = (chunk: ArrayBuffer): void => {
        if (writeError) return;
        try {
          const count = fs.writeSync(target.fd, chunk);
          if (count !== chunk.byteLength) throw new Error('写入下载缓存不完整');
          received += count;
          if (onProgress) onProgress(received, total);
        } catch (error) {
          writeError = OpdsError.message(error as Object, '写入下载缓存失败');
          try { client.destroy(); } catch (_) {}
        }
      };
      client.on('headersReceive', onHeaders);
      client.on('dataReceive', onData);
      let options: http.HttpRequestOptions;
      try {
        options = this.buildDownloadOptions(url);
      } catch (error) {
        cleanup(false);
        reject(this.toDownloadError(url, error as Object));
        return;
      }
      client.requestInStream(url, options).then((code: number): void => {
        if (cancelled) {
          cleanup(false);
          return;
        }
        if (writeError) {
          cleanup(false);
          reject(new OpdsError('unknown', writeError));
          return;
        }
        if (code < 200 || code >= 300) {
          cleanup(false);
          reject(new OpdsError('network', `书库下载失败（HTTP ${code}）`));
          return;
        }
        if (total > 0 && received !== total) {
          cleanup(false);
          reject(new OpdsError('network', '下载文件长度不完整'));
          return;
        }
        cleanup(true);
        resolve();
      }).catch((error: Object): void => {
        cleanup(false);
        if (cancelled) return;
        reject(this.toDownloadError(url, error));
      });
    });
    const handle: OpdsDownloadHandle = {
      promise: promise,
      cancel: (): void => {
        if (cancelled) return;
        cancelled = true;
        try { client.destroy(); } catch (_) {}
        rejectRef(new OpdsError('cancelled', '已取消'));
      }
    };
    return handle;
  }

  private async fetchText(url: string): Promise<string> {
    const body = await this.fetchXml(url);
    const head = body.substring(0, 4096);
    if (head.indexOf('<feed') < 0 && head.indexOf('<entry') < 0) {
      throw new OpdsError('not-opds', '该地址不是有效的 OPDS 目录');
    }
    return body;
  }

  private async fetchXml(url: string): Promise<string> {
    const request: HttpRequest = {
      url: url,
      method: 'GET',
      headers: {
        'Accept': 'application/atom+xml;profile=opds-catalog;q=0.9, application/atom+xml;q=0.8'
      },
      maxResponseBytes: OpdsClient.MAX_FEED_BYTES
    };
    const authorization = this.authorizationHeader();
    if (authorization) request.headers['Authorization'] = authorization;
    const response = await this.httpClient.execute(request);
    if (response.statusCode === 401 || response.statusCode === 403) {
      throw new OpdsError('auth', '用户名或密码错误');
    }
    if (response.statusCode === 404) {
      throw new OpdsError('not-found', '书库地址不存在（404）');
    }
    if (!response.success) {
      const detail = response.error || '';
      if (response.statusCode === 0) {
        if (detail.indexOf('证书校验失败') >= 0) {
          throw new OpdsError('certificate', detail);
        }
        throw new OpdsError('network', detail || '网络连接失败');
      }
      throw new OpdsError('network', `书库请求失败（HTTP ${response.statusCode}）`);
    }
    return response.body || '';
  }

  private authorizationHeader(): string {
    if (!this.server.username) return '';
    const authorization = new util.Base64Helper().encodeToStringSync(
      new util.TextEncoder().encodeInto(`${this.server.username}:${this.password}`));
    return `Basic ${authorization}`;
  }

  private buildDownloadOptions(url: string): http.HttpRequestOptions {
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: this.downloadHeaders(url),
      connectTimeout: this.timeout,
      readTimeout: Math.max(this.timeout, 120000),
      maxRedirects: OpdsClient.MAX_REDIRECTS
    };
    this.applyTlsTrust(options, url);
    return options;
  }

  private downloadHeaders(url: string): Record<string, string> {
    const headers: Record<string, string> = {
      'Accept': '*/*',
      'User-Agent': 'LegadoHarmony-OPDS/1.0'
    };
    const authorization = this.authorizationHeader();
    if (authorization) headers['Authorization'] = authorization;
    const cookie = CookieStore.getCookie(url);
    if (cookie) headers['Cookie'] = cookie;
    return headers;
  }

  private toDownloadError(url: string, error: Object): OpdsError {
    const message = OpdsError.message(error, '未知网络错误');
    if (TlsTrustStore.isCertificateError(message)) {
      return new OpdsError('certificate', this.decorateTlsError(url, message));
    }
    return new OpdsError('network', message);
  }

  private decorateTlsError(url: string, error: string): string {
    if (!TlsTrustStore.isCertificateError(error) || /证书主机\s*[：:]/.test(error || '')) return error;
    const host = TlsTrustStore.hostFromUrl(url);
    return host ? `证书校验失败（证书主机：${host}）：${error}` : error;
  }

  private applyTlsTrust(options: http.HttpRequestOptions, url: string): void {
    if (TlsTrustStore.isTrustedUrl(url)) {
      options.remoteValidation = 'skip';
    }
  }

  private resolveUrl(base: string, href: string): string {
    const value = (href || '').trim();
    if (!value) return base || '';
    if (/^https?:\/\//i.test(value)) return value;
    const match = (base || '').match(/^(https?:\/\/[^/?#]+)/i);
    if (!match) return value;
    const origin = match[1];
    if (value.startsWith('/')) return `${origin}${value}`;
    const basePath = base.substring(origin.length).split('?')[0].split('#')[0];
    const directory = basePath.endsWith('/') ?
      basePath : basePath.substring(0, basePath.lastIndexOf('/') + 1);
    return `${origin}${directory}${value}`;
  }

  private static replaceOpenSearchPlaceholder(url: string, name: string, value: string): string {
    return url.split(`{${name}}`).join(value);
  }

  private headerValue(headers: Record<string, string>, name: string): string {
    const target = name.toLowerCase();
    for (const key of Object.keys(headers)) {
      if (key.toLowerCase() === target) return String(headers[key] || '');
    }
    return '';
  }

  private ensureParent(path: string): void {
    const normalized = path.replace(/\\/g, '/');
    const index = normalized.lastIndexOf('/');
    if (index <= 0) return;
    const parent = normalized.substring(0, index);
    if (!fs.accessSync(parent)) fs.mkdirSync(parent, true);
  }

  private hostForLog(url: string): string {
    const match = (url || '').match(/^https?:\/\/([^/:?#]+)/i);
    return match && match[1] ? match[1] : '(unknown host)';
  }
}
