export class WebDavError {
  static message(error: Object, fallback: string = '未知错误'): string {
    const message = WebDavError.value(error, 0);
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
      const errorMessage = WebDavError.value(errorValue['message'], depth + 1);
      const errorCode = WebDavError.code(errorValue, depth + 1);
      if (errorMessage) return errorCode ? `${errorMessage}（错误码 ${errorCode}）` : errorMessage;
      if (errorCode) return `错误码 ${errorCode}`;
    }
    if (typeof input === 'object') {
      const record = input as Record<string, Object>;
      const fields: string[] = ['message', 'reason', 'description', 'detail', 'cause', 'data'];
      for (const field of fields) {
        const text = WebDavError.value(record[field], depth + 1);
        if (text) {
          const code = WebDavError.code(record, depth + 1);
          return code && !text.includes(code) ? `${text}（错误码 ${code}）` : text;
        }
      }
      const code = WebDavError.code(record, depth + 1);
      if (code) return `错误码 ${code}`;
    }
    return '';
  }

  private static code(record: Record<string, Object>, depth: number): string {
    const fields: string[] = ['code', 'errorCode', 'errCode'];
    for (const field of fields) {
      const code = WebDavError.value(record[field], depth + 1);
      if (code) return code;
    }
    return '';
  }
}
