import { BookSource, ExploreRule, SearchBook } from '../../model/data/Book';
import { appDb } from '../../model/data/AppDatabase';
import { HttpClient } from '../http/HttpClient';
import { AnalyzeUrl } from '../rule/AnalyzeUrl';
import { AnalyzeRule } from '../rule/AnalyzeRule';
import { RuleContext } from '../rule/RuleContext';
import { JsRuntime } from '../rule/JsRuntime';
import { ScriptEngine, ScriptEngineContext } from '../rule/ScriptEngine';
import { VerificationSupport } from '../http/VerificationSupport';
import { EncodedSourceUrl } from './EncodedSourceUrl';
import { BookSourceDataUrlSupport } from './BookSourceDataUrlSupport';
import { BookUrlResolver } from './BookUrlResolver';
import { BookSourceScriptRunner } from './BookSourceScriptRunner';
import { BookTypeSupport } from './BookTypeSupport';
import { BookSourceRuntimeRouter, SourceRuntimeStage } from './BookSourceRuntimeRouter';
import { BookSourceStageWebRuntime, StageWebRuntimeRequest } from './BookSourceStageWebRuntime';
import { BookSourceStageRuleSupport } from './BookSourceStageRuleSupport';

export interface ExploreEntry {
  title: string;
  url: string;
  sourceUrl: string;
  sourceName: string;
}

export interface ExploreSourceOption {
  sourceName: string;
  sourceUrl: string;
  sourceGroup: string;
  platforms: string[];
}

interface ExploreUrlItem {
  title?: string;
  url?: string;
}

export class ExploreCoordinator {
  private http: HttpClient = new HttpClient(10000);
  private noticeMessage: string = '';

  getNoticeMessage(): string {
    return this.noticeMessage;
  }

  async getExploreSources(): Promise<ExploreSourceOption[]> {
    const sources = await appDb.getEnabledBookSourcesForExplore();
    const options: ExploreSourceOption[] = [];
    for (const source of sources) {
      if (!source.enabledExplore || !source.exploreUrl) continue;
      options.push({
        sourceName: source.bookSourceName,
        sourceUrl: source.bookSourceUrl,
        sourceGroup: (source.bookSourceGroup || '').trim(),
        platforms: BookSourceDataUrlSupport.sourceUsesGyExplore(source) ?
          await BookSourceDataUrlSupport.getExplorePlatforms(this.http, source) :
          []
      });
    }
    return options;
  }

  async getEntries(platform: string = '番茄', sourceUrl: string = ''): Promise<ExploreEntry[]> {
    this.noticeMessage = '';
    const sources = await appDb.getEnabledBookSourcesForExplore();
    const entries: ExploreEntry[] = [];
    for (const source of sources) {
      if (!source.enabledExplore || !source.exploreUrl) continue;
      if (sourceUrl && source.bookSourceUrl !== sourceUrl) continue;
      if (BookSourceDataUrlSupport.sourceUsesGyExplore(source)) {
        const dataUrlEntries = await BookSourceDataUrlSupport.getExploreEntries(this.http, platform, '小说', '男频', source);
        for (const item of dataUrlEntries) {
          entries.push({
            title: item.title,
            url: item.url,
            sourceUrl: source.bookSourceUrl,
            sourceName: source.bookSourceName
          });
        }
        continue;
      }
      if (!source.variable && this.requiresSourceVariable(source)) {
        const hint = (source.variableComment || '').trim();
        this.noticeMessage = hint ? `请先在书源编辑中填写书源变量：${hint}` :
          '请先在书源编辑中填写书源变量（共享 Token）';
        continue;
      }
      const exploreRule = this.effectiveExploreRule(source);
      if (!exploreRule.bookList || !exploreRule.name || !exploreRule.bookUrl) {
        console.warn('[ExploreCoordinator] skip source without explore rules:', source.bookSourceName);
        continue;
      }
      const parsed = await this.parseExploreUrl(source);
      entries.push(...parsed);
    }
    return entries;
  }

  async explore(entry: ExploreEntry, page: number = 1): Promise<SearchBook[]> {
    const source = await appDb.getBookSource(entry.sourceUrl);
    if (!source) return [];
    try {
      VerificationSupport.clearVerification();
      if (BookSourceDataUrlSupport.sourceUsesGyExplore(source)) {
        return await BookSourceDataUrlSupport.explore(this.http, source, entry.url, page);
      }
      const au = new AnalyzeUrl(source, this.http);
      const reqUrl = await this.buildUrl(source, entry.url, page);
      if (!reqUrl || /^\s*@?js:/i.test(reqUrl) || !/^https?:\/\//i.test(reqUrl)) {
        this.noticeMessage = '发现地址脚本未能生成有效请求地址';
        return [];
      }
      console.info('[ExploreCoordinator] explore:', `${entry.sourceName}/${entry.title}`, reqUrl);
      const resp = EncodedSourceUrl.canHandle(reqUrl) ?
        await this.fetchEncodedDataUrl(reqUrl, source) : await au.fetch(reqUrl);
      console.info('[ExploreCoordinator] response:', resp.statusCode, 'len:', resp.body?.length || 0, 'url:', resp.url);
      if (VerificationSupport.shouldRequestBrowserVerification(source, resp.body, resp.statusCode, entry.url)) {
        const verifyUrl = VerificationSupport.pickVerificationUrl(source, reqUrl, entry.url);
        VerificationSupport.requestVerification(verifyUrl, `${source.bookSourceName} 验证`, source);
        console.warn('[ExploreCoordinator] source needs browser verification:', source.bookSourceName, verifyUrl);
        return [];
      }
      if (!resp.success || !resp.body) {
        console.warn('[ExploreCoordinator] empty response:', resp.statusCode, resp.error || '');
        this.noticeMessage = !resp.success ? (resp.statusCode > 0 ?
          `发现接口请求失败（HTTP ${resp.statusCode}）` : `发现接口请求失败：${resp.error || '网络异常'}`) :
          '发现接口返回空响应';
        return [];
      }

      const baseUrl = BookUrlResolver.effectiveBase(resp, reqUrl, source.bookSourceUrl);
      const rule = new AnalyzeRule(resp.body, baseUrl);
      this.seedSourceVariables(rule.getContext(), source);
      const exploreRule = this.effectiveExploreRule(source);
      const stageItems = await BookSourceStageRuleSupport.getElements(source, resp.body, baseUrl,
        exploreRule.bookList || '', SourceRuntimeStage.EXPLORE);
      const items = stageItems === null ? rule.getElements(exploreRule.bookList || '') : stageItems;
      if (items.length === 0) this.noticeMessage = '发现接口已有响应，但列表规则未匹配到内容';
      console.info('[ExploreCoordinator] parsed list:', source.bookSourceName, 'rule:', exploreRule.bookList, 'count:', items.length);
      const books: SearchBook[] = [];
      const sourceBackendHost = BookSourceDataUrlSupport.sourceBackendHost(source);
      const stageBookUrls = await this.analyzeExploreFieldBatch(source, items, baseUrl, exploreRule.bookUrl);

      for (let itemIndex = 0; itemIndex < items.length; itemIndex++) {
        const item = items[itemIndex];
        const ir = new AnalyzeRule(item, baseUrl);
        this.seedSourceVariables(ir.getContext(), source);
        if (sourceBackendHost) {
          ir.getContext().put('host', sourceBackendHost);
          ir.getContext().put('backend', sourceBackendHost);
        }
        const book = new SearchBook();
        book.name = ir.analyzeFirst(exploreRule.name) || '';
        book.author = ir.analyzeFirst(exploreRule.author) || '';
        book.coverUrl = BookSourceDataUrlSupport.normalizeCoverUrlFromItem(source,
          ir.analyzeFirst(exploreRule.coverUrl), item, baseUrl);
        book.intro = ir.analyzeFirst(exploreRule.intro) || '';
        book.kind = ir.analyzeFirst(exploreRule.kind) || '';
        book.latestChapterTitle = ir.analyzeFirst(exploreRule.lastChapter) || '';
        book.wordCount = ir.analyzeFirst(exploreRule.wordCount) || '';
        const stageBookUrl = itemIndex < stageBookUrls.length ? stageBookUrls[itemIndex] : '';
        book.bookUrl = BookUrlResolver.resolve(stageBookUrl || ir.analyzeFirst(exploreRule.bookUrl), baseUrl);
        book.origin = source.bookSourceUrl;
        book.originName = source.bookSourceName;
        BookTypeSupport.applySearchBookType(book, source);

        if (book.name && book.bookUrl && !books.some(b => b.bookUrl === book.bookUrl && b.origin === book.origin)) {
          books.push(book);
        }
      }
      if (books.length > 0) {
        console.info('[ExploreCoordinator] first book:', books[0].name, books[0].bookUrl);
      } else if (items.length > 0) {
        this.noticeMessage = '发现列表已匹配，但书名或详情地址解析失败';
        console.warn('[ExploreCoordinator] list matched but no valid book:', source.bookSourceName,
          'nameRule:', exploreRule.name, 'urlRule:', exploreRule.bookUrl,
          'firstItem:', items[0].substring(0, Math.min(items[0].length, 240)));
      }
      return books;
    } catch (e) {
      console.error('[ExploreCoordinator] explore failed:', e);
      const message = e instanceof Error ? e.message : String(e || '');
      this.noticeMessage = message ? `发现解析异常：${message}` : '发现解析异常';
      return [];
    }
  }

  private async parseExploreUrl(source: BookSource): Promise<ExploreEntry[]> {
    const entries: ExploreEntry[] = [];
    const raw = source.exploreUrl.trim();
    if (!raw) return entries;

    if (raw.startsWith('@js:') || raw.startsWith('js:')) {
      const scriptItems = await this.evaluateExploreScript(raw, source);
      if (scriptItems.length > 0) {
        this.appendExploreItems(entries, scriptItems, source);
        return entries;
      }
      const embeddedItems = this.parseEmbeddedExploreDsl(raw);
      if (embeddedItems.length > 0) {
        this.appendExploreItems(entries, embeddedItems, source);
      }
      return entries;
    }

    try {
      const parsed = JSON.parse(raw) as ExploreUrlItem[];
      if (Array.isArray(parsed)) {
        this.appendExploreItems(entries, parsed, source);
        return entries;
      }
    } catch (_) {
    }

    const looseItems = this.parseLooseExploreItems(raw);
    if (looseItems.length > 0) {
      this.appendExploreItems(entries, looseItems, source);
      if (entries.length > 0) return entries;
    }

    const lines = source.exploreUrl
      .split(/[\n\r]+/)
      .map(line => line.trim())
      .filter(line => line.length > 0);

    for (const line of lines) {
      const idx = line.indexOf('::');
      const title = idx > 0 ? line.substring(0, idx).trim() : source.bookSourceName;
      const url = idx > 0 ? line.substring(idx + 2).trim() : line;
      if (!url || this.isPersonalExploreUrl(title, url)) continue;
      entries.push({
        title: title,
        url: url,
        sourceUrl: source.bookSourceUrl,
        sourceName: source.bookSourceName
      });
    }
    return entries;
  }

  private effectiveExploreRule(source: BookSource): ExploreRule {
    const candidate = source.exploreRule;
    if (candidate && !Array.isArray(candidate) && candidate.bookList && candidate.name && candidate.bookUrl) {
      return candidate;
    }
    return source.searchRule as ExploreRule;
  }

  private async evaluateExploreScript(raw: string, source: BookSource): Promise<ExploreUrlItem[]> {
    const code = raw.replace(/^\s*@?js:\s*/, '');
    const decision = BookSourceRuntimeRouter.decide(SourceRuntimeStage.EXPLORE,
      `${source.jsLib || ''}\n${code}`);
    if (decision.runtime === 'arkweb' && BookSourceStageWebRuntime.get().isAvailable()) {
      const request = new StageWebRuntimeRequest();
      request.source = source;
      request.code = code;
      request.baseUrl = source.bookSourceUrl;
      request.variables = { page: '1', pageIndex: '1' };
      try {
        const runtimeResult = await BookSourceStageWebRuntime.get().execute(request);
        if (runtimeResult.toastMessage) this.noticeMessage = runtimeResult.toastMessage.trim();
        const parsed = JSON.parse(runtimeResult.value || '[]') as ExploreUrlItem[];
        if (Array.isArray(parsed)) return parsed;
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error || '');
        if (message) this.noticeMessage = `发现脚本执行失败：${message}`;
        console.warn('[ExploreCoordinator] stage runtime menu failed, fallback legacy:', source.bookSourceName, error);
      }
    }
    const env = new ScriptEngineContext();
    env.baseUrl = source.bookSourceUrl;
    this.seedSourceVariables(env.ctx, source);
    const result = new ScriptEngine(new JsRuntime()).evalBlock(code, env);
    if (!result.handled || !result.value) return [];
    try {
      const parsed = JSON.parse(result.value) as ExploreUrlItem[];
      return Array.isArray(parsed) ? parsed : [];
    } catch (_) {
      return [];
    }
  }

  private parseEmbeddedExploreDsl(raw: string): ExploreUrlItem[] {
    const blocks = raw.match(/`[\s\S]*?`/g) || [];
    for (const block of blocks) {
      const content = block.substring(1, block.length - 1);
      if (!content.includes('::')) continue;
      const items: ExploreUrlItem[] = [];
      for (const rawLine of content.split(/[\n\r]+/)) {
        const line = rawLine.trim();
        if (!line) continue;
        const index = line.indexOf('::');
        if (index > 0) {
          items.push({
            title: line.substring(0, index).trim(),
            url: line.substring(index + 2).trim()
          });
        } else {
          items.push({ title: line, url: '' });
        }
      }
      if (items.length > 0) return items;
    }
    return [];
  }

  private appendExploreItems(entries: ExploreEntry[], items: ExploreUrlItem[], source: BookSource): void {
    let groupTitle = '';
    for (const item of items) {
      const title = String(item.title || '').trim();
      const url = String(item.url || '').trim();
      if (!url) {
        if (this.isExploreNotice(title)) {
          this.noticeMessage = title;
        } else {
          groupTitle = this.cleanExploreGroupTitle(title) || groupTitle;
        }
        continue;
      }
      if (!title || this.isPersonalExploreUrl(title, url)) continue;
      const entryTitle = groupTitle ? `${groupTitle} · ${title}` : title;
      if (entries.some(entry => entry.title === entryTitle && entry.url === url && entry.sourceUrl === source.bookSourceUrl)) {
        continue;
      }
      entries.push({
        title: entryTitle,
        url: url,
        sourceUrl: source.bookSourceUrl,
        sourceName: source.bookSourceName
      });
    }
  }

  private parseLooseExploreItems(raw: string): ExploreUrlItem[] {
    const items: ExploreUrlItem[] = [];
    const blocks = this.extractLooseObjectBlocks(raw);
    for (const block of blocks) {
      const title = this.readLooseObjectValue(block, 'title');
      const url = this.readLooseObjectValue(block, 'url');
      if (title || url) {
        items.push({ title: title, url: url });
      }
    }
    return items;
  }

  private extractLooseObjectBlocks(raw: string): string[] {
    const blocks: string[] = [];
    let depth = 0;
    let quote = '';
    let start = -1;
    for (let i = 0; i < raw.length; i++) {
      const ch = raw.charAt(i);
      if (quote) {
        if (ch === quote && raw.charAt(i - 1) !== '\\') quote = '';
        continue;
      }
      if (ch === '"' || ch === "'") {
        quote = ch;
        continue;
      }
      if (ch === '{') {
        if (depth === 0) start = i;
        depth++;
      } else if (ch === '}') {
        if (depth > 0) depth--;
        if (depth === 0 && start >= 0) {
          blocks.push(raw.substring(start, i + 1));
          start = -1;
        }
      }
    }
    return blocks;
  }

  private readLooseObjectValue(block: string, key: string): string {
    const keyIndex = block.search(new RegExp(`["']?${key}["']?\\s*:`));
    if (keyIndex < 0) return '';
    const afterKey = block.substring(keyIndex);
    const colonIndex = afterKey.indexOf(':');
    if (colonIndex < 0) return '';
    let valueStart = keyIndex + colonIndex + 1;
    while (valueStart < block.length && /\s/.test(block.charAt(valueStart))) {
      valueStart++;
    }
    if (valueStart >= block.length) return '';

    const first = block.charAt(valueStart);
    if (first === '"' || first === "'") {
      let value = '';
      for (let i = valueStart + 1; i < block.length; i++) {
        const ch = block.charAt(i);
        if (ch === first && block.charAt(i - 1) !== '\\') {
          return value.trim();
        }
        value += ch;
      }
      return value.trim();
    }

    let valueEnd = block.length;
    const commaIndex = block.indexOf(',', valueStart);
    const braceIndex = block.indexOf('}', valueStart);
    if (commaIndex >= 0) valueEnd = Math.min(valueEnd, commaIndex);
    if (braceIndex >= 0) valueEnd = Math.min(valueEnd, braceIndex);
    return block.substring(valueStart, valueEnd)
      .replace(/^['"]|['"]$/g, '')
      .trim();
  }

  private cleanExploreGroupTitle(title: string): string {
    return (title || '')
      .replace(/[༺༻ˇ»«`´ʚɞ]/g, '')
      .replace(/[^\u4e00-\u9fa5A-Za-z0-9]+/g, '')
      .trim();
  }

  private isExploreNotice(title: string): boolean {
    return /请先|需要登录|未登录|token|失败|错误|异常|失效|过期|无权限/i.test(title || '');
  }

  private requiresSourceVariable(source: BookSource): boolean {
    const script = `${source.jsLib || ''}\n${source.exploreUrl || ''}`;
    return /authorization[\s\S]{0,160}getVariable\s*\(|Bearer[\s\S]{0,120}getVariable\s*\(/i.test(script);
  }

  private isPersonalExploreUrl(title: string, url: string): boolean {
    const value = `${title || ''}\n${url || ''}`.toLowerCase();
    return value.includes('我的书架') || value.includes('bookshelf') || value.includes('/user/') ||
      value.includes('/login');
  }

  private async buildUrl(source: BookSource, url: string, page: number): Promise<string> {
    const decision = BookSourceRuntimeRouter.decide(SourceRuntimeStage.URL,
      `${source.jsLib || ''}\n${url || ''}`);
    const isFullJsUrl = /^\s*@?js:/i.test(url || '');
    if (decision.runtime === 'arkweb' && BookSourceStageWebRuntime.get().isAvailable() &&
      (isFullJsUrl || url.includes('{{'))) {
      const request = new StageWebRuntimeRequest();
      request.source = source;
      request.baseUrl = source.bookSourceUrl;
      request.variables = { page: String(page), pageIndex: String(page) };
      if (isFullJsUrl) {
        request.code = (url || '').replace(/^\s*@?js:\s*/i, '');
      } else {
        const template = JSON.stringify(url || '');
        request.code = `const __exploreTemplate=${template};result=__exploreTemplate.replace(/\\{\\{([\\s\\S]*?)\\}\\}/g,` +
          `function(_,expr){try{return String(eval(expr));}catch(e){return '';}});result;`;
      }
      try {
        const result = await BookSourceStageWebRuntime.get().execute(request);
        if (result.value) return result.value;
      } catch (error) {
        console.warn('[ExploreCoordinator] stage runtime URL failed, fallback legacy:', source.bookSourceName, error);
      }
    }
    if (/^\s*@?js:/i.test(url || '')) {
      const scripted = BookSourceScriptRunner.evaluateUrl(source, url, '', String(page));
      if (scripted.handled && scripted.value) {
        source.variable = scripted.variable;
        return scripted.value;
      }
    }
    const built = BookSourceDataUrlSupport.buildRequestUrl(source, url, String(page));
    if (built) return built;
    const js = new JsRuntime();
    js.setVar('page', String(page));
    js.setVar('pageIndex', String(page));
    return js.evalTemplate(this.applySourceTemplate(url, source)).replace(/\{\{[^}]+\}\}/g, String(page));
  }

  private async analyzeExploreFieldBatch(source: BookSource, items: string[], baseUrl: string,
    rawRule: string): Promise<string[]> {
    const rule = (rawRule || '').trim();
    if (!rule || !/^@?js:/i.test(rule) || items.length === 0) return [];
    const code = rule.replace(/^@?js:\s*/i, '');
    const decision = BookSourceRuntimeRouter.decide(SourceRuntimeStage.EXPLORE,
      `${source.jsLib || ''}\n${code}`);
    const runtime = BookSourceStageWebRuntime.get();
    if (decision.runtime !== 'arkweb' || !runtime.isAvailable()) return [];

    const request = new StageWebRuntimeRequest();
    request.source = source;
    request.content = JSON.stringify(items.map((item: string): Object | string => {
      try { return JSON.parse(item) as Object; } catch (_) { return item; }
    }));
    request.contextContent = request.content;
    request.baseUrl = baseUrl || source.bookSourceUrl;
    request.code = `const __fieldItems=JSON.parse(result||'[]');const __fieldCode=${JSON.stringify(code)};` +
      `JSON.stringify(__fieldItems.map(function(__fieldItem){java.__setContextContent(__fieldItem);` +
      `try{const __fieldValue=eval(__fieldCode);return __fieldValue==null?'':String(__fieldValue);}` +
      `catch(__fieldError){return '';}}));`;
    try {
      const result = await runtime.execute(request);
      const parsed = JSON.parse(result.value || '[]') as Object;
      if (!Array.isArray(parsed)) return [];
      return (parsed as Object[]).map((value: Object): string => String(value || ''));
    } catch (error) {
      console.warn('[ExploreCoordinator] stage runtime field batch failed, fallback legacy:',
        source.bookSourceName, error);
      return [];
    }
  }

  private applySourceTemplate(url: string, source: BookSource): string {
    return (url || '')
      .replace(/\{\{\s*source\.bookSourceUrl\s*\}\}/g, source.bookSourceUrl || '')
      .replace(/\{\{\s*source\.bookSourceName\s*\}\}/g, source.bookSourceName || '')
      .replace(/\{\{\s*source\.bookSourceGroup\s*\}\}/g, source.bookSourceGroup || '');
  }

  private seedSourceVariables(ctx: RuleContext, source: BookSource): void {
    ctx.put('source.bookSourceUrl', source.bookSourceUrl || '');
    ctx.put('bookSourceUrl', source.bookSourceUrl || '');
    ctx.put('source.bookSourceName', source.bookSourceName || '');
    ctx.put('bookSourceName', source.bookSourceName || '');
    ctx.put('source.bookSourceGroup', source.bookSourceGroup || '');
    ctx.put('bookSourceGroup', source.bookSourceGroup || '');
    ctx.put('source.bookSourceComment', source.bookSourceComment || '');
    ctx.put('bookSourceComment', source.bookSourceComment || '');
    if (!ctx.has('source.variable')) ctx.put('source.variable', source.variable || '');
  }

  private async fetchEncodedDataUrl(url: string, source: BookSource): Promise<{ url: string, statusCode: number, headers: Record<string, string>, body: string, success: boolean, error?: string }> {
    const root = await EncodedSourceUrl.requestJsonForDataUrl(this.http, url,
      BookSourceDataUrlSupport.sourceBackendHost(source));
    if (!root) {
      return { url: url, statusCode: 0, headers: {}, body: '', success: false, error: 'encoded data url request failed' };
    }
    return { url: url, statusCode: 200, headers: {}, body: JSON.stringify(root), success: true };
  }
}
