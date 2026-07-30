import { BookSource } from '../../model/data/Book';
import { util } from '@kit.ArkTS';

export class LoginRuntimeStep {
  pendingAjax: string = '';
  pendingCookie: string = '';
  cookieOperations: string = '[]';
  variable: string = '';
  loginHeader: string = '';
  loginInfo: string = '{}';
  requestedUrl: string = '';
  requestedTitle: string = '';
  toastMessage: string = '';
  errorMessage: string = '';
}

export class LoginCookieOperation {
  operation: string = '';
  url: string = '';
  value: string = '';
  name: string = '';
}

class LoginScriptFunction {
  name: string = '';
  start: number = 0;
  end: number = 0;
  source: string = '';
}

/** Runs loginUi actions in ArkWeb's real JavaScript engine with a sandboxed bridge. */
export class BookSourceLoginWebRuntime {
  private static readonly RUNTIME_STATE_KEY: string = '__legadoHarmonyRuntime';

  static buildScript(source: BookSource, action: string, responses: Record<string, string>,
    cookies: Record<string, string> = {}): string {
    const state = JSON.stringify({
      variable: source.variable || '',
      loginHeader: source.loginHeader || '',
      loginInfo: this.parseRecord(source.loginInfo),
      runtime: this.parseRuntimeState(source.loginInfo),
      responses: responses || {},
      cookies: cookies || {},
      sourceUrl: source.bookSourceUrl || '',
      sourceName: source.bookSourceName || '',
      loginUi: source.loginUi || ''
    });
    const completeLibrary = `${source.jsLib || ''}\n${source.loginUrl || ''}`;
    const actionLibrary = this.shouldIsolateActionScript(completeLibrary) ?
      this.selectActionScript(completeLibrary, action || '') : completeLibrary;
    const library = this.normalizeScript(actionLibrary);
    const exposeFunctions = this.functionExposeScript(library);
    // ArkWeb's runJavaScript transport can misparse very large quoted source strings containing
    // nested templates/HTML. Keep both payloads ASCII-only while crossing that boundary, then
    // restore their UTF-8 text inside the Web runtime before parsing or evaluating them.
    const stateBase64 = this.encodeBase64(state);
    const codeBase64 = this.encodeBase64(`${library}\n${exposeFunctions}\n${action || ''}` +
      '\n//# sourceURL=book-source-login.js');
    return `(function(){` +
      `function decodeUtf8(v){try{return decodeURIComponent(escape(atob(v)));}catch(e){return atob(v);}}` +
      `const S=JSON.parse(decodeUtf8('${stateBase64}'));` +
      `let pending='',pendingCookie='',url='',title='',toast='',error='';` +
      `const runtime=S.runtime&&typeof S.runtime==='object'?S.runtime:{};` +
      `const vars=Object.assign({},runtime.java||{});` +
      `const cacheData=Object.assign({},runtime.cache||{});` +
      `const cookieData=Object.assign({},S.cookies||{});const cookieOps=[];` +
      `const loginMap=Object.assign({},S.loginInfo||{});` +
      `Object.defineProperty(loginMap,'get',{enumerable:false,value:function(k){return this[k]||'';}});` +
      `Object.defineProperty(loginMap,'put',{enumerable:false,value:function(k,v){this[k]=v;return v;}});` +
      `const source={` +
      `bookSourceUrl:S.sourceUrl,bookSourceName:S.sourceName,loginUi:S.loginUi,` +
      `getKey:function(){return S.sourceUrl;},` +
      `getVariable:function(){return S.variable||'';},` +
      `setVariable:function(v){S.variable=String(v??'');return S.variable;},` +
      `getLoginHeader:function(){return S.loginHeader||'';},` +
      `putLoginHeader:function(v){S.loginHeader=String(v??'');return S.loginHeader;},` +
      `getLoginInfoMap:function(){return loginMap;},` +
      `getLoginInfo:function(k){return arguments.length?(k?loginMap[k]||'':''):JSON.stringify(loginMap);},` +
      `putLoginInfo:function(a,b){if(arguments.length>1){loginMap[a]=b;return b;}` +
      `let next=a;if(typeof next==='string'){try{next=JSON.parse(next);}catch(e){return a;}}` +
      `if(next&&typeof next==='object'&&!Array.isArray(next)){Object.keys(loginMap).forEach(function(k){delete loginMap[k];});` +
      `Object.assign(loginMap,next);}return a;}` +
      `};` +
      `function b64e(v){try{return btoa(unescape(encodeURIComponent(String(v??''))));}catch(e){return String(v??'');}}` +
      `function b64d(v){try{return decodeURIComponent(escape(atob(String(v??''))));}catch(e){return String(v??'');}}` +
      `function open(u,t){url=String(u??'');title=String(t??'');return {body:function(){return '';}};}` +
      `const cache={get:function(k){return Object.prototype.hasOwnProperty.call(cacheData,k)?cacheData[k]:null;},` +
      `getFromMemory:function(k){return Object.prototype.hasOwnProperty.call(cacheData,k)?cacheData[k]:null;},` +
      `put:function(k,v){cacheData[k]=v;return v;},putMemory:function(k,v){cacheData[k]=v;return v;},` +
      `delete:function(k){delete cacheData[k];return true;}};` +
      `const cookie={getCookie:function(k){k=String(k??'');` +
      `if(Object.prototype.hasOwnProperty.call(cookieData,k))return cookieData[k]??'';` +
      `if(!pendingCookie)pendingCookie=k;return '';},getKey:function(k,n){` +
      `const value=this.getCookie(k);const m=String(value??'').match(new RegExp('(?:^|;\\s*)'+n+'=([^;]*)'));` +
      `return m?m[1]:'';},` +
      `setCookie:function(k,v){k=String(k??'');v=String(v??'');cookieData[k]=v;` +
      `cookieOps.push({operation:'set',url:k,value:v,name:''});return v;},` +
      `removeCookie:function(k,n){k=String(k??'');n=String(n??'');` +
      `cookieOps.push({operation:'remove',url:k,value:'',name:n});` +
      `if(!n){cookieData[k]='';}else{cookieData[k]=String(cookieData[k]??'').split(';').filter(function(x){` +
      `return x.trim().split('=')[0]!==n;}).join(';');}return true;}};` +
      `const java={` +
      `ajax:function(v){v=String(v??'');if(Object.prototype.hasOwnProperty.call(S.responses,v))return S.responses[v];` +
      `if(!pending)pending=v;return '{"code":599,"message":"pending","data":{}}';},` +
      `put:function(k,v){vars[k]=v;return v;},get:function(k){` +
      `return Object.prototype.hasOwnProperty.call(vars,k)?vars[k]:null;},` +
      `toast:function(v){toast=String(v??'');return toast;},longToast:function(v){toast=String(v??'');return toast;},` +
      `startBrowser:function(u,t){return open(u,t);},startBrowserAwait:function(u,t){return open(u,t);},` +
      `startBrowserDp:function(u,t){return open(u,t);},showBrowser:function(u,c,j,o){return open(u,'');},` +
      `showReadingBrowser:function(u,t){return open(u,t);},open:function(u,t){return open(u,t);},` +
      `base64Encode:b64e,base64EncodeToString:b64e,base64Decode:b64d,base64DecodeToString:b64d,` +
      `base64DecodeToByteArray:b64d,androidId:function(){return 'harmony';},deviceID:function(){return 'harmony';},` +
      `getCookie:function(k){return cookie.getCookie(k);},lang:function(){return 'zh';},reLoginView:function(){return '';},` +
      `qread:function(){return '0';},log:function(){return '';},refreshExplore:function(){return '';},` +
      `searchBook:function(){return '';},getWebViewUA:function(){return navigator.userAgent;},` +
      `timeFormat:function(v){try{return new Date(v).toISOString().replace('T',' ').replace('Z','');}` +
      `catch(e){return String(v??'');}},createSymmetricCrypto:function(){return {` +
      `encrypt:function(v){return String(v??'');},encryptStr:function(v){return String(v??'');},` +
      `decrypt:function(v){return String(v??'');},decryptStr:function(v){return String(v??'');}};}` +
      `};` +
      `const TimeoutCancellationException=function(){};` +
      `const Packages={io:{legato:{kazusa:{utils:{TimeoutCancellationException:TimeoutCancellationException}}}},` +
      `java:{lang:{Thread:{sleep:function(){return '';}}}},android:{util:{Base64:{` +
      `encodeToString:function(v){return b64e(v);}}}}};` +
      `globalThis.source=source;globalThis.java=java;globalThis.cache=cache;globalThis.cookie=cookie;` +
      `globalThis.Packages=Packages;globalThis.result=loginMap;` +
      `try{(function(){eval(decodeUtf8('${codeBase64}'));}).call(globalThis);}` +
      `catch(e){error=String((e&&e.name?e.name+': ':'')+((e&&e.message)||e||'脚本执行失败')+` +
      `(e&&e.stack?'\\n'+e.stack:''));}` +
      `const cleanInfo={};Object.keys(loginMap).forEach(function(k){cleanInfo[k]=String(loginMap[k]??'');});` +
      `cleanInfo['${this.RUNTIME_STATE_KEY}']=JSON.stringify({java:vars,cache:cacheData});` +
      `return encodeURIComponent(JSON.stringify({pendingAjax:pending,pendingCookie:pendingCookie,` +
      `cookieOperations:JSON.stringify(cookieOps),variable:S.variable||'',` +
      `loginHeader:S.loginHeader||'',loginInfo:JSON.stringify(cleanInfo),requestedUrl:url,requestedTitle:title,` +
      `toastMessage:toast,errorMessage:error}));})()`;
  }

  private static encodeBase64(value: string): string {
    const bytes = new util.TextEncoder().encodeInto(value || '');
    return new util.Base64Helper().encodeToStringSync(bytes);
  }

  private static normalizeScript(script: string): string {
    // Some ArkWeb versions reject an unparenthesized object literal that is indexed directly
    // in a variable initializer: `const value = { a: 1 }[key]`. Parentheses are equivalent and
    // are accepted by both the Web engine and the JavaScript dialect used by Android Legado.
    return (script || '').replace(/=\s*\{([^{}]*)\}\s*\[([A-Za-z_$][A-Za-z0-9_$]*)\]/g,
      (_match: string, body: string, key: string): string => `= ({${body}})[${key}]`);
  }

  private static shouldIsolateActionScript(script: string): boolean {
    // `[removed]` is produced by privacy/sanitizing pipelines when a template expression is
    // stripped. Some pipelines also remove its closing backtick, making an otherwise unrelated
    // function invalidate the whole login library. Clean sources keep their exact full script.
    return (script || '').includes('[removed]');
  }

  private static selectActionScript(script: string, action: string): string {
    const functions = this.extractFunctions(script || '');
    if (functions.length === 0) return script || '';
    const required: string[] = [];
    const pending: string[] = this.scriptIdentifiers(action || '');
    while (pending.length > 0) {
      const name = pending.shift() || '';
      if (!name || required.includes(name)) continue;
      const block = functions.find((item: LoginScriptFunction): boolean =>
        item.name === name && !!item.source);
      if (!block) continue;
      required.push(name);
      for (const dependency of this.scriptIdentifiers(block.source)) {
        if (!required.includes(dependency) && !pending.includes(dependency)) pending.push(dependency);
      }
    }

    // Preserve top-level constants and setup statements, but remove every unneeded function body.
    // Replacing removed spans with a line break also prevents adjacent comments/tokens merging.
    let prelude = '';
    let cursor = 0;
    for (const block of functions) {
      if (block.start < cursor) continue;
      prelude += script.substring(cursor, block.start) + '\n';
      cursor = block.end;
    }
    prelude += script.substring(cursor);
    if (required.length === 0) return prelude;
    let selected = prelude;
    for (const block of functions) {
      if (required.includes(block.name)) selected += `\n${block.source}\n`;
    }
    return selected;
  }

  private static extractFunctions(script: string): LoginScriptFunction[] {
    const result: LoginScriptFunction[] = [];
    const regex = /\bfunction\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(/g;
    let match: RegExpExecArray | null;
    while ((match = regex.exec(script || '')) !== null) {
      const parametersOpen = regex.lastIndex - 1;
      const parametersClose = this.findMatchingDelimiter(script, parametersOpen, '(', ')');
      if (parametersClose < 0) {
        const invalid = this.invalidFunctionBlock(script, match[1] || '', match.index, regex.lastIndex);
        result.push(invalid);
        regex.lastIndex = invalid.end;
        continue;
      }
      let bodyOpen = parametersClose + 1;
      while (bodyOpen < script.length && /\s/.test(script.charAt(bodyOpen))) bodyOpen++;
      if (script.charAt(bodyOpen) !== '{') {
        const invalid = this.invalidFunctionBlock(script, match[1] || '', match.index, regex.lastIndex);
        result.push(invalid);
        regex.lastIndex = invalid.end;
        continue;
      }
      const bodyClose = this.findMatchingDelimiter(script, bodyOpen, '{', '}');
      if (bodyClose < 0) {
        // A damaged, unrelated source function must not poison every loginUi button. Isolate it
        // up to the next named declaration; if the button needs it, the action gets a clear
        // missing-function error instead of a parser failure in unrelated code.
        const invalid = this.invalidFunctionBlock(script, match[1] || '', match.index, regex.lastIndex);
        result.push(invalid);
        regex.lastIndex = invalid.end;
        continue;
      }
      const block = new LoginScriptFunction();
      block.name = match[1] || '';
      block.start = match.index;
      block.end = bodyClose + 1;
      block.source = script.substring(block.start, block.end);
      result.push(block);
      regex.lastIndex = block.end;
    }
    return result;
  }

  private static invalidFunctionBlock(script: string, name: string, start: number, searchFrom: number): LoginScriptFunction {
    const nextRegex = /\bfunction\s+[A-Za-z_$][A-Za-z0-9_$]*\s*\(/g;
    nextRegex.lastIndex = Math.max(searchFrom, start + 1);
    const next = nextRegex.exec(script);
    const block = new LoginScriptFunction();
    block.name = name;
    block.start = start;
    block.end = next ? next.index : script.length;
    block.source = '';
    return block;
  }

  private static findMatchingDelimiter(script: string, start: number, open: string, close: string): number {
    let depth = 0;
    let quote = '';
    let lineComment = false;
    let blockComment = false;
    let regexLiteral = false;
    let regexClass = false;
    for (let index = start; index < script.length; index++) {
      const current = script.charAt(index);
      const next = index + 1 < script.length ? script.charAt(index + 1) : '';
      if (lineComment) {
        if (current === '\n' || current === '\r') lineComment = false;
        continue;
      }
      if (blockComment) {
        if (current === '*' && next === '/') {
          blockComment = false;
          index++;
        }
        continue;
      }
      if (quote) {
        if (current === '\\') {
          index++;
        } else if (current === quote) {
          quote = '';
        }
        continue;
      }
      if (regexLiteral) {
        if (current === '\\') {
          index++;
        } else if (current === '[') {
          regexClass = true;
        } else if (current === ']') {
          regexClass = false;
        } else if (current === '/' && !regexClass) {
          regexLiteral = false;
        }
        continue;
      }
      if (current === '/' && next === '/') {
        lineComment = true;
        index++;
        continue;
      }
      if (current === '/' && next === '*') {
        blockComment = true;
        index++;
        continue;
      }
      if (current === '/' && this.isRegexLiteralStart(script, index)) {
        regexLiteral = true;
        regexClass = false;
        continue;
      }
      if (current === '\'' || current === '"' || current === '`') {
        quote = current;
        continue;
      }
      if (current === open) depth++;
      if (current === close) {
        depth--;
        if (depth === 0) return index;
      }
    }
    return -1;
  }

  private static isRegexLiteralStart(script: string, slashIndex: number): boolean {
    let index = slashIndex - 1;
    while (index >= 0 && /\s/.test(script.charAt(index))) index--;
    if (index < 0) return true;
    const previous = script.charAt(index);
    if ('([{:;,=!?&|+-*%^~<>'.includes(previous)) return true;
    let end = index + 1;
    while (index >= 0 && /[A-Za-z_$]/.test(script.charAt(index))) index--;
    const word = script.substring(index + 1, end);
    return word === 'return' || word === 'case' || word === 'throw' || word === 'typeof' ||
      word === 'delete' || word === 'void' || word === 'new' || word === 'in' || word === 'of';
  }

  private static scriptIdentifiers(script: string): string[] {
    const clean = this.stripScriptStrings(script || '');
    const result: string[] = [];
    const regex = /\b[A-Za-z_$][A-Za-z0-9_$]*\b/g;
    let match: RegExpExecArray | null;
    while ((match = regex.exec(clean)) !== null) {
      const name = match[0] || '';
      if (name && !result.includes(name)) result.push(name);
    }
    return result;
  }

  private static stripScriptStrings(script: string): string {
    let result = '';
    let quote = '';
    let lineComment = false;
    let blockComment = false;
    let regexLiteral = false;
    let regexClass = false;
    for (let index = 0; index < script.length; index++) {
      const current = script.charAt(index);
      const next = index + 1 < script.length ? script.charAt(index + 1) : '';
      if (lineComment) {
        if (current === '\n' || current === '\r') {
          lineComment = false;
          result += current;
        } else {
          result += ' ';
        }
        continue;
      }
      if (blockComment) {
        if (current === '*' && next === '/') {
          blockComment = false;
          result += '  ';
          index++;
        } else {
          result += current === '\n' || current === '\r' ? current : ' ';
        }
        continue;
      }
      if (quote) {
        if (current === '\\') {
          result += quote === '`' ? current + next : '  ';
          index++;
        } else if (current === quote) {
          quote = '';
          result += ' ';
        } else {
          result += quote === '`' ? current : (current === '\n' || current === '\r' ? current : ' ');
        }
        continue;
      }
      if (regexLiteral) {
        if (current === '\\') {
          result += '  ';
          index++;
        } else if (current === '[') {
          regexClass = true;
          result += ' ';
        } else if (current === ']') {
          regexClass = false;
          result += ' ';
        } else if (current === '/' && !regexClass) {
          regexLiteral = false;
          result += ' ';
        } else {
          result += current === '\n' || current === '\r' ? current : ' ';
        }
        continue;
      }
      if (current === '/' && next === '/') {
        lineComment = true;
        result += '  ';
        index++;
      } else if (current === '/' && next === '*') {
        blockComment = true;
        result += '  ';
        index++;
      } else if (current === '/' && this.isRegexLiteralStart(script, index)) {
        regexLiteral = true;
        regexClass = false;
        result += ' ';
      } else if (current === '\'' || current === '"' || current === '`') {
        quote = current;
        result += ' ';
      } else {
        result += current;
      }
    }
    return result;
  }

  static parseResult(raw: string): LoginRuntimeStep {
    let value = (raw || '').trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    try {
      const record = JSON.parse(decodeURIComponent(value)) as Record<string, Object>;
      const result = new LoginRuntimeStep();
      result.pendingAjax = String(record['pendingAjax'] || '');
      result.pendingCookie = String(record['pendingCookie'] || '');
      result.cookieOperations = String(record['cookieOperations'] || '[]');
      result.variable = String(record['variable'] || '');
      result.loginHeader = String(record['loginHeader'] || '');
      result.loginInfo = String(record['loginInfo'] || '{}');
      result.requestedUrl = String(record['requestedUrl'] || '');
      result.requestedTitle = String(record['requestedTitle'] || '');
      result.toastMessage = String(record['toastMessage'] || '');
      result.errorMessage = String(record['errorMessage'] || '');
      return result;
    } catch (_) {
      const result = new LoginRuntimeStep();
      result.errorMessage = '登录脚本返回格式异常';
      return result;
    }
  }

  static parseRecord(json: string): Record<string, string> {
    try {
      const parsed = JSON.parse(json || '{}') as Record<string, Object>;
      const result: Record<string, string> = {};
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
        for (const key in parsed) {
          if (key !== this.RUNTIME_STATE_KEY) result[key] = String(parsed[key] || '');
        }
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  static mergeRecord(json: string, values: Record<string, string>): string {
    const merged: Record<string, Object> = {};
    for (const key in values) merged[key] = values[key];
    const runtime = this.parseRuntimeState(json);
    let hasRuntime = false;
    for (const key in runtime) {
      if (key) hasRuntime = true;
    }
    if (hasRuntime) {
      merged[this.RUNTIME_STATE_KEY] = JSON.stringify(runtime);
    }
    return JSON.stringify(merged);
  }

  static parseCookieOperations(json: string): LoginCookieOperation[] {
    const result: LoginCookieOperation[] = [];
    try {
      const parsed = JSON.parse(json || '[]') as Object[];
      if (!Array.isArray(parsed)) return result;
      for (const item of parsed) {
        if (!item || typeof item !== 'object' || Array.isArray(item)) continue;
        const record = item as Record<string, Object>;
        const operation = new LoginCookieOperation();
        operation.operation = String(record['operation'] || '');
        operation.url = String(record['url'] || '');
        operation.value = String(record['value'] || '');
        operation.name = String(record['name'] || '');
        if (operation.url && (operation.operation === 'set' || operation.operation === 'remove')) {
          result.push(operation);
        }
      }
    } catch (_) {}
    return result;
  }

  private static parseRuntimeState(json: string): Record<string, Object> {
    const empty: Record<string, Object> = {};
    try {
      const parsed = JSON.parse(json || '{}') as Record<string, Object>;
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return empty;
      let value = parsed[this.RUNTIME_STATE_KEY];
      if (typeof value === 'string') value = JSON.parse(value) as Object;
      if (value && typeof value === 'object' && !Array.isArray(value)) {
        return value as Record<string, Object>;
      }
    } catch (_) {}
    return empty;
  }

  private static functionExposeScript(script: string): string {
    const names: string[] = [];
    const regex = /\bfunction\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(/g;
    let match: RegExpExecArray | null;
    while ((match = regex.exec(script || '')) !== null) {
      const name = match[1] || '';
      if (name && !names.includes(name)) names.push(name);
    }
    let code = '';
    for (const name of names) {
      code += `if(typeof ${name}==='function')globalThis[${JSON.stringify(name)}]=${name};`;
    }
    return code;
  }
}
