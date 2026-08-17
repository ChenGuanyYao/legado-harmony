import { BookSource } from '../../model/data/Book';
import { BookSourceStageWebRuntime, StageWebRuntimeRequest } from '../book/BookSourceStageWebRuntime';
import { BookUrlResolver } from '../book/BookUrlResolver';
import { CooperativeCancellationToken, CooperativeScheduler } from '../concurrency/CooperativeScheduler';
import { AnalyzeRule } from './AnalyzeRule';
import { RuleContext } from './RuleContext';
import { RuleBatchExecutionRequest, RuleBatchExecutionResult, RuleFieldRequest } from './RuleExecutionModels';
import { QuickJsAsyncRouter } from '../script/QuickJsAsyncRouter';
import { QuickJsScriptRuntime } from '../script/QuickJsScriptRuntime';
import { QuickJsObservationContext } from '../script/QuickJsRuntimeStatus';

/**
 * The single public execution gateway for rule parsing.
 *
 * Phase one centralizes cancellation, timing, cooperative yielding and full-JS routing. The
 * synchronous lightweight branch is intentionally kept behind this boundary so it can be moved
 * to a Worker without changing search/explore/detail call sites again.
 */
export class RuleExecutionService {
  private static instance: RuleExecutionService | null = null;
  private cancelledOwners: Set<string> = new Set<string>();
  private activeTokens: Record<string, CooperativeCancellationToken[]> = {};

  static get(): RuleExecutionService {
    if (!RuleExecutionService.instance) RuleExecutionService.instance = new RuleExecutionService();
    return RuleExecutionService.instance;
  }

  cancelOwner(ownerId: string): void {
    if (!ownerId) return;
    this.cancelledOwners.add(ownerId);
    const tokens = this.activeTokens[ownerId] || [];
    for (const token of tokens) token.cancel('规则解析任务已取消');
    BookSourceStageWebRuntime.get().cancelOwner(ownerId);
  }

  clearOwner(ownerId: string): void {
    if (!ownerId) return;
    this.cancelledOwners.delete(ownerId);
    delete this.activeTokens[ownerId];
    BookSourceStageWebRuntime.get().clearOwner(ownerId);
  }

  async executeBatch(request: RuleBatchExecutionRequest): Promise<RuleBatchExecutionResult> {
    const result = new RuleBatchExecutionResult();
    const startedAt = Date.now();
    const token = new CooperativeCancellationToken();
    this.registerToken(request.ownerId, token);
    try {
      if (request.ownerId && this.cancelledOwners.has(request.ownerId)) token.cancel('规则解析任务已取消');
      token.throwIfCancelled();
      const deadlineAt = startedAt + Math.max(500, request.timeoutMs || 15000);
      const slice = CooperativeScheduler.createTimeSlice(request.uiSliceMs);
      const itemChunkSize = Math.max(4, Math.min(Math.round(request.itemChunkSize || 16), 64));
      const fullJsValues: Record<string, string[]> = {};

      for (const field of request.fields) {
        const code = this.extractStandaloneJsCode(field.rule);
        const postProcessor = code === null ? this.extractPostProcessorJs(field.rule) : null;
        if (code === null && postProcessor === null) continue;
        try {
          if (code !== null) {
            fullJsValues[field.name] = QuickJsScriptRuntime.isPureExpressionCandidate(code) ?
              await this.executeRoutedPureJsFieldBatch(request, field, code, token) :
              await this.executeFullJsFieldBatch(request, field, code, token);
          } else if (postProcessor !== null) {
            fullJsValues[field.name] = await this.executePostProcessorJsFieldBatch(request, field,
              postProcessor.baseRule, postProcessor.code, token);
          }
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error || '完整脚本执行失败');
          result.errors.push(`${field.name}: ${message}`);
          fullJsValues[field.name] = [];
        }
        token.throwIfCancelled();
        this.throwIfDeadlineExceeded(deadlineAt, request.stage);
      }

      for (let itemIndex = 0; itemIndex < request.contents.length; itemIndex++) {
        if (itemIndex > 0 && itemIndex % itemChunkSize === 0) {
          await CooperativeScheduler.yieldToNextUiFrame();
          result.yieldedCount++;
          token.throwIfCancelled();
        }
        if (await slice.checkpoint(token)) result.yieldedCount++;
        this.throwIfDeadlineExceeded(deadlineAt, request.stage);
        const content = request.contents[itemIndex] || '';
        const analyzer = new AnalyzeRule(content, request.baseUrl);
        this.seedSourceVariables(analyzer.getContext(), request.source, request.contextValues);
        const itemValues: Record<string, string> = {};
        for (const field of request.fields) {
          token.throwIfCancelled();
          analyzer.setQuickJsObservation(this.observationContext(request, field));
          const jsValues = fullJsValues[field.name];
          if (jsValues !== undefined) {
            const value = itemIndex < jsValues.length ? jsValues[itemIndex] : '';
            itemValues[field.name] = field.resolveUrl ? BookUrlResolver.resolve(value, request.baseUrl) : value;
          } else {
            const fieldStartedAt = Date.now();
            if (field.listResult) {
              itemValues[field.name] = JSON.stringify(analyzer.getStringList(field.rule));
            } else if (field.joinMatches) {
              itemValues[field.name] = analyzer.getString(field.rule);
            } else {
              itemValues[field.name] = field.resolveUrl ? analyzer.getString(field.rule, true) :
                analyzer.analyzeFirst(field.rule);
            }
            CooperativeScheduler.reportSynchronousOperation(`rule/${request.stage}/${field.name}`,
              Date.now() - fieldStartedAt, `input=${content.length}`);
          }
          if (await slice.checkpoint(token)) result.yieldedCount++;
          this.throwIfDeadlineExceeded(deadlineAt, request.stage);
        }
        result.values.push(itemValues);
        // Static source fields (especially jsLib) are re-seeded for every stage and must not be
        // copied into every item's persistent context.
        result.contextValues.push(analyzer.getContext().toPersistentJson());
      }
      return result;
    } catch (error) {
      if (token.isCancelled()) {
        result.cancelled = true;
        result.errors.push(token.reason());
        return result;
      }
      throw error;
    } finally {
      result.elapsedMs = Math.max(0, Date.now() - startedAt);
      this.unregisterToken(request.ownerId, token);
      if (result.elapsedMs >= CooperativeScheduler.DANGEROUS_OPERATION_MS) {
        console.info(`[RuleExecution] ${request.stage || 'unknown'} items=${request.contents.length} ` +
          `fields=${request.fields.length} elapsed=${result.elapsedMs}ms yields=${result.yieldedCount}`);
      }
    }
  }

  private async executeRoutedPureJsFieldBatch(request: RuleBatchExecutionRequest, field: RuleFieldRequest,
    code: string, token: CooperativeCancellationToken): Promise<string[]> {
    let legacyValuesPromise: Promise<string[]> | null = null;
    const getLegacyValues = (): Promise<string[]> => {
      if (!legacyValuesPromise) {
        legacyValuesPromise = this.executeFullJsFieldBatch(request, field, code, token);
      }
      return legacyValuesPromise;
    };
    const values: string[] = [];
    for (let index = 0; index < request.contents.length; index++) {
      token.throwIfCancelled();
      const content = request.contents[index] || '';
      const bindings: Record<string, number | string | boolean> = {};
      for (const key of Object.keys(request.contextValues)) {
        const value = request.contextValues[key] || '';
        bindings[key] = /^-?(?:\d+\.?\d*|\.\d+)$/.test(value) ? Number(value) : value;
      }
      bindings['result'] = content;
      bindings['src'] = content;
      bindings['$'] = content;
      bindings['baseUrl'] = request.baseUrl || request.source.bookSourceUrl || '';
      const itemIndex = index;
      const value = await QuickJsAsyncRouter.evaluate(code, bindings, async (): Promise<string> => {
        const legacyValues = await getLegacyValues();
        return itemIndex < legacyValues.length ? legacyValues[itemIndex] : '';
      }, Math.min(200, Math.max(40, Math.round((request.timeoutMs || 15000) /
        Math.max(1, request.contents.length)))), this.observationContext(request, field));
      values.push(value);
    }
    return values;
  }

  private async executeFullJsFieldBatch(request: RuleBatchExecutionRequest, field: RuleFieldRequest,
    code: string, token: CooperativeCancellationToken): Promise<string[]> {
    token.throwIfCancelled();
    const runtime = BookSourceStageWebRuntime.get();
    if (!runtime.isAvailable()) {
      const available = await runtime.waitUntilAvailable(5000);
      if (!available) throw new Error('完整脚本运行环境未就绪');
    }
    const runtimeRequest = new StageWebRuntimeRequest();
    runtimeRequest.applyStageBudget(request.stage);
    runtimeRequest.source = request.source;
    runtimeRequest.book = request.book;
    runtimeRequest.chapter = request.chapter;
    runtimeRequest.readerActionMode = request.readerActionMode;
    runtimeRequest.content = JSON.stringify(request.contents.map((item: string): Object | string => {
      try { return JSON.parse(item) as Object; } catch (_) { return item; }
    }));
    // The runtime falls back to content when contextContent is empty. Keeping only one copy avoids
    // serializing every search item twice before it crosses into ArkWeb.
    runtimeRequest.contextContent = '';
    runtimeRequest.baseUrl = request.baseUrl || request.source.bookSourceUrl;
    runtimeRequest.variables = request.contextValues;
    runtimeRequest.ownerId = request.ownerId;
    // Android Legado accepts a common field-script idiom where the script builds `let info = ...`
    // and a final conditional statement has no completion value.  A plain WebView eval returns
    // undefined in that case.  Bind that well-known intro accumulator to the surrounding field
    // scope so it can be used only as a fallback; an explicit eval result (including <usehtml>)
    // still wins.  This is rule-language compatibility and is not tied to any source or site.
    // Prefer the top-level template accumulator. Some rules also have a nested helper containing
    // `let info = ""`; capturing that local variable would leave the actual intro accumulator
    // scoped inside eval and produce an empty result.
    const introInfoDeclaration = /\b(?:let|const|var)\s+info\s*=\s*(?=`)/;
    const capturesIntroInfo = field.name === 'intro' && introInfoDeclaration.test(code);
    const compatibleCode = capturesIntroInfo ?
      code.replace(/\b(?:let|const|var)\s+(?=info\s*=\s*`)/, '') : code;
    runtimeRequest.code = `const __fieldItems=JSON.parse(result||'[]');const __fieldCodeTemplate=${JSON.stringify(compatibleCode)};` +
      `const __fieldList=${field.listResult ? 'true' : 'false'};` +
      `JSON.stringify(__fieldItems.map(function(__fieldItem){java.__setContextContent(__fieldItem);` +
      `try{const $=__fieldItem;let info;const __fieldCode=__fieldCodeTemplate.replace(/\\{\\{([\\s\\S]*?)\\}\\}/g,` +
      `function(_all,__expr){try{const __inner=eval(__expr);return __inner==null?'':String(__inner);}catch(__innerError){return '';}});` +
      `let __fieldValue=eval(__fieldCode);` +
      `${capturesIntroInfo ? `if(__fieldValue==null&&info!=null)__fieldValue=info;` : ''}` +
      `if(__fieldValue==null)return '';` +
      `return __fieldList?JSON.stringify(Array.isArray(__fieldValue)?__fieldValue:[__fieldValue]):String(__fieldValue);}` +
      `catch(__fieldError){return '__LEGADO_FIELD_ERROR__'+String((__fieldError&&__fieldError.name?` +
      `__fieldError.name+': ':'')+((__fieldError&&__fieldError.message)||__fieldError||'脚本执行失败'));}}));`;
    const runtimeResult = await runtime.execute(runtimeRequest);
    token.throwIfCancelled();
    const parsed = JSON.parse(runtimeResult.value || '[]') as Object;
    if (!Array.isArray(parsed)) throw new Error('完整脚本批量结果格式错误');
    const values = (parsed as Object[]).map((value: Object): string => String(value || ''));
    const fieldError = values.find((value: string): boolean => value.startsWith('__LEGADO_FIELD_ERROR__'));
    if (fieldError) throw new Error(fieldError.substring('__LEGADO_FIELD_ERROR__'.length));
    return values;
  }

  /**
   * Android-style combined rules first extract/template a value and then run an `@js:` suffix
   * with that value exposed as `result`. Keep the original item as the JSON/path context (`$`,
   * `src`, java.getString) while the full script runs in the bounded host runtime.
   */
  private async executePostProcessorJsFieldBatch(request: RuleBatchExecutionRequest, field: RuleFieldRequest,
    baseRule: string, code: string, token: CooperativeCancellationToken): Promise<string[]> {
    const baseValues: string[] = [];
    for (let index = 0; index < request.contents.length; index++) {
      token.throwIfCancelled();
      const analyzer = new AnalyzeRule(request.contents[index] || '', request.baseUrl);
      this.seedSourceVariables(analyzer.getContext(), request.source, request.contextValues);
      baseValues.push(field.listResult ? JSON.stringify(analyzer.getStringList(baseRule)) :
        (field.joinMatches ? analyzer.getString(baseRule) : analyzer.analyzeFirst(baseRule)));
    }

    const runtime = BookSourceStageWebRuntime.get();
    if (!runtime.isAvailable()) {
      const available = await runtime.waitUntilAvailable(5000);
      if (!available) throw new Error('完整脚本运行环境未就绪');
    }
    const runtimeRequest = new StageWebRuntimeRequest();
    runtimeRequest.applyStageBudget(request.stage);
    runtimeRequest.source = request.source;
    runtimeRequest.book = request.book;
    runtimeRequest.chapter = request.chapter;
    runtimeRequest.readerActionMode = request.readerActionMode;
    runtimeRequest.content = JSON.stringify(request.contents.map((item: string): Object | string => {
      try { return JSON.parse(item) as Object; } catch (_) { return item; }
    }));
    runtimeRequest.contextContent = '';
    runtimeRequest.baseUrl = request.baseUrl || request.source.bookSourceUrl;
    runtimeRequest.variables = request.contextValues;
    runtimeRequest.ownerId = request.ownerId;
    runtimeRequest.code = `const __postItems=JSON.parse(result||'[]');` +
      `const __postBases=${JSON.stringify(baseValues)};const __postTemplate=${JSON.stringify(code)};` +
      `JSON.stringify(__postItems.map(function(__postItem,__postIndex){java.__setContextContent(__postItem);` +
      `try{const $=__postItem;const __postSource=typeof __postItem==='string'?__postItem:JSON.stringify(__postItem);` +
      `globalThis.src=__postSource;globalThis.result=String(__postBases[__postIndex]||'').replace(` +
      `/\\{\\{([\\s\\S]*?)\\}\\}/g,function(_all,__expr){try{const __inner=eval(__expr);` +
      `return __inner==null?'':String(__inner);}catch(__baseInnerError){return '';}});` +
      `const __postCode=__postTemplate.replace(/\\{\\{([\\s\\S]*?)\\}\\}/g,function(_all,__expr){` +
      `try{const __inner=eval(__expr);return __inner==null?'':String(__inner);}catch(__innerError){return '';}});` +
      `const __postValue=eval(__postCode);if(__postValue==null)return String(globalThis.result||'');` +
      `return ${field.listResult ? `JSON.stringify(Array.isArray(__postValue)?__postValue:[__postValue])` :
        `String(__postValue)`};}catch(__postError){return '__LEGADO_FIELD_ERROR__'+` +
      `String((__postError&&__postError.name?__postError.name+': ':'')+` +
      `((__postError&&__postError.message)||__postError||'脚本执行失败'));}}));`;
    const runtimeResult = await runtime.execute(runtimeRequest);
    token.throwIfCancelled();
    const parsed = JSON.parse(runtimeResult.value || '[]') as Object;
    if (!Array.isArray(parsed)) throw new Error('完整脚本批量结果格式错误');
    const values = (parsed as Object[]).map((value: Object): string => String(value || ''));
    const fieldError = values.find((value: string): boolean => value.startsWith('__LEGADO_FIELD_ERROR__'));
    if (fieldError) throw new Error(fieldError.substring('__LEGADO_FIELD_ERROR__'.length));
    return values;
  }

  private extractStandaloneJsCode(rule: string): string | null {
    const value = (rule || '').trim();
    const tagged = value.match(/^<js>([\s\S]*?)<\/js>$/i);
    if (tagged) return (tagged[1] || '').trim();
    if (/^@?js:/i.test(value)) return value.replace(/^@?js:\s*/i, '');
    return null;
  }

  private observationContext(request: RuleBatchExecutionRequest,
    field: RuleFieldRequest): QuickJsObservationContext {
    const observation = new QuickJsObservationContext();
    observation.sourceUrl = request.source.bookSourceUrl || '';
    observation.sourceName = request.source.bookSourceName || observation.sourceUrl;
    observation.stage = request.stage || '';
    if (field.name === 'value' || !request.stage) observation.field = field.name;
    else observation.field = `${request.stage}.${field.name}`;
    return observation;
  }

  private extractPostProcessorJs(rule: string): { baseRule: string, code: string } | null {
    const value = rule || '';
    let templateDepth = 0;
    for (let index = 0; index < value.length - 3; index++) {
      if (value.substring(index, index + 2) === '{{') {
        templateDepth++;
        index++;
        continue;
      }
      if (value.substring(index, index + 2) === '}}' && templateDepth > 0) {
        templateDepth--;
        index++;
        continue;
      }
      if (templateDepth === 0 && value.substring(index, index + 4).toLowerCase() === '@js:') {
        const baseRule = value.substring(0, index).trimEnd();
        const code = value.substring(index + 4).trim();
        // Replacement processors following JS need an additional ordered stage. Leave those on
        // the legacy path until that stage is represented explicitly rather than guessing where
        // JavaScript string literals end.
        if (!baseRule || !code || code.includes('##')) return null;
        return { baseRule: baseRule, code: code };
      }
    }
    return null;
  }

  private seedSourceVariables(ctx: RuleContext, source: BookSource,
    contextValues: Record<string, string>): void {
    ctx.put('source.bookSourceUrl', source.bookSourceUrl || '');
    ctx.put('bookSourceUrl', source.bookSourceUrl || '');
    ctx.put('source.bookSourceName', source.bookSourceName || '');
    ctx.put('bookSourceName', source.bookSourceName || '');
    ctx.put('source.bookSourceGroup', source.bookSourceGroup || '');
    ctx.put('bookSourceGroup', source.bookSourceGroup || '');
    ctx.put('source.bookSourceComment', source.bookSourceComment || '');
    ctx.put('bookSourceComment', source.bookSourceComment || '');
    ctx.put('source.jsLib', source.jsLib || '');
    ctx.put('jsLib', source.jsLib || '');
    ctx.put('source.variable', source.variable || '');
    for (const key of Object.keys(contextValues)) ctx.put(key, contextValues[key] || '');
  }

  private throwIfDeadlineExceeded(deadlineAt: number, stage: string): void {
    if (Date.now() > deadlineAt) throw new Error(`${stage || '规则'}解析超过时间预算`);
  }

  private registerToken(ownerId: string, token: CooperativeCancellationToken): void {
    if (!ownerId) return;
    const tokens = this.activeTokens[ownerId] || [];
    tokens.push(token);
    this.activeTokens[ownerId] = tokens;
  }

  private unregisterToken(ownerId: string, token: CooperativeCancellationToken): void {
    if (!ownerId) return;
    const tokens = this.activeTokens[ownerId] || [];
    this.activeTokens[ownerId] = tokens.filter((item: CooperativeCancellationToken): boolean => item !== token);
    if (this.activeTokens[ownerId].length === 0) delete this.activeTokens[ownerId];
  }
}
