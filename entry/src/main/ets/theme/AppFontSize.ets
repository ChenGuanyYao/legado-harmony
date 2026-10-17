/**
 * 应用界面的字号档位（vp）。页面里的文字统一从这里取，不再各写各的数值。
 * 阅读正文、页眉页脚的字号由阅读设置决定，图标（SymbolGlyph）的尺寸也不走这里。
 */
export class AppFontSize {
  /** 角标、徽标等极小文字。 */
  static readonly MICRO: number = 10;
  /** 说明、标签、次要信息。 */
  static readonly CAPTION: number = 12;
  /** 正文、按钮、输入框。 */
  static readonly BODY: number = 14;
  /** 列表项和设置项的主文字。 */
  static readonly BODY_LARGE: number = 16;
  /** 分组标题、弹窗标题。 */
  static readonly SUBTITLE: number = 18;
  /** 页面标题。 */
  static readonly TITLE: number = 20;
  /** 大标题、突出显示的数字。 */
  static readonly HEADLINE: number = 24;
  /** 首页各页签顶部的大标题。 */
  static readonly DISPLAY: number = 28;
}
