export class FullTextCacheCancelSignal {
  nonce: number = 0;
  taskKey: string = '';
  bookUrl: string = '';
}

class FullTextCacheCancelRegistration {
  bookUrl: string;
  handler: (signal: FullTextCacheCancelSignal) => void;

  constructor(bookUrl: string, handler: (signal: FullTextCacheCancelSignal) => void) {
    this.bookUrl = bookUrl;
    this.handler = handler;
  }
}

// Keep mutable coordinator state at module scope. ArkTS lowers calls from notification callbacks as standalone
// functions and rejects class-static state access there as an implicit standalone `this` reference.
const fullTextCacheCancelRegistrations: Map<string, FullTextCacheCancelRegistration> = new Map();
let fullTextCacheCancelLastNonce: number = 0;

function nextFullTextCacheCancelNonce(): number {
  const stored = AppStorage.get<number>('fullTextCacheCancelNonce') || 0;
  fullTextCacheCancelLastNonce = Math.max(Date.now(), stored + 1, fullTextCacheCancelLastNonce + 1);
  return fullTextCacheCancelLastNonce;
}

function findFullTextCacheCancelRegistration(
  signal: FullTextCacheCancelSignal): FullTextCacheCancelRegistration | null {
  if (signal.taskKey) return fullTextCacheCancelRegistrations.get(signal.taskKey) || null;
  if (!signal.bookUrl) return null;
  for (const registration of fullTextCacheCancelRegistrations.values()) {
    if (registration.bookUrl === signal.bookUrl) return registration;
  }
  return null;
}

/** Keeps notification cancellation reachable while the page that started the background task is unmounted. */
export class FullTextCacheCancelCoordinator {
  static nextNonce(): number {
    return nextFullTextCacheCancelNonce();
  }

  static register(taskKey: string, bookUrl: string,
    handler: (signal: FullTextCacheCancelSignal) => void): void {
    if (!taskKey) return;
    fullTextCacheCancelRegistrations.set(taskKey,
      new FullTextCacheCancelRegistration(bookUrl, handler));
  }

  static unregister(taskKey: string): void {
    if (taskKey) fullTextCacheCancelRegistrations.delete(taskKey);
  }

  static request(taskKey: string, bookUrl: string, nonce: number = 0): FullTextCacheCancelSignal {
    const signal = new FullTextCacheCancelSignal();
    signal.nonce = nonce > 0 ? nonce : nextFullTextCacheCancelNonce();
    signal.taskKey = taskKey || '';
    signal.bookUrl = bookUrl || '';
    const registration = findFullTextCacheCancelRegistration(signal);
    if (registration) registration.handler(signal);
    AppStorage.setOrCreate('fullTextCacheCancelSignal', JSON.stringify(signal));
    AppStorage.setOrCreate('fullTextCacheCancelNonce', signal.nonce);
    return signal;
  }

  static parse(raw: string): FullTextCacheCancelSignal | null {
    if (!raw || !raw.trim()) return null;
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const signal = new FullTextCacheCancelSignal();
      signal.nonce = typeof parsed['nonce'] === 'number' ? parsed['nonce'] as number : 0;
      signal.taskKey = typeof parsed['taskKey'] === 'string' ? parsed['taskKey'] as string : '';
      signal.bookUrl = typeof parsed['bookUrl'] === 'string' ? parsed['bookUrl'] as string : '';
      return signal.nonce > 0 ? signal : null;
    } catch (_) {
      return null;
    }
  }

  static matches(signal: FullTextCacheCancelSignal | null, taskKey: string, bookUrl: string): boolean {
    if (!signal) return false;
    if (signal.taskKey) return signal.taskKey === taskKey;
    return !!signal.bookUrl && signal.bookUrl === bookUrl;
  }
}
