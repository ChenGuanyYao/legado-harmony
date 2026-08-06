import { util } from '@kit.ArkTS';
import { webview } from '@kit.ArkWeb';
import { Book, BookChapter, BookSource } from '../../model/data/Book';
import { AppDatabase } from '../../model/data/AppDatabase';
import { CookieStore } from '../http/CookieStore';
import { HttpClient, HttpResponse } from '../http/HttpClient';
import { AnalyzeUrl } from '../rule/AnalyzeUrl';
import { SourceRuntimeStage } from './BookSourceRuntimeRouter';

export class StageWebRuntimeRequest {
  source: BookSource = new BookSource();
  book: Book | null = null;
  chapter: BookChapter | null = null;
  code: string = '';
  content: string = '';
  contextContent: string = '';
  baseUrl: string = '';
  variables: Record<string, string> = {};
  readerActionMode: boolean = false;
  networkTimeoutMs: number = 20000;
  maxResponseBytes: number = 8 * 1024 * 1024;
  maxTotalResponseBytes: number = 16 * 1024 * 1024;
  maxInputBytes: number = 20 * 1024 * 1024;
  maxRequestCount: number = 12;
  stage: string = SourceRuntimeStage.URL;
  ownerId: string = '';

  applyStageBudget(stage: string): void {
    this.stage = stage || SourceRuntimeStage.URL;
    if (this.stage === SourceRuntimeStage.SEARCH || this.stage === SourceRuntimeStage.EXPLORE) {
      this.maxResponseBytes = 2 * 1024 * 1024;
      this.maxTotalResponseBytes = 4 * 1024 * 1024;
      this.maxInputBytes = 8 * 1024 * 1024;
      this.maxRequestCount = 6;
    } else if (this.stage === SourceRuntimeStage.BOOK_INFO) {
      this.maxResponseBytes = 4 * 1024 * 1024;
      this.maxTotalResponseBytes = 6 * 1024 * 1024;
      this.maxInputBytes = 12 * 1024 * 1024;
      this.maxRequestCount = 8;
    } else if (this.stage === SourceRuntimeStage.TOC) {
      this.maxResponseBytes = 4 * 1024 * 1024;
      this.maxTotalResponseBytes = 8 * 1024 * 1024;
      this.maxInputBytes = 16 * 1024 * 1024;
      this.maxRequestCount = 8;
    } else if (this.stage === SourceRuntimeStage.CONTENT) {
      this.maxResponseBytes = 6 * 1024 * 1024;
      this.maxTotalResponseBytes = 10 * 1024 * 1024;
      this.maxInputBytes = 20 * 1024 * 1024;
      this.maxRequestCount = 8;
    } else {
      this.maxResponseBytes = 2 * 1024 * 1024;
      this.maxTotalResponseBytes = 4 * 1024 * 1024;
      this.maxInputBytes = 8 * 1024 * 1024;
      this.maxRequestCount = 4;
    }
  }
}

export class StageWebRuntimeResult {
  value: string = '';
  variable: string = '';
  bookVariable: string = '';
  bookType: string = '';
  chapterImgUrl: string = '';
  requestedUrl: string = '';
  toastMessage: string = '';
  errorMessage: string = '';
}

class StageWebRuntimeStep extends StageWebRuntimeResult {
  pendingAjax: string = '';
  pendingCookie: string = '';
  loginHeader: string = '';
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
  estimatedBytes: number = 0;
  resolve: ((value: StageWebRuntimeResult) => void) | null = null;
  reject: ((reason: Error) => void) | null = null;
}

/**
 * Shared ArkWeb host for complex non-login source scripts. Calls are serialized and every
 * network/cookie side effect is replayed through the native bridge before a result is accepted.
 */
export class BookSourceStageWebRuntime {
  private static readonly MAX_QUEUED_TASKS: number = 16;
  private static readonly MAX_QUEUED_BYTES: number = 24 * 1024 * 1024;
  private static readonly MAX_CACHE_SOURCES: number = 24;
  private static readonly MAX_CACHE_ENTRIES_PER_SOURCE: number = 128;
  private static readonly MAX_CACHE_BYTES_PER_SOURCE: number = 512 * 1024;
  private static readonly MAX_CACHE_BYTES_TOTAL: number = 4 * 1024 * 1024;
  private static readonly RECYCLE_TASK_INTERVAL: number = 40;
  private static instance: BookSourceStageWebRuntime | null = null;
  private controller: webview.WebviewController | null = null;
  private controllers: webview.WebviewController[] = [];
  private readyControllers: Set<webview.WebviewController> = new Set<webview.WebviewController>();
  private ready: boolean = false;
  private tasks: StageWebRuntimeTask[] = [];
  private queuedBytes: number = 0;
  private running: boolean = false;
  private activeTask: StageWebRuntimeTask | null = null;
  private activeHttpClient: HttpClient | null = null;
  private cancelledOwners: Set<string> = new Set<string>();
  private caches: Record<string, Record<string, string>> = {};
  private cacheTouchedAt: Record<string, number> = {};
  private resetHandler: (() => void) | null = null;
  private resetHandlerController: webview.WebviewController | null = null;
  private resetRequested: boolean = false;
  private completedTaskCount: number = 0;

  static get(): BookSourceStageWebRuntime {
    if (!BookSourceStageWebRuntime.instance) {
      BookSourceStageWebRuntime.instance = new BookSourceStageWebRuntime();
    }
    return BookSourceStageWebRuntime.instance;
  }

  setResetHandler(handler: (() => void) | null,
    controller: webview.WebviewController | null = this.controller): void {
    this.resetHandler = handler;
    this.resetHandlerController = handler ? controller : null;
  }

  clearResetHandler(controller: webview.WebviewController): void {
    if (this.resetHandlerController !== controller) return;
    this.resetHandler = null;
    this.resetHandlerController = null;
  }

  attach(controller: webview.WebviewController): void {
    this.controllers = this.controllers.filter((item: webview.WebviewController): boolean => item !== controller);
    this.controllers.push(controller);
    this.controller = controller;
    this.ready = this.readyControllers.has(controller);
    this.resetRequested = false;
    this.completedTaskCount = 0;
  }

  setReady(ready: boolean, controller: webview.WebviewController | null = null): void {
    const target = controller || this.controller;
    if (!target) return;
    if (ready) this.readyControllers.add(target);
    else this.readyControllers.delete(target);
    if (this.controller !== target) return;
    this.ready = ready;
    if (ready) this.startNext();
  }

  async waitUntilAvailable(timeoutMs: number = 3000): Promise<boolean> {
    if (this.isAvailable()) return true;
    const startedAt = Date.now();
    while (Date.now() - startedAt < Math.max(100, timeoutMs)) {
      await new Promise<void>((resolve) => setTimeout(resolve, 50));
      if (this.isAvailable()) return true;
    }
    return this.isAvailable();
  }

  detach(controller: webview.WebviewController): void {
    this.controllers = this.controllers.filter((item: webview.WebviewController): boolean => item !== controller);
    this.readyControllers.delete(controller);
    if (this.controller !== controller) return;
    this.controller = this.controllers.length > 0 ? this.controllers[this.controllers.length - 1] : null;
    this.ready = !!this.controller && this.readyControllers.has(this.controller);
    if (this.ready) this.startNext();
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
      const estimatedBytes = this.estimateRequestBytes(request);
      const inputLimit = Math.max(256 * 1024,
        Math.min(request.maxInputBytes || 20 * 1024 * 1024, 24 * 1024 * 1024));
      if (estimatedBytes > inputLimit) {
        reject(new Error(`书源脚本输入过大(${Math.ceil(estimatedBytes / 1024)} KiB)`));
        return;
      }
      if (this.tasks.length >= BookSourceStageWebRuntime.MAX_QUEUED_TASKS ||
        this.queuedBytes + estimatedBytes > BookSourceStageWebRuntime.MAX_QUEUED_BYTES) {
        reject(new Error('书源脚本队列繁忙，请稍后重试'));
        return;
      }
      const task = new StageWebRuntimeTask();
      task.request = request;
      task.estimatedBytes = estimatedBytes;
      task.resolve = resolve;
      task.reject = reject;
      this.tasks.push(task);
      this.queuedBytes += estimatedBytes;
      this.startNext();
    });
  }

  cancelOwner(ownerId: string): void {
    if (!ownerId) return;
    this.cancelledOwners.add(ownerId);
    const remaining: StageWebRuntimeTask[] = [];
    for (const task of this.tasks) {
      if (task.request.ownerId === ownerId) {
        this.queuedBytes = Math.max(0, this.queuedBytes - task.estimatedBytes);
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
    this.queuedBytes = Math.max(0, this.queuedBytes - task.estimatedBytes);
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
        this.completedTaskCount++;
        if (this.maybeRecycleController()) return;
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
      request.source.loginHeader = step.loginHeader;
      if (request.book) {
        request.book.variable = step.bookVariable;
        const bookType = Number(step.bookType);
        if (step.bookType && Number.isFinite(bookType)) request.book.type = bookType;
      }
      if (request.chapter && step.chapterImgUrl) {
        request.chapter.variable = this.setVariableValue(request.chapter.variable, 'imgUrl', step.chapterImgUrl);
      }
      try {
        cacheState = JSON.parse(step.cacheState || '{}') as Record<string, string>;
      } catch (_) {
        cacheState = {};
      }
      cacheState = this.storeCache(sourceKey, cacheState);
      request.source.loginInfo = this.mergeRuntimeState(request.source.loginInfo || '',
        step.javaState, step.sourceState);
      this.applyCookieOperations(step.cookieOperations, appliedOperations);
      if (step.pendingCookie) {
        cookies[step.pendingCookie] = CookieStore.getCookie(step.pendingCookie);
        continue;
      }
      if (step.pendingAjax) {
        requestCount++;
        const requestLimit = Math.max(1, Math.min(request.maxRequestCount || 12, 12));
        if (requestCount > requestLimit) throw new Error('书源脚本网络请求次数过多');
        const response = await this.fetch(request, step.pendingAjax);
        this.ensureNotCancelled(request);
        if (!response.success && response.statusCode === 0) {
          throw new Error(response.error || '书源脚本网络请求失败');
        }
        const responseBody = response.body || '';
        // ArkTS/ArkWeb exchange response bodies as UTF-16 strings. Count their in-memory
        // footprint instead of only character count so the cumulative guard remains useful.
        totalResponseBytes += responseBody.length * 2;
        const responseLimit = Math.max(64 * 1024,
          Math.min(request.maxResponseBytes || 8 * 1024 * 1024, 8 * 1024 * 1024));
        const totalLimit = Math.max(responseLimit,
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
          step.javaState, step.sourceState);
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
        this.quarantineController(controller, '书源脚本引擎响应超时');
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

  /** A timed-out renderer must not receive the next queued script. Rebuild the hidden Web host first. */
  private quarantineController(controller: webview.WebviewController, reason: string): void {
    this.readyControllers.delete(controller);
    this.controllers = this.controllers.filter((item: webview.WebviewController): boolean => item !== controller);
    if (this.controller === controller) {
      this.controller = this.controllers.length > 0 ? this.controllers[this.controllers.length - 1] : null;
      this.ready = !!this.controller && this.readyControllers.has(this.controller);
    }
    if (this.ready || this.resetRequested || !this.resetHandler ||
      this.resetHandlerController !== controller) return;
    this.resetRequested = true;
    console.warn('[StageWebRuntime] reset requested:', reason);
    this.resetHandler();
  }

  private maybeRecycleController(): boolean {
    if (this.completedTaskCount < BookSourceStageWebRuntime.RECYCLE_TASK_INTERVAL ||
      this.resetRequested || !this.controller || !this.resetHandler ||
      this.resetHandlerController !== this.controller) {
      return false;
    }
    const controller = this.controller;
    const handler = this.resetHandler;
    this.readyControllers.delete(controller);
    this.controllers = this.controllers.filter((item: webview.WebviewController): boolean => item !== controller);
    this.controller = this.controllers.length > 0 ? this.controllers[this.controllers.length - 1] : null;
    this.ready = !!this.controller && this.readyControllers.has(this.controller);
    this.resetRequested = true;
    this.completedTaskCount = 0;
    console.info('[StageWebRuntime] recycle requested after task budget');
    handler();
    return true;
  }

  private estimateRequestBytes(request: StageWebRuntimeRequest): number {
    let total = this.utf16Bytes(request.content);
    if (request.contextContent && request.contextContent !== request.content) {
      total += this.utf16Bytes(request.contextContent);
    }
    total += this.utf16Bytes(request.code);
    total += this.utf16Bytes(request.source.jsLib);
    total += this.utf16Bytes(request.source.header);
    total += this.utf16Bytes(request.source.loginHeader);
    total += this.utf16Bytes(request.source.loginInfo);
    total += this.utf16Bytes(request.source.variable);
    try {
      total += this.utf16Bytes(JSON.stringify(request.variables || {}));
    } catch (_) {}
    return total;
  }

  private utf16Bytes(value: string): number {
    return (value || '').length * 2;
  }

  private storeCache(sourceKey: string, rawState: Record<string, string>): Record<string, string> {
    const state: Record<string, string> = {};
    const keys = Object.keys(rawState || {});
    const selectedKeys: string[] = [];
    let bytes = 0;
    for (let i = keys.length - 1; i >= 0 &&
      selectedKeys.length < BookSourceStageWebRuntime.MAX_CACHE_ENTRIES_PER_SOURCE; i--) {
      const key = keys[i];
      const value = String(rawState[key] || '');
      const entryBytes = this.utf16Bytes(key) + this.utf16Bytes(value);
      if (entryBytes > BookSourceStageWebRuntime.MAX_CACHE_BYTES_PER_SOURCE ||
        bytes + entryBytes > BookSourceStageWebRuntime.MAX_CACHE_BYTES_PER_SOURCE) {
        continue;
      }
      selectedKeys.unshift(key);
      bytes += entryBytes;
    }
    for (const key of selectedKeys) state[key] = String(rawState[key] || '');
    this.caches[sourceKey] = state;
    this.cacheTouchedAt[sourceKey] = Date.now();
    this.pruneCaches();
    return this.caches[sourceKey] || {};
  }

  private pruneCaches(): void {
    const sourceKeys = Object.keys(this.caches);
    sourceKeys.sort((left: string, right: string): number =>
      (this.cacheTouchedAt[left] || 0) - (this.cacheTouchedAt[right] || 0));
    let totalBytes = 0;
    const sizes: Record<string, number> = {};
    for (const sourceKey of sourceKeys) {
      let sourceBytes = 0;
      const state = this.caches[sourceKey] || {};
      for (const key of Object.keys(state)) {
        sourceBytes += this.utf16Bytes(key) + this.utf16Bytes(String(state[key] || ''));
      }
      sizes[sourceKey] = sourceBytes;
      totalBytes += sourceBytes;
    }
    while (sourceKeys.length > BookSourceStageWebRuntime.MAX_CACHE_SOURCES ||
      totalBytes > BookSourceStageWebRuntime.MAX_CACHE_BYTES_TOTAL) {
      const oldest = sourceKeys.shift();
      if (!oldest) break;
      totalBytes = Math.max(0, totalBytes - (sizes[oldest] || 0));
      delete this.caches[oldest];
      delete this.cacheTouchedAt[oldest];
    }
  }

  private buildScript(request: StageWebRuntimeRequest, responses: Record<string, string>,
    cookies: Record<string, string>, cacheState: Record<string, string>, fixedNow: number, randomSeed: number): string {
    const bookVariables = this.parseRecord(request.book ? request.book.variable : '');
    const loginInfo = this.parseLoginInfo(request.source.loginInfo || '');
    const javaState = this.parseRuntimeJavaState(request.source.loginInfo || '');
    const sourceState = this.parseRuntimeObjectState(request.source.loginInfo || '', 'source');
    const contextContent = request.contextContent && request.contextContent !== request.content ?
      request.contextContent : '';
    const state = JSON.stringify({
      sourceUrl: request.source.bookSourceUrl || '',
      sourceName: request.source.bookSourceName || '',
      sourceHeader: request.source.header || '',
      sourceLoginHeader: request.source.loginHeader || '',
      variable: request.source.variable || '',
      content: request.content || '',
      contextContent: contextContent,
      baseUrl: request.baseUrl || request.source.bookSourceUrl || '',
      variables: request.variables || {},
      bookVariables: bookVariables,
      bookType: request.book ? request.book.type : 0,
      chapterTitle: request.chapter ? request.chapter.title : '',
      chapterImgUrl: request.chapter ? this.variableValue(request.chapter.variable, 'imgUrl') : '',
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
    const library = this.normalizeScript(request.source.jsLib || '');
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
      `let contextValue=S.contextContent||S.content;function pathValue(path){try{let value=typeof contextValue==='string'?JSON.parse(contextValue):contextValue;` +
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
      `putLoginHeader:function(v){S.sourceLoginHeader=String(v??'');return S.sourceLoginHeader;},` +
      `removeLoginHeader:function(){S.sourceLoginHeader='';return '';},` +
      `getHeaderMap:function(){try{return JSON.parse(S.sourceHeader||'{}');}catch(e){return {};}} ,` +
      `getVariable:function(){return S.variable||'';},setVariable:function(v){S.variable=String(v??'');return S.variable;},` +
      `get:function(k){return sourceData[String(k??'')]??'';},put:function(k,v){sourceData[String(k??'')]=v;return v;},` +
      `putLoginInfo:function(v){if(typeof v==='string'){try{v=JSON.parse(v);}catch(e){return v;}}` +
      `if(v&&typeof v==='object')Object.assign(loginMap,v);return v;},` +
      `getLoginInfo:function(k){return arguments.length?(loginMap[k]??''):JSON.stringify(loginMap);},` +
      `getLoginInfoMap:function(){return loginMap;}};` +
      `const book={type:Number(S.bookType||0),getVariable:function(k){return bookData[String(k??'')]??'';},` +
      `putVariable:function(k,v){bookData[String(k??'')]=String(v??'');return v;}};` +
      `const chapter={title:String(S.chapterTitle||''),imgUrl:String(S.chapterImgUrl||''),` +
      `update:function(){return true;}};` +
      `const cache={get:function(k){return cacheData[k]??null;},getFromMemory:function(k){return cacheData[k]??null;},` +
      `put:function(k,v){cacheData[k]=v;return v;},putMemory:function(k,v){cacheData[k]=v;return v;},` +
      `delete:function(k){delete cacheData[k];return true;}};` +
      `function stableDeviceId(){let value=String(javaData.__legadoHarmonyDeviceId||'').trim();` +
      `if(!/^[0-9a-f]{16}$/i.test(value)){value='';for(let i=0;i<16;i++)value+=Math.floor(Math.random()*16).toString(16);` +
      `javaData.__legadoHarmonyDeviceId=value;}return value;}` +
      `const java={ajax:function(v){v=String(v??'');if(Object.prototype.hasOwnProperty.call(S.responses,v))return S.responses[v];` +
      `if(!pending)pending=v;return '{}';},put:function(k,v){javaData[String(k??'')]=v;return v;},` +
      `get:function(k){k=String(k??'');return Object.prototype.hasOwnProperty.call(javaData,k)?javaData[k]:null;},` +
      `log:function(v){return v===undefined?'':v;},logType:function(v){return v===undefined?'':v;},` +
      `toast:function(v){toast=String(v??'');return toast;},longToast:function(v){toast=String(v??'');return toast;},` +
      `androidId:stableDeviceId,deviceID:function(){if(S.readerActionMode)return stableDeviceId();` +
      `throw new Error('deviceID unavailable');},qread:function(){throw new Error('qread unavailable');},` +
      `base64Encode:b64e,base64EncodeToString:b64e,base64Decode:b64d,base64DecodeToString:b64d,` +
      `hexDecodeToString:hexD,hexEncodeToString:hexE,getCookie:function(k){return cookie.getCookie(k);},` +
      `__setContextContent:function(v){contextValue=v;globalThis.result=typeof v==='string'?v:JSON.stringify(v);return true;},` +
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
      `globalThis.source=source;globalThis.book=book;globalThis.chapter=chapter;globalThis.java=java;` +
      `globalThis.cache=cache;globalThis.cookie=cookie;` +
      `globalThis.Packages=Packages;globalThis.baseUrl=S.baseUrl;globalThis.result=S.content;globalThis.src=S.content;` +
      `globalThis.title=S.chapterTitle||'';Object.keys(bookData).forEach(function(k){` +
      `if(/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(k)&&globalThis[k]===undefined)globalThis[k]=bookData[k];});` +
      `Object.keys(S.variables||{}).forEach(function(k){globalThis[k]=S.variables[k];});` +
      `let evaluated;try{evaluated=(function(){return eval(dec('${codeBase64}'));}).call(globalThis);}` +
      `catch(e){error=String((e&&e.name?e.name+': ':'')+((e&&e.message)||e||'脚本执行失败')+(e&&e.stack?'\\n'+e.stack:''));}` +
      `function text(v){if(typeof v==='string')return v;if(v===undefined||v===null)return '';try{return JSON.stringify(v);}catch(e){return String(v);}}` +
      `const value=text(evaluated)||text(globalThis.result);` +
      `return encodeURIComponent(JSON.stringify({pendingAjax:pending,pendingCookie:pendingCookie,` +
      `cookieOperations:JSON.stringify(cookieOps),variable:S.variable||'',loginHeader:S.sourceLoginHeader||'',` +
      `bookVariable:JSON.stringify(bookData),bookType:String(book.type??''),chapterImgUrl:String(chapter.imgUrl??''),` +
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
      step.loginHeader = String(record['loginHeader'] || '');
      step.bookVariable = String(record['bookVariable'] || '{}');
      step.bookType = String(record['bookType'] || '');
      step.chapterImgUrl = String(record['chapterImgUrl'] || '');
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

  private variableValue(raw: string, key: string): string {
    try {
      const record = JSON.parse(raw || '{}') as Record<string, Object>;
      return String(record[key] || '');
    } catch (_) {
      return '';
    }
  }

  private setVariableValue(raw: string, key: string, value: string): string {
    let record: Record<string, Object> = {};
    try {
      record = JSON.parse(raw || '{}') as Record<string, Object>;
    } catch (_) {
      record = {};
    }
    record[key] = value;
    return JSON.stringify(record);
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

  private normalizeScript(script: string): string {
    // Rhino/Legado sources sometimes redeclare a function argument while applying a default:
    // `function f(sourceUrl) { let sourceUrl = sourceUrl || host; }`. Chromium correctly rejects
    // this as a duplicate lexical declaration. Rewriting only the self-fallback declaration keeps
    // the intended assignment and also covers the same legacy pattern with other argument names.
    return (script || '').replace(/\b(?:let|const)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*\1\s*\|\|/g,
      (_match: string, name: string): string => `${name} = ${name} ||`);
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

  private mergeRuntimeState(raw: string, javaStateRaw: string, sourceStateRaw: string): string {
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
    // Script cache is a bounded in-memory acceleration structure. Persisting it inside loginInfo
    // duplicated potentially large values in the database and in every later runtime request.
    delete runtime['cache'];
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
