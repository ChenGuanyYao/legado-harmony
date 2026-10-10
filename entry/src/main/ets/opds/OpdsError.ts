// OPDS 业务错误。code 为稳定的机器可读分类，userMessage 为可直接展示的中文文案。
// code 取值：'auth'（认证失败）、'not-found'（地址不存在）、'not-opds'（非 OPDS 内容）、
// 'network'（网络/HTTP 失败）、'certificate'（证书校验失败）、'cancelled'（用户取消）、
// 'unknown'（其他未知错误）。

export class OpdsError extends Error {
  code: string = '';
  userMessage: string = '';

  constructor(code: string, userMessage: string) {
    super(userMessage);
    this.name = 'OpdsError';
    this.code = code || 'unknown';
    this.userMessage = userMessage || '未知错误';
  }

  static message(error: Object, fallback: string = '未知错误'): string {
    const message = OpdsError.value(error, 0);
    return message || fallback;
  }

  private static value(input: Object | null | undefined, depth: number): string {
    if (input === null || input === undefined || depth > 4) return '';
    if (typeof input === 'string') {
      const text = input.trim();
      return text === '[object Object]' ? '' : text;
    }
    if (typeof input === 'number' || typeof input === 'boolean') return String(input);
    if (input instanceof Error) {
      const errorValue = input as Object as Record<string, Object>;
      const errorMessage = OpdsError.value(errorValue['message'], depth + 1);
      const errorCode = OpdsError.code(errorValue, depth + 1);
      if (errorMessage) return errorCode ? `${errorMessage}（错误码 ${errorCode}）` : errorMessage;
      if (errorCode) return `错误码 ${errorCode}`;
    }
    if (typeof input === 'object') {
      const record = input as Record<string, Object>;
      const fields: string[] = ['message', 'reason', 'description', 'detail', 'cause', 'data'];
      for (const field of fields) {
        const text = OpdsError.value(record[field], depth + 1);
        if (text) {
          const code = OpdsError.code(record, depth + 1);
          return code && !text.includes(code) ? `${text}（错误码 ${code}）` : text;
        }
      }
      const code = OpdsError.code(record, depth + 1);
      if (code) return `错误码 ${code}`;
    }
    return '';
  }

  private static code(record: Record<string, Object>, depth: number): string {
    const fields: string[] = ['code', 'errorCode', 'errCode'];
    for (const field of fields) {
      const code = OpdsError.value(record[field], depth + 1);
      if (code) return code;
    }
    return '';
  }
}
