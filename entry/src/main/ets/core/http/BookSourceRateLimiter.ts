import { BookSource } from '../../model/data/Book';

class BookSourceRateState {
  timestamps: number[] = [];
}

export class BookSourceRateLimiter {
  private static states: Record<string, BookSourceRateState> = {};

  static async acquire(source: BookSource | null): Promise<void> {
    if (!source || !source.concurrentRate) return;
    const config = this.parse(source.concurrentRate);
    if (!config) return;
    const key = source.bookSourceUrl || source.bookSourceName;
    if (!key) return;
    let state = this.states[key];
    if (!state) {
      state = new BookSourceRateState();
      this.states[key] = state;
    }
    while (true) {
      const now = Date.now();
      state.timestamps = state.timestamps.filter(timestamp => now - timestamp < config.windowMs);
      if (state.timestamps.length < config.limit) {
        state.timestamps.push(now);
        return;
      }
      const waitMs = Math.max(1, state.timestamps[0] + config.windowMs - now);
      await this.delay(waitMs);
    }
  }

  private static parse(value: string): { limit: number, windowMs: number } | null {
    const match = (value || '').match(/^\s*(\d+)\s*\/\s*(\d+)\s*$/);
    if (!match) return null;
    const limit = Math.min(1000, Math.max(1, parseInt(match[1])));
    const windowMs = Math.min(60 * 60 * 1000, Math.max(100, parseInt(match[2])));
    return { limit: limit, windowMs: windowMs };
  }

  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(resolve, ms);
    });
  }
}
