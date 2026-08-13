import taskpool from '@ohos.taskpool';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { QuickJsExpressionResult, QuickJsScriptRuntime } from './QuickJsScriptRuntime';
import { QuickJsRuntimeStatus, QuickJsShadowSubmitter } from './QuickJsRuntimeStatus';

/** Pure TaskPool entry: no UI, database, network, Cookie or filesystem access is exposed. */
@Concurrent
function executeQuickJsShadow(expression: string, variablesJson: string): string {
  const variables: Record<string, number | string | boolean> = {};
  try {
    const parsed = JSON.parse(variablesJson || '{}') as Record<string, Object>;
    const keys = Object.keys(parsed);
    for (let index = 0; index < keys.length; index++) {
      const key = keys[index];
      const value = parsed[key];
      if (typeof value === 'number' || typeof value === 'string' || typeof value === 'boolean') {
        variables[key] = value;
      }
    }
  } catch (_) {
    const invalid = new QuickJsExpressionResult();
    invalid.error = 'invalid-bindings';
    return JSON.stringify(invalid);
  }
  return JSON.stringify(QuickJsScriptRuntime.evaluateExpression(expression, variables, 80));
}

export class QuickJsShadowExecutor implements QuickJsShadowSubmitter {
  private static readonly DOMAIN: number = 0x0000;
  private static readonly TAG: string = 'QuickJSShadow';
  private static readonly MAX_IN_FLIGHT: number = 4;
  private inFlight: number = 0;
  private completed: number = 0;
  private matches: number = 0;
  private mismatches: number = 0;
  private failures: number = 0;

  static install(): void {
    QuickJsRuntimeStatus.setShadowSubmitter(new QuickJsShadowExecutor());
  }

  submit(expression: string, variablesJson: string, legacyValue: string,
    fingerprint: string, sample: number): boolean {
    if (this.inFlight >= QuickJsShadowExecutor.MAX_IN_FLIGHT) return false;
    this.inFlight++;
    taskpool.execute(executeQuickJsShadow, expression, variablesJson)
      .then((raw: Object): void => {
        const result = this.parseResult(String(raw || ''));
        this.record(result, legacyValue, fingerprint, sample);
      })
      .catch((error: Error): void => {
        const result = new QuickJsExpressionResult();
        result.error = error.message || 'taskpool-failed';
        this.record(result, legacyValue, fingerprint, sample);
      })
      .finally((): void => {
        this.inFlight = Math.max(0, this.inFlight - 1);
      });
    return true;
  }

  private parseResult(raw: string): QuickJsExpressionResult {
    const result = new QuickJsExpressionResult();
    try {
      const parsed = JSON.parse(raw || '{}') as Record<string, Object>;
      result.success = parsed['success'] === true;
      result.value = String(parsed['value'] || '');
      result.error = String(parsed['error'] || '');
      result.timedOut = parsed['timedOut'] === true;
      result.elapsedMs = Number(parsed['elapsedMs'] || 0);
    } catch (_) {
      result.error = 'invalid-task-result';
    }
    return result;
  }

  private record(result: QuickJsExpressionResult, legacyValue: string,
    fingerprint: string, sample: number): void {
    this.completed++;
    if (!result.success) {
      this.failures++;
      hilog.warn(QuickJsShadowExecutor.DOMAIN, QuickJsShadowExecutor.TAG,
        'sample=%{public}d id=%{public}s status=error timeout=%{public}s elapsed=%{public}d',
        sample, fingerprint, `${result.timedOut}`, result.elapsedMs);
    } else if (result.value === legacyValue) {
      this.matches++;
      hilog.info(QuickJsShadowExecutor.DOMAIN, QuickJsShadowExecutor.TAG,
        'sample=%{public}d id=%{public}s status=match elapsed=%{public}d',
        sample, fingerprint, result.elapsedMs);
    } else {
      this.mismatches++;
      hilog.warn(QuickJsShadowExecutor.DOMAIN, QuickJsShadowExecutor.TAG,
        'sample=%{public}d id=%{public}s status=mismatch legacyLen=%{public}d quickLen=%{public}d',
        sample, fingerprint, legacyValue.length, result.value.length);
    }
    hilog.info(QuickJsShadowExecutor.DOMAIN, QuickJsShadowExecutor.TAG,
      'summary completed=%{public}d matches=%{public}d mismatches=%{public}d failures=%{public}d inFlight=%{public}d',
      this.completed, this.matches, this.mismatches, this.failures, this.inFlight);
  }
}
