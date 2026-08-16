class ReaderOpenTraceEntry {
  startedAt: number;
  lastMarkedAt: number;

  constructor(startedAt: number) {
    this.startedAt = startedAt;
    this.lastMarkedAt = startedAt;
  }
}

/**
 * Lightweight timing trace for the path from tapping a shelf book to publishing its first page.
 * Entries are intentionally process-local: they are diagnostic only and never affect reader state.
 */
export class ReaderOpenTrace {
  private static entries: Map<string, ReaderOpenTraceEntry> = new Map<string, ReaderOpenTraceEntry>();

  static begin(bookUrl: string): void {
    if (!bookUrl) return;
    const now = Date.now();
    ReaderOpenTrace.entries.set(bookUrl, new ReaderOpenTraceEntry(now));
    console.info(`[ReaderOpen] begin book=${ReaderOpenTrace.shortBookUrl(bookUrl)}`);
  }

  static beginIfNeeded(bookUrl: string): void {
    if (!bookUrl || ReaderOpenTrace.entries.has(bookUrl)) return;
    ReaderOpenTrace.begin(bookUrl);
  }

  static mark(bookUrl: string, stage: string, detail: string = ''): void {
    if (!bookUrl || !stage) return;
    const entry = ReaderOpenTrace.entries.get(bookUrl);
    if (!entry) return;
    const now = Date.now();
    const total = Math.max(0, now - entry.startedAt);
    const step = Math.max(0, now - entry.lastMarkedAt);
    entry.lastMarkedAt = now;
    console.info(`[ReaderOpen] ${stage} total=${total}ms step=${step}ms${detail ? ` ${detail}` : ''}`);
  }

  static finish(bookUrl: string, stage: string = 'first-page-ready'): void {
    if (!bookUrl) return;
    ReaderOpenTrace.mark(bookUrl, stage);
    ReaderOpenTrace.entries.delete(bookUrl);
  }

  static cancel(bookUrl: string, reason: string): void {
    if (!bookUrl) return;
    ReaderOpenTrace.mark(bookUrl, 'cancelled', reason);
    ReaderOpenTrace.entries.delete(bookUrl);
  }

  private static shortBookUrl(bookUrl: string): string {
    if (bookUrl.length <= 96) return bookUrl;
    return `${bookUrl.substring(0, 48)}...${bookUrl.substring(bookUrl.length - 32)}`;
  }
}
