import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { ImmersiveBackButton } from '../components/ImmersiveBackButton';
import { ThemeRuntime } from '../theme/ThemeRuntime';
import { syncSystemBars } from '../utils/SystemBars';

@Entry
@Component
struct HelpPage {
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  private webController: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    this.syncBars();
  }

  onPageShow(): void {
    this.syncBars();
  }

  build() {
    Column() {
      Row() {
        ImmersiveBackButton({ iconColor: this.primaryTextColor(), darkMode: this.appDarkMode,
          buttonSize: 40, containerWidth: 56, materialScale: 0.83, compactLayout: true,
          onBack: () => router.back() })

        Text('使用说明')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
          .layoutWeight(1)
      }
      .width('100%')
      .height(56 + this.statusBarHeight)
      .padding({ top: this.statusBarHeight })
      .backgroundColor(ThemeRuntime.topBarColor(this.appDarkMode))
      .alignItems(VerticalAlign.Center)

      // 说明书随 HAP 打包在 rawfile/manual，离线可读；内容与 docs/manual 保持一致
      Web({ src: $rawfile('manual/index.html'), controller: this.webController })
        .javaScriptAccess(true)
        .fileAccess(false)
        .geolocationAccess(false)
        .zoomAccess(false)
        .darkMode(this.appDarkMode ? WebDarkMode.On : WebDarkMode.Off)
        .forceDarkAccess(false)
        .backgroundColor(this.pageColor())
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
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
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
