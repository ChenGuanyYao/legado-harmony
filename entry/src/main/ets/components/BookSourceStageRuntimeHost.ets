import { webview } from '@kit.ArkWeb';
import { BookSourceStageWebRuntime } from '../core/book/BookSourceStageWebRuntime';

/** Keeps the shared full-JavaScript source runtime available on routed book pages. */
@Component
export struct BookSourceStageRuntimeHost {
  private controller: webview.WebviewController = new webview.WebviewController();

  aboutToDisappear(): void {
    BookSourceStageWebRuntime.get().detach(this.controller);
  }

  build() {
    Web({ src: 'about:blank', controller: this.controller })
      .width(1)
      .height(1)
      .opacity(0.01)
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .mixedMode(MixedMode.All)
      .onControllerAttached(() => {
        BookSourceStageWebRuntime.get().attach(this.controller);
      })
      .onPageBegin(() => {
        BookSourceStageWebRuntime.get().setReady(false, this.controller);
      })
      .onPageEnd(() => {
        BookSourceStageWebRuntime.get().setReady(true, this.controller);
      })
  }
}
