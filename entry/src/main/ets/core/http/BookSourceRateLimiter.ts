import { BookSource } from '../../model/data/Book';
import { sleepMs } from '../../utils/Sleep';

class BookSourceRateState {
  timestamps: number[] = [];
}

/** Why a request may not be sent yet. */
export enum RateLimitAcquireResult {
  Acquired = 0,
  Cancelled = 1,
  // waited as long as allowed and the source's window is still full
  RateLimited = 2
}

export class BookSourceRateLimiter {
  private static states: Record<string, BookSourceRateState> = {};
  // Sleep in slices so a cancelled caller is released promptly instead of after the whole window.
  private static readonly WAIT_SLICE_MS: number = 500;

  /**
   * Waits for a slot in the source's `concurrentRate` window.
   * @param isCancelled checked before every wait slice; a cancelled wait consumes no slot
   * @param maxWaitMs total waiting allowed; 0 (the default) waits as long as the window requires, which is what
   *   reading and caching want. Searching passes a cap: a source may declare windows of up to an hour.
   */
  static async acquire(source: BookSource | null, isCancelled?: () => boolean,
    maxWaitMs: number = 0): Promise<RateLimitAcquireResult> {
    if (!source || !source.concurrentRate) return RateLimitAcquireResult.Acquired;
    const config = this.parse(source.concurrentRate);
    if (!config) return RateLimitAcquireResult.Acquired;
    const key = source.bookSourceUrl || source.bookSourceName;
    if (!key) return RateLimitAcquireResult.Acquired;
    const deadline = maxWaitMs > 0 ? Date.now() + maxWaitMs : 0;
    let state = this.states[key];
    if (!state) {
      state = new BookSourceRateState();
      this.states[key] = state;
    }
    while (true) {
      if (isCancelled && isCancelled()) return RateLimitAcquireResult.Cancelled;
      const now = Date.now();
      state.timestamps = state.timestamps.filter(timestamp => now - timestamp < config.windowMs);
      if (state.timestamps.length < config.limit) {
        state.timestamps.push(now);
        return RateLimitAcquireResult.Acquired;
      }
      let waitMs = Math.max(1, state.timestamps[0] + config.windowMs - now);
      if (deadline > 0) {
        if (now >= deadline) return RateLimitAcquireResult.RateLimited;
        waitMs = Math.min(waitMs, deadline - now);
      }
      await sleepMs(Math.min(waitMs, BookSourceRateLimiter.WAIT_SLICE_MS));
    }
  }

  private static parse(value: string): { limit: number, windowMs: number } | null {
    const match = (value || '').match(/^\s*(\d+)\s*\/\s*(\d+)\s*$/);
    if (!match) return null;
    const limit = Math.min(1000, Math.max(1, parseInt(match[1])));
    const windowMs = Math.min(60 * 60 * 1000, Math.max(100, parseInt(match[2])));
    return { limit: limit, windowMs: windowMs };
  }
}
