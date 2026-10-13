import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { ThemeRuntime } from '../theme/ThemeRuntime';
import { syncSystemBars } from '../utils/SystemBars';
import { AppFontSize } from '../theme/AppFontSize';
import { PageScaffold } from '../components/common/PageScaffold';

@Entry
@Component
struct HelpPage {
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;
  private webController: webview.WebviewController = new webview.WebviewController();
  /** 打开后要滚动到的小节 id，由调用方通过 anchor 参数传入。 */
  private anchor: string = '';

  aboutToAppear(): void {
    this.syncBars();
    const params = router.getParams() as Record<string, string> | undefined;
    const anchor = params && typeof params['anchor'] === 'string' ? params['anchor'] : '';
    this.anchor = /^[A-Za-z0-9_-]+$/.test(anchor) ? anchor : '';
  }

  onPageShow(): void {
    this.syncBars();
  }

  build() {
    Stack() {
      PageScaffold({ title: '使用说明', scrollable: false, content: () => {
        this.pageContent()
      } })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  pageContent() {
    // 说明书随 HAP 打包在 rawfile/manual，离线可读；内容与 docs/manual 保持一致
    Web({ src: $rawfile('manual/index.html'), controller: this.webController })
      .javaScriptAccess(true)
      .fileAccess(false)
      .geolocationAccess(false)
      .zoomAccess(false)
      .darkMode(this.appDarkMode ? WebDarkMode.On : WebDarkMode.Off)
      .forceDarkAccess(false)
      .backgroundColor(this.pageColor())
      .onPageEnd(() => {
        if (!this.anchor) return;
        this.webController.runJavaScript(
          `(function(){var e=document.getElementById('${this.anchor}');if(e){e.scrollIntoView();}})()`)
          .catch((error: Error) => {
            console.warn('定位说明书小节失败:', error.message);
          });
      })
      .onLoadIntercept((event) => {
        const url = event?.data?.getRequestUrl() || '';
        if (url.startsWith('http://') || url.startsWith('https://')) {
          // 外部链接交给系统浏览器，说明页本身不联网
          this.openExternal(url);
          return true;
        }
        return false;
      })
      .width('100%')
      .layoutWeight(1)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  openExternal(url: string): void {
    const context = getContext(this) as common.UIAbilityContext;
    context.openLink(url).catch((error: Error) => {
      console.error('打开外部链接失败:', error);
    });
  }

  pageColor(): string {
    return ThemeRuntime.pageColor(this.appDarkMode);
  }

  primaryTextColor(): string {
    return ThemeRuntime.primaryTextColor(this.appDarkMode);
  }

  syncBars(): void {
    syncSystemBars(getContext(this), this.appDarkMode, this.pageColor());
  }
}
