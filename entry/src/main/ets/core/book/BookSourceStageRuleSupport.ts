import { BookSource } from '../../model/data/Book';
import { AnalyzeRule } from '../rule/AnalyzeRule';
import { BookSourceRuntimeRouter, SourceRuntimeStage } from './BookSourceRuntimeRouter';
import { BookSourceStageWebRuntime, StageWebRuntimeRequest } from './BookSourceStageWebRuntime';

class EmbeddedStageRule {
  baseRule: string = '';
  code: string = '';
}

/** Full-JavaScript post-processing for list rules such as `jsonPath <js>...</js>`. */
export class BookSourceStageRuleSupport {
  static async getElements(source: BookSource, content: string, baseUrl: string,
    rawRule: string, stage: string = SourceRuntimeStage.SEARCH): Promise<string[] | null> {
    const embedded = this.splitEmbeddedRule(rawRule || '');
    if (!embedded || !embedded.baseRule || !embedded.code) return null;
    const decision = BookSourceRuntimeRouter.decide(stage, `${source.jsLib || ''}\n${embedded.code}`);
    const runtime = BookSourceStageWebRuntime.get();
    if (decision.runtime !== 'arkweb' || !runtime.isAvailable()) return null;

    const baseItems = new AnalyzeRule(content || '', baseUrl).getElements(embedded.baseRule);
    const values: Object[] = [];
    for (const item of baseItems) {
      try {
        values.push(JSON.parse(item) as Object);
      } catch (_) {
        values.push(item);
      }
    }
    const request = new StageWebRuntimeRequest();
    request.source = source;
    request.content = JSON.stringify(values);
    request.contextContent = content || '';
    request.baseUrl = baseUrl || source.bookSourceUrl;
    request.code = embedded.code;
    try {
      const result = await runtime.execute(request);
      const parsed = JSON.parse(result.value || '[]') as Object;
      if (!Array.isArray(parsed)) return null;
      // A stage runtime may complete without throwing while still losing the evaluated expression
      // (for example when a source library exports top-level helpers through `this`). Let the legacy
      // analyzer execute the same embedded script before accepting an unexpected empty list.
      if (parsed.length === 0 && baseItems.length > 0) return null;
      return parsed.map((item: Object): string => typeof item === 'string' ? item : JSON.stringify(item));
    } catch (error) {
      console.warn('[StageRule] list post-process failed, fallback legacy:', source.bookSourceName, error);
      return null;
    }
  }

  private static splitEmbeddedRule(rawRule: string): EmbeddedStageRule | null {
    const raw = (rawRule || '').trim();
    const block = raw.match(/^([\s\S]*?)<js>([\s\S]*?)<\/js>\s*$/i);
    if (block && block[1].trim() && block[2].trim()) {
      const result = new EmbeddedStageRule();
      result.baseRule = block[1].trim();
      result.code = block[2].trim();
      return result;
    }
    const suffixIndex = raw.indexOf('@js:');
    if (suffixIndex > 0) {
      const result = new EmbeddedStageRule();
      result.baseRule = raw.substring(0, suffixIndex).trim();
      result.code = raw.substring(suffixIndex + 4).trim();
      return result.baseRule && result.code ? result : null;
    }
    return null;
  }
}
