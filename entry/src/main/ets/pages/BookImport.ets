import { router } from '@kit.ArkUI';
import { syncSystemBars } from '../utils/SystemBars';
import { ThemeRuntime } from '../theme/ThemeRuntime';
import { LocalBookScanResult, LocalBookService } from '../core/book/LocalBookService';
import { ImmersiveBackButton } from '../components/ImmersiveBackButton';
import { HdsFeedback } from '../utils/HdsFeedback';
import { AppFontSize } from '../theme/AppFontSize';

@Entry
@Component
struct BookImportPage {
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;
  @StorageLink('appLightAccentColor') appLightAccentColor: string = '#007DFF';
  @StorageLink('appDarkAccentColor') appDarkAccentColor: string = '#4E9BFF';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State isScanning: boolean = false;
  @State statusText: string = '';

  aboutToAppear(): void {
    this.syncBars();
  }

  onPageShow(): void {
    this.syncBars();
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Scroll() {
        Column() {
          this.sectionTitle('导入方式')
          Column() {
            this.menuRow($r('sys.symbol.bookshelf'), 'OPDS 书库',
              '连接 Calibre / Komga / Kavita 等书库，浏览并下载图书', true, () => {
                router.pushUrl({ url: 'pages/OpdsServers' });
              })
            this.menuRow($r('sys.symbol.externaldrive'), 'WebDAV 服务',
              '浏览远程 TXT / EPUB 书库', true, () => {
                router.pushUrl({ url: 'pages/WebDav' });
              })
            this.menuRow($r('sys.symbol.book'), '本地导入',
              '选择并导入 TXT / EPUB 文件', false, () => {
                this.addBooks();
              })
            Text('仅支持 TXT / EPUB 格式')
              .fontSize(AppFontSize.CAPTION)
              .fontColor(this.subTextColor())
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 12 })
          }
          .width('calc(100% - 24vp)')
          .margin({ left: 12, right: 12 })
          .borderRadius(ThemeRuntime.cardRadius())
          .clip(true)
          .backgroundColor(this.cardColor())
        }
        .width('100%')
        .padding({ top: 56 + this.statusBarHeight, bottom: 32 + this.navBarHeight })
      }
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .width('100%')
      .height('100%')
      .align(Alignment.TopStart)

      this.titleBar()

      if (this.isScanning) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(36)
            .height(36)
            .color(this.accentColor())
          Text(this.statusText || '处理中...')
            .fontSize(AppFontSize.BODY)
            .fontColor(this.primaryTextColor())
        }
        .width('78%')
        .padding(20)
        .borderRadius(ThemeRuntime.cardRadius())
        .backgroundColor(this.cardColor())
        .shadow({ radius: 18, color: this.appDarkMode ? '#66000000' : '#28000000' })
        .position({ x: '11%', y: '42%' })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  async addBooks(): Promise<void> {
    if (this.isScanning) return;
    try {
      const selected = await LocalBookService.chooseBookFiles(getContext(this));
      if (selected.length === 0) return;
      this.isScanning = true;
      this.statusText = `正在导入${selected.length}本书...`;
      const result = await LocalBookService.importSelectedFiles(getContext(this), selected);
      this.finishImport(result);
    } catch (e) {
      console.error('添加本地书籍失败:', e);
      this.statusText = '导入失败，请重新选择文件';
      HdsFeedback.showToast('导入失败');
    } finally {
      this.isScanning = false;
    }
  }

  finishImport(result: LocalBookScanResult): void {
    const failed = result.failed > 0 ? `，${result.failed}本失败` : '';
    this.statusText = `导入完成：成功${result.imported}本${failed}`;
    AppStorage.setOrCreate('shelfUpdateTime', Date.now());
    HdsFeedback.showToast(this.statusText);
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

  @Builder
  titleBar() {
    Row() {
      ImmersiveBackButton({ iconColor: this.primaryTextColor(), darkMode: this.appDarkMode,
        buttonSize: 40, containerWidth: 56, materialScale: 0.83, compactLayout: true,
        onBack: () => router.back() })
      Text('书籍导入')
        .fontSize(AppFontSize.TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryTextColor())
        .layoutWeight(1)
    }
    .width('100%')
    .height(56 + this.statusBarHeight)
    .padding({ top: this.statusBarHeight })
    .backgroundColor(ThemeRuntime.topBarColor(this.appDarkMode))
    .backdropBlur(ThemeRuntime.topBarBlur())
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(AppFontSize.BODY)
      .fontColor(this.subTextColor())
      .width('100%')
      .padding({ left: 16, right: 16, top: 20, bottom: 8 })
  }

  @Builder
  menuRow(icon: Resource, title: string, desc: string, showDivider: boolean, onClick: () => void) {
    Row() {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([this.subTextColor()])
        .width(32)

      Column() {
        Text(title)
          .fontSize(AppFontSize.BODY_LARGE)
          .fontColor(this.primaryTextColor())
        Text(desc)
          .fontSize(AppFontSize.CAPTION)
          .fontColor(this.subTextColor())
          .margin({ top: 4 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([this.subTextColor()])
    }
    .width('calc(100% - 32vp)')
    .constraintSize({ minHeight: 64 })
    .padding({ left: 0, right: 0, top: 10, bottom: 10 })
    .margin({ left: 16, right: 16 })
    .backgroundColor(Color.Transparent)
    .border({ width: { bottom: showDivider ? 0.5 : 0 },
      color: this.appDarkMode ? '#24FFFFFF' : '#14000000' })
    .alignItems(VerticalAlign.Center)
    .onClick(onClick)
  }
}
