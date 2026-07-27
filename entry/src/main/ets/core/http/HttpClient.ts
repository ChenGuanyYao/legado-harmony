import http from '@ohos.net.http';
import { util } from '@kit.ArkTS';
import { CookieStore } from './CookieStore';

export interface HttpRequest {
  url: string;
  method: string;
  headers: Record<string, string>;
  body?: string;
  charset?: string;
  connectTimeout?: number;
  readTimeout?: number;
  contentType?: string;
  maxResponseBytes?: number;
}

export interface HttpResponse {
  url: string;
  statusCode: number;
  headers: Record<string, string>;
  body: string;
  success: boolean;
  error?: string;
}

export class HttpClient {
  private timeout: number;
  private defaultHeaders: Record<string, string> = {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': '*/*',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'Connection': 'keep-alive'
  };

  constructor(timeout: number = 8000) {
    this.timeout = timeout;
  }

  async execute(req: HttpRequest): Promise<HttpResponse> {
    if (!req.url || req.url.trim() === '') {
      return { url: '', statusCode: 0, headers: {}, body: '', success: false, error: 'empty url' };
    }
    const client = http.createHttp();
    let responseTooLarge = false;
    try {
      const method = this.resolveMethod(req.method);
      const headers: Record<string, string> = { ...this.defaultHeaders, ...req.headers };
      const cookie = CookieStore.getCookie(req.url);
      if (cookie && !headers['Cookie']) {
        headers['Cookie'] = cookie;
      }
      const maxResponseBytes = req.maxResponseBytes || 0;
      if (maxResponseBytes > 0) {
        const chunks: ArrayBuffer[] = [];
        let receivedBytes = 0;
        let streamedHeaders: Record<string, string> = {};
        const onHeadersReceive = (value: Object): void => {
          streamedHeaders = (value || {}) as Record<string, string>;
          const contentLength = Number(this.findHeader(streamedHeaders, 'content-length') || '0');
          if (contentLength > maxResponseBytes) {
            responseTooLarge = true;
            client.destroy();
          }
        };
        const onDataReceive = (chunk: ArrayBuffer): void => {
          if (responseTooLarge) return;
          receivedBytes += chunk.byteLength;
          if (receivedBytes > maxResponseBytes) {
            responseTooLarge = true;
            chunks.length = 0;
            client.destroy();
            return;
          }
          chunks.push(chunk);
        };
        client.on('headersReceive', onHeadersReceive);
        client.on('dataReceive', onDataReceive);
        let responseCode = 0;
        try {
          responseCode = await client.requestInStream(req.url, {
            method: method,
            header: headers,
            extraData: req.body,
            connectTimeout: req.connectTimeout || this.timeout,
            readTimeout: req.readTimeout || this.timeout
          });
        } finally {
          client.off('headersReceive', onHeadersReceive);
          client.off('dataReceive', onDataReceive);
        }
        if (responseTooLarge) {
          return {
            url: req.url,
            statusCode: responseCode,
            headers: streamedHeaders,
            body: '',
            success: false,
            error: `response too large: >${maxResponseBytes}`
          };
        }
        const result = this.mergeArrayBuffers(chunks, receivedBytes);
        return this.buildResponse(req, responseCode, streamedHeaders, result);
      }

      const resp = await client.request(req.url, {
        method: method,
        header: headers,
        extraData: req.body,
        connectTimeout: req.connectTimeout || this.timeout,
        readTimeout: req.readTimeout || this.timeout,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });

      const responseHeaders = (resp.header || {}) as Record<string, string>;
      return this.buildResponse(req, resp.responseCode, responseHeaders, resp.result);
    } catch (e) {
      return {
        url: req.url,
        statusCode: 0,
        headers: {},
        body: '',
        success: false,
        error: responseTooLarge ? `response too large: >${req.maxResponseBytes}` :
          (e instanceof Error ? e.message : String(e))
      };
    } finally {
      client.destroy();
    }
  }

  private resolveMethod(method: string): http.RequestMethod {
    switch (method.toUpperCase()) {
      case 'POST': return http.RequestMethod.POST;
      case 'PUT': return http.RequestMethod.PUT;
      case 'DELETE': return http.RequestMethod.DELETE;
      case 'HEAD': return http.RequestMethod.HEAD;
      default: return http.RequestMethod.GET;
    }
  }

  private findHeader(headers: Record<string, string>, name: string): string {
    const lower = name.toLowerCase();
    for (const key in headers) {
      if (key.toLowerCase() === lower) return String(headers[key] || '');
    }
    return '';
  }

  private buildResponse(req: HttpRequest, responseCode: number, responseHeaders: Record<string, string>,
    result: string | Object): HttpResponse {
    const setCookie = this.findHeader(responseHeaders, 'set-cookie');
    if (setCookie) {
      CookieStore.setCookies(req.url, setCookie);
      CookieStore.saveAsync();
    }
    const charset = req.charset || this.responseCharset(responseHeaders);
    const body = this.decodeBody(result, charset);
    const finalBody = req.charset ? body : this.decodeBodyWithMetaCharset(result, body, charset);
    return {
      url: req.url,
      statusCode: responseCode,
      headers: responseHeaders,
      body: finalBody,
      success: responseCode >= 200 && responseCode < 300
    };
  }

  private mergeArrayBuffers(chunks: ArrayBuffer[], totalBytes: number): ArrayBuffer {
    if (chunks.length === 1) return chunks[0];
    const merged = new Uint8Array(totalBytes);
    let offset = 0;
    for (const chunk of chunks) {
      const bytes = new Uint8Array(chunk);
      merged.set(bytes, offset);
      offset += bytes.byteLength;
    }
    return merged.buffer as ArrayBuffer;
  }

  private responseCharset(headers: Record<string, string>): string {
    const contentType = this.findHeader(headers, 'content-type');
    const match = contentType.match(/charset\s*=\s*["']?([^;\s"']+)/i);
    return match ? match[1].trim().toLowerCase() : 'utf-8';
  }

  private decodeBody(result: string | Object, charset?: string): string {
    if (typeof result === 'string') return result as string;
    if (result instanceof ArrayBuffer) {
      try {
        return util.TextDecoder.create(this.normalizeCharset(charset || 'utf-8'))
          .decodeWithStream(new Uint8Array(result as ArrayBuffer), { stream: false });
      } catch (_) {
        return String(result || '');
      }
    }
    return String(result || '');
  }

  private decodeBodyWithMetaCharset(result: string | Object, decoded: string, charset: string): string {
    if (!(result instanceof ArrayBuffer)) return decoded;
    const metaCharset = this.findMetaCharset(decoded);
    if (!metaCharset || this.normalizeCharset(metaCharset) === this.normalizeCharset(charset || 'utf-8')) {
      return decoded;
    }
    return this.decodeBody(result, metaCharset);
  }

  private findMetaCharset(html: string): string {
    const head = (html || '').substring(0, 4096);
    const direct = head.match(/<meta[^>]+charset\s*=\s*["']?\s*([A-Za-z0-9_-]+)/i);
    if (direct) return direct[1].trim().toLowerCase();
    const contentType = head.match(/<meta[^>]+http-equiv\s*=\s*["']?content-type["']?[^>]+content\s*=\s*["'][^"']*charset\s*=\s*([^;"'\s>]+)/i);
    return contentType ? contentType[1].trim().toLowerCase() : '';
  }

  private normalizeCharset(charset: string): string {
    const value = charset.toLowerCase().replace(/["']/g, '').trim();
    if (value === 'gb2312' || value === 'gbk') return 'gb18030';
    return value || 'utf-8';
  }
}
