/** 一张图片在页面中占据的盒子（物理像素）。 */
export class ReaderMixedImageBox {
  widthPx: number = 0;
  heightPx: number = 0;
  /** true：填满本页剩余空间的整页插图；false：按原始尺寸随文排版的小图。 */
  fill: boolean = true;
}

/**
 * 图文混排里图片尺寸的判定规则（纯逻辑，由 V2 分页器使用）：
 * - 小图（分隔线、图标、小插图）按原始尺寸随文排版，后面的文字接着排在同一页；
 * - 大图与尺寸未知的图片是整页插图：填满本页剩余空间并结束这一页；
 * - 剩余空间不足以体面地放下图片时，图片移到下一页。
 */
export class ReaderMixedPageLayout {
  /** 原始高度低于页高的这个比例才算随文小图。 */
  static readonly INLINE_HEIGHT_RATIO: number = 0.4;
  /** 整页插图最多被压缩到自身（不超过一页）高度的这个比例，再小就换页。 */
  static readonly FILL_MIN_RATIO: number = 0.5;

  /** 原始尺寸为 width×height 的图片在给定版心里的盒子；尺寸未知时返回 null。 */
  static naturalBoxForSize(width: number, height: number, availableWidthPx: number, availableHeightPx: number,
    pxPerVp: number): ReaderMixedImageBox | null {
    if (width <= 0 || height <= 0) return null;
    const box = new ReaderMixedImageBox();
    box.widthPx = Math.max(1, Math.min(availableWidthPx, width * Math.max(0.01, pxPerVp)));
    box.heightPx = Math.max(1, box.widthPx * height / width);
    box.fill = box.heightPx >= availableHeightPx * ReaderMixedPageLayout.INLINE_HEIGHT_RATIO;
    return box;
  }
}
