import { webview } from '@kit.ArkWeb';
import { BookSourceStageWebRuntime } from '../core/book/BookSourceStageWebRuntime';

/** Keeps the shared full-JavaScript source runtime available on routed book pages. */
@Component
export struct BookSourceStageRuntimeHost {
  private controller: webview.WebviewController = new webview.WebviewController();
  @State mounted: boolean = true;
  private resetScheduled: boolean = false;

  aboutToDisappear(): void {
    BookSourceStageWebRuntime.get().clearResetHandler(this.controller);
    BookSourceStageWebRuntime.get().detach(this.controller);
  }

  private resetHost(): void {
    if (this.resetScheduled) return;
    this.resetScheduled = true;
    const previous = this.controller;
    BookSourceStageWebRuntime.get().clearResetHandler(previous);
    BookSourceStageWebRuntime.get().detach(previous);
    this.mounted = false;
    setTimeout(() => {
      this.controller = new webview.WebviewController();
      this.mounted = true;
      this.resetScheduled = false;
    }, 0);
  }

  build() {
    if (this.mounted) {
      Web({ src: 'about:blank', controller: this.controller })
        .width(1)
        .height(1)
        .opacity(0.01)
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .mixedMode(MixedMode.All)
        .onControllerAttached(() => {
          BookSourceStageWebRuntime.get().attach(this.controller);
          BookSourceStageWebRuntime.get().setResetHandler((): void => this.resetHost(), this.controller);
        })
        .onPageBegin(() => {
          BookSourceStageWebRuntime.get().setReady(false, this.controller);
        })
        .onPageEnd(() => {
          BookSourceStageWebRuntime.get().setReady(true, this.controller);
        })
    }
  }
}
