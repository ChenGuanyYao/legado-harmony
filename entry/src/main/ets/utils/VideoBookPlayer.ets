import { router } from '@kit.ArkUI';

/** 视频类书籍（短剧等）没有阅读形态，统一进入播放页；集数在播放页内切换。 */
export class VideoBookPlayer {
  /** chapterIndex 小于 0 表示接着上次看到的那一集。 */
  static async open(bookUrl: string, chapterIndex: number = -1, replace: boolean = false): Promise<void> {
    const options: router.RouterOptions = {
      url: 'pages/VideoPlayer',
      params: { bookUrl: bookUrl, chapterIndex: chapterIndex >= 0 ? `${chapterIndex}` : '' }
    };
    if (replace) await router.replaceUrl(options);
    else await router.pushUrl(options);
  }
}
