import { router } from '@kit.ArkUI';
import { BookSource } from '../../model/data/Book';
import { SearchExploreSettings } from '../../utils/SearchExploreSettingsStore';
import { ThemeRuntime } from '../../theme/ThemeRuntime';
import { CloudSyncSettingsStore } from '../../account/CloudSyncSettingsStore';

/** 首页"我的"页签：设置入口列表。 */
@Component
export struct SettingsPage {
  @Prop statusBarHeight: number = 0;
  @Prop navBarHeight: number = 0;
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;
  @StorageLink('accountLoggedIn') accountLoggedIn: boolean = false;
  @StorageLink('accountDisplayName') accountDisplayName: string = '';
  @StorageLink('accountAvatarUrl') accountAvatarUrl: string = '';
  @StorageLink('accountPoints') accountPoints: number = 0;
  @StorageLink('cloudSyncEnabled') cloudSyncEnabled: boolean = false;
  @StorageLink('cloudSyncLastSuccessAt') cloudSyncLastSuccessAt: number = 0;
  @StorageLink('cloudSyncPendingCount') cloudSyncPendingCount: number = 0;
  @StorageLink('cloudSyncStatus') cloudSyncStatus: string = CloudSyncSettingsStore.STATUS_DISABLED;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Scroll() {
        Column({ space: 12 }) {
          Row()
            .width('100%')
            .height(56 + this.statusBarHeight)

          this.accountSummaryCard()
          Column() {
            this.syncMenuItem()
            this.menuItem($r('sys.symbol.timer'), '阅读统计', true, () => {
              router.pushUrl({ url: 'pages/ReadingStats' });
            })
            this.menuItem($r('sys.symbol.externaldrive'), '书源管理', true, () => {
              router.pushUrl({ url: 'pages/BookSource' });
            })
            this.menuItem($r('sys.symbol.download'), '书籍导入', true, () => {
              router.pushUrl({ url: 'pages/BookImport' });
            })
            this.menuItem($r('sys.symbol.book'), '阅读设置', true, () => {
              router.pushUrl({ url: 'pages/Settings' });
            })
            this.menuItem($r('sys.symbol.speaker_wave_3'), '朗读设置', true, () => {
              router.pushUrl({ url: 'pages/TtsSettings' });
            })
            this.menuItem($r('sys.symbol.bookshelf'), '书架设置', true, () => {
              router.pushUrl({ url: 'pages/BookshelfSettings' });
            })
            this.menuItem($r('sys.symbol.magnifyingglass'), '搜索/发现配置', true, () => {
              router.pushUrl({ url: 'pages/SearchExploreSettings' });
            })
            this.menuItem($r('sys.symbol.circle_lefthalf_inset_filled'), '主题', true, () => {
              router.pushUrl({ url: 'pages/ThemeSettings' });
            })
            this.menuItem($r('sys.symbol.gearshape'), '其他设置', true, () => {
              router.pushUrl({ url: 'pages/OtherSettings' });
            })
            this.menuItem($r('sys.symbol.questionmark_circle'), '帮助', true, () => {
              router.pushUrl({ url: 'pages/Help' });
            })
            this.menuItem($r('sys.symbol.info_circle'), '关于', false, () => {
              router.pushUrl({ url: 'pages/About' });
            })
          }
          .width('100%')
          .borderRadius(ThemeRuntime.largeRadius())
          .clip(true)
          .backgroundColor(this.glassCardColor())

          Row()
            .width('100%')
            .height(56 + Math.max(this.navBarHeight, 8) + 20)
        }
        .width('calc(100% - 24vp)')
        .margin({ left: 12, right: 12, top: 12 })
        .justifyContent(FlexAlign.Start)
      }
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .width('100%')
      .height('100%')
      .align(Alignment.TopStart)
      .backgroundColor(this.pageColor())
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])

      Row() {
        Text('我的')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
          .layoutWeight(1)
      }
      .width('100%')
      .height(56 + this.statusBarHeight)
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, top: this.statusBarHeight })
      .backgroundColor(ThemeRuntime.topBarColor(this.appDarkMode))
      .backdropBlur(ThemeRuntime.topBarBlur())
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  accountSummaryCard() {
    Row({ space: 12 }) {
      if (this.accountLoggedIn && this.accountAvatarUrl) {
        Image(this.accountAvatarUrl)
          .width(48)
          .height(48)
          .borderRadius(24)
          .objectFit(ImageFit.Cover)
      } else {
        Image($r('app.media.ic_default_reader_avatar'))
          .width(48)
          .height(48)
          .borderRadius(24)
          .objectFit(ImageFit.Cover)
      }

      Column({ space: 4 }) {
        Text(this.accountLoggedIn ? this.accountDisplayName : '登录华为账号')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
        Text(this.accountLoggedIn ? `${this.accountPoints} 点` : '首次登录免费送 300 点')
          .fontSize(12)
          .fontColor(this.subTextColor())
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([this.subTextColor()])
    }
    .width('100%')
    .padding(16)
    .borderRadius(ThemeRuntime.largeRadius())
    .backgroundColor(this.glassCardColor())
    .onClick(() => {
      router.pushUrl({ url: 'pages/AccountCenter' });
    })
  }

  @Builder
  syncMenuItem() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(22)
          .fontColor([this.subTextColor()])
          .width(32)

        Column({ space: 3 }) {
          Text('数据同步')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
          Text(CloudSyncSettingsStore.statusSummary(this.accountLoggedIn, this.cloudSyncEnabled,
            this.cloudSyncStatus, this.cloudSyncPendingCount, this.cloudSyncLastSuccessAt))
            .fontSize(12)
            .fontColor(this.cloudSyncEnabled && this.accountLoggedIn ? this.accentColor() : this.subTextColor())
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(18)
          .fontColor([this.subTextColor()])
      }
      .width('100%')
      .height(64)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      Divider()
        .strokeWidth(0.5)
        .color(this.dividerColor())
        .width('calc(100% - 60vp)')
        .margin({ left: 60 })
    }
    .width('100%')
    .onClick(() => {
      router.pushUrl({ url: 'pages/DataSync' });
    })
  }

  @Builder
  menuItem(icon: Resource, title: string, showDivider: boolean, onClick: () => void) {
    Column() {
      Row() {
        SymbolGlyph(icon)
          .fontSize(22)
          .fontColor([this.subTextColor()])
          .width(32)

        Text(title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
          .layoutWeight(1)
          .margin({ left: 12 })

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(18)
          .fontColor([this.subTextColor()])
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      if (showDivider) {
        Divider()
          .strokeWidth(0.5)
          .color(this.dividerColor())
          .margin({ left: 60, right: 16 })
      }
    }
    .width('100%')
    .onClick(onClick)
  }

  pageColor(): string {
    return ThemeRuntime.pageColor(this.appDarkMode);
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

  glassCardColor(): string {
    return ThemeRuntime.cardColor(this.appDarkMode);
  }

  dividerColor(): string {
    return this.appDarkMode ? '#24FFFFFF' : '#14000000';
  }

}
