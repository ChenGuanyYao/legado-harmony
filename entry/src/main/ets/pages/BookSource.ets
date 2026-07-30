import { router, promptAction } from '@kit.ArkUI';
import { BookSource, SearchBook, BookListRule, SearchRule, ExploreRule, BookInfoRule, TocRule, ContentRule } from '../model/data/Book';
import { AppDatabase } from '../model/data/AppDatabase';
import { HttpClient, HttpResponse } from '../core/http/HttpClient';
import { RawHttpTextClient } from '../core/http/RawHttpTextClient';
import { SearchCoordinator, SearchProgress, SearchSourceResult } from '../core/book/SearchCoordinator';
import { syncSystemBars } from '../utils/SystemBars';
import { SearchExploreSettingsStore } from '../utils/SearchExploreSettingsStore';
import { ImmersiveBackButton } from '../components/ImmersiveBackButton';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import { util } from '@kit.ArkTS';
import { ThemeRuntime } from '../theme/ThemeRuntime';
import { VerificationSupport } from '../core/http/VerificationSupport';
import { CookieStore } from '../core/http/CookieStore';
import { BookSourceGroupStore } from '../utils/BookSourceGroupStore';
import { ResponsiveManagerListLayout } from '../utils/ResponsiveManagerListLayout';
import { VirtualListScrollbar } from '../utils/VirtualListScrollbar';
import { common, WantAgent, wantAgent } from '@kit.AbilityKit';
import { request } from '@kit.BasicServicesKit';
import { webview } from '@kit.ArkWeb';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import commonEventManager from '@ohos.commonEventManager';
import { BookSourceLoginItem, BookSourceScriptRunner } from '../core/book/BookSourceScriptRunner';
import { BookSourceLoginWebRuntime, LoginCookieOperation, LoginRuntimeStep } from '../core/book/BookSourceLoginWebRuntime';
import { AnalyzeUrl } from '../core/rule/AnalyzeUrl';

const BOOK_SOURCE_IMPORT_FILE_LIMIT_BYTES = 25 * 1024 * 1024;
const BOOK_SOURCE_IMPORT_TIMEOUT_MS = 20000;
const BOOK_SOURCE_IMPORT_URL_RETRY_COUNT = 3;
const BOOK_SOURCE_WEB_IMPORT_RETRY_COUNT = 3;
const BOOK_SOURCE_CHECK_KEYWORD = '斗破苍穹';
const BOOK_SOURCE_LIST_BATCH_SIZE = 60;
const BOOK_SOURCE_CHECK_CANCEL_EVENT: string = 'com.legado.harmony.action.BOOK_SOURCE_CHECK_CANCEL';
const BOOK_SOURCE_CHECK_NOTIFICATION_INTERVAL_MS: number = 1000;
const BOOK_SOURCE_CHECK_NOTIFICATION_ID: number = 2701;

@Entry
@Component
struct BookSourcePage {
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;
  @StorageLink('appLightAccentColor') appLightAccentColor: string = '#007DFF';
  @StorageLink('appDarkAccentColor') appDarkAccentColor: string = '#4E9BFF';
  @StorageLink('appLightButtonColor') appLightButtonColor: string = '#007DFF';
  @StorageLink('appDarkButtonColor') appDarkButtonColor: string = '#3F8CFF';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @StorageLink('pendingBookSourceImportNonce') @Watch('onPendingBookSourceImportChanged')
  pendingBookSourceImportNonce: number = 0;
  @StorageLink('bookSourceCheckOpenNonce') @Watch('onBookSourceCheckOpenRequested')
  bookSourceCheckOpenNonce: number = 0;
  @State allSources: BookSource[] = [];
  @State sources: BookSource[] = [];
  @State visibleSources: BookSource[] = [];
  @State sourceListViewportHeight: number = 0;
  @State sourceFirstVisibleIndex: number = 0;
  @State sourceVisibleItemCount: number = 1;
  @State sourceGroups: string[] = [];
  @State isLoading: boolean = false;
  @State searchText: string = '';
  @State activeSourceGroup: string = '__all__';
  @State showSourceFilterDialog: boolean = false;
  @State sourceEnabledFilter: string = 'all';
  @State sourceExplorePageFilter: string = 'all';
  @State sourceExploreEnabledFilter: string = 'all';
  @State sourceLoginFilter: string = 'all';
  @State sourceValidationFilter: string = 'all';
  @State sourceSortMode: string = 'custom';
  @State showAddDialog: boolean = false;
  @State showImportUrlDialog: boolean = false;
  @State selectionMode: boolean = false;
  @State selectedSourceUrls: string[] = [];
  @State showBatchDeleteDialog: boolean = false;
  @State showGroupDialog: boolean = false;
  @State showMoreActionDialog: boolean = false;
  @State showSourceActionDialog: boolean = false;
  @State showSourceLoginUiDialog: boolean = false;
  @State sourceLoginItems: BookSourceLoginItem[] = [];
  @State isExecutingLoginAction: boolean = false;
  @State loginRuntimeActive: boolean = false;
  @State showSourceDeleteDialog: boolean = false;
  @State showSourceGroupToolsMenu: boolean = false;
  @State showSourceGroupActionMenu: boolean = false;
  @State showRenameSourceGroupDialog: boolean = false;
  @State showDeleteSourceGroupDialog: boolean = false;
  @State showAddSourceGroupDialog: boolean = false;
  @State showSourceGroupManagerDialog: boolean = false;
  @State showDeleteSelectedSourceGroupsDialog: boolean = false;
  @State selectedManagedSourceGroups: string[] = [];
  @State pendingSourceGroup: string = '';
  @State renameSourceGroupInput: string = '';
  @State newSourceGroupInput: string = '';
  @State actionSourceUrl: string = '';
  @State actionSourceDetail: BookSource | null = null;
  @State contextMenuX: number = 16;
  @State contextMenuY: number = 96;
  @State contextViewportWidth: number = 360;
  @State contextViewportHeight: number = 720;
  @State groupNameInput: string = '';
  @State groupActionSourceUrl: string = '';
  @State draggingSourceUrl: string = '';
  @State importUrl: string = '';
  @State isImporting: boolean = false;
  @State isBatchOperating: boolean = false;
  @State batchOperationText: string = '正在操作书源...';
  @State showCheckDialog: boolean = false;
  @State showCheckOptionsDialog: boolean = false;
  @State isCheckingSources: boolean = false;
  @State checkDone: number = 0;
  @State checkTotal: number = 0;
  @State checkOkCount: number = 0;
  @State checkFailedCount: number = 0;
  @State checkNoResultCount: number = 0;
  @State checkNeedVerificationCount: number = 0;
  @State checkTemporaryErrorCount: number = 0;
  @State checkBadUrls: string[] = [];
  @State checkResultDetails: string[] = [];
  @State checkStatus: string = '';
  @State checkInvalidAction: string = 'none';
  @State checkAutoHandledCount: number = 0;
  @State checkBackgroundMode: boolean = false;
  @State webImportActive: boolean = false;
  private sourceListScroller: Scroller = new Scroller();
  private hasShownOnce: boolean = false;
  private checkCoordinator: SearchCoordinator | null = null;
  private checkTaskSerial: number = 0;
  private checkNotificationLastAt: number = 0;
  private checkBackgroundRunning: boolean = false;
  private checkCancelAgent: WantAgent | null = null;
  private checkCancelSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private pageVisible: boolean = true;
  private webImportController: webview.WebviewController = new webview.WebviewController();
  private webImportTargetUrl: string = '';
  private webImportStarted: boolean = false;
  private webImportResolve: ((value: string) => void) | null = null;
  private webImportReject: ((reason: Error) => void) | null = null;
  private webImportTimeoutId: number = -1;
  private webImportDownloadDelegate: webview.WebDownloadDelegate | null = null;
  private webImportDownloadItem: webview.WebDownloadItem | null = null;
  private webImportDownloadPath: string = '';
  private loginRuntimeController: webview.WebviewController = new webview.WebviewController();
  private loginRuntimeSource: BookSource | null = null;
  private loginRuntimeAction: string = '';
  private loginRuntimeResponses: Record<string, string> = {};
  private loginRuntimeCookies: Record<string, string> = {};
  private loginRuntimeCookieUrls: string[] = [];
  private loginRuntimeRequestCount: number = 0;
  private loginRuntimeStepRunning: boolean = false;
  private loginRuntimeReady: boolean = false;
  private loginRuntimeResolve: ((value: LoginRuntimeStep) => void) | null = null;
  private loginRuntimeReject: ((reason: Error) => void) | null = null;
  private loginRuntimeTimeoutId: number = -1;

  aboutToAppear() {
    this.syncBars();
    this.loadSources();
    this.handlePendingBookSourceImport();
    this.ensureBookSourceCheckCancelSubscriber();
  }

  aboutToDisappear(): void {
    this.finishWebImport('', '网页取数已取消');
    this.finishLoginRuntime(null, '登录动作已取消');
    if (!this.isCheckingSources) {
      this.releaseBookSourceCheckCancelSubscriber();
    }
  }

  onPendingBookSourceImportChanged(): void {
    this.handlePendingBookSourceImport();
  }

  onBookSourceCheckOpenRequested(): void {
    if (this.isCheckingSources || this.checkBackgroundMode) {
      this.showCheckDialog = true;
    }
  }

  onPageShow(): void {
    this.pageVisible = true;
    this.syncBars();
    if (!this.hasShownOnce) {
      this.hasShownOnce = true;
      return;
    }
    this.refreshSources();
  }

  onPageHide(): void {
    this.pageVisible = false;
    if (!this.isCheckingSources) {
      this.releaseBookSourceCheckCancelSubscriber();
    }
  }

  async refreshSources(): Promise<void> {
    await this.loadSources();
  }

  async loadSources() {
    this.isLoading = true;
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      this.allSources = await db.getBookSourceSummaries();
      this.sourceGroups = await BookSourceGroupStore.load(getContext(this), this.sourceGroupsFromSources());
      this.ensureActiveSourceGroup();
      this.applySourceFilters();
    } catch (e) {
      console.error('加载书源失败:', e);
    } finally {
      this.isLoading = false;
    }
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        Column() {
          Row() {
            TextInput({ placeholder: '搜索书源', text: this.searchText })
              .layoutWeight(1)
              .height(40)
              .borderRadius(20)
              .backgroundColor(this.glassInputColor())
              .border({ width: ThemeRuntime.glassBorderWidth(), color: this.glassBorderColor() })
              .shadow({ radius: ThemeRuntime.glassShadowRadius(), color: this.glassShadowColor(), offsetX: ThemeRuntime.glassShadowOffsetX(), offsetY: ThemeRuntime.glassShadowOffsetY() })
              .fontColor(this.primaryTextColor())
              .placeholderColor(this.placeholderTextColor())
              .padding({ left: 16, right: 16 })
              .onChange((value: string) => {
                this.searchText = value;
                this.searchSources();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })

          if (!this.selectionMode) {
            this.sourceGroupBar()
          }

          if (this.selectionMode) {
            Row() {
              Text(this.isAllSelected() ? '☑' : '☐')
                .fontSize(20)
                .fontColor(this.accentColor())
                .width(28)
                .textAlign(TextAlign.Center)
                .onClick(() => {
                  if (this.isBatchOperating) {
                    return;
                  }
                  this.toggleAllSources();
                })

              Text(`已选择 ${this.selectedSourceUrls.length}/${this.allSources.length}`)
                .fontSize(14)
                .fontColor(this.secondaryTextColor())
                .margin({ left: 8 })
                .layoutWeight(1)

              Text(this.isAllSelected() ? '取消全选' : '全选')
                .fontSize(14)
                .fontColor(this.isBatchOperating ? this.subTextColor() : this.accentColor())
                .onClick(() => {
                  if (this.isBatchOperating) {
                    return;
                  }
                  this.toggleAllSources();
                })
            }
            .width('100%')
            .height(42)
            .padding({ left: 16, right: 16 })
          }
        }
        .width('100%')
        .backgroundColor(ThemeRuntime.topBarColor(this.appDarkMode))
        .backdropBlur(ThemeRuntime.topBarBlur())
        .zIndex(2)

        if (this.isLoading) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
            Text('加载中...')
              .fontSize(14)
              .fontColor(this.subTextColor())
              .margin({ top: 8 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.sources.length === 0) {
          Column() {
            Text(this.emptySourceTitle())
              .fontSize(16)
              .fontColor(this.subTextColor())
            Text(this.emptySourceDescription())
              .fontSize(14)
              .fontColor(this.subTextColor())
              .margin({ top: 8 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          Stack({ alignContent: Alignment.TopEnd }) {
            List({ space: 8, scroller: this.sourceListScroller }) {
            ListItem() {
              Row()
                .height(this.sourceListTopInset())
                .hitTestBehavior(HitTestMode.None)
            }

            ForEach(this.visibleSources, (source: BookSource) => {
              ListItem() {
                Row() {
                  if (this.selectionMode) {
                    Toggle({ type: ToggleType.Checkbox, isOn: this.isSourceSelected(source.bookSourceUrl) })
                      .selectedColor(this.buttonColor())
                      .enabled(!this.isBatchOperating)
                      .margin({ right: 12 })
                      .onChange((isOn: boolean) => {
                        if (this.isBatchOperating) {
                          return;
                        }
                        this.setSourceSelected(source.bookSourceUrl, isOn);
                      })
                  }

                  if (!this.selectionMode) {
                    Text('☰')
                      .fontSize(18)
                      .fontColor(this.subTextColor())
                      .width(28)
                      .height(40)
                      .textAlign(TextAlign.Center)
                      .margin({ right: 8 })
                      .accessibilityText(`拖动排序：${source.bookSourceName}`)
                  }

                  Column() {
                    Row() {
                      Text(source.bookSourceName)
                        .fontSize(16)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(this.primaryTextColor())
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)

                      if (source.isPinned) {
                        this.sourceStatusIcon($r('sys.symbol.pin'), this.accentColor(), '已置顶')
                      }
                      if (this.isSourceAtBottom(source)) {
                        this.sourceOrderStatusBadge('尾', '已置尾')
                      }

                      if (source.bookSourceGroup) {
                        Text(source.bookSourceGroup)
                          .fontSize(11)
                          .fontColor(this.accentColor())
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .constraintSize({ maxWidth: 72 })
                          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                          .backgroundColor(this.inputColor())
                          .borderRadius(4)
                          .margin({ left: 6 })
                      }

                      if (this.sourceNeedsLogin(source)) {
                        this.sourceLoginStatusBadge(
                          this.sourceLoggedIn(source) ? '#1E8E3E' : '#C62828',
                          this.sourceLoggedIn(source) ? '已登录' : '未登录')
                      }
                      if (source.isLocked) {
                        this.sourceStatusIcon($r('sys.symbol.lock'), this.accentColor(), '已锁定')
                      }
                    }
                    .width('100%')
                    .alignItems(VerticalAlign.Center)

                    Row({ space: 7 }) {
                      this.sourceValidationStatusBadge(source.validationStatus)
                      Text(source.bookSourceUrl)
                        .fontSize(12)
                        .fontColor(this.subTextColor())
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                    }
                    .width('100%')
                    .margin({ top: 4 })
                    .alignItems(VerticalAlign.Center)

                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  .gesture(
                    LongPressGesture({ repeat: false })
                      .onAction((event: GestureEvent) => {
                        if (!this.selectionMode && !this.isBatchOperating) {
                          this.openSourceActions(source, event);
                        }
                      })
                  )

                  if (this.selectionMode) {
                    Column() {
                      Text(source.enabled ? '已启用' : '已禁用')
                        .fontSize(12)
                        .fontColor(source.enabled ? '#1E8E3E' : this.subTextColor())
                      Text(source.enabledExplore ? '发现已启用' : '发现已禁用')
                        .fontSize(12)
                        .fontColor(source.enabledExplore ? '#1E8E3E' : this.subTextColor())
                        .margin({ top: 4 })
                    }
                    .alignItems(HorizontalAlign.End)
                  }
                }
                .width('100%')
                .padding(12)
                .backgroundColor(this.glassCardColor())
                .borderRadius(8)
                .border({ width: ThemeRuntime.glassBorderWidth(), color: this.glassBorderColor() })
                .shadow({ radius: ThemeRuntime.glassShadowRadius(), color: this.glassShadowColor(), offsetX: ThemeRuntime.glassShadowOffsetX(), offsetY: ThemeRuntime.glassShadowOffsetY() })
                .opacity(source.enabled ? 1 : 0.45)
                .onClick(() => {
                  if (this.isBatchOperating) {
                    return;
                  }
                  if (this.selectionMode) {
                    this.toggleSourceSelected(source.bookSourceUrl);
                  }
                })
              }
              .width('100%')
              .borderRadius(8)
              .clip(true)
              .swipeAction(this.selectionMode || source.isLocked ? {} : {
                start: {
                  builder: () => {
                    this.sourceDisableSwipeAction(source)
                  },
                  actionAreaDistance: 64,
                  onAction: () => {
                    if (!this.selectionMode && !this.isBatchOperating) this.toggleSourceEnabled(source);
                  }
                },
                end: {
                  builder: () => {
                    this.sourceDeleteSwipeAction(source)
                  },
                  actionAreaDistance: 64,
                  onAction: () => {
                    if (!this.selectionMode && !this.isBatchOperating) this.deleteSourceFromSwipe(source);
                  }
                },
                edgeEffect: SwipeEdgeEffect.Spring
              })
            }, (source: BookSource) => this.sourceListItemKey(source))

            ListItem() {
              Row()
                .height(Math.max(20, this.navBarHeight + 12))
            }
            }
            .width('100%')
            .height('100%')
            .padding({ left: 16, right: 16 })
            .lanes(ResponsiveManagerListLayout.laneCount(this.contextViewportWidth),
              ResponsiveManagerListLayout.gutter(this.contextViewportWidth))
            .scrollBar(BarState.Off)
            .clip(true)
            .onScrollIndex((start: number, end: number) => {
              this.sourceFirstVisibleIndex = Math.max(0, start - 1);
              this.sourceVisibleItemCount = Math.max(1, end - start + 1);
            })
            .onReachEnd(() => this.loadMoreVisibleSources())
            .onItemDragStart((_event: ItemDragInfo, itemIndex: number) => {
              const sourceIndex = itemIndex - 1;
              this.draggingSourceUrl = !this.selectionMode && sourceIndex >= 0 &&
                sourceIndex < this.visibleSources.length ? this.visibleSources[sourceIndex].bookSourceUrl : '';
              return this.sourceDragPreview;
            })
            .onItemDrop((_event: ItemDragInfo, itemIndex: number, insertIndex: number, isSuccess: boolean) => {
              if (isSuccess && this.draggingSourceUrl) {
                this.moveVisibleSourceTo(itemIndex - 1, Math.max(0, insertIndex - 1));
              }
              this.draggingSourceUrl = '';
            })

            this.sourceVirtualScrollbar()
          }
          .width('100%')
          .layoutWeight(1)
          .margin({ top: -this.sourceListTopInset() })
          .zIndex(0)
          .onAreaChange((_oldValue: Area, newValue: Area) => {
            this.sourceListViewportHeight = Number(newValue.height);
          })
        }

        if (this.selectionMode) {
          Row() {
            Button('启用')
              .layoutWeight(1)
              .height(42)
              .enabled(this.selectedSourceUrls.length > 0 && !this.isBatchOperating)
              .backgroundColor(this.buttonColor())
              .fontColor('#FFFFFF')
              .onClick(() => {
                this.batchSetEnabled(true);
              })

            Button('禁用')
              .layoutWeight(1)
              .height(42)
              .margin({ left: 8 })
              .enabled(this.selectedSourceUrls.length > 0 && !this.isBatchOperating)
              .backgroundColor(this.inputColor())
              .fontColor(this.primaryTextColor())
              .onClick(() => {
                this.batchSetEnabled(false);
              })

            Button('分组')
              .layoutWeight(1)
              .height(42)
              .margin({ left: 8 })
              .enabled(this.selectedSourceUrls.length > 0 && !this.isBatchOperating)
              .backgroundColor(this.inputColor())
              .fontColor(this.primaryTextColor())
              .onClick(() => {
                this.groupNameInput = this.commonSelectedGroupName();
                this.showGroupDialog = true;
              })

            Button('更多')
              .layoutWeight(1)
              .height(42)
              .margin({ left: 8 })
              .enabled(this.selectedSourceUrls.length > 0 && !this.isBatchOperating)
              .backgroundColor(this.inputColor())
              .fontColor(this.primaryTextColor())
              .onClick(() => {
                this.showMoreActionDialog = true;
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 10, bottom: 12 })
          .backgroundColor(this.glassCardColor())
          .border({ width: ThemeRuntime.glassBorderWidth(), color: this.glassBorderColor() })
        }
      }
      .width('100%')
      .height('100%')
      .padding({ top: 56 + this.statusBarHeight })
      .backgroundColor(this.pageColor())

      this.bookSourceTitleBar()

      if (!this.selectionMode && !this.showAddDialog && !this.isImporting && !this.isBatchOperating) {
        this.addSourceFloatingButton()
      }

      if (this.showAddDialog) {
        this.addSourceDropdown()
      }

      if (this.showImportUrlDialog) {
        Column() {
          Column() {
            Text('从URL导入')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ bottom: 16 })

            TextInput({ placeholder: '请输入书源URL', text: this.importUrl })
              .width('100%')
              .height(48)
              .borderRadius(8)
              .backgroundColor(this.inputColor())
              .fontColor(this.primaryTextColor())
              .placeholderColor(this.placeholderTextColor())
              .padding({ left: 12, right: 12 })
              .margin({ bottom: 16 })
              .onChange((value: string) => {
                this.importUrl = value;
              })

            Row() {
              Button('取消')
                .width('45%')
                .height(44)
                .backgroundColor(this.inputColor())
                .fontColor(this.primaryTextColor())
                .onClick(() => {
                  this.showImportUrlDialog = false;
                  this.importUrl = '';
                })

              Button('导入')
                .width('45%')
                .height(44)
                .backgroundColor(this.buttonColor())
                .fontColor('#FFFFFF')
                .onClick(() => {
                  this.importFromUrl();
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
          .width('90%')
          .padding(24)
          .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
          .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
          .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
          .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
          .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.showImportUrlDialog = false;
        })
      }

      if (this.showBatchDeleteDialog) {
        Column() {
          Column() {
            Text('确认删除')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ bottom: 12 })

            Text(`确定删除已选择的 ${this.selectedSourceUrls.length} 个书源吗？删除后不可恢复。`)
              .fontSize(15)
              .fontColor(this.secondaryTextColor())
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ bottom: 20 })

            Row() {
              Button('取消')
                .width('45%')
                .height(44)
                .backgroundColor(this.inputColor())
                .fontColor(this.primaryTextColor())
                .onClick(() => {
                  this.showBatchDeleteDialog = false;
                })

              Button('删除')
                .width('45%')
                .height(44)
                .backgroundColor('#E53935')
                .onClick(() => {
                  this.showBatchDeleteDialog = false;
                  this.batchDeleteSelectedSources();
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
          .width('85%')
          .padding(24)
          .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
          .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
          .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
          .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
          .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.showBatchDeleteDialog = false;
        })
      }

      if (this.showGroupDialog) {
        Column() {
          Column() {
            Text('设置书源分组')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ bottom: 12 })

            Text(this.groupActionSourceUrl ? `书源：${this.actionGroupingSourceName()}` :
              `已选择 ${this.selectedSourceUrls.length} 个书源`)
              .fontSize(13)
              .fontColor(this.subTextColor())
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ bottom: 14 })

            TextInput({ placeholder: '输入新分组名称，留空为未分组', text: this.groupNameInput })
              .width('100%')
              .height(44)
              .borderRadius(8)
              .backgroundColor(this.inputColor())
              .fontColor(this.primaryTextColor())
              .placeholderColor(this.placeholderTextColor())
              .padding({ left: 12, right: 12 })
              .onChange((value: string) => {
                this.groupNameInput = value;
              })

            if (this.getSourceGroups().length > 0) {
              Scroll() {
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.getSourceGroups(), (group: string) => {
                    Text(group)
                      .fontSize(13)
                      .fontColor(this.secondaryTextColor())
                      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                      .backgroundColor(this.inputColor())
                      .borderRadius(14)
                      .margin({ right: 8, top: 10 })
                      .onClick(() => {
                        this.groupNameInput = group;
                      })
                  })
                }
                .width('100%')
              }
              .width('100%')
              .constraintSize({ maxHeight: 240 })
              .scrollBar(BarState.Auto)
            }

            Row() {
              Button('取消')
                .width('45%')
                .height(44)
                .backgroundColor(this.inputColor())
                .fontColor(this.primaryTextColor())
                .onClick(() => {
                  this.closeSourceGroupDialog();
                })

              Button('保存')
                .width('45%')
                .height(44)
                .backgroundColor(this.buttonColor())
                .fontColor('#FFFFFF')
                .onClick(() => {
                  this.applySelectedSourceGroup();
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
            .margin({ top: 18 })
          }
          .width('88%')
          .constraintSize({ maxHeight: '78%' })
          .padding(24)
          .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
          .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
          .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
          .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
          .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.closeSourceGroupDialog();
        })
      }

      if (this.showMoreActionDialog) {
        this.batchMorePopupMenu()
      }

      if (this.showSourceGroupActionMenu) {
        this.sourceGroupActionMenu()
      }

      if (this.showSourceGroupToolsMenu) {
        this.sourceGroupToolsMenu()
      }

      if (this.showSourceGroupManagerDialog) {
        this.sourceGroupManagerDialog()
      }

      if (this.showRenameSourceGroupDialog) {
        this.renameSourceGroupDialog()
      }

      if (this.showDeleteSourceGroupDialog) {
        this.deleteSourceGroupDialog()
      }

      if (this.showDeleteSelectedSourceGroupsDialog) {
        this.deleteSelectedSourceGroupsDialog()
      }

      if (this.showAddSourceGroupDialog) {
        this.addSourceGroupDialog()
      }

      if (this.showSourceFilterDialog) {
        this.sourceFilterDialog()
      }

      if (this.showCheckOptionsDialog) {
        this.checkOptionsDialog()
      }

      if (this.showSourceActionDialog) {
        this.sourceActionDialog()
      }

      if (this.showSourceLoginUiDialog) {
        this.sourceLoginUiDialog()
      }

      if (this.showSourceDeleteDialog) {
        this.sourceDeleteDialog()
      }

      if (this.showCheckDialog) {
        Column() {
          Column() {
            Text(this.isCheckingSources ? '正在校验书源' : '校验完成')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ bottom: 12 })

            if (this.isCheckingSources) {
              LoadingProgress()
                .width(42)
                .height(42)
                .color(this.accentColor())
                .margin({ bottom: 12 })
            }

            Text(this.checkStatus || (this.isCheckingSources ? '准备中...' : this.checkSummaryText()))
              .fontSize(14)
              .fontColor(this.secondaryTextColor())
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ bottom: 12 })

            Progress({ value: this.checkDone, total: Math.max(this.checkTotal, 1), type: ProgressType.Linear })
              .width('100%')
              .height(8)
              .color(this.buttonColor())
              .backgroundColor(this.inputColor())
              .margin({ bottom: 12 })

            Text(`${this.checkDone}/${this.checkTotal}`)
              .fontSize(13)
              .fontColor(this.subTextColor())
              .margin({ bottom: this.isCheckingSources ? 0 : 12 })

            if (this.isCheckingSources) {
              Row({ space: 10 }) {
                Button('取消', { type: ButtonType.Normal })
                  .layoutWeight(1)
                  .height(42)
                  .borderRadius(10)
                  .fontSize(13)
                  .backgroundColor(this.inputColor())
                  .fontColor(this.primaryTextColor())
                  .onClick(() => {
                    this.cancelBookSourceCheck(true);
                  })

                Button('后台', { type: ButtonType.Normal })
                  .layoutWeight(1)
                  .height(42)
                  .borderRadius(10)
                  .fontSize(13)
                  .backgroundColor(this.buttonColor())
                  .fontColor('#FFFFFF')
                  .onClick(() => {
                    this.continueBookSourceCheckInBackground();
                  })
              }
              .width('100%')
              .margin({ top: 16 })
            }

            if (!this.isCheckingSources) {
              Text(this.checkResultText())
                .fontSize(14)
                .fontColor(this.secondaryTextColor())
                .width('100%')
                .textAlign(TextAlign.Center)
                .margin({ bottom: 12 })

              if (this.checkResultDetails.length > 0) {
                Scroll() {
                  Column() {
                    ForEach(this.checkResultDetails, (name: string, index: number) => {
                      Text(name)
                        .fontSize(13)
                        .fontColor(this.subTextColor())
                        .width('100%')
                        .maxLines(2)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .margin({ bottom: index === this.checkResultDetails.length - 1 ? 0 : 6 })
                    }, (name: string, index: number) => `${index}-${name}`)
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .height(Math.min(this.checkResultDetails.length * 40 + 20, 160))
                .padding(10)
                .backgroundColor(this.inputColor())
                .borderRadius(8)
                .margin({ bottom: 16 })
                .scrollBar(BarState.Auto)
              }

              Row({ space: 8 }) {
                if (this.checkInvalidAction === 'none') {
                  Button('禁用失败项', { type: ButtonType.Normal })
                    .layoutWeight(1)
                    .height(42)
                    .borderRadius(10)
                    .fontSize(11)
                    .enabled(this.checkBadUrls.length > 0 && !this.isBatchOperating)
                    .backgroundColor(this.checkBadUrls.length > 0 && !this.isBatchOperating ? '#F57C00' : this.inputColor())
                    .fontColor(this.checkBadUrls.length > 0 && !this.isBatchOperating ? '#FFFFFF' : this.subTextColor())
                    .onClick(() => {
                      this.disableFailedCheckedSources();
                    })

                  Button('删除失败项', { type: ButtonType.Normal })
                    .layoutWeight(1)
                    .height(42)
                    .borderRadius(10)
                    .fontSize(11)
                    .enabled(this.checkBadUrls.length > 0 && !this.isBatchOperating)
                    .backgroundColor(this.checkBadUrls.length > 0 && !this.isBatchOperating ? '#E53935' : this.inputColor())
                    .fontColor(this.checkBadUrls.length > 0 && !this.isBatchOperating ? '#FFFFFF' : this.subTextColor())
                    .onClick(() => {
                      this.deleteFailedCheckedSources();
                    })
                }

                Button('关闭', { type: ButtonType.Normal })
                  .layoutWeight(1)
                  .height(42)
                  .borderRadius(10)
                  .fontSize(11)
                  .backgroundColor(this.inputColor())
                  .fontColor(this.primaryTextColor())
                  .onClick(() => {
                    this.showCheckDialog = false;
                  })
              }
              .width('100%')
              .justifyContent(FlexAlign.SpaceBetween)
            }
          }
          .width('88%')
          .constraintSize({ maxHeight: '78%' })
          .padding(24)
          .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
          .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
          .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
          .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
          .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
          .alignItems(HorizontalAlign.Center)
          .onClick(() => {
          })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          if (!this.isCheckingSources) {
            this.showCheckDialog = false;
          }
        })
      }

      if (this.webImportActive) {
        Web({ src: 'about:blank', controller: this.webImportController })
          .width(1)
          .height(1)
          .opacity(0.01)
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .mixedMode(MixedMode.All)
          .onControllerAttached(() => {
            this.startWebImportDownload();
          })
      }

      // Keep one JS runtime mounted for the lifetime of this page. Creating a new
      // controller for every click can fire onControllerAttached before about:blank
      // is ready, leaving runJavaScript pending forever on some Harmony devices.
      Web({ src: 'about:blank', controller: this.loginRuntimeController })
        .width(1)
        .height(1)
        .opacity(0.01)
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .onPageBegin(() => {
          this.loginRuntimeReady = false;
        })
        .onPageEnd(() => {
          this.loginRuntimeReady = true;
          this.continueLoginRuntime();
        })

      if (this.isImporting) {
        Column() {
          Column() {
            LoadingProgress()
              .width(46)
              .height(46)
              .color(this.accentColor())

            Text('正在导入书源...')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
              .margin({ top: 14 })

            Text('请稍候')
              .fontSize(13)
              .fontColor(this.subTextColor())
              .margin({ top: 6 })
          }
          .width(180)
          .padding({ left: 24, right: 24, top: 26, bottom: 24 })
          .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
          .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
          .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
          .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
          .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
        })
      }

      if (this.isBatchOperating) {
        Column() {
          Column() {
            LoadingProgress()
              .width(46)
              .height(46)
              .color(this.accentColor())

            Text(this.batchOperationText)
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
              .margin({ top: 14 })

            Text('请稍候')
              .fontSize(13)
              .fontColor(this.subTextColor())
              .margin({ top: 6 })
          }
          .width(190)
          .padding({ left: 24, right: 24, top: 26, bottom: 24 })
          .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
          .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
          .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
          .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
          .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor())
    .onAreaChange((_oldValue: Area, newValue: Area) => this.updateContextViewport(newValue))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  bookSourceTitleBar() {
    Row() {
      ImmersiveBackButton({ iconColor: this.primaryTextColor(), darkMode: this.appDarkMode,
        buttonSize: 40, containerWidth: 56, materialScale: 0.83, compactLayout: true,
        onBack: () => router.back() })

      Text('书源管理')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryTextColor())
        .layoutWeight(1)

      if (!this.selectionMode) {
        Stack({ alignContent: Alignment.Center }) {
          Column({ space: 3 }) {
            Row()
              .width(20)
              .height(2)
              .borderRadius(1)
              .backgroundColor(this.hasActiveSourceFilters() ? this.accentColor() : this.primaryTextColor())
            Row()
              .width(14)
              .height(2)
              .borderRadius(1)
              .backgroundColor(this.hasActiveSourceFilters() ? this.accentColor() : this.primaryTextColor())
            Row()
              .width(8)
              .height(2)
              .borderRadius(1)
              .backgroundColor(this.hasActiveSourceFilters() ? this.accentColor() : this.primaryTextColor())
          }
          .alignItems(HorizontalAlign.Center)
          if (this.hasActiveSourceFilters()) {
            Circle()
              .width(7)
              .height(7)
              .fill(this.accentColor())
              .position({ x: 27, y: 7 })
          }
        }
        .width(40)
        .height(40)
        .accessibilityText(this.hasActiveSourceFilters() ?
          `筛选，已启用 ${this.activeSourceFilterCount()} 项` : '筛选书源')
        .onClick(() => {
          this.showSourceFilterDialog = true;
        })

        Text('校验')
          .fontSize(15)
          .fontColor(this.isCheckingSources ? this.subTextColor() : this.primaryTextColor())
          .width(44)
          .height(40)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.openCheckOptions();
          })
      }

      Text(this.selectionMode ? '取消' : '选择')
        .fontSize(15)
        .fontColor(this.isBatchOperating ? this.subTextColor() : this.primaryTextColor())
        .width(44)
        .height(40)
        .textAlign(TextAlign.Center)
        .margin({ left: this.selectionMode ? 0 : 4 })
        .onClick(() => {
          if (this.isBatchOperating) return;
          if (this.selectionMode) {
            this.exitSelectionMode();
          } else {
            this.enterSelectionMode();
          }
        })
    }
    .width('100%')
    .height(56 + this.statusBarHeight)
    .padding({ right: 16, top: this.statusBarHeight })
    .backgroundColor(ThemeRuntime.topBarColor(this.appDarkMode))
    .backdropBlur(ThemeRuntime.topBarBlur())
    .alignItems(VerticalAlign.Center)
    .position({ x: 0, y: 0 })
  }

  @Builder
  addSourceFloatingButton() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize(25)
        .fontColor([this.accentColor()])
    }
    .width(52)
    .height(52)
    .margin({ right: 22, bottom: this.navBarHeight + 22 })
    .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, this.cardColor(), 'button'))
    .backdropBlur(ThemeRuntime.glassBlur('button', 12))
    .border({ width: ThemeRuntime.glassBorderWidth('button'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'button') })
    .shadow({ radius: ThemeRuntime.glassShadowRadius('button'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'button'), offsetX: ThemeRuntime.glassShadowOffsetX('button'), offsetY: ThemeRuntime.glassShadowOffsetY('button') })
    .accessibilityText('新增书源')
    .onClick(() => {
      this.showAddDialog = true;
    })
  }

  @Builder
  addSourceDropdown() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column()
        .width('100%')
        .height('100%')
        .onClick(() => {
          this.showAddDialog = false;
        })

      Column() {
        this.popupActionItem($r('sys.symbol.plus'), '新建书源', this.primaryTextColor(), () => {
          this.showAddDialog = false;
          router.pushUrl({
            url: 'pages/BookSourceEdit',
            params: { bookSourceUrl: '' }
          });
        })
        this.popupActionItem($r('sys.symbol.arrow_right_up_and_square'), '从 URL 导入', this.primaryTextColor(), () => {
          this.showAddDialog = false;
          this.showImportUrlDialog = true;
        })
        this.popupActionItem($r('sys.symbol.download'), '从文件导入', this.primaryTextColor(), () => {
          this.showAddDialog = false;
          this.importFromFile();
        }, false)
      }
      .width(188)
      .padding({ left: 6, right: 6, top: 6, bottom: 6 })
      .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
      .borderRadius(ThemeRuntime.glassCornerRadius(16, 'panel'))
      .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
      .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'panel') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'panel'), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
      .margin({ right: 22, bottom: this.navBarHeight + 82 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  batchMorePopupMenu() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .onClick(() => {
          this.showMoreActionDialog = false;
        })

      Column() {
        Text(`已选择 ${this.selectedSourceUrls.length} 个书源`)
          .fontSize(12)
          .fontColor(this.subTextColor())
          .width('100%')
          .height(34)
          .padding({ left: 12, right: 12 })
          .textAlign(TextAlign.Start)

        this.popupActionItem($r('sys.symbol.checkmark_circle'), '启用发现', this.primaryTextColor(), () => {
          this.showMoreActionDialog = false;
          this.batchSetExploreEnabled(true);
        })
        this.popupActionItem($r('sys.symbol.minus_circle'), '禁用发现', this.primaryTextColor(), () => {
          this.showMoreActionDialog = false;
          this.batchSetExploreEnabled(false);
        })
        this.popupActionItem($r('sys.symbol.lock'), '锁定', this.primaryTextColor(), () => {
          this.showMoreActionDialog = false;
          this.batchSetLocked(true);
        })
        this.popupActionItem($r('sys.symbol.lock_open'), '解锁', this.primaryTextColor(), () => {
          this.showMoreActionDialog = false;
          this.batchSetLocked(false);
        })
        this.popupActionItem($r('sys.symbol.download'), '导出 JSON', this.primaryTextColor(), () => {
          this.showMoreActionDialog = false;
          this.exportSelectedSources();
        })
        this.popupActionItem($r('sys.symbol.trash'), '删除', '#E53935', () => {
          this.showMoreActionDialog = false;
          this.showBatchDeleteDialog = true;
        }, false)
      }
      .width(188)
      .padding({ left: 6, right: 6, top: 4, bottom: 6 })
      .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
      .borderRadius(ThemeRuntime.glassCornerRadius(16, 'panel'))
      .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
      .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'panel') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'panel'), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
      .position({ x: '100%', y: '100%' })
      .translate({ x: -200, y: -(334 + Math.max(this.navBarHeight, 8)) })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  popupActionItem(icon: Resource, label: string, color: string, action: () => void,
    showDivider: boolean = true) {
    Column() {
      Row({ space: 10 }) {
        SymbolGlyph(icon)
          .fontSize(19)
          .fontColor([color])
          .width(24)
        Text(label)
          .fontSize(15)
          .fontColor(color)
          .layoutWeight(1)
      }
      .width('100%')
      .height(44)
      .padding({ left: 10, right: 10 })

      if (showDivider) {
        Divider()
          .strokeWidth(0.5)
          .color(ThemeRuntime.glassBorderColor(this.appDarkMode))
          .margin({ left: 44, right: 8 })
      }
    }
    .width('100%')
    .onClick(action)
  }

  @Builder
  sourceFilterDialog() {
    Column() {
      Column({ space: 14 }) {
        Row() {
          Text('筛选书源')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.primaryTextColor())
            .layoutWeight(1)
          Text(`当前 ${this.sources.length}/${this.allSources.length}`)
            .fontSize(12)
            .fontColor(this.subTextColor())
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        this.sourceSortFilterRow()
        this.sourceFilterRow('书源状态', 'enabled', '已启用', '未启用')
        this.sourceValidationFilterRow()
        this.sourceFilterRow('发现页面', 'explorePage', '有发现页', '无发现页')
        this.sourceFilterRow('发现状态', 'exploreEnabled', '已启用', '未启用')
        this.sourceFilterRow('登录要求', 'login', '需要登录', '无需登录')

        Row({ space: 10 }) {
          Button('重置', { type: ButtonType.Normal })
            .layoutWeight(1)
            .height(42)
            .borderRadius(10)
            .enabled(this.hasActiveSourceFilters())
            .backgroundColor(this.inputColor())
            .fontColor(this.primaryTextColor())
            .onClick(() => this.resetSourceFilters())
          Button('完成', { type: ButtonType.Normal })
            .layoutWeight(1)
            .height(42)
            .borderRadius(10)
            .backgroundColor(this.buttonColor())
            .fontColor('#FFFFFF')
            .onClick(() => this.showSourceFilterDialog = false)
        }
        .width('100%')
        .margin({ top: 4 })
      }
      .width('92%')
      .constraintSize({ maxWidth: 540 })
      .padding(22)
      .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
      .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
      .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
      .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#80000000')
  }

  @Builder
  sourceSortFilterRow() {
    Row({ space: 10 }) {
      Text('排序')
        .fontSize(14)
        .fontColor(this.primaryTextColor())
        .width(66)
      Row({ space: 6 }) {
        this.sourceSortChoice('custom', '默认')
        this.sourceSortChoice('latest', '最新在前')
        this.sourceSortChoice('oldest', '最旧在前')
        this.sourceSortChoice('name', '名称排序')
      }
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  sourceSortChoice(value: string, label: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.sourceSortMode === value ? '#FFFFFF' : this.secondaryTextColor())
      .layoutWeight(1)
      .height(34)
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .backgroundColor(this.sourceSortMode === value ? this.accentColor() : this.inputColor())
      .borderRadius(9)
      .onClick(() => {
        this.sourceSortMode = value;
        this.applySourceFilters();
      })
  }

  @Builder
  sourceFilterRow(label: string, filterKey: string, yesLabel: string, noLabel: string) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(14)
        .fontColor(this.primaryTextColor())
        .width(66)
      Row({ space: 6 }) {
        this.sourceFilterChoice(filterKey, 'all', '不限')
        this.sourceFilterChoice(filterKey, 'yes', yesLabel)
        this.sourceFilterChoice(filterKey, 'no', noLabel)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  sourceValidationFilterRow() {
    Row({ space: 10 }) {
      Text('校验状态')
        .fontSize(14)
        .fontColor(this.primaryTextColor())
        .width(66)
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        this.sourceValidationFilterChoice('all', '不限')
        this.sourceValidationFilterChoice('unchecked', '未校验')
        this.sourceValidationFilterChoice('passed', '通过')
        this.sourceValidationFilterChoice('failed', '失败')
        this.sourceValidationFilterChoice('noResults', '无结果')
        this.sourceValidationFilterChoice('needsVerification', '需要验证')
        this.sourceValidationFilterChoice('temporaryError', '暂时异常')
      }
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  sourceValidationFilterChoice(value: string, label: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.sourceValidationFilter === value ? '#FFFFFF' : this.secondaryTextColor())
      .width('32%')
      .height(34)
      .margin({ bottom: 6 })
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .backgroundColor(this.sourceValidationFilter === value ? this.accentColor() : this.inputColor())
      .borderRadius(9)
      .onClick(() => this.setSourceFilterValue('validation', value))
  }

  @Builder
  sourceFilterChoice(filterKey: string, value: string, label: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.sourceFilterValue(filterKey) === value ? '#FFFFFF' : this.secondaryTextColor())
      .layoutWeight(1)
      .height(34)
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .backgroundColor(this.sourceFilterValue(filterKey) === value ? this.accentColor() : this.inputColor())
      .borderRadius(9)
      .onClick(() => this.setSourceFilterValue(filterKey, value))
  }

  @Builder
  checkOptionsDialog() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.appDarkMode ? '#38000000' : '#14FFFFFF')
        .backdropBlur(ThemeRuntime.glassBlur('menu', 10))
        .onClick(() => {
          this.showCheckOptionsDialog = false;
        })

      Column({ space: 12 }) {
        Text('校验设置')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
          .width('100%')

        Text('只有明确的请求或规则错误会标记为失败并参与自动处理；无结果、需要验证和暂时异常不会被禁用或删除。')
          .fontSize(13)
          .fontColor(this.secondaryTextColor())
          .width('100%')

        this.checkActionOption('仅校验', '记录各类校验状态，校验完成后再手动处理', 'none')
        this.checkActionOption('自动禁用', '仅禁用明确失败的书源，可稍后重新启用', 'disable')
        this.checkActionOption('自动删除', '仅删除明确失败的书源，此操作不可恢复', 'delete', true)

        Row({ space: 10 }) {
          Button('取消')
            .layoutWeight(1)
            .height(42)
            .backgroundColor(this.inputColor())
            .fontColor(this.primaryTextColor())
            .onClick(() => {
              this.showCheckOptionsDialog = false;
            })

          Button('开始校验')
            .layoutWeight(1)
            .height(42)
            .backgroundColor(this.checkInvalidAction === 'delete' ? '#B71C1C' : this.buttonColor())
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.startCheckEnabledSources(this.checkInvalidAction);
            })
        }
        .width('100%')
        .margin({ top: 4 })
      }
      .width('calc(100% - 24vp)')
      .constraintSize({ maxWidth: 360 })
      .padding(18)
      .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
      .borderRadius(ThemeRuntime.glassCornerRadius(14, 'panel'))
      .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
      .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'panel') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'panel'), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
      .margin({ top: this.statusBarHeight + 62, right: 12 })
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  checkActionOption(title: string, description: string, action: string, danger: boolean = false) {
    Row() {
      Text(this.checkInvalidAction === action ? '●' : '○')
        .fontSize(20)
        .fontColor(this.checkInvalidAction === action ?
          (danger ? '#B71C1C' : this.accentColor()) : this.subTextColor())
        .width(28)

      Column() {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(danger ? '#B71C1C' : this.primaryTextColor())
        Text(description)
          .fontSize(12)
          .fontColor(this.subTextColor())
          .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(9)
    .backgroundColor(this.checkInvalidAction === action ? this.inputColor() : this.cardColor())
    .border({
      width: this.checkInvalidAction === action ? 1 : 0.5,
      color: this.checkInvalidAction === action ? (danger ? '#B71C1C' : this.accentColor()) : this.glassBorderColor()
    })
    .onClick(() => {
      this.checkInvalidAction = action;
    })
  }

  @Builder
  sourceActionDialog() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.appDarkMode ? '#52000000' : '#26FFFFFF')
        .backdropBlur(ThemeRuntime.glassBlur('popover', 18))
        .onClick(() => this.closeSourceActions())
      Column() {
        this.contextActionItem($r('sys.symbol.magnifyingglass'), '搜索', this.primaryTextColor(),
          () => this.openActionSourceSearch())
        if (this.actionSourceNeedsLogin()) {
          this.contextActionItem($r('sys.symbol.arrow_right_up_and_square'),
            this.actionSourceLoggedIn() ? '重新登录' : '登录',
            this.primaryTextColor(), () => this.openActionSourceLogin())
        }
        this.contextActionItem($r('sys.symbol.checkmark_shield'), '校验', this.primaryTextColor(),
          () => this.checkActionSource())
        this.contextActionItem($r('sys.symbol.pin'), this.actionSourcePinned() ? '取消置顶' : '置顶',
          this.primaryTextColor(), () => this.toggleActionSourcePinned())
        this.contextActionItem($r('sys.symbol.chevron_down'), '置底', this.primaryTextColor(),
          () => this.moveActionSourceToBottom())
        this.contextActionItem($r('sys.symbol.lock'), this.actionSourceLocked() ? '解锁' : '锁定',
          this.primaryTextColor(), () => this.toggleActionSourceLocked())
        if (!this.actionSourceLocked()) {
          this.contextActionItem($r('sys.symbol.folder'), '分组', this.primaryTextColor(),
            () => this.openActionSourceGroup())
          this.contextActionItem($r('sys.symbol.square_and_pencil'), '修改', this.primaryTextColor(),
            () => this.openActionSourceEdit())
          this.contextActionItem(this.actionSourceEnabled() ? $r('sys.symbol.minus_circle') :
            $r('sys.symbol.checkmark_circle'), this.actionSourceEnabled() ? '禁用' : '启用', this.primaryTextColor(),
            () => this.toggleActionSourceEnabled())
        }
        this.contextActionItem($r('sys.symbol.list_bullet'), '多选', this.primaryTextColor(),
          () => this.enterActionSourceSelection())
        if (!this.actionSourceLocked()) {
          this.contextActionItem($r('sys.symbol.trash'), '删除', '#E53935', () => {
              this.showSourceActionDialog = false;
              this.showSourceDeleteDialog = true;
            })
        }
      }
      .width(158)
      .padding({ top: 6, bottom: 6 })
      .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
      .borderRadius(ThemeRuntime.glassCornerRadius(14, 'panel'))
      .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
      .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'panel') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'panel'), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
      .position({
        x: this.contextMenuLeft(158),
        y: this.contextMenuTop(this.sourceActionMenuHeight())
      })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  sourceLoginUiDialog() {
    Column() {
      Column() {
        Text(`${this.actionSourceName()} · 登录与接口`)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: 12 })

        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.sourceLoginItems, (item: BookSourceLoginItem, index: number) => {
              if (this.isSourceLoginInput(item)) {
                Column({ space: 4 }) {
                  Text(item.name)
                    .fontSize(12)
                    .fontColor(this.subTextColor())
                    .width('100%')
                  TextInput({ text: item.value, placeholder: item.placeholder || item.name })
                    .type(item.type.toLowerCase() === 'password' ? InputType.Password : InputType.Normal)
                    .width('100%')
                    .height(42)
                    .borderRadius(8)
                    .backgroundColor(this.inputColor())
                    .fontColor(this.primaryTextColor())
                    .placeholderColor(this.placeholderTextColor())
                    .padding({ left: 12, right: 12 })
                    .enabled(!this.isExecutingLoginAction)
                    .onChange((value: string) => {
                      this.updateSourceLoginInput(index, value);
                    })
                }
                .width('100%')
              } else {
                Button(this.isExecutingLoginAction && item.action ? `执行中 · ${item.name}` : item.name,
                  { type: ButtonType.Normal })
                  .width('100%')
                  .height(40)
                  .fontSize(14)
                  .fontColor(item.action ? this.primaryTextColor() : this.subTextColor())
                  .backgroundColor(item.action ? this.inputColor() : this.cardColor())
                  .enabled(!!item.action && !this.isExecutingLoginAction)
                  .onClick(() => {
                    this.executeSourceLoginAction(item);
                  })
              }
            }, (item: BookSourceLoginItem, index: number) => `${index}_${item.name}_${item.action}`)
          }
          .width('100%')
        }
        .width('100%')
        .constraintSize({ maxHeight: 430 })
        .scrollBar(BarState.Auto)

        Button('关闭')
          .width('100%')
          .height(42)
          .margin({ top: 8 })
          .backgroundColor(this.buttonColor())
          .fontColor('#FFFFFF')
          .onClick(() => {
            this.saveSourceLoginInputs();
            this.showSourceLoginUiDialog = false;
            this.sourceLoginItems = [];
            this.actionSourceUrl = '';
            this.actionSourceDetail = null;
          })
      }
      .width('90%')
      .padding(22)
      .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
      .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
      .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
      .border({ width: ThemeRuntime.glassBorderWidth('overlay'),
        color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  contextActionItem(icon: Resource, label: string, color: string, action: () => void) {
    Row({ space: 10 }) {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([color])
        .width(24)
      Text(label)
        .fontSize(15)
        .fontColor(color)
        .layoutWeight(1)
    }
    .width('100%')
    .height(44)
    .padding({ left: 12, right: 12 })
    .alignItems(VerticalAlign.Center)
    .onClick(action)
  }

  @Builder
  sourceOrderStatusBadge(label: string, accessibilityLabel: string) {
    Text(label)
      .fontSize(11)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.accentColor())
      .width(24)
      .height(24)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.inputColor())
      .borderRadius(12)
      .margin({ left: 6 })
      .accessibilityText(accessibilityLabel)
  }

  @Builder
  sourceStatusIcon(icon: Resource, color: string, accessibilityLabel: string) {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(icon)
        .fontSize(16)
        .fontColor([color])
    }
    .width(24)
    .height(24)
    .borderRadius(12)
    .backgroundColor(this.inputColor())
    .margin({ left: 6 })
    .accessibilityText(accessibilityLabel)
  }

  @Builder
  sourceLoginStatusBadge(color: string, accessibilityLabel: string) {
    Text('登')
      .fontSize(11)
      .fontWeight(FontWeight.Medium)
      .fontColor(color)
      .width(24)
      .height(24)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.inputColor())
      .borderRadius(12)
      .margin({ left: 6 })
      .accessibilityText(accessibilityLabel)
  }

  @Builder
  sourceValidationStatusBadge(validationStatus: number) {
    Text(this.sourceValidationStatusLabel(validationStatus))
      .fontSize(10)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.sourceValidationStatusColor(validationStatus))
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .backgroundColor(this.inputColor())
      .borderRadius(4)
      .maxLines(1)
      .accessibilityText(this.sourceValidationStatusLabel(validationStatus))
  }

  sourceValidationStatusLabel(validationStatus: number): string {
    if (validationStatus === BookSource.VALIDATION_PASSED) return '通过';
    if (validationStatus === BookSource.VALIDATION_FAILED) return '失败';
    if (validationStatus === BookSource.VALIDATION_NO_RESULTS) return '无结果';
    if (validationStatus === BookSource.VALIDATION_NEEDS_VERIFICATION) return '需要验证';
    if (validationStatus === BookSource.VALIDATION_TEMPORARY_ERROR) return '暂时异常';
    return '未校验';
  }

  sourceValidationStatusColor(validationStatus: number): string {
    if (validationStatus === BookSource.VALIDATION_PASSED) return '#1E8E3E';
    if (validationStatus === BookSource.VALIDATION_FAILED) return '#C62828';
    if (validationStatus === BookSource.VALIDATION_NO_RESULTS) return '#8A6D3B';
    if (validationStatus === BookSource.VALIDATION_NEEDS_VERIFICATION) return '#1565C0';
    if (validationStatus === BookSource.VALIDATION_TEMPORARY_ERROR) return '#F57C00';
    return this.subTextColor();
  }

  @Builder
  sourceDisableSwipeAction(source: BookSource) {
    Column({ space: 4 }) {
      SymbolGlyph(source.enabled ? $r('sys.symbol.minus_circle') : $r('sys.symbol.checkmark_circle'))
        .fontSize(22)
        .fontColor(['#FFFFFF'])
      Text(source.enabled ? '禁用' : '启用')
        .fontSize(11)
        .fontColor('#FFFFFF')
    }
    .width(64)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(source.enabled ? '#F39C3D' : '#1E8E3E')
    .onClick(() => {
      if (!this.selectionMode && !this.isBatchOperating) this.toggleSourceEnabled(source);
    })
  }

  @Builder
  sourceDeleteSwipeAction(source: BookSource) {
    Column({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(22)
        .fontColor(['#FFFFFF'])
      Text('删除')
        .fontSize(11)
        .fontColor('#FFFFFF')
    }
    .width(64)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#E53935')
    .onClick(() => {
      if (!this.selectionMode && !this.isBatchOperating) this.deleteSourceFromSwipe(source);
    })
  }

  @Builder
  sourceDeleteDialog() {
    Column() {
      Column() {
        Text('删除书源')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
          .width('100%')
          .textAlign(TextAlign.Center)

        Text(`确定删除“${this.actionSourceName()}”吗？删除后不可恢复。`)
          .fontSize(14)
          .fontColor(this.secondaryTextColor())
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 12, bottom: 20 })

        Row({ space: 10 }) {
          Button('取消')
            .layoutWeight(1)
            .height(44)
            .backgroundColor(this.inputColor())
            .fontColor(this.primaryTextColor())
            .onClick(() => {
              this.showSourceDeleteDialog = false;
              this.actionSourceUrl = '';
            })

          Button('删除')
            .layoutWeight(1)
            .height(44)
            .backgroundColor('#B71C1C')
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.deleteActionSource();
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(22)
      .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
      .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
      .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
      .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.showSourceDeleteDialog = false;
      this.actionSourceUrl = '';
    })
  }

  @Builder
  sourceDragPreview() {
    Row() {
      Text('☰')
        .fontSize(18)
        .fontColor(this.subTextColor())
        .width(28)
        .textAlign(TextAlign.Center)
        .margin({ right: 8 })
      Column() {
        Text(this.draggingSourceName())
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.draggingSourceUrl)
          .fontSize(12)
          .fontColor(this.subTextColor())
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width(280)
    .padding(12)
    .borderRadius(8)
    .backgroundColor(this.cardColor())
    .shadow({ radius: 12, color: this.appDarkMode ? '#66000000' : '#22000000', offsetX: 0, offsetY: 4 })
  }

  @Builder
  sourceVirtualScrollbar() {
    if (this.sourceShouldShowVirtualScrollbar()) {
      Column()
        .width(3)
        .height(this.sourceListViewportHeight)
        .borderRadius(2)
        .backgroundColor(this.appDarkMode ? '#18FFFFFF' : '#14000000')
        .margin({ right: 3 })
        .hitTestBehavior(HitTestMode.None)
      Column()
        .width(3)
        .height(this.sourceScrollbarThumbLength())
        .borderRadius(2)
        .backgroundColor(this.appDarkMode ? '#99D5D8DE' : '#887A6F63')
        .margin({ right: 3 })
        .translate({ y: this.sourceScrollbarThumbOffset() })
        .hitTestBehavior(HitTestMode.None)
    }
  }

  sourceShouldShowVirtualScrollbar(): boolean {
    return this.sourceListViewportHeight > 0 && this.sources.length > this.sourceVisibleItemCount;
  }

  sourceScrollbarThumbLength(): number {
    return VirtualListScrollbar.thumbLength(this.sourceListViewportHeight,
      this.sources.length, this.sourceVisibleItemCount);
  }

  sourceScrollbarThumbOffset(): number {
    return VirtualListScrollbar.thumbOffset(this.sourceListViewportHeight,
      this.sourceScrollbarThumbLength(), this.sources.length,
      this.sourceFirstVisibleIndex, this.sourceVisibleItemCount);
  }

  sourceListTopInset(): number {
    return 56 + this.statusBarHeight + 98;
  }

  @Builder
  sourceGroupBar() {
    Scroll() {
      Row({ space: 8 }) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.more'))
            .fontSize(18)
            .fontColor([this.primaryTextColor()])
        }
          .width(32)
          .height(32)
          .borderRadius(16)
          .backgroundColor(this.glassCardColor())
          .border({ width: ThemeRuntime.glassBorderWidth(), color: this.glassBorderColor() })
          .onClick((event: ClickEvent) => {
            this.contextMenuX = event.windowX;
            this.contextMenuY = event.windowY;
            this.showSourceGroupToolsMenu = true;
          })
        this.sourceGroupChip('全部', '__all__')
        ForEach(this.getSourceGroups(), (group: string) => {
          this.sourceGroupChip(group, group, true)
        }, (group: string) => group)
        this.sourceGroupChip('未分组', '__ungrouped__')
        Text('＋')
          .fontSize(20)
          .fontColor(this.accentColor())
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .borderRadius(17)
          .backgroundColor(this.glassCardColor())
          .border({ width: ThemeRuntime.glassBorderWidth(), color: this.glassBorderColor() })
          .onClick(() => {
            this.newSourceGroupInput = '';
            this.showAddSourceGroupDialog = true;
          })
      }
      .padding({ left: 16, right: 16, bottom: 8 })
      .constraintSize({ minWidth: '100%' })
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .zIndex(2)
  }

  @Builder
  sourceGroupToolsMenu() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showSourceGroupToolsMenu = false;
        })

      Column() {
        this.contextActionItem($r('sys.symbol.list_bullet'), '分组管理', this.primaryTextColor(), () => {
          this.showSourceGroupToolsMenu = false;
          this.selectedManagedSourceGroups = [];
          this.showSourceGroupManagerDialog = true;
        })
        this.contextActionItem($r('sys.symbol.trash'), '清除空分组', this.primaryTextColor(), () => {
          this.showSourceGroupToolsMenu = false;
          this.clearEmptySourceGroups();
        })
        this.contextActionItem($r('sys.symbol.plus'), '新建分组', this.primaryTextColor(), () => {
          this.showSourceGroupToolsMenu = false;
          this.newSourceGroupInput = '';
          this.showAddSourceGroupDialog = true;
        })
      }
      .width(166)
      .padding({ top: 6, bottom: 6 })
      .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
      .borderRadius(ThemeRuntime.glassCornerRadius(14, 'panel'))
      .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
      .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'panel') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'panel'), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
      .position({ x: this.contextMenuLeft(166), y: this.contextMenuTop(144) })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  sourceGroupManagerDialog() {
    Column() {
      Column() {
        Row() {
          Text('分组管理')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.primaryTextColor())
            .layoutWeight(1)
          Text('新建')
            .fontSize(14)
            .fontColor(this.accentColor())
            .padding({ left: 10, right: 2, top: 8, bottom: 8 })
            .onClick(() => {
              this.newSourceGroupInput = '';
              this.showAddSourceGroupDialog = true;
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.getSourceGroups().length === 0) {
          Column({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.folder'))
              .fontSize(30)
              .fontColor([this.subTextColor()])
            Text('暂无书源分组')
              .fontSize(14)
              .fontColor(this.subTextColor())
          }
          .width('100%')
          .height(150)
          .justifyContent(FlexAlign.Center)
        } else {
          Row() {
            Toggle({ type: ToggleType.Checkbox, isOn: this.areAllManagedSourceGroupsSelected() })
              .selectedColor(this.buttonColor())
              .onChange((isOn: boolean) => this.selectAllManagedSourceGroups(isOn))
            Text(this.areAllManagedSourceGroupsSelected() ? '取消全选' : '全选')
              .fontSize(13)
              .fontColor(this.secondaryTextColor())
              .margin({ left: 8 })
              .layoutWeight(1)
            Text(`已选 ${this.selectedManagedSourceGroups.length} 项`)
              .fontSize(12)
              .fontColor(this.subTextColor())
          }
          .width('100%')
          .height(40)
          .padding({ left: 4, right: 4 })

          Scroll() {
            Column({ space: 6 }) {
              ForEach(this.getSourceGroups(), (group: string) => {
                Row() {
                  Toggle({ type: ToggleType.Checkbox, isOn: this.isManagedSourceGroupSelected(group) })
                    .selectedColor(this.buttonColor())
                    .onChange((isOn: boolean) => this.setManagedSourceGroupSelected(group, isOn))
                  Column() {
                    Text(group)
                      .fontSize(15)
                      .fontColor(this.primaryTextColor())
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`${this.sourceGroupCount(group)} 个书源`)
                      .fontSize(11)
                      .fontColor(this.subTextColor())
                      .margin({ top: 2 })
                  }
                  .layoutWeight(1)
                  .margin({ left: 8 })
                  .alignItems(HorizontalAlign.Start)
                  Text('编辑')
                    .fontSize(13)
                    .fontColor(this.accentColor())
                    .height(36)
                    .padding({ left: 9, right: 9 })
                    .textAlign(TextAlign.Center)
                    .onClick(() => this.openManagedSourceGroupRename(group))
                  Text('删除')
                    .fontSize(13)
                    .fontColor('#E53935')
                    .height(36)
                    .padding({ left: 9, right: 4 })
                    .textAlign(TextAlign.Center)
                    .onClick(() => this.openManagedSourceGroupDelete(group))
                }
                .width('100%')
                .height(56)
                .padding({ left: 8, right: 8 })
                .borderRadius(9)
                .backgroundColor(this.inputColor())
              }, (group: string) => group)
            }
            .width('100%')
          }
          .width('100%')
          .constraintSize({ maxHeight: 360 })
          .scrollBar(BarState.Auto)
        }

        Row({ space: 10 }) {
          Button('关闭', { type: ButtonType.Normal })
            .layoutWeight(1)
            .height(42)
            .borderRadius(10)
            .backgroundColor(this.glassCardColor())
            .fontColor(this.primaryTextColor())
            .onClick(() => {
              this.showSourceGroupManagerDialog = false;
              this.selectedManagedSourceGroups = [];
            })
          Button('删除所选', { type: ButtonType.Normal })
            .layoutWeight(1)
            .height(42)
            .borderRadius(10)
            .enabled(this.selectedManagedSourceGroups.length > 0 && !this.isBatchOperating)
            .backgroundColor('#E53935')
            .fontColor('#FFFFFF')
            .onClick(() => this.showDeleteSelectedSourceGroupsDialog = true)
        }
        .width('100%')
        .margin({ top: 16 })
      }
      .width('90%')
      .constraintSize({ maxWidth: 520 })
      .padding(22)
      .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
      .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
      .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
      .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#80000000')
  }

  @Builder
  sourceGroupChip(label: string, groupKey: string, editable: boolean = false) {
    Text(label)
      .fontSize(13)
      .fontColor(this.activeSourceGroup === groupKey ? '#FFFFFF' : this.primaryTextColor())
      .maxLines(1)
      .padding({ left: 13, right: 13, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor(this.activeSourceGroup === groupKey ? this.accentColor() : this.glassCardColor())
      .border({ width: this.activeSourceGroup === groupKey ? 0 : 1, color: this.glassBorderColor() })
      .onClick(() => {
        this.selectSourceGroup(groupKey);
      })
      .gesture(
        LongPressGesture({ repeat: false })
          .onAction((event: GestureEvent) => {
            if (editable) {
              this.openSourceGroupActions(groupKey, event);
            }
          })
      )
  }

  @Builder
  sourceGroupActionMenu() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.appDarkMode ? '#52000000' : '#26FFFFFF')
        .backdropBlur(ThemeRuntime.glassBlur('popover', 18))
        .onClick(() => this.closeSourceGroupActions())

      Column() {
        this.contextActionItem($r('sys.symbol.square_and_pencil'), '重命名', this.primaryTextColor(), () => {
            this.renameSourceGroupInput = this.pendingSourceGroup;
            this.showSourceGroupActionMenu = false;
            this.showRenameSourceGroupDialog = true;
          })
        this.contextActionItem($r('sys.symbol.trash'), '删除', '#E53935', () => {
            this.showSourceGroupActionMenu = false;
            this.showDeleteSourceGroupDialog = true;
          })
      }
      .width(148)
      .padding({ top: 6, bottom: 6 })
      .backgroundColor(ThemeRuntime.glassPanelColor(this.appDarkMode, '', 'panel'))
      .borderRadius(ThemeRuntime.glassCornerRadius(14, 'panel'))
      .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
      .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'panel') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'panel'), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
      .position({ x: this.contextMenuLeft(148), y: this.contextMenuTop(100) })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  addSourceGroupDialog() {
    Column() {
      Column({ space: 16 }) {
        Text('新增书源分组')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())

        TextInput({ placeholder: '输入分组名称', text: this.newSourceGroupInput })
          .width('100%')
          .height(42)
          .backgroundColor(this.inputColor())
          .fontColor(this.primaryTextColor())
          .borderRadius(10)
          .onChange((value: string) => this.newSourceGroupInput = value)

        Row({ space: 12 }) {
          Button('取消', { type: ButtonType.Normal })
            .layoutWeight(1)
            .height(42)
            .borderRadius(10)
            .backgroundColor(this.glassCardColor())
            .fontColor(this.primaryTextColor())
            .onClick(() => this.closeAddSourceGroupDialog())
          Button('新增', { type: ButtonType.Normal })
            .layoutWeight(1)
            .height(42)
            .borderRadius(10)
            .backgroundColor(this.buttonColor())
            .fontColor('#FFFFFF')
            .enabled(!!this.newSourceGroupInput.trim() && !this.isBatchOperating)
            .onClick(() => this.addSourceGroup())
        }
        .width('100%')
      }
      .width('85%')
      .padding(22)
      .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
      .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
      .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
      .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#80000000')
  }

  @Builder
  renameSourceGroupDialog() {
    Column() {
      Column({ space: 16 }) {
        Text('重命名书源分组')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())

        TextInput({ placeholder: '输入分组名称', text: this.renameSourceGroupInput })
          .width('100%')
          .height(42)
          .backgroundColor(this.inputColor())
          .fontColor(this.primaryTextColor())
          .borderRadius(10)
          .onChange((value: string) => this.renameSourceGroupInput = value)

        Row({ space: 12 }) {
          Button('取消', { type: ButtonType.Normal })
            .layoutWeight(1)
            .height(42)
            .borderRadius(10)
            .backgroundColor(this.glassCardColor())
            .fontColor(this.primaryTextColor())
            .onClick(() => this.closeRenameSourceGroupDialog())
          Button('保存', { type: ButtonType.Normal })
            .layoutWeight(1)
            .height(42)
            .borderRadius(10)
            .backgroundColor(this.buttonColor())
            .fontColor('#FFFFFF')
            .enabled(!!this.renameSourceGroupInput.trim() && !this.isBatchOperating)
            .onClick(() => this.renameSourceGroup())
        }
        .width('100%')
      }
      .width('85%')
      .padding(22)
      .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
      .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
      .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
      .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#80000000')
  }

  @Builder
  deleteSourceGroupDialog() {
    Column() {
      Column({ space: 16 }) {
        Text('删除书源分组')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
        Text(`删除“${this.pendingSourceGroup}”后，分组内书源将移到未分组，书源本身不会删除。`)
          .fontSize(14)
          .fontColor(this.secondaryTextColor())
          .textAlign(TextAlign.Center)
        Row({ space: 12 }) {
          Button('取消', { type: ButtonType.Normal })
            .layoutWeight(1)
            .height(42)
            .borderRadius(10)
            .backgroundColor(this.glassCardColor())
            .fontColor(this.primaryTextColor())
            .onClick(() => this.closeDeleteSourceGroupDialog())
          Button('删除', { type: ButtonType.Normal })
            .layoutWeight(1)
            .height(42)
            .borderRadius(10)
            .backgroundColor('#E53935')
            .fontColor('#FFFFFF')
            .enabled(!this.isBatchOperating)
            .onClick(() => this.deleteSourceGroup())
        }
        .width('100%')
      }
      .width('85%')
      .padding(22)
      .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
      .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
      .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
      .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#80000000')
  }

  @Builder
  deleteSelectedSourceGroupsDialog() {
    Column() {
      Column({ space: 16 }) {
        Text('删除所选分组')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
        Text(`确定删除所选 ${this.selectedManagedSourceGroups.length} 个分组吗？分组内书源将移到未分组。`)
          .fontSize(14)
          .fontColor(this.secondaryTextColor())
          .textAlign(TextAlign.Center)
        Row({ space: 12 }) {
          Button('取消', { type: ButtonType.Normal })
            .layoutWeight(1)
            .height(42)
            .borderRadius(10)
            .backgroundColor(this.glassCardColor())
            .fontColor(this.primaryTextColor())
            .onClick(() => this.showDeleteSelectedSourceGroupsDialog = false)
          Button('删除', { type: ButtonType.Normal })
            .layoutWeight(1)
            .height(42)
            .borderRadius(10)
            .backgroundColor('#E53935')
            .fontColor('#FFFFFF')
            .enabled(this.selectedManagedSourceGroups.length > 0 && !this.isBatchOperating)
            .onClick(() => this.deleteSelectedSourceGroups())
        }
        .width('100%')
      }
      .width('85%')
      .padding(22)
      .borderRadius(ThemeRuntime.glassCornerRadius(16, 'overlay'))
      .backgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode, '', 'overlay'))
      .backdropBlur(ThemeRuntime.glassBlur('overlay', 28))
      .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: ThemeRuntime.glassBorderColor(this.appDarkMode, 'overlay') })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: ThemeRuntime.glassShadowColor(this.appDarkMode, 'overlay'), offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#80000000')
  }

  syncBars(): void {
    syncSystemBars(getContext(this), this.appDarkMode, this.pageColor());
  }

  pageColor(): string {
    return ThemeRuntime.pageColor(this.appDarkMode);
  }

  cardColor(): string {
    return ThemeRuntime.cardColor(this.appDarkMode);
  }

  glassCardColor(): string {
    return this.cardColor();
  }

  inputColor(): string {
    return ThemeRuntime.inputColor(this.appDarkMode);
  }

  glassInputColor(): string {
    return this.cardColor();
  }

  glassBorderColor(): string {
    return this.appDarkMode ? '#262A31' : '#FFFFFF';
  }

  glassShadowColor(): string {
    return '#00000000';
  }

  primaryTextColor(): string {
    return ThemeRuntime.primaryTextColor(this.appDarkMode);
  }

  secondaryTextColor(): string {
    return ThemeRuntime.subTextColor(this.appDarkMode);
  }

  subTextColor(): string {
    return ThemeRuntime.subTextColor(this.appDarkMode);
  }

  placeholderTextColor(): string {
    return ThemeRuntime.subTextColor(this.appDarkMode);
  }

  accentColor(): string {
    return ThemeRuntime.accentColor(this.appDarkMode);
  }

  buttonColor(): string {
    return ThemeRuntime.buttonColor(this.appDarkMode);
  }

  searchSources(): void {
    this.applySourceFilters();
  }

  selectSourceGroup(groupKey: string): void {
    if (this.activeSourceGroup === groupKey) {
      return;
    }
    this.activeSourceGroup = groupKey;
    this.applySourceFilters();
  }

  openSourceGroupActions(group: string, event?: GestureEvent): void {
    const finger = event && event.fingerList.length > 0 ? event.fingerList[0] : undefined;
    if (finger) {
      this.contextMenuX = finger.globalX;
      this.contextMenuY = finger.globalY;
    }
    this.pendingSourceGroup = group;
    this.showSourceGroupActionMenu = true;
  }

  closeSourceGroupActions(): void {
    this.showSourceGroupActionMenu = false;
    this.pendingSourceGroup = '';
  }

  closeRenameSourceGroupDialog(): void {
    this.showRenameSourceGroupDialog = false;
    this.renameSourceGroupInput = '';
    this.pendingSourceGroup = '';
  }

  closeDeleteSourceGroupDialog(): void {
    this.showDeleteSourceGroupDialog = false;
    this.pendingSourceGroup = '';
  }

  closeAddSourceGroupDialog(): void {
    this.showAddSourceGroupDialog = false;
    this.newSourceGroupInput = '';
  }

  sourceGroupCount(group: string): number {
    return this.allSources.filter((source: BookSource) =>
      (source.bookSourceGroup || '').trim() === group).length;
  }

  isManagedSourceGroupSelected(group: string): boolean {
    return this.selectedManagedSourceGroups.includes(group);
  }

  setManagedSourceGroupSelected(group: string, selected: boolean): void {
    if (selected) {
      if (!this.isManagedSourceGroupSelected(group)) {
        this.selectedManagedSourceGroups = this.selectedManagedSourceGroups.concat([group]);
      }
      return;
    }
    this.selectedManagedSourceGroups = this.selectedManagedSourceGroups.filter((item: string) => item !== group);
  }

  areAllManagedSourceGroupsSelected(): boolean {
    const groups = this.getSourceGroups();
    return groups.length > 0 && this.selectedManagedSourceGroups.length === groups.length;
  }

  selectAllManagedSourceGroups(selected: boolean): void {
    this.selectedManagedSourceGroups = selected ? this.getSourceGroups() : [];
  }

  openManagedSourceGroupRename(group: string): void {
    this.pendingSourceGroup = group;
    this.renameSourceGroupInput = group;
    this.showRenameSourceGroupDialog = true;
  }

  openManagedSourceGroupDelete(group: string): void {
    this.pendingSourceGroup = group;
    this.showDeleteSourceGroupDialog = true;
  }

  async addSourceGroup(): Promise<void> {
    const groupName = this.newSourceGroupInput.trim();
    if (!groupName || this.isBatchOperating) {
      return;
    }
    if (this.getSourceGroups().includes(groupName)) {
      promptAction.showToast({ message: '分组名称已存在' });
      return;
    }
    this.isBatchOperating = true;
    try {
      this.sourceGroups = await BookSourceGroupStore.add(getContext(this), groupName, this.sourceGroups);
      this.activeSourceGroup = groupName;
      this.applySourceFilters();
      this.closeAddSourceGroupDialog();
      promptAction.showToast({ message: '书源分组已新增' });
    } catch (e) {
      console.error('新增书源分组失败:', e);
      promptAction.showToast({ message: '新增分组失败' });
    } finally {
      this.isBatchOperating = false;
    }
  }

  async deleteSelectedSourceGroups(): Promise<void> {
    const groupsToDelete = this.selectedManagedSourceGroups.filter((group: string) =>
      this.getSourceGroups().includes(group));
    if (groupsToDelete.length === 0 || this.isBatchOperating) return;
    this.isBatchOperating = true;
    this.batchOperationText = '正在删除书源分组...';
    try {
      const db = AppDatabase.getInstance();
      for (const source of this.allSources) {
        if (groupsToDelete.includes((source.bookSourceGroup || '').trim())) {
          source.bookSourceGroup = '';
          await db.updateBookSourceGroupMembership(source.bookSourceUrl, '');
        }
      }
      let groups = this.sourceGroups;
      for (const group of groupsToDelete) {
        groups = await BookSourceGroupStore.remove(getContext(this), group, groups);
      }
      this.sourceGroups = groups;
      if (groupsToDelete.includes(this.activeSourceGroup)) {
        this.activeSourceGroup = '__ungrouped__';
      }
      this.selectedManagedSourceGroups = [];
      this.showDeleteSelectedSourceGroupsDialog = false;
      await this.loadSources();
      promptAction.showToast({ message: `已删除 ${groupsToDelete.length} 个分组` });
    } catch (e) {
      console.error('批量删除书源分组失败:', e);
      promptAction.showToast({ message: '删除分组失败' });
    } finally {
      this.isBatchOperating = false;
    }
  }

  async reconcileSourceGroups(): Promise<void> {
    try {
      this.sourceGroups = await BookSourceGroupStore.load(getContext(this), this.sourceGroupsFromSources());
      this.ensureActiveSourceGroup();
      this.applySourceFilters();
    } catch (e) {
      console.warn('清理空书源分组失败:', e);
    }
  }

  async clearEmptySourceGroups(): Promise<void> {
    if (this.isBatchOperating) {
      return;
    }
    const occupiedGroups = this.sourceGroupsFromSources();
    const emptyGroups = this.getSourceGroups().filter((group: string) => !occupiedGroups.includes(group));
    if (emptyGroups.length === 0) {
      promptAction.showToast({ message: '没有空分组' });
      return;
    }
    this.isBatchOperating = true;
    this.batchOperationText = '正在清除空分组...';
    try {
      let groups = this.sourceGroups;
      for (const group of emptyGroups) {
        groups = await BookSourceGroupStore.remove(getContext(this), group, groups);
      }
      this.sourceGroups = groups;
      this.ensureActiveSourceGroup();
      this.applySourceFilters();
      promptAction.showToast({ message: `已清除 ${emptyGroups.length} 个空分组` });
    } catch (e) {
      console.error('清除空书源分组失败:', e);
      promptAction.showToast({ message: '清除空分组失败' });
    } finally {
      this.isBatchOperating = false;
    }
  }

  async renameSourceGroup(): Promise<void> {
    const oldName = this.pendingSourceGroup;
    const newName = this.renameSourceGroupInput.trim();
    if (!oldName || !newName || this.isBatchOperating) {
      return;
    }
    if (oldName === newName) {
      this.closeRenameSourceGroupDialog();
      return;
    }
    if (this.getSourceGroups().includes(newName)) {
      promptAction.showToast({ message: '分组名称已存在' });
      return;
    }

    this.isBatchOperating = true;
    this.batchOperationText = '正在重命名书源分组...';
    try {
      const db = AppDatabase.getInstance();
      const groupedSources = this.allSources.filter((source: BookSource) =>
        (source.bookSourceGroup || '').trim() === oldName);
      for (const source of groupedSources) {
        source.bookSourceGroup = newName;
        await db.updateBookSourceGroupMembership(source.bookSourceUrl, newName);
      }
      this.sourceGroups = await BookSourceGroupStore.rename(
        getContext(this), oldName, newName, this.sourceGroups);
      this.selectedManagedSourceGroups = this.selectedManagedSourceGroups.map((group: string) =>
        group === oldName ? newName : group);
      if (this.activeSourceGroup === oldName) {
        this.activeSourceGroup = newName;
      }
      this.showRenameSourceGroupDialog = false;
      this.renameSourceGroupInput = '';
      this.pendingSourceGroup = '';
      await this.loadSources();
      promptAction.showToast({ message: '书源分组已重命名' });
    } catch (e) {
      console.error('重命名书源分组失败:', e);
      promptAction.showToast({ message: '重命名失败' });
    } finally {
      this.isBatchOperating = false;
    }
  }

  async deleteSourceGroup(): Promise<void> {
    const groupName = this.pendingSourceGroup;
    if (!groupName || this.isBatchOperating) {
      return;
    }
    this.isBatchOperating = true;
    this.batchOperationText = '正在删除书源分组...';
    try {
      const db = AppDatabase.getInstance();
      const groupedSources = this.allSources.filter((source: BookSource) =>
        (source.bookSourceGroup || '').trim() === groupName);
      for (const source of groupedSources) {
        source.bookSourceGroup = '';
        await db.updateBookSourceGroupMembership(source.bookSourceUrl, '');
      }
      this.sourceGroups = await BookSourceGroupStore.remove(getContext(this), groupName, this.sourceGroups);
      this.selectedManagedSourceGroups = this.selectedManagedSourceGroups.filter((group: string) =>
        group !== groupName);
      if (this.activeSourceGroup === groupName) {
        this.activeSourceGroup = '__ungrouped__';
      }
      this.showDeleteSourceGroupDialog = false;
      this.pendingSourceGroup = '';
      await this.loadSources();
      promptAction.showToast({ message: '分组已删除，书源已移到未分组' });
    } catch (e) {
      console.error('删除书源分组失败:', e);
      promptAction.showToast({ message: '删除分组失败' });
    } finally {
      this.isBatchOperating = false;
    }
  }

  draggingSourceName(): string {
    const source = this.allSources.find((item: BookSource) => item.bookSourceUrl === this.draggingSourceUrl);
    return source ? (source.bookSourceName || '未命名书源') : '';
  }

  async moveVisibleSourceTo(from: number, to: number): Promise<void> {
    if (this.isBatchOperating || from < 0 || from >= this.visibleSources.length || this.sources.length < 2) {
      return;
    }
    const draggedUrl = this.draggingSourceUrl || this.visibleSources[from].bookSourceUrl;
    const sourceIndex = this.sources.findIndex((source: BookSource) => source.bookSourceUrl === draggedUrl);
    if (sourceIndex < 0) return;
    const targetIndex = Math.max(0, Math.min(to, this.sources.length - 1));
    if (sourceIndex === targetIndex) return;

    const reordered = this.sources.slice();
    const moved = reordered.splice(sourceIndex, 1)[0];
    reordered.splice(targetIndex, 0, moved);

    const filteredUrls = this.sources.map((source: BookSource) => source.bookSourceUrl);
    const nextAllSources = this.allSources.slice();
    let orderedIndex = 0;
    for (let index = 0; index < nextAllSources.length; index++) {
      if (filteredUrls.includes(nextAllSources[index].bookSourceUrl)) {
        nextAllSources[index] = reordered[orderedIndex++];
      }
    }
    await this.applyAndPersistSourceOrder(nextAllSources, '排序已保存');
  }

  async applyAndPersistSourceOrder(nextSources: BookSource[], successMessage: string = ''): Promise<void> {
    if (this.isBatchOperating || nextSources.length === 0) return;
    const orderedSources = nextSources.filter((source: BookSource) => source.isPinned)
      .concat(nextSources.filter((source: BookSource) => !source.isPinned));
    const restoreFirstIndex = this.sourceFirstVisibleIndex;
    const restoreVisibleCount = this.sourceVisibleItemCount;
    const restoreLoadedCount = this.visibleSources.length;
    this.isBatchOperating = true;
    this.batchOperationText = '正在保存书源排序...';
    try {
      for (let index = 0; index < orderedSources.length; index++) {
        orderedSources[index].customOrder = index;
      }
      await AppDatabase.getInstance().updateBookSourceOrders(
        orderedSources.map((source: BookSource) => source.bookSourceUrl));
      this.allSources = orderedSources;
      this.applySourceFilters();
      this.restoreSourceListViewport(restoreFirstIndex, restoreVisibleCount, restoreLoadedCount);
      const revision = AppStorage.get<number>('bookSourceOrderRevision') || 0;
      AppStorage.setOrCreate('bookSourceOrderRevision', revision + 1);
      if (successMessage) promptAction.showToast({ message: successMessage });
    } catch (e) {
      console.error('保存书源排序失败:', e);
      promptAction.showToast({ message: '保存排序失败' });
      await this.loadSources();
    } finally {
      this.isBatchOperating = false;
    }
  }

  restoreSourceListViewport(firstIndex: number, visibleCount: number, loadedCount: number): void {
    if (this.sources.length === 0) return;
    const targetIndex = Math.max(0, Math.min(firstIndex, this.sources.length - 1));
    const requiredCount = Math.max(BOOK_SOURCE_LIST_BATCH_SIZE,
      Math.max(loadedCount, targetIndex + Math.max(1, visibleCount)));
    this.visibleSources = this.sources.slice(0, Math.min(this.sources.length, requiredCount));
    this.sourceFirstVisibleIndex = targetIndex;
    this.sourceVisibleItemCount = Math.max(1, visibleCount);
    setTimeout(() => {
      if (targetIndex < this.visibleSources.length) {
        this.sourceListScroller.scrollToIndex(targetIndex, false, ScrollAlign.START);
      }
    }, 0);
  }

  reapplySourceFiltersPreservingViewport(): void {
    const restoreFirstIndex = this.sourceFirstVisibleIndex;
    const restoreVisibleCount = this.sourceVisibleItemCount;
    const restoreLoadedCount = this.visibleSources.length;
    this.applySourceFilters();
    this.restoreSourceListViewport(restoreFirstIndex, restoreVisibleCount, restoreLoadedCount);
  }

  sourceFilterValue(filterKey: string): string {
    switch (filterKey) {
      case 'enabled': return this.sourceEnabledFilter;
      case 'explorePage': return this.sourceExplorePageFilter;
      case 'exploreEnabled': return this.sourceExploreEnabledFilter;
      case 'login': return this.sourceLoginFilter;
      case 'validation': return this.sourceValidationFilter;
      default: return 'all';
    }
  }

  setSourceFilterValue(filterKey: string, value: string): void {
    if (filterKey === 'validation') {
      const allowed = ['unchecked', 'passed', 'failed', 'noResults', 'needsVerification', 'temporaryError'];
      this.sourceValidationFilter = allowed.includes(value) ? value : 'all';
      this.applySourceFilters();
      return;
    }
    const normalized = value === 'yes' || value === 'no' ? value : 'all';
    switch (filterKey) {
      case 'enabled': this.sourceEnabledFilter = normalized; break;
      case 'explorePage': this.sourceExplorePageFilter = normalized; break;
      case 'exploreEnabled': this.sourceExploreEnabledFilter = normalized; break;
      case 'login': this.sourceLoginFilter = normalized; break;
      default: return;
    }
    this.applySourceFilters();
  }

  resetSourceFilters(): void {
    this.sourceSortMode = 'custom';
    this.sourceEnabledFilter = 'all';
    this.sourceExplorePageFilter = 'all';
    this.sourceExploreEnabledFilter = 'all';
    this.sourceLoginFilter = 'all';
    this.sourceValidationFilter = 'all';
    this.applySourceFilters();
  }

  activeSourceFilterCount(): number {
    let count = 0;
    if (this.sourceSortMode !== 'custom') count++;
    if (this.sourceEnabledFilter !== 'all') count++;
    if (this.sourceExplorePageFilter !== 'all') count++;
    if (this.sourceExploreEnabledFilter !== 'all') count++;
    if (this.sourceLoginFilter !== 'all') count++;
    if (this.sourceValidationFilter !== 'all') count++;
    return count;
  }

  hasActiveSourceFilters(): boolean {
    return this.activeSourceFilterCount() > 0;
  }

  sourceHasExplorePage(source: BookSource): boolean {
    return !!String(source.exploreUrl || '').trim();
  }

  isSourceAtBottom(source: BookSource): boolean {
    return this.allSources.length > 1 &&
      this.allSources[this.allSources.length - 1].bookSourceUrl === source.bookSourceUrl;
  }

  applySourceFilters(): void {
    const keyword = this.searchText.trim().toLowerCase();
    let filtered: BookSource[] = this.allSources;
    if (this.activeSourceGroup === '__ungrouped__') {
      filtered = filtered.filter((source: BookSource) => !(source.bookSourceGroup || '').trim());
    } else if (this.activeSourceGroup !== '__all__') {
      filtered = filtered.filter((source: BookSource) =>
        (source.bookSourceGroup || '').trim() === this.activeSourceGroup);
    }
    if (this.sourceEnabledFilter !== 'all') {
      const expected = this.sourceEnabledFilter === 'yes';
      filtered = filtered.filter((source: BookSource) => source.enabled === expected);
    }
    if (this.sourceExplorePageFilter !== 'all') {
      const expected = this.sourceExplorePageFilter === 'yes';
      filtered = filtered.filter((source: BookSource) => this.sourceHasExplorePage(source) === expected);
    }
    if (this.sourceExploreEnabledFilter !== 'all') {
      const expected = this.sourceExploreEnabledFilter === 'yes';
      filtered = filtered.filter((source: BookSource) => source.enabledExplore === expected);
    }
    if (this.sourceLoginFilter !== 'all') {
      const expected = this.sourceLoginFilter === 'yes';
      filtered = filtered.filter((source: BookSource) => this.sourceNeedsLogin(source) === expected);
    }
    if (this.sourceValidationFilter !== 'all') {
      const expected = this.sourceValidationStatusForFilter(this.sourceValidationFilter);
      filtered = filtered.filter((source: BookSource) => source.validationStatus === expected);
    }
    if (keyword) {
      filtered = filtered.filter((source: BookSource) => {
        const searchable = `${source.bookSourceName || ''}\n${source.bookSourceUrl || ''}\n${source.bookSourceGroup || ''}`;
        return searchable.toLowerCase().includes(keyword);
      });
    }
    this.sources = this.sortFilteredSources(filtered);
    this.visibleSources = this.sources.slice(0, BOOK_SOURCE_LIST_BATCH_SIZE);
    this.sourceFirstVisibleIndex = 0;
    this.sourceVisibleItemCount = 1;
    this.pruneSelectedSources();
  }

  sortFilteredSources(filtered: BookSource[]): BookSource[] {
    if (this.sourceSortMode === 'custom') return filtered.slice();
    const bottomUrl = this.allSources.length > 0 ?
      this.allSources[this.allSources.length - 1].bookSourceUrl : '';
    return filtered.slice().sort((left: BookSource, right: BookSource): number => {
      if (left.isPinned !== right.isPinned) return left.isPinned ? -1 : 1;
      if (!left.isPinned && left.bookSourceUrl === bottomUrl) return 1;
      if (!right.isPinned && right.bookSourceUrl === bottomUrl) return -1;
      if (this.sourceSortMode === 'name') {
        return (left.bookSourceName || '').localeCompare(right.bookSourceName || '');
      }
      const timeDiff = (left.lastUpdateTime || 0) - (right.lastUpdateTime || 0);
      if (timeDiff !== 0) return this.sourceSortMode === 'oldest' ? timeDiff : -timeDiff;
      return left.customOrder - right.customOrder;
    });
  }

  sourceValidationStatusForFilter(value: string): number {
    if (value === 'passed') return BookSource.VALIDATION_PASSED;
    if (value === 'failed') return BookSource.VALIDATION_FAILED;
    if (value === 'noResults') return BookSource.VALIDATION_NO_RESULTS;
    if (value === 'needsVerification') return BookSource.VALIDATION_NEEDS_VERIFICATION;
    if (value === 'temporaryError') return BookSource.VALIDATION_TEMPORARY_ERROR;
    return BookSource.VALIDATION_UNCHECKED;
  }

  loadMoreVisibleSources(): void {
    if (this.visibleSources.length >= this.sources.length) {
      return;
    }
    const nextCount = Math.min(this.sources.length, this.visibleSources.length + BOOK_SOURCE_LIST_BATCH_SIZE);
    this.visibleSources = this.sources.slice(0, nextCount);
  }

  ensureActiveSourceGroup(): void {
    if (this.activeSourceGroup === '__all__') {
      return;
    }
    if (this.activeSourceGroup === '__ungrouped__') {
      return;
    }
    if (!this.getSourceGroups().includes(this.activeSourceGroup)) {
      this.activeSourceGroup = '__all__';
    }
  }

  hasUngroupedSources(): boolean {
    return this.allSources.some((source: BookSource) => !(source.bookSourceGroup || '').trim());
  }

  emptySourceTitle(): string {
    if (this.searchText.trim()) {
      return '未找到匹配书源';
    }
    if (this.hasActiveSourceFilters()) {
      return '筛选条件下暂无书源';
    }
    if (this.activeSourceGroup !== '__all__') {
      return '当前分组暂无书源';
    }
    return '暂无书源';
  }

  emptySourceDescription(): string {
    if (this.searchText.trim()) {
      return '请尝试其他关键词';
    }
    if (this.hasActiveSourceFilters()) {
      return '请调整或重置筛选条件';
    }
    if (this.activeSourceGroup !== '__all__') {
      return '可切换其他分组查看';
    }
    return '点击右上角"+"添加书源';
  }

  sourceNeedsLogin(source: BookSource): boolean {
    const loginUrl = String(source.loginUrl || '').trim();
    const loginUi = String(source.loginUi || '').trim();
    const loginCheckJs = String(source.loginCheckJs || '').trim();
    const loginHeader = String(source.loginHeader || '').trim();
    if (loginUrl || loginUi || loginCheckJs || loginHeader) {
      return true;
    }
    const rules = `${source.jsLib || ''}\n${source.searchUrl || ''}\n${source.exploreUrl || ''}\n` +
      `${source.bookInfoRule?.init || ''}\n${source.tocRule?.chapterList || ''}\n${source.contentRule?.content || ''}`;
    return /loginCheck|loginUrl|loginUi|book-source-login|请先登[录陆]|需要登[录陆]|账号登[录陆]|网页登录|登[录陆]后/i.test(rules);
  }

  sourceLoggedIn(source: BookSource): boolean {
    if (!this.sourceNeedsLogin(source)) {
      return false;
    }
    if (String(source.loginHeader || '').trim()) {
      return true;
    }
    const loginUrl = VerificationSupport.resolveBookSourceLoginUrl(source);
    const urls = [
      String(source.loginUrl || '').trim(),
      loginUrl,
      this.sourceUrlOrigin(loginUrl),
      String(source.bookSourceUrl || '').trim(),
      this.sourceUrlOrigin(String(source.bookSourceUrl || '').trim())
    ];
    for (const url of urls) {
      if (url && this.hasLoginCookie(CookieStore.getCookie(url))) {
        return true;
      }
    }
    return false;
  }

  hasLoginCookie(cookie: string): boolean {
    return VerificationSupport.hasEffectiveLoginCookie(cookie);
  }

  sourceUrlOrigin(url: string): string {
    const match = (url || '').match(/^(https?:\/\/[^/]+)/i);
    return match && match[1] ? match[1] : '';
  }

  async openSourceActions(source: BookSource, event?: GestureEvent): Promise<void> {
    const finger = event && event.fingerList.length > 0 ? event.fingerList[0] : undefined;
    if (finger) {
      this.contextMenuX = finger.globalX;
      this.contextMenuY = finger.globalY;
    }
    this.actionSourceUrl = source.bookSourceUrl;
    this.actionSourceDetail = null;
    this.showSourceDeleteDialog = false;
    this.showSourceActionDialog = true;
    const detail = await AppDatabase.getInstance().getBookSource(source.bookSourceUrl);
    if (this.actionSourceUrl === source.bookSourceUrl) {
      this.actionSourceDetail = detail;
    }
  }

  updateContextViewport(area: Area): void {
    const width = Number(area.width);
    const height = Number(area.height);
    if (Number.isFinite(width) && width > 0) this.contextViewportWidth = width;
    if (Number.isFinite(height) && height > 0) this.contextViewportHeight = height;
  }

  contextMenuLeft(menuWidth: number): number {
    return Math.max(12, Math.min(this.contextMenuX - 18, this.contextViewportWidth - menuWidth - 12));
  }

  contextMenuTop(menuHeight: number): number {
    const below = this.contextMenuY + 12;
    if (below + menuHeight <= this.contextViewportHeight - 12) return below;
    return Math.max(this.statusBarHeight + 8, this.contextMenuY - menuHeight - 12);
  }

  closeSourceActions(): void {
    this.showSourceActionDialog = false;
    this.actionSourceUrl = '';
    this.actionSourceDetail = null;
  }

  enterActionSourceSelection(): void {
    const sourceUrl = this.actionSourceUrl;
    if (!sourceUrl) {
      return;
    }
    this.showSourceActionDialog = false;
    this.actionSourceUrl = '';
    this.actionSourceDetail = null;
    this.showAddDialog = false;
    this.showMoreActionDialog = false;
    this.selectionMode = true;
    this.selectedSourceUrls = [sourceUrl];
  }

  actionSource(): BookSource | null {
    if (this.actionSourceDetail && this.actionSourceDetail.bookSourceUrl === this.actionSourceUrl) {
      return this.actionSourceDetail;
    }
    return this.sources.find((source: BookSource) => source.bookSourceUrl === this.actionSourceUrl) || null;
  }

  actionSourceName(): string {
    const source = this.actionSource();
    return source ? (source.bookSourceName || source.bookSourceUrl) : '当前书源';
  }

  actionSourceNeedsLogin(): boolean {
    const source = this.actionSource();
    return source ? this.sourceNeedsLogin(source) : false;
  }

  actionSourceLoggedIn(): boolean {
    const source = this.actionSource();
    return source ? this.sourceLoggedIn(source) : false;
  }

  actionSourceEnabled(): boolean {
    const source = this.actionSource();
    return source ? source.enabled : false;
  }

  actionSourceLocked(): boolean {
    const source = this.actionSource();
    return source ? source.isLocked : false;
  }

  actionSourcePinned(): boolean {
    const source = this.actionSource();
    return source ? source.isPinned : false;
  }

  sourceActionMenuHeight(): number {
    if (this.actionSourceLocked()) {
      return this.actionSourceNeedsLogin() ? 320 : 276;
    }
    return this.actionSourceNeedsLogin() ? 496 : 452;
  }

  async toggleActionSourcePinned(): Promise<void> {
    const source = this.actionSource();
    if (!source || this.isBatchOperating) return;
    const sourceUrl = source.bookSourceUrl;
    const pinned = !source.isPinned;
    this.closeSourceActions();
    const currentIndex = this.allSources.findIndex((item: BookSource) => item.bookSourceUrl === sourceUrl);
    if (currentIndex < 0) return;
    const next = this.allSources.slice();
    const moved = next.splice(currentIndex, 1)[0];
    moved.isPinned = pinned;
    await AppDatabase.getInstance().setBookSourcePinned(sourceUrl, pinned);
    if (pinned) {
      next.unshift(moved);
    } else {
      const pinnedCount = next.filter((item: BookSource) => item.isPinned).length;
      next.splice(pinnedCount, 0, moved);
    }
    await this.applyAndPersistSourceOrder(next, pinned ? '书源已置顶' : '已取消置顶');
  }

  async moveActionSourceToBottom(): Promise<void> {
    const source = this.actionSource();
    if (!source || this.isBatchOperating) return;
    const sourceUrl = source.bookSourceUrl;
    this.closeSourceActions();
    const currentIndex = this.allSources.findIndex((item: BookSource) => item.bookSourceUrl === sourceUrl);
    if (currentIndex < 0) return;
    const next = this.allSources.slice();
    const moved = next.splice(currentIndex, 1)[0];
    moved.isPinned = false;
    await AppDatabase.getInstance().setBookSourcePinned(sourceUrl, false);
    next.push(moved);
    await this.applyAndPersistSourceOrder(next, '书源已置底');
  }

  openActionSourceGroup(): void {
    const source = this.actionSource();
    if (!source) return;
    if (source.isLocked) {
      this.closeSourceActions();
      promptAction.showToast({ message: '请先解锁书源' });
      return;
    }
    const sourceUrl = source.bookSourceUrl;
    const groupName = source.bookSourceGroup || '';
    this.closeSourceActions();
    this.groupActionSourceUrl = sourceUrl;
    this.groupNameInput = groupName;
    this.showGroupDialog = true;
  }

  async toggleActionSourceLocked(): Promise<void> {
    const source = this.actionSource();
    if (!source || this.isBatchOperating) return;
    const locked = !source.isLocked;
    await AppDatabase.getInstance().setBookSourceLocked(source.bookSourceUrl, locked);
    source.isLocked = locked;
    this.closeSourceActions();
    await this.loadSources();
    promptAction.showToast({ message: locked ? '书源已锁定' : '书源已解锁' });
  }

  openActionSourceSearch(): void {
    const source = this.actionSource();
    if (!source) {
      this.closeSourceActions();
      promptAction.showToast({ message: '书源不存在' });
      return;
    }
    const nonce = AppStorage.get<number>('singleSourceSearchNonce') || 0;
    AppStorage.setOrCreate('singleSourceSearchUrl', source.bookSourceUrl);
    AppStorage.setOrCreate('singleSourceSearchName', source.bookSourceName || source.bookSourceUrl);
    AppStorage.setOrCreate('singleSourceSearchNonce', nonce + 1);
    this.closeSourceActions();
    router.back();
  }

  async openActionSourceLogin(): Promise<void> {
    const summary = this.actionSource();
    if (!summary) {
      return;
    }
    const source = await AppDatabase.getInstance().getBookSource(summary.bookSourceUrl);
    if (!source || !this.sourceNeedsLogin(source)) {
      promptAction.showToast({ message: '书源不存在' });
      return;
    }
    this.showSourceActionDialog = false;
    const loginItems = BookSourceScriptRunner.loginItems(source);
    if (loginItems.some((item: BookSourceLoginItem): boolean => !!item.action)) {
      const loginInfo = BookSourceLoginWebRuntime.parseRecord(source.loginInfo);
      for (const item of loginItems) {
        if (this.isSourceLoginInput(item) && loginInfo[item.name] !== undefined) {
          item.value = loginInfo[item.name];
        }
      }
      this.actionSourceDetail = source;
      this.sourceLoginItems = loginItems;
      this.showSourceLoginUiDialog = true;
      return;
    }
    const loginEntryUrl = VerificationSupport.resolveBookSourceLoginUrl(source) ||
      VerificationSupport.pickVerificationUrl(source, source.bookSourceUrl);
    if (!loginEntryUrl || !/^https?:\/\//i.test(loginEntryUrl)) {
      this.actionSourceUrl = '';
      promptAction.showToast({ message: '未找到可用的网页登录地址，请检查书源登录配置' });
      return;
    }
    this.openSourceLoginBrowser(source, loginEntryUrl, `${source.bookSourceName || '书源'} 登录`, true);
  }

  async executeSourceLoginAction(item: BookSourceLoginItem): Promise<void> {
    const source = this.actionSourceDetail;
    if (!source || !item.action || this.isExecutingLoginAction) return;
    this.isExecutingLoginAction = true;
    this.syncSourceLoginInfo(source);
    try {
      const result = await this.runSourceLoginAction(source, item.action);
      source.variable = result.variable;
      source.loginHeader = result.loginHeader;
      source.loginInfo = result.loginInfo;
      await AppDatabase.getInstance().updateBookSourceLoginRuntime(source.bookSourceUrl,
        source.variable, source.loginHeader, source.loginInfo);
      this.markSourceLoginCompleted(item, result);
      if (result.toastMessage) {
        promptAction.showToast({ message: result.toastMessage.trim() || '操作成功' });
      } else if (result.errorMessage) {
        promptAction.showToast({ message: `登录动作失败：${result.errorMessage}` });
      }
      if (result.requestedUrl) {
        this.showSourceLoginUiDialog = false;
        this.sourceLoginItems = [];
        const isLogin = /(?:登录|login)/i.test(item.name) ||
          /\/login(?:\.html)?(?:[?#]|$)/i.test(result.requestedUrl);
        this.openSourceLoginBrowser(source, result.requestedUrl,
          result.requestedTitle || `${source.bookSourceName || '书源'} · ${item.name}`, isLogin);
        return;
      }
      this.actionSourceDetail = source;
    } catch (error) {
      promptAction.showToast({ message: `登录动作失败：${this.importErrorMessage(error as Object)}` });
    } finally {
      this.isExecutingLoginAction = false;
    }
  }

  isSourceLoginInput(item: BookSourceLoginItem): boolean {
    const type = (item.type || '').toLowerCase();
    return type === 'text' || type === 'password' || type === 'email' || type === 'number';
  }

  markSourceLoginCompleted(item: BookSourceLoginItem, result: LoginRuntimeStep): void {
    if (!/(?:登录|login)/i.test(`${item.name}\n${item.action}`)) return;
    const message = result.toastMessage || '';
    if (result.errorMessage || /(?:失败|错误|未登录|请先|请输入)/.test(message)) return;
    const operations = BookSourceLoginWebRuntime.parseCookieOperations(result.cookieOperations);
    const hasLoginCookie = operations.some((operation: LoginCookieOperation): boolean =>
      operation.operation === 'set' && operation.value.includes('='));
    if (!(result.loginHeader || '').trim() && !hasLoginCookie && !/(?:成功|欢迎回来|已登录)/.test(message)) return;
    AppStorage.setOrCreate('pendingVerificationUrl', '');
    AppStorage.setOrCreate('pendingVerificationTitle', '');
    AppStorage.setOrCreate('verificationCompletedAt', Date.now());
  }

  updateSourceLoginInput(index: number, value: string): void {
    if (index < 0 || index >= this.sourceLoginItems.length) return;
    const items = this.sourceLoginItems.slice();
    const copy = new BookSourceLoginItem();
    copy.name = items[index].name;
    copy.type = items[index].type;
    copy.action = items[index].action;
    copy.value = items[index].value;
    copy.placeholder = items[index].placeholder;
    copy.value = value;
    items[index] = copy;
    this.sourceLoginItems = items;
  }

  syncSourceLoginInfo(source: BookSource): void {
    const values = BookSourceLoginWebRuntime.parseRecord(source.loginInfo);
    for (const item of this.sourceLoginItems) {
      if (this.isSourceLoginInput(item) && item.name) values[item.name] = item.value || '';
    }
    source.loginInfo = BookSourceLoginWebRuntime.mergeRecord(source.loginInfo, values);
  }

  saveSourceLoginInputs(): void {
    const source = this.actionSourceDetail;
    if (!source) return;
    this.syncSourceLoginInfo(source);
    AppDatabase.getInstance().updateBookSourceLoginRuntime(source.bookSourceUrl,
      source.variable, source.loginHeader, source.loginInfo).catch((error: Object): void => {
      console.warn('保存书源登录输入失败:', error);
    });
  }

  runSourceLoginAction(source: BookSource, action: string): Promise<LoginRuntimeStep> {
    if (this.loginRuntimeResolve || this.loginRuntimeReject) {
      return Promise.reject(new Error('已有登录动作正在执行'));
    }
    this.loginRuntimeSource = source;
    this.loginRuntimeAction = action;
    this.loginRuntimeResponses = {};
    this.loginRuntimeCookies = {};
    this.loginRuntimeCookieUrls = [];
    this.loginRuntimeRequestCount = 0;
    this.loginRuntimeStepRunning = false;
    return new Promise<LoginRuntimeStep>((resolve, reject) => {
      this.loginRuntimeResolve = resolve;
      this.loginRuntimeReject = reject;
      this.loginRuntimeTimeoutId = setTimeout(() => {
        const message = this.loginRuntimeReady ? '登录脚本执行超时' : '登录脚本运行环境未就绪';
        this.finishLoginRuntime(null, message);
      }, 60000);
      this.loginRuntimeActive = true;
      if (this.loginRuntimeReady) this.continueLoginRuntime();
    });
  }

  continueLoginRuntime(): void {
    if (!this.loginRuntimeActive || this.loginRuntimeStepRunning || !this.loginRuntimeSource) return;
    this.loginRuntimeStepRunning = true;
    this.executeLoginRuntimeStep().catch((error: Object): void => {
      this.finishLoginRuntime(null, this.importErrorMessage(error));
    });
  }

  async executeLoginRuntimeStep(): Promise<void> {
    const source = this.loginRuntimeSource;
    if (!source || !this.loginRuntimeActive) return;
    const script = BookSourceLoginWebRuntime.buildScript(source, this.loginRuntimeAction,
      this.loginRuntimeResponses, this.loginRuntimeCookies);
    const raw = await this.runLoginRuntimeScript(script);
    const step = BookSourceLoginWebRuntime.parseResult(raw);
    source.variable = step.variable;
    source.loginHeader = step.loginHeader;
    source.loginInfo = step.loginInfo;
    this.applyLoginCookieOperations(step.cookieOperations);
    if (step.pendingCookie) {
      this.loginRuntimeCookies[step.pendingCookie] = CookieStore.getCookie(step.pendingCookie);
      if (!this.loginRuntimeCookieUrls.includes(step.pendingCookie)) {
        this.loginRuntimeCookieUrls.push(step.pendingCookie);
      }
      this.loginRuntimeStepRunning = false;
      this.continueLoginRuntime();
      return;
    }
    if (step.pendingAjax) {
      this.loginRuntimeRequestCount++;
      if (this.loginRuntimeRequestCount > 12) {
        this.finishLoginRuntime(null, '登录脚本网络请求次数过多');
        return;
      }
      const response = await this.fetchLoginRuntimeRequest(source, step.pendingAjax);
      if (!response.success && !response.body) {
        this.finishLoginRuntime(null, response.error || `HTTP ${response.statusCode}`);
        return;
      }
      this.loginRuntimeResponses[step.pendingAjax] = response.body || '';
      for (const key of this.loginRuntimeCookieUrls) {
        this.loginRuntimeCookies[key] = CookieStore.getCookie(key);
      }
      this.loginRuntimeStepRunning = false;
      this.continueLoginRuntime();
      return;
    }
    this.finishLoginRuntime(step);
  }

  runLoginRuntimeScript(script: string): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      let completed = false;
      const timeoutId = setTimeout(() => {
        if (completed) return;
        completed = true;
        this.loginRuntimeReady = false;
        try {
          this.loginRuntimeController.loadUrl('about:blank');
        } catch (_) {}
        reject(new Error('登录脚本引擎响应超时'));
      }, 15000);
      this.loginRuntimeController.runJavaScript(script)
        .then((result: string): void => {
          if (completed) return;
          completed = true;
          clearTimeout(timeoutId);
          resolve(result);
        })
        .catch((error: Object): void => {
          if (completed) return;
          completed = true;
          clearTimeout(timeoutId);
          reject(error);
        });
    });
  }

  fetchLoginRuntimeRequest(source: BookSource, requestUrl: string): Promise<HttpResponse> {
    const client = new HttpClient(15000);
    return new Promise<HttpResponse>((resolve) => {
      let completed = false;
      const timeoutId = setTimeout(() => {
        if (completed) return;
        completed = true;
        client.cancelAll();
        resolve({
          url: requestUrl,
          statusCode: 0,
          headers: {},
          body: '',
          success: false,
          error: '登录请求超时，请检查网络或切换书源线路'
        });
      }, 20000);
      new AnalyzeUrl(source, client).fetch(requestUrl)
        .then((response: HttpResponse): void => {
          if (completed) return;
          completed = true;
          clearTimeout(timeoutId);
          if ((response.body || '').length > 8 * 1024 * 1024) {
            resolve({
              url: response.url,
              statusCode: response.statusCode,
              headers: response.headers,
              body: '',
              success: false,
              error: '登录响应过大'
            });
            return;
          }
          resolve(response);
        })
        .catch((error: Object): void => {
          if (completed) return;
          completed = true;
          clearTimeout(timeoutId);
          resolve({
            url: requestUrl,
            statusCode: 0,
            headers: {},
            body: '',
            success: false,
            error: this.importErrorMessage(error)
          });
        });
    });
  }

  applyLoginCookieOperations(raw: string): void {
    const operations: LoginCookieOperation[] = BookSourceLoginWebRuntime.parseCookieOperations(raw);
    for (const operation of operations) {
      if (operation.operation === 'set') {
        CookieStore.setCookies(operation.url, operation.value);
      } else if (operation.operation === 'remove') {
        CookieStore.removeCookie(operation.url, operation.name || undefined);
      }
      this.loginRuntimeCookies[operation.url] = CookieStore.getCookie(operation.url);
      if (!this.loginRuntimeCookieUrls.includes(operation.url)) {
        this.loginRuntimeCookieUrls.push(operation.url);
      }
    }
    if (operations.length > 0) CookieStore.saveAsync();
  }

  finishLoginRuntime(result: LoginRuntimeStep | null, errorMessage: string = ''): void {
    if (!this.loginRuntimeResolve && !this.loginRuntimeReject) return;
    if (this.loginRuntimeTimeoutId >= 0) clearTimeout(this.loginRuntimeTimeoutId);
    const resolve = this.loginRuntimeResolve;
    const reject = this.loginRuntimeReject;
    this.loginRuntimeResolve = null;
    this.loginRuntimeReject = null;
    this.loginRuntimeTimeoutId = -1;
    this.loginRuntimeSource = null;
    this.loginRuntimeAction = '';
    this.loginRuntimeResponses = {};
    this.loginRuntimeCookies = {};
    this.loginRuntimeCookieUrls = [];
    this.loginRuntimeRequestCount = 0;
    this.loginRuntimeStepRunning = false;
    this.loginRuntimeActive = false;
    if (errorMessage) {
      if (reject) reject(new Error(errorMessage));
    } else if (result && resolve) {
      resolve(result);
    }
  }

  openSourceLoginBrowser(source: BookSource, url: string, title: string, requireLoginCookie: boolean): void {
    VerificationSupport.requestVerification(url, title, source);
    this.actionSourceUrl = '';
    router.pushUrl({
      url: 'pages/VerifyWeb',
      params: {
        url: url,
        title: title,
        requireLoginCookie: requireLoginCookie ? 'true' : 'false'
      }
    });
  }

  openActionSourceEdit(): void {
    const source = this.actionSource();
    if (!source) {
      return;
    }
    if (source.isLocked) {
      this.closeSourceActions();
      promptAction.showToast({ message: '请先解锁书源' });
      return;
    }
    this.closeSourceActions();
    router.pushUrl({
      url: 'pages/BookSourceEdit',
      params: { bookSourceUrl: source.bookSourceUrl }
    });
  }

  async toggleActionSourceEnabled(): Promise<void> {
    const source = this.actionSource();
    if (!source) {
      return;
    }
    this.closeSourceActions();
    await this.toggleSourceEnabled(source);
  }

  async toggleSourceEnabled(source: BookSource): Promise<void> {
    if (this.isBatchOperating) {
      return;
    }
    if (source.isLocked) {
      promptAction.showToast({ message: '锁定的书源不能修改' });
      return;
    }
    const enabled = !source.enabled;
    source.enabled = enabled;
    await this.updateSource(source);
    this.allSources = this.allSources.map((item: BookSource) =>
      item.bookSourceUrl === source.bookSourceUrl ? source : item);
    this.reapplySourceFiltersPreservingViewport();
    promptAction.showToast({ message: enabled ? '书源已启用' : '书源已禁用' });
  }

  async deleteSourceFromSwipe(source: BookSource): Promise<void> {
    if (this.isBatchOperating) {
      return;
    }
    if (source.isLocked) {
      promptAction.showToast({ message: '锁定的书源不能删除' });
      return;
    }
    this.isBatchOperating = true;
    this.batchOperationText = '正在删除书源...';
    try {
      await AppDatabase.getInstance().deleteBookSource(source.bookSourceUrl);
      this.sources = this.sources.filter((item: BookSource) => item.bookSourceUrl !== source.bookSourceUrl);
      this.allSources = this.allSources.filter((item: BookSource) => item.bookSourceUrl !== source.bookSourceUrl);
      this.visibleSources = this.visibleSources.filter((item: BookSource) => item.bookSourceUrl !== source.bookSourceUrl);
      this.selectedSourceUrls = this.selectedSourceUrls.filter((url: string) => url !== source.bookSourceUrl);
      await this.reconcileSourceGroups();
      promptAction.showToast({ message: '书源已删除' });
    } catch (e) {
      console.error('滑动删除书源失败:', e);
      promptAction.showToast({ message: '删除书源失败' });
    } finally {
      this.isBatchOperating = false;
    }
  }

  async deleteActionSource(): Promise<void> {
    const source = this.actionSource();
    if (!source || this.isBatchOperating) {
      return;
    }
    if (source.isLocked) {
      this.showSourceDeleteDialog = false;
      promptAction.showToast({ message: '锁定的书源不能删除' });
      return;
    }
    this.showSourceDeleteDialog = false;
    this.isBatchOperating = true;
    this.batchOperationText = '正在删除书源...';
    try {
      const db = AppDatabase.getInstance();
      await db.deleteBookSource(source.bookSourceUrl);
      this.sources = this.sources.filter((item: BookSource) => item.bookSourceUrl !== source.bookSourceUrl);
      this.allSources = this.allSources.filter((item: BookSource) => item.bookSourceUrl !== source.bookSourceUrl);
      this.visibleSources = this.visibleSources.filter((item: BookSource) => item.bookSourceUrl !== source.bookSourceUrl);
      this.actionSourceUrl = '';
      await this.reconcileSourceGroups();
      promptAction.showToast({ message: '书源已删除' });
    } catch (e) {
      console.error('删除书源失败:', e);
      promptAction.showToast({ message: '删除书源失败' });
    } finally {
      this.isBatchOperating = false;
    }
  }

  enterSelectionMode(): void {
    this.showAddDialog = false;
    this.selectionMode = true;
    this.selectedSourceUrls = [];
  }

  exitSelectionMode(): void {
    this.selectionMode = false;
    this.selectedSourceUrls = [];
    this.showBatchDeleteDialog = false;
    this.showMoreActionDialog = false;
  }

  sourceListItemKey(source: BookSource): string {
    const loginStatus = this.sourceNeedsLogin(source) ? (this.sourceLoggedIn(source) ? 'logged' : 'unlogged') : 'none';
    const positionStatus = `${source.isPinned ? 'pinned' : 'normal'}_${this.isSourceAtBottom(source) ? 'bottom' : 'middle'}`;
    return `${source.bookSourceUrl}_${source.bookSourceGroup || ''}_${source.enabled ? '1' : '0'}_${source.enabledExplore ? '1' : '0'}_${source.isLocked ? 'locked' : 'unlocked'}_${source.validationStatus}_${source.bookSourceName || ''}_${loginStatus}_${positionStatus}_${this.selectionMode ? 'select' : 'normal'}`;
  }

  isSourceSelected(bookSourceUrl: string): boolean {
    return this.selectedSourceUrls.includes(bookSourceUrl);
  }

  setSourceSelected(bookSourceUrl: string, selected: boolean): void {
    if (selected) {
      if (!this.isSourceSelected(bookSourceUrl)) {
        this.selectedSourceUrls = this.selectedSourceUrls.concat([bookSourceUrl]);
      }
      return;
    }
    this.selectedSourceUrls = this.selectedSourceUrls.filter((url: string) => url !== bookSourceUrl);
  }

  toggleSourceSelected(bookSourceUrl: string): void {
    this.setSourceSelected(bookSourceUrl, !this.isSourceSelected(bookSourceUrl));
  }

  isAllSelected(): boolean {
    return this.sources.length > 0 &&
      this.sources.every((source: BookSource) => this.isSourceSelected(source.bookSourceUrl));
  }

  selectAllSources(): void {
    const selected = this.selectedSourceUrls.slice();
    for (const source of this.sources) {
      if (!selected.includes(source.bookSourceUrl)) {
        selected.push(source.bookSourceUrl);
      }
    }
    this.selectedSourceUrls = selected;
  }

  toggleAllSources(): void {
    if (this.isAllSelected()) {
      const filteredUrls = this.sources.map((source: BookSource) => source.bookSourceUrl);
      this.selectedSourceUrls = this.selectedSourceUrls.filter((url: string) => !filteredUrls.includes(url));
      return;
    }
    this.selectAllSources();
  }

  clearSelection(): void {
    this.selectedSourceUrls = [];
  }

  pruneSelectedSources(): void {
    if (this.selectedSourceUrls.length === 0) {
      return;
    }
    const existingUrls = this.allSources.map((source: BookSource) => source.bookSourceUrl);
    this.selectedSourceUrls = this.selectedSourceUrls.filter((url: string) => existingUrls.includes(url));
  }

  getSelectedSources(): BookSource[] {
    return this.allSources.filter((source: BookSource) => this.isSourceSelected(source.bookSourceUrl));
  }

  getSelectedMutableSources(): BookSource[] {
    return this.getSelectedSources().filter((source: BookSource) => !source.isLocked);
  }

  getSourceGroups(): string[] {
    return [...this.sourceGroups].sort((a: string, b: string) => a.localeCompare(b));
  }

  sourceGroupsFromSources(): string[] {
    const groups: string[] = [];
    for (const source of this.allSources) {
      const group = (source.bookSourceGroup || '').trim();
      if (group && !groups.includes(group)) {
        groups.push(group);
      }
    }
    return groups.sort((a: string, b: string) => a.localeCompare(b));
  }

  commonSelectedGroupName(): string {
    const selected = this.getSelectedSources();
    if (selected.length === 0) {
      return '';
    }
    const first = selected[0].bookSourceGroup || '';
    for (const source of selected) {
      if ((source.bookSourceGroup || '') !== first) {
        return '';
      }
    }
    return first;
  }

  groupingSources(): BookSource[] {
    if (this.groupActionSourceUrl) {
      const source = this.allSources.find((item: BookSource) =>
        item.bookSourceUrl === this.groupActionSourceUrl);
      return source ? [source] : [];
    }
    return this.getSelectedSources();
  }

  mutableGroupingSources(): BookSource[] {
    return this.groupingSources().filter((source: BookSource) => !source.isLocked);
  }

  actionGroupingSourceName(): string {
    const source = this.groupingSources()[0];
    return source ? (source.bookSourceName || source.bookSourceUrl) : '当前书源';
  }

  closeSourceGroupDialog(): void {
    this.showGroupDialog = false;
    this.groupActionSourceUrl = '';
  }

  async applySelectedSourceGroup(): Promise<void> {
    if (this.isBatchOperating) {
      return;
    }
    const selectedSources = this.mutableGroupingSources();
    if (selectedSources.length === 0) {
      promptAction.showToast({ message: '所选书源均已锁定' });
      return;
    }

    const groupName = this.groupNameInput.trim();
    const isNewUserGroup = !!groupName && !this.getSourceGroups().includes(groupName);
    this.isBatchOperating = true;
    this.batchOperationText = '正在设置分组...';
    try {
      const db = AppDatabase.getInstance();
      for (const source of selectedSources) {
        source.bookSourceGroup = groupName;
        await db.updateBookSourceListFields(source.bookSourceUrl, { bookSourceGroup: groupName });
      }
      if (groupName) {
        this.sourceGroups = await BookSourceGroupStore.add(
          getContext(this), groupName, this.sourceGroups, isNewUserGroup);
      }
      this.sources = this.sources.map((source: BookSource) => {
        if (this.isSourceSelected(source.bookSourceUrl) && !source.isLocked) {
          source.bookSourceGroup = groupName;
        }
        return source;
      });
      this.ensureActiveSourceGroup();
      this.applySourceFilters();
      this.closeSourceGroupDialog();
      promptAction.showToast({ message: groupName ? `已加入分组：${groupName}` : '已移出分组' });
    } catch (e) {
      console.error('设置书源分组失败:', e);
      promptAction.showToast({ message: '设置分组失败' });
    } finally {
      this.isBatchOperating = false;
    }
  }

  async batchSetEnabled(enabled: boolean): Promise<void> {
    if (this.isBatchOperating) {
      return;
    }
    const selectedSources = this.getSelectedMutableSources();
    if (selectedSources.length === 0) {
      promptAction.showToast({ message: '所选书源均已锁定' });
      return;
    }

    this.isBatchOperating = true;
    this.batchOperationText = enabled ? '正在启用书源...' : '正在禁用书源...';
    try {
      const db = AppDatabase.getInstance();
      for (const source of selectedSources) {
        source.enabled = enabled;
        await db.updateBookSourceListFields(source.bookSourceUrl, { enabled: enabled ? 1 : 0 });
      }
      this.reapplySourceFiltersPreservingViewport();
      promptAction.showToast({ message: `已${enabled ? '启用' : '禁用'} ${selectedSources.length} 个书源` });
    } catch (e) {
      console.error('批量更新书源失败:', e);
      promptAction.showToast({ message: '批量操作失败' });
    } finally {
      this.isBatchOperating = false;
    }
  }

  async batchSetExploreEnabled(enabled: boolean): Promise<void> {
    if (this.isBatchOperating) {
      return;
    }
    const selectedSources = this.getSelectedMutableSources();
    if (selectedSources.length === 0) {
      promptAction.showToast({ message: '所选书源均已锁定' });
      return;
    }

    this.isBatchOperating = true;
    this.batchOperationText = enabled ? '正在启用发现...' : '正在禁用发现...';
    try {
      const db = AppDatabase.getInstance();
      for (const source of selectedSources) {
        source.enabledExplore = enabled;
        await db.updateBookSourceListFields(source.bookSourceUrl, { enabledExplore: enabled ? 1 : 0 });
      }
      this.reapplySourceFiltersPreservingViewport();
      promptAction.showToast({ message: `已${enabled ? '启用' : '禁用'} ${selectedSources.length} 个书源的发现` });
    } catch (e) {
      console.error('批量更新发现状态失败:', e);
      promptAction.showToast({ message: '批量操作失败' });
    } finally {
      this.isBatchOperating = false;
    }
  }

  async batchSetLocked(locked: boolean): Promise<void> {
    if (this.isBatchOperating) {
      return;
    }
    const selectedSources = this.getSelectedSources()
      .filter((source: BookSource) => source.isLocked !== locked);
    if (selectedSources.length === 0) {
      promptAction.showToast({ message: locked ? '所选书源均已锁定' : '所选书源均已解锁' });
      return;
    }

    this.isBatchOperating = true;
    this.batchOperationText = locked ? '正在锁定书源...' : '正在解锁书源...';
    try {
      const db = AppDatabase.getInstance();
      for (const source of selectedSources) {
        await db.setBookSourceLocked(source.bookSourceUrl, locked);
        source.isLocked = locked;
      }
      this.reapplySourceFiltersPreservingViewport();
      promptAction.showToast({ message: `已${locked ? '锁定' : '解锁'} ${selectedSources.length} 个书源` });
    } catch (e) {
      console.error(`批量${locked ? '锁定' : '解锁'}书源失败:`, e);
      await this.loadSources();
      promptAction.showToast({ message: `批量${locked ? '锁定' : '解锁'}失败` });
    } finally {
      this.isBatchOperating = false;
    }
  }

  async batchDeleteSelectedSources(): Promise<void> {
    if (this.isBatchOperating) {
      return;
    }
    const selectedUrls = this.getSelectedMutableSources().map((source: BookSource) => source.bookSourceUrl);
    if (selectedUrls.length === 0) {
      promptAction.showToast({ message: '所选书源均已锁定' });
      return;
    }

    this.isBatchOperating = true;
    this.batchOperationText = '正在删除书源...';
    try {
      const db = AppDatabase.getInstance();
      for (const url of selectedUrls) {
        await db.deleteBookSource(url);
      }
      this.selectedSourceUrls = [];
      await this.loadSources();
      this.selectionMode = false;
      promptAction.showToast({ message: `已删除 ${selectedUrls.length} 个书源` });
    } catch (e) {
      console.error('批量删除书源失败:', e);
      promptAction.showToast({ message: '批量删除失败' });
    } finally {
      this.isBatchOperating = false;
    }
  }

  async updateSource(source: BookSource) {
    try {
      const db = AppDatabase.getInstance();
      await db.updateBookSourceListFields(source.bookSourceUrl, {
        bookSourceGroup: source.bookSourceGroup || '',
        enabled: source.enabled ? 1 : 0,
        enabledExplore: source.enabledExplore ? 1 : 0
      });
    } catch (e) {
      console.error('更新书源失败:', e);
    }
  }

  openCheckOptions(): void {
    if (this.selectionMode) {
      return;
    }
    if (this.isCheckingSources) {
      promptAction.showToast({ message: '正在校验中' });
      return;
    }
    this.showCheckOptionsDialog = true;
  }

  async startCheckEnabledSources(action: string = 'none'): Promise<void> {
    if (this.selectionMode) {
      return;
    }
    if (this.isCheckingSources) {
      promptAction.showToast({ message: '正在校验中' });
      return;
    }

    this.checkInvalidAction = action === 'disable' || action === 'delete' ? action : 'none';
    this.showCheckOptionsDialog = false;

    const db = AppDatabase.getInstance();
    const enabledSources = await db.getEnabledBookSources();
    if (enabledSources.length === 0) {
      promptAction.showToast({ message: '暂无启用书源' });
      return;
    }

    await this.startCheckSources(enabledSources, action);
  }

  async checkActionSource(): Promise<void> {
    const summary = this.actionSource();
    this.closeSourceActions();
    if (!summary) {
      promptAction.showToast({ message: '书源不存在' });
      return;
    }
    if (this.isCheckingSources) {
      promptAction.showToast({ message: '正在校验中' });
      return;
    }
    const source = await AppDatabase.getInstance().getBookSource(summary.bookSourceUrl);
    if (!source) {
      promptAction.showToast({ message: '书源不存在' });
      return;
    }
    await this.startCheckSources([source], 'none');
  }

  async startCheckSources(targetSources: BookSource[], action: string = 'none'): Promise<void> {
    if (targetSources.length === 0) {
      return;
    }

    const taskSerial = ++this.checkTaskSerial;
    this.checkInvalidAction = action === 'disable' || action === 'delete' ? action : 'none';
    this.showCheckOptionsDialog = false;
    this.showCheckDialog = true;
    this.isCheckingSources = true;
    this.checkBackgroundMode = false;
    this.checkDone = 0;
    this.checkTotal = targetSources.length;
    this.checkOkCount = 0;
    this.checkFailedCount = 0;
    this.checkNoResultCount = 0;
    this.checkNeedVerificationCount = 0;
    this.checkTemporaryErrorCount = 0;
    this.checkBadUrls = [];
    this.checkResultDetails = [];
    this.checkAutoHandledCount = 0;
    this.checkStatus = `准备校验 ${targetSources.length} 个书源`;
    this.checkNotificationLastAt = 0;
    this.checkCancelAgent = null;
    await this.ensureBookSourceCheckCancelSubscriber();
    if (taskSerial !== this.checkTaskSerial || !this.isCheckingSources) {
      return;
    }

    try {
      const coordinator = new SearchCoordinator(SearchExploreSettingsStore.getSearchConcurrency());
      this.checkCoordinator = coordinator;
      await coordinator.search(BOOK_SOURCE_CHECK_KEYWORD, (progress: SearchProgress) => {
        if (taskSerial !== this.checkTaskSerial || !this.isCheckingSources) {
          return;
        }
        this.checkDone = progress.done;
        this.checkTotal = progress.total;
        this.checkStatus = this.formatCheckProgressStatus(progress);
        if (this.checkBackgroundMode) {
          this.publishBookSourceCheckProgress(false).catch((e: Error) => {
            console.warn('更新书源校验通知失败:', e);
          });
        }
      }, {
        onSourceComplete: async (source: BookSource, result: SearchSourceResult) => {
          if (taskSerial !== this.checkTaskSerial || !this.isCheckingSources) {
            return;
          }
          await this.handleCheckedSourceCompletion(source, result);
        },
        targetSources: targetSources,
        validationOnly: true
      });

      if (taskSerial !== this.checkTaskSerial) {
        return;
      }
      this.checkDone = targetSources.length;
      this.checkTotal = targetSources.length;
      this.checkStatus = this.checkResultText();
    } catch (e) {
      if (taskSerial !== this.checkTaskSerial) {
        return;
      }
      console.error('校验书源失败:', e);
      this.checkStatus = '校验失败，请稍后重试';
      promptAction.showToast({ message: '校验失败' });
    } finally {
      if (taskSerial !== this.checkTaskSerial) {
        return;
      }
      const finishedInBackground = this.checkBackgroundMode;
      this.checkCoordinator = null;
      this.isCheckingSources = false;
      if (this.checkInvalidAction !== 'none') {
        await this.loadSources();
      }
      if (finishedInBackground) {
        await this.publishBookSourceCheckNotification('书源校验完成', this.checkResultText(), false);
      }
      this.checkBackgroundMode = false;
      await this.stopBookSourceCheckBackgroundRunning();
      if (!this.pageVisible) {
        this.releaseBookSourceCheckCancelSubscriber();
      }
    }
  }

  cancelBookSourceCheck(showToast: boolean): void {
    if (!this.isCheckingSources) {
      return;
    }
    const wasBackground = this.checkBackgroundMode;
    this.checkTaskSerial++;
    if (this.checkCoordinator) {
      this.checkCoordinator.cancel();
      this.checkCoordinator = null;
    }
    this.isCheckingSources = false;
    this.checkBackgroundMode = false;
    this.checkStatus = `校验已取消（${this.checkDone}/${this.checkTotal}）`;
    if (showToast) {
      promptAction.showToast({ message: '已停止书源校验' });
    }
    if (this.checkInvalidAction !== 'none') {
      this.loadSources().catch((e: Error) => {
        console.warn('取消校验后刷新书源失败:', e);
      });
    }
    if (wasBackground) {
      this.publishBookSourceCheckNotification('书源校验已取消', this.bookSourceCheckProgressText(), false)
        .catch((e: Error) => {
          console.warn('更新书源校验取消通知失败:', e);
        });
    }
    this.stopBookSourceCheckBackgroundRunning().catch((e: Error) => {
      console.warn('停止书源校验后台任务失败:', e);
    });
    if (!this.pageVisible) {
      this.releaseBookSourceCheckCancelSubscriber();
    }
  }

  async continueBookSourceCheckInBackground(): Promise<void> {
    if (!this.isCheckingSources) {
      return;
    }
    this.checkBackgroundMode = true;
    this.showCheckDialog = false;
    promptAction.showToast({ message: '书源校验将在后台继续，可在通知栏取消' });
    await this.startBookSourceCheckBackgroundRunning();
    await this.requestBookSourceCheckNotificationEnabled();
    if (this.isCheckingSources && this.checkBackgroundMode) {
      await this.publishBookSourceCheckProgress(true);
    }
  }

  bookSourceCheckProgressText(): string {
    const total = Math.max(0, this.checkTotal);
    if (total === 0) {
      return '正在准备校验书源（0%）';
    }
    const done = Math.max(0, Math.min(this.checkDone, total));
    const percent = Math.floor((done / total) * 100);
    return `已校验 ${done}/${total}（${percent}%）`;
  }

  async publishBookSourceCheckProgress(force: boolean): Promise<void> {
    const now = Date.now();
    if (!force && now - this.checkNotificationLastAt < BOOK_SOURCE_CHECK_NOTIFICATION_INTERVAL_MS) {
      return;
    }
    this.checkNotificationLastAt = now;
    await this.publishBookSourceCheckNotification(
      this.checkStatus || '书源校验后台进行中',
      this.bookSourceCheckProgressText(),
      true
    );
  }

  async publishBookSourceCheckNotification(text: string, additionalText: string, ongoing: boolean): Promise<void> {
    try {
      const request: notificationManager.NotificationRequest = {
        id: BOOK_SOURCE_CHECK_NOTIFICATION_ID,
        label: 'book_source_check',
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        isOngoing: ongoing,
        tapDismissed: false,
        isAlertOnce: true,
        wantAgent: await this.getBookSourceCheckOpenWantAgent(),
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: '书源校验',
            text: text,
            additionalText: additionalText
          }
        }
      };
      if (ongoing) {
        request.actionButtons = [{
          title: '取消',
          wantAgent: await this.getBookSourceCheckCancelWantAgent()
        }];
      } else {
        request.autoDeletedTime = Date.now() + 5000;
      }
      await notificationManager.publish(request);
    } catch (e) {
      console.warn('发布书源校验通知失败:', e);
    }
  }

  async requestBookSourceCheckNotificationEnabled(): Promise<void> {
    try {
      if (await notificationManager.isNotificationEnabled()) {
        return;
      }
      await notificationManager.requestEnableNotification(getContext(this) as common.UIAbilityContext);
    } catch (e) {
      console.warn('请求书源校验通知权限失败:', e);
    }
  }

  async getBookSourceCheckOpenWantAgent(): Promise<WantAgent> {
    const context = getContext(this) as common.UIAbilityContext;
    return await wantAgent.getWantAgent({
      wants: [{
        bundleName: context.abilityInfo.bundleName,
        abilityName: 'EntryAbility',
        parameters: {
          bookSourceCheckAction: 'open'
        }
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 2702,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
  }

  async getBookSourceCheckCancelWantAgent(): Promise<WantAgent> {
    if (this.checkCancelAgent) {
      return this.checkCancelAgent;
    }
    this.checkCancelAgent = await wantAgent.getWantAgent({
      wants: [{
        action: BOOK_SOURCE_CHECK_CANCEL_EVENT
      }],
      actionType: wantAgent.OperationType.SEND_COMMON_EVENT,
      requestCode: 2703,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    return this.checkCancelAgent;
  }

  async ensureBookSourceCheckCancelSubscriber(): Promise<void> {
    if (this.checkCancelSubscriber) {
      return;
    }
    try {
      const subscriber = await commonEventManager.createSubscriber({
        events: [BOOK_SOURCE_CHECK_CANCEL_EVENT]
      });
      this.checkCancelSubscriber = subscriber;
      commonEventManager.subscribe(subscriber,
        (error: Error | null, _data: commonEventManager.CommonEventData) => {
          if (error) {
            console.warn('接收书源校验取消事件失败:', error);
            return;
          }
          this.cancelBookSourceCheck(false);
        });
    } catch (e) {
      console.warn('注册书源校验取消事件失败:', e);
    }
  }

  releaseBookSourceCheckCancelSubscriber(): void {
    if (!this.checkCancelSubscriber) {
      return;
    }
    const subscriber = this.checkCancelSubscriber;
    this.checkCancelSubscriber = null;
    commonEventManager.unsubscribe(subscriber, (error: Error | null) => {
      if (error) {
        console.warn('注销书源校验取消事件失败:', error);
      }
    });
  }

  async startBookSourceCheckBackgroundRunning(): Promise<void> {
    if (this.checkBackgroundRunning) {
      return;
    }
    try {
      const agent = await this.getBookSourceCheckOpenWantAgent();
      await backgroundTaskManager.startBackgroundRunning(getContext(this), ['dataTransfer'], agent);
      this.checkBackgroundRunning = true;
    } catch (e) {
      console.warn('启动书源校验后台任务失败:', e);
    }
  }

  async stopBookSourceCheckBackgroundRunning(): Promise<void> {
    if (!this.checkBackgroundRunning) {
      return;
    }
    this.checkBackgroundRunning = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(getContext(this));
    } catch (e) {
      console.warn('停止书源校验后台任务失败:', e);
    }
  }

  async handleCheckedSourceCompletion(source: BookSource, result: SearchSourceResult): Promise<void> {
    source.validationStatus = result.validationStatus;
    try {
      await AppDatabase.getInstance().updateBookSourceValidationStatus(
        source.bookSourceUrl, source.validationStatus);
    } catch (e) {
      console.error('保存书源校验状态失败:', source.bookSourceName, e);
    }
    this.applyCheckedSourceValidationStatus(source.bookSourceUrl, source.validationStatus);

    if (source.validationStatus === BookSource.VALIDATION_PASSED) {
      this.checkOkCount++;
      return;
    }
    if (source.validationStatus === BookSource.VALIDATION_FAILED) {
      this.checkFailedCount++;
    } else if (source.validationStatus === BookSource.VALIDATION_NO_RESULTS) {
      this.checkNoResultCount++;
    } else if (source.validationStatus === BookSource.VALIDATION_NEEDS_VERIFICATION) {
      this.checkNeedVerificationCount++;
    } else if (source.validationStatus === BookSource.VALIDATION_TEMPORARY_ERROR) {
      this.checkTemporaryErrorCount++;
    }
    const sourceName = source.bookSourceName || source.bookSourceUrl;
    const detail = result.reason ?
      `${sourceName}：${this.sourceValidationStatusLabel(source.validationStatus)}（${result.reason}）` :
      `${sourceName}：${this.sourceValidationStatusLabel(source.validationStatus)}`;
    this.checkResultDetails = [...this.checkResultDetails, detail];

    if (source.validationStatus !== BookSource.VALIDATION_FAILED) {
      return;
    }
    if (!this.checkBadUrls.includes(source.bookSourceUrl)) {
      this.checkBadUrls = [...this.checkBadUrls, source.bookSourceUrl];
    }
    if (this.checkInvalidAction === 'none') {
      return;
    }
    if (source.isLocked) {
      return;
    }

    try {
      const db = AppDatabase.getInstance();
      if (this.checkInvalidAction === 'disable') {
        source.enabled = false;
        source.lastUpdateTime = Date.now();
        await db.updateBookSource(source);
        this.sources = this.sources.map((item: BookSource) =>
          item.bookSourceUrl === source.bookSourceUrl ? source : item);
      } else if (this.checkInvalidAction === 'delete') {
        await db.deleteBookSource(source.bookSourceUrl);
        this.sources = this.sources.filter((item: BookSource) => item.bookSourceUrl !== source.bookSourceUrl);
        this.allSources = this.allSources.filter((item: BookSource) => item.bookSourceUrl !== source.bookSourceUrl);
        this.visibleSources = this.visibleSources.filter(
          (item: BookSource) => item.bookSourceUrl !== source.bookSourceUrl);
      }
      this.checkAutoHandledCount++;
    } catch (e) {
      console.error(`自动${this.checkInvalidAction === 'delete' ? '删除' : '禁用'}无效书源失败:`, e);
    }
  }

  applyCheckedSourceValidationStatus(bookSourceUrl: string, validationStatus: number): void {
    this.allSources = this.allSources.map((item: BookSource) => {
      if (item.bookSourceUrl === bookSourceUrl) item.validationStatus = validationStatus;
      return item;
    });
    if (this.sourceValidationFilter !== 'all') {
      this.applySourceFilters();
      return;
    }
    this.sources = this.sources.map((item: BookSource) => {
      if (item.bookSourceUrl === bookSourceUrl) item.validationStatus = validationStatus;
      return item;
    });
    this.visibleSources = this.visibleSources.map((item: BookSource) => {
      if (item.bookSourceUrl === bookSourceUrl) item.validationStatus = validationStatus;
      return item;
    });
  }

  checkSummaryText(): string {
    return `已校验 ${this.checkTotal} 个书源${this.checkAutoActionSummary()}`;
  }

  formatCheckProgressStatus(progress: SearchProgress): string {
    const verifyText = progress.needVerification ? '；有书源需要网页验证' : '';
    return `已校验 ${progress.done}/${progress.total}${this.checkAutoActionSummary()}${verifyText}`;
  }

  checkAutoActionSummary(): string {
    if (this.checkInvalidAction === 'disable') {
      return `，已自动禁用 ${this.checkAutoHandledCount} 个`;
    }
    if (this.checkInvalidAction === 'delete') {
      return `，已自动删除 ${this.checkAutoHandledCount} 个`;
    }
    return '';
  }

  checkResultText(): string {
    if (this.checkTotal === 0) {
      return '没有需要校验的书源';
    }
    return `通过 ${this.checkOkCount}，失败 ${this.checkFailedCount}，无结果 ${this.checkNoResultCount}，` +
      `需要验证 ${this.checkNeedVerificationCount}，暂时异常 ${this.checkTemporaryErrorCount}` +
      this.checkAutoActionSummary();
  }

  async disableFailedCheckedSources(): Promise<void> {
    if (this.isBatchOperating) {
      return;
    }
    const lockedUrls = new Set(this.allSources.filter((source: BookSource) => source.isLocked)
      .map((source: BookSource) => source.bookSourceUrl));
    const failedUrls = this.checkBadUrls.filter((url: string) => !lockedUrls.has(url));
    if (failedUrls.length === 0) {
      promptAction.showToast({ message: '明确失败的书源均已锁定，未执行禁用' });
      return;
    }

    this.isBatchOperating = true;
    this.batchOperationText = '正在禁用书源...';
    try {
      const db = AppDatabase.getInstance();
      for (const url of failedUrls) {
        const source = await db.getBookSource(url);
        if (source) {
          source.enabled = false;
          source.lastUpdateTime = Date.now();
          await db.updateBookSource(source);
        }
      }
      const disabledCount = failedUrls.length;
      this.showCheckDialog = false;
      await this.loadSources();
      promptAction.showToast({ message: `已禁用 ${disabledCount} 个明确失败的书源` });
    } catch (e) {
      console.error('禁用异常书源失败:', e);
      promptAction.showToast({ message: '禁用失败' });
    } finally {
      this.isBatchOperating = false;
    }
  }

  async deleteFailedCheckedSources(): Promise<void> {
    if (this.isBatchOperating) {
      return;
    }
    const lockedUrls = new Set(this.allSources.filter((source: BookSource) => source.isLocked)
      .map((source: BookSource) => source.bookSourceUrl));
    const failedUrls = this.checkBadUrls.filter((url: string) => !lockedUrls.has(url));
    if (failedUrls.length === 0) {
      promptAction.showToast({ message: '明确失败的书源均已锁定，未执行删除' });
      return;
    }

    this.isBatchOperating = true;
    this.batchOperationText = '正在删除书源...';
    try {
      const db = AppDatabase.getInstance();
      for (const url of failedUrls) {
        await db.deleteBookSource(url);
      }
      this.checkBadUrls = [];
      this.showCheckDialog = false;
      await this.loadSources();
      promptAction.showToast({ message: `已删除 ${failedUrls.length} 个明确失败的书源` });
    } catch (e) {
      console.error('删除异常书源失败:', e);
      promptAction.showToast({ message: '删除失败' });
    } finally {
      this.isBatchOperating = false;
    }
  }

  async importFromFile() {
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['JSON|.json', '文本|.txt'];
      const pickerResult: Array<string> = await new picker.DocumentViewPicker().select(options);

      if (!pickerResult || pickerResult.length === 0) {
        return;
      }

      this.isImporting = true;
      const content = await this.readTextFile(pickerResult[0]);
      if (!content.trim()) {
        promptAction.showToast({ message: '文件内容为空' });
        return;
      }
      await this.importSourcesFromJson(content);
    } catch (e) {
      console.error('从文件导入失败:', e);
      const errMsg = this.importErrorMessage(e as Object);
      promptAction.showToast({ message: `导入失败: ${errMsg}` });
    } finally {
      this.isImporting = false;
    }
  }

  async handlePendingBookSourceImport(): Promise<void> {
    if (this.isImporting) return;
    const uri = AppStorage.get<string>('pendingBookSourceImportUri') || '';
    if (!uri) return;
    AppStorage.setOrCreate('pendingBookSourceImportUri', '');
    this.isImporting = true;
    try {
      const content = await this.readTextFile(uri);
      if (!content.trim()) {
        promptAction.showToast({ message: '文件内容为空' });
        return;
      }
      await this.importSourcesFromJson(content);
    } catch (e) {
      console.error('打开 JSON 书源文件失败:', e);
      const message = this.importErrorMessage(e as Object);
      promptAction.showToast({ message: `导入失败: ${message}` });
    } finally {
      this.isImporting = false;
      if (AppStorage.get<string>('pendingBookSourceImportUri')) {
        this.handlePendingBookSourceImport();
      }
    }
  }

  async exportSelectedSources(): Promise<void> {
    if (this.selectedSourceUrls.length === 0 || this.isBatchOperating) {
      promptAction.showToast({ message: '请先选择书源' });
      return;
    }
    const selectedSummaries = this.sources.filter((source: BookSource) =>
      this.selectedSourceUrls.includes(source.bookSourceUrl));
    if (selectedSummaries.length === 0) {
      promptAction.showToast({ message: '未找到可导出的书源' });
      return;
    }

    let file: fs.File | null = null;
    try {
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [`legado_book_sources_${this.exportTimestamp()}.json`];
      options.fileSuffixChoices = ['JSON 文件|.json'];
      const result = await new picker.DocumentViewPicker(getContext(this)).save(options);
      if (!result || result.length === 0) {
        return;
      }

      this.isBatchOperating = true;
      this.batchOperationText = '正在导出书源...';
      const selected: BookSource[] = [];
      const db = AppDatabase.getInstance();
      for (const summary of selectedSummaries) {
        const source = await db.getBookSource(summary.bookSourceUrl);
        if (source) selected.push(source);
      }
      const exported = selected.map((source: BookSource): Object => this.bookSourceExportObject(source));
      const json = JSON.stringify(exported, null, 2);
      const bytes = new util.TextEncoder().encodeInto(json);
      file = await fs.open(result[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      await fs.write(file.fd, bytes.buffer, { offset: 0, length: bytes.byteLength });
      await fs.close(file);
      file = null;
      promptAction.showToast({ message: `已导出 ${selected.length} 个书源` });
    } catch (e) {
      console.error('导出书源失败:', e);
      const message = e instanceof Error ? e.message : String(e);
      promptAction.showToast({ message: `导出失败: ${message}` });
    } finally {
      if (file) {
        try {
          await fs.close(file);
        } catch (_) {
        }
      }
      this.isBatchOperating = false;
      this.batchOperationText = '正在操作书源...';
    }
  }

  exportTimestamp(): string {
    const date = new Date();
    const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}_` +
      `${pad(date.getHours())}${pad(date.getMinutes())}`;
  }

  bookSourceExportObject(source: BookSource): Object {
    let result: Record<string, Object> = {};
    try {
      const parsed = JSON.parse(source.rawSourceJson || '{}') as Object;
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
        result = parsed as Record<string, Object>;
      }
    } catch (_) {}
    result['bookSourceUrl'] = source.bookSourceUrl;
    result['bookSourceName'] = source.bookSourceName;
    result['bookSourceType'] = source.bookSourceType;
    result['bookSourceGroup'] = source.bookSourceGroup;
    result['bookSourceComment'] = source.bookSourceComment;
    result['bookUrlPattern'] = source.bookUrlPattern;
    result['customOrder'] = source.customOrder;
    result['enabled'] = source.enabled;
    result['enabledExplore'] = source.enabledExplore;
    result['enabledCookieJar'] = source.enabledCookieJar;
    result['jsLib'] = source.jsLib;
    result['header'] = source.header;
    result['loginUrl'] = source.loginUrl;
    result['loginUi'] = source.loginUi;
    result['loginCheckJs'] = source.loginCheckJs;
    result['searchUrl'] = source.searchUrl;
    result['exploreUrl'] = source.exploreUrl;
    result['ruleSearch'] = JSON.parse(JSON.stringify(source.searchRule || {})) as Object;
    result['ruleExplore'] = JSON.parse(JSON.stringify(source.exploreRule || {})) as Object;
    result['ruleBookInfo'] = JSON.parse(JSON.stringify(source.bookInfoRule || {})) as Object;
    result['ruleToc'] = JSON.parse(JSON.stringify(source.tocRule || {})) as Object;
    result['ruleContent'] = JSON.parse(JSON.stringify(source.contentRule || {})) as Object;
    result['variableComment'] = source.variableComment;
    result['lastUpdateTime'] = source.lastUpdateTime;
    result['respondTime'] = source.respondTime;
    result['weight'] = source.weight;
    result['concurrentRate'] = source.concurrentRate;
    result['customButton'] = source.customButton;
    result['eventListener'] = source.eventListener;
    if (source.isPinned || result['isPinned'] !== undefined) result['isPinned'] = source.isPinned;
    if (source.isLocked || result['isLocked'] !== undefined) result['isLocked'] = source.isLocked;
    return result;
  }

  async readTextFile(filePath: string): Promise<string> {
    let file: fs.File | null = null;
    try {
      const stat = await fs.stat(filePath);
      if (stat.size <= 0) {
        return '';
      }
      if (stat.size > BOOK_SOURCE_IMPORT_FILE_LIMIT_BYTES) {
        throw new Error('文件过大，请选择 25MB 以内的书源文件');
      }

      file = await fs.open(filePath, fs.OpenMode.READ_ONLY);
      const buffer = new ArrayBuffer(stat.size);
      await fs.read(file.fd, buffer, { offset: 0, length: stat.size });
      const text = util.TextDecoder.create('utf-8').decodeWithStream(new Uint8Array(buffer), { stream: false });
      return text.replace(/^\uFEFF/, '');
    } finally {
      if (file) {
        await fs.close(file);
      }
    }
  }

  async importFromUrl() {
    this.hideKeyboard();
    const url = this.importUrl.trim();
    if (!url) {
      promptAction.showToast({ message: '请输入URL' });
      return;
    }

    try {
      this.isImporting = true;
      const content = await this.fetchImportUrlBody(url);
      await this.importSourcesFromJson(content);
      this.showImportUrlDialog = false;
      this.importUrl = '';
    } catch (e) {
      console.error('从URL导入失败:', e);
      const errMsg = this.importErrorMessage(e as Object);
      promptAction.showToast({ message: `导入失败: ${errMsg}` });
    } finally {
      this.isImporting = false;
    }
  }

  async fetchImportUrlBody(url: string): Promise<string> {
    let lastError = '';
    let webFallbackError = '';
    const candidates = this.importUrlCandidates(url);
    const directAttempts = Math.min(BOOK_SOURCE_IMPORT_URL_RETRY_COUNT, candidates.length);
    for (let attempt = 0; attempt < directAttempts; attempt++) {
      const requestUrl = candidates[attempt];
      const response = await new HttpClient(BOOK_SOURCE_IMPORT_TIMEOUT_MS).execute({
        url: requestUrl,
        method: 'GET',
        headers: {
          'Accept': 'application/json,text/plain,*/*'
        },
        connectTimeout: BOOK_SOURCE_IMPORT_TIMEOUT_MS,
        readTimeout: BOOK_SOURCE_IMPORT_TIMEOUT_MS,
        maxResponseBytes: BOOK_SOURCE_IMPORT_FILE_LIMIT_BYTES
      });
      if (this.isValidBookSourceJson(response.body)) {
        return response.body.replace(/^\uFEFF/, '');
      }
      const reason = response.success ? '响应内容不是有效书源JSON' :
        (response.error || `HTTP ${response.statusCode}`);
      lastError = `${this.importUrlHost(requestUrl)}: ${reason}`;
      if (reason.includes('2300056') || reason.toLowerCase().includes('failed to receive data from the peer')) {
        break;
      }
      if (attempt + 1 < directAttempts) {
        await new Promise<void>((resolve) => setTimeout(resolve, (attempt + 1) * 300));
      }
    }

    const plainHttpUrl = candidates.find((candidate: string) => /^http:\/\//i.test(candidate));
    if (plainHttpUrl) {
      try {
        const body = await RawHttpTextClient.get(plainHttpUrl, BOOK_SOURCE_IMPORT_FILE_LIMIT_BYTES,
          BOOK_SOURCE_IMPORT_TIMEOUT_MS);
        if (this.isValidBookSourceJson(body)) return body.replace(/^\uFEFF/, '');
        lastError = `${this.importUrlHost(plainHttpUrl)}: TCP兜底响应不是有效书源JSON`;
      } catch (tcpError) {
        lastError = `${this.importUrlHost(plainHttpUrl)}: ${this.importErrorMessage(tcpError as Object)}`;
      }
    }

    const webCandidates = candidates.length > 0 ? candidates : [url];
    for (let attempt = 0; attempt < BOOK_SOURCE_WEB_IMPORT_RETRY_COUNT; attempt++) {
      const webRequestUrl = webCandidates[attempt % webCandidates.length];
      try {
        const body = await this.fetchImportUrlViaWeb(webRequestUrl);
        if (this.isValidBookSourceJson(body)) return body.replace(/^\uFEFF/, '');
        webFallbackError = '网页取数失败: 浏览器下载内容不是有效书源JSON';
        lastError = `${this.importUrlHost(webRequestUrl)}: ${webFallbackError}`;
      } catch (webError) {
        webFallbackError = `网页取数失败: ${this.importErrorMessage(webError as Object)}`;
        lastError = `${this.importUrlHost(webRequestUrl)}: ${webFallbackError}`;
      }
      if (attempt + 1 < BOOK_SOURCE_WEB_IMPORT_RETRY_COUNT) {
        await new Promise<void>((resolve) => setTimeout(resolve, (attempt + 1) * 350));
      }
    }

    for (const requestUrl of candidates) {
      try {
        const body = await this.fetchImportUrlViaDownload(requestUrl);
        if (this.isValidBookSourceJson(body)) return body.replace(/^\uFEFF/, '');
        lastError = `${this.importUrlHost(requestUrl)}: 下载内容不是有效书源JSON`;
      } catch (downloadError) {
        const downloadMessage = this.importErrorMessage(downloadError as Object);
        const combinedMessage = webFallbackError ? `${webFallbackError}；${downloadMessage}` : downloadMessage;
        lastError = `${this.importUrlHost(requestUrl)}: ${combinedMessage}`;
      }
    }
    throw new Error(lastError || '获取书源失败');
  }

  fetchImportUrlViaWeb(url: string): Promise<string> {
    const origin = this.importUrlOrigin(url);
    if (!origin) return Promise.reject(new Error('网页取数仅支持 HTTP/HTTPS 地址'));
    if (this.webImportResolve || this.webImportReject) {
      return Promise.reject(new Error('已有网页取数任务正在运行'));
    }
    this.webImportController = new webview.WebviewController();
    this.webImportTargetUrl = url;
    this.webImportStarted = false;
    return new Promise<string>((resolve, reject) => {
      this.webImportResolve = resolve;
      this.webImportReject = reject;
      this.webImportTimeoutId = setTimeout(() => {
        this.finishWebImport('', '浏览器内核下载超时');
      }, BOOK_SOURCE_IMPORT_TIMEOUT_MS);
      this.webImportActive = true;
    });
  }

  startWebImportDownload(): void {
    if (!this.webImportActive || this.webImportStarted || !this.webImportTargetUrl) return;
    this.webImportStarted = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const suffix = `${Date.now()}_${Math.floor(Math.random() * 1000000)}`;
      this.webImportDownloadPath = `${context.cacheDir}/book_source_web_import_${suffix}.json`;
      const delegate = new webview.WebDownloadDelegate();
      delegate.onBeforeDownload((item: webview.WebDownloadItem): void => {
        if (!this.webImportActive) {
          try {
            item.cancel();
          } catch (_) {
          }
          return;
        }
        this.webImportDownloadItem = item;
        const totalBytes = item.getTotalBytes();
        if (totalBytes > BOOK_SOURCE_IMPORT_FILE_LIMIT_BYTES) {
          this.finishWebImport('', '浏览器下载文件过大，请使用 25MB 以内的书源文件');
          return;
        }
        try {
          item.start(this.webImportDownloadPath);
        } catch (startError) {
          this.finishWebImport('', `浏览器下载启动失败: ${this.importErrorMessage(startError as Object)}`);
        }
      });
      delegate.onDownloadFinish((item: webview.WebDownloadItem): void => {
        if (!this.webImportActive) return;
        const filePath = item.getFullPath() || this.webImportDownloadPath;
        this.readTextFile(filePath)
          .then((body: string): void => {
            this.finishWebImport(body);
          })
          .catch((readError: Object): void => {
            this.finishWebImport('', `读取浏览器下载文件失败: ${this.importErrorMessage(readError)}`);
          });
      });
      delegate.onDownloadFailed((item: webview.WebDownloadItem): void => {
        if (!this.webImportActive) return;
        this.finishWebImport('', `浏览器内核下载失败 (${item.getLastErrorCode()})`);
      });
      this.webImportDownloadDelegate = delegate;
      this.webImportController.setDownloadDelegate(delegate);
      // Navigate like a normal browser address-bar request. The server's attachment
      // response then naturally enters WebDownloadDelegate.
      this.webImportController.loadUrl(this.webImportTargetUrl);
    } catch (error) {
      this.finishWebImport('', `浏览器内核下载启动失败: ${this.importErrorMessage(error as Object)}`);
    }
  }

  finishWebImport(body: string = '', errorMessage: string = ''): void {
    if (!this.webImportResolve && !this.webImportReject) return;
    if (this.webImportTimeoutId >= 0) clearTimeout(this.webImportTimeoutId);
    if (errorMessage && this.webImportDownloadItem) {
      try {
        this.webImportDownloadItem.cancel();
      } catch (_) {
      }
    }
    const resolve = this.webImportResolve;
    const reject = this.webImportReject;
    const downloadPath = this.webImportDownloadPath;
    this.webImportResolve = null;
    this.webImportReject = null;
    this.webImportTimeoutId = -1;
    this.webImportStarted = false;
    this.webImportTargetUrl = '';
    this.webImportDownloadDelegate = null;
    this.webImportDownloadItem = null;
    this.webImportDownloadPath = '';
    this.webImportActive = false;
    if (downloadPath) {
      try {
        fs.unlinkSync(downloadPath);
      } catch (_) {
      }
    }
    if (errorMessage) {
      if (reject) reject(new Error(errorMessage));
    } else if (resolve) {
      resolve(body);
    }
  }

  async fetchImportUrlViaDownload(url: string): Promise<string> {
    const context = getContext(this) as common.UIAbilityContext;
    const suffix = `${Date.now()}_${Math.floor(Math.random() * 1000000)}`;
    const filePath = `${context.cacheDir}/book_source_import_${suffix}.json`;
    let task: request.DownloadTask | null = null;
    try {
      task = await request.downloadFile(context, {
        url: url,
        header: {
          'Accept': 'application/json,text/plain,*/*',
          'User-Agent': 'Mozilla/5.0 (Linux; HarmonyOS; Mobile) AppleWebKit/537.36 Safari/537.36'
        },
        enableMetered: true,
        enableRoaming: true,
        filePath: filePath,
        background: false,
        title: '导入书源'
      });
      await this.waitForImportDownload(task);
      return await this.readTextFile(filePath);
    } finally {
      if (task) {
        try {
          await task.delete();
        } catch (_) {
        }
      }
      try {
        fs.unlinkSync(filePath);
      } catch (_) {
      }
    }
  }

  waitForImportDownload(task: request.DownloadTask): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let settled = false;
      const finish = (errorMessage: string = ''): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timeoutId);
        try {
          task.off('complete', onComplete);
          task.off('fail', onFail);
        } catch (_) {
        }
        if (errorMessage) reject(new Error(errorMessage));
        else resolve();
      };
      const onComplete = (): void => finish();
      const onFail = (errorCode: number): void => finish(this.downloadServiceErrorMessage(errorCode));
      const timeoutId = setTimeout(() => finish('下载服务超时'), BOOK_SOURCE_IMPORT_TIMEOUT_MS);
      try {
        task.on('complete', onComplete);
        task.on('fail', onFail);
      } catch (subscribeError) {
        finish(this.importErrorMessage(subscribeError as Object));
        return;
      }
      task.query().then((info: request.DownloadInfo): void => {
        if (info.status === request.SESSION_SUCCESSFUL) finish();
        else if (info.status === request.SESSION_FAILED) finish(this.downloadServiceErrorMessage(info.failedReason));
      }).catch((queryError: Object): void => {
        if (!settled) console.warn('查询书源下载状态失败:', queryError);
      });
    });
  }

  downloadServiceErrorMessage(errorCode: number): string {
    if (errorCode === 8) return '下载服务未知错误 (8)';
    return `下载服务失败 (${errorCode})`;
  }

  importUrlCandidates(url: string): string[] {
    const raw = (url || '').trim();
    if (!raw) return [];
    const candidates: string[] = [raw];
    if (/^http:\/\//i.test(raw)) {
      const secure = `https://${raw.substring('http://'.length)}`;
      if (!candidates.includes(secure)) candidates.push(secure);
    }
    return candidates;
  }

  importUrlHost(url: string): string {
    const match = (url || '').match(/^https?:\/\/([^/?#]+)/i);
    return match ? match[1] : '书源地址';
  }

  importUrlOrigin(url: string): string {
    const match = (url || '').match(/^(https?:\/\/[^/?#]+)/i);
    return match ? match[1] : '';
  }

  looksLikeBookSourceJson(body: string): boolean {
    const text = (body || '').replace(/^\uFEFF/, '').replace(/^\s+/, '');
    return text.startsWith('[') || text.startsWith('{');
  }

  isValidBookSourceJson(body: string): boolean {
    if (!this.looksLikeBookSourceJson(body)) return false;
    try {
      const parsed = JSON.parse((body || '').replace(/^\uFEFF/, '')) as Object;
      return Array.isArray(parsed) || (!!parsed && typeof parsed === 'object');
    } catch (_) {
      return false;
    }
  }

  hideKeyboard(): void {
    try {
      this.getUIContext().getFocusController().clearFocus();
    } catch (_) {
    }
  }

  importErrorMessage(error: Object): string {
    if (error instanceof Error && this.isReadableErrorText(error.message)) return error.message;
    if (typeof error === 'string' && this.isReadableErrorText(error as string)) return error as string;
    if (error && typeof error === 'object') {
      const record = error as Record<string, Object>;
      const rawMessage = record['message'] || record['msg'] || record['reason'];
      let message = typeof rawMessage === 'string' ? (rawMessage as string).trim() : '';
      if (!this.isReadableErrorText(message) && rawMessage && typeof rawMessage === 'object') {
        const nested = rawMessage as Record<string, Object>;
        message = String(nested['message'] || nested['msg'] || nested['reason'] || '').trim();
      }
      const code = String(record['code'] || record['errorCode'] || '').trim();
      if (this.isReadableErrorText(message)) return code ? `${message} (${code})` : message;
      try {
        const json = JSON.stringify(error);
        if (json && json !== '{}') return json;
      } catch (_) {
      }
    }
    const fallback = String(error || '').trim();
    return this.isReadableErrorText(fallback) ? fallback : '未知错误';
  }

  isReadableErrorText(value: string): boolean {
    const text = (value || '').trim().toLowerCase();
    return !!text && !text.includes('[object object]') && text !== 'object object' && text !== '{}';
  }

  async importSourcesFromJson(json: string) {
    try {
      console.log('开始解析JSON，长度:', json.length);
      let sources: BookSource[] = [];

      const parsed: Object = JSON.parse(json);
      console.log('JSON解析成功，类型:', typeof parsed);

      // 处理 {"value": [...]} 结构
      let items: Record<string, Object>[] = [];
      if (Array.isArray(parsed)) {
        items = parsed as Record<string, Object>[];
      } else if (typeof parsed === 'object') {
        const obj = parsed as Record<string, Object>;
        if (Array.isArray(obj['value'])) {
          items = obj['value'] as Record<string, Object>[];
        } else if (obj['bookSourceUrl']) {
          items = [obj];
        }
      }

      console.log('待解析书源数量:', items.length);

      for (const item of items) {
        const source = this.parseBookSource(item);
        if (source.bookSourceUrl) {
          sources.push(source);
        }
      }

      console.log('解析到书源数量:', sources.length);

      if (sources.length === 0) {
        promptAction.showToast({ message: '未找到有效的书源' });
        return;
      }

      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      let importCount = 0;
      let failedCount = 0;
      let lockedCount = 0;
      let lastInsertError = '';
      for (const source of sources) {
        if (source.bookSourceUrl && source.bookSourceName) {
          try {
            const stored = await db.insertBookSource(source);
            if (stored) {
              if (!await this.verifyImportedBookSource(db, source)) {
                throw new Error('写入后校验失败，书源内容未完整保存');
              }
              importCount++;
            } else {
              lockedCount++;
            }
          } catch (insertErr) {
            failedCount++;
            lastInsertError = this.importErrorMessage(insertErr as Object);
            console.error('插入书源失败:', source.bookSourceName, insertErr);
          }
        }
      }

      if (importCount === 0) {
        if (lockedCount > 0 && failedCount === 0) {
          promptAction.showToast({ message: `未导入：${lockedCount} 个同地址书源已锁定，请先解锁后重试` });
          return;
        }
        throw new Error(lastInsertError || '书源未能写入本地数据库');
      }

      const loginCount = sources.filter((source: BookSource) => this.sourceNeedsLogin(source)).length;
      const loginMessage = loginCount > 0 ? `，其中 ${loginCount} 个需要登录` : '';
      const failedMessage = failedCount > 0 ? `，${failedCount} 个失败` : '';
      const lockedMessage = lockedCount > 0 ? `，${lockedCount} 个已锁定未覆盖` : '';
      promptAction.showToast({
        message: `成功导入 ${importCount} 个书源${failedMessage}${lockedMessage}${loginMessage}`
      });
      await this.loadSources();
    } catch (e) {
      console.error('解析书源失败:', e);
      const errMsg = this.importErrorMessage(e as Object);
      promptAction.showToast({ message: `书源格式错误: ${errMsg}` });
    }
  }

  parseBookSource(obj: Record<string, Object>): BookSource {
    const source = new BookSource();
    source.bookSourceUrl = obj['bookSourceUrl'] as string || '';
    source.bookSourceName = obj['bookSourceName'] as string || '';
    source.bookSourceType = Number(obj['bookSourceType'] || 0);
    source.bookSourceGroup = obj['bookSourceGroup'] as string || '';
    source.bookSourceComment = obj['bookSourceComment'] as string || '';
    source.loginUrl = obj['loginUrl'] as string || '';
    source.loginUi = obj['loginUi'] as string || '';
    source.loginCheckJs = obj['loginCheckJs'] as string || '';
    source.loginHeader = obj['loginHeader'] as string || '';
    source.loginInfo = String(obj['loginInfo'] || '');
    source.rawSourceJson = JSON.stringify(obj);
    source.bookUrlPattern = obj['bookUrlPattern'] as string || '';
    source.searchUrl = obj['searchUrl'] as string || '';
    source.exploreUrl = obj['exploreUrl'] as string || '';
    source.jsLib = obj['jsLib'] as string || '';
    source.header = obj['header'] as string || '';
    source.variableComment = obj['variableComment'] as string || '';
    source.variable = obj['variable'] as string || '';
    source.enabledCookieJar = obj['enabledCookieJar'] !== false;
    source.enabled = obj['enabled'] !== false;
    source.enabledExplore = obj['enabledExplore'] !== false;
    source.isPinned = obj['isPinned'] === true;
    source.isLocked = obj['isLocked'] === true || obj['locked'] === true;
    source.weight = (obj['weight'] as number) || 0;
    source.concurrentRate = obj['concurrentRate'] as string || '';
    source.lastUpdateTime = Number(obj['lastUpdateTime'] || Date.now());
    if (!Number.isFinite(source.lastUpdateTime)) source.lastUpdateTime = Date.now();
    source.respondTime = Number(obj['respondTime'] || 180000);
    if (!Number.isFinite(source.respondTime)) source.respondTime = 180000;
    source.customOrder = Math.floor(Number(obj['customOrder'] || 0));
    source.customButton = obj['customButton'] === true;
    source.eventListener = obj['eventListener'] === true;

    // 解析 searchRule (ruleSearch)
    const ruleSearch = obj['ruleSearch'];
    if (ruleSearch && typeof ruleSearch === 'string') {
      const fields = this.parseCompactRule(ruleSearch as string);
      const rule = new SearchRule();
      this.applyRuleToSearchRule(fields, rule);
      source.searchRule = rule;
    } else if (ruleSearch && typeof ruleSearch === 'object') {
      source.searchRule = ruleSearch as SearchRule;
    } else if (obj['searchRule'] && typeof obj['searchRule'] === 'object') {
      source.searchRule = obj['searchRule'] as SearchRule;
    }

    // 解析 exploreRule (ruleExplore)
    const ruleExplore = obj['ruleExplore'];
    if (ruleExplore && typeof ruleExplore === 'string') {
      const fields = this.parseCompactRule(ruleExplore as string);
      const rule = new ExploreRule();
      this.applyRuleToSearchRule(fields, rule);
      source.exploreRule = rule;
    } else if (ruleExplore && typeof ruleExplore === 'object' && !Array.isArray(ruleExplore)) {
      source.exploreRule = ruleExplore as ExploreRule;
    } else if (obj['exploreRule'] && typeof obj['exploreRule'] === 'object') {
      source.exploreRule = obj['exploreRule'] as ExploreRule;
    }

    // 解析 bookInfoRule (ruleBookInfo)
    const ruleBookInfo = obj['ruleBookInfo'];
    if (ruleBookInfo && typeof ruleBookInfo === 'string') {
      const fields = this.parseCompactRule(ruleBookInfo as string);
      const rule = new BookInfoRule();
      this.applyRuleToBookInfoRule(fields, rule);
      source.bookInfoRule = rule;
    } else if (ruleBookInfo && typeof ruleBookInfo === 'object') {
      source.bookInfoRule = ruleBookInfo as BookInfoRule;
    } else if (obj['bookInfoRule'] && typeof obj['bookInfoRule'] === 'object') {
      source.bookInfoRule = obj['bookInfoRule'] as BookInfoRule;
    }

    // 解析 tocRule (ruleToc)
    const ruleToc = obj['ruleToc'];
    if (ruleToc && typeof ruleToc === 'string') {
      const fields = this.parseCompactRule(ruleToc as string);
      const rule = new TocRule();
      this.applyRuleToTocRule(fields, rule);
      source.tocRule = rule;
    } else if (ruleToc && typeof ruleToc === 'object') {
      source.tocRule = ruleToc as TocRule;
    } else if (obj['tocRule'] && typeof obj['tocRule'] === 'object') {
      source.tocRule = obj['tocRule'] as TocRule;
    }

    // 解析 contentRule (ruleContent)
    const ruleContent = obj['ruleContent'];
    if (ruleContent && typeof ruleContent === 'string') {
      const fields = this.parseCompactRule(ruleContent as string);
      const rule = new ContentRule();
      this.applyRuleToContentRule(fields, rule);
      source.contentRule = rule;
    } else if (ruleContent && typeof ruleContent === 'object') {
      source.contentRule = ruleContent as ContentRule;
    } else if (obj['contentRule'] && typeof obj['contentRule'] === 'object') {
      source.contentRule = obj['contentRule'] as ContentRule;
    }

    return source;
  }

  async verifyImportedBookSource(db: AppDatabase, expected: BookSource): Promise<boolean> {
    const actual = await db.getBookSource(expected.bookSourceUrl);
    if (!actual) return false;
    return actual.rawSourceJson === expected.rawSourceJson &&
      actual.jsLib === expected.jsLib &&
      actual.loginUrl === expected.loginUrl &&
      actual.loginUi === expected.loginUi &&
      actual.header === expected.header &&
      actual.searchUrl === expected.searchUrl &&
      actual.exploreUrl === expected.exploreUrl &&
      this.ruleContainsImportedFields(actual.searchRule, expected.searchRule) &&
      this.ruleContainsImportedFields(actual.exploreRule, expected.exploreRule) &&
      this.ruleContainsImportedFields(actual.bookInfoRule, expected.bookInfoRule) &&
      this.ruleContainsImportedFields(actual.tocRule, expected.tocRule) &&
      this.ruleContainsImportedFields(actual.contentRule, expected.contentRule) &&
      actual.respondTime === expected.respondTime &&
      actual.customButton === expected.customButton &&
      actual.eventListener === expected.eventListener;
  }

  ruleContainsImportedFields(actual: Object, expected: Object): boolean {
    const actualRecord = actual as Record<string, Object>;
    const expectedRecord = expected as Record<string, Object>;
    for (const key of Object.keys(expectedRecord)) {
      if (JSON.stringify(actualRecord[key]) !== JSON.stringify(expectedRecord[key])) return false;
    }
    return true;
  }

  parseCompactRule(ruleStr: string): Record<string, string> {
    const result: Record<string, string> = {};

    let content = ruleStr.trim();
    if (content.startsWith('@{')) {
      content = content.substring(2);
    }
    if (content.endsWith('}')) {
      content = content.substring(0, content.length - 1);
    }

    let depth = 0;
    let inString = false;
    let stringChar = '';
    let inJsValue = false; // 是否在 @js: 值内部

    const pairs: string[] = [];
    let current = '';

    for (let i = 0; i < content.length; i++) {
      const ch = content[i];

      if (inString) {
        current += ch;
        if (ch === '\\') {
          i++;
          if (i < content.length) current += content[i];
        } else if (ch === stringChar) {
          inString = false;
        }
        continue;
      }

      if (ch === '"' || ch === "'") {
        inString = true;
        stringChar = ch;
        current += ch;
        continue;
      }

      if (ch === '(' || ch === '[' || ch === '{') {
        depth++;
        current += ch;
        continue;
      }

      if (ch === ')' || ch === ']' || ch === '}') {
        if (depth > 0) depth--;
        current += ch;
        continue;
      }

      // 检测当前是否在 @js: 值中（值以 @js: 开头时禁用分号拆分）
      if (!inJsValue && current.trim().includes('=@js:')) {
        inJsValue = true;
      }

      // 在非 @js: 值中，分号且深度为0时作为分隔符
      if (ch === ';' && depth === 0 && !inJsValue) {
        pairs.push(current.trim());
        current = '';
        continue;
      }

      // 在 @js: 值中，分号+换行可能表示新字段开始
      if (ch === ';' && depth === 0 && inJsValue) {
        // 检查后续是否是新字段: ;\s*keyword=
        const rest = content.substring(i + 1);
        const nextFieldMatch = rest.match(/^\s*(\w+)=/);
        if (nextFieldMatch) {
          // 是新字段开始，结束当前 @js: 值
          pairs.push(current.trim());
          current = '';
          inJsValue = false;
          // 跳过空白
          while (i + 1 < content.length && (content[i + 1] === ' ' || content[i + 1] === '\n' || content[i + 1] === '\r')) {
            i++;
          }
          continue;
        }
      }

      current += ch;
    }

    if (current.trim()) {
      pairs.push(current.trim());
    }

    for (const pair of pairs) {
      const eqIdx = pair.indexOf('=');
      if (eqIdx > 0) {
        const field = pair.substring(0, eqIdx).trim();
        let value = pair.substring(eqIdx + 1).trim();

        if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
          value = value.substring(1, value.length - 1);
        }

        result[field] = value;
      }
    }

    return result;
  }

  applyRuleToSearchRule(fields: Record<string, string>, rule: SearchRule): void {
    rule.bookList = fields['bookList'] || fields['booklist'] || '';
    rule.name = fields['name'] || '';
    rule.author = fields['author'] || '';
    rule.coverUrl = fields['coverUrl'] || '';
    rule.intro = fields['intro'] || fields['desc'] || '';
    rule.kind = fields['kind'] || '';
    rule.lastChapter = fields['lastChapter'] || fields['lastchapter'] || '';
    rule.bookUrl = fields['bookUrl'] || fields['bookurl'] || '';
    rule.wordCount = fields['wordCount'] || fields['wordcount'] || '';
  }

  applyRuleToTocRule(fields: Record<string, string>, rule: TocRule): void {
    rule.chapterList = fields['chapterList'] || fields['chapterlist'] || '';
    rule.chapterName = fields['chapterName'] || fields['chaptername'] || '';
    rule.chapterUrl = fields['chapterUrl'] || fields['chapterurl'] || '';
    rule.nextTocUrl = fields['nextTocUrl'] || fields['nexttocurl'] || '';
    rule.isVip = fields['isVip'] || fields['isvip'] || '';
    rule.isPay = fields['isPay'] || fields['ispay'] || '';
    rule.updateTime = fields['updateTime'] || fields['updatetime'] || '';
  }

  applyRuleToContentRule(fields: Record<string, string>, rule: ContentRule): void {
    rule.content = fields['content'] || '';
    rule.title = fields['title'] || '';
    rule.images = fields['images'] || '';
    rule.nextContentUrl = fields['nextContentUrl'] || fields['nextcontenturl'] || '';
    rule.replaceRegex = fields['replaceRegex'] || fields['replaceregex'] || '';
    rule.imageDecode = fields['imageDecode'] || fields['imagedecode'] || '';
    rule.imageStyle = fields['imageStyle'] || fields['imagestyle'] || '';
    rule.payAction = fields['payAction'] || fields['payaction'] || '';
  }

  applyRuleToBookInfoRule(fields: Record<string, string>, rule: BookInfoRule): void {
    rule.init = fields['init'] || '';
    rule.name = fields['name'] || '';
    rule.author = fields['author'] || '';
    rule.coverUrl = fields['coverUrl'] || '';
    rule.intro = fields['intro'] || fields['desc'] || '';
    rule.kind = fields['kind'] || '';
    rule.lastChapter = fields['lastChapter'] || fields['lastchapter'] || '';
    rule.wordCount = fields['wordCount'] || fields['wordcount'] || '';
    rule.updateTime = fields['updateTime'] || fields['updatetime'] || '';
    rule.tocUrl = fields['tocUrl'] || fields['tocurl'] || '';
  }
}
