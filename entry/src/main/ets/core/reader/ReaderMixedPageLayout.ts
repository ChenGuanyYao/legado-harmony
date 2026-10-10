import { ReaderImageMarker } from '../book/ReaderImageMarker';

/** 一张图片在页面中占据的盒子（物理像素）。 */
export class ReaderMixedImageBox {
  widthPx: number = 0;
  heightPx: number = 0;
  /** true：填满本页剩余空间的整页插图；false：按原始尺寸随文排版的小图。 */
  fill: boolean = true;
}

/** 分页器需要宿主提供的几何参数与文本测量能力。 */
export class ReaderMixedPageHost {
  availableWidthPx: number = 1;
  availableHeightPx: number = 1;
  minImageHeightPx: number = 1;
  /** 图片原始像素按 vp 解释（与 CSS px 一致），这里是 1vp 对应的物理像素。 */
  pxPerVp: number = 1;
  isTrimChar: (value: string) => boolean = (value: string): boolean => value === ' ' || value === '\n';
  /** 从 start 起、高度不超过 availableHeightPx 的文本页终点。 */
  findTextPageEnd: (source: string, start: number, availableHeightPx: number) => number =
    (_source: string, start: number, _availableHeightPx: number): number => start;
  measureTextHeightPx: (source: string, start: number, end: number) => number =
    (_source: string, _start: number, _end: number): number => 0;
  /** 相邻两个块之间的间距；任一侧是独立组件（图片、按钮）时 independent 为 true。 */
  boundaryPx: (independent: boolean) => number = (_independent: boolean): number => 0;
  isIndependentParagraph: (text: string) => boolean = (_text: string): boolean => false;
  /** 把 pageText 作为一页时，页高减去全部文字与块间距后的剩余高度（与渲染使用同一算法）。 */
  leftoverPx: (pageText: string) => number = (_pageText: string): number => 0;
}

/**
 * 图文混排页的分页与图片尺寸规则（纯逻辑，分页与渲染共用）：
 * - 小图（分隔线、图标、小插图）按原始尺寸随文排版，后面的文字接着排在同一页；
 * - 大图与尺寸未知的图片是整页插图：填满本页剩余空间并结束这一页；
 * - 剩余空间不足以体面地放下图片时，图片移到下一页。
 */
export class ReaderMixedPageLayout {
  /** 原始高度低于页高的这个比例才算随文小图。 */
  static readonly INLINE_HEIGHT_RATIO: number = 0.4;
  /** 整页插图最多被压缩到自身（不超过一页）高度的这个比例，再小就换页。 */
  static readonly FILL_MIN_RATIO: number = 0.5;

  /** 图片按原始尺寸显示时的盒子；标记不带尺寸时返回 null。 */
  static naturalBox(marker: string, host: ReaderMixedPageHost): ReaderMixedImageBox | null {
    const info = ReaderImageMarker.parse(marker);
    return ReaderMixedPageLayout.naturalBoxForSize(info.width, info.height, host.availableWidthPx,
      host.availableHeightPx, host.pxPerVp);
  }

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

  /**
   * 一页内各图片的盒子。leftoverPx 是页高减去全部文字与块间距之后的剩余高度：
   * 小图取原始尺寸，填充型图片平分其余空间。
   */
  static imageBoxes(markers: string[], leftoverPx: number, host: ReaderMixedPageHost): ReaderMixedImageBox[] {
    const boxes: ReaderMixedImageBox[] = [];
    let inlineHeightPx = 0;
    let fillCount = 0;
    for (const marker of markers) {
      const natural = ReaderMixedPageLayout.naturalBox(marker, host);
      if (natural && !natural.fill) {
        inlineHeightPx += natural.heightPx;
        boxes.push(natural);
      } else {
        const box = new ReaderMixedImageBox();
        box.widthPx = host.availableWidthPx;
        boxes.push(box);
        fillCount++;
      }
    }
    if (fillCount > 0) {
      const share = (leftoverPx - inlineHeightPx) / fillCount;
      const heightPx = Math.min(host.availableHeightPx, Math.max(host.minImageHeightPx, share));
      for (const box of boxes) {
        if (box.fill) box.heightPx = heightPx;
      }
    }
    return boxes;
  }

  /** 从 start 起的一页在 source 中的结束偏移。保证返回值大于跳过空白后的起点。 */
  static findPageEnd(source: string, start: number, host: ReaderMixedPageHost): number {
    const text = source || '';
    const length = text.length;
    let safeStart = Math.max(0, Math.min(start, length));
    while (safeStart < length && host.isTrimChar(text.charAt(safeStart))) safeStart++;
    if (safeStart >= length) return length;

    const availablePx = Math.max(1, host.availableHeightPx);
    let cursor = safeStart;
    let pageEnd = -1;
    let usedPx = 0;
    let hasContent = false;
    let previousIndependent = false;
    let inlineImagePx = 0;

    while (cursor < length) {
      const markerStart = text.indexOf(ReaderImageMarker.PREFIX, cursor);
      const segmentEnd = markerStart < 0 ? length : markerStart;
      if (segmentEnd > cursor) {
        const segment = text.substring(cursor, segmentEnd);
        if (segment.trim()) {
          const paragraphs = segment.split(/\n+/).filter((item: string): boolean => !!item.trim());
          const firstIndependent = paragraphs.length > 0 && host.isIndependentParagraph(paragraphs[0]);
          const boundaryPx = hasContent ? host.boundaryPx(previousIndependent || firstIndependent) : 0;
          const remainingPx = availablePx - usedPx - boundaryPx;
          let measuredEnd = Math.min(segmentEnd, host.findTextPageEnd(text, cursor, Math.max(1, remainingPx)));
          // 文本分页器返回的终点不含段落后的空白：只差空白就到图片时，这段文字已经全部放下了。
          if (measuredEnd > cursor && measuredEnd < segmentEnd && !text.substring(measuredEnd, segmentEnd).trim()) {
            measuredEnd = segmentEnd;
          }
          // 没有文字还能放进这一页：保留已经确定的内容。
          if (measuredEnd <= cursor) break;
          if (hasContent) {
            // 文本分页器为了保证前进，在空间不足时也会返回至少一行。图片之后的文字必须真的放得下。
            const heightPx = host.measureTextHeightPx(text, cursor, measuredEnd);
            if (remainingPx <= 0 || heightPx > remainingPx + 1) break;
            if (measuredEnd < segmentEnd) return measuredEnd;
            usedPx += boundaryPx + heightPx;
          } else {
            // 文字自己就排满了这一页，图片从下一页开始。
            if (measuredEnd < segmentEnd) return measuredEnd;
            usedPx += boundaryPx + host.measureTextHeightPx(text, cursor, segmentEnd);
          }
          previousIndependent = paragraphs.length > 0 &&
            host.isIndependentParagraph(paragraphs[paragraphs.length - 1]);
          hasContent = true;
          pageEnd = segmentEnd;
        }
        cursor = segmentEnd;
      }
      if (markerStart < 0) break;
      const suffix = text.indexOf(ReaderImageMarker.SUFFIX, markerStart + ReaderImageMarker.PREFIX.length);
      if (suffix < 0) break;
      const markerEnd = suffix + ReaderImageMarker.SUFFIX.length;
      const natural = ReaderMixedPageLayout.naturalBox(text.substring(markerStart, markerEnd), host);
      if (natural && !natural.fill) {
        const boundaryPx = hasContent ? host.boundaryPx(true) : 0;
        // 页面已有内容且放不下这张小图：这一页到此为止，小图排到下一页开头。
        if (hasContent && usedPx + boundaryPx + natural.heightPx > availablePx + 1) break;
        usedPx += boundaryPx + natural.heightPx;
        inlineImagePx += natural.heightPx;
        hasContent = true;
        previousIndependent = true;
        pageEnd = markerEnd;
        cursor = markerEnd;
        continue;
      }
      // 整页插图总是结束当前页：它填满前文留下的空间，后面的文字从下一页继续。
      if (!hasContent) return markerEnd;
      const wantedPx = natural ? Math.min(natural.heightPx, availablePx) * ReaderMixedPageLayout.FILL_MIN_RATIO : 0;
      const sharePx = host.leftoverPx(text.substring(safeStart, markerEnd)) - inlineImagePx;
      if (sharePx >= Math.max(host.minImageHeightPx, wantedPx)) return markerEnd;
      // 图片在这一页会被压得太小：在图片之前结束本页，让它在下一页得到完整空间。
      break;
    }
    if (pageEnd > safeStart) return pageEnd;
    // 前进保证：永远不返回起点。起点就是一个标记时至少越过它。
    if (text.startsWith(ReaderImageMarker.PREFIX, safeStart)) {
      const suffix = text.indexOf(ReaderImageMarker.SUFFIX, safeStart + ReaderImageMarker.PREFIX.length);
      if (suffix >= 0) return suffix + ReaderImageMarker.SUFFIX.length;
    }
    return Math.min(length, Math.max(safeStart + 1, host.findTextPageEnd(text, safeStart, availablePx)));
  }
}
