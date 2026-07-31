/** Runtime stages are routed independently so enabling ArkWeb for login never changes reading rules. */
export class SourceRuntimeStage {
  static readonly LOGIN: string = 'login';
  static readonly URL: string = 'url';
  static readonly SEARCH: string = 'search';
  static readonly EXPLORE: string = 'explore';
  static readonly BOOK_INFO: string = 'bookInfo';
  static readonly TOC: string = 'toc';
  static readonly CONTENT: string = 'content';
}

export class SourceRuntimeCapabilityReport {
  requiredJavaMethods: string[] = [];
  requiredSourceMethods: string[] = [];
  requiredCacheMethods: string[] = [];
  requiredCookieMethods: string[] = [];
  emulatedMethods: string[] = [];
  missingMethods: string[] = [];
  needsDom: boolean = false;
  usesPackages: boolean = false;
  usesDynamicEval: boolean = false;
  usesUnmanagedNetwork: boolean = false;
  hasSideEffects: boolean = false;

  fullySupported(): boolean {
    return this.missingMethods.length === 0 && !this.usesUnmanagedNetwork;
  }
}

export class SourceRuntimeDecision {
  stage: string = SourceRuntimeStage.URL;
  runtime: string = 'legacy';
  bridgeVersion: number = 1;
  preservesCurrentPath: boolean = true;
  fallbackAllowed: boolean = true;
  reason: string = '';
  capabilities: SourceRuntimeCapabilityReport = new SourceRuntimeCapabilityReport();
}

/**
 * Capability-based router. Non-login stages deliberately stay on the current engine until an
 * asynchronous ArkWeb pipeline has passed shadow comparison for that individual stage.
 */
export class BookSourceRuntimeRouter {
  static readonly BRIDGE_VERSION: number = 1;

  private static readonly FULL_JAVA_METHODS: string[] = [
    'ajax', 'put', 'get', 'toast', 'longToast', 'startBrowser', 'startBrowserAwait',
    'startBrowserDp', 'showBrowser', 'showReadingBrowser', 'open', 'openUrl',
    'base64Encode', 'base64EncodeToString', 'base64Decode', 'base64DecodeToString',
    'base64DecodeToByteArray', 'base64UrlEncode', 'base64UrlDecode',
    'hexEncodeToString', 'hexDecodeToString', 'urlEncode', 'urlDecode', 'encodeURI',
    'htmlEncode', 'htmlDecode',
    'androidId', 'deviceID', 'randomUUID', 'getCookie', 'lang', 'log', 'logType',
    'getWebViewUA', 'timeFormat', 'timeFormatUTC', 'strToBytes', 'bytesToStr', 'evalJS',
    'createSymmetricCrypto', 'reLoginView', 'refreshExplore', 'searchBook', 'upLoginData'
  ];

  private static readonly EMULATED_JAVA_METHODS: string[] = [
    'qread'
  ];

  private static readonly SOURCE_METHODS: string[] = [
    'getKey', 'getTag', 'getSource', 'getVariable', 'setVariable', 'getLoginHeader',
    'putLoginHeader', 'removeLoginHeader', 'getLoginInfo', 'getLoginInfoMap',
    'putLoginInfo', 'removeLoginInfo', 'getHeaderMap', 'get', 'put'
  ];

  private static readonly CACHE_METHODS: string[] = [
    'get', 'getFromMemory', 'put', 'putMemory', 'delete'
  ];

  private static readonly COOKIE_METHODS: string[] = [
    'getCookie', 'getKey', 'setCookie', 'removeCookie'
  ];

  private static readonly SIDE_EFFECT_METHODS: string[] = [
    'ajax', 'connect', 'get', 'post', 'head', 'put', 'setVariable', 'putLoginHeader',
    'removeLoginHeader', 'putLoginInfo', 'removeLoginInfo', 'setCookie', 'removeCookie',
    'startBrowser', 'startBrowserAwait',
    'open', 'openUrl', 'showBrowser', 'showReadingBrowser'
  ];

  static decide(stage: string, script: string): SourceRuntimeDecision {
    const decision = new SourceRuntimeDecision();
    decision.stage = stage || SourceRuntimeStage.URL;
    decision.bridgeVersion = this.BRIDGE_VERSION;
    decision.capabilities = this.analyze(script || '');
    decision.fallbackAllowed = !decision.capabilities.hasSideEffects;
    if (decision.stage === SourceRuntimeStage.LOGIN) {
      // ArkWeb is already the established login path. Keep it even when capability analysis finds
      // an unsupported API so existing behavior cannot silently switch to a second engine.
      decision.runtime = 'arkweb';
      decision.reason = decision.capabilities.fullySupported() ?
        '登录动作由已启用的ArkWeb兼容层执行' : '保持现有ArkWeb登录路径并报告缺少的桥接能力';
      return decision;
    }
    decision.runtime = 'legacy';
    decision.reason = '阅读阶段保持现有规则引擎，等待该阶段影子执行验证通过';
    return decision;
  }

  static analyze(script: string): SourceRuntimeCapabilityReport {
    const report = new SourceRuntimeCapabilityReport();
    const code = script || '';
    const executable = this.executableCode(code);
    report.requiredJavaMethods = this.objectMethods(executable, 'java');
    report.requiredSourceMethods = this.objectMethods(executable, 'source');
    report.requiredCacheMethods = this.objectMethods(executable, 'cache');
    report.requiredCookieMethods = this.objectMethods(executable, 'cookie');
    report.needsDom = /\b(?:document|window|location|navigator)\b|querySelector|createElement/.test(executable);
    report.usesPackages = /\b(?:Packages|JavaImporter|JavaAdapter)\b/.test(executable);
    report.usesDynamicEval = /\b(?:eval|Function)\s*\(/.test(executable);
    report.usesUnmanagedNetwork = /\b(?:fetch|XMLHttpRequest|WebSocket)\s*\(?/.test(executable);
    for (const method of report.requiredJavaMethods) {
      if (this.EMULATED_JAVA_METHODS.includes(method)) {
        this.pushUnique(report.emulatedMethods, `java.${method}`);
      } else if (!this.FULL_JAVA_METHODS.includes(method)) {
        this.pushUnique(report.missingMethods, `java.${method}`);
      }
      if (this.SIDE_EFFECT_METHODS.includes(method)) report.hasSideEffects = true;
    }
    this.checkObjectMethods(report, 'source', report.requiredSourceMethods, this.SOURCE_METHODS);
    this.checkObjectMethods(report, 'cache', report.requiredCacheMethods, this.CACHE_METHODS);
    this.checkObjectMethods(report, 'cookie', report.requiredCookieMethods, this.COOKIE_METHODS);
    if (report.usesPackages) this.pushUnique(report.emulatedMethods, 'Packages');
    if (report.usesUnmanagedNetwork) this.pushUnique(report.missingMethods, '浏览器直连网络');
    return report;
  }

  static isDirectUrlAction(action: string): boolean {
    return /^https?:\/\//i.test((action || '').trim());
  }

  static missingCapabilityMessage(decision: SourceRuntimeDecision | null): string {
    if (!decision || decision.capabilities.missingMethods.length === 0) return '';
    return `缺少兼容能力：${decision.capabilities.missingMethods.join('、')}`;
  }

  private static objectMethods(script: string, objectName: string): string[] {
    const result: string[] = [];
    const dot = new RegExp('\\b' + objectName + '\\s*\\.\\s*([A-Za-z_$][A-Za-z0-9_$]*)\\s*\\(', 'g');
    let match: RegExpExecArray | null;
    while ((match = dot.exec(script || '')) !== null) this.pushUnique(result, match[1] || '');
    const bracket = new RegExp('\\b' + objectName + '\\s*\\[\\s*[\'\"]([^\'\"]+)[\'\"]\\s*\\]\\s*\\(', 'g');
    while ((match = bracket.exec(script || '')) !== null) this.pushUnique(result, match[1] || '');
    return result;
  }

  private static checkObjectMethods(report: SourceRuntimeCapabilityReport, objectName: string,
    required: string[], supported: string[]): void {
    for (const method of required) {
      if (!supported.includes(method)) this.pushUnique(report.missingMethods, `${objectName}.${method}`);
      if (this.SIDE_EFFECT_METHODS.includes(method)) report.hasSideEffects = true;
    }
  }

  private static pushUnique(values: string[], value: string): void {
    if (value && !values.includes(value)) values.push(value);
  }

  /** Removes comments and literal bodies while preserving expressions embedded in template strings. */
  private static executableCode(script: string): string {
    script = this.stripEmbeddedHtml(script || '');
    let output = '';
    let quote = '';
    let lineComment = false;
    let blockComment = false;
    let templateExpressionDepth = 0;
    for (let index = 0; index < script.length; index++) {
      const current = script.charAt(index);
      const next = index + 1 < script.length ? script.charAt(index + 1) : '';
      if (lineComment) {
        if (current === '\n' || current === '\r') {
          lineComment = false;
          output += current;
        } else output += ' ';
        continue;
      }
      if (blockComment) {
        if (current === '*' && next === '/') {
          output += '  ';
          blockComment = false;
          index++;
        } else output += current === '\n' || current === '\r' ? current : ' ';
        continue;
      }
      if (quote === '`') {
        if (current === '\\') {
          output += '  ';
          index++;
        } else if (current === '`') {
          quote = '';
          output += ' ';
        } else if (current === '$' && next === '{') {
          quote = '';
          templateExpressionDepth = 1;
          output += '  ';
          index++;
        } else output += current === '\n' || current === '\r' ? current : ' ';
        continue;
      }
      if (quote) {
        if (current === '\\') {
          output += '  ';
          index++;
        } else if (current === quote) {
          quote = '';
          output += ' ';
        } else output += current === '\n' || current === '\r' ? current : ' ';
        continue;
      }
      if (current === '/' && next === '/') {
        lineComment = true;
        output += '  ';
        index++;
      } else if (current === '/' && next === '*') {
        blockComment = true;
        output += '  ';
        index++;
      } else if (current === '\'' || current === '"' || current === '`') {
        quote = current;
        output += ' ';
      } else {
        if (templateExpressionDepth > 0) {
          if (current === '{') templateExpressionDepth++;
          if (current === '}') {
            templateExpressionDepth--;
            if (templateExpressionDepth === 0) quote = '`';
          }
        }
        output += current;
      }
    }
    return output;
  }

  private static stripEmbeddedHtml(script: string): string {
    let value = script || '';
    let searchFrom = 0;
    while (searchFrom < value.length) {
      const doctype = value.indexOf('<!DOCTYPE', searchFrom);
      const htmlTag = value.indexOf('<html', searchFrom);
      let marker = -1;
      if (doctype >= 0 && htmlTag >= 0) marker = Math.min(doctype, htmlTag);
      else marker = Math.max(doctype, htmlTag);
      if (marker < 0) break;
      const start = value.lastIndexOf('`', marker);
      if (start < 0) {
        searchFrom = marker + 5;
        continue;
      }
      let end = marker;
      while (end < value.length) {
        end = value.indexOf('`', end + 1);
        if (end < 0 || value.charAt(end - 1) !== '\\') break;
      }
      if (end < 0) break;
      let blank = '';
      const removed = value.substring(start, end + 1);
      for (let index = 0; index < removed.length; index++) {
        const char = removed.charAt(index);
        blank += char === '\n' || char === '\r' ? char : ' ';
      }
      value = value.substring(0, start) + blank + value.substring(end + 1);
      searchFrom = start + blank.length;
    }
    return value;
  }
}
