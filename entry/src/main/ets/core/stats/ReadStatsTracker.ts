import { Context } from '@kit.AbilityKit';
import { appDb, ReadStatsEntry } from '../../model/data/AppDatabase';

/**
 * 阅读时长计时器（进程级单例）。
 *
 * 双通道采集：
 * - 阅读通道：ReadBook 页面可见即计时，App 切后台暂停；
 * - 听书通道：TTS/听书播放中即计时（ReaderTtsFloatingSession 驱动），后台长时任务播放照常累计。
 *
 * 同一时刻只计一个通道（听书优先），避免"阅读页开着朗读"被双计。
 * 结算时机：通道/书目切换、每 60 秒定时、应用前后台切换；跨午夜的时间段按 00:00 拆分到两天。
 */
export class ReadStatsTracker {
  private static readonly FLUSH_INTERVAL_MS: number = 60000;

  private static instance: ReadStatsTracker | null = null;

  private context: Context | null = null;
  private appForeground: boolean = true;
  private readingBookUrl: string = '';
  private ttsBookUrl: string = '';
  private currentBookUrl: string = '';
  private segmentStart: number = 0;
  private flushTimerId: number = -1;
  private dbReady: boolean = false;

  static getInstance(): ReadStatsTracker {
    if (!ReadStatsTracker.instance) {
      ReadStatsTracker.instance = new ReadStatsTracker();
    }
    return ReadStatsTracker.instance;
  }

  init(context: Context): void {
    this.context = context;
  }

  /** 阅读通道：reader 页可见时传入当前书，隐藏/销毁时传空串。 */
  setReadingActive(bookUrl: string): void {
    if (this.readingBookUrl === bookUrl) return;
    this.readingBookUrl = bookUrl;
    this.refreshSegment();
  }

  /** 听书通道：播放中传入书 url，暂停/停止传空串。后台播放不受 appForeground 影响。 */
  setTtsActive(bookUrl: string): void {
    if (this.ttsBookUrl === bookUrl) return;
    this.ttsBookUrl = bookUrl;
    this.refreshSegment();
  }

  /** 应用级开关：仅影响阅读通道（ReadBook onPageHide 与 EntryAbility.onBackground 双保险）。 */
  setAppForeground(foreground: boolean): void {
    if (this.appForeground === foreground) return;
    this.appForeground = foreground;
    this.refreshSegment();
  }

  /** 立即结算当前段（进程退出前调用，尽量减少丢数）。 */
  flush(): void {
    this.settleCurrentSegment(Date.now());
  }

  private effectiveBookUrl(): string {
    if (this.ttsBookUrl) return this.ttsBookUrl;
    if (this.appForeground && this.readingBookUrl) return this.readingBookUrl;
    return '';
  }

  private refreshSegment(): void {
    const target = this.effectiveBookUrl();
    if (target === this.currentBookUrl) return;
    this.settleCurrentSegment(Date.now());
    this.currentBookUrl = target;
    this.segmentStart = target ? Date.now() : 0;
    this.updateFlushTimer();
  }

  private settleCurrentSegment(now: number): void {
    if (!this.currentBookUrl || this.segmentStart <= 0 || now <= this.segmentStart) return;
    const entries: ReadStatsEntry[] = [];
    let cursor = this.segmentStart;
    while (cursor < now) {
      const nextMidnight = ReadStatsTracker.nextMidnightTs(cursor);
      const segmentEnd = Math.min(now, nextMidnight);
      const durationMs = segmentEnd - cursor;
      if (durationMs > 0) {
        const entry = new ReadStatsEntry();
        entry.dayKey = ReadStatsTracker.dayKeyOf(cursor);
        entry.bookUrl = this.currentBookUrl;
        entry.durationMs = durationMs;
        entry.lastReadAt = segmentEnd;
        entries.push(entry);
      }
      cursor = segmentEnd;
    }
    this.segmentStart = this.currentBookUrl ? now : 0;
    if (entries.length > 0) {
      this.writeEntries(entries);
    }
  }

  private async writeEntries(entries: ReadStatsEntry[]): Promise<void> {
    try {
      if (!this.dbReady) {
        if (!this.context) return;
        await appDb.init(this.context);
        this.dbReady = true;
      }
      await appDb.addReadStats(entries);
    } catch (error) {
      console.warn('[ReadStats] 阅读时长入库失败', error);
    }
  }

  private updateFlushTimer(): void {
    const need = this.currentBookUrl !== '';
    if (need && this.flushTimerId < 0) {
      this.flushTimerId = setInterval(() => {
        this.settleCurrentSegment(Date.now());
      }, ReadStatsTracker.FLUSH_INTERVAL_MS);
    } else if (!need && this.flushTimerId >= 0) {
      clearInterval(this.flushTimerId);
      this.flushTimerId = -1;
    }
  }

  private static pad2(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  /** 本地时区日期键 'YYYY-MM-DD'。 */
  static dayKeyOf(ts: number): string {
    const d = new Date(ts);
    return `${d.getFullYear()}-${ReadStatsTracker.pad2(d.getMonth() + 1)}-${ReadStatsTracker.pad2(d.getDate())}`;
  }

  private static nextMidnightTs(ts: number): number {
    const d = new Date(ts);
    return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1).getTime();
  }
}

export const readStatsTracker = ReadStatsTracker.getInstance();
