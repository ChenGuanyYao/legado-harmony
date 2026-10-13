import { router } from '@kit.ArkUI';
import { BookSource } from '../model/data/Book';
import { AppDatabase } from '../model/data/AppDatabase';
import { HttpClient } from '../core/http/HttpClient';
import { VerificationSupport } from '../core/http/VerificationSupport';
import { syncSystemBars } from '../utils/SystemBars';
import { ThemeRuntime } from '../theme/ThemeRuntime';
import { ImmersiveBackButton } from '../components/ImmersiveBackButton';
import { HdsFeedback } from '../utils/HdsFeedback';
import { ExploreResultCache } from '../utils/ExploreResultCache';
import { AppFontSize } from '../theme/AppFontSize';
import { AppSpacing } from '../theme/AppSpacing';
import { NativeSourceService, NativeVarItem } from '../core/nativesource/NativeSourceService';

interface NativeSourceSettingsParams {
  bookSourceUrl?: string;
}

/** 原生书源的设置页：书源变量与账号登录。 */
@Entry
@Component
struct NativeSourceSettingsPage {
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State sourceName: string = '';
  @State items: NativeVarItem[] = [];
  @State hasLogin: boolean = false;
  @State loggedIn: boolean = false;
  @State loginStatus: string = '';
  @State canCheckLogin: boolean = false;
  @State isChecking: boolean = false;
  @State dirty: boolean = false;
  private bookSourceUrl: string = '';
  private source: BookSource | null = null;
  private http: HttpClient = new HttpClient(10000);

  aboutToAppear(): void {
    syncSystemBars(getContext(this), this.appDarkMode, ThemeRuntime.pageColor(this.appDarkMode));
    const params = router.getParams() as NativeSourceSettingsParams;
    this.bookSourceUrl = params && params.bookSourceUrl ? params.bookSourceUrl : '';
    this.loadSource();
  }

  onPageShow(): void {
    // 从登录页返回后刷新登录状态。
    if (this.source) this.refreshLoginState();
  }

  async loadSource(): Promise<void> {
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      const source = await db.getBookSource(this.bookSourceUrl);
      if (!source || !NativeSourceService.isNative(source)) {
        HdsFeedback.showToast('未找到该原生书源');
        router.back();
        return;
      }
      this.source = source;
      this.sourceName = source.bookSourceName;
      this.items = NativeSourceService.varItems(source);
      const login = NativeSourceService.loginSpec(source);
      this.hasLogin = !!login;
      this.canCheckLogin = !!login && !!login.check;
      this.refreshLoginState();
    } catch (e) {
      console.error('加载书源设置失败:', e);
      HdsFeedback.showToast('加载书源失败');
    }
  }

  refreshLoginState(): void {
    if (!this.source || !this.hasLogin) return;
    this.loggedIn = NativeSourceService.hasLoginCookies(this.source);
    this.loginStatus = this.loggedIn ? '已登录' : '未登录';
  }

  setValue(index: number, value: string): void {
    const next = this.items.slice();
    const item = next[index];
    next[index] = { key: item.key, label: item.label, options: item.options, value: value };
    this.items = next;
    this.dirty = true;
  }

  async save(): Promise<void> {
    if (!this.source) return;
    try {
      const variable = NativeSourceService.variableWithValues(this.source, this.items);
      const db = AppDatabase.getInstance();
      await db.updateBookSourceVariable(this.source.bookSourceUrl, variable);
      this.source.variable = variable;
      await ExploreResultCache.invalidateSources(getContext(this), [this.source.bookSourceUrl]);
      this.dirty = false;
      HdsFeedback.showToast('已保存');
    } catch (e) {
      console.error('保存书源设置失败:', e);
      HdsFeedback.showToast('保存失败');
    }
  }

  openLogin(): void {
    if (!this.source) return;
    const login = NativeSourceService.loginSpec(this.source);
    if (!login) return;
    const title = `${this.sourceName || '书源'} 登录`;
    VerificationSupport.requestVerification(login.url, title, this.source);
    router.pushUrl({
      url: 'pages/VerifyWeb',
      params: {
        url: login.url,
        title: title,
        requireLoginCookie: 'true',
        bookSourceBrowserAwaitToken: '',
        bookSourceBrowserPayloadToken: '',
        bookSourceVariable: this.source.variable || ''
      }
    });
  }

  async checkLogin(): Promise<void> {
    if (!this.source || this.isChecking) return;
    this.isChecking = true;
    this.loginStatus = '正在检查…';
    try {
      const state = await NativeSourceService.checkLogin(this.source, this.http);
      this.loggedIn = state.ok;
      this.loginStatus = state.ok ? (state.name ? `已登录：${state.name}` : '已登录') : (state.message || '未登录');
    } catch (e) {
      this.loginStatus = `检查失败：${(e as Error).message || '未知错误'}`;
    } finally {
      this.isChecking = false;
    }
  }

  logout(): void {
    if (!this.source) return;
    NativeSourceService.logout(this.source);
    this.refreshLoginState();
    HdsFeedback.showToast('已退出登录');
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(AppFontSize.BODY)
      .fontColor(ThemeRuntime.subTextColor(this.appDarkMode))
      .width('100%')
      .padding({ left: AppSpacing.XL, right: AppSpacing.XL, top: AppSpacing.XL, bottom: AppSpacing.MD })
  }

  @Builder
  actionButton(label: string, color: string, action: () => void) {
    Text(label)
      .fontSize(AppFontSize.BODY)
      .fontColor(color)
      .padding({ left: AppSpacing.XL, right: AppSpacing.XL, top: AppSpacing.MD, bottom: AppSpacing.MD })
      .borderRadius(ThemeRuntime.smallRadius())
      .backgroundColor(ThemeRuntime.inputColor(this.appDarkMode))
      .onClick(() => action())
  }

  build() {
    Column() {
      Row() {
        ImmersiveBackButton({ iconColor: ThemeRuntime.primaryTextColor(this.appDarkMode), darkMode: this.appDarkMode,
          buttonSize: 40, containerWidth: 56, materialScale: 0.83, compactLayout: true,
          onBack: () => router.back() })

        Text('书源设置')
          .fontSize(AppFontSize.TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemeRuntime.primaryTextColor(this.appDarkMode))
          .layoutWeight(1)

        if (this.items.length > 0) {
          Text('保存')
            .fontSize(AppFontSize.BODY_LARGE)
            .fontColor(this.dirty ? ThemeRuntime.accentColor(this.appDarkMode) :
              ThemeRuntime.subTextColor(this.appDarkMode))
            .width(60)
            .height(56)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.save();
            })
        }
      }
      .width('100%')
      .height(56 + this.statusBarHeight)
      .padding({ top: this.statusBarHeight })
      .backgroundColor(ThemeRuntime.topBarColor(this.appDarkMode))
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          Text(this.sourceName)
            .fontSize(AppFontSize.BODY_LARGE)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeRuntime.primaryTextColor(this.appDarkMode))
            .width('100%')
            .padding({ left: AppSpacing.XL, right: AppSpacing.XL, top: AppSpacing.XL })

          if (this.items.length > 0) {
            this.sectionTitle('变量')
            ForEach(this.items, (item: NativeVarItem, index: number) => {
              Row() {
                Text(item.label)
                  .fontSize(AppFontSize.BODY)
                  .fontColor(ThemeRuntime.primaryTextColor(this.appDarkMode))
                  .width(96)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })

                if (item.options.length > 0) {
                  Select(item.options.map((option: string): SelectOption => ({ value: option })))
                    .selected(Math.max(0, item.options.indexOf(item.value)))
                    .value(item.value)
                    .font({ size: AppFontSize.BODY })
                    .fontColor(ThemeRuntime.primaryTextColor(this.appDarkMode))
                    .layoutWeight(1)
                    .onSelect((_selected: number, text: string) => {
                      this.setValue(index, text);
                    })
                } else {
                  TextInput({ text: item.value, placeholder: '未填写' })
                    .fontSize(AppFontSize.BODY)
                    .fontColor(ThemeRuntime.primaryTextColor(this.appDarkMode))
                    .backgroundColor(ThemeRuntime.inputColor(this.appDarkMode))
                    .borderRadius(ThemeRuntime.smallRadius())
                    .layoutWeight(1)
                    .onChange((value: string) => {
                      if (value !== this.items[index].value) this.setValue(index, value);
                    })
                }
              }
              .width('100%')
              .padding({ left: AppSpacing.XL, right: AppSpacing.XL, top: AppSpacing.SM, bottom: AppSpacing.SM })
              .alignItems(VerticalAlign.Center)
            }, (item: NativeVarItem) => `${item.key}_${item.options.length > 0 ? item.value : ''}`)
          }

          if (this.hasLogin) {
            this.sectionTitle('账号')
            Text(this.loginStatus)
              .fontSize(AppFontSize.BODY)
              .fontColor(this.loggedIn ? ThemeRuntime.successColor(this.appDarkMode) :
                ThemeRuntime.subTextColor(this.appDarkMode))
              .width('100%')
              .padding({ left: AppSpacing.XL, right: AppSpacing.XL, bottom: AppSpacing.MD })
            Row({ space: AppSpacing.MD }) {
              this.actionButton(this.loggedIn ? '重新登录' : '登录', ThemeRuntime.accentColor(this.appDarkMode),
                () => this.openLogin())
              if (this.canCheckLogin) {
                this.actionButton('检查登录', ThemeRuntime.primaryTextColor(this.appDarkMode), () => {
                  this.checkLogin();
                })
              }
              if (this.loggedIn) {
                this.actionButton('退出登录', ThemeRuntime.dangerColor(this.appDarkMode), () => this.logout())
              }
            }
            .width('100%')
            .padding({ left: AppSpacing.XL, right: AppSpacing.XL })
          }

          if (this.items.length === 0 && !this.hasLogin) {
            Text('该书源没有可设置的项目')
              .fontSize(AppFontSize.BODY)
              .fontColor(ThemeRuntime.subTextColor(this.appDarkMode))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 80 })
          }
        }
        .width('100%')
        .padding({ bottom: this.navBarHeight + AppSpacing.XL })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeRuntime.pageColor(this.appDarkMode))
  }
}
