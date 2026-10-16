import { ReaderContinuousDataSource, ReaderScrollSegment } from './ReaderDataSources';

/** 阅读页为相邻章节预装提供的环境。 */
export interface ReaderNeighborChapterHost {
  visible: () => boolean;
  bookUrl: () => string;
  isCurrentBook: (bookUrl: string) => boolean;
  currentChapter: () => number;
  chapterCount: () => number;
  isComic: () => boolean;
  /** 条漫或小说滚动模式（列表首尾接章）。 */
  isScrollList: () => boolean;
  /** 漫画翻页模式（预切相邻章节给翻页视图）。 */
  isPagedComic: () => boolean;
  scrollWindow: () => ReaderContinuousDataSource;
  /** 按正式加载的同一套流程取正文并切块；正文为空或没切出页时返回 null。 */
  prepare: (chapterIndex: number) => Promise<ReaderScrollSegment | null>;
  /** 翻页模式的相邻章节切好了。 */
  publishPagedNeighbor: (chapterIndex: number, pages: string[]) => void;
}

/**
 * 相邻章节预装：滚动模式接到列表首尾，漫画翻页模式交给翻页视图。
 * 同一章同时只取一次；取失败后冷却 30 秒，期间滚动、翻页都不再自动重试，
 * 免得对拒绝访问或断网的书源反复请求（手动切章不受影响）。
 */
export class ReaderNeighborChapterLoader {
  private static readonly RETRY_COOLDOWN_MS: number = 30000;
  private readonly host: ReaderNeighborChapterHost;
  private loading: Set<number> = new Set();
  private failedAt: Map<number, number> = new Map();

  constructor(host: ReaderNeighborChapterHost) {
    this.host = host;
  }

  reset(): void {
    this.loading.clear();
    this.failedAt.clear();
  }

  private canStart(chapterIndex: number): boolean {
    if (chapterIndex < 0 || chapterIndex >= this.host.chapterCount() || this.loading.has(chapterIndex)) return false;
    return Date.now() - (this.failedAt.get(chapterIndex) || 0) >= ReaderNeighborChapterLoader.RETRY_COOLDOWN_MS;
  }

  /**
   * 滚动模式：当前章末尾进入视口附近时接上下一章，开头附近时接上上一章（列表序号）。
   * currentLength 为当前章的块数。
   */
  ensureScrollNeighbors(listStart: number, listEnd: number, currentLength: number): void {
    if (!this.host.isScrollList() || this.host.isPagedComic()) return;
    const window = this.host.scrollWindow();
    const current = this.host.currentChapter();
    const offset = window.offsetOf(current);
    if (offset < 0) return;
    if (window.lastChapter() === current && listEnd >= offset + currentLength - 3) {
      this.loadScrollNeighbor(current + 1);
    }
    if (window.firstChapter() === current && listStart <= offset + 2) {
      this.loadScrollNeighbor(current - 1);
    }
  }

  private isScrollNeighborWanted(chapterIndex: number, generation: number, bookUrl: string,
    comicMode: boolean): boolean {
    const window = this.host.scrollWindow();
    return this.host.visible() && window.generation() === generation && this.host.isCurrentBook(bookUrl) &&
      comicMode === this.host.isComic() && this.host.isScrollList() && !this.host.isPagedComic() &&
      !window.segment(chapterIndex) &&
      (chapterIndex === window.lastChapter() + 1 || chapterIndex === window.firstChapter() - 1);
  }

  private async loadScrollNeighbor(chapterIndex: number): Promise<void> {
    if (!this.canStart(chapterIndex)) return;
    const window = this.host.scrollWindow();
    if (window.segment(chapterIndex)) return;
    const generation = window.generation();
    const bookUrl = this.host.bookUrl();
    const comicMode = this.host.isComic();
    const forward = chapterIndex > window.lastChapter();
    this.loading.add(chapterIndex);
    if (forward) window.setTrailingState(true, false);
    try {
      const segment = await this.host.prepare(chapterIndex);
      if (!this.isScrollNeighborWanted(chapterIndex, generation, bookUrl, comicMode)) return;
      if (!segment) {
        this.failedAt.set(chapterIndex, Date.now());
        if (forward) window.setTrailingState(false, true);
        return;
      }
      if (forward) {
        window.append(segment, chapterIndex < this.host.chapterCount() - 1 ? chapterIndex + 1 : -1);
      } else {
        window.prepend(segment);
      }
    } catch (error) {
      console.warn(`[ReaderContinuous] 相邻章节装入失败 chapter=${chapterIndex}:`, error);
      this.failedAt.set(chapterIndex, Date.now());
      if (forward && this.isScrollNeighborWanted(chapterIndex, generation, bookUrl, comicMode)) {
        window.setTrailingState(false, true);
      }
    } finally {
      this.loading.delete(chapterIndex);
    }
  }

  /** 漫画翻页模式：预切一个相邻章节（chapterIndex 必须与当前章相邻）。 */
  async loadPagedNeighbor(chapterIndex: number): Promise<void> {
    if (!this.canStart(chapterIndex)) return;
    const bookUrl = this.host.bookUrl();
    this.loading.add(chapterIndex);
    try {
      const segment = await this.host.prepare(chapterIndex);
      if (!this.host.visible() || !this.host.isPagedComic() || !this.host.isCurrentBook(bookUrl) ||
        Math.abs(chapterIndex - this.host.currentChapter()) !== 1) {
        return;
      }
      if (!segment) {
        this.failedAt.set(chapterIndex, Date.now());
        return;
      }
      this.host.publishPagedNeighbor(chapterIndex, segment.pages);
    } catch (error) {
      console.warn(`[ReaderComicPaged] 相邻章节预切失败 chapter=${chapterIndex}:`, error);
      this.failedAt.set(chapterIndex, Date.now());
    } finally {
      this.loading.delete(chapterIndex);
    }
  }
}
