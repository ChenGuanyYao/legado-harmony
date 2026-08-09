import { util } from '@kit.ArkTS';
import { HttpClient } from '../http/HttpClient';
import { AnalyzeUrl } from '../rule/AnalyzeUrl';
import { BookSource } from '../../model/data/Book';

export type EncodedJsonValue = string | number | boolean | Object | null;
export type EncodedJsonMap = Record<string, EncodedJsonValue>;

export class EncodedSourcePayload {
  raw: string = '';
  text: string = '';
  type: string = '';
  data: EncodedJsonMap = {};
  options: EncodedJsonMap = {};
}

export class EncodedSourceUrl {
  static isEncodedDataUrl(url: string): boolean {
    const value = url || '';
    return value.startsWith('data:;base64,') ||
      value.startsWith('data:detailsUrl;base64,') ||
      value.startsWith('data:catalogUrl;base64,') ||
      value.startsWith('data:contentUrl;base64,');
  }

  static decode(url: string): EncodedSourcePayload | null {
    if (!EncodedSourceUrl.isEncodedDataUrl(url)) return null;
    const payload = new EncodedSourcePayload();
    payload.raw = url;
    const prefix = EncodedSourceUrl.dataUrlPrefix(url);
    if (!prefix.prefix) return null;
    const rest = url.substring(prefix.prefix.length);
    const split = EncodedSourceUrl.splitPayload(rest);
    const jsonText = EncodedSourceUrl.base64Decode(split[0]);
    payload.text = jsonText;
    if (prefix.type === 'content') {
      payload.data = EncodedSourceUrl.parseQueryData(jsonText);
    } else {
      try {
        payload.data = EncodedSourceUrl.asMap(JSON.parse(jsonText) as Object);
      } catch (_) {
        payload.data = {};
      }
    }
    if (split[1]) {
      try {
        payload.options = EncodedSourceUrl.asMap(JSON.parse(split[1]) as Object);
      } catch (_) {
        payload.options = {};
      }
      payload.type = EncodedSourceUrl.str(payload.options['type']);
    }
    if (prefix.type) {
      payload.type = prefix.type;
    }
    return payload;
  }

  static canHandle(url: string): boolean {
    const payload = EncodedSourceUrl.decode(url);
    if (!payload) return false;
    const requestUrl = EncodedSourceUrl.str(payload.options['url']) ||
      EncodedSourceUrl.str(payload.data['requestUrl']);
    return payload.type === 'request' && /^https?:\/\//i.test(requestUrl);
  }

  static async requestJsonForDataUrl(http: HttpClient, url: string, source: BookSource,
    maxResponseBytes?: number):
    Promise<EncodedJsonMap | null> {
    const payload = EncodedSourceUrl.decode(url);
    if (!payload) return null;
    return await EncodedSourceUrl.requestJsonForPayload(http, payload, source, maxResponseBytes);
  }

  static async requestJsonForPayload(http: HttpClient, payload: EncodedSourcePayload, source: BookSource,
    maxResponseBytes?: number):
    Promise<EncodedJsonMap | null> {
    const req = EncodedSourceUrl.buildRequest(payload);
    if (!req.path) return null;
    const options: Record<string, Object> = { method: req.method };
    if (req.body) options['body'] = req.body;
    if (Object.keys(req.headers).length > 0) options['headers'] = req.headers;
    const response = await new AnalyzeUrl(source, http).fetch(`${req.path},${JSON.stringify(options)}`,
      maxResponseBytes);
    if (!response.success || !response.body) return null;
    try {
      return EncodedSourceUrl.asMap(JSON.parse(response.body) as Object);
    } catch (_) {
      return null;
    }
  }

  static encode(data: EncodedJsonMap, type: string): string {
    const encoded = EncodedSourceUrl.base64Encode(JSON.stringify(data));
    return `data:;base64,${encoded},{"type":"${type}"}`;
  }

  static encodeRaw(text: string, type: string, host: string = ''): string {
    const encoded = EncodedSourceUrl.base64Encode(text || '');
    const options = host ? `{"type":"${type}","host":"${host}"}` : `{"type":"${type}"}`;
    return `data:;base64,${encoded},${options}`;
  }

  static str(value: EncodedJsonValue | undefined): string {
    if (value === undefined || value === null) return '';
    return String(value).trim();
  }

  static asMap(value: Object | undefined | null): EncodedJsonMap {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
    return value as EncodedJsonMap;
  }

  /** Scalar metadata remains source data; callers may expose it to rules without interpreting it. */
  static scalarVariables(url: string): Record<string, string> {
    const result: Record<string, string> = {};
    const payload = EncodedSourceUrl.decode(url || '');
    if (!payload) return result;
    result['encodedPayload'] = payload.text || '';
    for (const record of [payload.data, payload.options]) {
      for (const key in record) {
        const value = record[key];
        if (value === undefined || value === null || typeof value === 'object') continue;
        result[key] = String(value);
      }
    }
    if (payload.type) result['type'] = payload.type;
    return result;
  }

  private static buildRequest(payload: EncodedSourcePayload): {
    path: string, method: string, body: string, headers: Record<string, string>
  } {
    const data = payload.data;
    const requestUrl = EncodedSourceUrl.str(payload.options['url']) || EncodedSourceUrl.str(data['requestUrl']);
    if (payload.type !== 'request' || !/^https?:\/\//i.test(requestUrl)) {
      return { path: '', method: 'GET', body: '', headers: {} };
    }
    const method = (EncodedSourceUrl.str(payload.options['method']) ||
      EncodedSourceUrl.str(data['method']) || 'GET').toUpperCase();
    const body = EncodedSourceUrl.str(payload.options['body']) || EncodedSourceUrl.str(data['body']);
    const headers = EncodedSourceUrl.headerMap(payload.options['headers'] || data['headers']);
    return { path: requestUrl, method: method, body: body, headers: headers };
  }

  private static headerMap(value: EncodedJsonValue | undefined): Record<string, string> {
    let source: Object | null = value && typeof value === 'object' && !Array.isArray(value) ? value : null;
    if (!source && typeof value === 'string') {
      try {
        const parsed = JSON.parse(value) as Object;
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) source = parsed;
      } catch (_) {}
    }
    const result: Record<string, string> = {};
    if (!source) return result;
    const record = source as Record<string, Object>;
    for (const key in record) {
      if (record[key] !== undefined && record[key] !== null && typeof record[key] !== 'object') {
        result[key] = String(record[key]);
      }
    }
    return result;
  }

  private static splitPayload(rest: string): string[] {
    const comma = rest.indexOf(',');
    if (comma < 0) return [rest, ''];
    return [rest.substring(0, comma), rest.substring(comma + 1)];
  }

  private static dataUrlPrefix(url: string): { prefix: string, type: string } {
    if ((url || '').startsWith('data:;base64,')) return { prefix: 'data:;base64,', type: '' };
    if ((url || '').startsWith('data:detailsUrl;base64,')) {
      return { prefix: 'data:detailsUrl;base64,', type: 'details' };
    }
    if ((url || '').startsWith('data:catalogUrl;base64,')) {
      return { prefix: 'data:catalogUrl;base64,', type: 'catalog' };
    }
    if ((url || '').startsWith('data:contentUrl;base64,')) {
      return { prefix: 'data:contentUrl;base64,', type: 'content' };
    }
    return { prefix: '', type: '' };
  }

  private static parseQueryData(text: string): EncodedJsonMap {
    const data: EncodedJsonMap = { url: text || '' };
    const query = (text || '').startsWith('chapter?') ? (text || '').substring('chapter?'.length) : (text || '');
    for (const item of query.split('&')) {
      const pair = item.trim();
      if (!pair) continue;
      const eq = pair.indexOf('=');
      const key = eq >= 0 ? pair.substring(0, eq) : pair;
      const rawValue = eq >= 0 ? pair.substring(eq + 1) : '';
      const decodedKey = EncodedSourceUrl.decodeQueryPart(key);
      if (!decodedKey) continue;
      data[decodedKey] = EncodedSourceUrl.decodeQueryPart(rawValue);
    }
    return data;
  }

  private static decodeQueryPart(value: string): string {
    try {
      return decodeURIComponent((value || '').replace(/\+/g, ' '));
    } catch (_) {
      return value || '';
    }
  }

  private static base64Encode(input: string): string {
    try {
      const e = new util.TextEncoder();
      return new util.Base64Helper().encodeToStringSync(e.encodeInto(input));
    } catch (_) {
      return input;
    }
  }

  private static base64Decode(input: string): string {
    try {
      const data = new util.Base64Helper().decodeSync(input);
      return util.TextDecoder.create('utf-8').decodeWithStream(data, { stream: false });
    } catch (_) {
      return input;
    }
  }
}
