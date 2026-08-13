export enum QuickJsRuntimeMode {
  OFF = 'off',
  SHADOW = 'shadow',
  PREFER_QUICKJS = 'prefer-quickjs'
}

export interface QuickJsShadowSubmitter {
  submit(expression: string, variablesJson: string, legacyValue: string,
    fingerprint: string, sample: number): boolean;
}

/** Process-local gate. A native self-test must pass before source code can reach QuickJS. */
export class QuickJsRuntimeStatus {
  private static healthy: boolean = false;
  private static mode: QuickJsRuntimeMode = QuickJsRuntimeMode.SHADOW;
  private static shadowSubmitter: QuickJsShadowSubmitter | null = null;

  static markSelfTest(passed: boolean): void {
    QuickJsRuntimeStatus.healthy = passed;
  }

  static isHealthy(): boolean {
    return QuickJsRuntimeStatus.healthy;
  }

  static getMode(): QuickJsRuntimeMode {
    return QuickJsRuntimeStatus.mode;
  }

  static setMode(mode: QuickJsRuntimeMode): void {
    QuickJsRuntimeStatus.mode = mode;
  }

  static setShadowSubmitter(submitter: QuickJsShadowSubmitter | null): void {
    QuickJsRuntimeStatus.shadowSubmitter = submitter;
  }

  static getShadowSubmitter(): QuickJsShadowSubmitter | null {
    return QuickJsRuntimeStatus.shadowSubmitter;
  }
}
