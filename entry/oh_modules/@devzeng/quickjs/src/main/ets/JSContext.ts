/*
 * Copyright (c) 2021 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Modified by the legado-harmony project in 2026 for QuickJS runtime integration.
 */

import { JSValue } from './JSValue';
import qjs from './NativeQuickJs';

export class JSRuntimeOptions {
  memoryLimitBytes: number = 64 * 1024 * 1024;
  stackLimitBytes: number = 256 * 1024;
}

export class JSBoundedExecutionResult {
  success: boolean = false;
  value: string = '';
  error: string = '';
  timedOut: boolean = false;
  elapsedMs: number = 0;
  pendingJobs: number = 0;
}

export class JSContext {
  private _engineHandle: bigint = 0n;
  private nameValue: string = '';

  get engineHandle(): bigint {
    return this._engineHandle;
  }

  constructor(options?: JSRuntimeOptions) {
    const runtimeOptions = options || new JSRuntimeOptions();
    this._engineHandle = qjs.createEngineWithOptions(
      runtimeOptions.memoryLimitBytes, runtimeOptions.stackLimitBytes);
  }

  get globalObject(): JSValue {
    const handle = qjs.getGlobal(this._engineHandle);
    return new JSValue(this, handle);
  }

  get exception(): JSValue | null {
    const handle = qjs.getException(this._engineHandle);
    if (handle === 0n) {
      return null;
    }
    return new JSValue(this, handle);
  }

  set exception(value: JSValue | null) {
    if (value !== null) {
      qjs.throwException(this._engineHandle, value.valueHandle);
    }
  }

  exceptionHandler?: (context: JSContext, exception: JSValue) => void;

  evaluateScript(script: string, sourceURL?: string): JSValue {
    const url = sourceURL ?? 'evaluate';
    const handle = qjs.evaluateScript(this.engineHandle, script, url);
    const value = new JSValue(this, handle);
    if (value.isException && this.exceptionHandler) {
      const exc = this.exception;
      if (exc) {
        this.exceptionHandler(this, exc);
      }
    }
    return value;
  }

  evaluateBounded(script: string, sourceURL: string = 'evaluate', timeoutMs: number = 100,
    maxPendingJobs: number = 8): JSBoundedExecutionResult {
    const nativeResult = qjs.evaluateBounded(this.engineHandle, script, sourceURL,
      Math.max(1, timeoutMs), Math.max(0, maxPendingJobs));
    const result = new JSBoundedExecutionResult();
    result.success = nativeResult.success;
    result.value = nativeResult.value;
    result.error = nativeResult.error;
    result.timedOut = nativeResult.timedOut;
    result.elapsedMs = nativeResult.elapsedMs;
    result.pendingJobs = nativeResult.pendingJobs;
    return result;
  }

  setObject(object: Record<string, number | string | boolean> | JSValue, name: string): void {
    if (object instanceof JSValue) {
      const globalObj = this.globalObject;
      qjs.setProperty(this.engineHandle, globalObj.valueHandle, name, object.valueHandle);
      globalObj.release();
    } else {
      const objHandle = qjs.createObject(this.engineHandle);
      for (const key of Object.keys(object)) {
        const val = object[key];
        if (typeof val === 'number') {
          const numHandle = qjs.createNumber(this.engineHandle, val);
          qjs.setProperty(this.engineHandle, objHandle, key, numHandle);
          qjs.release(numHandle);
        } else if (typeof val === 'string') {
          const strHandle = qjs.createString(this.engineHandle, val);
          qjs.setProperty(this.engineHandle, objHandle, key, strHandle);
          qjs.release(strHandle);
        } else if (typeof val === 'boolean') {
          const boolHandle = qjs.createBoolean(this.engineHandle, val);
          qjs.setProperty(this.engineHandle, objHandle, key, boolHandle);
          qjs.release(boolHandle);
        }
      }
      const globalObj = this.globalObject;
      qjs.setProperty(this.engineHandle, globalObj.valueHandle, name, objHandle);
      globalObj.release();
      qjs.release(objHandle);
    }
  }

  getGlobalProperty(name: string): JSValue {
    return this.globalObject.getProperty(name);
  }

  get name(): string {
    return this.nameValue;
  }

  set name(value: string) {
    this.nameValue = value;
  }

  release(): void {
    if (this.engineHandle !== 0n) {
      qjs.releaseEngine(this.engineHandle);
      this._engineHandle = 0n;
    }
  }
}
