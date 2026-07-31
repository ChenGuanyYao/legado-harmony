import { BookSource } from '../../model/data/Book';
import { JsRuntime } from '../rule/JsRuntime';
import { ScriptEngine, ScriptEngineContext } from '../rule/ScriptEngine';
import { BookUrlResolver } from './BookUrlResolver';

export class BookSourceLoginItem {
  name: string = '';
  type: string = '';
  action: string = '';
  value: string = '';
  placeholder: string = '';
}

export class BookSourceScriptResult {
  handled: boolean = false;
  value: string = '';
  variable: string = '';
  requestedUrl: string = '';
  toastMessage: string = '';
}

/**
 * Executes the deterministic, allow-listed subset of Legado source scripts.
 * All URL-producing entry points use the same context so jsLib functions and
 * source variables behave consistently in search, explore and login flows.
 */
export class BookSourceScriptRunner {
  static evaluateUrl(source: BookSource, rawRule: string, key: string = '', page: string = '1'):
    BookSourceScriptResult {
    const raw = (rawRule || '').trim();
    if (!raw) return new BookSourceScriptResult();
    if (!/^\s*@?js:/i.test(raw) && !/^\s*<js>/i.test(raw)) {
      const result = new BookSourceScriptResult();
      result.handled = true;
      result.variable = source.variable || '';
      result.value = this.resolveUrl(this.applyTemplates(source, raw, key, page), source);
      return result;
    }
    const code = raw.replace(/^\s*@?js:\s*/i, '').replace(/^\s*<js>|<\/js>\s*$/gi, '');
    return this.execute(source, code, key, page);
  }

  static executeAction(source: BookSource, action: string): BookSourceScriptResult {
    const call = (action || '').trim();
    if (!call) return new BookSourceScriptResult();
    const code = `${source.loginUrl || ''}\n${call}`;
    const result = this.execute(source, code, '', '1');
    if (result.variable !== (source.variable || '') && result.toastMessage) {
      const copy = Object.assign(new BookSource(), source);
      copy.variable = result.variable;
      result.toastMessage = `成功设置 ${this.selectedBaseUrl(copy)}`;
    }
    return result;
  }

  static loginItems(source: BookSource): BookSourceLoginItem[] {
    return this.parseLoginItems(source.loginUi || '');
  }

  static parseLoginItems(value: string): BookSourceLoginItem[] {
    const raw = (value || '').trim();
    if (!raw) return [];
    let parsed: Object;
    try {
      parsed = JSON.parse(raw) as Object;
    } catch (_) {
      try {
        parsed = JSON.parse(this.normalizeLoginUiJson(raw)) as Object;
      } catch (_) {
        return [];
      }
    }
    if (!Array.isArray(parsed)) return [];
    const items: BookSourceLoginItem[] = [];
    for (const value of parsed) {
      if (!value || typeof value !== 'object' || Array.isArray(value)) continue;
      const record = value as Record<string, Object>;
      const item = new BookSourceLoginItem();
      item.name = String(record['name'] || '').trim();
      item.type = String(record['type'] || '').trim();
      item.action = String(record['action'] || '').trim();
      item.value = String(record['value'] || '').trim();
      item.placeholder = String(record['placeholder'] || '').trim();
      if (item.name) items.push(item);
    }
    return items;
  }

  static dynamicLoginUiScript(source: BookSource): string {
    const raw = (source.loginUi || '').trim();
    if (/^@?js:/i.test(raw)) return raw.replace(/^@?js:\s*/i, '');
    if (/^<js>/i.test(raw) && /<\/js>\s*$/i.test(raw)) {
      return raw.replace(/^<js>\s*/i, '').replace(/<\/js>\s*$/i, '');
    }
    return '';
  }

  private static normalizeLoginUiJson(raw: string): string {
    return (raw || '')
      .replace(/([{,]\s*)([A-Za-z_$][A-Za-z0-9_$]*)\s*:/g, '$1"$2":')
      .replace(/([{,]\s*)'([^'\\]*(?:\\.[^'\\]*)*)'\s*:/g, '$1"$2":')
      .replace(/:\s*'([^'\\]*(?:\\.[^'\\]*)*)'(\s*[,}])/g, ':"$1"$2')
      .replace(/,\s*([}\]])/g, '$1');
  }

  static selectedBaseUrl(source: BookSource): string {
    const hosts = this.scriptHosts(source.jsLib || '');
    const rawIndex = String(source.variable || '').split(',')[0].trim();
    const index = parseInt(rawIndex, 10);
    if (hosts.length > 0) {
      if (Number.isFinite(index) && index >= 0 && index < hosts.length) return hosts[index].replace(/\/+$/, '');
      return hosts[0].replace(/\/+$/, '');
    }
    return (source.bookSourceUrl || '').replace(/\/+$/, '');
  }

  static loginEntryUrl(source: BookSource): string {
    const action = this.loginItems(source).find((item: BookSourceLoginItem): boolean =>
      !!item.action && /(?:登录|login)/i.test(item.name));
    if (action) {
      const result = this.executeAction(source, action.action);
      if (result.requestedUrl) return result.requestedUrl;
    }
    const browserMatch = (source.loginUrl || '').match(
      /java\.startBrowser(?:Await)?\(\s*([A-Za-z_$][A-Za-z0-9_$]*\s*\+\s*)?(['"])([^'"]*login[^'"]*)\2/i);
    const base = this.selectedBaseUrl(source);
    if (browserMatch && browserMatch[3]) return BookUrlResolver.resolve(browserMatch[3], base);
    return base ? `${base}/login.html` : '';
  }

  private static execute(source: BookSource, code: string, key: string, page: string): BookSourceScriptResult {
    const env = new ScriptEngineContext();
    env.baseUrl = this.selectedBaseUrl(source) || source.bookSourceUrl;
    this.seedContext(env, source, key, page);
    const selectedBase = this.selectedBaseUrl(source);
    const preparedCode = (code || '').replace(/\bURL\(\)/g, JSON.stringify(selectedBase));
    const script = `${source.jsLib || ''}\n${preparedCode}`;
    const evaluated = new ScriptEngine(new JsRuntime()).evalBlock(script, env);
    const result = new BookSourceScriptResult();
    result.handled = evaluated.handled;
    result.variable = env.getSourceVariable();
    result.requestedUrl = this.resolveUrl(env.requestedUrl, source);
    result.toastMessage = env.toastMessage;
    result.value = this.resolveUrl(evaluated.value, source);
    return result;
  }

  private static seedContext(env: ScriptEngineContext, source: BookSource, key: string, page: string): void {
    env.ctx.put('source.bookSourceUrl', source.bookSourceUrl || '');
    env.ctx.put('bookSourceUrl', source.bookSourceUrl || '');
    env.ctx.put('source.bookSourceName', source.bookSourceName || '');
    env.ctx.put('bookSourceName', source.bookSourceName || '');
    env.ctx.put('source.bookSourceGroup', source.bookSourceGroup || '');
    env.ctx.put('bookSourceGroup', source.bookSourceGroup || '');
    env.ctx.put('source.bookSourceComment', source.bookSourceComment || '');
    env.ctx.put('bookSourceComment', source.bookSourceComment || '');
    env.ctx.put('source.jsLib', source.jsLib || '');
    env.ctx.put('jsLib', source.jsLib || '');
    env.ctx.put('source.variable', source.variable || '');
    env.ctx.put('key', key);
    env.ctx.put('searchKey', key);
    env.ctx.put('keyword', key);
    env.ctx.put('page', page || '1');
    env.ctx.put('pageIndex', page || '1');
  }

  private static applyTemplates(source: BookSource, raw: string, key: string, page: string): string {
    const js = new JsRuntime();
    js.setVar('key', encodeURIComponent(key || ''));
    js.setVar('searchKey', encodeURIComponent(key || ''));
    js.setVar('keyword', encodeURIComponent(key || ''));
    js.setVar('page', page || '1');
    js.setVar('pageIndex', page || '1');
    return js.evalTemplate(raw)
      .replace(/\{\{\s*(?:key|searchKey|keyword)\s*\}\}/g, encodeURIComponent(key || ''))
      .replace(/\{\{\s*(?:page|pageIndex)\s*\}\}/g, page || '1')
      .replace(/\{\{\s*source\.bookSourceUrl\s*\}\}/g, source.bookSourceUrl || '')
      .replace(/\{\{\s*source\.bookSourceName\s*\}\}/g, source.bookSourceName || '')
      .replace(/\{\{\s*source\.bookSourceGroup\s*\}\}/g, source.bookSourceGroup || '')
      .replace(/\{\{[^}]+\}\}/g, '');
  }

  private static resolveUrl(value: string, source: BookSource): string {
    const raw = (value || '').trim();
    if (!raw) return '';
    if (!/^(?:https?:|data:|\/\/|\/|\.\.?\/)/i.test(raw)) return raw;
    const optionIndex = raw.search(/,\s*\{[\s\S]*\}\s*$/);
    const url = optionIndex >= 0 ? raw.substring(0, optionIndex).trim() : raw;
    const options = optionIndex >= 0 ? raw.substring(optionIndex) : '';
    const resolved = BookUrlResolver.resolve(url, this.selectedBaseUrl(source) || source.bookSourceUrl);
    return resolved ? `${resolved}${options}` : raw;
  }

  private static scriptHosts(script: string): string[] {
    const hosts: string[] = [];
    const arrayMatch = (script || '').match(
      /(?:var|let|const)?\s*[A-Za-z_$][A-Za-z0-9_$]*\s*=\s*\[([\s\S]*?)\]\s*;/);
    const body = arrayMatch ? arrayMatch[1] : script;
    const regex = /(['"])(https?:\/\/[^'"]+)\1/g;
    let match: RegExpExecArray | null;
    while ((match = regex.exec(body)) !== null) {
      const host = (match[2] || '').replace(/\/+$/, '');
      if (host && !hosts.includes(host)) hosts.push(host);
    }
    return hosts;
  }
}
