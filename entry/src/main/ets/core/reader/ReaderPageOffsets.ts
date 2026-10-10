/**
 * 页索引与章节字符偏移之间的映射（纯逻辑）。阅读进度按字符偏移持久化，
 * 重新分页后靠这里把偏移落回页码。
 */
export class ReaderPageOffsets {
  static startOf(starts: number[], pageIndex: number): number {
    if (starts.length === 0) {
      return 0;
    }
    const index = Math.max(0, Math.min(pageIndex, starts.length - 1));
    return Math.max(0, starts[index]);
  }

  static endOf(starts: number[], ends: number[], pageIndex: number, emptyFallback: number): number {
    if (ends.length === 0) {
      return emptyFallback;
    }
    const index = Math.max(0, Math.min(pageIndex, ends.length - 1));
    return Math.max(ReaderPageOffsets.startOf(starts, index), ends[index]);
  }

  /**
   * 偏移落在页内返回该页；落在两页之间被裁掉的空白里返回后一页；越过末尾返回最后一页。
   * starts 为空时返回 -1，由调用方决定回退页。
   */
  static pageIndexOf(starts: number[], ends: number[], offset: number, sourceLength: number): number {
    if (starts.length === 0) {
      return -1;
    }
    const clampedOffset = Math.max(0, Math.min(offset, Math.max(0, sourceLength - 1)));
    for (let i = 0; i < starts.length; i++) {
      if (clampedOffset >= starts[i] && clampedOffset < ends[i]) {
        return i;
      }
      if (i < starts.length - 1 && clampedOffset >= ends[i] && clampedOffset < starts[i + 1]) {
        return i + 1;
      }
    }
    return Math.max(0, starts.length - 1);
  }
}
