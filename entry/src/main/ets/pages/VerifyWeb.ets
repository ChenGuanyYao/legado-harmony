import { router, promptAction } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { CookieStore } from '../core/http/CookieStore';
import { EncodedSourceUrl } from '../core/book/EncodedSourceUrl';
import { VerificationSupport } from '../core/http/VerificationSupport';
import { AppDatabase } from '../model/data/AppDatabase';
import { BookSource } from '../model/data/Book';
import { syncSystemBars } from '../utils/SystemBars';
import { ImmersiveBackButton } from '../components/ImmersiveBackButton';
import { ThemeRuntime } from '../theme/ThemeRuntime';

/**
 * Restricted bridge used only by HTML passed to java.showBrowser(). Remote pages do not receive
 * the login runtime object: only navigation, user feedback and same-origin cookie operations are
 * exposed, so enabling this bridge cannot reach files, processes, reflection or arbitrary hosts.
 */
class BookSourceBrowserJavaBridge {
  private readonly activeProvider: () => boolean;
  private readonly currentUrlProvider: () => string;
  private readonly navigate: (url: string, title: string) => void;

  constructor(activeProvider: () => boolean, currentUrlProvider: () => string,
    navigate: (url: string, title: string) => void) {
    this.activeProvider = activeProvider;
    this.currentUrlProvider = currentUrlProvider;
    this.navigate = navigate;
  }

  toast(message: string): void {
    this.showToast(String(message || ''));
  }

  longToast(message: string): void {
    this.showToast(String(message || ''));
  }

  startBrowser(url: string, title: string): void {
    this.openTarget(url, title);
  }

  startBrowserDp(url: string, title: string): void {
    this.openTarget(url, title);
  }

  open(url: string): void {
    this.openTarget(url, '');
  }

  openUrl(url: string): void {
    this.openTarget(url, '');
  }

  getCookie(url: string): string {
    if (!this.activeProvider()) return '';
    const target = this.sameOriginTarget(url);
    return target ? CookieStore.getCookie(target) : '';
  }

  setCookie(url: string, value: string): boolean {
    if (!this.activeProvider()) return false;
    const target = this.sameOriginTarget(url);
    const cookie = String(value || '');
    if (!target || !cookie || cookie.length > 16 * 1024) return false;
    CookieStore.setCookies(target, cookie);
    CookieStore.saveAsync();
    return true;
  }

  removeCookie(url: string, name: string): boolean {
    if (!this.activeProvider()) return false;
    const target = this.sameOriginTarget(url);
    if (!target) return false;
    CookieStore.removeCookie(target, String(name || '') || undefined);
    return true;
  }

  private openTarget(url: string, title: string): void {
    if (!this.activeProvider()) return;
    const target = String(url || '').trim();
    if (!/^https?:\/\//i.test(target)) {
      this.showToast('网页请求打开的地址不受支持');
      return;
    }
    this.navigate(target, String(title || ''));
  }

  private sameOriginTarget(url: string): string {
    const current = this.currentUrlProvider() || '';
    const target = String(url || '').trim() || current;
    const currentOrigin = this.originOf(current);
    const targetOrigin = this.originOf(target);
    return currentOrigin && currentOrigin === targetOrigin ? target : '';
  }

  private originOf(url: string): string {
    const match = String(url || '').match(/^(https?:\/\/[^\/:?#]+(?::\d+)?)/i);
    return match ? String(match[1] || '').toLowerCase() : '';
  }

  private showToast(message: string): void {
    if (!this.activeProvider() || !message) return;
    try {
      promptAction.showToast({ message: message.substring(0, 4000) });
    } catch (_) {}
  }
}

@Entry
@Component
struct VerifyWebPage {
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('appLightAccentColor') appLightAccentColor: string = '#007DFF';
  @StorageLink('appDarkAccentColor') appDarkAccentColor: string = '#4E9BFF';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State url: string = '';
  @State title: string = '网页验证';
  @State currentUrl: string = '';
  @State progress: number = 0;
  @State requireLoginCookie: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  private browserAwaitToken: string = '';
  private browserAwaitCompleted: boolean = false;
  private browserPayloadToken: string = '';
  private browserPayloadHtml: string = '';
  private browserPayloadBaseUrl: string = '';
  private browserPayloadInjectJs: string = '';
  private browserPayloadLoaded: boolean = false;
  private browserPayloadInjected: boolean = false;
  private readonly browserJavaBridge: BookSourceBrowserJavaBridge = new BookSourceBrowserJavaBridge(
    (): boolean => !!this.browserPayloadToken,
    (): string => this.currentUrl || this.browserPayloadBaseUrl || this.url,
    (url: string, title: string): void => this.openBridgeUrl(url, title));
  private readonly mobileUserAgent: string =
    'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  private readonly guangYuHosts: string[] = [
    'https://v1.gyks.cf',
    'https://v2.gyks.cf',
    'https://v3.gyks.cf',
    'https://v4.gyks.cf',
    'https://v5.gyks.cf',
    'https://v6.gyks.cf',
    'https://v7.gyks.cf'
  ];

  aboutToAppear(): void {
    this.syncBars();
    const params = router.getParams() as Record<string, string>;
    const initialUrl = params?.['url'] || AppStorage.get<string>('pendingVerificationUrl') || 'https://www.qidian.com';
    this.title = params?.['title'] || AppStorage.get<string>('pendingVerificationTitle') || '网页验证';
    this.requireLoginCookie = params?.['requireLoginCookie'] === 'true';
    this.browserAwaitToken = params?.['bookSourceBrowserAwaitToken'] || '';
    this.browserPayloadToken = params?.['bookSourceBrowserPayloadToken'] || '';
    if (this.browserPayloadToken && this.browserPayloadToken ===
      (AppStorage.get<string>('bookSourceBrowserPayloadToken') || '')) {
      this.browserPayloadHtml = AppStorage.get<string>('bookSourceBrowserPayloadHtml') || '';
      this.browserPayloadBaseUrl = AppStorage.get<string>('bookSourceBrowserPayloadBaseUrl') || initialUrl;
      this.browserPayloadInjectJs = AppStorage.get<string>('bookSourceBrowserPayloadInjectJs') || '';
      this.url = 'about:blank';
      this.currentUrl = this.browserPayloadBaseUrl || initialUrl;
      return;
    }
    if (this.browserAwaitToken) {
      this.url = initialUrl;
      this.currentUrl = initialUrl;
      return;
    }
    if (VerificationSupport.isBookSourceLoginUrl(initialUrl)) {
      this.url = 'about:blank';
      this.currentUrl = '';
      this.resolveBookSourceLoginUrl(initialUrl).catch((e: Error) => {
        console.error('解析书源登录地址失败:', e);
      });
      return;
    }
    this.url = initialUrl;
    this.currentUrl = this.url;
  }

  onPageShow(): void {
    this.syncBars();
  }

  onBackPress(): boolean {
    if (!this.browserAwaitToken) return false;
    this.finishBrowserAwait();
    return true;
  }

  aboutToDisappear(): void {
    if (this.browserAwaitToken && !this.browserAwaitCompleted) {
      this.publishBrowserAwaitResult('', '网页操作已取消');
    }
  }

  build() {
    Column() {
      Row() {
        ImmersiveBackButton({ iconColor: this.primaryTextColor(), darkMode: this.appDarkMode,
          onBack: () => this.finishVerify() })

        Column() {
          Text(this.title)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.primaryTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.currentUrl)
            .fontSize(11)
            .fontColor(this.subTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text('完成')
          .fontSize(15)
          .fontColor(this.accentColor())
          .width(56)
          .height(56)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.finishVerify();
          })
      }
      .width('100%')
      .height(56)
      .padding({ right: 8 })
      .backgroundColor(this.cardColor())
      .alignItems(VerticalAlign.Center)

      if (this.progress > 0 && this.progress < 100) {
        Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(2)
          .color(this.accentColor())
      }

      Web({ src: this.url, controller: this.controller })
        .width('100%')
        .layoutWeight(1)
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .onlineImageAccess(true)
        .imageAccess(true)
        .mixedMode(MixedMode.All)
        .userAgent(this.mobileUserAgent)
        .javaScriptProxy({
          object: this.browserJavaBridge,
          name: 'java',
          methodList: [
            'toast', 'longToast', 'startBrowser', 'startBrowserDp', 'open', 'openUrl',
            'getCookie', 'setCookie', 'removeCookie'
          ],
          controller: this.controller
        })
        .onControllerAttached(() => {
          this.loadBrowserPayload();
        })
        .onPageBegin((event?: OnPageBeginEvent) => {
          if (event?.url) this.currentUrl = event.url;
        })
        .onPageEnd((event?: OnPageEndEvent) => {
          if (event?.url) {
            this.currentUrl = event.url;
            this.saveCookies(event.url);
            this.syncDocumentCookies(event.url);
            this.syncGuangYuDocumentCookies(event.url);
            this.syncGuangYuDeviceCookie(event.url);
          }
          this.injectBrowserPayloadScript();
        })
        .onProgressChange((event?: OnProgressChangeEvent) => {
          this.progress = event?.newProgress || 0;
        })
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.statusBarHeight, bottom: this.navBarHeight })
    .backgroundColor(this.pageColor())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  async finishVerify(): Promise<void> {
    if (this.browserAwaitToken) {
      await this.finishBrowserAwait();
      return;
    }
    if (this.browserPayloadToken) {
      this.saveCookies(this.currentUrl || this.browserPayloadBaseUrl);
      CookieStore.saveSync();
      this.backSafely();
      return;
    }
    const verifyUrl = this.currentUrl || this.url;
    await this.syncDocumentCookiesAwait(verifyUrl);
    this.syncGuangYuDocumentCookies(verifyUrl);
    this.syncGuangYuDeviceCookie(verifyUrl);
    this.saveCookies(verifyUrl);
    if (this.currentUrl && this.currentUrl !== this.url) {
      this.saveCookies(this.url);
      CookieStore.copyCookies(this.currentUrl, this.url);
    }
    this.syncBookSourceLoginCookies();
    this.syncGuangYuCookies(verifyUrl);
    CookieStore.saveSync();
    const isGuangYu = this.isGuangYuVerify(verifyUrl);
    const verified = this.requireLoginCookie ? this.hasEffectiveBookSourceLoginCookie() :
      (!isGuangYu || this.hasGuangYuToken());
    if (verified) {
      AppStorage.setOrCreate('pendingVerificationUrl', '');
      AppStorage.setOrCreate('pendingVerificationTitle', '');
      AppStorage.setOrCreate('pendingVerificationSourceUrl', '');
      AppStorage.setOrCreate('pendingVerificationLoginUrl', '');
      AppStorage.setOrCreate('verificationCompletedAt', Date.now());
      this.showToastSafely('验证信息已保存，请重试搜索或刷新目录');
      this.backSafely();
    } else {
      this.showToastSafely('未检测到有效登录 Cookie，请正常登录后再点完成');
    }
  }

  loadBrowserPayload(): void {
    if (this.browserPayloadLoaded || !this.browserPayloadHtml) return;
    this.browserPayloadLoaded = true;
    try {
      const baseUrl = this.browserPayloadBaseUrl && /^https?:\/\//i.test(this.browserPayloadBaseUrl) ?
        this.browserPayloadBaseUrl : undefined;
      this.controller.loadData(this.browserPayloadHtml, 'text/html', 'UTF-8', baseUrl, baseUrl);
    } catch (error) {
      console.error('加载书源网页内容失败:', error);
      this.showToastSafely('加载书源网页内容失败');
    } finally {
      AppStorage.setOrCreate('bookSourceBrowserPayloadToken', '');
      AppStorage.setOrCreate('bookSourceBrowserPayloadHtml', '');
      AppStorage.setOrCreate('bookSourceBrowserPayloadBaseUrl', '');
      AppStorage.setOrCreate('bookSourceBrowserPayloadInjectJs', '');
    }
  }

  injectBrowserPayloadScript(): void {
    if (this.browserPayloadInjected || !this.browserPayloadInjectJs) return;
    this.browserPayloadInjected = true;
    this.controller.runJavaScript(this.browserPayloadInjectJs).catch((error: Object): void => {
      console.warn('注入书源网页脚本失败:', error);
    });
  }

  openBridgeUrl(url: string, title: string): void {
    if (title) this.title = title;
    this.currentUrl = url;
    try {
      this.controller.loadUrl(url);
    } catch (error) {
      console.warn('书源网页桥接打开地址失败:', error);
      this.showToastSafely('打开网页失败');
    }
  }

  async finishBrowserAwait(): Promise<void> {
    if (!this.browserAwaitToken || this.browserAwaitCompleted) return;
    this.browserAwaitCompleted = true;
    try {
      const raw = await this.controller.runJavaScript(
        `document.documentElement ? document.documentElement.outerHTML : (document.body ? document.body.innerHTML : '')`);
      const body = this.normalizeBrowserScriptResult(raw);
      if (body.length > 2 * 1024 * 1024) {
        this.publishBrowserAwaitResult('', '网页返回内容超过2MB');
      } else {
        this.publishBrowserAwaitResult(body, '');
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.publishBrowserAwaitResult('', `读取网页结果失败：${message}`);
    }
    this.backSafely();
  }

  normalizeBrowserScriptResult(raw: string): string {
    const value = String(raw || '');
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      try {
        return String(JSON.parse(value));
      } catch (_) {}
    }
    return value;
  }

  publishBrowserAwaitResult(body: string, error: string): void {
    if (!this.browserAwaitToken) return;
    AppStorage.setOrCreate('bookSourceBrowserAwaitResultBody', body || '');
    AppStorage.setOrCreate('bookSourceBrowserAwaitResultError', error || '');
    AppStorage.setOrCreate('bookSourceBrowserAwaitResultToken', this.browserAwaitToken);
  }

  hasEffectiveBookSourceLoginCookie(): boolean {
    const sourceUrl = AppStorage.get<string>('pendingVerificationSourceUrl') || '';
    const loginUrl = AppStorage.get<string>('pendingVerificationLoginUrl') || this.url;
    const urls = [
      this.currentUrl,
      this.url,
      loginUrl,
      sourceUrl,
      this.originOf(this.currentUrl),
      this.originOf(this.url),
      this.originOf(loginUrl),
      this.originOf(sourceUrl)
    ];
    for (const url of urls) {
      if (url && VerificationSupport.hasEffectiveLoginCookie(CookieStore.getCookie(url))) {
        return true;
      }
    }
    return false;
  }

  saveCookies(url: string): void {
    if (!url) return;
    CookieStore.getCookie(url);
    CookieStore.saveSync();
  }

  async resolveBookSourceLoginUrl(url: string): Promise<void> {
    const bookSourceUrl = VerificationSupport.getBookSourceUrlFromLoginUrl(url);
    if (!bookSourceUrl) return;
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      const source = await db.getBookSource(bookSourceUrl);
      if (source && this.isShushanSource(source)) {
        await this.replaceToBookSourceEdit(bookSourceUrl);
        return;
      }
      const loginUrl = source ? VerificationSupport.resolveBookSourceLoginUrl(source) : '';
      if (source && loginUrl) {
        this.url = loginUrl;
        this.currentUrl = loginUrl;
        this.title = `${source.bookSourceName || '书源'} 登录`;
        AppStorage.setOrCreate('pendingVerificationSourceUrl', source.bookSourceUrl || '');
        AppStorage.setOrCreate('pendingVerificationLoginUrl', loginUrl);
        setTimeout(() => {
          try {
            this.controller.loadUrl(loginUrl);
          } catch (e) {
            console.warn('主动加载书源登录地址失败，将由 Web 组件状态刷新:', e);
          }
        }, 0);
        return;
      }
    } catch (e) {
      console.error('解析书源登录地址失败:', e);
    }
    await this.replaceToBookSourceEdit(bookSourceUrl);
  }

  backSafely(): void {
    try {
      router.back();
    } catch (e) {
      console.error('退出网页验证页失败:', e);
    }
  }

  showToastSafely(message: string): void {
    try {
      promptAction.showToast({ message: message });
    } catch (e) {
      console.error('显示网页验证提示失败:', e);
    }
  }

  async replaceToBookSourceEdit(bookSourceUrl: string): Promise<void> {
    try {
      await router.replaceUrl({
        url: 'pages/BookSourceEdit',
        params: {
          bookSourceUrl: bookSourceUrl
        }
      });
    } catch (e) {
      console.error('跳转书源编辑页失败:', e);
    }
  }

  isShushanSource(source: BookSource): boolean {
    const raw = `${source.bookSourceUrl || ''}\n${source.searchUrl || ''}\n${source.exploreUrl || ''}\n` +
      `${source.loginUrl || ''}\n${source.jsLib || ''}\n${source.header || ''}`;
    return raw.includes('vossc.com') || raw.includes('SHUSAN_READ_2025');
  }

  syncBookSourceLoginCookies(): void {
    const sourceUrl = AppStorage.get<string>('pendingVerificationSourceUrl') || '';
    const loginUrl = AppStorage.get<string>('pendingVerificationLoginUrl') || this.url;
    if (!sourceUrl || !loginUrl) return;
    VerificationSupport.syncLoginCookiesToSourceHosts(sourceUrl, loginUrl, this.currentUrl || this.url);
  }

  syncDocumentCookies(sourceUrl: string): void {
    this.syncDocumentCookiesAwait(sourceUrl).catch(() => {
    });
  }

  async syncDocumentCookiesAwait(sourceUrl: string): Promise<void> {
    if (!sourceUrl || !this.shouldSyncDocumentCookies(sourceUrl)) {
      return;
    }
    try {
      const value = await this.controller.runJavaScript('document.cookie || ""');
      const cookies = this.cleanJsString(value);
      if (!cookies) return;
      const pairs = cookies.split(';').map((item: string) => item.trim()).filter((item: string) => item.includes('='));
      if (pairs.length === 0) return;
      const targets = this.documentCookieTargets(sourceUrl);
      for (const target of targets) {
        for (const pair of pairs) {
          CookieStore.setCookies(target, pair);
          CookieStore.setCookies(target, `${pair}; Path=/`);
        }
      }
      CookieStore.saveSync();
    } catch (_) {
    }
  }

  shouldSyncDocumentCookies(url: string): boolean {
    const sourceUrl = AppStorage.get<string>('pendingVerificationSourceUrl') || '';
    const loginUrl = AppStorage.get<string>('pendingVerificationLoginUrl') || this.url;
    const raw = `${url || ''}\n${this.url || ''}\n${this.currentUrl || ''}\n${sourceUrl}\n${loginUrl}`.toLowerCase();
    return raw.includes('chaoxing.com') || raw.includes('fanqienovel.com') || raw.includes('snssdk.com') ||
      raw.includes('fqnovel.com');
  }

  documentCookieTargets(url: string): string[] {
    const sourceUrl = AppStorage.get<string>('pendingVerificationSourceUrl') || '';
    const loginUrl = AppStorage.get<string>('pendingVerificationLoginUrl') || this.url;
    const raw = `${url || ''}\n${this.url || ''}\n${this.currentUrl || ''}\n${sourceUrl}\n${loginUrl}`.toLowerCase();
    const targets: string[] = [
      url,
      this.currentUrl,
      this.url,
      sourceUrl,
      loginUrl,
      this.originOf(url),
      this.originOf(this.currentUrl),
      this.originOf(this.url),
      this.originOf(sourceUrl),
      this.originOf(loginUrl)
    ];
    if (raw.includes('chaoxing.com')) {
      targets.push('https://chaoxing.com');
      targets.push('https://qikan.chaoxing.com');
      targets.push('https://fxlogin.chaoxing.com');
      targets.push('https://passport2.chaoxing.com');
      targets.push('https://i.chaoxing.com');
    }
    if (raw.includes('fanqienovel.com') || raw.includes('snssdk.com') || raw.includes('fqnovel.com')) {
      targets.push('https://fanqienovel.com');
      targets.push('https://novel.snssdk.com');
      targets.push('https://api5-normal-sinfonlineb.fqnovel.com');
    }
    return targets.filter((item: string, index: number, array: string[]) => {
      return this.isHttpUrl(item) && array.indexOf(item) === index;
    });
  }

  syncGuangYuCookies(sourceUrl: string): void {
    if (!this.isGuangYuVerify(sourceUrl)) {
      return;
    }
    let fromUrl = sourceUrl || this.url;
    if (!fromUrl || !CookieStore.getCookie(fromUrl)) {
      for (const host of this.guangYuHosts) {
        const cookie = CookieStore.getCookie(host);
        if (cookie) {
          fromUrl = host;
          break;
        }
      }
    }
    if (!fromUrl || !CookieStore.getCookie(fromUrl)) {
      return;
    }
    for (const host of this.guangYuHosts) {
      CookieStore.copyCookies(fromUrl, host);
      CookieStore.copyCookies(fromUrl, `${host}/login`);
      CookieStore.copyCookies(fromUrl, `${host}/user`);
      CookieStore.copyCookies(fromUrl, `${host}/content`);
    }
    EncodedSourceUrl.syncCookiesAcrossHosts(fromUrl);
    CookieStore.saveAsync();
  }

  syncGuangYuDeviceCookie(sourceUrl: string): void {
    if (!this.isGuangYuVerify(sourceUrl)) {
      return;
    }
    this.controller.runJavaScript('localStorage.getItem("deviceId") || ""')
      .then((value: string) => {
        const deviceId = this.cleanJsString(value);
        if (!deviceId) return;
        for (const host of this.guangYuHosts) {
          CookieStore.setCookies(host, `deviceId=${deviceId}; Path=/`);
          CookieStore.setCookies(`${host}/login`, `deviceId=${deviceId}; Path=/`);
          CookieStore.setCookies(`${host}/user`, `deviceId=${deviceId}; Path=/`);
          CookieStore.setCookies(`${host}/content`, `deviceId=${deviceId}; Path=/`);
        }
        CookieStore.saveAsync();
      })
      .catch(() => {
      });
  }

  syncGuangYuDocumentCookies(sourceUrl: string): void {
    if (!this.isGuangYuVerify(sourceUrl)) {
      return;
    }
    this.controller.runJavaScript('document.cookie || ""')
      .then((value: string) => {
        const cookies = this.cleanJsString(value);
        if (!cookies) return;
        const pairs = cookies.split(';').map((item: string) => item.trim()).filter((item: string) => item.includes('='));
        for (const host of this.guangYuHosts) {
          for (const pair of pairs) {
            CookieStore.setCookies(host, pair);
            CookieStore.setCookies(`${host}/login`, pair);
            CookieStore.setCookies(`${host}/user`, pair);
            CookieStore.setCookies(`${host}/content`, pair);
          }
        }
        CookieStore.saveAsync();
      })
      .catch(() => {
      });
  }

  isGuangYuVerify(url: string): boolean {
    return (this.title || '').includes('光遇') || (url || '').includes('gyks.cf') || (this.url || '').includes('gyks.cf');
  }

  hasGuangYuToken(): boolean {
    const urls: string[] = [];
    if (this.currentUrl) urls.push(this.currentUrl);
    if (this.url) urls.push(this.url);
    for (const host of this.guangYuHosts) {
      urls.push(host);
      urls.push(`${host}/login`);
      urls.push(`${host}/user`);
      urls.push(`${host}/content`);
    }
    for (const url of urls) {
      if (this.cookieValue(CookieStore.getCookie(url), 'qttoken')) {
        return true;
      }
    }
    return false;
  }

  cookieValue(cookie: string, name: string): string {
    if (!cookie) return '';
    for (const item of cookie.split(';')) {
      const pair = item.trim();
      const eq = pair.indexOf('=');
      if (eq <= 0) continue;
      if (pair.substring(0, eq).trim() === name) return pair.substring(eq + 1).trim();
    }
    return '';
  }

  cleanJsString(value: string): string {
    let result = (value || '').trim();
    if ((result.startsWith('"') && result.endsWith('"')) || (result.startsWith("'") && result.endsWith("'"))) {
      result = result.substring(1, result.length - 1);
    }
    return result.trim();
  }

  originOf(url: string): string {
    const match = (url || '').match(/^(https?:\/\/[^/:?#]+(?::\d+)?)/i);
    return match ? match[1] : '';
  }

  isHttpUrl(url: string): boolean {
    return (url || '').startsWith('http://') || (url || '').startsWith('https://');
  }

  pageColor(): string {
    return ThemeRuntime.pageColor(this.appDarkMode);
  }

  cardColor(): string {
    return ThemeRuntime.cardColor(this.appDarkMode);
  }

  primaryTextColor(): string {
    return ThemeRuntime.primaryTextColor(this.appDarkMode);
  }

  subTextColor(): string {
    return ThemeRuntime.subTextColor(this.appDarkMode);
  }

  accentColor(): string {
    return ThemeRuntime.accentColor(this.appDarkMode);
  }

  syncBars(): void {
    syncSystemBars(getContext(this), this.appDarkMode, this.pageColor());
  }
}
