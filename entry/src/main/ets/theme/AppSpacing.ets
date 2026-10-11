/**
 * 应用界面的间距档位（vp），用于内边距、外边距和子元素间隔。
 * 0、1 这类细线级数值和 24 以上的特殊留白仍直接写数字。
 */
export class AppSpacing {
  /** 图标与文字贴近、标签内上下留白。 */
  static readonly XXS: number = 2;
  /** 同一组内紧凑排列的元素。 */
  static readonly XS: number = 4;
  /** 标题与说明、小控件之间。 */
  static readonly SM: number = 6;
  /** 行内元素之间、小块的内边距。 */
  static readonly MD: number = 8;
  /** 卡片内边距、列表项之间。 */
  static readonly LG: number = 12;
  /** 页面左右边距、卡片之间。 */
  static readonly XL: number = 16;
  /** 分组之间。 */
  static readonly XXL: number = 20;
  /** 大块内容之间、弹窗内边距。 */
  static readonly XXXL: number = 24;
}
