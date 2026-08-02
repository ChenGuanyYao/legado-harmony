import { util } from '@kit.ArkTS';
import { webview } from '@kit.ArkWeb';
import { Book, BookSource } from '../../model/data/Book';
import { AppDatabase } from '../../model/data/AppDatabase';
import { CookieStore } from '../http/CookieStore';
import { HttpClient, HttpResponse } from '../http/HttpClient';
import { AnalyzeUrl } from '../rule/AnalyzeUrl';

export class StageWebRuntimeRequest {
  source: BookSource = new BookSource();
  book: Book | null = null;
  code: string = '';
  content: string = '';
  contextContent: string = '';
  baseUrl: string = '';
  variables: Record<string, string> = {};
  readerActionMode: boolean = false;
  networkTimeoutMs: number = 20000;
  maxResponseBytes: number = 8 * 1024 * 1024;
  maxTotalResponseBytes: number = 16 * 1024 * 1024;
  ownerId: string = '';
}

export class StageWebRuntimeResult {
  value: string = '';
  variable: string = '';
  bookVariable: string = '';
  requestedUrl: string = '';
  toastMessage: string = '';
  errorMessage: string = '';
}

class StageWebRuntimeStep extends StageWebRuntimeResult {
  pendingAjax: string = '';
  pendingCookie: string = '';
  cookieOperations: string = '[]';
  cacheState: string = '{}';
  javaState: string = '{}';
  sourceState: string = '{}';
}

class StageWebRuntimeCookieOperation {
  operation: string = '';
  url: string = '';
  value: string = '';
  name: string = '';
}

class StageWebRuntimeTask {
  request: StageWebRuntimeRequest = new StageWebRuntimeRequest();
  resolve: ((value: StageWebRuntimeResult) => void) | null = null;
  reject: ((reason: Error) => void) | null = null;
}

/**
 * Shared ArkWeb host for complex non-login source scripts. Calls are serialized and every
 * network/cookie side effect is replayed through the native bridge before a result is accepted.
 */
export class BookSourceStageWebRuntime {
  private static instance: BookSourceStageWebRuntime | null = null;
  private controller: webview.WebviewController | null = null;
  private ready: boolean = false;
  private tasks: StageWebRuntimeTask[] = [];
  private running: boolean = false;
  private activeTask: StageWebRuntimeTask | null = null;
  private activeHttpClient: HttpClient | null = null;
  private cancelledOwners: Set<string> = new Set<string>();
  private caches: Record<string, Record<string, string>> = {};

  static get(): BookSourceStageWebRuntime {
    if (!BookSourceStageWebRuntime.instance) {
      BookSourceStageWebRuntime.instance = new BookSourceStageWebRuntime();
    }
    return BookSourceStageWebRuntime.instance;
  }

  attach(controller: webview.WebviewController): void {
    this.controller = controller;
  }

  setReady(ready: boolean): void {
    this.ready = ready;
    if (ready) this.startNext();
  }

  detach(controller: webview.WebviewController): void {
    if (this.controller !== controller) return;
    this.controller = null;
    this.ready = false;
  }

  isAvailable(): boolean {
    return !!this.controller && this.ready;
  }

  execute(request: StageWebRuntimeRequest): Promise<StageWebRuntimeResult> {
    return new Promise<StageWebRuntimeResult>((resolve, reject) => {
      if (request.ownerId && this.cancelledOwners.has(request.ownerId)) {
        reject(new Error('书源脚本任务已取消'));
        return;
      }
      const task = new StageWebRuntimeTask();
      task.request = request;
      task.resolve = resolve;
      task.reject = reject;
      this.tasks.push(task);
      this.startNext();
    });
  }

  cancelOwner(ownerId: string): void {
    if (!ownerId) return;
    this.cancelledOwners.add(ownerId);
    const remaining: StageWebRuntimeTask[] = [];
    for (const task of this.tasks) {
      if (task.request.ownerId === ownerId) {
        if (task.reject) task.reject(new Error('书源脚本任务已取消'));
      } else {
        remaining.push(task);
      }
    }
    this.tasks = remaining;
    if (this.activeTask?.request.ownerId === ownerId && this.activeHttpClient) {
      this.activeHttpClient.cancelAll();
    }
  }

  clearOwner(ownerId: string): void {
    if (ownerId) this.cancelledOwners.delete(ownerId);
  }

  private startNext(): void {
    if (this.running || !this.controller || !this.ready || this.tasks.length === 0) return;
    const task = this.tasks.shift();
    if (!task) return;
    this.running = true;
    this.activeTask = task;
    this.executeTask(task.request)
      .then((value: StageWebRuntimeResult): void => {
        if (task.resolve) task.resolve(value);
      })
      .catch((error: Error): void => {
        if (task.reject) task.reject(error);
      })
      .finally((): void => {
        this.activeTask = null;
        this.activeHttpClient = null;
        this.running = false;
        this.startNext();
      });
  }

  private async executeTask(request: StageWebRuntimeRequest): Promise<StageWebRuntimeResult> {
    this.ensureNotCancelled(request);
    // Coordinators may hold a source snapshot while the login/editor page saves a new token.
    // Refresh missing runtime fields before executing so a stale empty snapshot cannot issue an
    // unauthenticated request or overwrite the newly saved state when the stage completes.
    const persistedAtStart = await AppDatabase.getInstance().getBookSource(request.source.bookSourceUrl);
    if (persistedAtStart) {
      if (!request.source.variable && persistedAtStart.variable) request.source.variable = persistedAtStart.variable;
      if (!request.source.loginHeader && persistedAtStart.loginHeader) {
        request.source.loginHeader = persistedAtStart.loginHeader;
      }
      if ((!request.source.loginInfo || request.source.loginInfo === '{}') && persistedAtStart.loginInfo) {
        request.source.loginInfo = persistedAtStart.loginInfo;
      }
    }
    const sourceKey = request.source.bookSourceUrl || request.source.bookSourceName || 'source';
    const responses: Record<string, string> = {};
    const cookies: Record<string, string> = {};
    let cacheState = this.caches[sourceKey] || {};
    const appliedOperations: string[] = [];
    const fixedNow = Date.now();
    const randomSeed = Math.max(1, Math.floor(Math.random() * 0x7fffffff));
    let requestCount = 0;
    let totalResponseBytes = 0;
    for (let stepIndex = 0; stepIndex < 20; stepIndex++) {
      this.ensureNotCancelled(request);
      const script = this.buildScript(request, responses, cookies, cacheState, fixedNow, randomSeed);
      const raw = await this.runJavaScript(script);
      this.ensureNotCancelled(request);
      const step = this.parseStep(raw);
      request.source.variable = step.variable;
      if (request.book) request.book.variable = step.bookVariable;
      try {
        cacheState = JSON.parse(step.cacheState || '{}') as Record<string, string>;
      } catch (_) {
        cacheState = {};
      }
      this.caches[sourceKey] = cacheState;
      request.source.loginInfo = this.mergeRuntimeState(request.source.loginInfo || '',
        step.javaState, step.sourceState, cacheState);
      this.applyCookieOperations(step.cookieOperations, appliedOperations);
      if (step.pendingCookie) {
        cookies[step.pendingCookie] = CookieStore.getCookie(step.pendingCookie);
        continue;
      }
      if (step.pendingAjax) {
        requestCount++;
        if (requestCount > 12) throw new Error('书源脚本网络请求次数过多');
        const response = await this.fetch(request, step.pendingAjax);
        this.ensureNotCancelled(request);
        if (!response.success && response.statusCode === 0) {
          throw new Error(response.error || '书源脚本网络请求失败');
        }
        const responseBody = response.body || '';
        // ArkTS/ArkWeb exchange response bodies as UTF-16 strings. Count their in-memory
        // footprint instead of only character count so the cumulative guard remains useful.
        totalResponseBytes += responseBody.length * 2;
        const totalLimit = Math.max(request.maxResponseBytes,
          Math.min(request.maxTotalResponseBytes || 16 * 1024 * 1024, 16 * 1024 * 1024));
        if (totalResponseBytes > totalLimit) {
          throw new Error('书源脚本累计响应过大');
        }
        responses[step.pendingAjax] = responseBody;
        continue;
      }
      if (step.errorMessage) throw new Error(step.errorMessage);
      const persistedBeforeSave = await AppDatabase.getInstance().getBookSource(request.source.bookSourceUrl);
      if (persistedBeforeSave) {
        // Empty state from a non-login task is never an explicit logout. Preserve a token/header
        // that another page saved while this asynchronous task was running.
        request.source.variable = step.variable || persistedBeforeSave.variable || '';
        request.source.loginHeader = request.source.loginHeader || persistedBeforeSave.loginHeader || '';
        request.source.loginInfo = this.mergeRuntimeState(
          persistedBeforeSave.loginInfo || request.source.loginInfo || '',
          step.javaState, step.sourceState, cacheState);
      }
      await AppDatabase.getInstance().updateBookSourceLoginRuntime(request.source.bookSourceUrl,
        request.source.variable || '', request.source.loginHeader || '', request.source.loginInfo || '');
      return step;
    }
    throw new Error('书源脚本执行步骤过多');
  }

  private async fetch(request: StageWebRuntimeRequest, requestUrl: string): Promise<HttpResponse> {
    const timeout = Math.max(3000, Math.min(request.networkTimeoutMs || 20000, 30000));
    const responseLimit = Math.max(64 * 1024,
      Math.min(request.maxResponseBytes || 8 * 1024 * 1024, 8 * 1024 * 1024));
    const client = new HttpClient(timeout);
    this.activeHttpClient = client;
    try {
      return await new AnalyzeUrl(request.source, client).fetch(requestUrl, responseLimit);
    } finally {
      if (this.activeHttpClient === client) this.activeHttpClient = null;
    }
  }

  private ensureNotCancelled(request: StageWebRuntimeRequest): void {
    if (request.ownerId && this.cancelledOwners.has(request.ownerId)) {
      throw new Error('书源脚本任务已取消');
    }
  }

  private runJavaScript(script: string): Promise<string> {
    const controller = this.controller;
    if (!controller || !this.ready) return Promise.reject(new Error('书源脚本运行环境未就绪'));
    return new Promise<string>((resolve, reject) => {
      let completed = false;
      const timer = setTimeout(() => {
        if (completed) return;
        completed = true;
        reject(new Error('书源脚本引擎响应超时'));
      }, 20000);
      controller.runJavaScript(script)
        .then((value: string): void => {
          if (completed) return;
          completed = true;
          clearTimeout(timer);
          resolve(value);
        })
        .catch((error: Error): void => {
          if (completed) return;
          completed = true;
          clearTimeout(timer);
          reject(error);
        });
    });
  }

  private buildScript(request: StageWebRuntimeRequest, responses: Record<string, string>,
    cookies: Record<string, string>, cacheState: Record<string, string>, fixedNow: number, randomSeed: number): string {
    const bookVariables = this.parseRecord(request.book ? request.book.variable : '');
    const loginInfo = this.parseLoginInfo(request.source.loginInfo || '');
    const javaState = this.parseRuntimeJavaState(request.source.loginInfo || '');
    const sourceState = this.parseRuntimeObjectState(request.source.loginInfo || '', 'source');
    const state = JSON.stringify({
      sourceUrl: request.source.bookSourceUrl || '',
      sourceName: request.source.bookSourceName || '',
      sourceHeader: request.source.header || '',
      sourceLoginHeader: request.source.loginHeader || '',
      variable: request.source.variable || '',
      content: request.content || '',
      contextContent: request.contextContent || request.content || '',
      baseUrl: request.baseUrl || request.source.bookSourceUrl || '',
      variables: request.variables || {},
      bookVariables: bookVariables,
      responses: responses || {},
      cookies: cookies || {},
      cache: cacheState || {},
      fixedNow: fixedNow,
      randomSeed: randomSeed,
      loginInfo: loginInfo,
      javaState: javaState,
      sourceState: sourceState,
      readerActionMode: request.readerActionMode
    });
    const library = request.source.jsLib || '';
    const exposeFunctions = this.functionExposeScript(library);
    const code = `${library}\n${exposeFunctions}\n${request.code || ''}\n//# sourceURL=book-source-stage.js`;
    const stateBase64 = this.encodeBase64(state);
    const codeBase64 = this.encodeBase64(code);
    return `(function(){` +
      `function dec(v){try{return decodeURIComponent(escape(atob(v)));}catch(e){return atob(v);}}` +
      `const S=JSON.parse(dec('${stateBase64}'));let pending='',pendingCookie='',url='',toast='',error='';` +
      `const cookieOps=[];const sourceData=Object.assign({},S.sourceState||{});` +
      `const cacheData=Object.assign({},S.cache||{});` +
      `const javaData=Object.assign({},S.javaState||{});const loginMap=Object.assign({},S.loginInfo||{});` +
      `Object.defineProperty(loginMap,'get',{enumerable:false,value:function(k){return this[k]??'';}});` +
      `Object.defineProperty(loginMap,'put',{enumerable:false,value:function(k,v){this[k]=v;return v;}});` +
      `const bookData=Object.assign({},S.bookVariables||{});` +
      `const NativeDate=globalThis.Date;const FixedDate=function(){const a=Array.from(arguments);` +
      `if(new.target)return Reflect.construct(NativeDate,a.length?a:[S.fixedNow]);return new NativeDate(S.fixedNow).toString();};` +
      `FixedDate.now=function(){return S.fixedNow;};FixedDate.parse=NativeDate.parse;FixedDate.UTC=NativeDate.UTC;` +
      `FixedDate.prototype=NativeDate.prototype;const Date=FixedDate;let randomState=(Number(S.randomSeed)||1)>>>0;` +
      `const Math=Object.create(globalThis.Math);Math.random=function(){randomState=(randomState*1664525+1013904223)>>>0;` +
      `return randomState/4294967296;};` +
      `const previousNames=Array.isArray(globalThis.__legadoHarmonyStageExposedNames)?` +
      `globalThis.__legadoHarmonyStageExposedNames:[];for(const oldName of previousNames){` +
      `try{delete globalThis[oldName];}catch(e){globalThis[oldName]=undefined;}}` +
      `globalThis.__legadoHarmonyStageExposedNames=[];` +
      `function bytes(v){if(v instanceof Uint8Array)return Array.from(v);if(Array.isArray(v))return v;` +
      `return Array.from(new TextEncoder().encode(String(v??'')));}` +
      `function b64e(v){try{let s='';for(const x of bytes(v))s+=String.fromCharCode(Number(x)&255);return btoa(s);}catch(e){return '';}}` +
      `function b64d(v){try{const s=atob(String(v??''));const a=[];for(let i=0;i<s.length;i++)a.push(s.charCodeAt(i)&255);` +
      `return new TextDecoder().decode(new Uint8Array(a));}catch(e){return '';}}` +
      `function hexD(v){try{v=String(v??'').replace(/\\s+/g,'');const a=[];for(let i=0;i<v.length;i+=2)` +
      `a.push(parseInt(v.substring(i,i+2),16));return new TextDecoder().decode(new Uint8Array(a));}catch(e){return '';}}` +
      `function hexE(v){return bytes(v).map(function(x){return Number(x).toString(16).padStart(2,'0');}).join('');}` +
      `function pathValue(path){try{let value=typeof S.contextContent==='string'?JSON.parse(S.contextContent):S.contextContent;` +
      `const parts=String(path??'').replace(/^\\$\\.?/,'').split('.').filter(Boolean);for(const p of parts){` +
      `if(value===null||value===undefined)return '';value=value[p];}return value===null||value===undefined?'':value;}catch(e){return '';}}` +
      `const cookieData=Object.assign({},S.cookies||{});const cookie={getCookie:function(k){k=String(k??'');` +
      `if(Object.prototype.hasOwnProperty.call(cookieData,k))return cookieData[k]??'';if(!pendingCookie)pendingCookie=k;return '';},` +
      `getKey:function(k,n){const v=this.getCookie(k);const m=String(v).match(new RegExp('(?:^|;\\\\s*)'+n+'=([^;]*)'));return m?m[1]:'';},` +
      `setCookie:function(k,v){k=String(k??'');v=String(v??'');cookieData[k]=v;cookieOps.push({operation:'set',url:k,value:v,name:''});return v;},` +
      `replaceCookie:function(k,v){k=String(k??'');v=String(v??'');cookieData[k]=v;cookieOps.push({operation:'replace',url:k,value:v,name:''});return v;},` +
      `removeCookie:function(k,n){k=String(k??'');n=String(n??'');cookieOps.push({operation:'remove',url:k,value:'',name:n});` +
      `cookieData[k]='';return true;}};` +
      `const source={bookSourceUrl:S.sourceUrl,bookSourceName:S.sourceName,header:S.sourceHeader,` +
      `getKey:function(){return S.sourceUrl;},getTag:function(){return S.sourceName;},getSource:function(){return this;},` +
      `getLoginHeader:function(){return S.sourceLoginHeader||'';},` +
      `getHeaderMap:function(){try{return JSON.parse(S.sourceHeader||'{}');}catch(e){return {};}} ,` +
      `getVariable:function(){return S.variable||'';},setVariable:function(v){S.variable=String(v??'');return S.variable;},` +
      `get:function(k){return sourceData[String(k??'')]??'';},put:function(k,v){sourceData[String(k??'')]=v;return v;},` +
      `putLoginInfo:function(v){if(typeof v==='string'){try{v=JSON.parse(v);}catch(e){return v;}}` +
      `if(v&&typeof v==='object')Object.assign(loginMap,v);return v;},` +
      `getLoginInfo:function(k){return arguments.length?(loginMap[k]??''):JSON.stringify(loginMap);},` +
      `getLoginInfoMap:function(){return loginMap;}};` +
      `const book={getVariable:function(k){return bookData[String(k??'')]??'';},` +
      `putVariable:function(k,v){bookData[String(k??'')]=String(v??'');return v;}};` +
      `const cache={get:function(k){return cacheData[k]??null;},getFromMemory:function(k){return cacheData[k]??null;},` +
      `put:function(k,v){cacheData[k]=v;return v;},putMemory:function(k,v){cacheData[k]=v;return v;},` +
      `delete:function(k){delete cacheData[k];return true;}};` +
      `const java={ajax:function(v){v=String(v??'');if(Object.prototype.hasOwnProperty.call(S.responses,v))return S.responses[v];` +
      `if(!pending)pending=v;return '{}';},put:function(k,v){javaData[String(k??'')]=v;return v;},` +
      `get:function(k){k=String(k??'');return Object.prototype.hasOwnProperty.call(javaData,k)?javaData[k]:null;},` +
      `log:function(v){return v===undefined?'':v;},logType:function(v){return v===undefined?'':v;},` +
      `toast:function(v){toast=String(v??'');return toast;},longToast:function(v){toast=String(v??'');return toast;},` +
      `androidId:function(){return 'harmony';},deviceID:function(){if(S.readerActionMode)return 'harmony';` +
      `throw new Error('deviceID unavailable');},qread:function(){throw new Error('qread unavailable');},` +
      `base64Encode:b64e,base64EncodeToString:b64e,base64Decode:b64d,base64DecodeToString:b64d,` +
      `hexDecodeToString:hexD,hexEncodeToString:hexE,getCookie:function(k){return cookie.getCookie(k);},` +
      `getString:function(k){const v=pathValue(k);return typeof v==='string'?v:JSON.stringify(v);},` +
      `timeFormat:function(v){try{return new NativeDate(Number(v)).toISOString().replace('T',' ').replace('Z','');}catch(e){return String(v??'');}},` +
      `timeFormatUTC:function(v){try{return new NativeDate(Number(v)).toISOString();}catch(e){return String(v??'');}},` +
      `startBrowser:function(u){url=String(u??'');return {body:function(){return '';}};},` +
      `startBrowserAwait:function(u){url=String(u??'');return {body:function(){return '';}};},` +
      `startBrowserDp:function(u){url=String(u??'');return {body:function(){return '';}};},` +
      `showBrowser:function(u){url=String(u??'');return {body:function(){return '';}};},` +
      `showReadingBrowser:function(u){url=String(u??'');return {body:function(){return '';}};},` +
      `open:function(u){url=String(u??'');return url;},webView:function(){throw new Error('java.webView仅登录动作可用');},` +
      `refreshExplore:function(){return true;},searchBook:function(){return true;}};` +
      `function TimeoutCancellationException(){}const Packages={io:{legato:{kazusa:{utils:{` +
      `TimeoutCancellationException:TimeoutCancellationException}}}}};` +
      `globalThis.source=source;globalThis.book=book;globalThis.java=java;globalThis.cache=cache;globalThis.cookie=cookie;` +
      `globalThis.Packages=Packages;globalThis.baseUrl=S.baseUrl;globalThis.result=S.content;` +
      `Object.keys(S.variables||{}).forEach(function(k){globalThis[k]=S.variables[k];});` +
      `let evaluated;try{evaluated=(function(){return eval(dec('${codeBase64}'));}).call(globalThis);}` +
      `catch(e){error=String((e&&e.name?e.name+': ':'')+((e&&e.message)||e||'脚本执行失败')+(e&&e.stack?'\\n'+e.stack:''));}` +
      `function text(v){if(typeof v==='string')return v;if(v===undefined||v===null)return '';try{return JSON.stringify(v);}catch(e){return String(v);}}` +
      `const value=text(evaluated)||text(globalThis.result);` +
      `return encodeURIComponent(JSON.stringify({pendingAjax:pending,pendingCookie:pendingCookie,` +
      `cookieOperations:JSON.stringify(cookieOps),variable:S.variable||'',bookVariable:JSON.stringify(bookData),` +
      `cacheState:JSON.stringify(cacheData),javaState:JSON.stringify(javaData),sourceState:JSON.stringify(sourceData),` +
      `value:value,requestedUrl:url,toastMessage:toast,errorMessage:error}));})()`;
  }

  private parseStep(raw: string): StageWebRuntimeStep {
    let value = (raw || '').trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    try {
      const record = JSON.parse(decodeURIComponent(value)) as Record<string, Object>;
      const step = new StageWebRuntimeStep();
      step.pendingAjax = String(record['pendingAjax'] || '');
      step.pendingCookie = String(record['pendingCookie'] || '');
      step.cookieOperations = String(record['cookieOperations'] || '[]');
      step.variable = String(record['variable'] || '');
      step.bookVariable = String(record['bookVariable'] || '{}');
      step.cacheState = String(record['cacheState'] || '{}');
      step.javaState = String(record['javaState'] || '{}');
      step.sourceState = String(record['sourceState'] || '{}');
      step.value = String(record['value'] || '');
      step.requestedUrl = String(record['requestedUrl'] || '');
      step.toastMessage = String(record['toastMessage'] || '');
      step.errorMessage = String(record['errorMessage'] || '');
      return step;
    } catch (_) {
      const step = new StageWebRuntimeStep();
      step.errorMessage = '书源脚本返回格式异常';
      return step;
    }
  }

  private functionExposeScript(script: string): string {
    const names: string[] = [];
    const regex = /\bfunction\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(/g;
    let match: RegExpExecArray | null;
    while ((match = regex.exec(script || '')) !== null) {
      const name = match[1] || '';
      if (name && !names.includes(name)) names.push(name);
    }
    let code = `globalThis.__legadoHarmonyStageExposedNames=${JSON.stringify(names)};`;
    for (const name of names) {
      code += `if(typeof ${name}==='function')globalThis[${JSON.stringify(name)}]=${name};`;
    }
    return code;
  }

  private applyCookieOperations(raw: string, applied: string[]): void {
    let records: Object[] = [];
    try {
      const value = JSON.parse(raw || '[]') as Object;
      if (Array.isArray(value)) records = value;
    } catch (_) {}
    for (const item of records) {
      if (!item || typeof item !== 'object' || Array.isArray(item)) continue;
      const record = item as Record<string, Object>;
      const operation = new StageWebRuntimeCookieOperation();
      operation.operation = String(record['operation'] || '');
      operation.url = String(record['url'] || '');
      operation.value = String(record['value'] || '');
      operation.name = String(record['name'] || '');
      const key = `${operation.operation}\n${operation.url}\n${operation.name}\n${operation.value}`;
      if (!operation.url || applied.includes(key)) continue;
      applied.push(key);
      if (operation.operation === 'set') CookieStore.setCookies(operation.url, operation.value);
      if (operation.operation === 'replace') CookieStore.replaceCookies(operation.url, operation.value);
      if (operation.operation === 'remove') CookieStore.removeCookie(operation.url, operation.name || undefined);
    }
    if (records.length > 0) CookieStore.saveAsync();
  }

  private parseRecord(raw: string): Record<string, string> {
    try {
      const value = JSON.parse(raw || '{}') as Record<string, Object>;
      const result: Record<string, string> = {};
      for (const key of Object.keys(value)) result[key] = String(value[key] || '');
      return result;
    } catch (_) {
      return {};
    }
  }

  private parseLoginInfo(raw: string): Record<string, string> {
    try {
      const value = JSON.parse(raw || '{}') as Record<string, Object>;
      const result: Record<string, string> = {};
      for (const key of Object.keys(value)) {
        if (key !== '__legadoHarmonyRuntime') result[key] = String(value[key] || '');
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  private parseRuntimeJavaState(raw: string): Record<string, Object> {
    return this.parseRuntimeObjectState(raw, 'java');
  }

  private parseRuntimeObjectState(raw: string, stateKey: string): Record<string, Object> {
    try {
      const loginInfo = JSON.parse(raw || '{}') as Record<string, Object>;
      let runtime = loginInfo['__legadoHarmonyRuntime'];
      if (typeof runtime === 'string') runtime = JSON.parse(runtime) as Object;
      if (!runtime || typeof runtime !== 'object' || Array.isArray(runtime)) return {};
      const state = (runtime as Record<string, Object>)[stateKey];
      if (!state || typeof state !== 'object' || Array.isArray(state)) return {};
      return state as Record<string, Object>;
    } catch (_) {
      return {};
    }
  }

  private mergeRuntimeState(raw: string, javaStateRaw: string, sourceStateRaw: string,
    cacheState: Record<string, string>): string {
    let loginInfo: Record<string, Object> = {};
    try {
      const parsed = JSON.parse(raw || '{}') as Object;
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
        loginInfo = parsed as Record<string, Object>;
      }
    } catch (_) {}
    let runtime: Record<string, Object> = {};
    const existingRuntime = loginInfo['__legadoHarmonyRuntime'];
    try {
      const parsedRuntime = typeof existingRuntime === 'string' ? JSON.parse(existingRuntime) as Object : existingRuntime;
      if (parsedRuntime && typeof parsedRuntime === 'object' && !Array.isArray(parsedRuntime)) {
        runtime = parsedRuntime as Record<string, Object>;
      }
    } catch (_) {}
    runtime['java'] = this.parseObjectState(javaStateRaw);
    runtime['source'] = this.parseObjectState(sourceStateRaw);
    runtime['cache'] = cacheState;
    loginInfo['__legadoHarmonyRuntime'] = JSON.stringify(runtime);
    return JSON.stringify(loginInfo);
  }

  private parseObjectState(raw: string): Record<string, Object> {
    try {
      const parsed = JSON.parse(raw || '{}') as Object;
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
        return parsed as Record<string, Object>;
      }
    } catch (_) {}
    return {};
  }

  private encodeBase64(value: string): string {
    const bytes = new util.TextEncoder().encodeInto(value || '');
    return new util.Base64Helper().encodeToStringSync(bytes);
  }
}
