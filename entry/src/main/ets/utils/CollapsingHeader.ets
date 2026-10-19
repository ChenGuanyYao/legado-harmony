/**
 * 首页（书架/发现/搜索）列表滚动时收起的大标题行：上滑跟手收起、下滑跟手展开，
 * 页签、频道栏、搜索框等仍固定在顶部。
 *
 * 收起量永远不超过列表实际滚动距离：列表顶部留白按标题行完全展开时的高度预留，
 * 所以刚开始滚动或顶部回弹时，标题行下方不会露出空隙。
 */
export class CollapsingHeader {
  /** 可收起的高度，即标题行去掉状态栏后的高度。 */
  static readonly DISTANCE: number = 56;

  static next(current: number, delta: number, offset: number): number {
    if (!Number.isFinite(delta) || !Number.isFinite(offset)) {
      return current;
    }
    const max = Math.min(CollapsingHeader.DISTANCE, Math.max(0, offset));
    return Math.round(Math.min(max, Math.max(0, current + delta)));
  }

  /** 停止滚动时吸附到完全展开或完全收起，避免标题行停在半截。 */
  static settle(current: number, offset: number): number {
    if (current <= 0 || current >= CollapsingHeader.DISTANCE) {
      return current;
    }
    return current > CollapsingHeader.DISTANCE / 2 && offset >= CollapsingHeader.DISTANCE ?
      CollapsingHeader.DISTANCE : 0;
  }

  /** 标题行内容在收起过半前就淡出，不会滑进状态栏里和系统图标叠在一起。 */
  static contentOpacity(collapse: number): number {
    return Math.max(0, 1 - collapse / (CollapsingHeader.DISTANCE * 0.6));
  }

  static acceptsTouch(collapse: number): boolean {
    return collapse < CollapsingHeader.DISTANCE / 2;
  }
}
