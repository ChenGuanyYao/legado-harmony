import { BookSource } from '../../model/data/Book';
import { BookSourceStageWebRuntime, StageWebRuntimeRequest } from '../book/BookSourceStageWebRuntime';
import { BookUrlResolver } from '../book/BookUrlResolver';
import { CooperativeCancellationToken, CooperativeScheduler } from '../concurrency/CooperativeScheduler';
import { AnalyzeRule } from './AnalyzeRule';
import { RuleContext } from './RuleContext';
import { RuleBatchExecutionRequest, RuleBatchExecutionResult, RuleFieldRequest } from './RuleExecutionModels';

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
        if (code === null) continue;
        try {
          fullJsValues[field.name] = await this.executeFullJsFieldBatch(request, field, code, token);
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
          const jsValues = fullJsValues[field.name];
          if (jsValues !== undefined) {
            const value = itemIndex < jsValues.length ? jsValues[itemIndex] : '';
            itemValues[field.name] = field.resolveUrl ? BookUrlResolver.resolve(value, request.baseUrl) : value;
          } else {
            const fieldStartedAt = Date.now();
            if (field.listResult) {
              itemValues[field.name] = JSON.stringify(analyzer.getStringList(field.rule));
            } else if (field.joinMatches) {
              itemValues[field.name] = analyzer.getStringList(field.rule)
                .map((value: string): string => value.trim())
                .filter((value: string): boolean => !!value)
                .join('\n\n');
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
    runtimeRequest.code = `const __fieldItems=JSON.parse(result||'[]');const __fieldCodeTemplate=${JSON.stringify(code)};` +
      `const __fieldList=${field.listResult ? 'true' : 'false'};` +
      `JSON.stringify(__fieldItems.map(function(__fieldItem){java.__setContextContent(__fieldItem);` +
      `try{const $=__fieldItem;const __fieldCode=__fieldCodeTemplate.replace(/\\{\\{([\\s\\S]*?)\\}\\}/g,` +
      `function(_all,__expr){try{const __inner=eval(__expr);return __inner==null?'':String(__inner);}catch(__innerError){return '';}});` +
      `const __fieldValue=eval(__fieldCode);if(__fieldValue==null)return '';` +
      `return __fieldList?JSON.stringify(Array.isArray(__fieldValue)?__fieldValue:[__fieldValue]):String(__fieldValue);}` +
      `catch(__fieldError){return '';}}));`;
    const runtimeResult = await runtime.execute(runtimeRequest);
    token.throwIfCancelled();
    const parsed = JSON.parse(runtimeResult.value || '[]') as Object;
    if (!Array.isArray(parsed)) throw new Error('完整脚本批量结果格式错误');
    return (parsed as Object[]).map((value: Object): string => String(value || ''));
  }

  private extractStandaloneJsCode(rule: string): string | null {
    const value = (rule || '').trim();
    const tagged = value.match(/^<js>([\s\S]*?)<\/js>$/i);
    if (tagged) return (tagged[1] || '').trim();
    if (/^@?js:/i.test(value)) return value.replace(/^@?js:\s*/i, '');
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
