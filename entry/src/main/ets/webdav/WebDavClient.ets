import fs from '@ohos.file.fs';
import http from '@ohos.net.http';
import request from '@ohos.request';
import xml from '@ohos.xml';
import { Context } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import {
  WebDavConnection,
  WebDavConnectionTestResult,
  WebDavDownloadResult,
  WebDavEntry,
  WebDavFileInfo
} from './WebDavModels';
import { WebDavSettingsStore } from './WebDavSettingsStore';
import { WebDavError } from './WebDavError';

class WebDavHttpResponse {
  statusCode: number = 0;
  headers: Record<string, string> = {};
  body: string = '';
}

class WebDavXmlNode {
  name: string = '';
  text: string = '';
  children: WebDavXmlNode[] = [];
}

export class WebDavClient {
  private static readonly MAX_REDIRECTS: number = 5;
  private static readonly DOWNLOAD_ATTEMPTS: number = 2;
  private readonly connection: WebDavConnection;
  private readonly password: string;
  private readonly timeout: number;

  constructor(connection: WebDavConnection, password: string, timeout: number = 30000) {
    this.connection = connection;
    this.password = password || '';
    this.timeout = timeout;
  }

  async testConnection(): Promise<WebDavConnectionTestResult> {
    const result = new WebDavConnectionTestResult();
    try {
      const response = await this.request('PROPFIND', this.urlForCollection(this.connection.libraryRoot), {
        'Depth': '0',
        'Content-Type': 'application/xml; charset=utf-8'
      }, WebDavClient.propfindBody());
      result.statusCode = response.statusCode;
      result.ok = response.statusCode === 207 || (response.statusCode >= 200 && response.statusCode < 300);
      result.message = result.ok ? '连接成功' : this.statusMessage(response.statusCode);
    } catch (error) {
      result.message = this.errorMessage(error as Object);
    }
    return result;
  }

  async list(relativePath: string): Promise<WebDavEntry[]> {
    const normalized = WebDavSettingsStore.normalizeRelativePath(relativePath);
    const target = this.urlForCollection(this.joinPath(this.connection.libraryRoot, normalized));
    const response = await this.request('PROPFIND', target, {
      'Depth': '1',
      'Content-Type': 'application/xml; charset=utf-8'
    }, WebDavClient.propfindBody(), 8 * 1024 * 1024);
    if (response.statusCode !== 207) throw new Error(this.statusMessage(response.statusCode));
    const entries = this.parseMultiStatus(response.body, normalized);
    entries.sort((left: WebDavEntry, right: WebDavEntry): number => {
      if (left.directory !== right.directory) return left.directory ? -1 : 1;
      return left.name.localeCompare(right.name);
    });
    return entries;
  }

  async listAtRoot(rootPath: string): Promise<WebDavEntry[]> {
    const previous = this.connection.libraryRoot;
    this.connection.libraryRoot = WebDavSettingsStore.normalizeRelativePath(rootPath);
    try {
      return await this.list('');
    } finally {
      this.connection.libraryRoot = previous;
    }
  }

  async headLibraryFile(relativePath: string): Promise<WebDavFileInfo> {
    return await this.headUrl(this.urlForPath(this.joinPath(this.connection.libraryRoot, relativePath)));
  }

  async headUrl(url: string): Promise<WebDavFileInfo> {
    const response = await this.request('HEAD', url, {}, undefined, 1024);
    const result = new WebDavFileInfo();
    result.statusCode = response.statusCode;
    result.exists = response.statusCode >= 200 && response.statusCode < 300;
    result.size = Math.max(0, Number(this.header(response.headers, 'content-length')) || 0);
    result.lastModified = this.parseDate(this.header(response.headers, 'last-modified'));
    result.etag = this.header(response.headers, 'etag');
    result.contentType = this.header(response.headers, 'content-type');
    return result;
  }

  async downloadLibraryFile(relativePath: string, targetPath: string,
    onProgress?: (received: number, total: number) => void): Promise<WebDavDownloadResult> {
    return await this.downloadUrl(
      this.urlForPath(this.joinPath(this.connection.libraryRoot, relativePath)), targetPath, onProgress);
  }

  async downloadBackup(relativePath: string, targetPath: string,
    onProgress?: (received: number, total: number) => void): Promise<WebDavDownloadResult> {
    return await this.downloadUrl(
      this.urlForPath(this.joinPath(this.connection.backupRoot, relativePath)), targetPath, onProgress);
  }

  async downloadUrl(url: string, targetPath: string,
    onProgress?: (received: number, total: number) => void): Promise<WebDavDownloadResult> {
    let lastMessage = '下载失败';
    for (let attempt = 0; attempt < WebDavClient.DOWNLOAD_ATTEMPTS; attempt++) {
      try {
        return await this.downloadUrlOnce(url, targetPath, onProgress);
      } catch (error) {
        lastMessage = this.errorMessage(error as Object);
        if (!this.isReceiveFailure(lastMessage) || attempt + 1 >= WebDavClient.DOWNLOAD_ATTEMPTS) {
          throw new Error(lastMessage);
        }
      }
    }
    throw new Error(lastMessage);
  }

  private async downloadUrlOnce(url: string, targetPath: string,
    onProgress?: (received: number, total: number) => void): Promise<WebDavDownloadResult> {
    if (fs.accessSync(targetPath)) fs.unlinkSync(targetPath);
    this.ensureParent(targetPath);
    const target = fs.openSync(targetPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    const client = http.createHttp();
    let received = 0;
    let total = 0;
    let headers: Record<string, string> = {};
    let writeError = '';
    const onHeaders = (value: Object): void => {
      headers = (value || {}) as Record<string, string>;
      total = Math.max(0, Number(this.header(headers, 'content-length')) || 0);
      if (onProgress) onProgress(0, total);
    };
    const onData = (chunk: ArrayBuffer): void => {
      if (writeError) return;
      try {
        const count = fs.writeSync(target.fd, chunk);
        if (count !== chunk.byteLength) throw new Error('写入下载缓存不完整');
        received += count;
        if (onProgress) onProgress(received, total);
      } catch (error) {
        writeError = this.errorMessage(error as Object);
        client.destroy();
      }
    };
    client.on('headersReceive', onHeaders);
    client.on('dataReceive', onData);
    try {
      const status = await client.requestInStream(url, {
        method: http.RequestMethod.GET,
        header: this.headers({}),
        connectTimeout: this.timeout,
        readTimeout: Math.max(this.timeout, 120000),
        usingProtocol: http.HttpProtocol.HTTP1_1,
        maxRedirects: WebDavClient.MAX_REDIRECTS
      });
      if (writeError) throw new Error(writeError);
      if (status < 200 || status >= 300) throw new Error(this.statusMessage(status));
      if (total > 0 && received !== total) throw new Error('下载文件长度不完整');
      const result = new WebDavDownloadResult();
      result.path = targetPath;
      result.size = received;
      result.etag = this.header(headers, 'etag');
      result.lastModified = this.parseDate(this.header(headers, 'last-modified'));
      return result;
    } catch (error) {
      try { fs.unlinkSync(targetPath); } catch (_) {}
      throw new Error(this.errorMessage(error as Object));
    } finally {
      client.off('headersReceive', onHeaders);
      client.off('dataReceive', onData);
      client.destroy();
      fs.closeSync(target);
    }
  }

  async ensureBackupRoot(): Promise<void> {
    await this.ensureCollection(this.connection.backupRoot);
  }

  async ensureCollection(relativePath: string): Promise<void> {
    const parts = WebDavSettingsStore.normalizeRelativePath(relativePath).split('/').filter((value: string): boolean => !!value);
    let current = '';
    for (const part of parts) {
      current = this.joinPath(current, part);
      const response = await this.request('MKCOL', this.urlForPath(current), {}, undefined, 1024);
      if (response.statusCode === 201 || response.statusCode === 200 || response.statusCode === 204 ||
        response.statusCode === 405) continue;
      throw new Error(`创建远端目录失败：${this.statusMessage(response.statusCode)}`);
    }
  }

  async createLibraryFolder(parentPath: string, name: string): Promise<void> {
    const relativePath = this.joinPath(parentPath, name);
    const response = await this.request('MKCOL', this.urlForPath(
      this.joinPath(this.connection.libraryRoot, relativePath)), {}, undefined, 1024);
    if (response.statusCode === 201 || response.statusCode === 200 || response.statusCode === 204) return;
    if (response.statusCode === 405) throw new Error('同名文件夹已存在');
    throw new Error(`创建文件夹失败：${this.statusMessage(response.statusCode)}`);
  }

  async uploadLibraryFile(context: Context, sourcePath: string, parentPath: string, remoteName: string,
    onProgress?: (sent: number, total: number) => void): Promise<void> {
    const finalPath = this.joinPath(parentPath, remoteName);
    const finalUrl = this.urlForPath(this.joinPath(this.connection.libraryRoot, finalPath));
    const existing = await this.headUrl(finalUrl);
    if (existing.exists) throw new Error('同名文件已存在');
    let uploadedSize = 0;
    try {
      uploadedSize = await this.streamUploadFile(context, sourcePath, finalUrl, remoteName, onProgress);
    } catch (error) {
      await this.deleteUrl(finalUrl).catch((): void => {});
      throw new Error(this.errorMessage(error as Object));
    }
    const uploaded = await this.headUrl(finalUrl);
    if (!uploaded.exists || uploaded.size !== uploadedSize) {
      await this.deleteUrl(finalUrl).catch((): void => {});
      throw new Error('远端文件长度校验失败');
    }
  }

  async renameLibraryEntry(relativePath: string, newName: string, directory: boolean): Promise<void> {
    const normalized = WebDavSettingsStore.normalizeRelativePath(relativePath);
    const index = normalized.lastIndexOf('/');
    const parent = index >= 0 ? normalized.substring(0, index) : '';
    const destinationPath = this.joinPath(parent, newName);
    const sourceRelative = this.joinPath(this.connection.libraryRoot, normalized);
    const destinationRelative = this.joinPath(this.connection.libraryRoot, destinationPath);
    const sourceUrl = directory ? this.urlForCollection(sourceRelative) : this.urlForPath(sourceRelative);
    const destinationUrl = directory ? this.urlForCollection(destinationRelative) : this.urlForPath(destinationRelative);
    const response = await this.request('MOVE', sourceUrl, {
      'Destination': this.destinationHeader(destinationUrl),
      'Overwrite': 'F'
    }, undefined, 1024);
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    if (response.statusCode === 412) throw new Error('同名文件或文件夹已存在');
    throw new Error(`重命名失败：${this.statusMessage(response.statusCode)}`);
  }

  async deleteLibraryEntry(relativePath: string, directory: boolean): Promise<void> {
    const target = this.joinPath(this.connection.libraryRoot, relativePath);
    await this.deleteUrl(directory ? this.urlForCollection(target) : this.urlForPath(target));
  }

  async listBackups(): Promise<WebDavEntry[]> {
    const root = this.connection.backupRoot;
    const response = await this.request('PROPFIND', this.urlForCollection(root), {
      'Depth': '1',
      'Content-Type': 'application/xml; charset=utf-8'
    }, WebDavClient.propfindBody(), 4 * 1024 * 1024);
    if (response.statusCode === 404) return [];
    if (response.statusCode !== 207) throw new Error(this.statusMessage(response.statusCode));
    return this.parseMultiStatus(response.body, '')
      .filter((item: WebDavEntry): boolean => !item.directory && item.name.toLowerCase().endsWith('.qingyebak'))
      .sort((left: WebDavEntry, right: WebDavEntry): number => right.lastModified - left.lastModified);
  }

  async uploadBackup(context: Context, sourcePath: string, remoteName: string,
    onProgress?: (sent: number, total: number) => void): Promise<void> {
    await this.ensureBackupRoot();
    const finalUrl = this.urlForPath(this.joinPath(this.connection.backupRoot, remoteName));
    const existing = await this.headUrl(finalUrl);
    if (existing.exists) throw new Error('同名备份已存在');
    let uploadedSize = 0;
    try {
      uploadedSize = await this.streamUploadFile(context, sourcePath, finalUrl, remoteName, onProgress);
    } catch (error) {
      await this.deleteUrl(finalUrl).catch((): void => {});
      throw new Error(this.errorMessage(error as Object));
    }
    const uploaded = await this.headUrl(finalUrl);
    if (!uploaded.exists || uploaded.size !== uploadedSize) {
      await this.deleteUrl(finalUrl).catch((): void => {});
      throw new Error('远端备份长度校验失败');
    }
  }

  async deleteBackup(relativePath: string): Promise<void> {
    await this.deleteUrl(this.urlForPath(this.joinPath(this.connection.backupRoot, relativePath)));
  }

  private async deleteUrl(url: string): Promise<void> {
    const response = await this.request('DELETE', url, {}, undefined, 1024);
    if (response.statusCode === 404 || (response.statusCode >= 200 && response.statusCode < 300)) return;
    throw new Error(this.statusMessage(response.statusCode));
  }

  private async request(method: string, url: string, extraHeaders: Record<string, string>,
    body?: string | ArrayBuffer, maxBytes: number = 4 * 1024 * 1024, timeout: number = 0): Promise<WebDavHttpResponse> {
    const client = http.createHttp();
    try {
      const response = await client.request(url, {
        method: method as http.RequestMethod,
        header: this.headers(extraHeaders),
        extraData: body,
        connectTimeout: timeout || this.timeout,
        readTimeout: timeout || this.timeout,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        maxLimit: maxBytes,
        usingProtocol: http.HttpProtocol.HTTP1_1,
        maxRedirects: WebDavClient.MAX_REDIRECTS
      });
      const result = new WebDavHttpResponse();
      result.statusCode = response.responseCode;
      result.headers = (response.header || {}) as Record<string, string>;
      if (response.result instanceof ArrayBuffer) {
        result.body = util.TextDecoder.create('utf-8')
          .decodeWithStream(new Uint8Array(response.result as ArrayBuffer), { stream: false });
      } else {
        result.body = String(response.result || '');
      }
      return result;
    } catch (error) {
      throw new Error(this.errorMessage(error as Object));
    } finally {
      client.destroy();
    }
  }

  private headers(extra: Record<string, string>): Record<string, string> {
    const authorization = new util.Base64Helper().encodeToStringSync(
      new util.TextEncoder().encodeInto(`${this.connection.username}:${this.password}`));
    const result: Record<string, string> = {};
    result['Authorization'] = `Basic ${authorization}`;
    result['Accept'] = '*/*';
    result['User-Agent'] = 'LegadoHarmony-WebDAV/1.0';
    for (const key of Object.keys(extra)) result[key] = extra[key];
    return result;
  }

  private parseMultiStatus(raw: string, currentRelativePath: string): WebDavEntry[] {
    const document = WebDavClient.parseXml(raw);
    const responses = WebDavClient.findNodes(document, 'response');
    const result: WebDavEntry[] = [];
    let skippedSelf = false;
    for (const response of responses) {
      const href = WebDavClient.nodeText(WebDavClient.findFirstNode(response, 'href')).trim();
      const resourceType = WebDavClient.findFirstNode(response, 'resourcetype');
      const directory = !!resourceType && !!WebDavClient.findFirstNode(resourceType, 'collection');
      const displayName = WebDavClient.nodeText(WebDavClient.findFirstNode(response, 'displayname')).trim();
      const name = displayName || this.nameFromHref(href, directory);
      if (!skippedSelf) {
        skippedSelf = true;
        continue;
      }
      if (!name || name === '.' || name === '..') continue;
      const item = new WebDavEntry();
      item.name = name;
      item.relativePath = this.joinPath(currentRelativePath, name);
      item.href = href;
      item.directory = directory;
      item.size = Math.max(0, Number(WebDavClient.nodeText(
        WebDavClient.findFirstNode(response, 'getcontentlength'))) || 0);
      item.lastModified = this.parseDate(WebDavClient.nodeText(
        WebDavClient.findFirstNode(response, 'getlastmodified')));
      item.etag = WebDavClient.nodeText(WebDavClient.findFirstNode(response, 'getetag')).trim();
      item.contentType = WebDavClient.nodeText(WebDavClient.findFirstNode(response, 'getcontenttype')).trim();
      result.push(item);
    }
    return result;
  }

  private urlForPath(relativePath: string): string {
    const base = WebDavSettingsStore.normalizeBaseUrl(this.connection.baseUrl);
    if (!/^https:\/\//i.test(base) && !/^http:\/\//i.test(base)) throw new Error('WebDAV 地址无效');
    const normalized = WebDavSettingsStore.normalizeRelativePath(relativePath);
    if (!normalized) return base;
    const encoded = normalized.split('/').map((value: string): string => encodeURIComponent(value)).join('/');
    return `${base}${encoded}${relativePath.endsWith('/') ? '/' : ''}`;
  }

  private urlForCollection(relativePath: string): string {
    const url = this.urlForPath(relativePath);
    return url.endsWith('/') ? url : `${url}/`;
  }

  private destinationHeader(url: string): string {
    const scheme = url.indexOf('://');
    if (scheme < 0) return url.startsWith('/') ? url : `/${url}`;
    const path = url.indexOf('/', scheme + 3);
    return path >= 0 ? url.substring(path) : '/';
  }

  private joinPath(left: string, right: string): string {
    return WebDavSettingsStore.normalizeRelativePath(`${left || ''}/${right || ''}`);
  }

  private nameFromHref(href: string, directory: boolean): string {
    let value = (href || '').split('?')[0].split('#')[0].replace(/\/+$/, '');
    const index = value.lastIndexOf('/');
    value = index >= 0 ? value.substring(index + 1) : value;
    try { value = decodeURIComponent(value); } catch (_) {}
    return value || (directory ? '/' : '');
  }

  private header(headers: Record<string, string>, name: string): string {
    const target = name.toLowerCase();
    for (const key of Object.keys(headers)) {
      if (key.toLowerCase() === target) return String(headers[key] || '');
    }
    return '';
  }

  private parseDate(value: string): number {
    const result = Date.parse((value || '').trim());
    return Number.isFinite(result) ? result : 0;
  }

  private statusMessage(status: number): string {
    if (status === 0) return '网络连接失败';
    if (status === 401) return '认证失败，请检查用户名和密码';
    if (status === 403) return '服务器拒绝访问';
    if (status === 404) return '远端路径不存在';
    if (status === 405) return '服务器不支持该 WebDAV 操作';
    if (status === 409) return '远端父目录不存在';
    if (status === 412) return '远端文件状态已变化';
    if (status === 423) return '远端文件已被锁定';
    if (status === 507) return 'WebDAV 空间不足';
    return `WebDAV HTTP ${status}`;
  }

  private errorMessage(error: Object): string {
    const message = WebDavError.message(error, '未知网络错误');
    if (message.includes('2300047')) return '服务器重定向次数过多（错误码 2300047）';
    if (message.includes('2300056')) return '接收文件时连接被服务器中断（错误码 2300056）';
    return message;
  }

  private isReceiveFailure(message: string): boolean {
    const value = (message || '').toLowerCase();
    return value.includes('2300056') || value.includes('failed to receive data') ||
      value.includes('failure when receiving data');
  }

  private ensureParent(path: string): void {
    const normalized = path.replace(/\\/g, '/');
    const index = normalized.lastIndexOf('/');
    if (index <= 0) return;
    const parent = normalized.substring(0, index);
    if (!fs.accessSync(parent)) fs.mkdirSync(parent, true);
  }

  private async streamUploadFile(context: Context, sourcePath: string, targetUrl: string, remoteName: string,
    onProgress?: (sent: number, total: number) => void): Promise<number> {
    const stat = await fs.stat(sourcePath);
    const total = Math.max(0, stat.size);
    if (onProgress) onProgress(0, total);
    let uploadPath = sourcePath;
    let cachePath = '';
    if (sourcePath.toLowerCase().startsWith('file://')) {
      this.cleanupUploadCaches(context.filesDir);
      cachePath = `${context.filesDir}/.webdav_upload_${Date.now()}_${Math.floor(Math.random() * 100000)}.cache`;
      try {
        await this.copyFileInChunks(sourcePath, cachePath, total, (copied: number): void => {
          if (onProgress) onProgress(copied, total * 2);
        });
      } catch (error) {
        try { fs.unlinkSync(cachePath); } catch (_) {}
        throw new Error(this.errorMessage(error as Object));
      }
      uploadPath = cachePath;
    }
    const file: request.agent.FileSpec = {
      path: uploadPath,
      filename: remoteName,
      mimeType: 'application/octet-stream'
    };
    const config: request.agent.Config = {
      action: request.agent.Action.UPLOAD,
      mode: request.agent.Mode.FOREGROUND,
      method: 'PUT',
      url: targetUrl,
      headers: this.headers({ 'Content-Type': 'application/octet-stream' }),
      data: [{ name: 'file', value: file }],
      title: `上传 ${remoteName}`,
      network: request.agent.Network.ANY,
      metered: true,
      roaming: true,
      retry: false,
      redirect: false,
      precise: true,
      multipart: false
    };
    try {
      const task = await request.agent.create(context, config);
      return await new Promise<number>((resolve: (value: number) => void, reject: (reason?: Object) => void): void => {
        let settled = false;
        let responseStatus = 0;
        const onTaskProgress = (progress: request.agent.Progress): void => {
          const reportedTotal = progress.sizes.length > 0 && progress.sizes[0] >= 0 ? progress.sizes[0] : total;
          const completedBeforeUpload = cachePath ? total : 0;
          const operationTotal = cachePath ? total + reportedTotal : reportedTotal;
          if (onProgress) {
            onProgress(completedBeforeUpload + Math.max(0, progress.processed), operationTotal);
          }
        };
        const onResponse = (response: request.agent.HttpResponse): void => {
          responseStatus = response.statusCode;
        };
        const release = (): void => {
          task.off('progress', onTaskProgress);
          task.off('completed', onCompleted);
          task.off('failed', onFailed);
          task.off('response', onResponse);
        };
        const removeThen = (action: () => void): void => {
          request.agent.remove(task.tid).then(action).catch(action);
        };
        const onCompleted = (_progress: request.agent.Progress): void => {
          if (settled) return;
          settled = true;
          release();
          removeThen((): void => {
            if (responseStatus > 0 && (responseStatus < 200 || responseStatus >= 300)) {
              reject(new Error(`上传文件失败：${this.statusMessage(responseStatus)}`));
              return;
            }
            if (onProgress) onProgress(total, total);
            resolve(total);
          });
        };
        const onFailed = (_progress: request.agent.Progress): void => {
          if (settled) return;
          settled = true;
          release();
          removeThen((): void => {
            if (responseStatus > 0) {
              reject(new Error(`上传文件失败：${this.statusMessage(responseStatus)}`));
            } else {
              reject(new Error('流式上传失败，请检查网络连接和服务器配置'));
            }
          });
        };
        task.on('progress', onTaskProgress);
        task.on('completed', onCompleted);
        task.on('failed', onFailed);
        task.on('response', onResponse);
        task.start().catch((error: Object): void => {
          if (settled) return;
          settled = true;
          release();
          removeThen((): void => reject(new Error(this.errorMessage(error))));
        });
      });
    } finally {
      if (cachePath) {
        try { fs.unlinkSync(cachePath); } catch (_) {}
      }
    }
  }

  private async copyFileInChunks(sourcePath: string, targetPath: string, total: number,
    onProgress?: (copied: number) => void): Promise<void> {
    const source = await fs.open(sourcePath, fs.OpenMode.READ_ONLY);
    let target: fs.File | null = null;
    let copied = 0;
    try {
      target = await fs.open(targetPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      const buffer = new ArrayBuffer(Math.max(1, Math.min(1024 * 1024, total)));
      while (copied < total) {
        const count = await fs.read(source.fd, buffer, { length: Math.min(buffer.byteLength, total - copied) });
        if (count <= 0) break;
        const written = fs.writeSync(target.fd, buffer, { length: count });
        if (written !== count) throw new Error('写入上传缓存不完整');
        copied += count;
        if (onProgress) onProgress(copied);
      }
    } finally {
      await fs.close(source);
      if (target) await fs.close(target);
    }
    if (copied !== total) {
      try { fs.unlinkSync(targetPath); } catch (_) {}
      throw new Error('复制待上传文件不完整');
    }
  }

  private cleanupUploadCaches(directory: string): void {
    try {
      const names = fs.listFileSync(directory);
      for (const name of names) {
        if (!name.startsWith('.webdav_upload_') || !name.endsWith('.cache')) continue;
        try { fs.unlinkSync(`${directory}/${name}`); } catch (_) {}
      }
    } catch (_) {}
  }

  private static propfindBody(): string {
    return '<?xml version="1.0" encoding="utf-8"?>' +
      '<d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/>' +
      '<d:getcontentlength/><d:getlastmodified/><d:getetag/><d:getcontenttype/>' +
      '</d:prop></d:propfind>';
  }

  private static parseXml(text: string): WebDavXmlNode {
    const root = new WebDavXmlNode();
    root.name = '#document';
    const stack: WebDavXmlNode[] = [root];
    const encoded = new util.TextEncoder().encodeInto(text || '');
    const bytes = new ArrayBuffer(encoded.length);
    new Uint8Array(bytes).set(encoded);
    const parser = new xml.XmlPullParser(bytes, 'utf-8');
    parser.parse({
      supportDoctype: false,
      ignoreNameSpace: true,
      tokenValueCallbackFunction: (eventType: xml.EventType, info: xml.ParseInfo): boolean => {
        if (eventType === xml.EventType.START_TAG) {
          const node = new WebDavXmlNode();
          node.name = WebDavClient.localName(info.getName());
          stack[stack.length - 1].children.push(node);
          stack.push(node);
        } else if (eventType === xml.EventType.TEXT || eventType === xml.EventType.CDSECT) {
          stack[stack.length - 1].text += info.getText();
        } else if (eventType === xml.EventType.END_TAG && stack.length > 1) {
          stack.pop();
        }
        return true;
      }
    });
    return root;
  }

  private static localName(value: string): string {
    const index = (value || '').indexOf(':');
    return (index >= 0 ? value.substring(index + 1) : value).toLowerCase();
  }

  private static findFirstNode(root: WebDavXmlNode | null, name: string): WebDavXmlNode | null {
    if (!root) return null;
    if (root.name === name) return root;
    for (const child of root.children) {
      const found = WebDavClient.findFirstNode(child, name);
      if (found) return found;
    }
    return null;
  }

  private static findNodes(root: WebDavXmlNode, name: string): WebDavXmlNode[] {
    const result: WebDavXmlNode[] = [];
    WebDavClient.appendNodes(root, name, result);
    return result;
  }

  private static appendNodes(root: WebDavXmlNode, name: string, target: WebDavXmlNode[]): void {
    if (root.name === name) target.push(root);
    for (const child of root.children) WebDavClient.appendNodes(child, name, target);
  }

  private static nodeText(node: WebDavXmlNode | null): string {
    if (!node) return '';
    let result = node.text || '';
    for (const child of node.children) result += WebDavClient.nodeText(child);
    return result;
  }
}
