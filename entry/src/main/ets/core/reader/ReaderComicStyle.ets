import { ReaderComicBackground } from './ReaderComicSettings';

/** 漫画画面的配色：由「背景」设置与当前阅读主题算出，纯计算。 */
export class ReaderComicStyle {
  /** 漫画视图底色；跟随主题时透明，露出下面的阅读主题底色与背景图。 */
  static surfaceColor(background: string): string {
    if (background === ReaderComicBackground.WHITE) return '#FFFFFF';
    if (background === ReaderComicBackground.THEME) return '#00000000';
    return '#000000';
  }

  /** 窗口与加载遮罩的底色（不能透明）。 */
  static windowColor(background: string, themeBackground: string): string {
    return background === ReaderComicBackground.THEME ? themeBackground : ReaderComicStyle.surfaceColor(background);
  }

  static isDark(background: string, themeDark: boolean): boolean {
    if (background === ReaderComicBackground.WHITE) return false;
    if (background === ReaderComicBackground.THEME) return themeDark;
    return true;
  }

  static textColor(background: string, themeText: string, themeDark: boolean): string {
    if (background === ReaderComicBackground.THEME) return themeText;
    return ReaderComicStyle.isDark(background, themeDark) ? '#E0E0E0' : '#333333';
  }

  static hintColor(background: string, themeSubText: string, themeDark: boolean): string {
    if (background === ReaderComicBackground.THEME) return themeSubText;
    return ReaderComicStyle.isDark(background, themeDark) ? '#99FFFFFF' : '#8C000000';
  }
}
