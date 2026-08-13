import { hilog } from '@kit.PerformanceAnalysisKit';
import { JSBoundedExecutionResult, JSContext, JSRuntimeOptions } from '@devzeng/quickjs';
import { QuickJsRuntimeStatus } from './QuickJsRuntimeStatus';
import { QuickJsShadowExecutor } from './QuickJsShadowExecutor';

class QuickJsSelfTestCase {
  name: string;
  script: string;
  expectedValue: string;

  constructor(name: string, script: string, expectedValue: string) {
    this.name = name;
    this.script = script;
    this.expectedValue = expectedValue;
  }
}

/**
 * Runs a small, local-only QuickJS health check after the first application frame.
 *
 * This does not execute book-source code and does not participate in source routing.
 * It exists so a broken native runtime can never silently replace the current engine.
 */
export class QuickJsDiagnostics {
  private static readonly DOMAIN: number = 0x0000;
  private static readonly TAG: string = 'QuickJS';
  private static hasRun: boolean = false;

  static runStartupSelfTest(): void {
    if (QuickJsDiagnostics.hasRun) {
      return;
    }
    QuickJsDiagnostics.hasRun = true;

    const cases: QuickJsSelfTestCase[] = [
      new QuickJsSelfTestCase('expression', '1 + 2', '3'),
      new QuickJsSelfTestCase('modern-syntax',
        'JSON.stringify([1, 2, 3].map((value) => value * 2))', '[2,4,6]')
    ];
    let passed = 0;
    let total = cases.length + 3;

    const options = new JSRuntimeOptions();
    options.memoryLimitBytes = 16 * 1024 * 1024;
    options.stackLimitBytes = 512 * 1024;
    const context = new JSContext(options);
    try {
      for (let index = 0; index < cases.length; index++) {
        const testCase = cases[index];
        const result = context.evaluateBounded(testCase.script,
          `quickjs-self-test-${testCase.name}.js`, 250, 16);
        if (QuickJsDiagnostics.isExpected(result, testCase.expectedValue)) {
          passed++;
        } else {
          QuickJsDiagnostics.logFailure(testCase.name, result);
        }
      }

      const fixture: Record<string, number | string | boolean> = {};
      fixture.value = 7;
      fixture.enabled = true;
      context.setObject(fixture, 'fixture');
      const bindingResult = context.evaluateBounded(
        'fixture.enabled ? fixture.value * 6 : 0', 'quickjs-self-test-binding.js', 250, 16);
      if (QuickJsDiagnostics.isExpected(bindingResult, '42')) {
        passed++;
      } else {
        QuickJsDiagnostics.logFailure('host-binding', bindingResult);
      }

      const promiseResult = context.evaluateBounded(
        "globalThis.__promiseValue = 0; Promise.resolve(6).then((value) => { " +
        "globalThis.__promiseValue = value * 7; }); 'queued'",
        'quickjs-self-test-promise.js', 250, 16);
      const promiseValue = context.evaluateBounded(
        'globalThis.__promiseValue', 'quickjs-self-test-promise-value.js', 250, 16);
      if (promiseResult.success && promiseResult.pendingJobs > 0 &&
        QuickJsDiagnostics.isExpected(promiseValue, '42')) {
        passed++;
      } else {
        QuickJsDiagnostics.logFailure('promise-job', promiseResult);
        if (!QuickJsDiagnostics.isExpected(promiseValue, '42')) {
          QuickJsDiagnostics.logFailure('promise-value', promiseValue);
        }
      }
    } catch (error) {
      hilog.error(QuickJsDiagnostics.DOMAIN, QuickJsDiagnostics.TAG,
        'Self-test runtime failure: %{public}s', QuickJsDiagnostics.errorMessage(error));
    } finally {
      context.release();
    }

    const timeoutContext = new JSContext(options);
    try {
      const timeoutResult = timeoutContext.evaluateBounded(
        'while (true) {}', 'quickjs-self-test-timeout.js', 40, 0);
      if (!timeoutResult.success && timeoutResult.timedOut && timeoutResult.elapsedMs < 500) {
        passed++;
      } else {
        QuickJsDiagnostics.logFailure('interrupt-timeout', timeoutResult);
      }
    } catch (error) {
      hilog.error(QuickJsDiagnostics.DOMAIN, QuickJsDiagnostics.TAG,
        'Timeout self-test failure: %{public}s', QuickJsDiagnostics.errorMessage(error));
    } finally {
      timeoutContext.release();
    }

    if (passed === total) {
      QuickJsRuntimeStatus.markSelfTest(true);
      QuickJsShadowExecutor.install();
      hilog.info(QuickJsDiagnostics.DOMAIN, QuickJsDiagnostics.TAG,
        'Self-test PASS %{public}d/%{public}d', passed, total);
    } else {
      QuickJsRuntimeStatus.markSelfTest(false);
      hilog.error(QuickJsDiagnostics.DOMAIN, QuickJsDiagnostics.TAG,
        'Self-test FAIL %{public}d/%{public}d', passed, total);
    }
  }

  private static isExpected(result: JSBoundedExecutionResult, expectedValue: string): boolean {
    return result.success && result.value === expectedValue && !result.timedOut;
  }

  private static logFailure(name: string, result: JSBoundedExecutionResult): void {
    hilog.error(QuickJsDiagnostics.DOMAIN, QuickJsDiagnostics.TAG,
      'Self-test %{public}s failed success=%{public}s timeout=%{public}s jobs=%{public}d elapsed=%{public}d ' +
      'value=%{public}s error=%{public}s', name, `${result.success}`, `${result.timedOut}`,
      result.pendingJobs, result.elapsedMs, result.value, result.error);
  }

  private static errorMessage(error: Object): string {
    if (error instanceof Error) {
      return error.message;
    }
    return `${error}`;
  }
}
