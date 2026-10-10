/** 解析用户输入的章节范围（纯逻辑）。 */
export class ReaderChapterRange {
  /**
   * 把 "1-10"、"1,3,5-8"、"3 至 9" 这类输入解析成去重、升序的章节下标（从 0 开始）。
   * 任何一段无法识别或越界都视为整体无效，返回空数组，由调用方提示重新输入。
   */
  static parse(raw: string, total: number): number[] {
    const value = (raw || '').trim();
    if (!value || total <= 0) return [];
    const normalized = value.replace(/[，、；;]/g, ',').replace(/[～至]/g, '-');
    const result = new Set<number>();
    for (const part of normalized.split(/[\s,]+/)) {
      if (!part) continue;
      const range = part.match(/^(\d+)\s*-\s*(\d+)$/);
      if (range) {
        const start = Number.parseInt(range[1], 10);
        const end = Number.parseInt(range[2], 10);
        if (start < 1 || end < 1 || start > total || end > total) return [];
        const low = Math.min(start, end);
        const high = Math.max(start, end);
        for (let chapterNumber = low; chapterNumber <= high; chapterNumber++) {
          result.add(chapterNumber - 1);
        }
        continue;
      }
      if (!/^\d+$/.test(part)) return [];
      const chapterNumber = Number.parseInt(part, 10);
      if (chapterNumber < 1 || chapterNumber > total) return [];
      result.add(chapterNumber - 1);
    }
    return Array.from(result).sort((left: number, right: number) => left - right);
  }
}
