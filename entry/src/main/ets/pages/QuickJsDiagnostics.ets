import { router } from '@kit.ArkUI';
import { Context } from '@kit.AbilityKit';
import { QuickJsFingerprintStats, QuickJsMigrationSnapshot, QuickJsMigrationStore, QuickJsRuntimeMode, QuickJsValidationStore } from '@legado/sourceengine';
import { ThemeRuntime } from '../theme/ThemeRuntime';
import { syncSystemBars } from '../utils/SystemBars';
import { AppFontSize } from '../theme/AppFontSize';
import { AppSpacing } from '../theme/AppSpacing';
import { PageScaffold } from '../components/common/PageScaffold';

@Entry
@Component
struct QuickJsDiagnosticsPage {
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;
  @StorageLink('quickJsMigrationRevision') quickJsMigrationRevision: number = 0;
  @State snapshot: QuickJsMigrationSnapshot = new QuickJsMigrationSnapshot();

  aboutToAppear(): void {
    this.syncBars();
    QuickJsMigrationStore.initialize(getContext(this) as Context)
      .then((): void => this.refresh())
      .catch((): void => this.refresh());
  }

  onPageShow(): void {
    this.syncBars();
    this.refresh();
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      PageScaffold({ title: '脚本引擎迁移', content: () => {
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
    Column({ space: AppSpacing.LG }) {
      this.infoCard()
      this.modeCard()
      this.statsCard()
      this.privacyCard()
      Button('书源脚本回归测试')
        .type(ButtonType.Capsule)
        .fontSize(AppFontSize.BODY_LARGE)
        .fontColor(ThemeRuntime.onAccentColor())
        .backgroundColor(ThemeRuntime.accentColor(this.appDarkMode))
        .width('calc(100% - 24vp)')
        .height(46)
        .onClick((): void => {
          router.pushUrl({ url: 'pages/QuickJsRegression' });
        })
      Button('清除迁移统计')
        .type(ButtonType.Capsule)
        .fontSize(AppFontSize.BODY)
        .fontColor(ThemeRuntime.dangerColor(this.appDarkMode))
        .backgroundColor(this.cardColor())
        .width('calc(100% - 24vp)')
        .height(46)
        .onClick((): void => {
          const context = getContext(this) as Context;
          Promise.all([QuickJsMigrationStore.clearDiagnostics(context),
            QuickJsValidationStore.clearRealProgress(context)])
            .then((): void => this.refresh())
            .catch((): void => {});
        })
    }
    .width('100%')
    .padding({ top: AppSpacing.LG })
  }

  @Builder
  infoCard() {
    Column({ space: AppSpacing.MD }) {
      Row() {
        Text('运行状态').fontSize(AppFontSize.BODY_LARGE).fontWeight(FontWeight.Medium).fontColor(this.primaryTextColor())
        Blank()
        Text(this.snapshot.selfTestPassed ? '自检通过' : '自检未通过')
          .fontSize(AppFontSize.BODY)
          .fontColor(this.snapshot.selfTestPassed ? ThemeRuntime.successColor(this.appDarkMode) : ThemeRuntime.dangerColor(this.appDarkMode))
      }.width('100%')
      Text(this.circuitText())
        .fontSize(AppFontSize.BODY)
        .fontColor(this.subTextColor())
        .width('100%')
    }
    .width('calc(100% - 24vp)')
    .padding(AppSpacing.XL)
    .borderRadius(ThemeRuntime.cardRadius())
    .backgroundColor(this.cardColor())
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  modeCard() {
    Column() {
      Text('执行模式')
        .fontSize(AppFontSize.BODY)
        .fontColor(this.subTextColor())
        .width('100%')
        .padding({ left: AppSpacing.XL, top: AppSpacing.LG, bottom: AppSpacing.MD })
      this.modeItem(QuickJsRuntimeMode.OFF, '关闭', '全部使用原有引擎')
      this.modeItem(QuickJsRuntimeMode.SHADOW, '影子校验（推荐）', '原有结果生效，后台对比 QuickJS')
      this.modeItem(QuickJsRuntimeMode.CANARY, '灰度接管', '仅接管已连续验证合格的纯表达式')
      this.modeItem(QuickJsRuntimeMode.PREFER_QUICKJS, '优先 QuickJS', '纯表达式优先新引擎，失败自动回退')
    }
    .width('calc(100% - 24vp)')
    .borderRadius(ThemeRuntime.cardRadius())
    .clip(true)
    .backgroundColor(this.cardColor())
  }

  @Builder
  modeItem(mode: QuickJsRuntimeMode, title: string, desc: string) {
    Row({ space: AppSpacing.LG }) {
      Column({ space: AppSpacing.XXS }) {
        Text(title).fontSize(AppFontSize.BODY_LARGE).fontColor(this.primaryTextColor())
        Text(desc).fontSize(AppFontSize.CAPTION).fontColor(this.subTextColor())
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.snapshot.mode === mode) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize(22)
          .fontColor([ThemeRuntime.accentColor(this.appDarkMode)])
      } else {
        SymbolGlyph($r('sys.symbol.circle'))
          .fontSize(22)
          .fontColor([this.subTextColor()])
      }
    }
    .width('100%')
    .height(64)
    .padding({ left: AppSpacing.XL, right: AppSpacing.XL })
    .onClick((): void => this.setMode(mode))
  }

  @Builder
  statsCard() {
    Column({ space: AppSpacing.LG }) {
      Text('累计统计').fontSize(AppFontSize.BODY_LARGE).fontWeight(FontWeight.Medium).fontColor(this.primaryTextColor())
        .width('100%')
      Row() {
        this.statItem('一致', this.snapshot.shadowMatches, ThemeRuntime.successColor(this.appDarkMode))
        this.statItem('差异', this.snapshot.shadowMismatches, ThemeRuntime.warningColor(this.appDarkMode))
        this.statItem('校验失败', this.snapshot.shadowFailures, ThemeRuntime.dangerColor(this.appDarkMode))
      }.width('100%')
      Row() {
        this.statItem('接管成功', this.snapshot.routedSuccesses, ThemeRuntime.successColor(this.appDarkMode))
        this.statItem('自动回退', this.snapshot.routedFallbacks, ThemeRuntime.warningColor(this.appDarkMode))
        this.statItem('灰度合格', this.eligibleCount(), ThemeRuntime.accentColor(this.appDarkMode))
      }.width('100%')
    }
    .width('calc(100% - 24vp)')
    .padding(AppSpacing.XL)
    .borderRadius(ThemeRuntime.cardRadius())
    .backgroundColor(this.cardColor())
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  statItem(label: string, value: number, color: string) {
    Column({ space: AppSpacing.XS }) {
      Text(`${value}`).fontSize(AppFontSize.TITLE).fontWeight(FontWeight.Bold).fontColor(color)
      Text(label).fontSize(AppFontSize.CAPTION).fontColor(this.subTextColor())
    }.layoutWeight(1)
  }

  @Builder
  privacyCard() {
    Column({ space: AppSpacing.SM }) {
      Text('边界说明').fontSize(AppFontSize.BODY_LARGE).fontWeight(FontWeight.Medium).fontColor(this.primaryTextColor())
      Text('QuickJS 当前只执行无网络、Cookie、文件或平台桥接的纯表达式。复杂脚本继续使用现有受控运行环境；统计只保存表达式指纹和计数。')
        .fontSize(AppFontSize.CAPTION)
        .fontColor(this.subTextColor())
        .lineHeight(19)
    }
    .width('calc(100% - 24vp)')
    .padding(AppSpacing.XL)
    .borderRadius(ThemeRuntime.cardRadius())
    .backgroundColor(this.cardColor())
    .alignItems(HorizontalAlign.Start)
  }

  private setMode(mode: QuickJsRuntimeMode): void {
    QuickJsMigrationStore.setMode(getContext(this) as Context, mode)
      .then((): void => this.refresh())
      .catch((): void => {});
  }

  private refresh(): void {
    this.snapshot = QuickJsMigrationStore.snapshot();
  }

  private eligibleCount(): number {
    return this.snapshot.fingerprints.filter((item: QuickJsFingerprintStats): boolean =>
      item.shadowMatches >= 4 && item.shadowMismatches === 0 && item.shadowFailures === 0).length;
  }

  private circuitText(): string {
    if (this.snapshot.circuitOpenUntil > Date.now()) {
      return `自动回退熔断中，${new Date(this.snapshot.circuitOpenUntil).toLocaleTimeString()} 后重试`;
    }
    return '自动回退与熔断正常';
  }

  private syncBars(): void { syncSystemBars(getContext(this), this.appDarkMode, this.pageColor()); }
  private pageColor(): string { return ThemeRuntime.pageColor(this.appDarkMode); }
  private cardColor(): string { return ThemeRuntime.cardColor(this.appDarkMode); }
  private primaryTextColor(): string { return ThemeRuntime.primaryTextColor(this.appDarkMode); }
  private subTextColor(): string { return ThemeRuntime.subTextColor(this.appDarkMode); }
}
