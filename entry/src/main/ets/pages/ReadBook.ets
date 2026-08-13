import { router, window, promptAction, MeasureOptions } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { common, ConfigurationConstant, WantAgent, wantAgent } from '@kit.AbilityKit';
import { inputConsumer, KeyCode, Action, KeyEvent } from '@kit.InputKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { avSession } from '@kit.AVSessionKit';
import { notificationManager } from '@kit.NotificationKit';
import image from '@ohos.multimedia.image';
import fs from '@ohos.file.fs';
import fileUri from '@ohos.file.fileuri';
import graphicsText from '@ohos.graphics.text';
import { LengthMetrics } from '@ohos.arkui.node';
import deviceInfo from '@ohos.deviceInfo';
import Animator, { AnimatorResult } from '@ohos.animator';
import { HdsTabs, hdsMaterial } from '@kit.UIDesignKit';
import { AccountCommerceApi } from '../account/AccountCommerceApi';
import { AccountSessionStore } from '../account/AccountSessionStore';
import { CloudSyncCoordinator } from '../account/CloudSyncCoordinator';
import { TtsVoiceInfo } from '../account/AccountCommerceModels';
import { Book, BookChapter, Bookmark, BookSource, SearchBook, HttpTTS } from '../model/data/Book';
import { AppDatabase } from '../model/data/AppDatabase';
import { ReadBookEngine } from '../core/book/ReadBookEngine';
import { BookTypeSupport } from '../core/book/BookTypeSupport';
import { LocalBookService } from '../core/book/LocalBookService';
import { WebDavBookService } from '../webdav/WebDavBookService';
import { SearchCoordinator, SearchProgress } from '../core/book/SearchCoordinator';
import { WebBookService } from '../core/book/WebBookService';
import { VerificationSupport } from '../core/http/VerificationSupport';
import { ReaderActionData, ReaderActionMarker, ReaderActionMatch } from '../core/book/ReaderActionMarker';
import { BookSourceRuntimeSnapshotStore, BookSourceSettingValue } from '../core/book/BookSourceRuntimeSnapshot';
import { ReaderInteractionProviderRegistry } from '../core/book/ReaderInteractionProvider';
import { RecentReadShortcut } from '../utils/RecentReadShortcut';
import { RecentReadCardUpdater } from '../utils/RecentReadCardUpdater';
import { SystemTtsReader, TtsChunk, TtsVoiceOption } from '../utils/SystemTtsReader';
import { ReaderTtsFloatingSession } from '../utils/ReaderTtsFloatingSession';
import { ReaderProgressCheckpoint } from '../utils/ReaderProgressCheckpoint';
import { ReaderSettings, ReaderSettingsStore } from '../utils/ReaderSettingsStore';
import { ReaderReplaceRule, ReaderReplaceRuleStore } from '../utils/ReaderReplaceRuleStore';
import { ReaderThemeHelper, ReaderThemeItem } from '../utils/ReaderThemeHelper';
import { ReaderCustomThemeData, ReaderCustomThemeHelper, ReaderCustomThemeScheme } from '../utils/ReaderCustomThemeHelper';
import { ReaderBackgroundImageStore } from '../utils/ReaderBackgroundImageStore';
import { ColorCodePicker } from '../components/ColorCodePicker';
import { ImmersiveBackButton } from '../components/ImmersiveBackButton';
import { ReaderThemeBackground } from '../components/ReaderThemeBackground';
import { ReaderPageCurlPainter } from '../components/ReaderPageCurlPainter';
import { BookSourceStageRuntimeHost } from '../components/BookSourceStageRuntimeHost';
import { BookSourceStageWebRuntime, StageWebRuntimeRequest } from '../core/book/BookSourceStageWebRuntime';
import { SourceRuntimeStage } from '../core/book/BookSourceRuntimeRouter';
import { TtsSettings, TtsSettingsStore } from '../utils/TtsSettingsStore';
import { ReaderFontHelper, ReaderFontItem } from '../utils/ReaderFontHelper';
import { ReaderFontBootstrap } from '../utils/ReaderFontBootstrap';
import { ReaderSystemFontHelper } from '../utils/ReaderSystemFontHelper';
import { BookFieldSanitizer } from '../utils/BookFieldSanitizer';
import { CoverUrlNormalizer } from '../utils/CoverUrlNormalizer';
import { SearchExploreSettingsStore } from '../utils/SearchExploreSettingsStore';
import { ChangeSourceResultCache } from '../utils/ChangeSourceResultCache';
import { BookDisplayHelper } from '../utils/BookDisplayHelper';
import { BookCoverCache } from '../utils/BookCoverCache';
import { CoverGallerySettings } from '../utils/CoverGallerySettings';
import { AppThemeModeStore } from '../utils/AppThemeModeStore';
import {
  ReaderRegexBubbleStyleResolver,
  ReaderRegexEmphasisContext,
  ReaderRegexFontCodec,
  ReaderRegexFontRule,
  ReaderRegexLegacySettings,
  ReaderResolvedRegexEmphasis
} from '../model/reader/ReaderRegexFontRule';
import { ThemeRuntime } from '../theme/ThemeRuntime';
import { ThemeAssetRegistry } from '../theme/ThemeAssetRegistry';
import { VirtualListScrollbar } from '../utils/VirtualListScrollbar';
import { ReaderContentPreprocessor } from '../core/concurrency/ReaderContentPreprocessor';
import { CooperativeScheduler } from '../core/concurrency/CooperativeScheduler';

const TOC_WINDOW_PAGE_SIZE = 72;
const FULL_TEXT_CACHE_NOTIFICATION_INTERVAL_MS = 5000;
const READER_CURRENT_PAGINATION_AHEAD_PAGE_COUNT = 4;
const READER_ADJACENT_PAGINATION_PREVIEW_PAGE_COUNT = 2;
const READER_PAGINATION_BATCH_DELAY_MS = 64;
const READER_INTERACTIVE_PAGINATION_BATCH_DELAY_MS = 140;
const READER_PAGINATION_BUSY_RETRY_DELAY_MS = 48;
const READER_DOUBLE_PAGE_DIVIDER_WIDTH = 1;

interface ReadTextSlice {
  text: string;
  start: number;
  end: number;
  highlighted: boolean;
  ruleIndex: number;
  ttsHighlighted?: boolean;
  key: string;
}

interface ReaderTextParagraph {
  text: string;
  start: number;
  end: number;
  index: number;
  isLast: boolean;
  key: string;
}

interface ReaderTextParagraphGroup {
  paragraphs: ReaderTextParagraph[];
  mergeable: boolean;
  key: string;
}

interface ReaderPaginationResult {
  source: string;
  pages: string[];
  starts: number[];
  ends: number[];
  cursor?: number;
  complete?: boolean;
}

interface ReaderParagraphMeasureFallback {
  fontSize: number;
  fontFamily: string;
}

interface ReaderParagraphMetrics {
  heightPx: number;
  lineEnds: number[];
  lineBottomsPx: number[];
  lineCount: number;
}

interface ReaderInlineActionBoundsTask {
  text: string;
  marker: string;
  left: number;
  top: number;
  width: number;
  height: number;
  pageIdentity: string;
  attempts: number;
}

interface ReaderMergedActionBoundsTask {
  paragraphs: ReaderTextParagraph[];
  selectableKey: string;
  left: number;
  top: number;
  pageIdentity: string;
  attempts: number;
}

class ReaderComicPageDataSource implements IDataSource {
  private pages: string[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.pages.length;
  }

  getData(index: number): string {
    return this.pages[index] || '';
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  replace(pages: string[]): void {
    const previousCount = this.pages.length;
    let appendsExistingPrefix = pages.length >= previousCount;
    if (appendsExistingPrefix) {
      for (let index = 0; index < previousCount; index++) {
        if (this.pages[index] !== pages[index]) {
          appendsExistingPrefix = false;
          break;
        }
      }
    }
    if (appendsExistingPrefix && pages.length === previousCount) return;
    this.pages = [...pages];
    for (const listener of this.listeners) {
      if (appendsExistingPrefix) {
        for (let index = previousCount; index < pages.length; index++) {
          listener.onDataAdd(index);
        }
      } else {
        listener.onDataReloaded();
      }
    }
  }

  notifyChanged(index: number): void {
    if (index < 0 || index >= this.pages.length) return;
    for (const listener of this.listeners) {
      listener.onDataChange(index);
    }
  }
}

class ReaderFloatingCatalogDataSource implements IDataSource {
  private titles: string[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number { return this.titles.length; }
  getData(index: number): string { return this.titles[index] || ''; }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) this.listeners.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) this.listeners.splice(index, 1);
  }

  replace(titles: string[]): void {
    this.titles = titles.slice();
    for (const listener of this.listeners) listener.onDataReloaded();
  }
}

class ReaderCustomFontItem {
  familyName: string = '';
  filePath: string = '';
  sourceName: string = '';
}

class ReaderCustomFontData {
  fonts: ReaderCustomFontItem[] = [];
}

class ReaderTxtCharsetOption {
  value: string = '';
  label: string = '';
  description: string = '';

  constructor(value: string, label: string, description: string) {
    this.value = value;
    this.label = label;
    this.description = description;
  }
}

interface PageTurnPreview {
  text: string;
  secondaryText?: string;
  pageIndex: number;
  chapterIndex: number;
  pageStart?: number;
  secondaryPageStart?: number;
  documentSource?: string;
}

@Entry
@Component
struct ReadBookPage {
  @State bookUrl: string = '';
  @State book: Book | null = null;
  @State chapters: BookChapter[] = [];
  @State tocVisibleChapters: BookChapter[] = [];
  @State tocWindowStart: number = 0;
  @State tocQuickJumpArmed: boolean = false;
  @State tocQuickJumpInputVisible: boolean = false;
  @State tocQuickJumpDraft: string = '';
  @State tocSearchVisible: boolean = false;
  @State tocSearchQuery: string = '';
  @State tocSearchChapterIndexes: number[] = [];
  @State tocSearchLoading: boolean = false;
  @State tocSearchResultActive: boolean = false;
  @State tocDatabaseChapterCount: number = 0;
  @State tocListViewportHeight: number = 0;
  @State tocFirstVisibleGlobalIndex: number = 0;
  @State tocVisibleItemCount: number = 1;
  private tocSearchRequestSerial: number = 0;
  @State currentChapterIndex: number = 0;
  @State menuChapterPreviewIndex: number = 0;
  @State menuChapterSliderActive: boolean = false;
  @State menuChapterTooltipVisible: boolean = false;
  @State menuChapterConfirming: boolean = false;
  @State content: string = '';
  @State readerReplaceRules: ReaderReplaceRule[] = [];
  @State isLoading: boolean = true;
  @State showMenu: boolean = false;
  @State hdsMaterialRenderBranch: boolean = false;
  // 展开屏上记住用户本次唤起菜单的手指侧：-1 左侧，1 右侧。
  @State readerMenuAnchorSide: number = 1;
  @State showReaderActionMenu: boolean = false;
  @State showLayoutElementSettings: boolean = false;
  @State showTxtCharsetDialog: boolean = false;
  @State txtCharsetDraft: string = '';
  @State txtCharsetApplying: boolean = false;
  @State showReaderCommentPanel: boolean = false;
  @State readerCommentPanelTitle: string = '段评';
  @State readerCommentPanelUrl: string = '';
  @State readerCommentPanelProgress: number = 0;
  @State readerCommentPanelLoading: boolean = false;
  @State readerCommentPanelHeightRatio: number = 0.6;
  private readerCommentPanelHtml: string = '';
  private readerCommentPanelBaseUrl: string = '';
  private readerCommentPanelHtmlLoaded: boolean = false;
  private readerCommentPanelLoadSerial: number = 0;
  private readerCommentPanelReadyTimerId: number = -1;
  private readerCommentPanelDragStartRatio: number = 0.6;
  @State showToc: boolean = false;
  @State tocPanelTab: number = 0;
  @State bookmarks: Bookmark[] = [];
  @State bookmarkMultiSelectMode: boolean = false;
  @State selectedBookmarkIds: number[] = [];
  @State showBookmarkActionMenu: boolean = false;
  @State pendingBookmarkAction: Bookmark | null = null;
  @State bookmarkActionMenuX: number = 16;
  @State bookmarkActionMenuY: number = 96;
  @State showSettings: boolean = false;
  @State showTapZoneSettings: boolean = false;
  @State settingsPanelTab: number = 0;
  @State loadStatus: string = '正在加载...';
  @State verificationUrl: string = '';
  @State verificationTitle: string = '网页验证';
  @State showChangeSourceDialog: boolean = false;
  @State changeSourceResults: SearchBook[] = [];
  @State isChangingSource: boolean = false;
  @State isSwitchingSource: boolean = false;
  @State changeSourceStatus: string = '';
  @State contentPages: string[] = [];
  @State currentPageIndex: number = 0;
  @State currentPageText: string = '';
  @State displayPageText: string = '';
  @State displayPageChapterIndex: number = 0;
  @State displayPageIndex: number = 0;
  @State displayPageRenderKey: number = 0;
  @State pageRenderVersion: number = 0;
  @State chapterJumpRenderGeneration: number = 0;
  @State pageViewWidth: number = 0;
  @State pageViewHeight: number = 0;
  @State readerInitialPageReady: boolean = false;
  @State readerComicMode: boolean = false;
  @State readerComicImageRatios: number[] = [];
  @State readerComicPaginationParsing: boolean = false;
  @State readerComicPaginationParsedPages: number = 0;
  @State readerComicPaginationTotalPages: number = 0;
  @State readerComicChapterSwitching: boolean = false;
  @State readerComicBoundaryDirection: number = 0;
  @State readerComicBoundaryPullDistance: number = 0;
  @State readerComicBoundaryReady: boolean = false;
  @State readerComicChapterTransitionY: number = 0;
  @State readerComicChapterTransitionOpacity: number = 1;
  private readerComicPaginationSource: string = '';
  @State statusBarSafeHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State isTtsSpeaking: boolean = false;
  @State isTtsPaused: boolean = false;
  @State ttsPagedScrollOverride: boolean = false;
  @State ttsMediaControlsExpanded: boolean = false;
  @State showTtsQuickPlayer: boolean = false;
  @State ttsQuickOptionsPanel: number = 0;
  @StorageLink('globalTtsCapsulePositionX') ttsMiniPlayerPositionX: number = 16;
  @StorageLink('globalTtsCapsulePositionY') ttsMiniPlayerPositionY: number = -1;
  @State ttsMediaImage: string = '';
  @State ttsDisplayText: string = '';
  @State ttsHighlightStart: number = -1;
  @State ttsHighlightEnd: number = -1;
  @State ttsHighlightRenderVersion: number = 0;
  @State ttsSleepTimerMinutes: number = 0;
  @State ttsSleepTimerRemainingSeconds: number = 0;
  @StorageLink('globalTtsActive') @Watch('onGlobalTtsActiveChanged') globalTtsActive: boolean = false;
  @StorageLink('globalTtsPaused') globalTtsPaused: boolean = false;
  @StorageLink('globalTtsBookName') globalTtsBookName: string = '';
  @StorageLink('globalTtsChapterTitle') globalTtsChapterTitle: string = '';
  @StorageLink('globalTtsMode') globalTtsMode: string = '';
  @StorageLink('globalTtsVoiceCode') globalTtsVoiceCode: string = '';
  @StorageLink('globalTtsCover') globalTtsCover: ResourceStr = '';
  @StorageLink('globalTtsCoverFrame') globalTtsCoverFrame: ResourceStr = '';
  @StorageLink('globalTtsContent') globalTtsContent: string = '';
  @StorageLink('globalTtsTextBefore') globalTtsTextBefore: string = '';
  @StorageLink('globalTtsCurrentText') @Watch('onGlobalTtsPanelTextChanged') globalTtsCurrentText: string = '';
  @StorageLink('globalTtsTextAfter') globalTtsTextAfter: string = '';
  @StorageLink('globalTtsChapterProgress') globalTtsChapterProgress: string = '';
  @StorageLink('globalTtsAudioPositionMs') globalTtsAudioPositionMs: number = 0;
  @StorageLink('globalTtsAudioDurationMs') globalTtsAudioDurationMs: number = 0;
  @StorageLink('globalTtsSpeed') globalTtsSpeed: number = 1;
  @StorageLink('globalTtsTimerMinutes') globalTtsTimerMinutes: number = 0;
  @StorageLink('globalTtsTimerRemainingSeconds') globalTtsTimerRemainingSeconds: number = 0;
  @StorageLink('globalTtsCanPrevious') globalTtsCanPrevious: boolean = false;
  @StorageLink('globalTtsCanNext') globalTtsCanNext: boolean = false;
  @StorageLink('globalTtsBookUrl') globalTtsBookUrl: string = '';
  @StorageLink('globalTtsChapterIndex') globalTtsChapterIndex: number = -1;
  @StorageLink('globalTtsOffsetStart') globalTtsOffsetStart: number = -1;
  @StorageLink('globalTtsOffsetEnd') globalTtsOffsetEnd: number = -1;
  @StorageLink('globalTtsRevision') @Watch('onGlobalTtsRevisionChanged') globalTtsRevision: number = 0;
  @State showGlobalTtsQuickPlayer: boolean = false;
  @State showGlobalTtsCatalog: boolean = false;
  @State globalTtsOptionsPanel: number = 0;
  private ttsFloatingSessionOwnerId: string = `reader_${Date.now()}_${Math.random()}`;
  private ttsMiniPlayerDragOriginX: number = 0;
  private ttsMiniPlayerDragOriginY: number = 0;
  private pendingRestorePageIndex: number = -1;
  private tocScroller: Scroller = new Scroller();
  private tocLoadingPreviousPage: boolean = false;
  private tocLoadingNextPage: boolean = false;
  private tocPositioning: boolean = false;
  private tocPositionRequestSerial: number = 0;
  private bookmarkScroller: ListScroller = new ListScroller();
  private ttsPanelTextScroller: ListScroller = new ListScroller();
  private globalTtsPanelTextScroller: ListScroller = new ListScroller();
  private globalTtsCatalogScroller: ListScroller = new ListScroller();
  private globalTtsCatalogSource: ReaderFloatingCatalogDataSource = new ReaderFloatingCatalogDataSource();
  private readerComicScroller: ListScroller = new ListScroller();
  private readerComicPageDataSource: ReaderComicPageDataSource = new ReaderComicPageDataSource();
  private readerComicImageRatioCache: Map<string, number> = new Map();
  private readerComicImageRatioLoading: Set<string> = new Set();
  private readerComicScrollRestoreSerial: number = 0;
  private readerComicScrollRestoring: boolean = false;
  private readerComicProgressSaveTimerId: number = -1;
  private readerPagedProgressSaveTimerId: number = -1;
  private readerComicPanLastOffsetY: number = 0;
  private readerComicPanMoved: boolean = false;
  private readerComicBoundaryPullOriginY: number = 0;
  private readerComicSuppressClickUntil: number = 0;
  private ttsReader: SystemTtsReader = new SystemTtsReader();
  private ttsAutoContinue: boolean = false;
  private ttsReadToken: number = 0;
  private ttsChapterSwitching: boolean = false;
  private ttsLastMediaChapterCommandAt: number = 0;
  private ttsTextStartOffset: number = 0;
  private ttsLastFocusChunk: TtsChunk | null = null;
  private ttsLastFocusPageIndex: number = -1;
  private ttsResumeSyncSerial: number = 0;
  private mirroredTtsFocusSyncSerial: number = 0;
  @State mirroredTtsFocusActive: boolean = false;
  private ttsProgressSaveTimerId: number = -1;
  private ttsAutoTurningPage: boolean = false;
  private ttsPageTurnSerial: number = 0;
  private ttsPendingTargetPageIndex: number = -1;
  private ttsPendingHighlightChunk: TtsChunk | null = null;
  private ttsManualPageTurnResumePending: boolean = false;
  private ttsManualPageTurnResumeTimerId: number = -1;
  private ttsManualPageTurnResumeSerial: number = 0;
  private ttsManualPageTurnStartedAt: number = 0;
  private ttsBackgroundRunning: boolean = false;
  private ttsBackgroundRequesting: boolean = false;
  private ttsBackgroundDesired: boolean = false;
  private ttsBackgroundHeartbeatId: number = -1;
  private ttsBackgroundLastLogAt: number = 0;
  private ttsAvSession: avSession.AVSession | null = null;
  private ttsAvSessionRequesting: boolean = false;
  private ttsSpeedSaveTimerId: number = -1;
  private ttsSpeedAvSessionTimerId: number = -1;
  private ttsSleepTimerId: number = -1;
  private ttsSleepTimerEndAt: number = 0;
  private ttsMediaImageRefreshSerial: number = 0;
  private ttsMediaImageRaw: string = '';
  private ttsMediaPixelMap: image.PixelMap | null = null;
  private contentPageStarts: number[] = [];
  private contentPageEnds: number[] = [];
  private pagedContentText: string = '';
  private readerPaginationCache: Map<string, ReaderPaginationResult> = new Map();
  private readerPreparedContentCache: Map<string, string> = new Map();
  private readerParagraphMetricsCache: Map<string, ReaderParagraphMetrics> = new Map();
  private readerAdaptiveLineHeightCache: Map<string, number> = new Map();
  private cachedRegexRulesKey: string = '';
  private cachedRegexRules: ReaderRegexFontRule[] = [];
  private cachedDocumentRegexSource: string = '';
  private cachedDocumentRegexRulesKey: string = '';
  private cachedDocumentRegexSlices: ReadTextSlice[] = [];
  private regexFrameStyleCache: Map<string, string> = new Map();
  private adjacentPaginationPreloadSerial: number = 0;
  private previousPaginationPreloadSerial: number = 0;
  private readerPaginationWorkSerial: number = 0;
  private readerPaginationInteractionIdleUntil: number = 0;
  private pageTurnPreviewKey: string = '';
  private pageTurnPreviewLoadingKey: string = '';
  private readerPageCurlPainter: ReaderPageCurlPainter = new ReaderPageCurlPainter();
  private readerPageCurlContext: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private readerPageCurlFront: image.PixelMap | null = null;
  private readerPageCurlBack: image.PixelMap | null = null;
  private readerPageCurlSnapshotHeight: number = 0;
  private readerPageCurlCaptureKey: string = '';
  private readerPageCurlCaptureSerial: number = 0;
  private readerPageCurlCapturePending: boolean = false;
  private readerPageCurlCanvasReady: boolean = false;
  private readerPageCurlOffset: number = 0;
  private readerPageCurlAnimator: AnimatorResult | null = null;
  private readerPageCurlAnimationSerial: number = 0;
  @State readerPageCurlSnapshotReady: boolean = false;
  @State pageTransitionX: number = 0;
  @State pageTransitionOpacity: number = 1;
  @State pageSlideOffsetX: number = 0;
  @State pageSlideOffsetY: number = 0;
  @State bookmarkPullOffsetY: number = 0;
  @State bookmarkPullActive: boolean = false;
  @State bookmarkPullReady: boolean = false;
  @State pageSlideDirection: number = 0;
  @State pageTurnAnimating: boolean = false;
  @State pageTurnIncomingText: string = '';
  @State pageTurnIncomingSecondaryText: string = '';
  @State pageTurnIncomingX: number = 0;
  @State pageTurnIncomingOpacity: number = 1;
  @State pageTurnIncomingPageIndex: number = 0;
  @State pageTurnIncomingChapterIndex: number = 0;
  @State pageTurnIncomingPageStart: number = -1;
  @State pageTurnIncomingSecondaryPageStart: number = -1;
  @State pageTurnIncomingDocumentSource: string = '';
  @State pageTurnIncomingRenderVersion: number = 0;
  private bookLoadSerial: number = 0;
  private contentLoadSerial: number = 0;
  private isPageTurning: boolean = false;
  private queuedPageTurnDirection: number = 0;
  private queuedPageTurnStyle: string = '';
  private queuedPageTurnCount: number = 0;
  private queuedPageTurnVelocity: number = 0;
  private pageTurnCrossChapterHandoff: boolean = false;
  private changeSourceSessionId: number = 0;
  private activeChangeSourceCoordinator: SearchCoordinator | null = null;
  private lastRecentReadCardReloadAt: number = 0;
  private lastRecentReadCardChapterIndex: number = -1;
  private readerTouchStartX: number = 0;
  private readerTouchStartY: number = 0;
  private readerTouchLastX: number = 0;
  private readerTouchLastY: number = 0;
  private readerTouchActive: boolean = false;
  private readerTouchMoved: boolean = false;
  private suppressReaderTapClick: boolean = false;
  private readerInteractiveActionUntil: number = 0;
  private readerSourceActionOpenedAt: number = 0;
  private readerTouchActionMarker: string = '';
  private readerInlineTouchActionMarker: string = '';
  private readerSourceActionAreas: Map<string, number[]> = new Map<string, number[]>();
  private readerPendingInlineActionBounds: Map<string, ReaderInlineActionBoundsTask> =
    new Map<string, ReaderInlineActionBoundsTask>();
  private readerPendingMergedActionBounds: Map<string, ReaderMergedActionBoundsTask> =
    new Map<string, ReaderMergedActionBoundsTask>();
  private readerActionMatchCache: Map<string, ReaderActionMatch> = new Map<string, ReaderActionMatch>();
  private readerSourceSettingCacheKey: string = '';
  private readerSourceSettingCacheRevision: string = '';
  private readerSourceSettingCacheContentRule: string = '';
  private readerSourceSettingCacheJsLib: string = '';
  private readerSourceHasCommentBubbleScript: boolean = false;
  private readerSourceActionBoundsFlushPending: boolean = false;
  private readerInlineActionTextControllers: Map<string, TextController> = new Map<string, TextController>();
  private readerSelectableTextControllers: Map<string, TextController> = new Map<string, TextController>();
  private readerSelectableTextAreas: Map<string, number[]> = new Map<string, number[]>();
  private readerSelectableTextValues: Map<string, string> = new Map<string, string>();
  private readerTextSelectionUntil: number = 0;
  private readerTapLayerGlobalX: number = 0;
  private readerTapLayerGlobalY: number = 0;
  private readerSourceActionHitSlopX: number = 8;
  private readerSourceActionHitSlopY: number = 8;
  private readerTapSlop: number = 12;
  private readerPageTurnCommitDistance: number = 18;
  private readerPageTurnDirectionRatio: number = 0.8;
  private readerBookmarkPullStartDistance: number = 48;
  private readerBookmarkPullDirectionRatio: number = 1.5;
  private readerPanActive: boolean = false;
  private readerPageTurnGestureCommitted: boolean = false;
  private readerGestureTurnGuardUntil: number = 0;
  private readerGestureTurnAllowance: number = 0;
  private slideResetSerial: number = 0;
  @StorageLink('readerFontSize') @Watch('onReadLayoutChanged') readerFontSize: number = 20;
  @StorageLink('readerLineHeight') @Watch('onReadLayoutChanged') readerLineHeight: number = 12;
  @StorageLink('readerParagraphSpacing') @Watch('onReadLayoutChanged') readerParagraphSpacing: number = 0;
  @StorageLink('readerMarginLeft') @Watch('onReadLayoutChanged') readerMarginLeft: number = 18;
  @StorageLink('readerMarginRight') @Watch('onReadLayoutChanged') readerMarginRight: number = 18;
  @StorageLink('readerMarginTop') @Watch('onReadLayoutChanged') readerMarginTop: number = 18;
  @StorageLink('readerMarginBottom') @Watch('onReadLayoutChanged') readerMarginBottom: number = 18;
  @StorageLink('readerLightThemeIndex') @Watch('onReaderThemeChanged') readerLightThemeIndex: number = 0;
  @StorageLink('readerDarkThemeIndex') @Watch('onReaderThemeChanged') readerDarkThemeIndex: number = 0;
  @StorageLink('readerLightCustomThemeBackgroundColor') @Watch('onReaderThemeChanged') readerLightCustomThemeBackgroundColor: string = ReaderThemeHelper.LIGHT_CUSTOM_BACKGROUND_COLOR;
  @StorageLink('readerLightCustomThemeTextColor') @Watch('onReaderThemeChanged') readerLightCustomThemeTextColor: string = ReaderThemeHelper.LIGHT_CUSTOM_TEXT_COLOR;
  @StorageLink('readerDarkCustomThemeBackgroundColor') @Watch('onReaderThemeChanged') readerDarkCustomThemeBackgroundColor: string = ReaderThemeHelper.DARK_CUSTOM_BACKGROUND_COLOR;
  @StorageLink('readerDarkCustomThemeTextColor') @Watch('onReaderThemeChanged') readerDarkCustomThemeTextColor: string = ReaderThemeHelper.DARK_CUSTOM_TEXT_COLOR;
  @StorageLink('readerCustomThemesRaw') @Watch('onReaderThemeChanged') readerCustomThemesRaw: string = '';
  @State customThemeNameDraft: string = '';
  @StorageLink('readerPageTurnMode') readerPageTurnMode: number = 1;
  @StorageLink('readerPageTurnAnimationType') @Watch('onReaderPageTurnAnimationChanged') readerPageTurnAnimationType: number = ReaderSettingsStore.PAGE_TURN_ANIMATION_SLIDE;
  @StorageLink('readerLandscapeDoublePage') @Watch('onReaderLandscapeDoublePageChanged') readerLandscapeDoublePage: boolean = false;
  @StorageLink('readerScreenOrientation') @Watch('onReaderScreenOrientationChanged') readerScreenOrientation: string =
    ReaderSettingsStore.SCREEN_ORIENTATION_SYSTEM;
  @StorageLink('readerTapZoneActions') readerTapZoneActions: string = '3,3,3,3,1,2,2,2,2';
  @StorageLink('readerVolumeTurnPage') @Watch('onReaderVolumeTurnPageChanged') readerVolumeTurnPage: boolean = false;
  @StorageLink('readerScreenTimeoutMinutes') readerScreenTimeoutMinutes: number =
    ReaderSettingsStore.SCREEN_TIMEOUT_ALWAYS_ON;
  @StorageLink('readerExtendToStatusBar') @Watch('onReaderExtendToStatusBarChanged') readerExtendToStatusBar: boolean = false;
  @StorageLink('readerPreloadEnabled') @Watch('onReaderPreloadChanged') readerPreloadEnabled: boolean = true;
  @StorageLink('readerPreloadChapterCount') @Watch('onReaderPreloadChanged') readerPreloadChapterCount: number = 1;
  @StorageLink('readerUseTtsQuickAction') readerUseTtsQuickAction: boolean = true;
  @StorageLink('readerUseChapterQuickJump') readerUseChapterQuickJump: boolean = true;
  @StorageLink('readerReplaceRulesUpdateTime') @Watch('onReaderReplaceRulesChanged') readerReplaceRulesUpdateTime: number = 0;
  @StorageLink('readerFontFamily') @Watch('onReaderFontChanged') readerFontFamily: string = '';
  @StorageLink('readerFontFilePath') @Watch('onReaderFontChanged') readerFontFilePath: string = '';
  @StorageLink('readerSystemFontFamily') @Watch('onReaderActiveFontChanged') readerSystemFontFamily: string = '';
  @StorageLink('readerActiveFontFamily') @Watch('onReaderActiveFontChanged') readerActiveFontFamily: string = '';
  @StorageLink('readerFontRegistered') @Watch('onReaderActiveFontChanged') readerStoredFontRegistered: boolean = false;
  @StorageLink('readerBodyFontMode') @Watch('onReaderFontStyleChanged') readerBodyFontMode: string = 'global';
  @StorageLink('readerBodyFontFamily') @Watch('onReaderFontStyleChanged') readerBodyFontFamily: string = '';
  @StorageLink('readerTitleFontMode') @Watch('onReaderFontStyleChanged') readerTitleFontMode: string = 'global';
  @StorageLink('readerTitleFontFamily') @Watch('onReaderFontStyleChanged') readerTitleFontFamily: string = '';
  @StorageLink('readerTitleFontSize') @Watch('onReaderFontStyleChanged') readerTitleFontSize: number = 22;
  @StorageLink('readerRegexFontEnabled') @Watch('onReaderFontStyleChanged') readerRegexFontEnabled: boolean = false;
  @StorageLink('readerRegexFontPattern') @Watch('onReaderFontStyleChanged') readerRegexFontPattern: string = '';
  @StorageLink('readerRegexFontMode') @Watch('onReaderFontStyleChanged') readerRegexFontMode: string = 'global';
  @StorageLink('readerRegexFontFamily') @Watch('onReaderFontStyleChanged') readerRegexFontFamily: string = '';
  @StorageLink('readerRegexFontSize') @Watch('onReaderFontStyleChanged') readerRegexFontSize: number = 20;
  @StorageLink('readerRegexShadowColor') @Watch('onReaderFontStyleChanged') readerRegexShadowColor: string = '';
  @StorageLink('readerRegexFontRulesRaw') @Watch('onReaderFontStyleChanged') readerRegexFontRulesRaw: string = '';
  @State activeReaderFontFamily: string = '';
  @State readerFontRegistered: boolean = false;
  @State readerFontRenderReady: boolean = false;
  @StorageLink('appDarkMode') @Watch('onReaderColorModeChanged') appDarkMode: boolean = false;
  @StorageLink('appThemeMode') appThemeMode: string = 'system';
  @StorageLink('appThemeBookCoverEnabled') themeBookCoverEnabled: boolean = false;
  @StorageLink('themeRevision') @Watch('onReaderThemeChanged') themeRevision: number = 0;
  @StorageLink('appLightAccentColor') appLightAccentColor: string = '#007DFF';
  @StorageLink('appDarkAccentColor') appDarkAccentColor: string = '#4E9BFF';
  @StorageLink('appLightButtonColor') appLightButtonColor: string = '#007DFF';
  @StorageLink('appDarkButtonColor') appDarkButtonColor: string = '#3F8CFF';
  @StorageLink('bookshelfCoverAlbums') @Watch('onTtsCoverSettingsChanged') bookshelfCoverAlbums: string = '';
  @StorageLink('bookshelfLightCoverAlbumId') @Watch('onTtsCoverSettingsChanged') bookshelfLightCoverAlbumId: string = '';
  @StorageLink('bookshelfDarkCoverAlbumId') @Watch('onTtsCoverSettingsChanged') bookshelfDarkCoverAlbumId: string = '';
  @StorageLink('bookshelfCoverApplyScope') @Watch('onTtsCoverSettingsChanged') bookshelfCoverApplyScope: string = 'all';
  @StorageLink('bookshelfCoverTargetBooks') @Watch('onTtsCoverSettingsChanged') bookshelfCoverTargetBooks: string = '';
  @StorageLink('bookshelfIgnoreSourceCover') @Watch('onTtsCoverSettingsChanged') bookshelfIgnoreSourceCover: boolean = false;
  @StorageLink('bookshelfCoverMode') @Watch('onTtsCoverSettingsChanged') bookshelfCoverMode: string = 'sequence';
  @StorageLink('coverGalleryUpdateTime') @Watch('onTtsCoverSettingsChanged') coverGalleryUpdateTime: number = 0;
  @StorageLink('ttsPerson') ttsPerson: number = 0;
  @StorageLink('ttsOnline') ttsOnline: number = 1;
  @StorageLink('ttsStyle') ttsStyle: string = '';
  @StorageLink('ttsLanguage') ttsLanguage: string = 'zh-CN';
  @StorageLink('ttsSpeed') ttsSpeed: number = 1;
  @StorageLink('ttsInstalledVoiceKeys') ttsInstalledVoiceKeys: string = '';
  @StorageLink('ttsCustomVoiceId') ttsCustomVoiceId: string = '';
  @StorageLink('ttsCustomVoices') @Watch('onTtsCustomVoicesChanged') ttsCustomVoices: string = '';
  @StorageLink('ttsCloudVoiceId') ttsCloudVoiceId: string = '';
  @StorageLink('launchShortcutNonce') @Watch('onLaunchShortcutChanged') launchShortcutNonce: number = 0;
  @StorageLink('fullTextCacheCancelNonce') @Watch('onFullTextCacheCancelNonceChanged') fullTextCacheCancelNonce: number = 0;
  @State ttsVoices: TtsVoiceOption[] = [ReadBookPage.defaultTtsVoice()];
  @State ttsCustomVoiceOptions: HttpTTS[] = [];
  @State ttsCloudVoices: TtsVoiceInfo[] = [];
  @State ttsSelectedVoiceKey: string = '';
  @State ttsVoicesLoading: boolean = false;
  @State showTtsVoiceDropdown: boolean = false;
  @State fullTextCaching: boolean = false;
  @State fullTextCacheDone: number = 0;
  @State fullTextCacheTotal: number = 0;
  @State fullTextCacheStatus: string = '';
  private fullTextCacheTaskId: number = 0;
  private fullTextCacheCancelRequested: boolean = false;
  private fullTextCacheCancelSeenNonce: number = 0;
  private fullTextCacheNotificationLastAt: number = 0;
  private fullTextCacheBackgroundRunning: boolean = false;
  private fullTextCacheCancelAgent: WantAgent | null = null;
  private volumeUpCallback?: (event: KeyEvent) => void;
  private volumeDownCallback?: (event: KeyEvent) => void;
  private lastLoggedReaderFontFamily: string = '';
  private readerFontChangeSerial: number = 0;
  private readerLayoutApplyTimerId: number = -1;
  private readerExtendLayoutRefreshTimerId: number = -1;
  private readerExtendLayoutReadingOffset: number = -1;
  private readerPageContentTopPaddingSnapshot: number = -1;
  private readerLayoutCommitInProgress: boolean = false;
  private readerTypographyDraftPending: boolean = false;
  @State readerTypographyValueRevision: number = 0;
  @State readerTypographyFontSize: number = 20;
  @State readerTypographyLineHeight: number = 12;
  @State readerTypographyParagraphSpacing: number = 0;
  @State readerTypographyMarginLeft: number = 18;
  @State readerTypographyMarginRight: number = 18;
  @State readerTypographyMarginTop: number = 18;
  @State readerTypographyMarginBottom: number = 18;
  private readingProgressSaveQueue: Promise<void> = Promise.resolve();
  private readerExitProgressSaved: boolean = false;
  private openedFromShortcut: boolean = false;
  private shortcutReplacedPreviousPage: boolean = false;
  private shortcutRoutingActive: boolean = false;
  private readerEntryInitializing: boolean = true;
  private readerSettingsReloadSerial: number = 0;
  private returningFromReaderReplaceRules: boolean = false;
  @State shelfOpeningEntryOpacity: number = 1;
  @State shelfOpeningEntryScale: number = 1;
  private shelfOpeningEntryTimer: number = -1;
  private openedWithShelfAnimation: boolean = false;
  private readerScreenTimeoutTimerId: number = -1;
  private readerScreenTimeoutSerial: number = 0;
  private readerScreenOrientationSerial: number = 0;
  private readerPageVisible: boolean = false;
  private readerCommentPanelMarker: string = '';
  private readerCommentPanelAnchorBottom: number = -1;
  private readerCommentPageAreaTop: number = -1;
  private readerCommentPageAreaHeight: number = 0;
  private readerCommentPanelController: webview.WebviewController = new webview.WebviewController();

  async aboutToAppear() {
    ReaderProgressCheckpoint.attach(this.ttsFloatingSessionOwnerId,
      (): Promise<void> => this.flushReadingProgressCheckpoint());
    this.readerPageVisible = true;
    this.applyReaderScreenOrientation();
    this.shortcutRoutingActive = true;
    this.readerEntryInitializing = true;
    this.enterReaderImmersive();
    this.updateVolumeKeySubscription();
    const params = router.getParams() as Record<string, string>;
    this.openedWithShelfAnimation = !!params && params['shelfBookOpening'] === 'true';
    this.openedFromShortcut = !!params && params['shortcutEntry'] === 'true';
    this.shortcutReplacedPreviousPage = !!params && params['shortcutReplace'] === 'true';
    if (this.openedWithShelfAnimation) {
      this.shelfOpeningEntryOpacity = 0.86;
      this.shelfOpeningEntryScale = 0.985;
      this.shelfOpeningEntryTimer = setTimeout(() => {
        this.shelfOpeningEntryTimer = -1;
        animateTo({ duration: 260, curve: Curve.EaseOut }, () => {
          this.shelfOpeningEntryOpacity = 1;
          this.shelfOpeningEntryScale = 1;
        });
      }, 20);
    }
    if (params && params['bookUrl']) {
      this.bookUrl = params['bookUrl'];
      this.isLoading = true;
      this.loadStatus = '正在加载...';
      this.resetReaderStateForBookLoad();
    }
    try {
      await this.loadReaderSettings();
      this.readerReplaceRules = await ReaderReplaceRuleStore.load(getContext(this), true);
      this.loadTtsSettingsAndVoices();
      if (this.bookUrl) {
        await this.loadBook();
        await this.loadBookmarks();
      }
    } finally {
      this.readerEntryInitializing = false;
    }
  }

  onPageShow(): void {
    this.readerPageVisible = true;
    this.applyReaderScreenOrientation();
    this.applyReaderScreenTimeout();
    this.shortcutRoutingActive = true;
    const returningFromReplaceRules = this.returningFromReaderReplaceRules;
    this.returningFromReaderReplaceRules = false;
    if (!this.readerEntryInitializing) {
      if (returningFromReplaceRules) {
        // 规则页只会改变替换净化配置，返回时仅重载规则并重排一次。
        this.reloadReaderReplaceRules(true).catch((error: Error) => {
          console.warn('恢复替换净化规则失败:', error);
        });
      } else {
        this.reloadReaderSettingsAfterPageShow().catch((error: Error) => {
          console.warn('恢复阅读设置失败:', error);
        });
        this.reloadReaderReplaceRules(true).catch((error: Error) => {
          console.warn('恢复替换净化规则失败:', error);
        });
        this.reloadSourceInteractionsAfterPageShow().catch((error: Error) => {
          console.warn('恢复书源交互设置失败:', error);
        });
      }
    }
    if (!returningFromReplaceRules) {
      this.reregisterReaderFontAfterShow(0);
      this.reregisterReaderFontAfterShow(120);
    }
    this.syncTtsFocusAfterResumeLater(0);
    this.syncTtsFocusAfterResumeLater(180);
  }

  onGlobalTtsActiveChanged(): void {
    if (!this.globalTtsActive) {
      this.showGlobalTtsQuickPlayer = false;
      this.globalTtsOptionsPanel = 0;
      this.clearMirroredTtsFocus();
    }
  }

  onGlobalTtsRevisionChanged(): void {
    if (!this.isMirroringActiveTtsForCurrentBook()) {
      return;
    }
    this.syncMirroredTtsFocus().catch((error: Error) => {
      console.warn('同步后台朗读正文焦点失败:', error);
    });
  }

  onGlobalTtsPanelTextChanged(): void {
    this.scrollGlobalTtsPanelToCurrentSentence();
  }

  onBackPress(): boolean {
    if (this.showReaderCommentPanel) {
      this.closeReaderCommentPanel();
      return true;
    }
    if (this.showGlobalTtsCatalog) {
      this.closeGlobalTtsCatalog();
      return true;
    }
    if (this.showTtsQuickPlayer) {
      this.closeTtsQuickPlayer();
      return true;
    }
    if (this.showGlobalTtsQuickPlayer) {
      this.closeGlobalTtsQuickPlayer();
      return true;
    }
    if (this.showTtsVoiceDropdown) {
      this.showTtsVoiceDropdown = false;
      return true;
    }
    if (this.showTxtCharsetDialog) {
      if (!this.txtCharsetApplying) this.showTxtCharsetDialog = false;
      return true;
    }
    if (this.showLayoutElementSettings) {
      this.showLayoutElementSettings = false;
      return true;
    }
    if (this.showBookmarkActionMenu) {
      this.closeBookmarkActionMenu();
      return true;
    }
    if (this.showChangeSourceDialog) {
      this.showChangeSourceDialog = false;
      return true;
    }
    if (this.showTapZoneSettings) {
      this.showTapZoneSettings = false;
      return true;
    }
    if (this.showToc || this.showSettings || this.showMenu) {
      this.showToc = false;
      this.hideReaderPanels();
      return true;
    }
    this.exitReaderPage();
    return true;
  }

  async reloadReaderSettingsAfterPageShow(): Promise<void> {
    const reloadSerial = ++this.readerSettingsReloadSerial;
    const paginationSource = this.pagedContentText;
    const previousPaginationKey = paginationSource ?
      this.buildReaderPaginationCacheKey(this.currentChapterIndex, paginationSource) : '';
    const settings = await ReaderSettingsStore.reload(getContext(this));
    if (reloadSerial !== this.readerSettingsReloadSerial) {
      return;
    }
    ReaderSettingsStore.applyToStorage(settings);
    this.applyLoadedReaderSettings(settings);
    this.cachedRegexRulesKey = '';
    this.cachedRegexRules = [];
    this.refreshReaderTextRender();
    const nextPaginationKey = paginationSource ?
      this.buildReaderPaginationCacheKey(this.currentChapterIndex, paginationSource) : '';
    if (previousPaginationKey && previousPaginationKey === nextPaginationKey) {
      return;
    }
    this.pendingRestorePageIndex = Math.max(this.pendingRestorePageIndex, this.currentPageIndex);
    this.readerPaginationCache.clear();
    this.paginateContent(this.content);
  }

  async reloadSourceInteractionsAfterPageShow(): Promise<void> {
    if (!this.book || this.book.origin === 'local' || this.chapters.length === 0) return;
    const engine = ReadBookEngine.get();
    const changed = await engine.refreshSourceInteractionState();
    if (!changed) return;
    this.book = engine.book || this.book;
    this.chapters = [...engine.chapters];
    this.pendingRestorePageIndex = this.currentPageIndex;
    this.readerPaginationCache.clear();
    this.readerPreparedContentCache.clear();
    this.readerPaginationWorkSerial++;
    this.adjacentPaginationPreloadSerial++;
    this.previousPaginationPreloadSerial++;
    await this.loadContent(true, this.currentChapterIndex, true);
  }

  reregisterReaderFontAfterShow(delayMs: number): void {
    setTimeout(() => {
      if (!this.readerFontFilePath) {
        this.readerSystemFontFamily = ReaderSystemFontHelper.applyToStorage(this.getUIContext());
      }
      this.registerReaderFont();
    }, delayMs);
  }

  aboutToDisappear() {
    this.resetReaderScreenOrientation();
    ReaderProgressCheckpoint.detach(this.ttsFloatingSessionOwnerId);
    this.readerPageVisible = false;
    this.resetReaderPageCurl();
    if (this.readerExtendLayoutRefreshTimerId >= 0) {
      clearTimeout(this.readerExtendLayoutRefreshTimerId);
      this.readerExtendLayoutRefreshTimerId = -1;
    }
    this.readerExtendLayoutReadingOffset = -1;
    this.flushPendingReaderLayoutChange(false);
    this.releaseReaderScreenTimeout();
    this.shortcutRoutingActive = false;
    if (this.shelfOpeningEntryTimer >= 0) {
      clearTimeout(this.shelfOpeningEntryTimer);
      this.shelfOpeningEntryTimer = -1;
    }
    this.flushPendingTtsSpeedSettings();
    this.flushReadingProgressCheckpoint();
    if (!ReaderTtsFloatingSession.isOwner(this.ttsFloatingSessionOwnerId)) {
      this.stopTtsReading();
      this.ttsReader.shutdown();
    }
    if (!this.readerExitProgressSaved) {
      this.saveReadingProgress(true).then(() => {
        return CloudSyncCoordinator.syncAutomatically(
          getContext(this), CloudSyncCoordinator.TRIGGER_CHANGE);
      }).catch((error: Error) => {
        console.error('离开阅读页保存进度失败:', error);
      });
    }
    this.unregisterVolumeKeyTurn();
    this.exitReaderImmersive();
  }

  onLaunchShortcutChanged(): void {
    if (!this.shortcutRoutingActive) {
      return;
    }
    this.openPendingShortcut();
  }

  onPageHide(): void {
    this.shortcutRoutingActive = false;
    this.readerPageVisible = false;
    this.releaseReaderScreenTimeout();
    this.flushReadingProgressCheckpoint().catch((error: Error) => {
      console.warn('阅读页退到后台时保存进度失败:', error);
    });
  }

  async openPendingShortcut(): Promise<void> {
    if (!RecentReadShortcut.isPending()) {
      return;
    }
    this.saveReadingProgress(true).catch((error: Error) => {
      console.warn('快捷入口切换前保存进度失败:', error);
    });
    try {
      await RecentReadShortcut.openPending(getContext(this), true);
    } catch (e) {
      console.error('打开最近阅读快捷项失败:', e);
    }
  }

  enterReaderImmersive() {
    window.getLastWindow(getContext(this)).then((mainWindow: window.Window) => {
      const bg = this.getBackgroundColor();
      const useLightIcons = this.isReaderThemeDark();
      const systemTextColor = useLightIcons ? '#D8D8D8' : '#2F261D';
      const comicMode = this.isReaderComicModeActive();
      mainWindow.setWindowBackgroundColor(bg);
      mainWindow.setWindowLayoutFullScreen(true);
      mainWindow.setWindowSystemBarEnable(comicMode || !this.readerExtendToStatusBar ?
        ['navigation', 'status'] : ['navigation']);
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        isStatusBarLightIcon: useLightIcons,
        statusBarContentColor: systemTextColor,
        navigationBarColor: comicMode ? '#00000000' : bg,
        isNavigationBarLightIcon: useLightIcons,
        navigationBarContentColor: systemTextColor
      });
      this.updateStatusBarSafeHeight(mainWindow);
    }).catch((err: Error) => {
      console.error('进入阅读沉浸模式失败:', err);
    });
  }

  exitReaderImmersive() {
    window.getLastWindow(getContext(this)).then((mainWindow: window.Window) => {
      mainWindow.setWindowLayoutFullScreen(true);
      mainWindow.setWindowSystemBarEnable(['navigation', 'status']);
      this.statusBarSafeHeight = 0;
    }).catch((err: Error) => {
      console.error('退出阅读沉浸模式失败:', err);
    });
  }

  updateStatusBarSafeHeight(mainWindow: window.Window): void {
    const previousHeight = this.statusBarSafeHeight;
    try {
      const avoidArea = mainWindow.getWindowAvoidAreaIgnoringVisibility(window.AvoidAreaType.TYPE_SYSTEM);
      const topHeight = px2vp(Math.max(0, avoidArea.topRect.height));
      this.statusBarSafeHeight = topHeight > 0 ? topHeight : 32;
    } catch (err) {
      console.error('获取状态栏安全区失败:', err);
      this.statusBarSafeHeight = 32;
    }
    if (Math.abs(previousHeight - this.statusBarSafeHeight) >= 0.5 && this.hasPagedReaderArea() && this.content) {
      // The status-bar avoid area arrives asynchronously. In extended mode the reader area's
      // layout size itself does not change, so onAreaChange cannot trigger the required repagination.
      this.readerPaginationCache.clear();
      this.pageTurnPreviewKey = '';
      this.paginateContent(this.content);
    }
  }

  async loadBook() {
    const loadSerial = ++this.bookLoadSerial;
    this.isLoading = true;
    this.loadStatus = '正在加载...';
    this.resetReaderStateForBookLoad();
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      
      this.book = await db.getBook(this.bookUrl);
      if (loadSerial !== this.bookLoadSerial) {
        return;
      }
      if (!this.book) {
        this.setReaderContent('书籍不存在，请先从搜索结果加入书架。');
        this.isLoading = false;
        return;
      }
      const sourceForType = this.book.origin && this.book.origin !== 'local' ?
        await db.getBookSource(this.book.origin) : null;
      BookTypeSupport.applyBookType(this.book, sourceForType);
      if (BookTypeSupport.isAudio(this.book)) {
        await db.updateBook(this.book, false);
        await router.replaceUrl({
          url: 'pages/AudioBook',
          params: {
            bookUrl: this.book.bookUrl,
            shelfBookOpening: this.openedWithShelfAnimation ? 'true' : 'false',
            shortcutEntry: this.openedFromShortcut ? 'true' : 'false',
            shortcutReplace: this.shortcutReplacedPreviousPage ? 'true' : 'false'
          }
        });
        return;
      }
      if (LocalBookService.isWebDavBook(this.book)) {
        this.loadStatus = '正在检查 WebDAV 书籍...';
        this.book = await WebDavBookService.ensureCached(getContext(this), this.book,
          (message: string): void => {
            this.loadStatus = message;
          });
      }
      if (this.book.origin === LocalBookService.ORIGIN) {
        this.loadStatus = '正在优化本地书籍...';
        const rebuilt = await LocalBookService.ensureLocalParserCurrent(getContext(this), this.book);
        if (rebuilt) {
          const rebuiltBook = await db.getBook(this.bookUrl);
          if (rebuiltBook) this.book = rebuiltBook;
        }
      }
      if (loadSerial !== this.bookLoadSerial) {
        return;
      }
      if (Book.hasStartedReading(this.book)) {
        await this.markBookRecentlyRead();
      }

      const engine = ReadBookEngine.get();
      await engine.openBook(this.book);
      if (loadSerial !== this.bookLoadSerial) {
        return;
      }
      this.book = engine.book || this.book;
      this.chapters = engine.chapters;
      this.initializeReaderComicMode();
      const activeTtsChapterIndex = this.activeMirroredTtsChapterIndex();
      const savedChapterIndex = activeTtsChapterIndex >= 0 ? activeTtsChapterIndex : engine.curIdx;
      this.currentChapterIndex = this.clampChapterIndex(savedChapterIndex);
      const savedPosition = this.currentChapterIndex === savedChapterIndex ? Math.max(0, engine.curPos) : 0;
      this.pendingRestorePageIndex = savedPosition;
      this.readerLightThemeIndex = ReaderThemeHelper.normalizeIndex(this.readerLightThemeIndex);
      this.readerDarkThemeIndex = ReaderThemeHelper.normalizeIndex(this.readerDarkThemeIndex);

      if (this.chapters.length > 0) {
        await this.loadContent();
        await this.syncMirroredTtsFocus();
      } else if (this.book.origin !== 'local' && this.book.origin) {
        this.setReaderContent(`《${this.book.name}》\n\n作者：${this.book.author || '未知'}\n来源：${this.book.originName || this.book.origin}\n\n正在尝试解析目录...`);
        this.loadStatus = '正在获取目录...';
        await this.retryFetchChapters();
      } else {
        this.setReaderContent(this.buildBookPreview());
        this.isLoading = false;
      }
    } catch (e) {
      console.error('加载书籍失败:', e);
      this.setReaderContent('书籍或目录加载失败。请点击右上角“更多操作”，选择“重试”重新加载。');
      this.isLoading = false;
    } finally {
      this.updatePendingVerification();
    }
  }

  async retryFetchChapters() {
    try {
      const engine = ReadBookEngine.get();
      await engine.refreshToc();
      this.book = engine.book || this.book;
      this.chapters = engine.chapters;
      if (this.chapters.length > 0) {
        this.loadStatus = '';
        await this.loadContent();
      } else {
        this.updatePendingVerification();
        this.setReaderContent(this.buildBookPreview());
        this.isLoading = false;
      }
    } catch (e) {
      console.error('重试获取目录失败:', e);
      this.updatePendingVerification();
      this.setReaderContent(this.buildBookPreview());
      this.isLoading = false;
    }
  }

  resetReaderStateForBookLoad(): void {
    this.contentLoadSerial++;
    this.content = '';
    this.chapters = [];
    this.tocVisibleChapters = [];
    this.tocWindowStart = 0;
    this.tocSearchVisible = false;
    this.tocSearchQuery = '';
    this.tocSearchChapterIndexes = [];
    this.tocSearchLoading = false;
    this.tocSearchResultActive = false;
    this.tocDatabaseChapterCount = 0;
    this.tocFirstVisibleGlobalIndex = 0;
    this.tocVisibleItemCount = 1;
    this.tocSearchRequestSerial++;
    this.currentChapterIndex = 0;
    this.contentPages = [];
    this.contentPageStarts = [];
    this.contentPageEnds = [];
    this.pagedContentText = '';
    this.readerPaginationCache.clear();
    this.readerParagraphMetricsCache.clear();
    if (this.readerExtendLayoutRefreshTimerId >= 0) {
      clearTimeout(this.readerExtendLayoutRefreshTimerId);
      this.readerExtendLayoutRefreshTimerId = -1;
    }
    this.readerExtendLayoutReadingOffset = -1;
    this.resetReaderPageCurl();
    this.adjacentPaginationPreloadSerial++;
    this.currentPageIndex = 0;
    this.currentPageText = '';
    this.displayPageText = '';
    this.displayPageChapterIndex = 0;
    this.displayPageIndex = 0;
    this.displayPageRenderKey = 0;
    this.chapterJumpRenderGeneration = 0;
    this.readerCommentPanelMarker = '';
    this.readerCommentPanelAnchorBottom = -1;
    this.readerCommentPageAreaTop = -1;
    this.readerCommentPageAreaHeight = 0;
    this.pageViewWidth = 0;
    this.pageViewHeight = 0;
    this.readerInitialPageReady = false;
    this.readerComicMode = false;
    this.readerComicImageRatios = [];
    this.clearReaderComicPaginationProgress();
    this.readerComicChapterSwitching = false;
    this.readerComicBoundaryDirection = 0;
    this.readerComicBoundaryPullDistance = 0;
    this.readerComicBoundaryReady = false;
    this.readerComicChapterTransitionY = 0;
    this.readerComicChapterTransitionOpacity = 1;
    this.readerComicBoundaryPullOriginY = 0;
    this.readerComicScrollRestoreSerial++;
    this.readerComicScrollRestoring = false;
    this.clearReaderComicProgressSaveTimer();
    this.readerComicPageDataSource.replace([]);
    this.pendingRestorePageIndex = -1;
    this.pageTransitionX = 0;
    this.pageTransitionOpacity = 1;
    this.pageSlideOffsetX = 0;
    this.pageSlideOffsetY = 0;
    this.pageSlideDirection = 0;
    this.bookmarkPullOffsetY = 0;
    this.bookmarkPullActive = false;
    this.bookmarkPullReady = false;
    this.pageTurnAnimating = false;
    this.pageTurnIncomingText = '';
    this.pageTurnIncomingSecondaryText = '';
    this.pageTurnIncomingX = 0;
    this.pageTurnIncomingOpacity = 1;
    this.pageTurnIncomingPageIndex = 0;
    this.pageTurnIncomingChapterIndex = 0;
    this.pageTurnIncomingPageStart = -1;
    this.pageTurnIncomingSecondaryPageStart = -1;
    this.pageTurnIncomingDocumentSource = '';
    this.pageTurnIncomingRenderVersion = 0;
    this.isPageTurning = false;
    this.queuedPageTurnDirection = 0;
    this.queuedPageTurnStyle = '';
    this.queuedPageTurnCount = 0;
    this.queuedPageTurnVelocity = 0;
    this.pageTurnCrossChapterHandoff = false;
    this.clearPageTurnPreviewState();
    this.clearTtsHighlight();
    this.pageRenderVersion++;
  }

  async loadContent(silent: boolean = false, targetChapterIndex: number = this.currentChapterIndex,
    preferImmediatePagination: boolean = false) {
    if (this.chapters.length === 0) {
      this.setReaderContent(this.buildBookPreview());
      this.isLoading = false;
      return;
    }
    
    const engine = ReadBookEngine.get();
    const chapterIndex = this.clampChapterIndex(targetChapterIndex);
    const loadSerial = ++this.contentLoadSerial;
    const showLoading = !silent && !engine.hasCachedContent(chapterIndex);
    if (showLoading) {
      this.isLoading = true;
      this.loadStatus = '正在加载章节内容...';
    }
    try {
      const body = await engine.loadContent(chapterIndex);
      if (loadSerial !== this.contentLoadSerial) {
        return;
      }
      this.currentChapterIndex = chapterIndex;
      this.closeReaderCommentPanel();
      this.readerComicImageRatios = [];
      let loadedContent = await this.prepareReaderContentRules(body, chapterIndex);
      if (loadSerial !== this.contentLoadSerial) {
        return;
      }
      if (body) {
        this.content = loadedContent;
        this.chapters = [...engine.chapters];
      } else {
        this.updatePendingVerification();
        const c = this.chapters[chapterIndex];
        loadedContent = this.verificationUrl ? `${c ? c.title : '当前章节'}\n\n该书源需要先完成网页验证。请点击右上角“更多操作”，选择“登录”，完成后返回，再从该菜单选择“重试”。` :
          (c ? `${c.title}\n\n章节正文加载失败。请点击右上角“刷新本章”或“换源”。` :
            '章节正文加载失败。请点击右上角“更多操作”，选择“重试”。');
        this.content = loadedContent;
      }
      this.detectReaderComicMode(loadedContent);
      let restoredPagination = body ?
        this.applyPreparedReaderPagination(loadedContent, chapterIndex, preferImmediatePagination) : false;
      if (body && !restoredPagination && !preferImmediatePagination) {
        restoredPagination = await this.restorePersistedReaderPagination(loadedContent, chapterIndex);
      }
      if (loadSerial !== this.contentLoadSerial) {
        return;
      }
      if (!restoredPagination) {
        this.paginateContent(loadedContent, chapterIndex);
      }
      this.preloadReaderContent();
    } catch (e) {
      console.error('加载内容失败:', e);
    } finally {
      if (loadSerial === this.contentLoadSerial && !silent) {
        this.isLoading = false;
        this.loadStatus = '';
      }
      this.updatePendingVerification();
    }
  }

  async refreshCurrentChapter(): Promise<void> {
    if (this.chapters.length === 0) {
      return;
    }

    const engine = ReadBookEngine.get();
    this.isLoading = true;
    this.loadStatus = '正在刷新本章...';
    try {
      const body = await engine.reloadContent(this.currentChapterIndex);
      if (body) {
        const processedBody = await this.prepareReaderContentRules(body, this.currentChapterIndex);
        this.readerComicImageRatios = [];
        this.content = processedBody;
        this.detectReaderComicMode(processedBody);
        this.chapters = [...engine.chapters];
        this.pendingRestorePageIndex = 0;
        this.currentPageIndex = 0;
        this.paginateContent(processedBody);
        this.preloadReaderContent();
        await this.saveReadingProgress();
        promptAction.showToast({ message: '本章已刷新' });
      } else {
        this.updatePendingVerification();
        const chapter = this.chapters[this.currentChapterIndex];
        const loadedContent = this.verificationUrl ? `${chapter ? chapter.title : '当前章节'}\n\n该书源需要先完成网页验证。请点击右上角“更多操作”，选择“登录”，完成后返回，再从该菜单选择“重试”。` :
          (chapter ? `${chapter.title}\n\n章节正文刷新失败。请再次点击右上角“刷新本章”或“换源”。` :
            '章节正文刷新失败。请点击右上角“更多操作”，选择“重试”。');
        this.content = loadedContent;
        this.paginateContent(loadedContent);
        promptAction.showToast({ message: '刷新本章失败' });
      }
    } catch (e) {
      console.error('刷新本章失败:', e);
      promptAction.showToast({ message: '刷新本章失败' });
    } finally {
      this.isLoading = false;
      this.loadStatus = '';
      this.updatePendingVerification();
    }
  }

  onFullTextCacheCancelNonceChanged(): void {
    const nonce = this.fullTextCacheCancelNonce || 0;
    if (this.fullTextCaching && nonce > 0 && nonce !== this.fullTextCacheCancelSeenNonce) {
      this.fullTextCacheCancelRequested = true;
      this.fullTextCacheCancelSeenNonce = nonce;
    }
  }

  startFullTextCache(): void {
    if (this.fullTextCaching) {
      promptAction.showToast({ message: this.fullTextCacheStatus || '全文缓存正在后台进行' });
      return;
    }
    if (!this.book || this.chapters.length === 0 || !this.book.origin || this.book.origin === 'local') {
      promptAction.showToast({ message: '当前书籍暂无可缓存章节' });
      return;
    }

    this.hideReaderPanels();
    promptAction.showToast({ message: '已转入后台缓存，可在通知栏取消' });
    this.runFullTextCache(++this.fullTextCacheTaskId).catch((error: Error) => {
      console.error('全文缓存任务失败:', error);
      this.fullTextCaching = false;
      this.fullTextCacheStatus = '全文缓存失败';
      promptAction.showToast({ message: '全文缓存失败' });
      this.publishFullTextCacheNotification('全文缓存失败', this.fullTextCacheProgressText(), false).catch((e: Error) => {
        console.warn('更新全文缓存失败通知失败:', e);
      });
      this.stopFullTextCacheBackgroundRunning().catch((e: Error) => {
        console.warn('停止全文缓存后台任务失败:', e);
      });
    });
  }

  async runFullTextCache(taskId: number): Promise<void> {
    const engine = ReadBookEngine.get();
    if (!engine.book || engine.chapters.length === 0) {
      return;
    }

    this.fullTextCaching = true;
    this.fullTextCacheCancelRequested = false;
    this.fullTextCacheCancelSeenNonce = AppStorage.get<number>('fullTextCacheCancelNonce') || 0;
    this.fullTextCacheNotificationLastAt = 0;
    this.fullTextCacheCancelAgent = null;
    await engine.syncChapterCacheDates();
    this.chapters = [...engine.chapters];
    this.fullTextCacheTotal = engine.chapters.length;
    this.fullTextCacheDone = this.countCachedChapters(engine.chapters);
    this.fullTextCacheStatus = '全文缓存后台进行中';

    await this.startFullTextCacheBackgroundRunning();
    await this.requestFullTextCacheNotificationEnabled();
    await this.publishFullTextCacheProgress(true);

    for (let index = 0; index < engine.chapters.length; index++) {
      if (taskId !== this.fullTextCacheTaskId || this.shouldCancelFullTextCache()) {
        break;
      }
      const chapter = engine.chapters[index];
      if (!chapter || chapter.cacheDate > 0) {
        continue;
      }

      const ok = await this.cacheFullTextChapter(engine, index, taskId);
      if (taskId !== this.fullTextCacheTaskId) {
        break;
      }
      if (ok) {
        this.fullTextCacheDone = this.countCachedChapters(engine.chapters);
        this.chapters = [...engine.chapters];
      }
      await this.publishFullTextCacheProgress(false);
      await this.sleep(0);
    }

    if (taskId !== this.fullTextCacheTaskId) {
      return;
    }

    const canceled = this.shouldCancelFullTextCache();
    await engine.syncChapterCacheDates();
    this.chapters = [...engine.chapters];
    this.fullTextCacheDone = this.countCachedChapters(engine.chapters);
    this.fullTextCaching = false;
    const failedCount = Math.max(0, this.fullTextCacheTotal - this.fullTextCacheDone);
    this.fullTextCacheStatus = canceled ? '全文缓存已取消' :
      (failedCount > 0 ? `缓存结束，${failedCount} 章未缓存` : '全文缓存完成');
    this.fullTextCacheCancelRequested = false;
    await this.publishFullTextCacheNotification(
      canceled ? '缓存已停止' : this.fullTextCacheStatus,
      this.fullTextCacheProgressText(),
      false
    );
    if (canceled) {
      promptAction.showToast({ message: '缓存已停止' });
    } else {
      promptAction.showToast({ message: '全文缓存完成' });
    }
    await this.stopFullTextCacheBackgroundRunning();
  }

  shouldCancelFullTextCache(): boolean {
    if (this.fullTextCacheCancelRequested) {
      return true;
    }
    const nonce = AppStorage.get<number>('fullTextCacheCancelNonce') || 0;
    if (nonce > 0 && nonce !== this.fullTextCacheCancelSeenNonce) {
      this.fullTextCacheCancelRequested = true;
      this.fullTextCacheCancelSeenNonce = nonce;
      return true;
    }
    return false;
  }

  clearReaderScreenTimeoutTimer(): void {
    if (this.readerScreenTimeoutTimerId >= 0) {
      clearTimeout(this.readerScreenTimeoutTimerId);
      this.readerScreenTimeoutTimerId = -1;
    }
  }

  applyReaderScreenTimeout(): void {
    this.clearReaderScreenTimeoutTimer();
    const serial = ++this.readerScreenTimeoutSerial;
    if (!this.readerPageVisible) {
      this.setReaderWindowKeepScreenOn(false, serial);
      return;
    }
    const minutes = ReaderSettingsStore.normalizeScreenTimeoutMinutes(this.readerScreenTimeoutMinutes);
    if (minutes === ReaderSettingsStore.SCREEN_TIMEOUT_FOLLOW_SYSTEM) {
      this.setReaderWindowKeepScreenOn(false, serial);
      return;
    }
    this.setReaderWindowKeepScreenOn(true, serial);
    if (minutes > 0) {
      this.readerScreenTimeoutTimerId = setTimeout(() => {
        if (serial !== this.readerScreenTimeoutSerial) {
          return;
        }
        this.readerScreenTimeoutTimerId = -1;
        this.setReaderWindowKeepScreenOn(false, serial);
      }, minutes * 60 * 1000);
    }
  }

  refreshReaderScreenTimeout(): void {
    if (this.readerPageVisible && this.readerScreenTimeoutMinutes > 0) {
      this.applyReaderScreenTimeout();
    }
  }

  releaseReaderScreenTimeout(): void {
    this.clearReaderScreenTimeoutTimer();
    const serial = ++this.readerScreenTimeoutSerial;
    this.setReaderWindowKeepScreenOn(false, serial);
  }

  setReaderWindowKeepScreenOn(enabled: boolean, serial: number): void {
    window.getLastWindow(getContext(this)).then((mainWindow: window.Window) => {
      if (serial !== this.readerScreenTimeoutSerial) {
        return;
      }
      mainWindow.setWindowKeepScreenOn(enabled).catch((error: Error) => {
        console.warn('设置阅读页亮屏状态失败:', error);
      });
    }).catch((error: Error) => {
      console.warn('获取阅读页窗口失败:', error);
    });
  }

  async cacheFullTextChapter(engine: ReadBookEngine, chapterIndex: number, taskId: number): Promise<boolean> {
    for (let attempt = 0; attempt < 2; attempt++) {
      if (taskId !== this.fullTextCacheTaskId || this.shouldCancelFullTextCache()) {
        return false;
      }
      try {
        if (await engine.cacheChapter(chapterIndex)) {
          return true;
        }
      } catch (error) {
        console.warn(`缓存第 ${chapterIndex + 1} 章失败（第 ${attempt + 1} 次）:`, error);
      }
      if (attempt === 0) {
        await this.sleep(300);
      }
    }
    return false;
  }

  countCachedChapters(chapters: BookChapter[]): number {
    let count = 0;
    for (const chapter of chapters) {
      if (chapter.cacheDate > 0) {
        count++;
      }
    }
    return count;
  }

  fullTextCacheProgressText(): string {
    const total = Math.max(this.fullTextCacheTotal, 0);
    if (total === 0) {
      return '正在准备缓存章节';
    }
    const done = Math.max(0, Math.min(this.fullTextCacheDone, total));
    const percent = Math.floor((done / total) * 100);
    return `已缓存 ${done}/${total} 章（${percent}%）`;
  }

  async publishFullTextCacheProgress(force: boolean): Promise<void> {
    const now = Date.now();
    if (!force && now - this.fullTextCacheNotificationLastAt < FULL_TEXT_CACHE_NOTIFICATION_INTERVAL_MS) {
      return;
    }
    this.fullTextCacheNotificationLastAt = now;
    await this.publishFullTextCacheNotification(this.fullTextCacheStatus || '全文缓存后台进行中',
      this.fullTextCacheProgressText(), true);
  }

  async publishFullTextCacheNotification(text: string, additionalText: string, ongoing: boolean): Promise<void> {
    try {
      const request: notificationManager.NotificationRequest = {
        id: 2601,
        label: 'full_text_cache',
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        isOngoing: ongoing,
        tapDismissed: false,
        isAlertOnce: true,
        autoDeletedTime: ongoing ? undefined : Date.now() + 5000,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: this.book?.name ? `缓存全文：${this.book.name}` : '缓存全文',
            text: text,
            additionalText: additionalText
          }
        }
      };
      if (ongoing) {
        request.actionButtons = [{
          title: '×',
          wantAgent: await this.getFullTextCacheCancelWantAgent()
        }];
      }
      await notificationManager.publish(request);
    } catch (error) {
      console.warn('发布全文缓存通知失败:', error);
    }
  }

  async requestFullTextCacheNotificationEnabled(): Promise<void> {
    try {
      if (await notificationManager.isNotificationEnabled()) {
        return;
      }
      await notificationManager.requestEnableNotification(getContext(this) as common.UIAbilityContext);
    } catch (error) {
      console.warn('请求通知权限失败:', error);
    }
  }

  async getFullTextCacheCancelWantAgent(): Promise<WantAgent> {
    if (this.fullTextCacheCancelAgent) {
      return this.fullTextCacheCancelAgent;
    }
    const context = getContext(this) as common.UIAbilityContext;
    this.fullTextCacheCancelAgent = await wantAgent.getWantAgent({
      wants: [{
        bundleName: context.abilityInfo.bundleName,
        abilityName: 'EntryAbility',
        parameters: {
          cacheAction: 'cancelFullTextCache',
          cacheTaskId: this.fullTextCacheTaskId
        }
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 2602,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    return this.fullTextCacheCancelAgent;
  }

  async startFullTextCacheBackgroundRunning(): Promise<void> {
    if (this.fullTextCacheBackgroundRunning) {
      return;
    }
    if (this.ttsBackgroundRunning) {
      this.fullTextCacheBackgroundRunning = true;
      return;
    }
    try {
      const agent = await this.createFullTextCacheOpenWantAgent();
      await backgroundTaskManager.startBackgroundRunning(getContext(this), ['dataTransfer'], agent);
      this.fullTextCacheBackgroundRunning = true;
    } catch (error) {
      console.warn('启动全文缓存后台任务失败:', error);
    }
  }

  async stopFullTextCacheBackgroundRunning(): Promise<void> {
    if (!this.fullTextCacheBackgroundRunning) {
      return;
    }
    this.fullTextCacheBackgroundRunning = false;
    if (this.ttsBackgroundRunning || this.ttsBackgroundRequesting) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(getContext(this));
    } catch (error) {
      console.warn('停止全文缓存后台任务失败:', error);
    }
  }

  async createFullTextCacheOpenWantAgent(): Promise<WantAgent> {
    const context = getContext(this) as common.UIAbilityContext;
    return await wantAgent.getWantAgent({
      wants: [{
        bundleName: context.abilityInfo.bundleName,
        abilityName: 'EntryAbility',
        parameters: {
          bookUrl: this.bookUrl || ''
        }
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 2603,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
  }

  sleep(ms: number): Promise<void> {
    return new Promise((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  shouldRenderPrimaryReaderContent(): boolean {
    return !this.isLoading || !!this.content;
  }

  isPagedReaderAwaitingPagination(): boolean {
    return !!this.content && this.contentPages.length === 0;
  }

  shouldShowReaderLoadingOverlay(): boolean {
    return this.shouldRenderPrimaryReaderContent() &&
      (this.isLoading || this.isPagedReaderAwaitingPagination() || !this.readerInitialPageReady);
  }

  shouldBlockReaderInteraction(): boolean {
    return this.isLoading || this.isPagedReaderAwaitingPagination() || !this.readerInitialPageReady ||
      this.readerComicPaginationParsing;
  }

  getReaderLoadingText(): string {
    if (this.pendingRestorePageIndex >= 0) {
      return '正在恢复阅读进度...';
    }
    if (this.isPagedReaderAwaitingPagination() && !this.isLoading) {
      return '正在排版...';
    }
    return this.loadStatus || '加载中...';
  }

  @Builder
  readerLoadingPanel() {
    Column() {
      LoadingProgress()
        .width(40)
        .height(40)
      Text(this.getReaderLoadingText())
        .fontSize(14)
        .fontColor('#999')
        .margin({ top: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.readerContentLayerColor())
  }

  @Builder
  readerComicPaginationPanel() {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(44)
        .height(44)
        .color(this.accentColor())
      Text('正在解析漫画')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.getTextColor())
      Text(`已解析 ${this.readerComicPaginationParsedPages} / ${this.readerComicPaginationTotalPages} 页`)
        .fontSize(13)
        .fontColor(this.isReaderThemeDark() ? '#AEB4BE' : '#777777')
      Progress({
        value: this.readerComicPaginationParsedPages,
        total: Math.max(1, this.readerComicPaginationTotalPages),
        type: ProgressType.Linear
      })
        .width(196)
        .height(4)
        .color(this.accentColor())
        .backgroundColor(this.isReaderThemeDark() ? '#3A3D43' : '#DDD8D0')
      Text('解析完成后自动开始阅读')
        .fontSize(12)
        .fontColor(this.isReaderThemeDark() ? '#858B94' : '#999999')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.getBackgroundColor())
  }

  @Builder
  readerComicScrollSurface() {
    Stack() {
      List({ space: 0, scroller: this.readerComicScroller }) {
        LazyForEach(this.readerComicPageDataSource, (page: string, index: number) => {
          ListItem() {
            if (this.isReaderImageOnlyPage(page)) {
              Image(this.getReaderEpubImageUri(page))
                .width('100%')
                .height(this.getReaderComicImageRenderHeight(index))
                .margin({ top: -this.getReaderComicImageSeamOverlap(index) })
                .objectFit(this.getReaderComicImageFit(index))
                .draggable(false)
                .onAppear(() => {
                  this.ensureReaderComicImageRatio(index, page).catch((error: Error) => {
                    console.warn('预读取漫画图片尺寸失败:', error);
                  });
                })
                .onComplete((event) => {
                  if (event) {
                    this.updateReaderComicImageRatio(index, event.width, event.height);
                  }
                })
            } else if (this.isReaderNovelContinuousScrollModeActive()) {
              Column() {
                this.styledReaderText(
                  page,
                  index === this.contentPages.length - 1 ? this.readerMarginBottom : 0,
                  this.currentChapterIndex,
                  0,
                  this.pageRenderVersion,
                  `reader_vertical_scroll_${this.currentChapterIndex}_${index}`,
                  index,
                  index === 0 ? this.readerMarginTop : 0
                )
              }
              .width('100%')
            } else {
              Column() {
                this.styledReaderText(page, this.getReaderContentBottomPadding(), this.currentChapterIndex,
                  0, this.pageRenderVersion, `reader_comic_fallback_${this.currentChapterIndex}_${index}`, index)
              }
              .width('100%')
              .constraintSize({ minHeight: this.pageViewHeight })
            }
          }
          .width('100%')
        }, (page: string, index: number) => `${this.currentChapterIndex}_${index}_${this.hashText(page)}`)
      }
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .translate({ y: this.readerComicChapterTransitionY })
      .opacity(this.readerComicChapterTransitionOpacity)
      .onScrollIndex((start: number, end: number) => {
        this.onReaderComicScrollIndexChanged(start, end);
      })

      Column() {
        Blank()
          .layoutWeight(1)
        this.readerBottomInfoBar()
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)

      if (this.readerComicBoundaryDirection !== 0 || this.readerComicChapterSwitching) {
        this.readerComicBoundaryHint()
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .opacity(this.readerInitialPageReady ? 1 : 0)
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.updatePagedReaderArea(newValue);
      this.rememberReaderTapLayerArea(newValue);
    })
    .priorityGesture(
      GestureGroup(GestureMode.Exclusive,
        LongPressGesture({ duration: 600 })
          .onAction((event: GestureEvent) => {
            if (this.isReaderNovelContinuousScrollModeActive()) {
              this.selectReaderTextAtGlobalPoint(event);
            }
          }),
        PanGesture({ direction: PanDirection.Vertical, distance: this.readerTapSlop })
          .onActionStart(() => {
            if (!this.isReaderNovelContinuousScrollModeActive()) return;
            this.beginReaderComicPan();
          })
          .onActionUpdate((event: GestureEvent) => {
            if (!this.isReaderNovelContinuousScrollModeActive()) return;
            this.updateReaderComicPan(event);
          })
          .onActionEnd((event: GestureEvent) => {
            if (!this.isReaderNovelContinuousScrollModeActive()) return;
            this.finishReaderComicPan(event);
          })
          .onActionCancel(() => {
            this.cancelReaderComicPan();
          }),
        TapGesture()
          .onAction((event: GestureEvent) => {
            if (!this.isReaderNovelContinuousScrollModeActive()) return;
            if (event.fingerList.length > 0) {
              const finger = event.fingerList[0];
              const marker = this.readerSourceActionAtPoint(Number(finger.globalX), Number(finger.globalY));
              if (marker) {
                this.beginReaderInteractiveAction();
                this.openReaderSourceAction(marker);
                return;
              }
            }
            if (this.consumeSuppressedReaderTapClick()) return;
            if (Date.now() >= this.readerComicSuppressClickUntil &&
              !this.showMenu && !this.showToc && !this.showSettings) {
              this.showMenu = true;
            }
          })
      ),
      GestureMask.IgnoreInternal
    )
  }

  @Builder
  readerComicBoundaryHint() {
    Column() {
      if (this.readerComicBoundaryDirection < 0) {
        this.readerComicBoundaryHintContent()
      }
      Blank()
        .layoutWeight(1)
      if (this.readerComicBoundaryDirection > 0) {
        this.readerComicBoundaryHintContent()
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.readerComicBoundaryHintTopPadding(), bottom: 54 })
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.None)
  }

  readerComicBoundaryHintTopPadding(): number {
    // The continuous surface is already inset when body content does not extend into the status bar;
    // extended and comic layouts are not.
    // Add only the unconsumed safe-area height so the top hint never sits underneath status-bar content.
    const consumedTopInset = this.getReaderTopSafePadding();
    return Math.max(14, this.statusBarSafeHeight - consumedTopInset + 12);
  }

  @Builder
  readerComicBoundaryHintContent() {
    Row({ space: 8 }) {
      if (this.readerComicChapterSwitching) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color(this.accentColor())
      } else {
        SymbolGlyph(this.readerComicBoundaryDirection < 0 ?
          $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_up'))
          .fontSize(17)
          .fontColor([this.readerComicBoundaryReady ? this.accentColor() : this.getTextColor()])
      }
      Text(this.readerComicBoundaryHintText())
        .fontSize(13)
        .fontWeight(this.readerComicBoundaryReady || this.readerComicChapterSwitching ? FontWeight.Medium :
          FontWeight.Regular)
        .fontColor(this.readerComicBoundaryReady || this.readerComicChapterSwitching ?
          this.accentColor() : this.getTextColor())
    }
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .borderRadius(18)
    .backgroundColor(this.isReaderThemeDark() ? '#E61B1D20' : '#E6FFFFFF')
    .shadow({ radius: 10, color: this.isReaderThemeDark() ? '#66000000' : '#26000000', offsetY: 3 })
    .opacity(this.readerComicChapterSwitching ? 1 :
      Math.min(1, 0.35 + this.readerComicBoundaryPullDistance / 56))
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  readerComicInteractionLayer() {
    Blank()
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .onClick(() => {
      if (this.consumeSuppressedReaderTapClick()) {
        return;
      }
      if (Date.now() >= this.readerComicSuppressClickUntil &&
        !this.showMenu && !this.showToc && !this.showSettings) {
        this.showMenu = true;
      }
    })
    .gesture(
      PanGesture({ direction: PanDirection.Vertical, distance: this.readerTapSlop })
        .onActionStart(() => {
          if (this.isReaderInteractiveActionActive()) {
            return;
          }
          this.beginReaderComicPan();
        })
        .onActionUpdate((event: GestureEvent) => {
          if (this.isReaderInteractiveActionActive()) {
            return;
          }
          this.updateReaderComicPan(event);
        })
        .onActionEnd((event: GestureEvent) => {
          if (this.isReaderInteractiveActionActive()) {
            this.cancelReaderComicPan();
            return;
          }
          this.finishReaderComicPan(event);
        })
        .onActionCancel(() => {
          this.cancelReaderComicPan();
        })
    )
  }

  build() {
    Stack() {
      BookSourceStageRuntimeHost()
      ReaderThemeBackground({
        surfaceColor: this.getBackgroundColor(),
        backgroundAssetId: this.getBackgroundAssetId(),
        customImage: this.currentReaderTheme().backgroundImageUri,
        customImageFit: this.getBackgroundImageFit(),
        viewportWidthHint: this.pageViewWidth,
        viewportHeightHint: this.getReaderBackgroundViewportHeight()
      })
        .id('reader_theme_background_root')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .hitTestBehavior(HitTestMode.None)

      Column() {
        if (!this.shouldRenderPrimaryReaderContent()) {
          this.readerLoadingPanel()
        } else if (this.isReaderContinuousScrollSurfaceActive()) {
          this.readerComicScrollSurface()
        } else {
          Stack() {
            ForEach(this.currentReaderSurfaceKeys(), (_surfaceKey: string) => {
              if (this.currentReaderSurfaceIndex() === 0) {
                if (this.isPageTurnAnimationEnabled()) {
                  this.readerSlidingPageTurnSurface(this.visibleCurrentPageText(), this.pageRenderVersion,
                    this.ttsHighlightRenderVersion)
                } else {
                  this.readerCurrentPageSurface(this.pageRenderVersion, this.visibleCurrentPageText(),
                    this.ttsHighlightRenderVersion)
                }
              } else {
                if (this.isPageTurnAnimationEnabled()) {
                  this.readerSlidingPageTurnSurfaceAlternate(this.visibleCurrentPageText(), this.pageRenderVersion,
                    this.ttsHighlightRenderVersion)
                } else {
                  this.readerCurrentPageSurfaceAlternate(this.pageRenderVersion, this.visibleCurrentPageText(),
                    this.ttsHighlightRenderVersion)
                }
              }
            }, (surfaceKey: string) => surfaceKey)
            Column() {
              Blank()
                .layoutWeight(1)
              this.readerBottomInfoBar()
            }
            .width('100%')
            .height('100%')
            .hitTestBehavior(HitTestMode.None)
          }
          .width('100%')
          .height('100%')
          .clip(true)
          .opacity(this.readerInitialPageReady ? 1 : 0)
          .onAreaChange((oldValue: Area, newValue: Area) => {
            this.updatePagedReaderArea(newValue);
            this.rememberReaderTapLayerArea(newValue);
          })
        }
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.getReaderTopSafePadding() })
      .backgroundColor(this.readerContentLayerColor())
      .hitTestBehavior(HitTestMode.Default)

      if (!this.isReaderContinuousScrollSurfaceActive() && !this.showMenu && !this.showToc && !this.showSettings &&
        !this.shouldBlockReaderInteraction()) {
        this.readerTapLayer()
      }

      if (this.readerComicPaginationParsing) {
        this.readerComicPaginationPanel()
      } else if (this.shouldShowReaderLoadingOverlay()) {
        this.readerLoadingPanel()
      }

      if (this.isReaderContinuousScrollSurfaceActive() && !this.isReaderNovelContinuousScrollModeActive() &&
        !this.showMenu && !this.showToc && !this.showSettings &&
        !this.shouldBlockReaderInteraction() && !this.readerComicChapterSwitching) {
        this.readerComicInteractionLayer()
      }

      if (this.bookmarkPullActive) {
        this.readerBookmarkPullHint()
      }

      if (this.isCurrentPageBookmarked() && !this.showMenu && !this.showToc && !this.showSettings) {
        this.readerCurrentPageBookmarkMarker()
      }

      if (this.showMenu && !this.showToc && !this.showSettings) {
        this.menuDismissLayer()
      }

      if (this.showSettings) {
        this.settingsDismissLayer()
      }

      if (this.showMenu) {
        this.readerFloatingTopMenu()
      }

      if (this.showMenu && this.showReaderActionMenu && !this.showToc && !this.showSettings) {
        this.readerActionMenu()
      }

      if (this.showLayoutElementSettings) {
        this.readerLayoutElementSettingsDialog()
      }

      if (this.showTxtCharsetDialog) {
        this.readerTxtCharsetDialog()
      }

      if (this.showMenu && !this.showToc && !this.showSettings && this.chapters.length > 0) {
        if (this.supportsReaderImmersiveMaterial()) {
          if (this.hdsMaterialRenderBranch) {
            this.readerHdsFloatingBottomMenu()
          } else {
            this.readerHdsFloatingBottomMenu()
          }
        } else {
          this.readerFloatingBottomMenu()
        }
        if (this.readerUseTtsQuickAction && !this.isReaderComicModeActive() && !this.ttsMediaControlsExpanded &&
          !this.isTtsSpeaking && !this.ttsReader.isSpeaking() && !this.globalTtsActive) {
          this.readerTtsQuickActionButton()
        }
        if (this.readerUseTtsQuickAction && this.shouldShowTtsMediaControls()) {
          if (this.hdsMaterialRenderBranch) {
            this.ttsExpandedMediaControlsBar()
          } else {
            this.ttsExpandedMediaControlsBar()
          }
        }
      }

      if (this.showToc) {
        this.readerFloatingTocPanel()
        if (this.supportsReaderImmersiveMaterial()) {
          if (this.hdsMaterialRenderBranch) {
            this.readerHdsFloatingActionBar(true)
          } else {
            this.readerHdsFloatingActionBar(true)
          }
        }
      }

      if (this.showSettings) {
        this.settingsPanel()
        if (this.showTtsVoiceDropdown) {
          this.ttsVoiceDropdownPanel()
        }
        if (this.supportsReaderImmersiveMaterial()) {
          if (this.hdsMaterialRenderBranch) {
            this.readerHdsFloatingActionBar(false, true)
          } else {
            this.readerHdsFloatingActionBar(false, true)
          }
        }
      }

      if (this.readerUseTtsQuickAction && this.shouldShowTtsMiniPlayer()) {
        this.ttsMiniPlayer()
      } else if (this.readerUseTtsQuickAction && this.shouldShowGlobalTtsMiniPlayer()) {
        this.globalTtsMiniPlayer()
      }

      if (this.showTtsQuickPlayer) {
        this.ttsQuickPlayerOverlay()
      }

      if (this.globalTtsActive && this.showGlobalTtsQuickPlayer) {
        this.globalTtsQuickPlayerOverlay()
      }

      if (this.globalTtsActive && this.showGlobalTtsQuickPlayer && this.showGlobalTtsCatalog) {
        this.globalTtsCatalogOverlay()
      }

      if (this.showBookmarkActionMenu && this.pendingBookmarkAction) {
        this.bookmarkActionMenu()
      }

      if (this.showTapZoneSettings) {
        this.tapZoneSettingsDialog()
      }

      if (this.showChangeSourceDialog) {
        this.changeSourceDialog()
      }

      if (this.showReaderCommentPanel) {
        this.readerCommentPanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.readerContentLayerColor())
    .opacity(this.shelfOpeningEntryOpacity)
    .scale({ x: this.shelfOpeningEntryScale, y: this.shelfOpeningEntryScale })
    .expandSafeArea([SafeAreaType.SYSTEM], this.getReaderSafeAreaEdges())
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.refreshReaderScreenTimeout();
      }
    })
  }

  @Builder
  readerCommentPanel() {
    Stack() {
      Row()
        .width('100%')
        .height('100%')
        .backgroundColor(this.isReaderThemeDark() ? '#52000000' : '#26000000')
        .onClick(() => {
          this.closeReaderCommentPanel();
        })
      Column() {
        Stack({ alignContent: Alignment.Top }) {
          Web({ src: this.readerCommentPanelUrl, controller: this.readerCommentPanelController })
            .width('100%')
            .height(this.readerCommentPanelContentHeight())
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .onlineImageAccess(true)
            .imageAccess(true)
            .darkMode(this.appDarkMode ? WebDarkMode.On : WebDarkMode.Off)
            .forceDarkAccess(this.appDarkMode)
            .onControllerAttached(() => {
              this.readerCommentPanelHtmlLoaded = false;
              setTimeout(() => this.loadReaderCommentPanelHtmlIfNeeded(), 0);
            })
            .onPageBegin(() => {
              this.readerCommentPanelLoading = true;
            })
            .onPageEnd(() => {
              if (this.loadReaderCommentPanelHtmlIfNeeded()) return;
              this.scheduleReaderCommentPanelHostReady(0);
            })
          this.readerCommentPanelDragHandle()
        }
        .width('100%')
        .height(this.readerCommentPanelContentHeight())
      }
      .width('100%')
      .backgroundColor(this.readerGlassPanelColor())
      .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
      .borderRadius({
        topLeft: ThemeRuntime.glassCornerRadius(28, 'panel'),
        topRight: ThemeRuntime.glassCornerRadius(28, 'panel')
      })
      .clip(true)
      .height(this.readerCommentPanelHeight())
      .opacity(this.readerCommentPanelLoading ? 0 : 1)

      if (this.readerCommentPanelLoading) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(38)
            .height(38)
            .color(this.accentColor())
          Text('评论加载中…')
            .fontSize(13)
            .fontColor(this.getTextColor())
        }
        .width('100%')
        .height(this.readerCommentPanelHeight())
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Bottom)
  }

  @Builder
  readerCommentPanelDragHandle() {
    Column() {
      Row()
        .width(34)
        .height(3)
        .borderRadius(1.5)
        .borderWidth(0)
        .backgroundColor(this.isReaderThemeDark() ? '#66FFFFFF' : '#33000000')
    }
    .width('100%')
    .height(this.readerCommentPanelDragHandleHeight())
    .backgroundColor('#00000000')
    .borderWidth(0)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .zIndex(2)
    .accessibilityText('上滑展开评论面板')
    .gesture(
      PanGesture({ direction: PanDirection.Vertical, distance: 2 })
        .onActionStart(() => {
          this.readerCommentPanelDragStartRatio = this.readerCommentPanelHeightRatio;
        })
        .onActionUpdate((event: GestureEvent) => {
          const viewportHeight = Math.max(1, this.readerCommentPageAreaHeight || this.pageViewHeight);
          const nextRatio = this.readerCommentPanelDragStartRatio - event.offsetY / viewportHeight;
          this.readerCommentPanelHeightRatio = Math.max(0.6, Math.min(0.9, nextRatio));
        })
    )
  }

  @Builder
  readerFloatingTopMenu() {
    Row() {
      ImmersiveBackButton({
        iconColor: this.getTextColor(),
        darkMode: this.isReaderThemeDark(),
        buttonSize: 40,
        containerWidth: 40,
        containerHeight: 56,
        startInset: 0,
        materialScale: 0.83,
        compactLayout: true,
        onBack: () => this.exitReaderPage()
      })

      Blank()
        .layoutWeight(1)

      Row({ space: 6 }) {
        if (this.book && !LocalBookService.isLocalBook(this.book) && this.chapters.length > 0) {
          this.readerRoundMenuButton($r('sys.symbol.arrow_clockwise'), '刷新本章', () => {
            this.hideReaderPanels();
            this.refreshCurrentChapter();
          })
        }
        if (this.book && !LocalBookService.isLocalBook(this.book)) {
          this.readerRoundMenuButton($r('sys.symbol.arrow_left_arrow_right'), '换源', () => {
            this.openChangeSourceDialog();
          })
        }
        this.readerRoundMenuButton($r('sys.symbol.more'), '更多操作', () => {
          this.showReaderActionMenu = !this.showReaderActionMenu;
        })
      }
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: this.getTopControlSafePadding() + 10 })
    .position({ x: 0, y: 0 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  readerRoundMenuButton(icon: Resource, accessibilityText: string, action: () => void) {
    ImmersiveBackButton({
      icon: icon,
      iconOffsetX: 0,
      iconColor: this.getTextColor(),
      darkMode: this.isReaderThemeDark(),
      buttonSize: 40,
      containerWidth: 40,
      containerHeight: 56,
      startInset: 0,
      materialScale: 0.83,
      compactLayout: true,
      accessibilityLabel: accessibilityText,
      onBack: action
    })
  }

  supportsReaderImmersiveMaterial(): boolean {
    return deviceInfo.sdkApiVersion >= 23;
  }

  @Builder
  readerHdsFloatingBottomMenu() {
    Column({ space: 4 }) {
      if (this.readerUseChapterQuickJump) {
        this.readerHdsChapterTabBar()
      }
      this.readerHdsActionBar(false)
    }
    .width('100%')
    .height(this.readerBottomMenuOverlayHeight())
    .padding({ bottom: this.readerFloatingBarBottomMargin() })
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.Center)
    .position({ x: 0, y: '100%' })
    .translate({
      x: this.readerFloatingBarTranslateX(),
      y: -this.readerBottomMenuOverlayHeight()
    })
  }

  @Builder
  readerHdsChapterTabBar() {
    Stack({ alignContent: Alignment.Center }) {
      HdsTabs({ barPosition: BarPosition.End, index: 0 }) {
        TabContent() {
          Column()
        }
        .height(56)
        .tabBar(this.readerHdsChapterBarContent())
      }
      .key(`reader_hds_chapter_bar_${this.themeRevision}_${this.isReaderThemeDark() ? 'dark' : 'light'}`)
      .barBackgroundColor(this.readerGlassPanelColor())
      .barMode(BarMode.Fixed)
      .barHeight(48)
      .barOverlap(true)
      .barFloatingStyle({
        barWidth: {
          smallWidth: this.readerFloatingBarWidth(),
          mediumWidth: this.readerFloatingBarWidth(),
          largeWidth: this.readerFloatingBarWidth()
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        },
        barSideMargin: 0,
        barBottomMargin: 4,
        gradientMask: {
          maskColor: '#00000000',
          maskHeight: 56
        },
        adaptToHandedness: false,
        thermoCtrl: true,
        barOpacity: 1
      })
      .scrollable(false)
      .width('100%')
      .height(56)

      if (this.menuChapterTooltipVisible) {
        Column({ space: 2 }) {
          Text(this.getChapterTitle(this.getMenuChapterDisplayIndex()))
            .fontSize(12)
            .fontColor('#FFFFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${this.getMenuChapterDisplayIndex() + 1}/${this.chapters.length}`)
            .fontSize(11)
            .fontColor('#CCFFFFFF')
        }
        .width(this.readerChapterTooltipWidth())
        .height(44)
        .padding({ left: 14, right: 14, top: 5, bottom: 5 })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(22)
        .backgroundColor(this.isReaderThemeDark() ? '#E63A3C40' : '#D94B4D52')
        .shadow({ radius: 10, color: '#50000000', offsetX: 0, offsetY: 3 })
        .position({ x: this.readerChapterTooltipCenteredLeft(), y: -48 })
      }
    }
    .width('100%')
    .height(56)
  }

  @Builder
  readerHdsChapterBarContent() {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(25)
          .fontColor([this.currentChapterIndex > 0 && !this.isLoading ?
            this.getTextColor() : this.getSubTextColor()])
      }
        .width(46)
        .height(48)
        .enabled(this.currentChapterIndex > 0 && !this.isLoading)
        .onClick(async () => {
          await this.jumpToAdjacentChapterFromMenu(-1);
        })

      Slider({
        value: this.getMenuChapterDisplayIndex(),
        min: 0,
        max: Math.max(0, this.chapters.length - 1),
        step: 1,
        style: SliderStyle.InSet
      })
        .layoutWeight(1)
        .height(48)
        .trackThickness(30)
        .blockSize({ width: 30, height: 30 })
        .selectedColor(this.accentColor())
        .trackColor(this.readerChapterTrackColor())
        .blockColor(this.readerSolidPanelColor())
        .showSteps(false)
        .onChange((value: number, mode: SliderChangeMode) => {
          this.handleMenuChapterSliderChange(value, mode);
        })

      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(25)
          .fontColor([this.currentChapterIndex < this.chapters.length - 1 && !this.isLoading ?
            this.getTextColor() : this.getSubTextColor()])
      }
        .width(46)
        .height(48)
        .enabled(this.currentChapterIndex < this.chapters.length - 1 && !this.isLoading)
        .onClick(async () => {
          await this.jumpToAdjacentChapterFromMenu(1);
        })
    }
    .width('100%')
    .height(48)
    .padding({ left: 4, right: 4 })
    .alignItems(VerticalAlign.Center)
    .translate({ y: -2 })
  }

  @Builder
  readerHdsFloatingActionBar(fromToc: boolean, fromSettings: boolean = false) {
    Column() {
      this.readerHdsActionBar(fromToc, fromSettings)
    }
    .width('100%')
    .height(this.readerBottomActionOverlayHeight())
    .padding({ bottom: this.readerFloatingBarBottomMargin() })
    .justifyContent(FlexAlign.End)
    .position({ x: 0, y: '100%' })
    .translate({
      x: this.readerFloatingBarTranslateX(),
      y: -this.readerBottomActionOverlayHeight()
    })
  }

  @Builder
  readerHdsActionBar(fromToc: boolean, fromSettings: boolean = false) {
    HdsTabs({ barPosition: BarPosition.End, index: 0 }) {
      TabContent() {
        Column()
      }
      .height(56)
      .tabBar(this.readerHdsMenuItem($r('sys.symbol.list_bullet'), fromToc))

      TabContent() {
        Column()
      }
      .height(56)
      .tabBar(this.readerHdsMenuItem($r('sys.symbol.gearshape'),
        fromSettings && this.settingsPanelTab === 0, false, !this.isReaderComicModeActive()))

      TabContent() {
        Column()
      }
      .height(56)
      .tabBar(this.readerHdsMenuItem($r('sys.symbol.textformat'),
        fromSettings && this.settingsPanelTab === 2, false,
        !this.isReaderComicModeActive()))

      TabContent() {
        Column()
      }
      .height(56)
      .tabBar(this.readerHdsMenuItem(this.readerDayNightIcon(), false))
    }
    .key(`reader_hds_action_bar_${this.themeRevision}_${this.isReaderThemeDark() ? 'dark' : 'light'}`)
    .barBackgroundColor(this.readerGlassPanelColor())
    .barMode(BarMode.Fixed)
    .barHeight(48)
    .barOverlap(true)
    .barFloatingStyle({
      barWidth: {
        smallWidth: this.readerFloatingBarWidth(),
        mediumWidth: this.readerFloatingBarWidth(),
        largeWidth: this.readerFloatingBarWidth()
      },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      },
      barSideMargin: 0,
      barBottomMargin: 4,
      gradientMask: {
        maskColor: '#00000000',
        maskHeight: 56
      },
      adaptToHandedness: false,
      thermoCtrl: true,
      barOpacity: 1
    })
    .scrollable(false)
    .onContentWillChange(() => false)
    .onTabBarClick((index: number) => {
      this.handleReaderHdsAction(index, fromToc, fromSettings);
    })
    .width('100%')
    .height(56)
  }

  @Builder
  readerHdsMenuItem(icon: Resource, active: boolean, showAddBadge: boolean = false, enabled: boolean = true) {
    Stack({ alignContent: Alignment.Center }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(icon)
          .fontSize(24)
          .fontColor([this.getSubTextColor()])

        if (showAddBadge) {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor([this.getSubTextColor()])
            .position({ x: 20, y: 0 })
        }
      }
      .width(32)
      .height(32)
    }
    .width('100%')
    .height(48)
    .opacity(enabled ? 1 : 0.32)
    .enabled(enabled)
    .translate({ y: -2 })
  }

  handleReaderHdsAction(index: number, fromToc: boolean, fromSettings: boolean = false): void {
    if (this.isReaderComicModeActive() && (index === 1 || index === 2)) {
      return;
    }
    if (index === 0) {
      if (fromToc) {
        this.cancelBookmarkMultiSelect();
        this.showToc = false;
        this.showMenu = true;
      } else if (fromSettings) {
        this.showSettings = false;
        this.openTocPanel();
      } else {
        this.openTocPanel();
      }
      return;
    }
    if (index === 3) {
      this.toggleReaderDayNightMode();
      return;
    }
    if (fromToc) {
      this.showToc = false;
    }
    if (index === 1) {
      if (fromSettings && this.settingsPanelTab === 0) {
        this.closeSettingsPanelKeepMenu();
      } else {
        this.openSettingsPanel();
      }
      return;
    }
    if (index === 2) {
      if (fromSettings && this.settingsPanelTab === 2) {
        this.closeSettingsPanelKeepMenu();
      } else {
        this.openTypographySettingsPanel();
      }
      return;
    }
  }

  readerDayNightIcon(): Resource {
    const mode = AppThemeModeStore.normalizeMode(this.appThemeMode);
    if (mode === 'system') {
      return $r('sys.symbol.circle_lefthalf_inset_filled');
    }
    return mode === 'dark' ? $r('sys.symbol.moon') : $r('sys.symbol.sun_max');
  }

  toggleReaderDayNightMode(): void {
    const currentMode = AppThemeModeStore.normalizeMode(this.appThemeMode);
    const nextMode = currentMode === 'light' ? 'dark' : (currentMode === 'dark' ? 'system' : 'light');
    const context = getContext(this) as common.UIAbilityContext;
    const systemDarkMode =
      context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    const nextDarkMode = nextMode === 'dark' || (nextMode === 'system' && systemDarkMode);
    const colorMode = nextMode === 'dark' ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK :
      (nextMode === 'light' ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT :
        ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);

    // 先同步模式来源，避免 setColorMode 触发的 ConfigurationUpdate 读到旧值，
    // 又把刚选择的浅色模式覆盖回系统深色模式。
    AppThemeModeStore.applyToStorage(nextMode);
    if (this.appDarkMode !== nextDarkMode) {
      this.appDarkMode = nextDarkMode;
    }
    context.getApplicationContext().setColorMode(colorMode);

    AppThemeModeStore.save(context, nextMode).catch((e: Error) => {
      console.warn('保存日间/夜间/自动模式失败:', e);
    });
    promptAction.showToast({
      message: nextMode === 'light' ? '已切换至日间模式' :
        (nextMode === 'dark' ? '已切换至夜间模式' : '已切换至自动模式')
    });
  }

  @Builder
  readerFloatingBottomMenu() {
    Column({ space: 10 }) {
      if (this.readerUseChapterQuickJump) {
        Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([this.currentChapterIndex > 0 && !this.isLoading ? this.getTextColor() : this.getSubTextColor()])
          .width(46)
          .height(54)
          .enabled(this.currentChapterIndex > 0 && !this.isLoading)
          .onClick(async () => {
            await this.jumpToAdjacentChapterFromMenu(-1);
          })

        Column({ space: 1 }) {
          Row() {
            Text(this.getChapterTitle(this.getMenuChapterDisplayIndex()))
              .fontSize(12)
              .fontColor(this.getSubTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(`${this.getMenuChapterDisplayIndex() + 1}/${this.chapters.length}`)
              .fontSize(11)
              .fontColor(this.getSubTextColor())
              .margin({ left: 8 })
          }
          .width('100%')

          Slider({
            value: this.getMenuChapterDisplayIndex(),
            min: 0,
            max: Math.max(0, this.chapters.length - 1),
            step: 1,
            style: SliderStyle.InSet
          })
            .width('100%')
            .height(24)
            .selectedColor(this.accentColor())
            .trackColor(this.readerChapterTrackColor())
            .blockColor(this.readerSolidPanelColor())
            .showSteps(false)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.handleMenuChapterSliderChange(value, mode);
            })
        }
        .layoutWeight(1)

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(24)
          .fontColor([this.currentChapterIndex < this.chapters.length - 1 && !this.isLoading ?
            this.getTextColor() : this.getSubTextColor()])
          .width(46)
          .height(54)
          .enabled(this.currentChapterIndex < this.chapters.length - 1 && !this.isLoading)
          .onClick(async () => {
            await this.jumpToAdjacentChapterFromMenu(1);
          })
        }
        .width('100%')
        .height(56)
        .padding({ left: 4, right: 4 })
        .borderRadius(ThemeRuntime.glassCornerRadius(28, 'panel'))
        .backgroundColor(this.readerGlassPanelColor())
        .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
        .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: this.readerGlassBorderColor() })
        .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: this.readerGlassShadowColor(), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
      }

      Row() {
        this.readerFloatingIconMenuItem($r('sys.symbol.list_bullet'), false, () => {
          this.openTocPanel();
        })
        this.readerFloatingIconMenuItem($r('sys.symbol.gearshape'), false, () => {
          this.openSettingsPanel();
        }, false, !this.isReaderComicModeActive())
        this.readerFloatingIconMenuItem($r('sys.symbol.textformat'), false, () => {
          this.openTypographySettingsPanel();
        }, false, !this.isReaderComicModeActive())
        this.readerFloatingIconMenuItem(this.readerDayNightIcon(), false, () => {
          this.toggleReaderDayNightMode();
        })
      }
      .width('100%')
      .height(56)
      .padding({ left: 8, right: 8 })
      .borderRadius(ThemeRuntime.glassCornerRadius(28, 'panel'))
      .backgroundColor(this.readerGlassPanelColor())
      .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
      .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: this.readerGlassBorderColor() })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: this.readerGlassShadowColor(), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
    }
    .width(this.readerFloatingBarWidth())
    .padding({ bottom: 14 })
    .position({ x: this.readerFloatingBarLeft(), y: '100%' })
    .translate({ y: '-100%' })
  }

  @Builder
  readerFloatingIconMenuItem(icon: Resource, active: boolean, action: () => void,
    showAddBadge: boolean = false, enabled: boolean = true) {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(icon)
          .fontSize(24)
          .fontColor([this.getSubTextColor()])

        if (showAddBadge) {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor([this.getSubTextColor()])
            .position({ x: 20, y: 0 })
        }
      }
      .width(32)
      .height(32)
    }
    .layoutWeight(1)
    .height(56)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(28)
    .opacity(enabled ? 1 : 0.32)
    .enabled(enabled)
    .onClick(action)
  }

  @Builder
  readerFloatingTocPanel() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showToc = false;
        })

      Column() {
        Row({ space: 14 }) {
          if (this.getTocCover()) {
            Image(this.getTocCover())
              .width(52)
              .height(68)
              .borderRadius(8)
              .objectFit(ImageFit.Cover)
          } else {
            Text(this.getTocBookInitial())
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .textAlign(TextAlign.Center)
              .width(52)
              .height(68)
              .borderRadius(8)
              .backgroundColor(this.accentColor())
          }

          Column({ space: 5 }) {
            Text(this.book?.name || '目录')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.getTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.book?.author || '未知作者')
              .fontSize(12)
              .fontColor(this.getSubTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          ImmersiveBackButton({
            icon: $r('sys.symbol.xmark'),
            iconOffsetX: 0,
            iconColor: this.getTextColor(),
            darkMode: this.isReaderThemeDark(),
            buttonSize: 40,
            containerWidth: 40,
            containerHeight: 40,
            startInset: 0,
            materialScale: 0.83,
            compactLayout: true,
            accessibilityLabel: '关闭目录',
            onBack: () => {
              this.showToc = false;
            }
          })
          .alignSelf(ItemAlign.Start)
          .margin({ top: 4 })
        }
        .width('100%')
        .padding({ left: 20, right: 16, top: 12, bottom: 10 })
        .alignItems(VerticalAlign.Center)

        Row() {
          Text('目录')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.tocPanelTab === 0 ? this.getTextColor() : this.getSubTextColor())
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(42)
            .borderRadius(21)
            .backgroundColor(this.tocPanelTab === 0 ? this.readerSolidPanelColor() : Color.Transparent)
            .shadow({ radius: this.tocPanelTab === 0 ? 8 : 0,
              color: this.readerGlassShadowColor(), offsetX: 0, offsetY: 2 })
            .onClick(() => {
              this.tocPanelTab = 0;
              this.cancelBookmarkMultiSelect();
              this.scrollTocToCurrentChapter(false);
            })
          Text('书签')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.tocPanelTab === 1 ? this.getTextColor() : this.getSubTextColor())
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(42)
            .borderRadius(21)
            .backgroundColor(this.tocPanelTab === 1 ? this.readerSolidPanelColor() : Color.Transparent)
            .shadow({ radius: this.tocPanelTab === 1 ? 8 : 0,
              color: this.readerGlassShadowColor(), offsetX: 0, offsetY: 2 })
            .onClick(() => {
              this.tocPanelTab = 1;
              this.loadBookmarks();
            })
        }
        .width('calc(100% - 40vp)')
        .height(46)
        .padding(2)
        .borderRadius(23)
        .backgroundColor(this.isReaderThemeDark() ? '#1FFFFFFF' : '#0D000000')
        .margin({ left: 20, right: 20 })

        if (this.tocPanelTab === 0) {
          this.tocPanelSummary()
          this.tocChapterList()
        } else {
          this.bookmarkPanelSummary()
          this.bookmarkList()
        }
      }
      .width(this.readerFloatingBarWidth())
      .height(this.readerTocPanelHeight())
      .borderRadius(ThemeRuntime.glassCornerRadius(28, 'panel'))
      .clip(true)
      .backgroundColor(this.readerGlassPanelColor())
      .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
      .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: this.readerGlassBorderColor() })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: this.readerGlassShadowColor(), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
      .position({ x: this.readerFloatingBarLeft(), y: '100%' })
      .translate({ y: -(this.readerTocPanelHeight() + this.readerFloatingPanelBottomInset()) })
      .transition(this.readerPanelTransition())

      if (!this.supportsReaderImmersiveMaterial()) {
        Row() {
          this.readerFloatingIconMenuItem($r('sys.symbol.list_bullet'), true, () => {
            this.tocPanelTab = 0;
          })
          this.readerFloatingIconMenuItem($r('sys.symbol.gearshape'), false, () => {
            this.showToc = false;
            this.openSettingsPanel();
          })
          this.readerFloatingIconMenuItem($r('sys.symbol.textformat'), false, () => {
            this.showToc = false;
            this.openTypographySettingsPanel();
          })
          this.readerFloatingIconMenuItem(this.readerDayNightIcon(), false, () => {
            this.toggleReaderDayNightMode();
          })
        }
        .width(this.readerFloatingBarWidth())
        .height(56)
        .padding({ left: 8, right: 8 })
        .borderRadius(ThemeRuntime.glassCornerRadius(28, 'panel'))
        .backgroundColor(this.readerGlassPanelColor())
        .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
        .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: this.readerGlassBorderColor() })
        .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: this.readerGlassShadowColor(), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
        .position({ x: this.readerFloatingBarLeft(), y: '100%' })
        .translate({ y: -70 })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  tocPanelSummary() {
    Column({ space: 8 }) {
      Row() {
        Text(this.isTocSearchActive() ? `找到 ${this.tocSearchChapterIndexes.length} 章` : `共 ${this.chapters.length} 章`)
          .fontSize(14)
          .fontColor(this.getSubTextColor())
          .margin({ right: 6 })
        SymbolGlyph($r('sys.symbol.chevron_up'))
          .fontSize(20)
          .fontColor([this.getTextColor()])
          .width(32)
          .height(36)
          .accessibilityText('跳到目录开头')
          .onClick(() => {
            this.scrollTocVisibleEdge(false);
          })
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(20)
          .fontColor([this.getTextColor()])
          .width(32)
          .height(36)
          .accessibilityText('跳到目录末尾')
          .onClick(() => {
            this.scrollTocVisibleEdge(true);
          })
        Blank()
          .layoutWeight(1)
        if (this.tocQuickJumpInputVisible && !this.isTocSearchActive()) {
          TextInput({ text: this.tocQuickJumpDraft, placeholder: `1-${this.chapters.length}` })
            .type(InputType.Number)
            .enterKeyType(EnterKeyType.Go)
            .key('tocQuickJumpChapterInput')
            .defaultFocus(true)
            .fontSize(13)
            .fontColor(this.getTextColor())
            .textAlign(TextAlign.Center)
            .width(92)
            .height(34)
            .padding({ left: 8, right: 8 })
            .borderRadius(17)
            .backgroundColor(this.isReaderThemeDark() ? '#2BFFFFFF' : '#14000000')
            .accessibilityText('输入目标章节序号，按回车定位')
            .onChange((value: string) => {
              this.tocQuickJumpDraft = value.replace(/[^0-9]/g, '').substring(0, 6);
            })
            .onSubmit(() => {
              this.submitTocQuickJump();
            })
        } else if (this.isTocSearchActive()) {
          Text(`匹配 ${this.tocSearchChapterIndexes.length}`)
            .fontSize(12)
            .fontColor(this.getTextColor())
            .height(34)
            .padding({ left: 12, right: 12 })
            .textAlign(TextAlign.Center)
            .borderRadius(16)
            .backgroundColor(this.isReaderThemeDark() ? '#1FFFFFFF' : '#0D000000')
        } else {
          Text(`当前${Math.min(this.currentChapterIndex + 1, this.chapters.length)}`)
            .fontSize(12)
            .fontColor(this.getTextColor())
            .height(34)
            .padding({ left: 12, right: 12 })
            .textAlign(TextAlign.Center)
            .borderRadius(16)
            .backgroundColor(this.isReaderThemeDark() ? '#1FFFFFFF' : '#0D000000')
            .accessibilityText(this.tocQuickJumpArmed ? '再次点击输入目标章节' : '回到当前章节')
            .onClick(() => {
              this.handleTocCurrentPositionClick();
            })
        }
        ImmersiveBackButton({
          icon: $r('sys.symbol.arrow_clockwise'),
          iconOffsetX: 0,
          iconColor: this.getTextColor(),
          darkMode: this.isReaderThemeDark(),
          buttonSize: 34,
          containerWidth: 34,
          containerHeight: 34,
          startInset: 0,
          materialScale: 0.7,
          compactLayout: true,
          accessibilityLabel: '刷新目录',
          onBack: () => {
            this.refreshTocFromPanel();
          }
        })
          .margin({ left: 8 })
        ImmersiveBackButton({
          icon: $r('sys.symbol.magnifyingglass'),
          iconOffsetX: 0,
          iconColor: this.tocSearchVisible ? this.accentColor() : this.getTextColor(),
          darkMode: this.isReaderThemeDark(),
          buttonSize: 34,
          containerWidth: 34,
          containerHeight: 34,
          startInset: 0,
          materialScale: 0.7,
          compactLayout: true,
          accessibilityLabel: '搜索目录',
          onBack: () => {
            this.toggleTocSearch();
          }
        })
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.tocSearchVisible) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(18)
            .fontColor([this.getSubTextColor()])
          TextInput({ text: this.tocSearchQuery,
            placeholder: this.tocSearchLoading ? '正在载入完整目录…' : '搜索章节名称' })
            .key('tocChapterSearchInput')
            .defaultFocus(true)
            .fontSize(14)
            .fontColor(this.getTextColor())
            .layoutWeight(1)
            .height(38)
            .padding({ left: 0, right: 0 })
            .backgroundColor(Color.Transparent)
            .enterKeyType(EnterKeyType.Search)
            .onChange((value: string) => {
              this.tocSearchQuery = value;
            })
            .onSubmit(() => {
              this.submitTocSearch();
            })
          if (this.tocSearchQuery) {
            Text('×')
              .fontSize(22)
              .fontColor(this.getSubTextColor())
              .width(32)
              .height(38)
              .textAlign(TextAlign.Center)
              .accessibilityText('清空目录搜索')
              .onClick(() => {
                this.clearTocSearchResult();
                setTimeout(() => focusControl.requestFocus('tocChapterSearchInput'), 30);
              })
          }
        }
        .width('100%')
        .height(40)
        .padding({ left: 12, right: 8 })
        .borderRadius(20)
        .backgroundColor(this.isReaderThemeDark() ? '#2BFFFFFF' : '#14000000')
      }
    }
    .width('100%')
    .padding({ left: 20, right: 16, top: 18, bottom: 10 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  tocChapterList() {
    Stack({ alignContent: Alignment.TopEnd }) {
      List({ space: 0, scroller: this.tocScroller }) {
        if (this.isTocSearchActive() && this.tocVisibleChapters.length === 0) {
          ListItem() {
            Column({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(28)
                .fontColor([this.getSubTextColor()])
              Text('未找到匹配章节')
                .fontSize(14)
                .fontColor(this.getSubTextColor())
            }
            .width('100%')
            .padding({ top: 44, bottom: 44 })
          }
        }
        ForEach(this.tocVisibleChapters, (chapter: BookChapter, localIndex: number) => {
          ListItem() {
            Row({ space: 10 }) {
              Text(this.tocGlobalIndex(localIndex) === this.currentChapterIndex ? '•' : '·')
                .fontSize(this.tocGlobalIndex(localIndex) === this.currentChapterIndex ? 22 : 18)
                .fontColor(this.tocGlobalIndex(localIndex) === this.currentChapterIndex ?
                  this.accentColor() : this.getSubTextColor())
                .width(18)
                .textAlign(TextAlign.Center)

              Text(this.getChapterTitle(this.tocGlobalIndex(localIndex)))
                .fontSize(15)
                .fontWeight(this.tocGlobalIndex(localIndex) === this.currentChapterIndex ?
                  FontWeight.Medium : FontWeight.Regular)
                .fontColor(this.getTocTitleColor(chapter, this.tocGlobalIndex(localIndex)))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)

              if (this.book?.origin !== 'local' && chapter.cacheDate > 0) {
                Text('已缓存')
                  .fontSize(10)
                  .fontColor(this.isReaderThemeDark() ? '#7CC7A0' : '#1F8F55')
                  .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                  .backgroundColor(this.isReaderThemeDark() ? '#24382F' : '#E6F4EC')
                  .borderRadius(10)
              }
            }
            .width('100%')
            .padding({ left: 14, right: 16, top: 14, bottom: 14 })
            .backgroundColor(this.tocGlobalIndex(localIndex) === this.currentChapterIndex ?
              this.tocSelectedBackgroundColor() : Color.Transparent)
            .border({ width: { bottom: 0.5 }, color: this.isReaderThemeDark() ? '#1FFFFFFF' : '#0D000000' })
            .onClick(async () => {
              const targetChapterIndex = this.tocGlobalIndex(localIndex);
              this.showToc = false;
              this.showMenu = false;
              await this.jumpToReaderPositionKeepingTts(targetChapterIndex, 0);
            })
          }
        }, (chapter: BookChapter, localIndex: number) =>
          `${this.tocGlobalIndex(localIndex)}_${chapter.url || chapter.title}`)
      }
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .onScrollIndex((start: number, end: number) => {
        this.updateTocScrollbarPosition(start, end);
      })
      .onReachStart(() => this.loadPreviousTocPage())
      .onReachEnd(() => this.loadNextTocPage())

      this.tocVirtualScrollbar()
    }
    .layoutWeight(1)
    .width('100%')
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.tocListViewportHeight = Number(newValue.height);
    })
  }

  @Builder
  tocVirtualScrollbar() {
    if (this.tocShouldShowVirtualScrollbar()) {
      Column()
        .width(3)
        .height(this.tocListViewportHeight)
        .borderRadius(2)
        .backgroundColor(this.isReaderThemeDark() ? '#18FFFFFF' : '#14000000')
        .margin({ right: 3 })
        .hitTestBehavior(HitTestMode.None)
      Column()
        .width(3)
        .height(this.tocScrollbarThumbLength())
        .borderRadius(2)
        .backgroundColor(this.isReaderThemeDark() ? '#99D5D8DE' : '#887A6F63')
        .margin({ right: 3 })
        .translate({ y: this.tocScrollbarThumbOffset() })
        .hitTestBehavior(HitTestMode.None)
    }
  }

  @Builder
  bookmarkPanelSummary() {
    if (this.bookmarkMultiSelectMode) {
      Row({ space: 16 }) {
        Text(`已选 ${this.selectedBookmarkIds.length} 项`)
          .fontSize(14)
          .fontColor(this.getTextColor())
          .layoutWeight(1)
        Text(this.selectedBookmarkIds.length === this.bookmarks.length ? '取消全选' : '全选')
          .fontSize(13)
          .fontColor(this.accentColor())
          .onClick(() => {
            this.toggleSelectAllBookmarks();
          })
        Text('删除')
          .fontSize(13)
          .fontColor(this.selectedBookmarkIds.length > 0 ? '#D94841' : this.getSubTextColor())
          .enabled(this.selectedBookmarkIds.length > 0)
          .onClick(() => {
            this.deleteSelectedBookmarks();
          })
        Text('取消')
          .fontSize(13)
          .fontColor(this.getSubTextColor())
          .onClick(() => {
            this.cancelBookmarkMultiSelect();
          })
      }
      .width('100%')
      .height(52)
      .padding({ left: 20, right: 20 })
      .alignItems(VerticalAlign.Center)
    } else {
      Row() {
        Text(`${this.bookmarks.length} 条书签`)
          .fontSize(14)
          .fontColor(this.getSubTextColor())
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 10 })
    }
  }

  @Builder
  bookmarkList() {
    if (this.bookmarks.length === 0) {
      Column({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.bookmark'))
          .fontSize(34)
          .fontColor([this.getSubTextColor()])
        Text('暂无书签')
          .fontSize(15)
          .fontColor(this.getSubTextColor())
        Text('可使用底栏最右侧按钮添加当前阅读位置')
          .fontSize(12)
          .fontColor(this.getSubTextColor())
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else {
      List({ space: 0, scroller: this.bookmarkScroller }) {
        ForEach(this.bookmarks, (bookmark: Bookmark) => {
          ListItem() {
            Column({ space: 5 }) {
              Row() {
                SymbolGlyph($r('sys.symbol.bookmark'))
                  .fontSize(18)
                  .fontColor([this.accentColor()])
                  .width(26)
                Text(bookmark.chapterName || `第 ${bookmark.chapterIndex + 1} 章`)
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.getTextColor())
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(`第 ${bookmark.pageIndex + 1} 页`)
                  .fontSize(11)
                  .fontColor(this.getSubTextColor())
                if (this.bookmarkMultiSelectMode) {
                  if (this.isBookmarkSelected(bookmark.id)) {
                    SymbolGlyph($r('sys.symbol.checkmark_circle'))
                      .fontSize(21)
                      .fontColor([this.accentColor()])
                      .margin({ left: 10 })
                  } else {
                    Circle()
                      .width(19)
                      .height(19)
                      .fill(Color.Transparent)
                      .stroke(this.getSubTextColor())
                      .strokeWidth(1.5)
                      .margin({ left: 10 })
                  }
                }
              }
              .width('100%')

              Text(bookmark.content || '已保存阅读位置')
                .fontSize(12)
                .fontColor(this.getSubTextColor())
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(this.formatBookmarkTime(bookmark.createTime))
                .fontSize(10)
                .fontColor(this.getSubTextColor())
                .width('100%')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .backgroundColor(this.isBookmarkSelected(bookmark.id) ? this.tocSelectedBackgroundColor() : Color.Transparent)
            .border({ width: { bottom: 0.5 }, color: this.isReaderThemeDark() ? '#1FFFFFFF' : '#0D000000' })
            .onClick(() => {
              if (this.bookmarkMultiSelectMode) {
                this.toggleBookmarkSelection(bookmark.id);
              } else {
                this.jumpToBookmark(bookmark);
              }
            })
            .gesture(
              LongPressGesture({ repeat: false })
                .onAction((event: GestureEvent) => {
                  if (!this.bookmarkMultiSelectMode) {
                    this.showBookmarkActions(bookmark, event);
                  }
                })
            )
          }
          .width('100%')
          .clip(true)
          .swipeAction({
            start: {
              builder: this.bookmarkMultiSelectAction.bind(this, bookmark),
              actionAreaDistance: 64,
              onAction: () => {
                this.enterBookmarkMultiSelect(bookmark.id);
              }
            },
            end: {
              builder: this.bookmarkDeleteAction.bind(this, bookmark),
              actionAreaDistance: 64,
              onAction: () => {
                this.deleteBookmark(bookmark);
              }
            },
            edgeEffect: SwipeEdgeEffect.Spring
          })
        }, (bookmark: Bookmark) => `${bookmark.id}`)
      }
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .layoutWeight(1)
      .width('100%')
      .clip(true)
      .scrollBar(BarState.Auto)
      .scrollBarColor(this.isReaderThemeDark() ? '#668A8F98' : '#667A6F63')
    }
  }

  @Builder
  bookmarkDeleteAction(bookmark: Bookmark) {
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
    .backgroundColor('#D94841')
    .onClick(() => {
      this.deleteBookmark(bookmark);
    })
  }

  @Builder
  readerActionMenu() {
    Column() {
      this.readerActionMenuItem(
        $r('sys.symbol.bookmark'),
        this.isCurrentPageBookmarked() ? '删除书签' : '添加书签',
        () => this.toggleCurrentPageBookmark(),
        true,
        this.readerSourceNeedsLogin() || this.readerCanRetry() || !this.isReaderComicModeActive()
      )
      if (!this.isReaderComicModeActive()) {
        this.readerActionMenuItem(
          this.isTtsSpeaking && !this.isTtsPaused ? $r('sys.symbol.pause') : $r('sys.symbol.play'),
          this.isTtsSpeaking ? (this.isTtsPaused ? '继续朗读' : '暂停朗读') : '开始朗读',
          () => this.toggleTtsReading()
        )
      }
      if (this.readerSourceNeedsLogin()) {
        this.readerActionMenuItem(
          $r('sys.symbol.checkmark_shield'),
          '登录',
          () => this.openReaderSourceLogin()
        )
      }
      if (this.readerCanRetry()) {
        this.readerActionMenuItem(
          $r('sys.symbol.exclamationmark_circle'),
          '重试',
          () => this.retryReaderContent()
        )
      }
      if (!this.isReaderComicModeActive()) {
        this.readerActionMenuItem(
          $r('sys.symbol.gearshape'),
          '阅读设置',
          () => this.openSettingsPanel()
        )
        this.readerActionMenuItem(
          $r('sys.symbol.speaker_wave_3'),
          '朗读设置',
          () => this.openTtsSettingsPanel(),
          true,
          true
        )
      }
      if (this.canSelectTxtCharset()) {
        this.readerActionMenuItem(
          $r('sys.symbol.textformat'),
          `字符编码 · ${this.txtCharsetMenuLabel()}`,
          () => this.openTxtCharsetDialog()
        )
      }
      this.readerActionMenuItem(
        this.isReaderComicModeActive() ? $r('sys.symbol.book') : $r('sys.symbol.rectangle_3_group'),
        this.isReaderComicModeActive() ? '切换为普通阅读' : '切换为漫画阅读',
        () => this.toggleReaderComicReadingMode()
      )
      this.readerActionMenuItem(
        $r('sys.symbol.square_grid_2x2'),
        '布局元素设置',
        () => this.openLayoutElementSettings()
      )
      this.readerActionMenuItem(
        $r('sys.symbol.arrow_left_arrow_right'),
        '替换净化配置',
        () => this.openCurrentReaderReplaceRules(),
        true,
        false
      )
    }
    .width(220)
    .padding({ left: 8, right: 8, top: 6, bottom: 6 })
    .backgroundColor(this.readerGlassPanelColor())
    .borderRadius(ThemeRuntime.glassCornerRadius(22, 'panel'))
    .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
    .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: this.readerGlassBorderColor() })
    .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: this.readerGlassShadowColor(), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
    .position({ x: '100%', y: 0 })
    .translate({ x: -232, y: this.getTopControlSafePadding() + 72 })
    .onClick(() => {
    })
  }

  @Builder
  readerActionMenuItem(icon: Resource, label: string, action: () => void,
    enabled: boolean = true, showDivider: boolean = true) {
    Column() {
      Row({ space: 12 }) {
        SymbolGlyph(icon)
          .fontSize(21)
          .fontColor([this.getTextColor()])
          .width(24)

        Text(label)
          .fontSize(16)
          .fontColor(this.getTextColor())
          .maxLines(1)
          .layoutWeight(1)
      }
      .width('100%')
      .height(46)
      .padding({ left: 10, right: 10 })

      if (showDivider) {
        Divider()
          .strokeWidth(0.5)
          .color(this.readerGlassBorderColor())
          .margin({ left: 46, right: 8 })
      }
    }
    .width('100%')
    .opacity(enabled ? 1 : 0.38)
    .enabled(enabled)
    .onClick(() => {
      if (!enabled) return;
      this.showReaderActionMenu = false;
      action();
    })
  }

  openLayoutElementSettings(): void {
    this.showReaderActionMenu = false;
    this.showLayoutElementSettings = true;
  }

  canSelectTxtCharset(): boolean {
    const currentBook = this.book;
    return currentBook !== null && LocalBookService.isLocalBook(currentBook) &&
      currentBook.type === LocalBookService.TYPE_TXT;
  }

  txtCharsetOptions(): ReaderTxtCharsetOption[] {
    return [
      new ReaderTxtCharsetOption('', '自动识别', '根据文件内容自动判断编码'),
      new ReaderTxtCharsetOption('gb18030', 'GBK / GB18030', '简体中文'),
      new ReaderTxtCharsetOption('utf-8', 'UTF-8', 'Unicode，支持带 BOM 文件'),
      new ReaderTxtCharsetOption('utf-16le', 'UTF-16 LE', 'Unicode 小端序'),
      new ReaderTxtCharsetOption('utf-16be', 'UTF-16 BE', 'Unicode 大端序'),
      new ReaderTxtCharsetOption('big5', 'Big5', '繁体中文'),
      new ReaderTxtCharsetOption('koi8-r', 'KOI8-R', '俄语'),
      new ReaderTxtCharsetOption('euc-kr', 'EUC-KR', '韩语'),
      new ReaderTxtCharsetOption('euc-jp', 'EUC-JP', '日语'),
      new ReaderTxtCharsetOption('shift_jis', 'Shift-JIS', '日语'),
      new ReaderTxtCharsetOption('windows-1250', 'Windows-1250', '中欧语言'),
      new ReaderTxtCharsetOption('ibm866', 'IBM866', '西里尔字符')
    ];
  }

  txtCharsetLabel(charset: string): string {
    const normalized = (charset || '').toLowerCase().replace(/_/g, '-');
    for (const option of this.txtCharsetOptions()) {
      if (option.value.replace(/_/g, '-') === normalized) return option.label;
    }
    return charset ? charset.toUpperCase() : '自动识别';
  }

  txtCharsetMenuLabel(): string {
    if (!this.book) return '自动';
    const charsetOverride = LocalBookService.getTxtCharsetOverride(this.book);
    return charsetOverride ? this.txtCharsetLabel(charsetOverride) : '自动';
  }

  openTxtCharsetDialog(): void {
    if (!this.canSelectTxtCharset()) return;
    this.showReaderActionMenu = false;
    this.txtCharsetDraft = LocalBookService.getTxtCharsetOverride(this.book);
    this.showTxtCharsetDialog = true;
  }

  async applyTxtCharsetSelection(): Promise<void> {
    if (!this.book || !this.canSelectTxtCharset() || this.txtCharsetApplying) return;
    const targetBook: Book = this.book;
    const selectedCharset = this.txtCharsetDraft;
    if (selectedCharset === LocalBookService.getTxtCharsetOverride(targetBook)) {
      this.showTxtCharsetDialog = false;
      return;
    }
    this.txtCharsetApplying = true;
    try {
      await this.saveReadingProgress();
      this.stopTtsReading();
      await LocalBookService.setTxtCharsetOverride(getContext(this), targetBook, selectedCharset);
      this.showTxtCharsetDialog = false;
      this.showMenu = false;
      await this.loadBook();
      AppStorage.setOrCreate('shelfUpdateTime', Date.now());
      const applied = selectedCharset ? this.txtCharsetLabel(selectedCharset) :
        `自动识别（${this.txtCharsetLabel(this.book?.charset || '')}）`;
      promptAction.showToast({ message: `已使用 ${applied} 重新解析` });
    } catch (e) {
      console.error('切换 TXT 字符编码失败:', e);
      promptAction.showToast({ message: '切换字符编码失败，请尝试其他编码' });
    } finally {
      this.txtCharsetApplying = false;
    }
  }

  @Builder
  readerTxtCharsetDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.isReaderThemeDark() ? '#52000000' : '#26000000')
        .backdropBlur(ThemeRuntime.glassBlur('overlay', 18))
        .onClick(() => {
          if (!this.txtCharsetApplying) this.showTxtCharsetDialog = false;
        })

      Column({ space: 10 }) {
        Row() {
          Column({ space: 3 }) {
            Text('选择字符编码')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.getTextColor())
            Text(`当前解析：${this.txtCharsetLabel(this.book?.charset || '')}`)
              .fontSize(12)
              .fontColor(this.getSubTextColor())
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          ImmersiveBackButton({
            icon: $r('sys.symbol.xmark'),
            iconOffsetX: 0,
            iconColor: this.getTextColor(),
            darkMode: this.isReaderThemeDark(),
            buttonSize: 38,
            containerWidth: 38,
            containerHeight: 38,
            startInset: 0,
            compactLayout: true,
            accessibilityLabel: '关闭字符编码选择',
            onBack: () => {
              if (!this.txtCharsetApplying) this.showTxtCharsetDialog = false;
            }
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Scroll() {
          Column({ space: 4 }) {
            ForEach(this.txtCharsetOptions(), (option: ReaderTxtCharsetOption) => {
              this.readerTxtCharsetOption(option)
            }, (option: ReaderTxtCharsetOption) => option.value || 'auto')
          }
          .width('100%')
        }
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .width('100%')
        .height(Math.min(440, Math.max(160, this.pageViewHeight - 190)))
        .scrollBar(BarState.Auto)

        Row({ space: 12 }) {
          Button('取消')
            .layoutWeight(1)
            .height(42)
            .fontColor(this.getTextColor())
            .backgroundColor(this.isReaderThemeDark() ? '#24FFFFFF' : '#10000000')
            .enabled(!this.txtCharsetApplying)
            .onClick(() => {
              this.showTxtCharsetDialog = false;
            })
          Button(this.txtCharsetApplying ? '正在重新解析…' : '应用')
            .layoutWeight(1)
            .height(42)
            .fontColor('#FFFFFF')
            .backgroundColor(this.accentColor())
            .enabled(!this.txtCharsetApplying)
            .onClick(() => this.applyTxtCharsetSelection())
        }
        .width('100%')
      }
      .width(Math.min(440, Math.max(310, this.pageViewWidth - 32)))
      .padding({ left: 18, right: 18, top: 16, bottom: 16 })
      .borderRadius(ThemeRuntime.glassCornerRadius(24, 'overlay'))
      .backgroundColor(this.readerGlassPanelColor())
      .backdropBlur(ThemeRuntime.glassBlur('overlay', 24))
      .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: this.readerGlassBorderColor() })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: this.readerGlassShadowColor(),
        offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  readerTxtCharsetOption(option: ReaderTxtCharsetOption) {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(option.label)
          .fontSize(16)
          .fontColor(this.getTextColor())
        Text(option.description)
          .fontSize(12)
          .fontColor(this.getSubTextColor())
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.txtCharsetDraft === option.value) {
        SymbolGlyph($r('sys.symbol.checkmark_circle'))
          .fontSize(22)
          .fontColor([this.accentColor()])
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
    .borderRadius(14)
    .backgroundColor(this.txtCharsetDraft === option.value ?
      ThemeRuntime.accentSurfaceColor(this.isReaderThemeDark()) : Color.Transparent)
    .enabled(!this.txtCharsetApplying)
    .onClick(() => {
      this.txtCharsetDraft = option.value;
    })
  }

  openCurrentReaderReplaceRules(): void {
    const chapter = this.chapters.length > 0 ?
      this.chapters[this.clampChapterIndex(this.currentChapterIndex)] : null;
    const rawTitle = chapter ? this.cleanChapterTitle(chapter.title || '') : '';
    const cached = this.chapters.length > 0 ?
      ReadBookEngine.get().getCachedContent(this.currentChapterIndex) : '';
    const rawContent = cached || this.content || '';
    AppStorage.setOrCreate('readerReplacePreviewTitle', rawTitle);
    AppStorage.setOrCreate('readerReplacePreviewContent', rawContent.substring(0, 20000));
    AppStorage.setOrCreate('readerReplacePreviewBookName', this.book?.name || '');
    AppStorage.setOrCreate('readerReplacePreviewBookAuthor', this.book?.author || '');
    AppStorage.setOrCreate('readerReplacePreviewBookOriginName', this.book?.originName || '');
    AppStorage.setOrCreate('readerReplacePreviewBookOrigin', this.book?.origin || '');
    AppStorage.setOrCreate('readerReplacePreviewBookUrl', this.book?.bookUrl || this.bookUrl);
    this.returningFromReaderReplaceRules = true;
    this.hideReaderPanels();
    router.pushUrl({ url: 'pages/ReaderReplaceRules', params: { previewCurrentChapter: 'true' } });
  }

  @Builder
  readerLayoutElementSettingsDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.isReaderThemeDark() ? '#52000000' : '#26000000')
        .backdropBlur(ThemeRuntime.glassBlur('overlay', 18))
        .onClick(() => {
          this.showLayoutElementSettings = false;
        })

      Column({ space: 4 }) {
        Row() {
          Text('布局元素设置')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.getTextColor())
            .layoutWeight(1)
          ImmersiveBackButton({
            icon: $r('sys.symbol.xmark'),
            iconOffsetX: 0,
            iconColor: this.getTextColor(),
            darkMode: this.isReaderThemeDark(),
            buttonSize: 38,
            containerWidth: 38,
            containerHeight: 38,
            startInset: 0,
            compactLayout: true,
            accessibilityLabel: '关闭布局元素设置',
            onBack: () => this.showLayoutElementSettings = false
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text('控制点击阅读页后出现的快捷组件')
          .fontSize(13)
          .fontColor(this.getSubTextColor())
          .width('100%')
          .margin({ bottom: 8 })

        this.readerLayoutElementToggle(
          '使用快速朗读组件',
          '显示朗读快捷按钮与展开控制条',
          this.readerUseTtsQuickAction,
          (enabled: boolean) => {
            this.readerUseTtsQuickAction = enabled;
            if (!enabled) this.ttsMediaControlsExpanded = false;
            this.saveReaderLayoutElementSettings();
          }
        )
        this.readerLayoutElementToggle(
          '使用章节快速跳转组件',
          '显示章节滑杆与上一章、下一章按钮',
          this.readerUseChapterQuickJump,
          (enabled: boolean) => {
            this.readerUseChapterQuickJump = enabled;
            if (!enabled) this.resetMenuChapterPreview();
            this.saveReaderLayoutElementSettings();
          }
        )
      }
      .width(Math.min(420, Math.max(300, this.pageViewWidth - 36)))
      .padding({ left: 20, right: 20, top: 18, bottom: 18 })
      .borderRadius(ThemeRuntime.glassCornerRadius(24, 'overlay'))
      .backgroundColor(this.readerGlassPanelColor())
      .backdropBlur(ThemeRuntime.glassBlur('overlay', 24))
      .border({ width: ThemeRuntime.glassBorderWidth('overlay'), color: this.readerGlassBorderColor() })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('overlay'), color: this.readerGlassShadowColor(),
        offsetX: ThemeRuntime.glassShadowOffsetX('overlay'), offsetY: ThemeRuntime.glassShadowOffsetY('overlay') })
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  readerLayoutElementToggle(title: string, description: string, enabled: boolean,
    onChange: (enabled: boolean) => void) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(title)
          .fontSize(16)
          .fontColor(this.getTextColor())
        Text(description)
          .fontSize(12)
          .fontColor(this.getSubTextColor())
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: enabled })
        .selectedColor(this.accentColor())
        .onChange(onChange)
    }
    .width('100%')
    .constraintSize({ minHeight: 64 })
    .padding({ left: 12, right: 8 })
    .borderRadius(14)
    .backgroundColor(this.isReaderThemeDark() ? '#1FFFFFFF' : '#0D000000')
    .alignItems(VerticalAlign.Center)
  }

  saveReaderLayoutElementSettings(): void {
    ReaderSettingsStore.saveLayoutElementSettings(
      getContext(this),
      this.readerUseTtsQuickAction,
      this.readerUseChapterQuickJump
    ).catch((e: Error) => {
      console.error('保存阅读布局元素设置失败:', e);
      promptAction.showToast({ message: '布局元素设置保存失败' });
    });
  }

  currentReaderSource(): BookSource | null {
    return ReadBookEngine.get().source;
  }

  readerSourceNeedsLogin(): boolean {
    const source = this.currentReaderSource();
    if (!source) return false;
    if (this.verificationUrl) return true;
    const loginUrl = String(source.loginUrl || '').trim();
    const loginUi = String(source.loginUi || '').trim();
    const loginCheckJs = String(source.loginCheckJs || '').trim();
    const loginHeader = String(source.loginHeader || '').trim();
    if (loginUrl || loginUi || loginCheckJs || loginHeader) return true;
    const rules = `${source.jsLib || ''}\n${source.searchUrl || ''}\n${source.exploreUrl || ''}\n` +
      `${source.bookInfoRule?.init || ''}\n${source.tocRule?.chapterList || ''}\n${source.contentRule?.content || ''}`;
    return /loginCheck|loginUrl|loginUi|book-source-login|请先登[录陆]|需要登[录陆]|账号登[录陆]|网页登录|登[录陆]后/i.test(rules);
  }

  openReaderSourceLogin(): void {
    const source = this.currentReaderSource();
    if (!source || !this.readerSourceNeedsLogin()) return;
    this.showReaderActionMenu = false;
    this.showMenu = false;
    if (String(source.loginUi || '').trim()) {
      router.pushUrl({
        url: 'pages/BookSource',
        params: { openLoginSourceUrl: source.bookSourceUrl }
      });
      return;
    }
    const loginEntryUrl = this.verificationUrl || VerificationSupport.resolveBookSourceLoginUrl(source) ||
      VerificationSupport.pickVerificationUrl(source, source.bookSourceUrl);
    if (!loginEntryUrl || !/^https?:\/\//i.test(loginEntryUrl)) {
      promptAction.showToast({ message: '未找到可用的网页登录地址，请检查书源登录配置' });
      return;
    }
    VerificationSupport.requestVerification(loginEntryUrl, `${source.bookSourceName || '书源'} 登录`, source);
    router.pushUrl({
      url: 'pages/VerifyWeb',
      params: {
        url: loginEntryUrl,
        title: `${source.bookSourceName || '书源'} 登录`,
        requireLoginCookie: 'true'
      }
    });
  }

  readerCanRetry(): boolean {
    return (this.chapters.length === 0 && this.book?.origin !== 'local') || !!this.verificationUrl;
  }

  retryReaderContent(): void {
    this.hideReaderPanels();
    if (this.chapters.length === 0) {
      this.retryFetchChapters();
    } else {
      this.loadContent();
    }
  }

  @Builder
  readerTtsQuickActionButton() {
    Stack({ alignContent: Alignment.Center }) {
      ImmersiveBackButton({
        icon: $r('sys.symbol.play'),
        iconOffsetX: 0,
        iconColor: this.getTextColor(),
        darkMode: this.isReaderThemeDark(),
        buttonSize: 48,
        containerWidth: 48,
        containerHeight: 48,
        startInset: 0,
        compactLayout: true,
        accessibilityLabel: this.isTtsSpeaking ? '展开朗读控制' : '开始朗读',
        onBack: () => {
          this.openTtsQuickPlayer();
        }
      })

      if (this.isTtsSpeaking || this.ttsReader.isSpeaking()) {
        Circle()
          .width(9)
          .height(9)
          .fill(this.accentColor())
          .stroke(this.readerContentLayerColor())
          .strokeWidth(2)
          .position({ x: 38, y: 3 })
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width(48)
    .height(48)
    .position({ x: this.readerTtsQuickActionLeft(), y: '100%' })
    .translate({
      y: -(this.readerBottomMenuOverlayHeight() + 62)
    })
  }

  async openTtsQuickPlayer(): Promise<void> {
    if (this.isReaderComicModeActive()) return;
    this.showMenu = false;
    this.showToc = false;
    this.showSettings = false;
    this.ttsQuickOptionsPanel = 0;
    this.ttsMediaControlsExpanded = false;
    animateTo({ duration: 280, curve: Curve.Friction }, () => {
      this.showTtsQuickPlayer = true;
    });
    this.scrollTtsPanelToCurrentSentence(false);
    this.loadTtsSettingsAndVoices();
    if (!this.isTtsSpeaking && !this.ttsReader.isSpeaking()) {
      await this.startTtsReadingFromCurrentPosition(true);
      this.ttsMediaControlsExpanded = false;
    }
  }

  shouldShowTtsMiniPlayer(): boolean {
    return this.showMenu && !this.showTtsQuickPlayer && !this.isReaderComicModeActive() &&
      (this.isTtsSpeaking || this.ttsReader.isSpeaking()) && !this.shouldBlockReaderInteraction();
  }

  shouldShowGlobalTtsMiniPlayer(): boolean {
    return this.showMenu && this.globalTtsActive && !this.showGlobalTtsQuickPlayer &&
      !ReaderTtsFloatingSession.isOwner(this.ttsFloatingSessionOwnerId) &&
      !this.isReaderComicModeActive() && !this.shouldBlockReaderInteraction();
  }

  closeTtsQuickPlayer(): void {
    this.ttsQuickOptionsPanel = 0;
    animateTo({ duration: 190, curve: Curve.EaseIn }, () => {
      this.showTtsQuickPlayer = false;
    });
  }

  openGlobalTtsQuickPlayer(): void {
    this.globalTtsOptionsPanel = 0;
    animateTo({ duration: 280, curve: Curve.Friction }, () => {
      this.showGlobalTtsQuickPlayer = true;
    });
    this.scrollGlobalTtsPanelToCurrentSentence(false);
  }

  closeGlobalTtsQuickPlayer(): void {
    this.globalTtsOptionsPanel = 0;
    this.showGlobalTtsCatalog = false;
    animateTo({ duration: 190, curve: Curve.EaseIn }, () => {
      this.showGlobalTtsQuickPlayer = false;
    });
  }

  openGlobalTtsCatalog(): void {
    const titles = ReaderTtsFloatingSession.catalogTitles();
    if (titles.length === 0) {
      promptAction.showToast({ message: '暂未获取到听书目录' });
      return;
    }
    this.globalTtsCatalogSource.replace(titles);
    animateTo({ duration: 280, curve: Curve.Friction }, () => {
      this.showGlobalTtsCatalog = true;
    });
    setTimeout(() => {
      if (!this.showGlobalTtsCatalog) return;
      try {
        this.globalTtsCatalogScroller.scrollToIndex(
          ReaderTtsFloatingSession.catalogIndex(), false, ScrollAlign.CENTER);
      } catch (_) {}
    }, 0);
  }

  closeGlobalTtsCatalog(): void {
    animateTo({ duration: 210, curve: Curve.EaseIn }, () => {
      this.showGlobalTtsCatalog = false;
    });
  }

  selectGlobalTtsCatalog(index: number): void {
    this.closeGlobalTtsCatalog();
    ReaderTtsFloatingSession.selectCatalogIndex(index);
  }

  toggleTtsQuickOptions(panel: number): void {
    this.ttsQuickOptionsPanel = this.ttsQuickOptionsPanel === panel ? 0 : panel;
  }

  ttsMiniPlayerLeft(): number {
    return this.clampTtsMiniPlayerPositionX(this.ttsMiniPlayerPositionX);
  }

  ttsMiniPlayerTop(): number {
    const viewportHeight = this.pageViewHeight > 0 ? this.pageViewHeight : 720;
    const defaultTop = viewportHeight - this.navBarHeight - 68;
    return this.clampTtsMiniPlayerPositionY(this.ttsMiniPlayerPositionY < 0 ?
      defaultTop : this.ttsMiniPlayerPositionY);
  }

  clampTtsMiniPlayerPositionX(position: number): number {
    const viewportWidth = this.pageViewWidth > 0 ? this.pageViewWidth : 360;
    const capsuleWidth = 184;
    const edgeInset = 8;
    const minLeft = edgeInset;
    const maxLeft = Math.max(minLeft, viewportWidth - capsuleWidth - edgeInset);
    return Math.max(minLeft, Math.min(position, maxLeft));
  }

  clampTtsMiniPlayerPositionY(position: number): number {
    const viewportHeight = this.pageViewHeight > 0 ? this.pageViewHeight : 720;
    const minTop = this.getReaderTopSafePadding() + 8;
    const maxTop = Math.max(minTop, viewportHeight - this.navBarHeight - 54);
    return Math.max(minTop, Math.min(position, maxTop));
  }

  ttsMiniPlayerTransition(): TransitionEffect {
    const appear = TransitionEffect.scale({ x: 0.84, y: 0.84, centerX: '50%', centerY: '50%' })
      .combine(TransitionEffect.opacity(0))
      .animation({ duration: 240, curve: Curve.Friction });
    const disappear = TransitionEffect.scale({ x: 0.9, y: 0.9, centerX: '50%', centerY: '50%' })
      .combine(TransitionEffect.opacity(0))
      .animation({ duration: 170, curve: Curve.EaseIn });
    return TransitionEffect.asymmetric(appear, disappear);
  }

  @Builder
  ttsMiniPlayer() {
    Row({ space: 7 }) {
      Row({ space: 7 }) {
        Stack({ alignContent: Alignment.Center }) {
          Circle().width(30).height(30).fill(this.accentColor())
          SymbolGlyph($r('sys.symbol.speaker_wave_3'))
            .fontSize(15)
            .fontColor(['#FFFFFF'])
        }
        Column({ space: 1 }) {
          Text(this.isTtsPaused ? '已暂停' : '朗读中')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.getTextColor())
          Text(`${this.currentChapterIndex + 1}/${Math.max(1, this.chapters.length)}章`)
            .fontSize(9)
            .fontColor(this.getSubTextColor())
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .onClick(() => this.openTtsQuickPlayer())
      SymbolGlyph(this.isTtsPaused ? $r('sys.symbol.play') : $r('sys.symbol.pause'))
        .id(`tts_capsule_playback_${this.isTtsSpeaking}_${this.isTtsPaused}`)
        .fontSize(17)
        .fontColor([this.getTextColor()])
        .width(28)
        .height(34)
        .onClick(() => this.toggleTtsReading())
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(14)
        .fontColor([this.getSubTextColor()])
        .width(24)
        .height(34)
        .onClick(() => this.stopTtsReading())
    }
    .width(184)
    .height(46)
    .padding({ left: 8, right: 5 })
    .borderRadius(23)
    .clip(true)
    .backgroundColor(this.readerGlassPanelColor())
    .backdropBlur(ThemeRuntime.glassBlur('button', 18))
    .border({ width: ThemeRuntime.glassBorderWidth('button'), color: this.readerGlassBorderColor() })
    .shadow({ radius: ThemeRuntime.glassShadowRadius('button'), color: this.readerGlassShadowColor(),
      offsetX: ThemeRuntime.glassShadowOffsetX('button'), offsetY: ThemeRuntime.glassShadowOffsetY('button') })
    .position({ x: 0, y: 0 })
    .translate({
      x: this.ttsMiniPlayerLeft(),
      y: this.ttsMiniPlayerTop()
    })
    .parallelGesture(
      PanGesture({ direction: PanDirection.All, distance: 4 })
        .onActionStart(() => {
          this.ttsMiniPlayerDragOriginX = this.ttsMiniPlayerLeft();
          this.ttsMiniPlayerDragOriginY = this.ttsMiniPlayerTop();
        })
        .onActionUpdate((event: GestureEvent) => {
          this.ttsMiniPlayerPositionX = this.clampTtsMiniPlayerPositionX(
            this.ttsMiniPlayerDragOriginX + event.offsetX);
          this.ttsMiniPlayerPositionY = this.clampTtsMiniPlayerPositionY(
            this.ttsMiniPlayerDragOriginY + event.offsetY);
        })
    )
    .transition(this.ttsMiniPlayerTransition())
  }

  @Builder
  globalTtsMiniPlayer() {
    Row({ space: 7 }) {
      Row({ space: 7 }) {
        Stack({ alignContent: Alignment.Center }) {
          Circle().width(30).height(30).fill(this.accentColor())
          SymbolGlyph($r('sys.symbol.speaker_wave_3'))
            .fontSize(15)
            .fontColor(['#FFFFFF'])
        }
        Column({ space: 1 }) {
          Text(this.globalTtsPaused ? '已暂停' : (this.globalTtsMode === 'audio' ? '听书中' : '朗读中'))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.getTextColor())
          Text(this.globalTtsChapterProgress || (this.globalTtsMode === 'audio' ? '后台听书' : '后台朗读'))
            .fontSize(9)
            .fontColor(this.getSubTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .onClick(() => this.openGlobalTtsQuickPlayer())
      SymbolGlyph(this.globalTtsPaused ? $r('sys.symbol.play') : $r('sys.symbol.pause'))
        .id(`global_tts_capsule_playback_${this.globalTtsPaused}`)
        .fontSize(17)
        .fontColor([this.getTextColor()])
        .width(28)
        .height(34)
        .onClick(() => ReaderTtsFloatingSession.toggle())
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(14)
        .fontColor([this.getSubTextColor()])
        .width(24)
        .height(34)
        .onClick(() => {
          this.closeGlobalTtsQuickPlayer();
          ReaderTtsFloatingSession.stop();
        })
    }
    .width(184)
    .height(46)
    .padding({ left: 8, right: 5 })
    .borderRadius(23)
    .clip(true)
    .backgroundColor(this.readerGlassPanelColor())
    .backdropBlur(ThemeRuntime.glassBlur('button', 18))
    .border({ width: ThemeRuntime.glassBorderWidth('button'), color: this.readerGlassBorderColor() })
    .shadow({ radius: ThemeRuntime.glassShadowRadius('button'), color: this.readerGlassShadowColor(),
      offsetX: ThemeRuntime.glassShadowOffsetX('button'), offsetY: ThemeRuntime.glassShadowOffsetY('button') })
    .position({ x: 0, y: 0 })
    .translate({
      x: this.ttsMiniPlayerLeft(),
      y: this.ttsMiniPlayerTop()
    })
    .parallelGesture(
      PanGesture({ direction: PanDirection.All, distance: 4 })
        .onActionStart(() => {
          this.ttsMiniPlayerDragOriginX = this.ttsMiniPlayerLeft();
          this.ttsMiniPlayerDragOriginY = this.ttsMiniPlayerTop();
        })
        .onActionUpdate((event: GestureEvent) => {
          this.ttsMiniPlayerPositionX = this.clampTtsMiniPlayerPositionX(
            this.ttsMiniPlayerDragOriginX + event.offsetX);
          this.ttsMiniPlayerPositionY = this.clampTtsMiniPlayerPositionY(
            this.ttsMiniPlayerDragOriginY + event.offsetY);
        })
    )
    .transition(this.ttsMiniPlayerTransition())
  }

  @Builder
  globalTtsQuickPlayerOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.isReaderThemeDark() ? '#52000000' : '#26000000')
        .backdropBlur(ThemeRuntime.glassBlur('popover', 10))
        .onClick(() => this.closeGlobalTtsQuickPlayer())

      Column({ space: 14 }) {
        Row({ space: 11 }) {
          Stack({ alignContent: Alignment.Center }) {
            Circle().width(38).height(38).fill(ThemeRuntime.accentSurfaceColor(this.isReaderThemeDark()))
            SymbolGlyph($r('sys.symbol.speaker_wave_3'))
              .fontSize(19)
              .fontColor([this.accentColor()])
          }
          Column({ space: 3 }) {
            Text(this.globalTtsBookName || '快速朗读')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.getTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.globalTtsChapterTitle || this.globalTtsChapterProgress)
              .fontSize(11)
              .fontColor(this.getSubTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          ImmersiveBackButton({
            icon: $r('sys.symbol.chevron_down'), iconOffsetX: 0, iconColor: this.getTextColor(),
            darkMode: this.isReaderThemeDark(), buttonSize: 38, containerWidth: 38, containerHeight: 38,
            startInset: 0, compactLayout: true, accessibilityLabel: '收起快速朗读',
            onBack: () => this.closeGlobalTtsQuickPlayer()
          })
        }
        .width('100%')

        Column({ space: 8 }) {
          this.globalTtsQuickBookCover()
          if (this.globalTtsMode === 'audio') {
            Scroll() {
              Text(this.globalTtsContent || '暂无书籍简介')
                .fontSize(15)
                .fontColor(this.getTextColor())
                .lineHeight(25)
                .width('100%')
            }
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
            .layoutWeight(1)
            .width('100%')
            .padding({ left: 4, right: 4 })
            .scrollBar(BarState.Auto)
          } else {
            List({ scroller: this.globalTtsPanelTextScroller, space: 8 }) {
              ListItem() {
                Text(this.globalTtsTextBefore)
                  .fontSize(15)
                  .fontColor(this.getSubTextColor())
                  .lineHeight(25)
                  .width('100%')
              }
              ListItem() {
                Text(this.globalTtsCurrentText || '正在定位当前朗读内容…')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.getTextColor())
                  .lineHeight(26)
                  .width('100%')
                  .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                  .borderRadius(8)
                  .backgroundColor(this.isReaderThemeDark() ? '#24FFFFFF' : '#12000000')
              }
              ListItem() {
                Text(this.globalTtsTextAfter || (this.globalTtsContent ? '' : '正在准备当前朗读内容…'))
                  .fontSize(15)
                  .fontColor(this.getSubTextColor())
                  .lineHeight(25)
                  .width('100%')
              }
            }
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
            .layoutWeight(1)
            .width('100%')
            .padding({ left: 4, right: 4 })
            .scrollBar(BarState.Auto)
          }
          Row() {
            Text(this.globalTtsChapterProgress || '后台朗读')
              .fontSize(10)
              .fontColor(this.getSubTextColor())
              .layoutWeight(1)
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .padding(14)
        .borderRadius(14)
        .backgroundColor(ThemeRuntime.accentSurfaceColor(this.isReaderThemeDark()))

        if (this.globalTtsMode === 'audio') {
          this.globalTtsQuickAudioProgress()
        }

        Row() {
          this.ttsQuickControl($r('sys.symbol.timer'), this.globalTtsTimerMinutes > 0 ?
            `${Math.max(1, Math.ceil(this.globalTtsTimerRemainingSeconds / 60))}分` : '定时', true, false,
            () => this.globalTtsOptionsPanel = this.globalTtsOptionsPanel === 1 ? 0 : 1)
          this.ttsQuickControl($r('sys.symbol.arrow_left'), '上一章', this.globalTtsCanPrevious, false,
            () => ReaderTtsFloatingSession.previous())
          this.globalTtsQuickPlaybackControl()
          this.ttsQuickControl($r('sys.symbol.arrow_right'), '下一章', this.globalTtsCanNext, false,
            () => ReaderTtsFloatingSession.next())
          this.ttsQuickControl($r('sys.symbol.hourglass'), `${this.globalTtsSpeed.toFixed(1)}x`, true, false,
            () => this.globalTtsOptionsPanel = this.globalTtsOptionsPanel === 2 ? 0 : 2)
        }
        .width('100%')

        if (this.globalTtsOptionsPanel === 1) {
          Row({ space: 6 }) {
            this.globalTtsQuickTimerChip(0, '关闭')
            this.globalTtsQuickTimerChip(15, '15分')
            this.globalTtsQuickTimerChip(30, '30分')
            this.globalTtsQuickTimerChip(60, '60分')
            this.globalTtsQuickTimerChip(90, '90分')
            this.globalTtsQuickTimerChip(120, '120分')
          }
          .width('100%')
        } else if (this.globalTtsOptionsPanel === 2) {
          Row({ space: 8 }) {
            this.globalTtsQuickSpeedChip(0.8)
            this.globalTtsQuickSpeedChip(1.0)
            this.globalTtsQuickSpeedChip(1.2)
            this.globalTtsQuickSpeedChip(1.5)
            this.globalTtsQuickSpeedChip(2.0)
          }
          .width('100%')
        }

        if (this.globalTtsMode === 'audio') {
          Row({ space: 10 }) {
            Button(`音色 · ${this.globalTtsVoiceCode || '4'}`)
              .layoutWeight(1)
              .height(40)
              .backgroundColor(ThemeRuntime.inputColor(this.isReaderThemeDark()))
              .fontColor(this.getTextColor())
              .onClick(() => ReaderTtsFloatingSession.openVoice())
            Button('目录跳转')
              .layoutWeight(1)
              .height(40)
              .backgroundColor(ThemeRuntime.inputColor(this.isReaderThemeDark()))
              .fontColor(this.getTextColor())
              .onClick(() => this.openGlobalTtsCatalog())
          }
          .width('100%')
        }

        Button(this.globalTtsMode === 'audio' ? '停止听书' : '停止朗读')
          .width('100%')
          .height(42)
          .borderRadius(12)
          .fontColor('#FFFFFF')
          .backgroundColor('#D94841')
          .onClick(() => {
            this.closeGlobalTtsQuickPlayer();
            ReaderTtsFloatingSession.stop();
          })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 18, right: 18, top: this.statusBarSafeHeight + 16, bottom: this.navBarHeight + 16 })
      .borderRadius(0)
      .backgroundColor(this.readerGlassPanelColor())
      .backdropBlur(ThemeRuntime.glassBlur('panel', 24))
      .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: this.readerGlassBorderColor() })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: this.readerGlassShadowColor(),
        offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
      .transition(this.readerPanelTransition())
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  globalTtsQuickAudioProgress() {
    Column({ space: 2 }) {
      Slider({
        value: this.globalTtsAudioPositionMs,
        min: 0,
        max: Math.max(1, this.globalTtsAudioDurationMs),
        step: 1000
      })
        .width('100%')
        .selectedColor(this.accentColor())
        .trackColor(ThemeRuntime.inputColor(this.isReaderThemeDark()))
        .onChange((value: number, mode: SliderChangeMode) => {
          this.globalTtsAudioPositionMs = value;
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            ReaderTtsFloatingSession.seekAudio(value);
          }
        })
      Row() {
        Text(this.formatGlobalTtsAudioDuration(this.globalTtsAudioPositionMs))
          .fontSize(11)
          .fontColor(this.getSubTextColor())
        Blank()
        Text(this.formatGlobalTtsAudioDuration(this.globalTtsAudioDurationMs))
          .fontSize(11)
          .fontColor(this.getSubTextColor())
      }
      .width('100%')
    }
    .width('100%')
  }

  formatGlobalTtsAudioDuration(valueMs: number): string {
    const totalSeconds = Math.max(0, Math.floor((valueMs || 0) / 1000));
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const seconds = totalSeconds % 60;
    const mm = minutes.toString().padStart(2, '0');
    const ss = seconds.toString().padStart(2, '0');
    return hours > 0 ? `${hours}:${mm}:${ss}` : `${minutes}:${ss}`;
  }

  @Builder
  globalTtsCatalogOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#78000000')
        .onClick(() => this.closeGlobalTtsCatalog())
      Column({ space: 10 }) {
        Row() {
          Text('听书目录')
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.getTextColor())
          Blank()
          Text(`${ReaderTtsFloatingSession.catalogIndex() + 1} / ` +
            `${ReaderTtsFloatingSession.catalogTitles().length}`)
            .fontSize(12)
            .fontColor(this.getSubTextColor())
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(17)
            .fontColor([this.getTextColor()])
            .width(40)
            .height(40)
            .margin({ left: 6 })
            .onClick(() => this.closeGlobalTtsCatalog())
        }
        .width('100%')
        List({ scroller: this.globalTtsCatalogScroller, space: 4 }) {
          LazyForEach(this.globalTtsCatalogSource, (title: string, index: number) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(`${index + 1}`)
                  .fontSize(11)
                  .fontColor(index === ReaderTtsFloatingSession.catalogIndex() ? '#FFFFFF' :
                    this.getSubTextColor())
                  .textAlign(TextAlign.Center)
                  .width(34)
                  .height(26)
                  .borderRadius(13)
                  .backgroundColor(index === ReaderTtsFloatingSession.catalogIndex() ?
                    this.accentColor() : ThemeRuntime.inputColor(this.isReaderThemeDark()))
                Text(title || `第${index + 1}章`)
                  .fontSize(15)
                  .fontWeight(index === ReaderTtsFloatingSession.catalogIndex() ?
                    FontWeight.Bold : FontWeight.Regular)
                  .fontColor(index === ReaderTtsFloatingSession.catalogIndex() ?
                    this.accentColor() : this.getTextColor())
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')
              .constraintSize({ minHeight: 50 })
              .padding({ left: 8, right: 8, top: 7, bottom: 7 })
              .borderRadius(10)
              .backgroundColor(index === ReaderTtsFloatingSession.catalogIndex() ?
                ThemeRuntime.accentSurfaceColor(this.isReaderThemeDark()) : Color.Transparent)
              .onClick(() => this.selectGlobalTtsCatalog(index))
            }
          }, (title: string, index: number) => `${index}_${title}`)
        }
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
      }
      .width('100%')
      .height('72%')
      .padding({ left: 16, right: 16, top: 12, bottom: this.navBarHeight + 12 })
      .borderRadius({ topLeft: 22, topRight: 22 })
      .backgroundColor(this.readerGlassPanelColor())
      .transition(TransitionEffect.translate({ y: 520 })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 280, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
    .zIndex(90)
  }

  @Builder
  globalTtsQuickPlaybackControl() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(46)
          .height(46)
          .fill(this.accentColor())
        SymbolGlyph(this.globalTtsPaused ? $r('sys.symbol.play') : $r('sys.symbol.pause'))
          .id(`global_tts_panel_playback_${this.globalTtsPaused}`)
          .fontSize(23)
          .fontColor(['#FFFFFF'])
      }
      Text(this.globalTtsPaused ? '播放' : '暂停')
        .fontSize(10)
        .fontColor(this.getSubTextColor())
    }
    .layoutWeight(1)
    .height(68)
    .justifyContent(FlexAlign.Center)
    .onClick(() => ReaderTtsFloatingSession.toggle())
  }

  @Builder
  globalTtsQuickBookCover() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.globalTtsCover) {
        Image(this.globalTtsCover)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
        if (this.globalTtsCoverFrame) {
          Image(this.globalTtsCoverFrame)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
        }
      } else {
        Column() {
          Text(this.globalTtsBookName ? this.globalTtsBookName.substring(0, 1) : '书')
            .fontSize(42)
            .fontColor('#FFFFFF')
        }
        .width('58%')
        .height('88%')
        .constraintSize({ maxWidth: 260, maxHeight: 360 })
        .borderRadius(10)
        .backgroundColor(this.accentColor())
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height(this.ttsQuickCoverHeight())
    .padding(10)
    .borderRadius(14)
    .clip(true)
  }

  @Builder
  globalTtsQuickSpeedChip(value: number) {
    Text(`${value.toFixed(1)}x`)
      .fontSize(11)
      .fontWeight(Math.abs(this.globalTtsSpeed - value) < 0.01 ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(Math.abs(this.globalTtsSpeed - value) < 0.01 ? '#FFFFFF' : this.getTextColor())
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(30)
      .borderRadius(15)
      .backgroundColor(Math.abs(this.globalTtsSpeed - value) < 0.01 ? this.accentColor() :
        (this.isReaderThemeDark() ? '#20FFFFFF' : '#0D000000'))
      .onClick(() => ReaderTtsFloatingSession.setSpeed(value))
  }

  @Builder
  globalTtsQuickTimerChip(minutes: number, label: string) {
    Text(label)
      .fontSize(11)
      .fontWeight(this.globalTtsTimerMinutes === minutes ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.globalTtsTimerMinutes === minutes ? '#FFFFFF' : this.getTextColor())
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(30)
      .borderRadius(15)
      .backgroundColor(this.globalTtsTimerMinutes === minutes ? this.accentColor() :
        (this.isReaderThemeDark() ? '#20FFFFFF' : '#0D000000'))
      .onClick(() => ReaderTtsFloatingSession.setTimer(minutes))
  }

  @Builder
  ttsQuickPlayerOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.isReaderThemeDark() ? '#52000000' : '#26000000')
        .backdropBlur(ThemeRuntime.glassBlur('popover', 10))
        .onClick(() => this.closeTtsQuickPlayer())

      Column({ space: 14 }) {
        Row({ space: 11 }) {
          Stack({ alignContent: Alignment.Center }) {
            Circle().width(38).height(38).fill(ThemeRuntime.accentSurfaceColor(this.isReaderThemeDark()))
            SymbolGlyph($r('sys.symbol.speaker_wave_3'))
              .fontSize(19)
              .fontColor([this.accentColor()])
          }
          Column({ space: 3 }) {
            Text('快速朗读')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.getTextColor())
            Text(this.getChapterTitle(this.currentChapterIndex))
              .fontSize(11)
              .fontColor(this.getSubTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          ImmersiveBackButton({
            icon: $r('sys.symbol.chevron_down'), iconOffsetX: 0, iconColor: this.getTextColor(),
            darkMode: this.isReaderThemeDark(), buttonSize: 38, containerWidth: 38, containerHeight: 38,
            startInset: 0, compactLayout: true, accessibilityLabel: '收起快速朗读',
            onBack: () => this.closeTtsQuickPlayer()
          })
        }
        .width('100%')

        Column({ space: 8 }) {
          this.ttsQuickBookCover()
          List({ scroller: this.ttsPanelTextScroller, space: 8 }) {
            ListItem() {
              Text(this.ttsPanelTextBefore())
                .fontSize(15)
                .fontColor(this.getSubTextColor())
                .lineHeight(25)
                .width('100%')
            }
            ListItem() {
              Text(this.ttsCurrentSentence() || '正在定位当前朗读内容…')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.getTextColor())
                .lineHeight(26)
                .width('100%')
                .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                .borderRadius(8)
                .backgroundColor(this.isReaderThemeDark() ? '#24FFFFFF' : '#12000000')
            }
            ListItem() {
              Text(this.ttsPanelTextAfter())
                .fontSize(15)
                .fontColor(this.getSubTextColor())
                .lineHeight(25)
                .width('100%')
            }
          }
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 4, right: 4 })
          .scrollBar(BarState.Auto)
          Row() {
            Text(this.ttsQuickProgressLabel())
              .fontSize(10)
              .fontColor(this.getSubTextColor())
              .layoutWeight(1)
            Text(this.selectedTtsVoiceTitle())
              .fontSize(10)
              .fontColor(this.getSubTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 150 })
          }
          .width('100%')
          Progress({ value: this.ttsQuickProgress(), total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(3)
            .color(this.accentColor())
            .backgroundColor(this.isReaderThemeDark() ? '#34FFFFFF' : '#18000000')
        }
        .width('100%')
        .layoutWeight(1)
        .padding(14)
        .borderRadius(14)
        .backgroundColor(ThemeRuntime.accentSurfaceColor(this.isReaderThemeDark()))

        Row() {
          this.ttsQuickControl($r('sys.symbol.timer'), this.ttsSleepTimerMinutes > 0 ?
            `${Math.max(1, Math.ceil(this.ttsSleepTimerRemainingSeconds / 60))}分` : '定时', true, false,
            () => this.toggleTtsQuickOptions(1))
          this.ttsQuickControl($r('sys.symbol.arrow_left'), '上一章', this.canPlayPreviousTtsChapter(), false,
            () => this.playPreviousChapterFromMediaSession())
          this.ttsQuickPlaybackControl()
          this.ttsQuickControl($r('sys.symbol.arrow_right'), '下一章', this.canPlayNextTtsChapter(), false,
            () => this.playNextChapterFromMediaSession())
          this.ttsQuickControl($r('sys.symbol.hourglass'), `${this.ttsSpeed.toFixed(1)}x`, true, false,
            () => this.toggleTtsQuickOptions(2))
        }
        .width('100%')

        if (this.ttsQuickOptionsPanel === 1) {
          Row({ space: 6 }) {
            this.ttsQuickSleepTimerChip(0, '关闭')
            this.ttsQuickSleepTimerChip(15, '15分')
            this.ttsQuickSleepTimerChip(30, '30分')
            this.ttsQuickSleepTimerChip(60, '60分')
            this.ttsQuickSleepTimerChip(90, '90分')
            this.ttsQuickSleepTimerChip(120, '120分')
          }
          .width('100%')
        } else if (this.ttsQuickOptionsPanel === 2) {
          Row({ space: 8 }) {
            this.ttsQuickSpeedChip(0.8)
            this.ttsQuickSpeedChip(1.0)
            this.ttsQuickSpeedChip(1.2)
            this.ttsQuickSpeedChip(1.5)
            this.ttsQuickSpeedChip(2.0)
          }
          .width('100%')
        }

        this.ttsQuickVoiceSelect()
        Button('停止朗读')
          .width('100%')
          .height(42)
          .borderRadius(12)
          .fontColor('#FFFFFF')
          .backgroundColor('#D94841')
          .onClick(() => {
            this.closeTtsQuickPlayer();
            this.stopTtsReading();
          })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 18, right: 18, top: this.statusBarSafeHeight + 16, bottom: this.navBarHeight + 16 })
      .borderRadius(0)
      .backgroundColor(this.readerGlassPanelColor())
      .backdropBlur(ThemeRuntime.glassBlur('panel', 24))
      .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: this.readerGlassBorderColor() })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: this.readerGlassShadowColor(),
        offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
      .transition(this.readerPanelTransition())
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  ttsQuickVoiceSelect() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.speaker_wave_3'))
        .fontSize(17)
        .fontColor([this.accentColor()])
        .width(24)
      Select(this.ttsQuickVoiceOptions())
        .selected(this.ttsQuickVoiceSelectedIndex())
        .value(this.selectedTtsVoiceTitle())
        .font({ size: 13 })
        .fontColor(this.getTextColor())
        .layoutWeight(1)
        .height(40)
        .padding({ left: 0, right: 0 })
        .backgroundColor(Color.Transparent)
        .border({ width: 0 })
        .borderRadius(0)
        .optionBgColor(Color.Transparent)
        .optionFontColor(this.getTextColor())
        .selectedOptionFontColor(this.accentColor())
        .selectedOptionBgColor(ThemeRuntime.accentSurfaceColor(this.isReaderThemeDark()))
        .menuBackgroundColor(ThemeRuntime.dropdownPanelColor(this.isReaderThemeDark(), this.getBackgroundColor()))
        .menuBackgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
        .onSelect((index: number) => this.selectTtsQuickVoice(index))
    }
    .width('100%')
    .height(44)
    .padding({ left: 12, right: 10 })
    .borderRadius(12)
    .backgroundColor(this.isReaderThemeDark() ? '#20FFFFFF' : '#0D000000')
  }

  @Builder
  ttsQuickPlaybackControl() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(46)
          .height(46)
          .fill(this.accentColor())
        SymbolGlyph(this.isTtsSpeaking && !this.isTtsPaused ?
          $r('sys.symbol.pause') : $r('sys.symbol.play'))
          .id(`tts_panel_playback_${this.isTtsSpeaking}_${this.isTtsPaused}`)
          .fontSize(23)
          .fontColor(['#FFFFFF'])
      }
      Text(this.isTtsSpeaking && !this.isTtsPaused ? '暂停' : '播放')
        .fontSize(10)
        .fontColor(this.getSubTextColor())
    }
    .layoutWeight(1)
    .height(68)
    .justifyContent(FlexAlign.Center)
    .onClick(() => this.toggleTtsReading())
  }

  @Builder
  ttsQuickControl(icon: Resource, label: string, enabled: boolean, primary: boolean, action: () => void) {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(primary ? 46 : 38)
          .height(primary ? 46 : 38)
          .fill(primary ? this.accentColor() :
            (this.isReaderThemeDark() ? '#24FFFFFF' : '#10000000'))
        SymbolGlyph(icon)
          .fontSize(primary ? 23 : 19)
          .fontColor([enabled ? (primary ? '#FFFFFF' : this.getTextColor()) : this.getSubTextColor()])
      }
      Text(label)
        .fontSize(10)
        .fontColor(enabled ? this.getSubTextColor() : this.getSubTextColor())
    }
    .layoutWeight(1)
    .height(68)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      if (enabled) action();
    })
  }

  @Builder
  ttsQuickSpeedChip(value: number) {
    Text(`${value.toFixed(1)}x`)
      .fontSize(11)
      .fontWeight(Math.abs(this.ttsSpeed - value) < 0.01 ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(Math.abs(this.ttsSpeed - value) < 0.01 ? '#FFFFFF' : this.getTextColor())
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(30)
      .borderRadius(15)
      .backgroundColor(Math.abs(this.ttsSpeed - value) < 0.01 ? this.accentColor() :
        (this.isReaderThemeDark() ? '#20FFFFFF' : '#0D000000'))
      .onClick(() => this.applyTtsSpeed(value))
  }

  @Builder
  ttsQuickSleepTimerChip(minutes: number, label: string) {
    Text(label)
      .fontSize(11)
      .fontWeight(this.ttsSleepTimerMinutes === minutes ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.ttsSleepTimerMinutes === minutes ? '#FFFFFF' : this.getTextColor())
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(30)
      .borderRadius(15)
      .backgroundColor(this.ttsSleepTimerMinutes === minutes ? this.accentColor() :
        (this.isReaderThemeDark() ? '#20FFFFFF' : '#0D000000'))
      .onClick(() => this.setTtsSleepTimer(minutes))
  }

  @Builder
  ttsQuickBookCover() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.shouldUseTtsThemeBookCover()) {
        if (this.activeTtsThemeBookCovers().length === 1) {
          Image(this.activeTtsThemeBookCovers()[0])
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
        } else {
          Swiper() {
            ForEach(this.activeTtsThemeBookCovers(), (cover: ResourceStr, index: number) => {
              Image(cover)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Contain)
            }, (_cover: ResourceStr, index: number) => `${this.bookUrl}_tts_theme_${index}`)
          }
          .width('100%')
          .height('100%')
          .autoPlay(true)
          .interval(this.ttsThemeBookCoverInterval())
          .indicator(false)
          .loop(true)
        }
        Image(this.activeTtsThemeShelfFrame())
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
      } else if (this.getTtsPanelCoverList().length === 0) {
        Column() {
          Text(this.book?.name ? this.book.name.substring(0, 1) : '书')
            .fontSize(48)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
        }
        .width('62%')
        .height('88%')
        .constraintSize({ maxWidth: 320, maxHeight: 450 })
        .borderRadius(10)
        .backgroundColor(this.getTtsCoverPlaceholderColor())
        .justifyContent(FlexAlign.Center)
      } else if (this.getTtsPanelCoverList().length === 1) {
        Image(this.getTtsPanelCoverList()[0])
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
      } else {
        Swiper() {
          ForEach(this.getTtsPanelCoverList(), (cover: string) => {
            Image(cover)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Contain)
          }, (cover: string) => cover)
        }
        .width('100%')
        .height('100%')
        .autoPlay(true)
        .interval(3500)
        .indicator(false)
        .loop(true)
      }
    }
    .width('100%')
    .height(this.ttsQuickCoverHeight())
    .padding(10)
    .borderRadius(14)
    .clip(true)
  }

  ttsCurrentSentence(): string {
    if (this.ttsHighlightStart < 0 || this.ttsHighlightEnd <= this.ttsHighlightStart || !this.ttsDisplayText) {
      return '';
    }
    const source = this.ttsPanelOffsetSource();
    return this.cleanTtsPanelSlice(source.substring(this.ttsHighlightStart, this.ttsHighlightEnd));
  }

  ttsQuickSentencePreview(): string {
    const source = this.cleanTtsPanelSlice(this.ttsPanelOffsetSource());
    if (source) {
      return source;
    }
    const sentence = this.ttsCurrentSentence();
    const fallback = this.cleanTtsPanelSlice(this.ttsOffsetSanitizedText(this.content)).substring(0, 3000);
    return sentence || fallback || '正在准备当前页的朗读内容…';
  }

  ttsPanelTextBefore(): string {
    const source = this.ttsPanelOffsetSource();
    if (this.ttsHighlightStart <= 0) return '';
    return this.cleanTtsPanelSlice(
      source.substring(Math.max(0, this.ttsHighlightStart - 600), this.ttsHighlightStart));
  }

  ttsPanelTextAfter(): string {
    const source = this.ttsPanelOffsetSource();
    const start = this.ttsHighlightEnd > this.ttsHighlightStart ? this.ttsHighlightEnd : 0;
    return this.cleanTtsPanelSlice(source.substring(start, Math.min(source.length, start + 900)));
  }

  ttsPanelOffsetSource(): string {
    return this.ttsOffsetSanitizedText(this.ttsDisplayText || this.currentPageText || '');
  }

  ttsOffsetSanitizedText(text: string): string {
    let source = ReaderActionMarker.strip(LocalBookService.stripEpubImageMarkers(text || '', true), true);
    for (const prefix of [ReaderActionMarker.PREFIX, ReaderActionMarker.LEGACY_PREFIX,
      ReaderActionMarker.ORIGINAL_PREFIX]) {
      let start = source.indexOf(prefix);
      while (start >= 0) {
        const lineEnd = source.indexOf('\n', start);
        const end = lineEnd >= 0 ? lineEnd : source.length;
        source = `${source.substring(0, start)}${' '.repeat(end - start)}${source.substring(end)}`;
        start = source.indexOf(prefix, end);
      }
    }
    return source;
  }

  cleanTtsPanelSlice(text: string): string {
    return (text || '')
      .replace(/[ \t]{2,}/g, ' ')
      .replace(/[ \t]*\n[ \t]*/g, '\n')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
  }

  ttsPanelFollowingText(): string {
    const before = this.ttsPanelTextBefore();
    const current = this.ttsCurrentSentence();
    const after = this.ttsPanelTextAfter();
    return [before, current, after].filter((value: string): boolean => !!value).join('\n');
  }

  scrollTtsPanelToCurrentSentence(smooth: boolean = true): void {
    setTimeout(() => {
      if (!this.showTtsQuickPlayer) return;
      try {
        this.ttsPanelTextScroller.scrollToIndex(1, smooth, ScrollAlign.CENTER);
      } catch (_) {}
    }, 0);
  }

  scrollGlobalTtsPanelToCurrentSentence(smooth: boolean = true): void {
    setTimeout(() => {
      if (!this.showGlobalTtsQuickPlayer || this.globalTtsMode === 'audio') return;
      try {
        this.globalTtsPanelTextScroller.scrollToIndex(1, smooth, ScrollAlign.CENTER);
      } catch (_) {}
    }, 0);
  }

  ttsQuickCoverHeight(): number {
    const viewportHeight = this.pageViewHeight > 0 ? this.pageViewHeight : 720;
    return Math.min(250, Math.max(130,
      (viewportHeight - this.statusBarSafeHeight - this.navBarHeight) * 0.32));
  }

  ttsQuickProgressLabel(): string {
    return `第 ${this.currentChapterIndex + 1}/${Math.max(1, this.chapters.length)} 章 · ` +
      `第 ${this.currentPageIndex + 1}/${Math.max(1, this.contentPages.length)} 页`;
  }

  ttsQuickProgress(): number {
    const chapterCount = Math.max(1, this.chapters.length);
    const pageCount = Math.max(1, this.contentPages.length);
    return Math.max(0, Math.min(100,
      ((this.currentChapterIndex + (this.currentPageIndex + 1) / pageCount) / chapterCount) * 100));
  }

  @Builder
  bookmarkMultiSelectAction(bookmark: Bookmark) {
    Column({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.checkmark_circle'))
        .fontSize(22)
        .fontColor(['#FFFFFF'])
      Text('多选')
        .fontSize(11)
        .fontColor('#FFFFFF')
    }
    .width(64)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.accentColor())
    .onClick(() => {
      this.enterBookmarkMultiSelect(bookmark.id);
    })
  }

  showBookmarkActions(bookmark: Bookmark, event: GestureEvent): void {
    if (event.fingerList.length > 0) {
      const finger = event.fingerList[0];
      this.bookmarkActionMenuX = finger.globalX;
      this.bookmarkActionMenuY = finger.globalY;
    }
    this.pendingBookmarkAction = bookmark;
    this.showBookmarkActionMenu = true;
  }

  closeBookmarkActionMenu(): void {
    this.showBookmarkActionMenu = false;
    this.pendingBookmarkAction = null;
  }

  bookmarkActionMenuLeft(menuWidth: number): number {
    const viewportWidth = this.pageViewWidth > 0 ? this.pageViewWidth : 360;
    return Math.max(12, Math.min(this.bookmarkActionMenuX - 18, viewportWidth - menuWidth - 12));
  }

  bookmarkActionMenuTop(menuHeight: number): number {
    const viewportHeight = this.pageViewHeight > 0 ? this.pageViewHeight : 720;
    const below = this.bookmarkActionMenuY + 12;
    if (below + menuHeight <= viewportHeight - 12) {
      return below;
    }
    return Math.max(this.getReaderTopSafePadding() + 8, this.bookmarkActionMenuY - menuHeight - 12);
  }

  @Builder
  bookmarkActionMenu() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.isReaderThemeDark() ? '#52000000' : '#26FFFFFF')
        .backdropBlur(ThemeRuntime.glassBlur('popover', 18))
        .onClick(() => {
          this.closeBookmarkActionMenu();
        })

      Column() {
        this.bookmarkContextActionItem($r('sys.symbol.checkmark_circle'), '多选', this.getTextColor(), () => {
          if (this.pendingBookmarkAction) {
            const bookmarkId = this.pendingBookmarkAction.id;
            this.closeBookmarkActionMenu();
            this.enterBookmarkMultiSelect(bookmarkId);
          }
        })
        this.bookmarkContextActionItem($r('sys.symbol.trash'), '删除', '#E53935', () => {
          if (this.pendingBookmarkAction) {
            const bookmark = this.pendingBookmarkAction;
            this.closeBookmarkActionMenu();
            this.deleteBookmark(bookmark);
          }
        })
      }
      .width(148)
      .padding({ top: 6, bottom: 6 })
      .backgroundColor(this.readerGlassPanelColor())
      .borderRadius(ThemeRuntime.glassCornerRadius(14, 'panel'))
      .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
      .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: this.readerGlassBorderColor() })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: this.readerGlassShadowColor(), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
      .position({ x: this.bookmarkActionMenuLeft(148), y: this.bookmarkActionMenuTop(100) })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  bookmarkContextActionItem(icon: Resource, label: string, color: string, action: () => void) {
    Row({ space: 12 }) {
      SymbolGlyph(icon)
        .fontSize(21)
        .fontColor([color])
        .width(26)
      Text(label)
        .fontSize(15)
        .fontColor(color)
        .layoutWeight(1)
    }
    .width('100%')
    .height(44)
    .padding({ left: 14, right: 14 })
    .alignItems(VerticalAlign.Center)
    .onClick(action)
  }

  getTocCover(): string {
    return this.book ? this.book.getDisplayCover() : '';
  }

  getTocBookInitial(): string {
    const name = (this.book?.name || '书').trim();
    return name.length > 0 ? name.substring(0, 1) : '书';
  }

  getChapterTitle(chapterIndex: number = this.currentChapterIndex): string {
    if (this.chapters.length === 0) return '暂无目录';
    const chapter = this.chapters[this.clampChapterIndex(chapterIndex)];
    const title = chapter ? this.cleanChapterTitle(chapter.title) : '';
    return ReaderReplaceRuleStore.applyTitle(title, this.readerReplaceRules, this.book);
  }

  applyReaderContentRules(content: string): string {
    return ReaderReplaceRuleStore.applyContent(content, this.readerReplaceRules, this.book);
  }

  readerPreparedContentKey(content: string, chapterIndex: number): string {
    return `${chapterIndex}_${content.length}_${this.hashText(content)}_${this.readerReplaceRules.length}_` +
      `${this.readerReplaceRulesUpdateTime}`;
  }

  getPreparedReaderContent(content: string, chapterIndex: number): string {
    return this.readerPreparedContentCache.get(this.readerPreparedContentKey(content, chapterIndex)) || '';
  }

  async prepareReaderContentRules(content: string, chapterIndex: number): Promise<string> {
    if (!content) return '';
    const key = this.readerPreparedContentKey(content, chapterIndex);
    const cached = this.readerPreparedContentCache.get(key);
    if (cached !== undefined) return cached;
    const startedAt = Date.now();
    const processed = await ReaderContentPreprocessor.apply(content, this.readerReplaceRules, this.book);
    const elapsedMs = Math.max(0, Date.now() - startedAt);
    if (elapsedMs >= CooperativeScheduler.DANGEROUS_OPERATION_MS) {
      console.info(`[ReaderPreprocessor] worker elapsed=${elapsedMs}ms input=${content.length}`);
    }
    this.readerPreparedContentCache.set(key, processed);
    while (this.readerPreparedContentCache.size > 8) {
      const oldestKey = this.readerPreparedContentCache.keys().next().value as string | undefined;
      if (!oldestKey) break;
      this.readerPreparedContentCache.delete(oldestKey);
    }
    // Do not begin native paragraph measurement in the same event-loop turn that publishes a
    // potentially large TaskPool result.
    await CooperativeScheduler.yieldToEventLoop();
    return processed;
  }

  onReaderReplaceRulesChanged(): void {
    if (this.readerEntryInitializing || !this.readerPageVisible) {
      return;
    }
    this.reloadReaderReplaceRules(true).catch((error: Error) => {
      console.warn('更新替换净化规则失败:', error);
    });
  }

  async reloadReaderReplaceRules(repaginate: boolean): Promise<void> {
    const nextRules = await ReaderReplaceRuleStore.load(getContext(this), true);
    const rulesChanged = JSON.stringify(nextRules) !== JSON.stringify(this.readerReplaceRules);
    this.readerReplaceRules = nextRules;
    if (!rulesChanged) {
      return;
    }
    this.readerPaginationCache.clear();
    this.readerPreparedContentCache.clear();
    this.adjacentPaginationPreloadSerial++;
    this.pageTurnPreviewKey = '';
    this.pageTurnPreviewLoadingKey = '';
    if (!repaginate || !this.book || this.chapters.length === 0) {
      return;
    }
    this.pendingRestorePageIndex = Math.max(this.pendingRestorePageIndex, this.currentPageIndex);
    const raw = ReadBookEngine.get().getCachedContent(this.currentChapterIndex);
    if (!raw) {
      return;
    }
    const processed = await this.prepareReaderContentRules(raw, this.currentChapterIndex);
    this.content = processed;
    this.paginateContent(processed, this.currentChapterIndex);
    this.refreshReaderTextRender();
  }

  cleanChapterTitle(title: string): string {
    const original = (title || '').trim();
    const cleaned = original
      .replace(/\s+/g, ' ')
      .replace(/[\s·|｜/／-]*上次(?:阅读|閱讀)(?:[\s:：，,。]*.*)?$/g, '')
      .replace(/^上次(?:阅读|閱讀)[\s:：，,。]*/g, '')
      .trim();
    return cleaned || original;
  }

  updatePendingVerification(): void {
    this.verificationUrl = AppStorage.get<string>('pendingVerificationUrl') || '';
    this.verificationTitle = AppStorage.get<string>('pendingVerificationTitle') || '网页验证';
  }

  openVerificationPage(): void {
    const url = this.verificationUrl || AppStorage.get<string>('pendingVerificationUrl') || '';
    if (!url) return;
    router.pushUrl({
      url: 'pages/VerifyWeb',
      params: {
        url: url,
        title: this.verificationTitle || '网页验证'
      }
    });
  }

  getProgressText(): string {
    if (this.chapters.length === 0) return '';
    if (this.contentPages.length === 0) {
      return `${this.currentChapterIndex + 1}/${this.chapters.length}`;
    }
    const pageText = this.isLandscapeDoublePageActive() ?
      `${this.currentPageIndex + 1}-${Math.min(this.currentPageIndex + 2, this.contentPages.length)}` :
      `${this.currentPageIndex + 1}`;
    return `${this.currentChapterIndex + 1}/${this.chapters.length} · ${pageText}/${this.contentPages.length}`;
  }

  getChapterInfoText(): string {
    if (this.chapters.length === 0) {
      return this.book?.name || '暂无目录';
    }
    const index = this.clampChapterIndex(this.currentChapterIndex);
    const chapter = this.chapters[index];
    return `${index + 1}/${this.chapters.length} ${chapter ? this.getChapterTitle(index) : this.getChapterTitle()}`;
  }

  getPageInfoText(): string {
    if (this.contentPages.length === 0) {
      return '1/1';
    }
    const index = Math.max(0, Math.min(this.currentPageIndex, this.contentPages.length - 1));
    if (this.isLandscapeDoublePageActive()) {
      const end = Math.min(index + 2, this.contentPages.length);
      return `${index + 1}-${end}/${this.contentPages.length}`;
    }
    return `${index + 1}/${this.contentPages.length}`;
  }

  getPageText(pageIndex: number): string {
    if (this.contentPages.length === 0) {
      if (this.content && !this.hasPagedReaderArea()) {
        return '';
      }
      return this.content;
    }
    const index = Math.max(0, Math.min(pageIndex, this.contentPages.length - 1));
    return this.contentPages[index];
  }

  getCurrentPageText(): string {
    return this.getPageText(this.currentPageIndex);
  }

  isLandscapeDoublePageActive(): boolean {
    return this.readerLandscapeDoublePage &&
      (this.pageViewWidth > this.pageViewHeight || this.pageViewWidth >= 600) &&
      !this.isReaderContinuousScrollSurfaceActive();
  }

  initializeReaderComicMode(): void {
    const manualMode = this.book?.getVariable('readerComicManualMode') || '';
    const autoDetected = this.book?.getVariable('readerComicAutoDetected') === '1';
    this.readerComicMode = manualMode === 'comic' ||
      (manualMode !== 'text' && (autoDetected || this.readerSourceIndicatesComic()));
    if (this.readerComicMode) {
      this.stopTtsReading();
      this.showSettings = false;
      this.ttsMediaControlsExpanded = false;
    }
    this.enterReaderImmersive();
  }

  readerSourceIndicatesComic(): boolean {
    const source = this.currentReaderSource();
    if (BookTypeSupport.isImage(this.book)) {
      return true;
    }
    // Legado's "full" imageStyle only controls how inline illustrations fill the
    // reader width. Text sources such as 神魔小说 use it as well, so it must not
    // switch the whole book to the continuous comic renderer.
    if (source && (source.bookSourceType === 2 ||
      /^(?:comic|manga|webtoon)$/i.test(source.contentRule?.imageStyle || ''))) {
      return true;
    }
    const bookIdentity = `${this.book?.kind || ''}\n${this.book?.customTag || ''}`;
    const sourceIdentity = source ? `${source.bookSourceGroup || ''}\n${source.bookSourceName || ''}` : '';
    return /漫画|漫話|条漫|條漫|コミック|comic|manga|manhua|webtoon/i.test(
      `${bookIdentity}\n${sourceIdentity}`);
  }

  detectReaderComicMode(_source: string): void {
    if (this.readerComicMode || !this.readerSourceIndicatesComic() ||
      this.book?.getVariable('readerComicManualMode') === 'text') return;
    this.readerComicMode = true;
    this.showSettings = false;
    this.ttsMediaControlsExpanded = false;
    this.stopTtsReading();
    this.enterReaderImmersive();
  }

  toggleReaderComicReadingMode(): void {
    if (!this.book) return;
    const next = !this.isReaderComicModeActive();
    this.stopTtsReading();
    this.readerComicMode = next;
    this.book.putVariable('readerComicManualMode', next ? 'comic' : 'text');
    // 继续写入旧字段，兼容已有导入导出数据；实际判定优先读取手动模式字段。
    this.book.putVariable('readerComicMode', next ? '1' : '0');
    AppDatabase.getInstance().updateBook(this.book, false).catch((error: Error) => {
      console.warn('保存阅读模式失败:', error);
    });
    this.showReaderActionMenu = false;
    this.showSettings = false;
    this.ttsMediaControlsExpanded = false;
    this.resetSlidePageEffect();
    this.syncReaderComicPageDataSource();
    if (next) {
      this.scheduleReaderComicScrollRestore();
    }
    this.enterReaderImmersive();
    promptAction.showToast({ message: next ? '已切换为漫画阅读' : '已切换为普通阅读' });
  }

  isReaderComicModeActive(): boolean {
    return this.readerComicMode;
  }

  isReaderNovelContinuousScrollModeActive(): boolean {
    return !this.isReaderComicModeActive() && this.readerPageTurnMode === 3 && !this.ttsPagedScrollOverride;
  }

  isReaderContinuousScrollSurfaceActive(): boolean {
    return this.isReaderComicModeActive() || this.isReaderNovelContinuousScrollModeActive();
  }

  readerEffectivePageTurnMode(): number {
    return this.ttsPagedScrollOverride && this.readerPageTurnMode === 3 ? 0 : this.readerPageTurnMode;
  }

  comicBoundaryChapterSwipeDirection(offsetY: number): number {
    if (!this.isReaderContinuousScrollSurfaceActive() || this.readerComicChapterSwitching || Math.abs(offsetY) < 2) {
      return 0;
    }
    try {
      if (offsetY < 0 && this.currentChapterIndex < this.chapters.length - 1 &&
        this.readerComicScroller.isAtEnd()) {
        return 1;
      }
      if (offsetY > 0 && this.currentChapterIndex > 0 &&
        this.readerComicScroller.currentOffset().yOffset <= 1) {
        return -1;
      }
    } catch (error) {
      console.warn('判断漫画章节滚动边界失败:', error);
    }
    return 0;
  }

  beginReaderComicPan(): void {
    if (this.readerComicChapterSwitching) return;
    this.readerComicPanLastOffsetY = 0;
    this.readerComicPanMoved = false;
    this.readerComicBoundaryPullOriginY = 0;
    this.resetReaderComicBoundaryFeedback(false);
  }

  updateReaderComicPan(event: GestureEvent): void {
    if (this.readerComicChapterSwitching) return;
    const previousOffsetY = this.readerComicPanLastOffsetY;
    const deltaY = event.offsetY - previousOffsetY;
    this.readerComicPanLastOffsetY = event.offsetY;
    if (Math.abs(event.offsetY) > 3) this.readerComicPanMoved = true;
    this.readerComicScroller.scrollBy(0, -deltaY);

    const direction = this.comicBoundaryChapterSwipeDirection(event.offsetY);
    if (direction === 0) {
      if (this.readerComicBoundaryDirection !== 0) this.resetReaderComicBoundaryFeedback(true);
      return;
    }
    if (direction !== this.readerComicBoundaryDirection) {
      this.readerComicBoundaryDirection = direction;
      this.readerComicBoundaryPullOriginY = previousOffsetY;
    }
    const distance = Math.min(88, Math.abs(event.offsetY - this.readerComicBoundaryPullOriginY));
    this.readerComicBoundaryPullDistance = distance;
    this.readerComicBoundaryReady = distance >= 48;
    this.readerComicChapterTransitionY = (direction < 0 ? 1 : -1) * Math.min(20, distance * 0.3);
    this.readerComicChapterTransitionOpacity = 1;
  }

  finishReaderComicPan(event: GestureEvent): void {
    if (this.readerComicChapterSwitching) return;
    const chapterDirection = this.readerComicBoundaryReady ? this.readerComicBoundaryDirection : 0;
    const hadBoundaryPull = this.readerComicBoundaryDirection !== 0;
    if (chapterDirection !== 0) {
      this.readerComicSuppressClickUntil = Date.now() + 360;
      this.switchComicBoundaryChapter(chapterDirection);
    } else {
      if (this.readerComicPanMoved && !hadBoundaryPull) {
        this.readerComicSuppressClickUntil = Date.now() + 220;
        this.readerComicScroller.fling(event.velocityY);
      }
      this.resetReaderComicBoundaryFeedback(true);
    }
    this.readerComicPanLastOffsetY = 0;
    this.readerComicPanMoved = false;
    this.readerComicBoundaryPullOriginY = 0;
  }

  cancelReaderComicPan(): void {
    this.readerComicPanLastOffsetY = 0;
    this.readerComicPanMoved = false;
    this.readerComicBoundaryPullOriginY = 0;
    this.resetReaderComicBoundaryFeedback(true);
  }

  resetReaderComicBoundaryFeedback(animated: boolean): void {
    this.readerComicBoundaryDirection = 0;
    this.readerComicBoundaryPullDistance = 0;
    this.readerComicBoundaryReady = false;
    if (this.readerComicChapterSwitching) return;
    if (animated) {
      animateTo({ duration: 150, curve: Curve.EaseOut }, () => {
        this.readerComicChapterTransitionY = 0;
        this.readerComicChapterTransitionOpacity = 1;
      });
    } else {
      this.readerComicChapterTransitionY = 0;
      this.readerComicChapterTransitionOpacity = 1;
    }
  }

  readerComicBoundaryHintText(): string {
    const previous = this.readerComicBoundaryDirection < 0;
    if (this.readerComicChapterSwitching) return previous ? '正在加载上一章…' : '正在加载下一章…';
    if (this.readerComicBoundaryReady) return previous ? '松开加载上一章' : '松开加载下一章';
    return previous ? '下拉加载上一章' : '上滑加载下一章';
  }

  switchComicBoundaryChapter(direction: number): void {
    if (direction === 0 || this.readerComicChapterSwitching) return;
    this.runReaderComicChapterTransition(direction).catch((error: Error) => {
      console.error('滚动切换漫画章节失败:', error);
    });
  }

  async runReaderComicChapterTransition(direction: number): Promise<void> {
    if (direction === 0 || this.readerComicChapterSwitching) return;
    const startedAt = Date.now();
    const sourceChapterIndex = this.currentChapterIndex;
    this.readerComicChapterSwitching = true;
    this.readerComicBoundaryDirection = direction;
    this.readerComicBoundaryPullDistance = Math.max(48, this.readerComicBoundaryPullDistance);
    this.readerComicBoundaryReady = true;
    animateTo({ duration: 110, curve: Curve.EaseIn }, () => {
      this.readerComicChapterTransitionY = direction > 0 ? -34 : 34;
      this.readerComicChapterTransitionOpacity = 0.18;
    });
    await this.delay(112);
    try {
      if (direction > 0) {
        await this.loadNextChapter(false, false);
      } else {
        await this.loadPrevChapter(true, false, false);
      }
      const switched = this.currentChapterIndex !== sourceChapterIndex;
      this.readerComicChapterTransitionY = switched ? (direction > 0 ? 28 : -28) :
        (direction > 0 ? -20 : 20);
      this.readerComicChapterTransitionOpacity = switched ? 0 : 0.35;
      await this.delay(24);
      animateTo({ duration: 220, curve: Curve.Friction }, () => {
        this.readerComicChapterTransitionY = 0;
        this.readerComicChapterTransitionOpacity = 1;
      });
      await this.delay(224);
      console.info(`[ReaderBoundary] direction=${direction} switched=${switched} elapsed=${Date.now() - startedAt}ms`);
    } finally {
      this.readerComicSuppressClickUntil = Date.now() + 320;
      this.suppressReaderTapClick = true;
      this.readerComicChapterSwitching = false;
      this.readerComicBoundaryDirection = 0;
      this.readerComicBoundaryPullDistance = 0;
      this.readerComicBoundaryReady = false;
      this.readerComicBoundaryPullOriginY = 0;
      this.readerComicChapterTransitionY = 0;
      this.readerComicChapterTransitionOpacity = 1;
    }
  }

  syncReaderComicPageDataSource(): void {
    this.readerComicPageDataSource.replace(this.contentPages);
    const ratios: number[] = [];
    for (let i = 0; i < this.contentPages.length; i++) {
      ratios.push(this.readerComicImageRatios[i] || 0);
    }
    this.readerComicImageRatios = ratios;
  }

  getReaderComicImageHeight(index: number): number {
    // 尺寸读取期间使用接近图片宽度的短占位，避免解码失败时每张图片都遗留整屏空白。
    const fallbackHeight = Math.max(240, this.pageViewWidth);
    const ratio = index >= 0 && index < this.readerComicImageRatios.length ?
      this.readerComicImageRatios[index] : 0;
    if (ratio <= 0 || this.pageViewWidth <= 0) return fallbackHeight;
    const height = Math.max(120, Math.min(24000, this.pageViewWidth * ratio));
    // ListItem 会分别把浮点 vp 高度转换为物理像素；先对齐到整数像素，避免相邻项反向取整后露底。
    return px2vp(Math.max(1, Math.round(vp2px(height))));
  }

  getReaderComicImageSeamOverlap(index: number): number {
    return index > 0 && index < this.contentPages.length &&
      this.isReaderImageOnlyPage(this.contentPages[index - 1]) ? px2vp(1) : 0;
  }

  getReaderComicImageRenderHeight(index: number): number {
    return this.getReaderComicImageHeight(index) + this.getReaderComicImageSeamOverlap(index);
  }

  getReaderComicImageFit(index: number): ImageFit {
    const ratio = index >= 0 && index < this.readerComicImageRatios.length ?
      this.readerComicImageRatios[index] : 0;
    // 原图比例尚未返回时保持 Contain；比例已知后容器已经严格等比，Fill 只消除边缘 letterbox。
    return ratio > 0 ? ImageFit.Fill : ImageFit.Contain;
  }

  updateReaderComicImageRatio(index: number, sourceWidth: number, sourceHeight: number): void {
    if (index < 0 || sourceWidth <= 0 || sourceHeight <= 0 || index >= this.contentPages.length) return;
    const ratio = sourceHeight / sourceWidth;
    if (!Number.isFinite(ratio) || ratio <= 0) return;
    const currentRatio = this.readerComicImageRatios[index] || 0;
    if (Math.abs(currentRatio - ratio) < 0.0001) return;
    const ratios = [...this.readerComicImageRatios];
    while (ratios.length < this.contentPages.length) {
      ratios.push(0);
    }
    ratios[index] = ratio;
    this.readerComicImageRatios = ratios;
    // LazyForEach 不会因为外部的比例数组变化而自动重建已经生成的 ListItem。
    // 显式通知当前图片项刷新，否则初始整屏占位会一直保留，形成图片之间的大块空白。
    this.readerComicPageDataSource.notifyChanged(index);
  }

  async ensureReaderComicImageRatio(index: number, marker: string): Promise<void> {
    if (index < 0 || index >= this.contentPages.length || this.readerComicImageRatios[index] > 0 ||
      this.contentPages[index] !== marker) {
      return;
    }
    const path = LocalBookService.epubImagePathFromMarker(marker);
    if (!path || /^(?:https?:|data:)/i.test(path)) return;
    const cachedRatio = this.readerComicImageRatioCache.get(path) || 0;
    if (cachedRatio > 0) {
      this.updateReaderComicImageRatio(index, 1, cachedRatio);
      return;
    }
    if (this.readerComicImageRatioLoading.has(path)) return;
    this.readerComicImageRatioLoading.add(path);
    let file: fs.File | null = null;
    let source: image.ImageSource | null = null;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      source = image.createImageSource(file.fd);
      const info = await source.getImageInfo();
      const width = info.size.width;
      const height = info.size.height;
      if (width > 0 && height > 0) {
        const ratio = height / width;
        this.readerComicImageRatioCache.set(path, ratio);
        if (index < this.contentPages.length && this.contentPages[index] === marker) {
          this.updateReaderComicImageRatio(index, width, height);
        }
      }
    } finally {
      this.readerComicImageRatioLoading.delete(path);
      if (source) {
        try {
          await source.release();
        } catch (_) {
        }
      }
      if (file) {
        try {
          fs.closeSync(file);
        } catch (_) {
        }
      }
    }
  }

  scheduleReaderComicScrollRestore(): void {
    if (!this.isReaderContinuousScrollSurfaceActive() || this.contentPages.length === 0) return;
    const serial = ++this.readerComicScrollRestoreSerial;
    const chapterIndex = this.currentChapterIndex;
    const pageIndex = Math.max(0, Math.min(this.currentPageIndex, this.contentPages.length - 1));
    this.readerComicScrollRestoring = true;
    setTimeout(() => {
      if (serial !== this.readerComicScrollRestoreSerial || chapterIndex !== this.currentChapterIndex ||
        !this.isReaderContinuousScrollSurfaceActive()) {
        return;
      }
      try {
        this.readerComicScroller.scrollToIndex(pageIndex, false, ScrollAlign.START);
      } catch (error) {
        console.warn('恢复漫画滚动位置失败:', error);
      }
      setTimeout(() => {
        if (serial === this.readerComicScrollRestoreSerial) {
          this.readerComicScrollRestoring = false;
        }
      }, 120);
    }, 16);
  }

  onReaderComicScrollIndexChanged(start: number, end: number): void {
    if (!this.isReaderContinuousScrollSurfaceActive() || this.readerComicScrollRestoring ||
      this.pendingRestorePageIndex >= 0 || this.contentPages.length === 0) {
      return;
    }
    const pageIndex = Math.max(0, Math.min(Math.round(start), this.contentPages.length - 1));
    if (pageIndex === this.currentPageIndex) return;
    this.currentPageIndex = pageIndex;
    this.currentPageText = this.contentPages[pageIndex] || '';
    if (this.contentPages.length - pageIndex <= 4) {
      this.preloadReaderContentLater();
      this.preloadNextChapterPaginationLater(0);
    }
    if (pageIndex <= 3) this.preloadPreviousChapterPaginationLater(0);
    this.scheduleReaderComicProgressSave();
  }

  scheduleReaderComicProgressSave(): void {
    this.clearReaderComicProgressSaveTimer();
    this.readerComicProgressSaveTimerId = setTimeout(() => {
      this.readerComicProgressSaveTimerId = -1;
      this.saveReadingProgress();
    }, 350);
  }

  clearReaderComicProgressSaveTimer(): void {
    if (this.readerComicProgressSaveTimerId < 0) return;
    clearTimeout(this.readerComicProgressSaveTimerId);
    this.readerComicProgressSaveTimerId = -1;
  }

  scheduleReaderPagedProgressSave(): void {
    this.clearReaderPagedProgressSaveTimer();
    this.readerPagedProgressSaveTimerId = setTimeout(() => {
      this.readerPagedProgressSaveTimerId = -1;
      this.saveReadingProgress();
    }, 300);
  }

  clearReaderPagedProgressSaveTimer(): void {
    if (this.readerPagedProgressSaveTimerId < 0) return;
    clearTimeout(this.readerPagedProgressSaveTimerId);
    this.readerPagedProgressSaveTimerId = -1;
  }

  isReaderImageOnlySource(source: string): boolean {
    const text = source || '';
    if (!LocalBookService.hasEpubImageMarkers(text)) return false;
    return LocalBookService.stripEpubImageMarkers(text).trim().length === 0;
  }

  countReaderImageMarkers(source: string): number {
    const text = source || '';
    const prefix = LocalBookService.EPUB_IMAGE_MARKER_PREFIX;
    let count = 0;
    let cursor = 0;
    while (cursor < text.length) {
      const markerStart = text.indexOf(prefix, cursor);
      if (markerStart < 0) break;
      count++;
      cursor = markerStart + prefix.length;
    }
    return count;
  }

  clearReaderComicPaginationProgress(): void {
    this.readerComicPaginationParsing = false;
    this.readerComicPaginationParsedPages = 0;
    this.readerComicPaginationTotalPages = 0;
    this.readerComicPaginationSource = '';
  }

  updateReaderComicPaginationProgress(chapterIndex: number, result: ReaderPaginationResult): void {
    if (chapterIndex !== this.currentChapterIndex) return;
    if (!this.isReaderComicModeActive()) {
      this.clearReaderComicPaginationProgress();
      return;
    }
    let total = this.readerComicPaginationTotalPages;
    if (this.readerComicPaginationSource !== result.source) {
      if (!this.isReaderImageOnlySource(result.source)) {
        this.clearReaderComicPaginationProgress();
        return;
      }
      this.readerComicPaginationSource = result.source;
      total = this.countReaderImageMarkers(result.source);
    }
    total = Math.max(total, result.pages.length);
    this.readerComicPaginationTotalPages = total;
    this.readerComicPaginationParsedPages = Math.min(total, result.pages.length);
    this.readerComicPaginationParsing = result.complete !== true &&
      this.readerComicPaginationParsedPages < total;
  }

  isReaderImageOnlyPage(text: string): boolean {
    return LocalBookService.isEpubImageMarker((text || '').trim());
  }

  getReaderPageHorizontalPadding(text: string, fallback: number): number {
    return this.isReaderImageOnlyPage(text) ? 0 : fallback;
  }

  getReaderPageVerticalPadding(text: string, fallback: number): number {
    return this.isReaderImageOnlyPage(text) ? 0 : fallback;
  }

  getReaderPageTurnStep(): number {
    return this.isLandscapeDoublePageActive() ? 2 : 1;
  }

  normalizeReaderSpreadPageIndex(pageIndex: number): number {
    const safeIndex = Math.max(0, Math.round(pageIndex));
    return this.isLandscapeDoublePageActive() ? Math.floor(safeIndex / 2) * 2 : safeIndex;
  }

  getSecondaryPageText(pageIndex: number = this.currentPageIndex): string {
    if (!this.isLandscapeDoublePageActive() || pageIndex + 1 >= this.contentPages.length) {
      return '';
    }
    return this.getPageText(pageIndex + 1);
  }

  currentReaderSurfaceIndex(): number {
    return Math.abs(this.currentChapterIndex + this.currentPageIndex) % 2;
  }

  currentReaderSurfaceKeys(): string[] {
    // Page/chapter and TTS focus changes must publish a fresh declarative subtree. Reusing one fixed ForEach item
    // leaves ArkUI holding the previous chapter or the previous set of highlighted spans.
    return [this.currentReaderPageRenderIdentity(this.pageRenderVersion, this.ttsHighlightRenderVersion)];
  }

  visibleCurrentPageText(): string {
    if (!this.shouldRenderSlidingPageTurn()) {
      const pageText = this.getCurrentPageText();
      return pageText || this.currentPageText || this.displayPageText;
    }
    if (this.displayPageChapterIndex === this.currentChapterIndex &&
      this.displayPageIndex === this.currentPageIndex && this.displayPageText) {
      return this.displayPageText;
    }
    const pageText = this.getCurrentPageText();
    return pageText || this.currentPageText;
  }

  syncCurrentPageText(): void {
    this.setCurrentPageText(this.getCurrentPageText());
  }

  setCurrentPageText(text: string): void {
    const nextText = text || '';
    if (this.currentPageText !== nextText) {
      this.chapterJumpRenderGeneration++;
    }
    this.readerSourceActionAreas.clear();
    this.clearPendingReaderSourceActionBounds();
    this.currentPageText = nextText;
    this.displayPageText = nextText;
    this.displayPageChapterIndex = this.currentChapterIndex;
    this.displayPageIndex = this.currentPageIndex;
    this.displayPageRenderKey++;
    this.pageRenderVersion++;
  }

  parseAreaDimension(value: Length): number {
    if (typeof value === 'number') {
      return value;
    }
    if (typeof value !== 'string') {
      return 0;
    }
    const text = String(value || '').trim();
    const match = text.match(/-?\d+(\.\d+)?/);
    if (!match) {
      return 0;
    }
    const parsed = Number(match[0]);
    return Number.isFinite(parsed) ? parsed : 0;
  }

  updatePagedReaderArea(area: Area): void {
    const width = this.parseAreaDimension(area.width);
    const contentTopPadding = this.getReaderPageContentTopPadding();
    const height = Math.max(1, this.parseAreaDimension(area.height) - contentTopPadding);
    this.readerPageContentTopPaddingSnapshot = contentTopPadding;
    if (width <= 0 || height <= 0) {
      return;
    }
    if (Math.abs(this.pageViewWidth - width) < 0.5 && Math.abs(this.pageViewHeight - height) < 0.5) {
      return;
    }
    const shouldRestoreSavedPage = this.pendingRestorePageIndex >= 0;
    const globalY: Length = area.globalPosition?.y ?? 0;
    this.readerCommentPageAreaTop = this.parseAreaDimension(globalY);
    this.readerCommentPageAreaHeight = height;
    const readingOffset = this.getCurrentPageStartOffset();
    this.pageViewWidth = width;
    this.pageViewHeight = height;
    this.paginateContent(this.content);
    if (!shouldRestoreSavedPage) {
      this.currentPageIndex = this.normalizeReaderSpreadPageIndex(this.findPageIndexByOffset(readingOffset));
    }
    this.syncCurrentPageText();
    this.preloadNextChapterPaginationLater();
    this.preloadPreviousChapterPaginationLater();
  }

  hasPagedReaderArea(): boolean {
    return this.pageViewWidth > 0 && this.pageViewHeight > 0;
  }

  getCurrentPageStartOffset(): number {
    return this.getPageStartOffset(this.currentPageIndex);
  }

  getPageStartOffset(pageIndex: number): number {
    if (this.contentPageStarts.length === 0) {
      return 0;
    }
    const index = Math.max(0, Math.min(pageIndex, this.contentPageStarts.length - 1));
    return Math.max(0, this.contentPageStarts[index]);
  }

  getPageEndOffset(pageIndex: number): number {
    if (this.contentPageEnds.length === 0) {
      return this.content.length;
    }
    const index = Math.max(0, Math.min(pageIndex, this.contentPageEnds.length - 1));
    return Math.max(this.getPageStartOffset(index), this.contentPageEnds[index]);
  }

  findPageIndexByOffset(offset: number): number {
    if (this.contentPageStarts.length === 0) {
      return Math.max(0, Math.min(this.currentPageIndex, Math.max(0, this.contentPages.length - 1)));
    }
    const sourceLength = this.pagedContentText ? this.pagedContentText.length : this.content.length;
    const clampedOffset = Math.max(0, Math.min(offset, Math.max(0, sourceLength - 1)));
    for (let i = 0; i < this.contentPageStarts.length; i++) {
      if (clampedOffset >= this.contentPageStarts[i] && clampedOffset < this.contentPageEnds[i]) {
        return i;
      }
      if (i < this.contentPageStarts.length - 1 &&
        clampedOffset >= this.contentPageEnds[i] && clampedOffset < this.contentPageStarts[i + 1]) {
        return i + 1;
      }
    }
    return Math.max(0, this.contentPageStarts.length - 1);
  }

  getBackgroundColor(): string {
    return this.currentReaderTheme().backgroundColor;
  }

  getBackgroundAssetId(): string {
    return this.currentReaderTheme().backgroundAssetId || '';
  }

  getBackgroundImageFit(): ImageFit {
    const fit = this.currentReaderTheme().backgroundImageFit;
    if (fit === 'contain') {
      return ImageFit.Contain;
    }
    if (fit === 'fill') {
      return ImageFit.Fill;
    }
    return ImageFit.Cover;
  }

  hasBackgroundImage(): boolean {
    return !!this.currentReaderTheme().backgroundImageUri || !!this.getBackgroundAssetId();
  }

  readerContentLayerColor(): string {
    return this.hasBackgroundImage() ? '#00000000' : this.getBackgroundColor();
  }

  getTextColor(): string {
    return this.currentReaderTheme().textColor;
  }

  currentReaderThemeIndex(): number {
    return this.appDarkMode ? this.readerDarkThemeIndex : this.readerLightThemeIndex;
  }

  currentReaderThemes(): ReaderThemeItem[] {
    const custom = this.currentCustomThemeScheme();
    return ReaderThemeHelper.themes(
      this.appDarkMode,
      custom.backgroundColor,
      custom.textColor,
      this.currentCustomThemeBackgroundImageUri(),
      custom.backgroundImageFit
    );
  }

  currentReaderTheme(): ReaderThemeItem {
    return ReaderThemeHelper.themeAt(
      this.appDarkMode,
      this.currentReaderThemeIndex(),
      this.currentCustomThemeBackgroundColor(),
      this.currentCustomThemeTextColor(),
      this.currentCustomThemeBackgroundImageUri(),
      this.currentCustomThemeScheme().backgroundImageFit
    );
  }

  currentCustomThemeBackgroundColor(): string {
    return this.currentCustomThemeScheme().backgroundColor;
  }

  currentCustomThemeTextColor(): string {
    return this.currentCustomThemeScheme().textColor;
  }

  currentCustomThemeBackgroundImageUri(): string {
    const current = this.currentCustomThemeScheme();
    return current.backgroundType === 'image' ? current.backgroundImageUri : '';
  }

  currentCustomThemeBackgroundTypeIndex(): number {
    return this.currentCustomThemeScheme().backgroundType === 'image' ? 1 : 0;
  }

  customThemeData(): ReaderCustomThemeData {
    return ReaderCustomThemeHelper.parse(
      this.readerCustomThemesRaw,
      this.readerLightCustomThemeBackgroundColor,
      this.readerLightCustomThemeTextColor,
      this.readerDarkCustomThemeBackgroundColor,
      this.readerDarkCustomThemeTextColor
    );
  }

  currentCustomThemeScheme(): ReaderCustomThemeScheme {
    return ReaderCustomThemeHelper.selected(this.customThemeData(), this.appDarkMode);
  }

  currentCustomThemeSchemes(): ReaderCustomThemeScheme[] {
    return ReaderCustomThemeHelper.schemesForMode(this.customThemeData(), this.appDarkMode);
  }

  currentCustomThemeSelectedIndex(): number {
    const schemes = this.currentCustomThemeSchemes();
    const selectedId = this.currentCustomThemeScheme().id;
    const index = schemes.findIndex((item: ReaderCustomThemeScheme) => item.id === selectedId);
    return Math.max(0, index);
  }

  customThemeOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (const item of this.currentCustomThemeSchemes()) {
      const option: SelectOption = { value: item.name };
      options.push(option);
    }
    return options;
  }

  customThemeFitSelectedIndex(): number {
    const fit = this.currentCustomThemeScheme().backgroundImageFit;
    return fit === 'contain' ? 1 : (fit === 'fill' ? 2 : 0);
  }

  normalizeColor(color: string, fallback: string): string {
    const trimmed = (color || '').trim();
    const normalized = trimmed.startsWith('#') ? trimmed : `#${trimmed}`;
    if (/^#[0-9a-fA-F]{6}$/.test(normalized)) {
      return normalized.toUpperCase();
    }
    const fallbackTrimmed = (fallback || '').trim();
    const normalizedFallback = fallbackTrimmed.startsWith('#') ? fallbackTrimmed : `#${fallbackTrimmed}`;
    return /^#[0-9a-fA-F]{6}$/.test(normalizedFallback) ? normalizedFallback.toUpperCase() : '#333333';
  }

  isReaderThemeDark(): boolean {
    const tone = this.currentReaderTheme().contentTone;
    if (tone === 'dark' || tone === 'light') {
      return tone === 'dark';
    }
    return this.isDarkHexColor(this.getBackgroundColor());
  }

  isDarkHexColor(color: string): boolean {
    const normalized = (color || '').trim();
    if (!/^#[0-9a-fA-F]{6}$/.test(normalized)) {
      return this.appDarkMode;
    }
    const red = parseInt(normalized.substring(1, 3), 16);
    const green = parseInt(normalized.substring(3, 5), 16);
    const blue = parseInt(normalized.substring(5, 7), 16);
    return red * 0.299 + green * 0.587 + blue * 0.114 < 128;
  }

  getReaderFontFamily(): string {
    const family = this.resolveReaderFontFamily();
    if (family !== this.lastLoggedReaderFontFamily) {
      this.lastLoggedReaderFontFamily = family;
      console.info(`阅读正文使用字体: ${family}`);
    }
    return family;
  }

  getBodyReaderFontFamily(): string {
    return this.resolveStyledReaderFontFamily(this.readerBodyFontMode, this.readerBodyFontFamily);
  }

  getTitleReaderFontFamily(): string {
    if (this.readerTitleFontMode === 'global' && !this.readerTitleFontFamily) {
      return this.getReaderFontFamily();
    }
    return this.resolveStyledReaderFontFamily(this.readerTitleFontMode, this.readerTitleFontFamily);
  }

  getRegexReaderFontFamily(): string {
    return this.resolveStyledReaderFontFamily(this.readerRegexFontMode, this.readerRegexFontFamily);
  }

  resolveStyledReaderFontFamily(mode: string, family: string): string {
    if (mode === 'system') {
      return this.getSystemReaderFontFamily();
    }
    if (mode === 'custom' && family) {
      return this.resolveCustomReaderFontFamily(family);
    }
    return this.getReaderFontFamily();
  }

  resolveCustomReaderFontFamily(family: string): string {
    if (!family) {
      return '';
    }
    const raw = AppStorage.get<string>('readerCustomFontsRaw') || '';
    if (!raw.trim()) {
      return family;
    }
    try {
      const parsed = JSON.parse(raw) as ReaderCustomFontData | ReaderCustomFontItem[];
      const source = Array.isArray(parsed) ? parsed as ReaderCustomFontItem[] : ((parsed as ReaderCustomFontData).fonts || []);
      for (const item of source) {
        if (!item || !item.filePath) {
          continue;
        }
        const stableFamily = ReaderFontHelper.normalizeFontFamily(item.filePath);
        if (item.familyName === family || stableFamily === family) {
          return stableFamily;
        }
      }
    } catch (e) {
      console.warn('解析阅读自定义字体失败:', e);
    }
    return family;
  }

  registerCustomReaderFontFamily(family: string): void {
    if (!family) {
      return;
    }
    const raw = AppStorage.get<string>('readerCustomFontsRaw') || '';
    if (!raw.trim()) {
      return;
    }
    try {
      const parsed = JSON.parse(raw) as ReaderCustomFontData | ReaderCustomFontItem[];
      const source = Array.isArray(parsed) ? parsed as ReaderCustomFontItem[] : ((parsed as ReaderCustomFontData).fonts || []);
      for (const item of source) {
        if (!item || !item.filePath) {
          continue;
        }
        const stableFamily = ReaderFontHelper.normalizeFontFamily(item.filePath);
        if (item.familyName !== family && stableFamily !== family) {
          continue;
        }
        const fontItem = new ReaderFontItem();
        fontItem.familyName = stableFamily;
        fontItem.filePath = item.filePath;
        fontItem.sourceName = item.sourceName || this.fileNameFromPath(item.filePath);
        ReaderFontHelper.registerFont(this.getUIContext(), fontItem);
        return;
      }
    } catch (e) {
      console.warn('解析阅读自定义字体失败:', e);
    }
  }

  registerStyledCustomReaderFonts(): void {
    if (this.readerBodyFontMode === 'custom') {
      this.registerCustomReaderFontFamily(this.readerBodyFontFamily);
    }
    if (this.readerTitleFontMode === 'custom') {
      this.registerCustomReaderFontFamily(this.readerTitleFontFamily);
    }
    if (this.readerRegexFontMode === 'custom') {
      this.registerCustomReaderFontFamily(this.readerRegexFontFamily);
    }
    const rules = this.getRegexRules();
    for (const rule of rules) {
      if (rule.fontMode === 'custom') {
        this.registerCustomReaderFontFamily(rule.fontFamily);
      }
    }
  }

  resolveReaderFontFamily(): string {
    if (this.activeReaderFontFamily) {
      return this.activeReaderFontFamily;
    }
    if (this.readerActiveFontFamily) {
      return this.readerActiveFontFamily;
    }
    return this.readerFontFamily || ThemeRuntime.fontFamily() || this.getSystemReaderFontFamily();
  }

  getSystemReaderFontFamily(): string {
    return this.readerSystemFontFamily || ReaderSystemFontHelper.currentFromStorage(this.getUIContext());
  }

  isReaderFontReady(): boolean {
    return !!this.activeReaderFontFamily || !!this.readerActiveFontFamily;
  }

  clearReaderFontState(): void {
    this.activeReaderFontFamily = '';
    this.readerFontRegistered = false;
    this.readerActiveFontFamily = '';
    this.readerStoredFontRegistered = false;
    this.readerFontRenderReady = false;
    this.applyReaderApplicationFont(this.getSystemReaderFontFamily());
  }

  async registerReaderFont(): Promise<boolean> {
    if (!this.readerFontFilePath) {
      this.clearReaderFontState();
      return false;
    }
    return await this.registerReaderFontAsync('readbook-sync-request');
  }

  async registerReaderFontBySettings(fontFamily: string, fontFilePath: string, fontSourceName: string): Promise<boolean> {
    if (!fontFilePath) {
      this.clearReaderFontState();
      return false;
    }
    this.readerFontFamily = fontFamily || ReaderFontHelper.normalizeFontFamily(fontFilePath);
    this.readerFontFilePath = fontFilePath;
    AppStorage.setOrCreate<string>('readerFontSourceName', fontSourceName || this.fileNameFromPath(fontFilePath));
    return await this.registerReaderFontAsync('readbook-register-by-settings');
  }

  async registerReaderFontAsync(source: string): Promise<boolean> {
    if (!this.readerFontFilePath) {
      this.clearReaderFontState();
      return false;
    }
    const requestedPath = this.readerFontFilePath;
    const registered = await ReaderFontBootstrap.registerFromSettings(getContext(this), this.getUIContext(), source);
    if (!this.readerFontFilePath) {
      this.clearReaderFontState();
      return false;
    }
    if (requestedPath !== this.readerFontFilePath) {
      return false;
    }
    if (!registered) {
      if (this.readerFontFilePath) {
        this.readerFontRegistered = false;
        this.readerStoredFontRegistered = false;
        this.readerActiveFontFamily = '';
        this.activeReaderFontFamily = '';
        this.readerFontRenderReady = false;
      }
      return false;
    }
    const activeFamily = AppStorage.get<string>('readerActiveFontFamily') || '';
    const activePath = AppStorage.get<string>('readerFontFilePath') || this.readerFontFilePath;
    if (activePath && activePath !== this.readerFontFilePath) {
      this.replaceReaderCustomFontPath(this.readerFontFilePath, activePath, ReaderFontHelper.normalizeFontFamily(activePath));
      this.readerFontFilePath = activePath;
    }
    const stableFamily = activePath ? ReaderFontHelper.normalizeFontFamily(activePath) : this.readerFontFamily;
    if (stableFamily && this.readerFontFamily !== stableFamily) {
      this.readerFontFamily = stableFamily;
    }
    this.activateRegisteredReaderFont(activeFamily);
    this.refreshReaderTextRender();
    this.paginateContent(this.content);
    return true;
  }

  activateRegisteredReaderFont(familyName: string): void {
    if (this.readerFontRegistered && this.activeReaderFontFamily === familyName) {
      this.readerFontRenderReady = false;
      this.refreshRegisteredReaderFontLater(familyName, 80);
      this.refreshRegisteredReaderFontLater(familyName, 240);
      return;
    }
    this.readerActiveFontFamily = familyName;
    this.readerStoredFontRegistered = true;
    this.readerFontRegistered = true;
    this.activeReaderFontFamily = familyName;
    this.readerFontRenderReady = false;
    setTimeout(() => {
      this.activeReaderFontFamily = familyName;
      this.readerFontRegistered = true;
      this.readerActiveFontFamily = familyName;
      this.readerStoredFontRegistered = true;
      this.refreshReaderTextRender();
      this.paginateContent(this.content);
    }, 0);
    this.refreshRegisteredReaderFontLater(familyName, 80);
    this.refreshRegisteredReaderFontLater(familyName, 240);
  }

  refreshRegisteredReaderFontLater(familyName: string, delayMs: number): void {
    setTimeout(() => {
      if (!familyName || this.activeReaderFontFamily !== familyName) {
        return;
      }
      this.readerFontRenderReady = true;
      console.info(`阅读字体延迟刷新: family=${familyName}, delay=${delayMs}`);
      this.refreshReaderTextRender();
      this.paginateContent(this.content);
    }, delayMs);
  }

  applyLoadedReaderSettings(settings: ReaderSettings): void {
    this.readerFontSize = settings.fontSize;
    this.readerLineHeight = settings.lineHeight;
    this.readerParagraphSpacing = settings.paragraphSpacing;
    this.readerMarginLeft = settings.marginLeft;
    this.readerMarginRight = settings.marginRight;
    this.readerMarginTop = settings.marginTop;
    this.readerMarginBottom = settings.marginBottom;
    this.readerLightThemeIndex = settings.lightThemeIndex;
    this.readerDarkThemeIndex = settings.darkThemeIndex;
    this.readerLightCustomThemeBackgroundColor = settings.lightCustomThemeBackgroundColor;
    this.readerLightCustomThemeTextColor = settings.lightCustomThemeTextColor;
    this.readerDarkCustomThemeBackgroundColor = settings.darkCustomThemeBackgroundColor;
    this.readerDarkCustomThemeTextColor = settings.darkCustomThemeTextColor;
    this.readerCustomThemesRaw = settings.customThemesRaw || '';
    this.customThemeNameDraft = this.currentCustomThemeScheme().name;
    this.readerPageTurnMode = settings.pageTurnMode;
    this.readerPageTurnAnimationType = settings.pageTurnAnimationType;
    this.readerLandscapeDoublePage = settings.landscapeDoublePage;
    this.readerScreenOrientation = settings.screenOrientation;
    this.readerTapZoneActions = settings.tapZoneActions;
    this.readerVolumeTurnPage = settings.volumeTurnPage;
    this.readerScreenTimeoutMinutes = settings.screenTimeoutMinutes;
    this.applyReaderScreenTimeout();
    this.readerExtendToStatusBar = settings.extendToStatusBar;
    this.readerPreloadEnabled = settings.preloadEnabled;
    this.readerPreloadChapterCount = settings.preloadChapterCount;
    this.readerUseTtsQuickAction = settings.useTtsQuickAction;
    this.readerUseChapterQuickJump = settings.useChapterQuickJump;
    this.readerFontFamily = settings.fontFamily || '';
    this.readerFontFilePath = settings.fontFilePath || '';
    AppStorage.setOrCreate<string>('readerFontSourceName', settings.fontSourceName || '系统默认');
    AppStorage.setOrCreate<string>('readerFontMode', settings.fontMode || (settings.fontFilePath ? 'custom' : 'system'));
    this.readerSystemFontFamily = settings.systemFontFamily || ReaderSystemFontHelper.currentFromStorage(this.getUIContext());
    AppStorage.setOrCreate<string>('readerSystemFontFamily', this.readerSystemFontFamily);
    AppStorage.setOrCreate<string>('readerCustomFontsRaw', settings.customFontsRaw || '');
    this.readerBodyFontMode = settings.bodyFontMode || 'global';
    this.readerBodyFontFamily = settings.bodyFontFamily || '';
    this.readerTitleFontMode = settings.titleFontMode || 'global';
    this.readerTitleFontFamily = settings.titleFontFamily || '';
    this.readerTitleFontSize = settings.titleFontSize || 22;
    this.readerRegexFontEnabled = settings.regexFontEnabled;
    this.readerRegexFontPattern = settings.regexFontPattern || '';
    this.readerRegexFontMode = settings.regexFontMode || 'global';
    this.readerRegexFontFamily = settings.regexFontFamily || '';
    this.readerRegexFontSize = settings.regexFontSize || 20;
    this.readerRegexShadowColor = settings.regexShadowColor || '';
    this.readerRegexFontRulesRaw = settings.regexFontRulesRaw || '';
    this.registerStyledCustomReaderFonts();
  }

  onReaderFontStyleChanged(): void {
    this.cachedRegexRulesKey = '';
    this.cachedRegexRules = [];
    this.readerPaginationCache.clear();
    this.pageTurnPreviewKey = '';
    this.registerStyledCustomReaderFonts();
    this.refreshReaderTextRender();
    this.paginateContent(this.content);
    this.preloadNextChapterPaginationLater();
  }

  replaceReaderCustomFontPath(oldPath: string, newPath: string, familyName: string): void {
    const raw = AppStorage.get<string>('readerCustomFontsRaw') || '';
    if (!raw.trim()) {
      return;
    }
    try {
      const parsed = JSON.parse(raw) as ReaderCustomFontData | ReaderCustomFontItem[];
      const source = Array.isArray(parsed) ? parsed as ReaderCustomFontItem[] : ((parsed as ReaderCustomFontData).fonts || []);
      const data = new ReaderCustomFontData();
      for (const item of source) {
        if (!item || !item.filePath) {
          continue;
        }
        const next = new ReaderCustomFontItem();
        next.filePath = item.filePath === oldPath ? newPath : item.filePath;
        next.familyName = item.filePath === oldPath ? familyName : (item.familyName || ReaderFontHelper.normalizeFontFamily(next.filePath));
        next.sourceName = item.sourceName || this.fileNameFromPath(next.filePath);
        data.fonts.push(next);
      }
      AppStorage.setOrCreate<string>('readerCustomFontsRaw', JSON.stringify(data));
    } catch (e) {
      console.warn('更新阅读字体列表失败:', e);
    }
  }

  fileNameFromPath(path: string): string {
    return ReaderFontHelper.fileNameFromPath(path);
  }

  applyReaderApplicationFont(familyName: string): void {
    try {
      getContext(this).getApplicationContext().setFont(familyName || '');
    } catch (e) {
      console.warn('应用阅读字体失败:', e);
    }
  }

  saveReaderFontSettings(): void {
    ReaderSettingsStore.saveFontSettings(
      getContext(this),
      this.readerFontFamily,
      this.readerFontFilePath,
      AppStorage.get<string>('readerFontSourceName') || '系统默认',
      AppStorage.get<string>('readerFontMode') || (this.readerFontFilePath ? 'custom' : 'system'),
      AppStorage.get<string>('readerSystemFontFamily') || this.getSystemReaderFontFamily(),
      AppStorage.get<string>('readerCustomFontsRaw') || ''
    ).catch((e: Error) => {
      console.warn('保存阅读字体设置失败:', e);
    });
  }

  getTocTitleColor(chapter: BookChapter, index: number): string {
    if (index === this.currentChapterIndex) {
      return this.accentColor();
    }
    if (chapter.cacheDate > 0) {
      return this.isReaderThemeDark() ? '#DDEFE5' : '#244B35';
    }
    return this.isReaderThemeDark() ? '#B8BDC7' : '#333333';
  }

  setReaderContent(text: string): void {
    this.content = text;
    this.paginateContent(text);
  }

  openTocPanel(): void {
    this.tocPanelTab = 0;
    this.tocSearchVisible = false;
    this.tocSearchQuery = '';
    this.tocSearchChapterIndexes = [];
    this.tocSearchLoading = false;
    this.tocSearchResultActive = false;
    this.tocSearchRequestSerial++;
    this.tocDatabaseChapterCount = this.chapters.length;
    this.tocFirstVisibleGlobalIndex = this.currentChapterIndex;
    this.tocQuickJumpArmed = false;
    this.tocQuickJumpInputVisible = false;
    this.tocQuickJumpDraft = '';
    this.cancelBookmarkMultiSelect();
    this.setTocWindowAround(this.currentChapterIndex, ScrollAlign.CENTER);
    this.showToc = true;
    this.showMenu = false;
    this.scrollTocToCurrentChapter(false);
    this.loadBookmarks();
    this.loadTocDatabaseChapterCount();
  }

  async refreshTocFromPanel(): Promise<void> {
    const searchQuery = this.tocSearchQuery;
    await this.retryFetchChapters();
    this.tocDatabaseChapterCount = this.chapters.length;
    if (this.tocSearchVisible && this.tocSearchResultActive && searchQuery.trim()) {
      await this.submitTocSearch();
    } else {
      this.setTocWindowAround(this.currentChapterIndex, ScrollAlign.CENTER);
      this.scrollTocToCurrentChapter(false);
    }
    promptAction.showToast({ message: '目录已刷新' });
  }

  async loadBookmarks(): Promise<void> {
    const bookUrl = this.book?.bookUrl || this.bookUrl;
    if (!bookUrl) {
      this.bookmarks = [];
      return;
    }
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      this.bookmarks = await db.getBookmarks(bookUrl);
    } catch (e) {
      console.warn('加载书签失败:', e);
      this.bookmarks = [];
    }
  }

  currentPageBookmark(): Bookmark | undefined {
    return this.bookmarks.find((bookmark: Bookmark) =>
      bookmark.chapterIndex === this.currentChapterIndex && bookmark.pageIndex === this.currentPageIndex);
  }

  isCurrentPageBookmarked(): boolean {
    return this.currentPageBookmark() !== undefined;
  }

  async toggleCurrentPageBookmark(): Promise<void> {
    const existing = this.currentPageBookmark();
    if (existing) {
      await this.deleteBookmark(existing);
      return;
    }
    await this.addCurrentBookmark();
  }

  bookmarkPullHintText(): string {
    if (this.isCurrentPageBookmarked()) {
      return this.bookmarkPullReady ? '松开删除书签' : '下拉删除书签';
    }
    return this.bookmarkPullReady ? '松开添加书签' : '下拉添加书签';
  }

  bookmarkPullHintColor(): string {
    return this.bookmarkPullReady ? this.accentColor() : this.getTextColor();
  }

  @Builder
  readerCurrentPageBookmarkMarker() {
    Stack({ alignContent: Alignment.Top }) {
      SymbolGlyph($r('sys.symbol.bookmark_fill'))
        .fontSize(32)
        .fontColor([this.accentColor()])
    }
    .width(46)
    .height(40)
    .position({ x: '100%', y: 0 })
    .translate({
      x: -62,
      y: this.readerBookmarkMarkerTopOffset() + this.bookmarkPullOffsetY
    })
    .hitTestBehavior(HitTestMode.None)
  }

  readerBookmarkMarkerTopOffset(): number {
    if (this.readerExtendToStatusBar) return 0;
    return this.hasBackgroundImage() || this.isStackPageTurnAnimation() ? this.statusBarSafeHeight : 0;
  }

  @Builder
  readerBookmarkPullHint() {
    Row() {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.bookmark'))
          .fontSize(19)
          .fontColor([this.bookmarkPullHintColor()])
        Text(this.bookmarkPullHintText())
          .fontSize(14)
          .fontWeight(this.bookmarkPullReady ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.bookmarkPullHintColor())
      }
      .height(40)
      .padding({ left: 14, right: 14 })
      .borderRadius(20)
      .backgroundColor(this.readerGlassPanelColor())
      .border({ width: ThemeRuntime.glassBorderWidth(), color: this.readerGlassBorderColor() })
      .shadow({ radius: ThemeRuntime.glassShadowRadius(), color: this.readerGlassShadowColor(), offsetX: ThemeRuntime.glassShadowOffsetX(), offsetY: ThemeRuntime.glassShadowOffsetY() })
    }
    .width('100%')
    .height(40)
    .justifyContent(FlexAlign.Center)
    .position({ x: 0, y: 0 })
    .translate({ y: this.getTopControlSafePadding() + 8 })
    .opacity(Math.min(1, this.bookmarkPullOffsetY / 36))
    .hitTestBehavior(HitTestMode.None)
  }

  async addCurrentBookmark(): Promise<void> {
    if (!this.book || this.chapters.length === 0) {
      promptAction.showToast({ message: '当前没有可添加的阅读位置' });
      return;
    }
    const pageIndex = Math.max(0, this.currentPageIndex);
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      const existing = await db.getBookmarkAt(this.book.bookUrl, this.currentChapterIndex, pageIndex);
      if (existing) {
        promptAction.showToast({ message: '当前阅读位置已添加书签' });
        return;
      }
      const bookmark = new Bookmark();
      bookmark.bookUrl = this.book.bookUrl;
      bookmark.bookName = this.book.name;
      bookmark.bookAuthor = this.book.author;
      bookmark.chapterIndex = this.currentChapterIndex;
      bookmark.chapterName = this.getChapterTitle(this.currentChapterIndex);
      bookmark.pageIndex = pageIndex;
      bookmark.startPos = this.getPageStartOffset(pageIndex);
      bookmark.endPos = this.getPageEndOffset(pageIndex);
      bookmark.content = this.bookmarkContentPreview(pageIndex);
      bookmark.createTime = Date.now();
      bookmark.id = await db.insertBookmark(bookmark);
      await this.loadBookmarks();
      promptAction.showToast({ message: '书签已添加' });
    } catch (e) {
      console.error('添加书签失败:', e);
      promptAction.showToast({ message: '添加书签失败' });
    }
  }

  bookmarkContentPreview(pageIndex: number): string {
    const text = this.getPageText(pageIndex).replace(/\s+/g, ' ').trim();
    return text.length > 90 ? `${text.substring(0, 90)}…` : text;
  }

  async deleteBookmark(bookmark: Bookmark): Promise<void> {
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      await db.deleteBookmark(bookmark.id);
      this.bookmarks = this.bookmarks.filter((item: Bookmark) => item.id !== bookmark.id);
      this.selectedBookmarkIds = this.selectedBookmarkIds.filter((id: number) => id !== bookmark.id);
      if (this.bookmarkMultiSelectMode && this.bookmarks.length === 0) {
        this.cancelBookmarkMultiSelect();
      }
      promptAction.showToast({ message: '书签已删除' });
    } catch (e) {
      console.error('删除书签失败:', e);
      promptAction.showToast({ message: '删除书签失败' });
    }
  }

  enterBookmarkMultiSelect(bookmarkId: number): void {
    this.bookmarkMultiSelectMode = true;
    if (!this.selectedBookmarkIds.includes(bookmarkId)) {
      this.selectedBookmarkIds = [...this.selectedBookmarkIds, bookmarkId];
    }
    setTimeout(() => {
      try {
        this.bookmarkScroller.closeAllSwipeActions();
      } catch (error) {
        console.warn('关闭书签滑动操作失败:', error);
      }
    }, 0);
  }

  isBookmarkSelected(bookmarkId: number): boolean {
    return this.selectedBookmarkIds.includes(bookmarkId);
  }

  toggleBookmarkSelection(bookmarkId: number): void {
    if (this.selectedBookmarkIds.includes(bookmarkId)) {
      this.selectedBookmarkIds = this.selectedBookmarkIds.filter((id: number) => id !== bookmarkId);
    } else {
      this.selectedBookmarkIds = [...this.selectedBookmarkIds, bookmarkId];
    }
  }

  toggleSelectAllBookmarks(): void {
    if (this.selectedBookmarkIds.length === this.bookmarks.length) {
      this.selectedBookmarkIds = [];
    } else {
      this.selectedBookmarkIds = this.bookmarks.map((bookmark: Bookmark) => bookmark.id);
    }
  }

  cancelBookmarkMultiSelect(): void {
    this.bookmarkMultiSelectMode = false;
    this.selectedBookmarkIds = [];
  }

  async deleteSelectedBookmarks(): Promise<void> {
    const ids = [...this.selectedBookmarkIds];
    if (ids.length === 0) return;
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      await db.deleteBookmarks(ids);
      this.bookmarks = this.bookmarks.filter((bookmark: Bookmark) => !ids.includes(bookmark.id));
      this.cancelBookmarkMultiSelect();
      promptAction.showToast({ message: `已删除 ${ids.length} 条书签` });
    } catch (e) {
      console.error('批量删除书签失败:', e);
      promptAction.showToast({ message: '批量删除书签失败' });
    }
  }

  async jumpToBookmark(bookmark: Bookmark): Promise<void> {
    const targetChapterIndex = this.clampChapterIndex(bookmark.chapterIndex);
    this.showToc = false;
    this.showMenu = false;
    await this.jumpToReaderPositionKeepingTts(targetChapterIndex, Math.max(0, bookmark.pageIndex));
  }

  formatBookmarkTime(timestamp: number): string {
    if (timestamp <= 0) return '';
    const date = new Date(timestamp);
    const month = `${date.getMonth() + 1}`.padStart(2, '0');
    const day = `${date.getDate()}`.padStart(2, '0');
    const hour = `${date.getHours()}`.padStart(2, '0');
    const minute = `${date.getMinutes()}`.padStart(2, '0');
    return `${month}-${day} ${hour}:${minute}`;
  }

  openSettingsPanel(): void {
    if (this.isReaderComicModeActive()) return;
    this.showReaderActionMenu = false;
    this.settingsPanelTab = 0;
    this.showToc = false;
    this.showTtsVoiceDropdown = false;
    this.showSettings = true;
    this.showMenu = false;
  }

  openTtsSettingsPanel(): void {
    if (this.isReaderComicModeActive()) return;
    this.showReaderActionMenu = false;
    this.settingsPanelTab = 1;
    this.showToc = false;
    this.showTtsVoiceDropdown = false;
    this.showSettings = true;
    this.showMenu = false;
    this.loadTtsSettingsAndVoices();
  }

  openTypographySettingsPanel(): void {
    if (this.isReaderComicModeActive()) return;
    if (!this.readerTypographyDraftPending) this.syncReaderTypographyDraft();
    this.showReaderActionMenu = false;
    this.settingsPanelTab = 2;
    this.showToc = false;
    this.showTtsVoiceDropdown = false;
    this.showSettings = true;
    this.showMenu = false;
  }

  closeSettingsPanelKeepMenu(): void {
    this.showTtsVoiceDropdown = false;
    this.showSettings = false;
    this.showMenu = true;
  }

  static defaultTtsVoice(): TtsVoiceOption {
    const option = new TtsVoiceOption();
    option.id = 0;
    option.name = '默认音色';
    option.online = 1;
    option.status = 'default';
    option.language = 'zh-CN';
    option.available = true;
    return option;
  }

  async loadTtsSettingsAndVoices(): Promise<void> {
    try {
      const settings = await TtsSettingsStore.load(getContext(this));
      this.applyLoadedTtsSettings(settings);
    } catch (e) {
      console.warn('读取朗读设置失败:', e);
    }
    this.normalizeDefaultTtsVoice();
    this.ttsSelectedVoiceKey = this.currentTtsVoiceKey();
    this.loadTtsVoices();
  }

  applyLoadedTtsSettings(settings: TtsSettings): void {
    this.ttsPerson = settings.person;
    this.ttsOnline = settings.online;
    this.ttsStyle = settings.style;
    this.ttsLanguage = settings.language;
    this.ttsSpeed = settings.speed;
    this.ttsInstalledVoiceKeys = settings.installedVoiceKeys;
    this.ttsCustomVoiceId = settings.customVoiceId;
    this.ttsCustomVoices = settings.customVoices;
    this.ttsCloudVoiceId = settings.cloudVoiceId;
    this.ttsCustomVoiceOptions = SystemTtsReader.parseCustomVoices(settings.customVoices);
  }

  onTtsCustomVoicesChanged(): void {
    this.ttsCustomVoiceOptions = SystemTtsReader.parseCustomVoices(this.ttsCustomVoices);
    this.ttsSelectedVoiceKey = this.currentTtsVoiceKey();
  }

  normalizeDefaultTtsVoice(): void {
    if (this.ttsOnline === 0 && this.ttsPerson === 0 && !this.ttsStyle &&
      this.sameTtsLanguage(this.ttsLanguage || 'zh-CN', 'zh-CN')) {
      this.ttsOnline = 1;
      this.saveTtsSettings();
    }
  }

  currentTtsSettings(): TtsSettings {
    const settings = new TtsSettings();
    settings.person = this.ttsPerson;
    settings.online = this.ttsOnline;
    settings.style = this.ttsStyle;
    settings.language = this.ttsLanguage;
    settings.speed = this.ttsSpeed;
    settings.installedVoiceKeys = this.ttsInstalledVoiceKeys;
    settings.customVoiceId = this.ttsCustomVoiceId;
    settings.customVoices = this.ttsCustomVoices;
    settings.cloudVoiceId = this.ttsCloudVoiceId;
    return settings;
  }

  saveTtsSettings(): void {
    const settings = this.currentTtsSettings();
    TtsSettingsStore.applyToStorage(settings);
    TtsSettingsStore.save(getContext(this), settings).catch((e: Error) => {
      console.warn('保存朗读设置失败:', e);
    });
  }

  async loadTtsVoices(): Promise<void> {
    if (this.ttsVoicesLoading) {
      return;
    }
    this.ttsVoicesLoading = true;
    try {
      const voiceResults = await Promise.all([
        SystemTtsReader.listAvailableVoices(),
        AccountCommerceApi.fetchTtsCatalog().catch(() => null)
      ]);
      const voices = voiceResults[0] as TtsVoiceOption[];
      const catalog = voiceResults[1];
      this.ttsCloudVoices = catalog ? catalog.voices : [];
      if (catalog && this.ttsCloudVoiceId && !this.findCurrentCloudTtsVoice()) {
        const previousVoiceId = this.ttsCloudVoiceId;
        const fallbackVoice = this.ttsCloudVoices.find((voice: TtsVoiceInfo) => voice.id === 'xiaoyan') ||
          this.ttsCloudVoices[0];
        this.ttsCloudVoiceId = fallbackVoice ? fallbackVoice.id : '';
        console.warn(`[TTS] unsupported cloud voice migrated: ${previousVoiceId} -> ${this.ttsCloudVoiceId}`);
        this.saveTtsSettings();
      }
      if (!catalog && this.ttsCloudVoiceId) {
        const fallbackCloudVoice = new TtsVoiceInfo();
        fallbackCloudVoice.id = this.ttsCloudVoiceId;
        fallbackCloudVoice.name = '云端音色';
        this.ttsCloudVoices = [fallbackCloudVoice];
      }
      this.ttsVoices = this.applyInstalledTtsVoiceOverrides(this.mergeWithDefaultTtsVoice(voices));
      const currentCloudVoice = this.findCurrentCloudTtsVoice();
      if (currentCloudVoice) {
        this.ttsSelectedVoiceKey = this.ttsCloudVoiceKey(currentCloudVoice);
        return;
      }
      const currentCustomVoice = this.findCurrentCustomTtsVoice();
      if (currentCustomVoice) {
        this.ttsSelectedVoiceKey = this.ttsCustomVoiceKey(currentCustomVoice);
        return;
      }
      const currentVoice = this.findCurrentTtsVoice();
      if (currentVoice && currentVoice.available) {
        this.ttsSelectedVoiceKey = this.ttsVoiceKey(currentVoice);
      } else {
        this.applyTtsVoice(this.firstAvailableTtsVoice(), false);
      }
    } catch (e) {
      this.ttsVoices = [ReadBookPage.defaultTtsVoice()];
      this.ttsPerson = 0;
      this.ttsOnline = 1;
      this.ttsStyle = '';
      this.ttsLanguage = 'zh-CN';
      this.ttsCustomVoiceId = '';
      this.ttsCloudVoiceId = '';
      this.saveTtsSettings();
      this.ttsSelectedVoiceKey = this.currentTtsVoiceKey();
      console.warn('加载朗读音色失败:', e);
    } finally {
      this.ttsVoicesLoading = false;
    }
  }

  mergeWithDefaultTtsVoice(voices: TtsVoiceOption[]): TtsVoiceOption[] {
    const options: TtsVoiceOption[] = [ReadBookPage.defaultTtsVoice()];
    for (const voice of voices) {
      const existingIndex = options.findIndex((item: TtsVoiceOption) =>
        this.isSameTtsVoiceOption(item, voice) || this.isSameTtsDisplayVoice(item, voice));
      if (existingIndex < 0) {
        options.push(voice);
      } else if (this.shouldPreferTtsVoiceOption(voice, options[existingIndex])) {
        options[existingIndex] = voice;
      }
    }
    return options;
  }

  firstAvailableTtsVoice(): TtsVoiceOption {
    return this.ttsVoices.find((voice: TtsVoiceOption) => voice.available) || this.ttsVoices[0] ||
      ReadBookPage.defaultTtsVoice();
  }

  applyInstalledTtsVoiceOverrides(voices: TtsVoiceOption[]): TtsVoiceOption[] {
    const options: TtsVoiceOption[] = [];
    for (const voice of voices) {
      options.push(this.isLocallyInstalledTtsVoice(voice) ? this.markTtsVoiceOptionInstalled(voice) : voice);
    }
    return options;
  }

  markTtsVoiceOptionInstalled(voice: TtsVoiceOption): TtsVoiceOption {
    const option = new TtsVoiceOption();
    option.id = voice.id;
    option.name = voice.name;
    option.online = voice.online;
    option.status = 'INSTALLED';
    option.systemStatus = 'INSTALLED';
    option.style = voice.style;
    option.language = voice.language;
    option.downloadLanguage = voice.downloadLanguage;
    option.gender = voice.gender;
    option.available = true;
    option.downloadable = false;
    return option;
  }

  isLocallyInstalledTtsVoice(voice: TtsVoiceOption): boolean {
    const key = this.installedTtsVoiceKey(voice);
    return !!key && this.ttsInstalledVoiceKeys.split('\n').includes(key);
  }

  installedTtsVoiceKey(voice: TtsVoiceOption): string {
    const style = this.isKnownTtsVoiceId(voice.id) ? '' : (voice.style || '');
    return `${voice.id}_${voice.online}_${this.normalizeTtsLanguage(voice.language || 'zh-CN')}_${style}`;
  }

  isSameTtsVoiceOption(left: TtsVoiceOption, right: TtsVoiceOption): boolean {
    if (left.id !== right.id || left.online !== right.online ||
      !this.sameTtsLanguage(left.language || 'zh-CN', right.language || 'zh-CN')) {
      return false;
    }
    if (this.isKnownTtsVoiceId(left.id)) {
      return true;
    }
    return (left.style || '') === (right.style || '');
  }

  isSameTtsDisplayVoice(left: TtsVoiceOption, right: TtsVoiceOption): boolean {
    if (this.ttsVoiceTitle(left) === this.ttsVoiceTitle(right)) {
      return true;
    }
    return (left.name || '') === (right.name || '') && left.online === right.online &&
      this.sameTtsLanguage(left.language || 'zh-CN', right.language || 'zh-CN');
  }

  shouldPreferTtsVoiceOption(candidate: TtsVoiceOption, current: TtsVoiceOption): boolean {
    if (candidate.available !== current.available) {
      return candidate.available;
    }
    if (this.isKnownTtsVoiceId(candidate.id) !== this.isKnownTtsVoiceId(current.id)) {
      return this.isKnownTtsVoiceId(candidate.id);
    }
    if (candidate.downloadable !== current.downloadable) {
      return candidate.downloadable;
    }
    return !current.style && !!candidate.style;
  }

  isKnownTtsVoiceId(id: number): boolean {
    return id === 0 || id === 8 || id === 13 || id === 21;
  }

  applyTtsVoice(voice: TtsVoiceOption, restartSpeaking: boolean): void {
    if (!voice.available) {
      promptAction.showToast({ message: voice.downloadable ? '请到朗读设置下载该音色' : '该系统音色当前不可用' });
      return;
    }
    const shouldResume = restartSpeaking && (this.isTtsSpeaking || this.ttsReader.isSpeaking());
    if (shouldResume) {
      this.stopTtsReading();
    }
    this.ttsPerson = voice.id;
    this.ttsOnline = voice.online;
    this.ttsStyle = voice.style;
    this.ttsLanguage = voice.language;
    this.ttsCustomVoiceId = '';
    this.ttsCloudVoiceId = '';
    this.ttsSelectedVoiceKey = this.ttsVoiceKey(voice);
    this.saveTtsSettings();
    if (shouldResume) {
      this.startTtsReadingFromCurrentPosition(false).catch((e: Error) => {
        console.warn('切换朗读音色后恢复朗读失败:', e);
      });
    }
  }

  applyTtsSpeed(value: number): void {
    const nextSpeed = Math.max(0.5, Math.min(2, Math.round(value * 10) / 10));
    if (Math.abs(this.ttsSpeed - nextSpeed) < 0.01) {
      return;
    }
    this.ttsSpeed = nextSpeed;
    this.scheduleTtsSpeedSettingsSave();
    this.updateTtsFloatingSession();
    if (this.isTtsSpeaking || this.ttsReader.isSpeaking()) {
      this.scheduleTtsSpeedAvSessionUpdate();
    }
  }

  scheduleTtsSpeedSettingsSave(): void {
    if (this.ttsSpeedSaveTimerId >= 0) {
      clearTimeout(this.ttsSpeedSaveTimerId);
    }
    this.ttsSpeedSaveTimerId = setTimeout(() => {
      this.ttsSpeedSaveTimerId = -1;
      this.saveTtsSettings();
    }, 300);
  }

  scheduleTtsSpeedAvSessionUpdate(): void {
    if (this.ttsSpeedAvSessionTimerId >= 0) {
      clearTimeout(this.ttsSpeedAvSessionTimerId);
    }
    this.ttsSpeedAvSessionTimerId = setTimeout(() => {
      this.ttsSpeedAvSessionTimerId = -1;
      if (this.isTtsSpeaking || this.ttsReader.isSpeaking()) {
        this.updateTtsAvSessionPlaybackState(this.ttsAvPlaybackState()).catch((e: Error) => {
          console.warn('更新朗读倍速媒体状态失败:', e);
        });
      }
    }, 300);
  }

  flushPendingTtsSpeedSettings(): void {
    if (this.ttsSpeedSaveTimerId >= 0) {
      clearTimeout(this.ttsSpeedSaveTimerId);
      this.ttsSpeedSaveTimerId = -1;
      this.saveTtsSettings();
    }
    if (this.ttsSpeedAvSessionTimerId >= 0) {
      clearTimeout(this.ttsSpeedAvSessionTimerId);
      this.ttsSpeedAvSessionTimerId = -1;
    }
  }

  currentTtsVoiceKey(): string {
    const cloudVoice = this.findCurrentCloudTtsVoice();
    if (cloudVoice) {
      return this.ttsCloudVoiceKey(cloudVoice);
    }
    const customVoice = this.findCurrentCustomTtsVoice();
    if (customVoice) {
      return this.ttsCustomVoiceKey(customVoice);
    }
    const matched = this.findCurrentTtsVoice();
    return matched ? this.ttsVoiceKey(matched) :
      `${this.ttsPerson}_${this.ttsOnline}_${this.ttsLanguage || 'zh-CN'}_${this.ttsStyle || ''}_`;
  }

  findCurrentTtsVoice(): TtsVoiceOption | undefined {
    return this.ttsVoices.find((voice: TtsVoiceOption) => this.isCurrentTtsVoice(voice));
  }

  isCurrentTtsVoice(voice: TtsVoiceOption): boolean {
    if (this.ttsCustomVoiceId || this.ttsCloudVoiceId) {
      return false;
    }
    return voice.id === this.ttsPerson && voice.online === this.ttsOnline &&
      (voice.style || '') === (this.ttsStyle || '') &&
      this.sameTtsLanguage(voice.language || 'zh-CN', this.ttsLanguage || 'zh-CN');
  }

  applyCustomTtsVoice(voice: HttpTTS, restartSpeaking: boolean): void {
    if (voice.enabled === false) {
      promptAction.showToast({ message: '该自定义音色已禁用' });
      return;
    }
    const shouldResume = restartSpeaking && (this.isTtsSpeaking || this.ttsReader.isSpeaking());
    if (shouldResume) {
      this.stopTtsReading();
    }
    this.ttsCustomVoiceId = String(voice.id);
    this.ttsCloudVoiceId = '';
    this.ttsSelectedVoiceKey = this.ttsCustomVoiceKey(voice);
    this.saveTtsSettings();
    if (shouldResume) {
      this.startTtsReadingFromCurrentPosition(false).catch((e: Error) => {
        console.warn('切换自定义朗读音色后恢复朗读失败:', e);
      });
    }
  }

  findCurrentCustomTtsVoice(): HttpTTS | undefined {
    const selectedId = (this.ttsCustomVoiceId || '').trim();
    if (!selectedId) {
      return undefined;
    }
    return this.ttsCustomVoiceOptions.find((voice: HttpTTS) => String(voice.id) === selectedId);
  }

  ttsCustomVoiceKey(voice: HttpTTS): string {
    return `custom_${voice.id}_${voice.name || ''}`;
  }

  isCurrentCustomTtsVoice(voice: HttpTTS): boolean {
    return (this.ttsCustomVoiceId || '') === String(voice.id);
  }

  ttsCustomVoiceTitle(voice: HttpTTS): string {
    const state = voice.enabled === false ? ' · 已禁用' : '';
    return `${voice.name || '未命名音色'} · 自定义${state}`;
  }

  ttsVoiceKey(voice: TtsVoiceOption): string {
    return `${voice.id}_${voice.online}_${voice.language || 'zh-CN'}_${voice.style || ''}_${voice.name || ''}`;
  }

  ttsVoiceTitle(voice: TtsVoiceOption): string {
    if (voice.status === 'default') {
      return `${voice.name} · 系统默认`;
    }
    const suffix = voice.online === 0 ? '在线' : '离线';
    const gender = this.ttsVoiceGenderText(voice);
    const state = voice.available ? '' : (voice.downloadable ? ' · 需下载' : ' · 不可用');
    return `${voice.name} · ${suffix}${gender}${state}`;
  }

  ttsVoiceGenderText(voice: TtsVoiceOption): string {
    const value = (voice.gender || '').toLowerCase();
    if (value === 'male' || value === '男' || value === '男声') {
      return ' · 男声';
    }
    if (value === 'female' || value === '女' || value === '女声') {
      return ' · 女声';
    }
    return '';
  }

  sameTtsLanguage(left: string, right: string): boolean {
    return this.normalizeTtsLanguage(left) === this.normalizeTtsLanguage(right);
  }

  normalizeTtsLanguage(language: string): string {
    const value = (language || 'zh-CN').trim().replace(/_/g, '-').toLowerCase();
    if (value === 'zh' || value === 'zh-cn' || value.startsWith('zh-hans')) {
      return 'zh-CN';
    }
    if (value === 'en' || value === 'en-us') {
      return 'en-US';
    }
    return value || 'zh-CN';
  }

  tocGlobalIndex(localIndex: number): number {
    if (this.isTocSearchActive()) {
      return this.tocSearchChapterIndexes[localIndex] ?? 0;
    }
    return this.tocWindowStart + localIndex;
  }

  applyCloudTtsVoice(voice: TtsVoiceInfo, restartSpeaking: boolean): void {
    if (!AccountSessionStore.isLoggedIn()) {
      promptAction.showToast({ message: '请先登录华为账号后使用在线音色' });
      return;
    }
    const shouldResume = restartSpeaking && (this.isTtsSpeaking || this.ttsReader.isSpeaking());
    if (shouldResume) {
      this.stopTtsReading();
    }
    this.ttsCloudVoiceId = voice.id;
    this.ttsCustomVoiceId = '';
    this.ttsSelectedVoiceKey = this.ttsCloudVoiceKey(voice);
    this.saveTtsSettings();
    if (shouldResume) {
      this.startTtsReadingFromCurrentPosition(false).catch((e: Error) => {
        console.warn('切换在线朗读音色后恢复失败:', e);
      });
    }
  }

  findCurrentCloudTtsVoice(): TtsVoiceInfo | undefined {
    const selectedId = (this.ttsCloudVoiceId || '').trim();
    if (!selectedId) return undefined;
    return this.ttsCloudVoices.find((voice: TtsVoiceInfo) => voice.id === selectedId);
  }

  ttsCloudVoiceKey(voice: TtsVoiceInfo): string {
    return `cloud_${voice.id}`;
  }

  isCurrentCloudTtsVoice(voice: TtsVoiceInfo): boolean {
    return (this.ttsCloudVoiceId || '') === voice.id;
  }

  ttsCloudVoiceTitle(voice: TtsVoiceInfo): string {
    const tier = voice.tier === 'PREMIUM' ? '精品' : '标准';
    const description = (voice.description || '').trim();
    return description
      ? `${voice.name} · ${description} · 云端${tier}`
      : `${voice.name} · 云端${tier}`;
  }

  selectableCustomTtsVoices(): HttpTTS[] {
    return this.ttsCustomVoiceOptions.filter((voice: HttpTTS) => voice.enabled !== false);
  }

  selectableSystemTtsVoices(): TtsVoiceOption[] {
    return this.ttsVoices.filter((voice: TtsVoiceOption) => voice.available);
  }

  selectedTtsVoiceTitle(): string {
    const cloudVoice = this.findCurrentCloudTtsVoice();
    if (cloudVoice) {
      return this.ttsCloudVoiceTitle(cloudVoice);
    }
    const customVoice = this.findCurrentCustomTtsVoice();
    if (customVoice && customVoice.enabled !== false) {
      return this.ttsCustomVoiceTitle(customVoice);
    }
    const systemVoice = this.findCurrentTtsVoice();
    if (systemVoice && systemVoice.available) {
      return this.ttsVoiceTitle(systemVoice);
    }
    const customVoices = this.selectableCustomTtsVoices();
    if (this.ttsCloudVoices.length > 0) {
      return this.ttsCloudVoiceTitle(this.ttsCloudVoices[0]);
    }
    if (customVoices.length > 0) {
      return this.ttsCustomVoiceTitle(customVoices[0]);
    }
    const systemVoices = this.selectableSystemTtsVoices();
    return systemVoices.length > 0 ? this.ttsVoiceTitle(systemVoices[0]) : '暂无可用音色';
  }

  ttsQuickVoiceOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (const voice of this.ttsCloudVoices) {
      options.push({ value: this.ttsCloudVoiceTitle(voice) });
    }
    for (const voice of this.selectableCustomTtsVoices()) {
      options.push({ value: this.ttsCustomVoiceTitle(voice) });
    }
    for (const voice of this.selectableSystemTtsVoices()) {
      options.push({ value: this.ttsVoiceTitle(voice) });
    }
    if (options.length === 0) {
      options.push({ value: '暂无可用音色' });
    }
    return options;
  }

  ttsQuickVoiceSelectedIndex(): number {
    const cloudIndex = this.ttsCloudVoices.findIndex((voice: TtsVoiceInfo) =>
      this.isCurrentCloudTtsVoice(voice));
    if (cloudIndex >= 0) return cloudIndex;
    const customVoices = this.selectableCustomTtsVoices();
    const customIndex = customVoices.findIndex((voice: HttpTTS) => this.isCurrentCustomTtsVoice(voice));
    if (customIndex >= 0) return this.ttsCloudVoices.length + customIndex;
    const systemVoices = this.selectableSystemTtsVoices();
    const systemIndex = systemVoices.findIndex((voice: TtsVoiceOption) => this.isCurrentTtsVoice(voice));
    if (systemIndex >= 0) return this.ttsCloudVoices.length + customVoices.length + systemIndex;
    return 0;
  }

  selectTtsQuickVoice(index: number): void {
    if (index < 0) return;
    if (index < this.ttsCloudVoices.length) {
      this.applyCloudTtsVoice(this.ttsCloudVoices[index], true);
      return;
    }
    const customVoices = this.selectableCustomTtsVoices();
    const customIndex = index - this.ttsCloudVoices.length;
    if (customIndex < customVoices.length) {
      this.applyCustomTtsVoice(customVoices[customIndex], true);
      return;
    }
    const systemVoices = this.selectableSystemTtsVoices();
    const systemIndex = customIndex - customVoices.length;
    if (systemIndex >= 0 && systemIndex < systemVoices.length) {
      this.applyTtsVoice(systemVoices[systemIndex], true);
    }
  }

  isTocSearchActive(): boolean {
    return this.tocSearchVisible && this.tocSearchResultActive;
  }

  toggleTocSearch(): void {
    if (this.tocSearchVisible) {
      this.tocSearchVisible = false;
      this.tocSearchQuery = '';
      this.tocSearchChapterIndexes = [];
      this.tocSearchLoading = false;
      this.tocSearchResultActive = false;
      this.tocSearchRequestSerial++;
      this.setTocWindowAround(this.currentChapterIndex, ScrollAlign.CENTER);
      this.scrollTocToCurrentChapter(false);
      return;
    }
    this.tocSearchVisible = true;
    this.tocQuickJumpArmed = false;
    this.tocQuickJumpInputVisible = false;
    this.tocQuickJumpDraft = '';
    setTimeout(() => {
      focusControl.requestFocus('tocChapterSearchInput');
    }, 50);
  }

  async submitTocSearch(): Promise<void> {
    const keyword = this.tocSearchQuery.trim();
    if (!keyword) {
      this.clearTocSearchResult();
      return;
    }
    const requestSerial = ++this.tocSearchRequestSerial;
    const bookUrl = this.book?.bookUrl || this.bookUrl;
    this.tocSearchLoading = true;
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      const matches = await db.searchBookChapters(bookUrl, keyword);
      const totalCount = await db.getBookChapterCount(bookUrl);
      if (requestSerial !== this.tocSearchRequestSerial || !this.tocSearchVisible) return;
      const indexes: number[] = [];
      for (const chapter of matches) {
        indexes.push(chapter.index);
      }
      this.tocDatabaseChapterCount = Math.max(totalCount, this.chapters.length);
      this.tocSearchChapterIndexes = indexes;
      this.tocVisibleChapters = matches;
      this.tocWindowStart = 0;
      this.tocSearchResultActive = true;
      this.tocFirstVisibleGlobalIndex = indexes.length > 0 ? indexes[0] : 0;
      this.tocVisibleItemCount = 1;
      console.info(`[TOC] 数据库目录搜索: keyword=${keyword}, total=${totalCount}, matches=${matches.length}`);
      setTimeout(() => {
        if (matches.length > 0) {
          this.tocScroller.scrollToIndex(0, false, ScrollAlign.START);
        }
      }, 0);
    } catch (e) {
      console.warn('数据库目录搜索失败:', e);
      if (requestSerial === this.tocSearchRequestSerial) {
        promptAction.showToast({ message: '目录搜索失败' });
      }
    } finally {
      if (requestSerial === this.tocSearchRequestSerial) {
        this.tocSearchLoading = false;
      }
    }
  }

  clearTocSearchResult(): void {
    this.tocSearchRequestSerial++;
    this.tocSearchQuery = '';
    this.tocSearchLoading = false;
    this.tocSearchResultActive = false;
    this.tocSearchChapterIndexes = [];
    const localIndex = this.setTocWindowAround(this.currentChapterIndex, ScrollAlign.CENTER);
    setTimeout(() => {
      try {
        this.tocScroller.scrollToIndex(localIndex, false, ScrollAlign.CENTER);
      } catch (e) {
        console.warn('清空目录搜索后恢复定位失败:', e);
      }
    }, 0);
  }

  async loadTocDatabaseChapterCount(): Promise<void> {
    const bookUrl = this.book?.bookUrl || this.bookUrl;
    if (!bookUrl) return;
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      this.tocDatabaseChapterCount = Math.max(await db.getBookChapterCount(bookUrl), this.chapters.length);
    } catch (e) {
      console.warn('读取数据库章节总数失败:', e);
    }
  }

  updateTocScrollbarPosition(start: number, end: number): void {
    const localStart = Math.max(0, start);
    this.tocFirstVisibleGlobalIndex = this.tocGlobalIndex(localStart);
    this.tocVisibleItemCount = Math.max(1, end - start + 1);
  }

  tocShouldShowVirtualScrollbar(): boolean {
    return this.tocListViewportHeight > 0 && this.tocDatabaseChapterCount > this.tocVisibleItemCount;
  }

  tocScrollbarThumbLength(): number {
    return VirtualListScrollbar.thumbLength(this.tocListViewportHeight,
      this.tocDatabaseChapterCount, this.tocVisibleItemCount);
  }

  tocScrollbarThumbOffset(): number {
    const thumbLength = this.tocScrollbarThumbLength();
    return VirtualListScrollbar.thumbOffset(this.tocListViewportHeight, thumbLength,
      this.tocDatabaseChapterCount, this.tocFirstVisibleGlobalIndex, this.tocVisibleItemCount);
  }

  scrollTocVisibleEdge(toEnd: boolean): void {
    if (!this.isTocSearchActive()) {
      this.scrollTocToChapter(toEnd ? this.chapters.length - 1 : 0,
        toEnd ? ScrollAlign.END : ScrollAlign.START);
      return;
    }
    if (this.tocVisibleChapters.length === 0) {
      return;
    }
    const localIndex = toEnd ? this.tocVisibleChapters.length - 1 : 0;
    setTimeout(() => {
      try {
        this.tocScroller.scrollToIndex(localIndex, true, toEnd ? ScrollAlign.END : ScrollAlign.START);
      } catch (e) {
        console.warn('定位目录搜索结果失败:', e);
      }
    }, 0);
  }

  setTocWindowAround(index: number, align: ScrollAlign): number {
    this.tocLoadingPreviousPage = false;
    this.tocLoadingNextPage = false;
    if (this.chapters.length === 0) {
      this.tocWindowStart = 0;
      this.tocVisibleChapters = [];
      return 0;
    }
    const target = Math.max(0, Math.min(index, this.chapters.length - 1));
    let start = target - Math.floor(TOC_WINDOW_PAGE_SIZE / 2);
    if (align === ScrollAlign.START) {
      start = target;
    } else if (align === ScrollAlign.END) {
      start = target - TOC_WINDOW_PAGE_SIZE + 1;
    }
    start = Math.max(0, Math.min(start, Math.max(0, this.chapters.length - TOC_WINDOW_PAGE_SIZE)));
    const end = Math.min(this.chapters.length, start + TOC_WINDOW_PAGE_SIZE);
    this.tocWindowStart = start;
    this.tocVisibleChapters = this.chapters.slice(start, end);
    return target - start;
  }

  loadNextTocPage(): void {
    if (this.isTocSearchActive() || this.tocPositioning || this.tocLoadingNextPage) {
      return;
    }
    const loadedEnd = this.tocWindowStart + this.tocVisibleChapters.length;
    if (loadedEnd >= this.chapters.length) {
      return;
    }
    this.tocLoadingNextPage = true;
    const nextEnd = Math.min(this.chapters.length, loadedEnd + TOC_WINDOW_PAGE_SIZE);
    this.tocVisibleChapters = this.tocVisibleChapters.concat(this.chapters.slice(loadedEnd, nextEnd));
    setTimeout(() => {
      this.tocLoadingNextPage = false;
    }, 0);
  }

  loadPreviousTocPage(): void {
    if (this.isTocSearchActive() || this.tocPositioning || this.tocLoadingPreviousPage ||
      this.tocWindowStart <= 0) {
      return;
    }
    this.tocLoadingPreviousPage = true;
    const oldStart = this.tocWindowStart;
    const nextStart = Math.max(0, oldStart - TOC_WINDOW_PAGE_SIZE);
    const added = oldStart - nextStart;
    this.tocWindowStart = nextStart;
    this.tocVisibleChapters = this.chapters.slice(nextStart, oldStart).concat(this.tocVisibleChapters);
    setTimeout(() => {
      try {
        this.tocScroller.scrollToIndex(added, false, ScrollAlign.START);
      } catch (e) {
        console.warn('向前加载目录失败:', e);
      } finally {
        this.tocLoadingPreviousPage = false;
      }
    }, 0);
  }

  scrollTocToCurrentChapter(smooth: boolean = true): void {
    if (this.chapters.length === 0) {
      return;
    }
    const index = Math.max(0, Math.min(this.currentChapterIndex, this.chapters.length - 1));
    this.scrollTocToChapter(index, ScrollAlign.CENTER, smooth);
  }

  scrollTocToChapter(index: number, align: ScrollAlign, smooth: boolean = true): void {
    if (this.chapters.length === 0) {
      return;
    }
    const targetIndex = Math.max(0, Math.min(index, this.chapters.length - 1));
    const requestSerial = ++this.tocPositionRequestSerial;
    this.tocPositioning = true;
    const localIndex = this.setTocWindowAround(targetIndex, align);
    setTimeout(() => {
      if (requestSerial !== this.tocPositionRequestSerial) {
        return;
      }
      try {
        this.tocScroller.scrollToIndex(localIndex, smooth, align);
      } catch (e) {
        console.warn('定位目录章节失败:', e);
      } finally {
        setTimeout(() => {
          if (requestSerial === this.tocPositionRequestSerial) {
            this.tocPositioning = false;
          }
        }, 0);
      }
    }, 50);
  }

  getSubTextColor(): string {
    return this.currentReaderTheme().subTextColor;
  }

  accentColor(): string {
    return ThemeRuntime.accentColor(this.appDarkMode);
  }

  buttonColor(): string {
    return ThemeRuntime.buttonColor(this.appDarkMode);
  }

  tocSelectedBackgroundColor(): string {
    const color = this.accentColor();
    if (/^#[0-9A-Fa-f]{6}$/.test(color)) {
      return `#11${color.substring(1)}`;
    }
    return this.appDarkMode ? '#112A6FCC' : '#11007DFF';
  }

  readerGlassPanelColor(): string {
    return ThemeRuntime.glassPanelColor(this.isReaderThemeDark(), this.getBackgroundColor());
  }

  readerGlassBorderColor(): string {
    return ThemeRuntime.glassBorderColor(this.isReaderThemeDark());
  }

  readerGlassShadowColor(): string {
    return ThemeRuntime.glassShadowColor(this.isReaderThemeDark());
  }

  readerSolidPanelColor(): string {
    return this.isReaderThemeDark() ? '#191B1F' : '#FFFFFF';
  }

  getReaderSafeAreaEdges(): SafeAreaEdge[] {
    return this.isReaderComicModeActive() || this.readerExtendToStatusBar ||
      this.hasBackgroundImage() || this.isStackPageTurnAnimation() || this.isSimulationPageTurnAnimation() ?
      [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM] : [SafeAreaEdge.BOTTOM];
  }

  getReaderPageTurnSurfaceSafeAreaEdges(): SafeAreaEdge[] {
    return this.isSimulationPageTurnAnimation() ?
      [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM] : [SafeAreaEdge.BOTTOM];
  }

  getReaderTopSafePadding(): number {
    if (this.isReaderComicModeActive()) {
      return 0;
    }
    // 扩展模式会隐藏状态栏，正文直接从屏幕顶部起算，不为已隐藏的状态栏保留高度。
    if (this.readerExtendToStatusBar) {
      return 0;
    }
    // 堆叠/仿真翻页的每一层会单独补偿顶部安全区，避免动画层与静态层坐标不一致。
    if (this.isStackPageTurnAnimation() || this.isSimulationPageTurnAnimation()) {
      return 0;
    }
    // 普通布局由系统安全区确定顶部起点。只有背景图要求根容器覆盖状态栏时才手动补偿。
    return this.hasBackgroundImage() ? this.statusBarSafeHeight : 0;
  }

  getReaderPageContentTopPadding(): number {
    return !this.readerExtendToStatusBar &&
      (this.isStackPageTurnAnimation() || this.isSimulationPageTurnAnimation()) ? this.statusBarSafeHeight : 0;
  }

  getTopControlSafePadding(): number {
    return Math.max(this.statusBarSafeHeight, 32);
  }

  getTopOverlayHeight(): number {
    return 56 + this.getTopControlSafePadding();
  }

  getReaderContentBottomReserve(): number {
    return 0;
  }

  getReaderBottomInfoBarHeight(): number {
    return 24;
  }

  getReaderPaginationBottomInfoBarHeight(): number {
    if (this.readerExtendToStatusBar) return 0;
    // 下边距本身已经属于正文外区域，应先用它容纳页脚，不能再无条件叠加一份 24vp。
    // 只有用户把下边距设得比页脚更小时才补足差额，以免页码覆盖最后一行。
    return Math.max(0, this.getReaderBottomInfoBarHeight() - Math.max(0, this.readerMarginBottom));
  }

  getReaderBottomInfoBarVisualOffsetY(): number {
    // 仅移动页脚绘制位置，不参与分页占位计算。
    return -6;
  }

  readerFloatingBarBottomMargin(): number {
    return this.navBarHeight > 0 ? this.navBarHeight : 8;
  }

  readerFloatingBarWidth(): number {
    const viewportWidth = this.pageViewWidth > 0 ? this.pageViewWidth : 360;
    const availableWidth = Math.max(0, viewportWidth - this.readerFloatingBarEdgeInset() * 2);
    if (this.readerUsesSideAnchoredControls()) {
      return Math.min(availableWidth, Math.min(520, Math.max(320, viewportWidth * 0.52)));
    }
    return Math.min(viewportWidth, Math.max(240, availableWidth));
  }

  readerChapterTrackColor(): string {
    return this.isReaderThemeDark() ? '#2EFFFFFF' : '#1F000000';
  }

  readerFloatingBarEdgeInset(): number {
    return 18;
  }

  readerUsesSideAnchoredControls(): boolean {
    const viewportWidth = this.pageViewWidth > 0 ? this.pageViewWidth : 360;
    return viewportWidth >= 600;
  }

  readerFloatingBarLeft(): number {
    const viewportWidth = this.pageViewWidth > 0 ? this.pageViewWidth : 360;
    const barWidth = this.readerFloatingBarWidth();
    if (!this.readerUsesSideAnchoredControls()) {
      return Math.max(0, (viewportWidth - barWidth) / 2);
    }
    if (this.readerMenuAnchorSide < 0) {
      return this.readerFloatingBarEdgeInset();
    }
    return Math.max(this.readerFloatingBarEdgeInset(),
      viewportWidth - this.readerFloatingBarEdgeInset() - barWidth);
  }

  readerFloatingBarRight(): number {
    return this.readerFloatingBarLeft() + this.readerFloatingBarWidth();
  }

  readerFloatingBarTranslateX(): number {
    const viewportWidth = this.pageViewWidth > 0 ? this.pageViewWidth : 360;
    const centeredLeft = (viewportWidth - this.readerFloatingBarWidth()) / 2;
    return this.readerFloatingBarLeft() - centeredLeft;
  }

  readerChapterTooltipWidth(): number {
    return Math.min(320, this.readerFloatingBarWidth() * 0.62);
  }

  readerChapterTooltipCenteredLeft(): number {
    const viewportWidth = this.pageViewWidth > 0 ? this.pageViewWidth : 360;
    return (viewportWidth - this.readerChapterTooltipWidth()) / 2;
  }

  readerTtsQuickActionLeft(): number {
    if (this.readerUsesSideAnchoredControls() && this.readerMenuAnchorSide < 0) {
      return this.readerFloatingBarLeft();
    }
    return this.readerFloatingBarRight() - 48;
  }

  readerTtsExpandedControlLeft(): number {
    if (this.readerUsesSideAnchoredControls() && this.readerMenuAnchorSide < 0) {
      return this.readerFloatingBarLeft();
    }
    return this.readerFloatingBarRight() - this.readerTtsExpandedControlWidth();
  }

  readerBottomMenuOverlayHeight(): number {
    return (this.readerUseChapterQuickJump ? 120 : 56) + this.readerFloatingBarBottomMargin();
  }

  readerBottomActionOverlayHeight(): number {
    return 56 + this.readerFloatingBarBottomMargin();
  }

  readerFloatingPanelBottomInset(): number {
    // 面板底边统一停在底部操作栏上方 4vp。
    return this.readerBottomActionOverlayHeight() + 4;
  }

  readerPanelTransition(): TransitionEffect {
    const appear = TransitionEffect.translate({ y: 52 })
      .combine(TransitionEffect.scale({ x: 0.985, y: 0.985, centerX: '50%', centerY: '100%' }))
      .combine(TransitionEffect.opacity(0))
      .animation({ duration: 300, curve: Curve.Friction });
    const disappear = TransitionEffect.translate({ y: 28 })
      .combine(TransitionEffect.scale({ x: 0.99, y: 0.99, centerX: '50%', centerY: '100%' }))
      .combine(TransitionEffect.opacity(0))
      .animation({ duration: 190, curve: Curve.EaseIn });
    return TransitionEffect.asymmetric(appear, disappear);
  }

  readerSettingsContentTransition(direction: number): TransitionEffect {
    const horizontalOffset = direction < 0 ? -28 : 28;
    const appear = TransitionEffect.translate({ x: horizontalOffset })
      .combine(TransitionEffect.opacity(0))
      .animation({ duration: 260, curve: Curve.Friction });
    const disappear = TransitionEffect.translate({ x: horizontalOffset * 0.65 })
      .combine(TransitionEffect.opacity(0))
      .animation({ duration: 160, curve: Curve.EaseIn });
    return TransitionEffect.asymmetric(appear, disappear);
  }

  readerTocPanelHeight(): number {
    const viewportHeight = this.pageViewHeight > 0 ? this.pageViewHeight : 720;
    const availableHeight = Math.max(280, viewportHeight - this.readerFloatingPanelBottomInset() - 12);
    return Math.min(availableHeight, Math.max(280, viewportHeight * 0.81));
  }

  getReaderContentBottomPadding(): number {
    return Math.max(0, this.readerMarginBottom + this.getReaderContentBottomReserve());
  }

  getReaderPaginationViewportHeight(): number {
    // Device layout reports the expanded reader surface itself through onAreaChange. Adding the
    // status-bar height again makes extended pages one safe-area too tall and pushes text under the footer.
    // When extension is disabled, pageViewHeight already starts below the top safe area as expected.
    return Math.max(1, this.pageViewHeight);
  }

  getReaderBackgroundViewportHeight(): number {
    // pageViewHeight excludes the explicit text-only status-bar inset when extension is disabled,
    // but already includes it in extended mode. Reuse the page-turn viewport calculation so the
    // static paper, simulation snapshots and curl canvas always fit the exact same full-screen rect.
    return Math.max(1, this.getPageTurnHeight());
  }

  getEffectiveReaderLineHeight(): number {
    return this.readerFontSize + Math.max(0, this.readerLineHeight);
  }

  getReaderPageColumnWidth(): number {
    if (!this.isLandscapeDoublePageActive()) return Math.max(1, this.pageViewWidth);
    // The divider participates in Row layout. Measuring each leaf as exactly half of the spread makes
    // pagination up to 0.5vp wider than the real Text node and can wrap one extra line at render time.
    return Math.max(1, (this.pageViewWidth - READER_DOUBLE_PAGE_DIVIDER_WIDTH) / 2);
  }

  getReaderAdaptiveLetterSpacing(): number {
    const availableWidth = Math.max(1,
      this.getReaderPageColumnWidth() - this.readerMarginLeft - this.readerMarginRight);
    try {
      const widthPx = vp2px(availableWidth);
      // ArkUI ultimately lays a component out on physical pixels, while graphics.text accepts a floating
      // constraint. Distribute only the discarded sub-pixel fraction across a typical line. JUSTIFY still
      // performs the visible horizontal alignment; this tiny non-positive correction keeps both breakers
      // on the same line without changing the user's chosen font size.
      const snappedWidthPx = Math.floor(widthPx);
      const charsPerLine = Math.max(8, Math.floor(availableWidth / Math.max(1, this.readerFontSize)));
      return Math.max(-0.08, Math.min(0, px2fp((snappedWidthPx - widthPx) / charsPerLine)));
    } catch (_) {
      return 0;
    }
  }

  getReaderPageLineSpacing(pageLineHeight: number = this.getEffectiveReaderLineHeight()): number {
    return Math.max(0, pageLineHeight - this.readerFontSize);
  }

  getReaderParagraphBoundarySpacing(pageLineHeight: number = this.getEffectiveReaderLineHeight()): number {
    return this.getReaderPageLineSpacing(pageLineHeight) + Math.max(0, this.readerParagraphSpacing);
  }

  getMeasuredReaderParagraphBoundarySpacingPx(): number {
    const boundaryPx = this.toMeasureNonNegativePx(this.getReaderParagraphBoundarySpacing());
    // Separate Text/Blank nodes are rounded independently by ArkUI. Model the average half-vp
    // boundary rounding only when paragraph spacing actually splits ordinary paragraphs into nodes.
    return boundaryPx + (this.readerParagraphSpacing > 0 ? this.toMeasurePx(0.5) : 0);
  }

  getReaderAdaptivePageLineHeight(text: string, chapterIndex: number, pageIndex: number,
    pageStart: number = -1, documentSource: string = ''): number {
    const baseLineHeight = this.getEffectiveReaderLineHeight();
    if (!text || this.isReaderNovelContinuousScrollModeActive() || this.isReaderImageOnlyPage(text)) {
      return baseLineHeight;
    }
    const source = documentSource || (chapterIndex === this.currentChapterIndex ? this.pagedContentText : '');
    const resolvedStart = pageStart >= 0 ? pageStart :
      (chapterIndex === this.currentChapterIndex ? this.getPageStartOffset(pageIndex) : -1);
    if (!source || resolvedStart < 0 || this.isReaderChapterLastPage(text, resolvedStart, source)) {
      return baseLineHeight;
    }

    const horizontalPadding = this.readerMarginLeft + this.readerMarginRight;
    const verticalPadding = this.readerMarginTop + this.getReaderContentBottomPadding() +
      this.getReaderPaginationBottomInfoBarHeight() + this.getReaderPaginationRenderGuardHeight();
    const columnWidth = this.getReaderPageColumnWidth();
    const availableWidth = Math.max(1, columnWidth - horizontalPadding);
    const availableHeight = Math.max(1, this.getReaderPaginationViewportHeight() - verticalPadding);
    const cacheKey = `${chapterIndex}_${pageIndex}_${resolvedStart}_${this.pageViewWidth}_${availableHeight}_` +
      `${this.readerTypographyCacheIdentity()}_${this.hashText(text)}`;
    const cached = this.readerAdaptiveLineHeightCache.get(cacheKey);
    if (cached !== undefined) return cached;

    const availableHeightPx = this.toMeasurePx(availableHeight);
    const paragraphs = this.getReaderTextParagraphs(text);
    let measuredHeightPx = 0;
    let adaptableInternalGapCount = 0;
    for (const paragraph of paragraphs) {
      const metrics = this.readerParagraphMetrics(paragraph.text, availableWidth,
        chapterIndex, source, resolvedStart + paragraph.start);
      measuredHeightPx += metrics.heightPx;
      if (!ReaderActionMarker.parse(paragraph.text) && !LocalBookService.isEpubImageMarker(paragraph.text)) {
        const lineCount = Math.max(1, metrics.lineCount);
        adaptableInternalGapCount += Math.max(0, lineCount - 1);
      }
    }
    if (paragraphs.length > 1) {
      measuredHeightPx += this.getMeasuredReaderParagraphBoundarySpacingPx() * (paragraphs.length - 1);
    }
    // Preserve only a sub-pixel rounding allowance. A fixed vp guard visibly shrinks the user-defined
    // text rectangle, while no allowance at all can put the last antialiased row fractionally outside it.
    const remainingHeightPx = Math.max(0, availableHeightPx - measuredHeightPx - 0.5);
    let adaptiveLineHeight = baseLineHeight;
    // All spacing is placed strictly between text lines. Internal text gaps and paragraph boundaries
    // are the only adjustable positions; fixed action/image rows retain their measured height.
    const adaptableGapCount = adaptableInternalGapCount + Math.max(0, paragraphs.length - 1);
    if (adaptableGapCount > 0 && remainingHeightPx > 0.5) {
      adaptiveLineHeight = baseLineHeight + Math.max(0, px2vp(remainingHeightPx / adaptableGapCount));
    }
    this.readerAdaptiveLineHeightCache.set(cacheKey, adaptiveLineHeight);
    while (this.readerAdaptiveLineHeightCache.size > 96) {
      const oldestKey = this.readerAdaptiveLineHeightCache.keys().next().value as string | undefined;
      if (oldestKey === undefined) break;
      this.readerAdaptiveLineHeightCache.delete(oldestKey);
    }
    return adaptiveLineHeight;
  }

  isReaderChapterLastPage(text: string, pageStart: number, documentSource: string): boolean {
    let pageEnd = Math.max(0, Math.min(documentSource.length, pageStart + (text || '').length));
    while (pageEnd < documentSource.length && this.isReaderTrimChar(documentSource.charAt(pageEnd))) pageEnd++;
    return pageEnd >= documentSource.length;
  }

  onReadLayoutChanged(): void {
    if (this.readerEntryInitializing || this.readerLayoutCommitInProgress) return;
    this.scheduleReaderLayoutChange();
  }

  scheduleReaderLayoutChange(): void {
    if (this.readerLayoutApplyTimerId >= 0) {
      clearTimeout(this.readerLayoutApplyTimerId);
    }
    this.readerLayoutApplyTimerId = setTimeout(() => {
      this.readerLayoutApplyTimerId = -1;
      this.applyPendingReaderLayoutChange();
    }, 1000);
  }

  scheduleReaderTypographyChange(): void {
    if (this.readerLayoutApplyTimerId >= 0) {
      clearTimeout(this.readerLayoutApplyTimerId);
    }
    this.readerLayoutApplyTimerId = setTimeout(() => {
      this.readerLayoutApplyTimerId = -1;
      this.commitReaderTypographyDraft();
      this.applyPendingReaderLayoutChange();
    }, 1000);
  }

  applyPendingReaderLayoutChange(): void {
    this.readerPaginationCache.clear();
    this.pageTurnPreviewKey = '';
    this.refreshReaderTextRender();
    this.paginateContent(this.content);
    this.preloadNextChapterPaginationLater();
    this.saveReaderLayoutSettings();
    this.saveReadConfig();
    this.saveReadingProgress();
  }

  flushPendingReaderLayoutChange(repaginate: boolean = true): void {
    if (this.readerLayoutApplyTimerId < 0 && !this.readerTypographyDraftPending) return;
    if (this.readerLayoutApplyTimerId >= 0) clearTimeout(this.readerLayoutApplyTimerId);
    this.readerLayoutApplyTimerId = -1;
    this.commitReaderTypographyDraft();
    if (repaginate && this.readerPageVisible) {
      this.applyPendingReaderLayoutChange();
      return;
    }
    this.saveReaderLayoutSettings();
    this.saveReadConfig();
  }

  refreshReaderTextRender(): void {
    this.pageRenderVersion++;
    this.pageTurnIncomingRenderVersion++;
  }

  forceCurrentReaderPageRender(): void {
    this.chapterJumpRenderGeneration++;
    this.pageRenderVersion++;
  }

  onReaderFontChanged(): void {
    const serial = ++this.readerFontChangeSerial;
    if (!this.readerFontFilePath) {
      this.clearReaderFontState();
      this.refreshReaderTextRender();
      this.onReadLayoutChanged();
      return;
    }
    this.registerReaderFont().then((registered: boolean) => {
      if (serial !== this.readerFontChangeSerial) {
        return;
      }
      if (registered || !this.readerFontFilePath) {
        this.refreshReaderTextRender();
      }
      this.onReadLayoutChanged();
    });
  }

  onReaderActiveFontChanged(): void {
    if (!this.readerFontFilePath && !this.readerActiveFontFamily && !this.readerStoredFontRegistered) {
      this.clearReaderFontState();
      this.refreshReaderTextRender();
      this.onReadLayoutChanged();
    }
  }

  onReaderExtendToStatusBarChanged(): void {
    this.scheduleReaderExtendLayoutRefresh();
  }

  onReaderScreenOrientationChanged(): void {
    if (this.readerPageVisible) this.applyReaderScreenOrientation();
  }

  applyReaderScreenOrientation(orientation: string = this.readerScreenOrientation): void {
    const normalized = ReaderSettingsStore.normalizeScreenOrientation(orientation);
    const serial = ++this.readerScreenOrientationSerial;
    let preferred = window.Orientation.UNSPECIFIED;
    if (normalized === ReaderSettingsStore.SCREEN_ORIENTATION_PORTRAIT) {
      preferred = window.Orientation.PORTRAIT;
    } else if (normalized === ReaderSettingsStore.SCREEN_ORIENTATION_LANDSCAPE) {
      preferred = window.Orientation.LANDSCAPE;
    }
    window.getLastWindow(getContext(this)).then((mainWindow: window.Window) => {
      if (serial !== this.readerScreenOrientationSerial) return;
      return mainWindow.setPreferredOrientation(preferred);
    }).catch((error: Error) => {
      console.warn('应用阅读屏幕方向失败:', error);
    });
  }

  resetReaderScreenOrientation(): void {
    this.applyReaderScreenOrientation(ReaderSettingsStore.SCREEN_ORIENTATION_SYSTEM);
  }

  syncReaderPageHeightForContentTopPadding(): void {
    const nextTopPadding = this.getReaderPageContentTopPadding();
    // The system-bar switch itself changes the reader area's measured height. Do not pre-add/subtract the
    // same inset here: onAreaChange will publish the new text viewport, and applying both adjustments makes
    // extended mode exactly one status-bar too tall (causing the last paragraph to be clipped).
    this.readerPageContentTopPaddingSnapshot = nextTopPadding;
  }

  scheduleReaderExtendLayoutRefresh(readingOffset: number = -1): void {
    if (readingOffset >= 0 && this.readerExtendLayoutReadingOffset < 0) {
      this.readerExtendLayoutReadingOffset = readingOffset;
    }
    this.enterReaderImmersive();
    this.syncReaderPageHeightForContentTopPadding();
    if (this.readerEntryInitializing || !this.content || !this.hasPagedReaderArea()) return;

    // A system-bar mode change rebuilds the safe-area geometry asynchronously. Stop and invalidate
    // every old curl surface immediately; otherwise a gesture started before the new area arrives can
    // combine the old wallpaper snapshot with the new text viewport for one visibly jumping frame.
    this.finishPageTurnAnimation(false);
    this.readerPaginationWorkSerial++;
    this.adjacentPaginationPreloadSerial++;
    this.readerPaginationCache.clear();
    this.pageTurnPreviewKey = '';
    this.pageTurnPreviewLoadingKey = '';
    this.refreshReaderTextRender();

    if (this.readerExtendLayoutRefreshTimerId >= 0) {
      clearTimeout(this.readerExtendLayoutRefreshTimerId);
    }
    this.readerExtendLayoutRefreshTimerId = setTimeout(() => {
      this.readerExtendLayoutRefreshTimerId = -1;
      if (!this.readerPageVisible || !this.content) {
        this.readerExtendLayoutReadingOffset = -1;
        return;
      }
      const restoreOffset = this.readerExtendLayoutReadingOffset >= 0 ?
        this.readerExtendLayoutReadingOffset : this.getCurrentPageStartOffset();
      this.readerExtendLayoutReadingOffset = -1;
      this.readerPaginationCache.clear();
      this.paginateContent(this.content);
      this.currentPageIndex = this.normalizeReaderSpreadPageIndex(this.findPageIndexByOffset(restoreOffset));
      this.syncCurrentPageText();
      this.preloadNextChapterPaginationLater();
      this.saveReadingProgress();
    }, 80);
  }

  onReaderThemeChanged(): void {
    this.hdsMaterialRenderBranch = !this.hdsMaterialRenderBranch;
    this.enterReaderImmersive();
    this.readerPaginationCache.clear();
    this.pageTurnPreviewKey = '';
    this.refreshReaderTextRender();
    this.paginateContent(this.content);
    this.saveReadingProgress();
    this.onTtsCoverSettingsChanged();
  }

  onReaderColorModeChanged(): void {
    // 明暗切换只改变配色和背景，不重新执行整章文本测量与分页。
    // 自定义主题若同时改变字体或排版，会通过 themeRevision / 阅读设置的监听单独触发重排。
    this.hdsMaterialRenderBranch = !this.hdsMaterialRenderBranch;
    this.enterReaderImmersive();
    this.refreshReaderTextRender();
    if (this.showReaderCommentPanel) {
      this.syncReaderCommentPanelWebTheme();
    }
    this.onTtsCoverSettingsChanged();
  }

  onTtsCoverSettingsChanged(): void {
    if (!this.isTtsSpeaking && !this.ttsReader.isSpeaking() && !this.ttsAvSession) {
      this.refreshTtsMediaImage().catch((e: Error) => {
        console.warn('刷新朗读媒体封面失败:', e);
      });
      return;
    }
    this.refreshTtsMediaImage().then(() => {
      return this.updateTtsAvSessionPlaybackState(
        this.isTtsSpeaking || this.ttsReader.isSpeaking() ?
          this.ttsAvPlaybackState() : avSession.PlaybackState.PLAYBACK_STATE_STOP
      );
    }).catch((e: Error) => {
      console.warn('同步朗读媒体封面失败:', e);
    });
  }

  onReaderVolumeTurnPageChanged(): void {
    this.updateVolumeKeySubscription();
    this.saveReadConfig();
  }

  onReaderPageTurnAnimationChanged(): void {
    this.resetSlidePageEffect();
    this.saveReadConfig();
  }

  onReaderPreloadChanged(): void {
    this.preloadReaderContentLater();
    this.saveReadConfig();
  }

  updateVolumeKeySubscription(): void {
    this.unregisterVolumeKeyTurn();
    if (!this.readerVolumeTurnPage || !this.readerPageVisible || this.isTtsSpeaking ||
      this.ttsReader.isSpeaking() || ReaderTtsFloatingSession.isActive()) {
      return;
    }
    this.registerVolumeKeyTurn();
  }

  registerVolumeKeyTurn(): void {
    this.volumeUpCallback = (_event: KeyEvent) => {
      this.handleVolumeKeyTurn(-1);
    };
    this.volumeDownCallback = (_event: KeyEvent) => {
      this.handleVolumeKeyTurn(1);
    };
    try {
      inputConsumer.on('keyPressed', {
        key: KeyCode.KEYCODE_VOLUME_UP,
        action: Action.DOWN,
        isRepeat: false
      }, this.volumeUpCallback);
      inputConsumer.on('keyPressed', {
        key: KeyCode.KEYCODE_VOLUME_DOWN,
        action: Action.DOWN,
        isRepeat: false
      }, this.volumeDownCallback);
    } catch (err) {
      console.error('注册音量键翻页失败:', err);
      this.volumeUpCallback = undefined;
      this.volumeDownCallback = undefined;
    }
  }

  unregisterVolumeKeyTurn(): void {
    try {
      if (this.volumeUpCallback) {
        inputConsumer.off('keyPressed', this.volumeUpCallback);
      }
      if (this.volumeDownCallback) {
        inputConsumer.off('keyPressed', this.volumeDownCallback);
      }
    } catch (err) {
      console.error('取消音量键翻页失败:', err);
    }
    this.volumeUpCallback = undefined;
    this.volumeDownCallback = undefined;
  }

  handleVolumeKeyTurn(direction: number): void {
    if (!this.readerVolumeTurnPage || !this.readerPageVisible || this.isTtsSpeaking ||
      this.ttsReader.isSpeaking() || ReaderTtsFloatingSession.isActive() || this.showMenu || this.showToc ||
      this.showSettings || this.isLoading || this.chapters.length === 0) {
      return;
    }
    if (this.isReaderContinuousScrollSurfaceActive()) {
      this.scrollReaderComicByPage(direction);
      return;
    }
    if (direction > 0) {
      this.turnNext();
    } else {
      this.turnPrev();
    }
  }

  clampChapterIndex(index: number): number {
    if (this.chapters.length === 0) return 0;
    return Math.max(0, Math.min(index, this.chapters.length - 1));
  }

  getMenuChapterDisplayIndex(): number {
    return this.menuChapterSliderActive ? this.menuChapterPreviewIndex : this.currentChapterIndex;
  }

  handleMenuChapterSliderChange(value: number, mode: SliderChangeMode): void {
    this.menuChapterPreviewIndex = this.clampChapterIndex(Math.round(value));
    this.menuChapterSliderActive = true;
    this.menuChapterTooltipVisible = mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving;
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      this.menuChapterTooltipVisible = false;
      this.confirmMenuChapterJump(this.menuChapterPreviewIndex);
    }
  }

  async confirmMenuChapterJump(targetIndex: number): Promise<void> {
    if (this.menuChapterConfirming) {
      return;
    }
    const normalizedIndex = this.clampChapterIndex(targetIndex);
    if (normalizedIndex === this.currentChapterIndex) {
      this.resetMenuChapterPreview();
      return;
    }
    this.menuChapterConfirming = true;
    try {
      const result = await promptAction.showDialog({
        title: '确认跳转章节',
        message: `是否跳转到「${this.getChapterTitle(normalizedIndex)}」？`,
        buttons: [
          { text: '取消', color: this.getSubTextColor() },
          { text: '跳转', color: this.accentColor() }
        ]
      });
      if (result.index === 1) {
        await this.jumpToMenuChapter(normalizedIndex);
      } else {
        this.resetMenuChapterPreview();
      }
    } catch (error) {
      console.error('确认跳转章节失败:', error);
      this.resetMenuChapterPreview();
    } finally {
      this.menuChapterConfirming = false;
    }
  }

  resetMenuChapterPreview(): void {
    this.menuChapterPreviewIndex = this.currentChapterIndex;
    this.menuChapterSliderActive = false;
    this.menuChapterTooltipVisible = false;
  }

  async jumpToMenuChapter(targetIndex: number): Promise<void> {
    const normalizedIndex = this.clampChapterIndex(targetIndex);
    if (normalizedIndex === this.currentChapterIndex) {
      this.menuChapterPreviewIndex = this.currentChapterIndex;
      this.menuChapterSliderActive = false;
      this.menuChapterTooltipVisible = false;
      return;
    }
    try {
      await this.jumpToReaderPositionKeepingTts(normalizedIndex, 0);
    } finally {
      this.menuChapterPreviewIndex = this.currentChapterIndex;
      this.menuChapterSliderActive = false;
      this.menuChapterTooltipVisible = false;
    }
  }

  async jumpToAdjacentChapterFromMenu(direction: number): Promise<void> {
    await this.jumpToAdjacentChapterFirstPage(direction);
    this.menuChapterPreviewIndex = this.currentChapterIndex;
    this.menuChapterSliderActive = false;
    this.menuChapterTooltipVisible = false;
  }

  restorePendingPageIndex(paginationComplete: boolean = true): void {
    if (this.pendingRestorePageIndex < 0) {
      return;
    }
    const maxPage = Math.max(0, this.contentPages.length - 1);
    if (!paginationComplete && this.pendingRestorePageIndex > maxPage) {
      return;
    }
    this.currentPageIndex = this.normalizeReaderSpreadPageIndex(
      Math.max(0, Math.min(this.pendingRestorePageIndex, maxPage))
    );
    this.pendingRestorePageIndex = -1;
  }

  canSaveReadingProgress(): boolean {
    if (this.isLoading || this.isPagedReaderAwaitingPagination() || this.pendingRestorePageIndex >= 0) {
      return false;
    }
    return this.pageViewWidth > 0 && this.pageViewHeight > 0 && this.contentPages.length > 0;
  }

  @Builder
  changeSourceDialog() {
    Column() {
      Column() {
        Row() {
          Text('选择新书源')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.getTextColor())
            .layoutWeight(1)

          Row({ space: 6 }) {
            if (this.isChangingSource) {
              Stack({ alignContent: Alignment.Center }) {
                LoadingProgress()
                  .width(24)
                  .height(24)
              }
              .width(40)
              .height(40)
              .accessibilityText('正在刷新书源')
            } else {
              ImmersiveBackButton({
                icon: $r('sys.symbol.arrow_clockwise'),
                iconOffsetX: 0,
                iconColor: this.getTextColor(),
                darkMode: this.isReaderThemeDark(),
                buttonSize: 40,
                containerWidth: 40,
                containerHeight: 40,
                startInset: 0,
                materialScale: 0.83,
                compactLayout: true,
                accessibilityLabel: '刷新书源',
                onBack: () => {
                  this.refreshChangeSourceResults();
                }
              })
            }

            ImmersiveBackButton({
              icon: $r('sys.symbol.xmark'),
              iconOffsetX: 0,
              iconColor: this.getTextColor(),
              darkMode: this.isReaderThemeDark(),
              buttonSize: 40,
              containerWidth: 40,
              containerHeight: 40,
              startInset: 0,
              materialScale: 0.83,
              compactLayout: true,
              accessibilityLabel: '关闭换源',
              onBack: () => this.closeChangeSourceDialog()
            })
          }
          .height(40)
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(this.changeSourceStatus || '将使用当前书名进行全词匹配搜索')
          .fontSize(13)
          .fontColor(this.getSubTextColor())
          .width('100%')
          .margin({ top: 6, bottom: 10 })

        if (this.isChangingSource && this.changeSourceResults.length === 0) {
          Column() {
            LoadingProgress()
              .width(36)
              .height(36)
            Text('正在搜索可用书源...')
              .fontSize(13)
              .fontColor(this.getSubTextColor())
              .margin({ top: 8 })
          }
          .width('100%')
          .height(220)
          .justifyContent(FlexAlign.Center)
        } else if (this.changeSourceResults.length === 0) {
          Column() {
            Text('暂无可切换书源')
              .fontSize(15)
              .fontColor(this.getSubTextColor())
          }
          .width('100%')
          .height(220)
          .justifyContent(FlexAlign.Center)
        } else {
           List({ space: 8 }) {
            ForEach(this.changeSourceResults, (book: SearchBook) => {
              ListItem() {
                Row() {
                  Column() {
                    Text(book.originName || book.origin)
                      .fontSize(15)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(this.getTextColor())
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })

                    Text(`${book.author || '作者未知'} ${book.latestChapterTitle || ''}`)
                      .fontSize(12)
                      .fontColor(this.getSubTextColor())
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 4 })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  Button('切换')
                    .width(64)
                    .height(32)
                    .fontSize(13)
                    .borderRadius(16)
                    .backgroundColor(this.buttonColor())
                    .fontColor('#FFFFFF')
                    .enabled(!this.isSwitchingSource)
                    .onClick(() => {
                      this.switchToSearchBook(book);
                    })
                }
                .width('100%')
                .padding(12)
                .backgroundColor(this.readerSolidPanelColor())
                .borderRadius(8)
                .onClick(() => {
                  this.switchToSearchBook(book);
                })
              }
            }, (book: SearchBook) => `${book.origin}|${book.bookUrl}`)

            if (this.isChangingSource) {
              ListItem() {
                Row() {
                  LoadingProgress()
                    .width(20)
                    .height(20)
                  Text('继续加载中...')
                    .fontSize(13)
                    .fontColor(this.getSubTextColor())
                    .margin({ left: 8 })
                }
                .width('100%')
                .height(42)
                .justifyContent(FlexAlign.Center)
              }
            }
          }
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .width('100%')
          .height(320)
        }
      }
      .width('90%')
      .padding(20)
      .borderRadius(ThemeRuntime.glassCornerRadius(12, 'panel'))
      .clip(true)
      .backgroundColor(this.readerGlassPanelColor())
      .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
      .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: this.readerGlassBorderColor() })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: this.readerGlassShadowColor(), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
  }

  async openChangeSourceDialog(): Promise<void> {
    if (!this.book || !this.book.name) {
      promptAction.showToast({ message: '当前书籍信息不完整' });
      return;
    }
    this.cancelActiveChangeSourceSearch();
    const sessionId = ++this.changeSourceSessionId;
    this.showChangeSourceDialog = true;
    this.showMenu = false;
    this.showToc = false;
    this.showSettings = false;
    this.changeSourceResults = [];
    this.changeSourceStatus = '正在读取历史换源结果...';
    this.isChangingSource = true;
    this.isSwitchingSource = false;
    try {
      const cachedResults = await ChangeSourceResultCache.load(getContext(this), this.book.name, this.book.author);
      if (!this.isChangeSourceSessionActive(sessionId) || !this.book) {
        return;
      }
      this.changeSourceResults = this.filterChangeSourceResults(
        cachedResults, this.book.bookUrl, this.book.origin
      );
      if (this.changeSourceResults.length > 0) {
        this.isChangingSource = false;
        this.changeSourceStatus = `已显示历史结果，共 ${this.changeSourceResults.length} 个；点击刷新可重新搜索`;
        return;
      }
    } catch (e) {
      console.warn('读取换源历史结果失败:', e);
    }
    if (this.isChangeSourceSessionActive(sessionId)) {
      this.searchChangeSource(sessionId);
    }
  }

  refreshChangeSourceResults(): void {
    if (!this.book || this.isSwitchingSource) {
      return;
    }
    this.cancelActiveChangeSourceSearch();
    const sessionId = ++this.changeSourceSessionId;
    this.changeSourceStatus = '正在刷新可用书源...';
    this.isChangingSource = true;
    this.searchChangeSource(sessionId);
  }

  closeChangeSourceDialog(): void {
    this.changeSourceSessionId++;
    this.cancelActiveChangeSourceSearch();
    this.showChangeSourceDialog = false;
    this.changeSourceResults = [];
    this.changeSourceStatus = '';
    this.isChangingSource = false;
    this.isSwitchingSource = false;
  }

  async searchChangeSource(sessionId: number): Promise<void> {
    if (!this.book) {
      return;
    }
    const cacheBookName = this.book.name;
    this.isChangingSource = true;
    this.changeSourceStatus = '正在搜索可用书源...';
    const coordinator = new SearchCoordinator(Math.min(2, SearchExploreSettingsStore.getSearchConcurrency()));
    this.activeChangeSourceCoordinator = coordinator;
    try {
      const currentBookUrl = this.book.bookUrl;
      const currentOrigin = this.book.origin;
      const results = await coordinator.search(this.book.name, (progress: SearchProgress) => {
        if (!this.isChangeSourceSessionActive(sessionId)) {
          return;
        }
        if (progress.finished) {
          this.changeSourceResults = this.filterChangeSourceResults(progress.results, currentBookUrl, currentOrigin);
        } else if (progress.deltaResults && progress.deltaResults.length > 0) {
          this.changeSourceResults = this.filterChangeSourceResults(
            this.changeSourceResults.concat(progress.deltaResults),
            currentBookUrl,
            currentOrigin
          );
        }
        this.changeSourceStatus = progress.status;
        if (progress.finished) {
          this.isChangingSource = false;
        }
      }, {
        exactMatch: true,
        leanResult: true,
        excludeSourceUrls: [currentOrigin],
        maxResultsPerSource: 1,
        maxTotalResults: 60,
        stopAfterResults: 20,
        maxCandidatesPerSource: 32
      });
      if (!this.isChangeSourceSessionActive(sessionId)) {
        return;
      }
      this.changeSourceResults = this.filterChangeSourceResults(results, currentBookUrl, currentOrigin);
      this.changeSourceStatus = this.changeSourceResults.length > 0 ?
        `搜索完成，找到 ${this.changeSourceResults.length} 个可切换书源` : '搜索完成，未找到可切换书源';
      try {
        // 缓存完整搜索结果；展示时再排除当前书源，确保切换后仍可换回原书源。
        await ChangeSourceResultCache.save(getContext(this), cacheBookName, results, this.book?.author || '');
      } catch (e) {
        console.warn('保存换源结果缓存失败:', e);
      }
    } catch (e) {
      if (!this.isChangeSourceSessionActive(sessionId)) {
        return;
      }
      console.error('搜索换源失败:', e);
      this.changeSourceStatus = '搜索换源失败';
    } finally {
      if (this.activeChangeSourceCoordinator === coordinator) {
        this.activeChangeSourceCoordinator = null;
      }
      if (this.isChangeSourceSessionActive(sessionId)) {
        this.isChangingSource = false;
      }
    }
  }

  isChangeSourceSessionActive(sessionId: number): boolean {
    return this.showChangeSourceDialog && sessionId === this.changeSourceSessionId;
  }

  cancelActiveChangeSourceSearch(): void {
    if (this.activeChangeSourceCoordinator) {
      this.activeChangeSourceCoordinator.cancel();
      this.activeChangeSourceCoordinator = null;
    }
  }

  filterChangeSourceResults(results: SearchBook[], currentBookUrl: string, currentOrigin: string): SearchBook[] {
    const filtered: SearchBook[] = [];
    const seen = new Set<string>();
    for (const result of results) {
      if (!result.bookUrl || (result.bookUrl === currentBookUrl && result.origin === currentOrigin)) {
        continue;
      }
      const key = `${result.origin || ''}\n${result.bookUrl}`;
      if (seen.has(key)) continue;
      seen.add(key);
      filtered.push(result);
    }
    return filtered;
  }

  async switchToSearchBook(searchBook: SearchBook): Promise<void> {
    if (!this.book || this.isSwitchingSource) {
      return;
    }
    this.cancelActiveChangeSourceSearch();
    this.isChangingSource = false;
    const sessionId = ++this.changeSourceSessionId;
    this.isSwitchingSource = true;
    this.changeSourceStatus = '正在切换书源...';
    await this.saveReadingProgress();
    const oldBook = this.book;
    const oldBookUrl = oldBook.bookUrl;
    const chapterIndex = this.clampChapterIndex(this.currentChapterIndex);
    const pageIndex = Math.max(0, this.currentPageIndex);
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      const source = searchBook.origin ? await db.getBookSource(searchBook.origin) : null;
      if (!source) {
        promptAction.showToast({ message: '书源不存在或已删除' });
        return;
      }
      if (!this.isChangeSourceSessionActive(sessionId)) {
        return;
      }

      const nextBook = this.buildBookFromSearchResult(searchBook, oldBook, chapterIndex, pageIndex);
      const service = new WebBookService();
      const fullBook = await service.getBookInfo(source, nextBook);
      if (!this.isChangeSourceSessionActive(sessionId)) {
        return;
      }
      this.preserveSwitchBookState(fullBook, nextBook, oldBook, chapterIndex, pageIndex);
      const chapters = await service.getChapterList(source, fullBook);
      if (!this.isChangeSourceSessionActive(sessionId)) {
        return;
      }
      if (chapters.length === 0) throw new Error('新书源目录为空，已保留原书源');
      fullBook.totalChapterNum = chapters.length;
      if (chapters.length > 0) {
        const safeIndex = Math.max(0, Math.min(chapterIndex, chapters.length - 1));
        fullBook.durChapterIndex = safeIndex;
        fullBook.durChapterTitle = chapters[safeIndex].title;
        fullBook.latestChapterTitle = chapters[chapters.length - 1].title;
      }

      await db.commitBookSourceSwitch(oldBookUrl, fullBook, chapters);

      AppStorage.setOrCreate('shelfUpdateTime', Date.now());
      this.bookUrl = fullBook.bookUrl;
      this.book = fullBook;
      this.closeChangeSourceDialog();
      promptAction.showToast({ message: `已切换至 ${fullBook.originName || searchBook.originName}` });
      await this.loadBook();
      await this.loadBookmarks();
    } catch (e) {
      if (!this.isChangeSourceSessionActive(sessionId)) {
        return;
      }
      console.error('切换书源失败:', e);
      promptAction.showToast({ message: '切换书源失败' });
    } finally {
      if (sessionId === this.changeSourceSessionId) {
        this.isSwitchingSource = false;
      }
    }
  }

  buildBookFromSearchResult(searchBook: SearchBook, oldBook: Book, chapterIndex: number, pageIndex: number): Book {
    const book = new Book();
    book.bookUrl = searchBook.bookUrl;
    book.tocUrl = searchBook.tocUrl;
    book.origin = searchBook.origin;
    book.originName = searchBook.originName;
    book.name = searchBook.name || oldBook.name;
    book.author = searchBook.author || oldBook.author;
    book.kind = BookFieldSanitizer.prefer(searchBook.kind, oldBook.kind);
    book.coverUrl = CoverUrlNormalizer.prefer(searchBook.coverUrl, oldBook.coverUrl);
    book.customCoverUrl = oldBook.customCoverUrl;
    book.intro = BookFieldSanitizer.prefer(searchBook.intro, oldBook.intro);
    book.customIntro = oldBook.customIntro;
    book.latestChapterTitle = BookFieldSanitizer.prefer(searchBook.latestChapterTitle, oldBook.latestChapterTitle);
    book.wordCount = BookFieldSanitizer.prefer(searchBook.wordCount, oldBook.wordCount);
    book.variable = searchBook.variable || '';
    book.group = oldBook.group;
    book.order = oldBook.order;
    book.originOrder = oldBook.originOrder;
    book.readConfig = oldBook.readConfig;
    book.canUpdate = oldBook.canUpdate;
    book.durChapterIndex = chapterIndex;
    book.durChapterPos = pageIndex;
    book.durChapterTitle = oldBook.durChapterTitle;
    book.durChapterTime = Date.now();
    book.putVariable('lastReadTime', `${Date.now()}`);
    return book;
  }

  preserveSwitchBookState(target: Book, source: Book, oldBook: Book, chapterIndex: number, pageIndex: number): void {
    target.origin = source.origin;
    target.originName = source.originName;
    target.coverUrl = CoverUrlNormalizer.prefer(source.coverUrl, target.coverUrl);
    target.group = oldBook.group;
    target.order = oldBook.order;
    target.originOrder = oldBook.originOrder;
    target.customCoverUrl = oldBook.customCoverUrl;
    target.customIntro = oldBook.customIntro;
    target.readConfig = oldBook.readConfig;
    target.canUpdate = oldBook.canUpdate;
    target.durChapterIndex = chapterIndex;
    target.durChapterPos = pageIndex;
    target.durChapterTitle = oldBook.durChapterTitle;
    target.durChapterTime = Date.now();
    target.syncTime = oldBook.syncTime;
    target.putVariable('lastReadTime', `${Date.now()}`);
  }

  async saveReadingProgress(notifyShelf: boolean = false): Promise<void> {
    if (!this.book || this.chapters.length === 0) {
      return;
    }
    if (!this.canSaveReadingProgress()) {
      return;
    }
    const engine = ReadBookEngine.get();
    const chapterIndex = this.clampChapterIndex(this.currentChapterIndex);
    const pageIndex = Math.max(0, Math.min(this.currentPageIndex, Math.max(0, this.contentPages.length - 1)));
    if (!Book.hasStartedReading(this.book) && chapterIndex <= 0 && pageIndex <= 0) {
      engine.curIdx = chapterIndex;
      engine.curPos = pageIndex;
      return;
    }
    this.currentChapterIndex = chapterIndex;
    this.currentPageIndex = pageIndex;
    this.book.durChapterIndex = chapterIndex;
    this.book.durChapterPos = pageIndex;
    const now = Date.now();
    this.book.durChapterTitle = this.getChapterTitle();
    this.book.durChapterTime = now;
    this.book.putVariable('readStarted', '1');
    this.book.putVariable('lastReadTime', `${now}`);
    this.book.putVariable('readProgressChapterIndex', `${chapterIndex}`);
    this.book.putVariable('readProgressPageCount', `${this.currentChapterProgressPageCount()}`);
    this.book.putVariable('lastReadPageText', this.getShelfLastReadPageText(pageIndex));
    this.book.putVariable('lastReadPageImage', this.getShelfLastReadPageImage(pageIndex));
    engine.curIdx = chapterIndex;
    engine.curPos = pageIndex;
    engine.book = this.book;
    const bookUrl = this.book.bookUrl;
    const chapterTitle = this.book.durChapterTitle;
    const variable = this.book.variable;
    const syncRelevant = !!this.book.origin && this.book.origin !== 'local';
    const shouldRefreshRecentCard = chapterIndex !== this.lastRecentReadCardChapterIndex;
    this.lastRecentReadCardChapterIndex = chapterIndex;
    const previous = this.readingProgressSaveQueue.catch(() => {
    });
    const next = previous.then(async () => {
      const db = AppDatabase.getInstance();
      await db.updateBookReadingProgress(
        bookUrl, chapterTitle, chapterIndex, pageIndex, now, variable, syncRelevant);
      // Page turns are saved frequently, while the retained bookshelf page is still alive underneath the reader.
      // Publishing shelfUpdateTime here would rebuild every hidden shelf card and decode all theme cover fallbacks on
      // every turn. Persist the progress immediately, but notify the shelf only when leaving the reader.
      if (notifyShelf) AppStorage.setOrCreate('shelfUpdateTime', Date.now());
      if (notifyShelf || shouldRefreshRecentCard) {
        this.reloadRecentReadCardLater(shouldRefreshRecentCard);
      }
    });
    this.readingProgressSaveQueue = next;
    try {
      await next;
    } catch (e) {
      console.error('保存阅读进度失败:', e);
    }
  }

  async markBookRecentlyRead() {
    if (!this.book) {
      return;
    }
    const now = Date.now();
    this.book.durChapterTime = now;
    this.book.putVariable('readStarted', '1');
    this.book.putVariable('lastReadTime', `${now}`);
    try {
      const db = AppDatabase.getInstance();
      await db.updateBook(this.book, false);
      AppStorage.setOrCreate('shelfUpdateTime', Date.now());
      this.lastRecentReadCardChapterIndex = this.currentChapterIndex;
      this.reloadRecentReadCardLater(true);
    } catch (e) {
      console.error('更新最近阅读时间失败:', e);
    }
  }

  reloadRecentReadCardLater(force: boolean = false): void {
    const now = Date.now();
    if (!force && now - this.lastRecentReadCardReloadAt < 30000) {
      return;
    }
    this.lastRecentReadCardReloadAt = now;
    const context = getContext(this) as common.UIAbilityContext;
    setTimeout(() => {
      RecentReadCardUpdater.reload(context).catch((err: Error) => {
        console.error('刷新最近阅读卡片失败:', err);
      });
    }, 0);
  }

  async saveReadConfig() {
    if (!this.book) return;
    this.book.setPageAnim(this.currentReaderThemeIndex());
    try {
      const db = AppDatabase.getInstance();
      await db.updateBook(this.book);
    } catch (e) {
      console.error('保存阅读设置失败:', e);
    }
  }

  @Builder
  readerBottomInfoBar() {
    Row() {
      Text(this.getChapterInfoText())
        .fontSize(12)
        .fontColor(this.getSubTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Text(this.getPageInfoText())
        .fontSize(12)
        .fontColor(this.getSubTextColor())
        .textAlign(TextAlign.End)
        .margin({ left: 12 })
    }
    .width('100%')
    .height(this.getReaderBottomInfoBarHeight())
    .padding({ left: 18, right: 18, top: 0, bottom: 0 })
    .alignItems(VerticalAlign.Top)
    .backgroundColor(Color.Transparent)
    .translate({ y: this.getReaderBottomInfoBarVisualOffsetY() })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  currentChapterProgressPageCount(): number {
    if (this.contentPages.length === 0) {
      return 0;
    }
    if (this.hasPagedReaderArea() && this.pagedContentText) {
      const pagination = this.getCachedReaderPagination(this.currentChapterIndex, this.pagedContentText);
      if (pagination && !pagination.complete) {
        // 增量分页尚未完成时，总页数并不可靠；下一次翻页或离开页面时会重新保存。
        return 0;
      }
    }
    return this.contentPages.length;
  }

  getShelfLastReadPageText(pageIndex: number): string {
    const pageText = ReaderActionMarker.strip(
      LocalBookService.stripEpubImageMarkers(this.getPageText(pageIndex) || '', false), false
    )
      .replace(/\r\n?/g, '\n')
      .replace(/[ \t]+\n/g, '\n')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
    return (pageText || '（图片页）').substring(0, 1600);
  }

  getShelfLastReadPageImage(pageIndex: number): string {
    const page = (this.getPageText(pageIndex) || '').trim();
    return this.isReaderImageOnlyPage(page) ? this.getReaderEpubImageUri(page) : '';
  }

  onReaderLandscapeDoublePageChanged(): void {
    const readingOffset = this.getCurrentPageStartOffset();
    this.finishPageTurnAnimation();
    this.readerPaginationCache.clear();
    this.paginateContent(this.content);
    this.currentPageIndex = this.normalizeReaderSpreadPageIndex(this.findPageIndexByOffset(readingOffset));
    this.syncCurrentPageText();
    this.refreshReaderTextRender();
    this.saveReadingProgress();
    this.saveReadConfig();
  }

  @Builder
  ttsExpandedMediaControlsBar() {
    HdsTabs({ barPosition: BarPosition.End, index: 0 }) {
      TabContent() {
        Column()
      }
      .height(48)
      .tabBar(this.ttsMediaTimerControl())

      TabContent() {
        Column()
      }
      .height(48)
      .tabBar(this.ttsMediaSymbolControl($r('sys.symbol.arrow_left'),
        this.canPlayPreviousTtsChapter(), '上一章'))

      TabContent() {
        Column()
      }
      .height(48)
      .tabBar(this.ttsMediaSymbolControl(this.isTtsSpeaking && !this.isTtsPaused ?
        $r('sys.symbol.pause') : $r('sys.symbol.play'), true,
        this.isTtsSpeaking && !this.isTtsPaused ? '暂停朗读' : '播放朗读'))

      TabContent() {
        Column()
      }
      .height(48)
      .tabBar(this.ttsMediaSymbolControl($r('sys.symbol.arrow_right'),
        this.canPlayNextTtsChapter(), '下一章'))

      TabContent() {
        Column()
      }
      .height(48)
      .tabBar(this.ttsMediaSpeedControl())

      TabContent() {
        Column()
      }
      .height(48)
      .tabBar(this.ttsMediaSymbolControl($r('sys.symbol.xmark'), true, '关闭朗读控制'))
    }
    .key(`reader_tts_controls_bar_${this.themeRevision}_${this.isReaderThemeDark() ? 'dark' : 'light'}`)
    .barBackgroundColor(this.readerGlassPanelColor())
    .barMode(BarMode.Fixed)
    .barHeight(48)
    .barOverlap(true)
    .barFloatingStyle({
      barWidth: {
        smallWidth: this.readerTtsExpandedControlWidth(),
        mediumWidth: this.readerTtsExpandedControlWidth(),
        largeWidth: this.readerTtsExpandedControlWidth()
      },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      },
      barSideMargin: 0,
      barBottomMargin: 4,
      gradientMask: {
        maskColor: '#00000000',
        maskHeight: 56
      },
      adaptToHandedness: false,
      thermoCtrl: true,
      barOpacity: 1
    })
    .scrollable(false)
    .onContentWillChange(() => false)
    .onTabBarClick((index: number) => {
      this.handleTtsExpandedControl(index);
    })
    .width(this.readerTtsExpandedControlWidth())
    .height(56)
    .position({ x: this.readerTtsExpandedControlLeft(), y: '100%' })
    .translate({
      y: -(this.readerBottomMenuOverlayHeight() + 66)
    })
  }

  @Builder
  ttsMediaTimerControl() {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph($r('sys.symbol.timer'))
        .fontSize(22)
        .fontColor([this.getTextColor()])

      if (this.ttsSleepTimerMinutes > 0) {
        Text(`${Math.max(1, Math.ceil(this.ttsSleepTimerRemainingSeconds / 60))}`)
          .fontSize(8)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .width(16)
          .height(16)
          .borderRadius(8)
          .backgroundColor(this.accentColor())
          .position({ x: 25, y: 2 })
      }
    }
    .width('100%')
    .height(48)
    .accessibilityText(this.ttsSleepTimerMinutes > 0 ?
      `朗读定时剩余 ${Math.max(1, Math.ceil(this.ttsSleepTimerRemainingSeconds / 60))} 分钟` : '设置朗读定时')
    .translate({ y: -2 })
  }

  @Builder
  ttsMediaSymbolControl(icon: Resource, enabled: boolean, accessibilityLabel: string) {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([enabled ? this.getTextColor() : this.getSubTextColor()])
    }
    .width('100%')
    .height(48)
    .opacity(enabled ? 1 : 0.45)
    .accessibilityText(accessibilityLabel)
    .translate({ y: -2 })
  }

  @Builder
  ttsMediaSpeedControl() {
    Text(`${this.ttsSpeed.toFixed(1)}x`)
      .fontSize(13)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.getTextColor())
      .textAlign(TextAlign.Center)
      .width('100%')
      .height(48)
      .translate({ y: -2 })
  }

  readerTtsExpandedControlWidth(): number {
    return 264;
  }

  handleTtsExpandedControl(index: number): void {
    if (index === 0) {
      this.cycleTtsSleepTimer();
    } else if (index === 1 && this.canPlayPreviousTtsChapter()) {
      this.playPreviousChapterFromMediaSession();
    } else if (index === 2) {
      this.toggleTtsReading();
      this.showMenu = true;
    } else if (index === 3 && this.canPlayNextTtsChapter()) {
      this.playNextChapterFromMediaSession();
    } else if (index === 4) {
      this.cycleTtsSpeed();
    } else if (index === 5) {
      this.ttsMediaControlsExpanded = false;
      this.showMenu = true;
      this.syncTtsSystemMediaControls();
    }
  }

  cycleTtsSleepTimer(): void {
    const options: number[] = [0, 15, 30, 60, 90, 120];
    const currentIndex = options.indexOf(this.ttsSleepTimerMinutes);
    const nextMinutes = options[(currentIndex + 1) % options.length];
    this.setTtsSleepTimer(nextMinutes);
  }

  setTtsSleepTimer(minutes: number): void {
    this.clearTtsSleepTimer();
    if (minutes <= 0) {
      promptAction.showToast({ message: '已关闭朗读定时' });
      return;
    }
    this.ttsSleepTimerMinutes = minutes;
    this.ttsSleepTimerRemainingSeconds = minutes * 60;
    this.updateTtsFloatingSession();
    this.ttsSleepTimerEndAt = Date.now() + minutes * 60 * 1000;
    this.ttsSleepTimerId = setInterval(() => {
      const remaining = Math.max(0, Math.ceil((this.ttsSleepTimerEndAt - Date.now()) / 1000));
      this.ttsSleepTimerRemainingSeconds = remaining;
      ReaderTtsFloatingSession.updateTimer(
        this.ttsFloatingSessionOwnerId, this.ttsSleepTimerMinutes, remaining);
      if (remaining <= 0) {
        this.clearTtsSleepTimer();
        this.stopTtsReading();
        promptAction.showToast({ message: '朗读定时结束，已停止朗读' });
      }
    }, 1000);
    promptAction.showToast({ message: `将在 ${minutes} 分钟后停止朗读` });
  }

  clearTtsSleepTimer(): void {
    if (this.ttsSleepTimerId >= 0) {
      clearInterval(this.ttsSleepTimerId);
      this.ttsSleepTimerId = -1;
    }
    this.ttsSleepTimerEndAt = 0;
    this.ttsSleepTimerMinutes = 0;
    this.ttsSleepTimerRemainingSeconds = 0;
    this.updateTtsFloatingSession();
  }

  cycleTtsSpeed(): void {
    const speeds: number[] = [0.8, 1.0, 1.2, 1.5, 2.0];
    let nextIndex = speeds.findIndex((speed: number) => speed > this.ttsSpeed + 0.01);
    if (nextIndex < 0) {
      nextIndex = 0;
    }
    this.applyTtsSpeed(speeds[nextIndex]);
    promptAction.showToast({ message: `朗读倍速 ${speeds[nextIndex].toFixed(1)}x` });
  }

  shouldShowTtsMediaControls(): boolean {
    return !this.isReaderComicModeActive() && this.ttsMediaControlsExpanded &&
      (this.isTtsSpeaking || this.ttsReader.isSpeaking()) &&
      this.showMenu && !this.showToc && !this.showSettings && !this.shouldBlockReaderInteraction();
  }

  canPlayPreviousTtsChapter(): boolean {
    return this.chapters.length > 0 && this.currentChapterIndex > 0;
  }

  canPlayNextTtsChapter(): boolean {
    return this.chapters.length > 0 && this.currentChapterIndex < this.chapters.length - 1;
  }

  disabledButtonColor(): string {
    return this.isReaderThemeDark() ? '#44515A66' : '#C8CDD4';
  }

  @Builder
  readerTapLayer() {
    if (this.readerEffectivePageTurnMode() === 2) {
      Column() {
        ForEach([0, 1, 2], (row: number) => {
          Row() {
            ForEach([0, 1, 2], (column: number) => {
              Blank()
                .height('100%')
                .layoutWeight(1)
                .onClick(() => {
                  if (this.consumeSuppressedReaderTapClick()) {
                    return;
                  }
                  this.commitReaderTapZone(row * 3 + column);
                })
            }, (column: number) => `${row}_${column}`)
          }
          .width('100%')
          .layoutWeight(1)
        }, (row: number) => `${row}`)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .onAreaChange((_oldValue: Area, newValue: Area) => this.rememberReaderTapLayerArea(newValue))
      .onTouch((event: TouchEvent) => {
        this.handleReaderTouch(event);
      })
      .parallelGesture(
        GestureGroup(GestureMode.Exclusive,
          PanGesture({ direction: PanDirection.All, distance: this.readerTapSlop })
            .onActionStart((event: GestureEvent) => {
              this.handleReaderPanStart(event);
            })
            .onActionUpdate((event: GestureEvent) => {
              this.handleReaderPanUpdate(event);
            })
            .onActionEnd((event: GestureEvent) => {
              this.handleReaderPanEnd(event);
            })
            .onActionCancel(() => {
              this.handleReaderPanCancel();
            }),
          LongPressGesture({ duration: 600 })
            .onAction((event: GestureEvent) => {
              this.selectReaderTextAtGlobalPoint(event);
            })
        )
      )
    } else if (this.readerEffectivePageTurnMode() === 0) {
      Column() {
        Blank()
          .width('100%')
          .layoutWeight(3)
          .onClick(() => {
            if (this.consumeSuppressedReaderTapClick()) {
              return;
            }
            this.turnPrev();
          })

        Row() {
          Blank()
            .height('100%')
            .layoutWeight(1)
            .onClick(() => {
              if (this.consumeSuppressedReaderTapClick()) {
                return;
              }
              this.turnPrev();
            })
          Blank()
            .height('100%')
            .layoutWeight(1)
            .onClick(() => {
              if (this.consumeSuppressedReaderTapClick()) {
                return;
              }
              this.showMenu = true;
            })
          Blank()
            .height('100%')
            .layoutWeight(1)
            .onClick(() => {
              if (this.consumeSuppressedReaderTapClick()) {
                return;
              }
              this.turnNext();
            })
        }
        .width('100%')
        .layoutWeight(4)

        Blank()
          .width('100%')
          .layoutWeight(3)
          .onClick(() => {
            if (this.consumeSuppressedReaderTapClick()) {
              return;
            }
            this.turnNext();
          })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .onAreaChange((_oldValue: Area, newValue: Area) => this.rememberReaderTapLayerArea(newValue))
      .onTouch((event: TouchEvent) => {
        this.handleReaderTouch(event);
      })
      .parallelGesture(
        GestureGroup(GestureMode.Exclusive,
          PanGesture({ direction: this.isVerticalPageTurnAnimation() ?
            PanDirection.Vertical : PanDirection.Horizontal, distance: this.readerTapSlop })
            .onActionStart((event: GestureEvent) => {
              this.handleReaderPanStart(event);
            })
            .onActionUpdate((event: GestureEvent) => {
              this.handleReaderPanUpdate(event);
            })
            .onActionEnd((event: GestureEvent) => {
              this.handleReaderPanEnd(event);
            })
            .onActionCancel(() => {
              this.handleReaderPanCancel();
            }),
          LongPressGesture({ duration: 600 })
            .onAction((event: GestureEvent) => {
              this.selectReaderTextAtGlobalPoint(event);
            })
        )
      )
    } else {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onAreaChange((_oldValue: Area, newValue: Area) => this.rememberReaderTapLayerArea(newValue))
        .onClick(() => {
          if (this.consumeSuppressedReaderTapClick()) {
            return;
          }
          if (this.readerEffectivePageTurnMode() === 1 && !this.showMenu && !this.showToc && !this.showSettings) {
            this.showMenu = true;
          }
        })
        .onTouch((event: TouchEvent) => {
          this.handleReaderTouch(event);
        })
        .parallelGesture(
          GestureGroup(GestureMode.Exclusive,
            PanGesture({ direction: PanDirection.All, distance: this.readerTapSlop })
              .onActionStart((event: GestureEvent) => {
                this.handleReaderPanStart(event);
              })
              .onActionUpdate((event: GestureEvent) => {
                this.handleReaderPanUpdate(event);
              })
              .onActionEnd((event: GestureEvent) => {
                this.handleReaderPanEnd(event);
              })
              .onActionCancel(() => {
                this.handleReaderPanCancel();
              }),
            LongPressGesture({ duration: 600 })
              .onAction((event: GestureEvent) => {
                this.selectReaderTextAtGlobalPoint(event);
              })
          )
        )
    }
  }

  canHandleReaderPageTurnPan(): boolean {
    return !this.showMenu && !this.showToc && !this.showSettings &&
      this.chapters.length > 0 && !this.isReaderInteractiveActionActive();
  }

  handleReaderPagedContentClick(event: ClickEvent): void {
    if (this.consumeSuppressedReaderTapClick() || this.showMenu || this.showToc || this.showSettings ||
      this.shouldBlockReaderInteraction()) {
      return;
    }
    const x = Number(event.x);
    const y = Number(event.y);
    if (this.readerEffectivePageTurnMode() === 1) {
      this.updateReaderMenuAnchorByPoint(x);
      this.showMenu = true;
      return;
    }
    this.commitReaderTapByPoint(x, y);
  }

  handleReaderPanStart(_event: GestureEvent): void {
    if (this.readerPageTurnGestureCommitted) {
      return;
    }
    if (!this.canHandleReaderPageTurnPan()) {
      return;
    }
    this.readerPanActive = true;
    this.deferReaderPaginationForInteraction();
    this.readerTouchMoved = false;
    this.suppressReaderTapClick = false;
    this.slideResetSerial++;
  }

  canHandleBookmarkPull(offsetX: number, offsetY: number): boolean {
    return this.readerEffectivePageTurnMode() !== 0 &&
      offsetY >= this.readerBookmarkPullStartDistance &&
      offsetY > Math.abs(offsetX) * this.readerBookmarkPullDirectionRatio;
  }

  bookmarkPullCommitDistance(): number {
    const viewportHeight = this.pageViewHeight > 0 ? this.pageViewHeight : 640;
    return Math.max(160, Math.min(220, viewportHeight * 0.24));
  }

  canCommitBookmarkPull(offsetX: number, offsetY: number): boolean {
    return this.readerEffectivePageTurnMode() !== 0 &&
      offsetY >= this.bookmarkPullCommitDistance() &&
      offsetY > Math.abs(offsetX) * this.readerBookmarkPullDirectionRatio;
  }

  updateBookmarkPullEffect(offsetX: number, offsetY: number): void {
    this.bookmarkPullActive = true;
    const effectiveOffset = Math.max(0, offsetY - this.readerBookmarkPullStartDistance);
    this.bookmarkPullOffsetY = Math.min(128, effectiveOffset * 0.65);
    this.bookmarkPullReady = this.canCommitBookmarkPull(offsetX, offsetY);
    this.readerTouchMoved = true;
    this.suppressReaderTapClick = true;
    this.pageSlideOffsetX = 0;
    this.pageSlideOffsetY = 0;
    this.pageSlideDirection = 0;
  }

  finishBookmarkPull(commit: boolean): void {
    const shouldToggle = commit && this.bookmarkPullReady;
    this.bookmarkPullReady = false;
    this.bookmarkPullActive = false;
    animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.bookmarkPullOffsetY = 0;
    });
    if (shouldToggle) {
      this.toggleCurrentPageBookmark();
    }
  }

  handleReaderPanUpdate(event: GestureEvent): void {
    if (this.readerPageTurnGestureCommitted) {
      return;
    }
    if (!this.canHandleReaderPageTurnPan()) {
      return;
    }
    if (!this.readerPanActive) {
      this.handleReaderPanStart(event);
    }
    const offsetX = event.offsetX;
    const offsetY = event.offsetY;
    if (this.isPageTurning) {
      if (this.isReaderTouchMoved(offsetX, offsetY)) {
        this.readerTouchMoved = true;
        this.suppressReaderTapClick = true;
      }
      return;
    }
    if (this.bookmarkPullActive || this.canHandleBookmarkPull(offsetX, offsetY)) {
      this.updateBookmarkPullEffect(offsetX, offsetY);
      return;
    }
    if (!this.isPageTurnAnimationEnabled()) {
      return;
    }
    if (this.isReaderTouchMoved(offsetX, offsetY)) {
      this.readerTouchMoved = true;
      this.suppressReaderTapClick = true;
    }
    this.updateSlidePageEffect(this.getReaderPageTurnGestureOffset(offsetX, offsetY));
  }

  handleReaderPanEnd(event: GestureEvent): void {
    if (!this.readerPanActive) {
      return;
    }
    this.readerPanActive = false;
    this.deferReaderPaginationForInteraction();
    if (this.bookmarkPullActive) {
      this.readerTouchMoved = true;
      this.suppressReaderTapClick = true;
      this.finishBookmarkPull(this.canCommitBookmarkPull(event.offsetX, event.offsetY));
      return;
    }
    const offsetX = event.offsetX;
    const offsetY = event.offsetY;
    if (this.isReaderPageTurnCommitGesture(offsetX, offsetY)) {
      this.readerTouchMoved = true;
      this.suppressReaderTapClick = true;
      const axisVelocity = this.isVerticalPageTurnAnimation() ? event.velocityY : event.velocityX;
      this.commitReaderMove(offsetX, offsetY,
        Number.isFinite(axisVelocity) ? Math.abs(axisVelocity) : 0);
      return;
    }
    if (this.readerTouchMoved || this.isReaderTouchMoved(offsetX, offsetY)) {
      this.suppressReaderTapClick = true;
      this.rollbackSlidePageEffect();
      return;
    }
    this.resetSlidePageEffect();
  }

  handleReaderPanCancel(): void {
    if (!this.readerPanActive) {
      return;
    }
    this.readerPanActive = false;
    this.deferReaderPaginationForInteraction();
    if (this.bookmarkPullActive) {
      this.suppressReaderTapClick = true;
      this.finishBookmarkPull(false);
      return;
    }
    if (Math.abs(this.getPageSlideAxisOffset()) > 0.5) {
      this.suppressReaderTapClick = true;
      this.rollbackSlidePageEffect();
      return;
    }
    this.resetSlidePageEffect();
  }

  handleReaderTouch(event: TouchEvent): void {
    if (this.showMenu || this.showToc || this.showSettings || this.chapters.length === 0) {
      return;
    }
    const point = event.changedTouches && event.changedTouches.length > 0 ? event.changedTouches[0] :
      (event.touches && event.touches.length > 0 ? event.touches[0] : null);
    if (!point) {
      return;
    }
    if (Date.now() < this.readerTextSelectionUntil) {
      this.readerTouchActive = false;
      this.readerPanActive = false;
      this.suppressReaderTapClick = true;
      return;
    }
    const x = point.x;
    const y = point.y;
    const globalX: number = Number(point.x) + this.readerTapLayerGlobalX;
    const globalY: number = Number(point.y) + this.readerTapLayerGlobalY;
    if (event.type === TouchType.Down) {
      this.deferReaderPaginationForInteraction();
      // A fresh pointer stream must not inherit the short click guard from the previous source action.
      this.readerInteractiveActionUntil = 0;
      this.readerTouchActionMarker = '';
      this.readerInlineTouchActionMarker = '';
      this.updateReaderMenuAnchorByPoint(x);
      this.readerTouchStartX = x;
      this.readerTouchStartY = y;
      this.readerTouchLastX = x;
      this.readerTouchLastY = y;
      this.readerTouchActive = true;
      this.readerPageTurnGestureCommitted = false;
      this.readerGestureTurnGuardUntil = 0;
      this.readerGestureTurnAllowance = 0;
      this.readerTouchMoved = false;
      this.suppressReaderTapClick = false;
      this.slideResetSerial++;
      // An explicitly rendered action owns its exact hit region. Page-turn tap zones only run
      // when no action was hit, so justified line-end comments remain accessible near an edge.
      const actionMarker = this.readerSourceActionAtPoint(globalX, globalY);
      if (actionMarker) {
        this.readerTouchActionMarker = actionMarker;
        this.beginReaderInteractiveAction();
        return;
      }
      return;
    }
    const sourceActionTouchActive = !!this.readerTouchActionMarker || !!this.readerInlineTouchActionMarker;
    if (this.isReaderInteractiveActionActive() && !sourceActionTouchActive) {
      this.readerTouchActive = false;
      this.suppressReaderTapClick = true;
      this.resetSlidePageEffect();
      return;
    }
    if (sourceActionTouchActive && event.type === TouchType.Move) {
      this.readerTouchLastX = x;
      this.readerTouchLastY = y;
      const offsetX = x - this.readerTouchStartX;
      const offsetY = y - this.readerTouchStartY;
      if (this.isReaderTouchMoved(offsetX, offsetY)) {
        this.readerTouchActionMarker = '';
        this.readerInlineTouchActionMarker = '';
        this.readerInteractiveActionUntil = 0;
        this.readerTouchActive = true;
        this.readerTouchMoved = true;
        this.suppressReaderTapClick = true;
        if (!this.readerPanActive && this.canHandleReaderPageTurnPan()) {
          this.readerPanActive = true;
          this.slideResetSerial++;
        }
      }
      return;
    }
    if (this.readerTouchActionMarker) {
      if (event.type === TouchType.Up) {
        const marker = this.readerTouchActionMarker;
        this.readerTouchActionMarker = '';
        this.beginReaderInteractiveAction();
        if (this.readerSourceActionAtPoint(globalX, globalY) === marker) {
          this.openReaderSourceAction(marker);
        }
      } else if (event.type === TouchType.Cancel) {
        this.readerTouchActionMarker = '';
      }
      return;
    }
    if (!this.readerTouchActive) {
      return;
    }
    if (event.type === TouchType.Move) {
      this.readerTouchLastX = x;
      this.readerTouchLastY = y;
      const offsetX = x - this.readerTouchStartX;
      const offsetY = y - this.readerTouchStartY;
      if (!this.isPageTurnAnimationEnabled()) {
        return;
      }
      if (this.isReaderTouchMoved(offsetX, offsetY)) {
        this.readerTouchMoved = true;
        this.suppressReaderTapClick = true;
      }
      // PanGesture owns page-turn progress. Drawing from Touch.Move too rendered every
      // physical move twice and let Touch.Up race PanGesture.onActionEnd.
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.readerTouchLastX = x;
      this.readerTouchLastY = y;
      this.readerTouchActive = false;
      this.deferReaderPaginationForInteraction();
      if (this.isPageTurnAnimationEnabled()) {
        return;
      }
      this.finishReaderHorizontalTouch(event.type === TouchType.Up);
    }
  }

  async jumpToReaderPositionKeepingTts(targetChapterIndex: number, targetPageIndex: number): Promise<void> {
    if (this.isMirroringActiveTtsForCurrentBook()) {
      ReaderTtsFloatingSession.jumpToPosition(
        this.clampChapterIndex(targetChapterIndex), Math.max(0, Math.round(targetPageIndex)));
      return;
    }
    const shouldResume = this.isTtsSpeaking || this.ttsReader.isSpeaking();
    if (shouldResume) {
      this.stopTtsReaderForChapterSwitch();
      await this.updateTtsAvSessionPlaybackState(avSession.PlaybackState.PLAYBACK_STATE_BUFFERING);
    }
    this.currentPageIndex = Math.max(0, targetPageIndex);
    this.pendingRestorePageIndex = this.currentPageIndex;
    await this.loadContent(false, this.clampChapterIndex(targetChapterIndex));
    await this.saveReadingProgress();
    if (shouldResume) {
      await this.startTtsReadingFromCurrentPosition(false);
    }
  }

  updateReaderMenuAnchorByPoint(x: number): void {
    if (!this.readerUsesSideAnchoredControls()) {
      return;
    }
    const viewportWidth = Math.max(1, this.pageViewWidth || this.getPageTurnWidth());
    this.readerMenuAnchorSide = x < viewportWidth / 2 ? -1 : 1;
  }

  finishReaderHorizontalTouch(canCommitTap: boolean = true): void {
    const offsetX = this.readerTouchLastX - this.readerTouchStartX;
    const offsetY = this.readerTouchLastY - this.readerTouchStartY;
    if (this.isReaderPageTurnCommitGesture(offsetX, offsetY)) {
      this.readerTouchMoved = true;
      this.suppressReaderTapClick = true;
      this.commitReaderMove(offsetX, offsetY);
      return;
    }
    if (this.readerTouchMoved || this.isReaderTouchMoved(offsetX, offsetY)) {
      this.suppressReaderTapClick = true;
      this.rollbackSlidePageEffect();
      return;
    }
    if (canCommitTap && !this.isPageTurnAnimationEnabled() && this.commitReaderTapByPoint(this.readerTouchLastX,
      this.readerTouchLastY)) {
      this.suppressReaderTapClick = true;
      this.resetSlidePageEffect();
      return;
    }
    this.resetSlidePageEffect();
  }

  commitReaderTapByPoint(x: number, y: number): boolean {
    if (this.isReaderInteractiveActionActive()) {
      return true;
    }
    if (this.isPageTurnAnimationEnabled() && this.readerEffectivePageTurnMode() !== 0 &&
      this.readerEffectivePageTurnMode() !== 2) {
      return false;
    }
    const width = Math.max(1, this.pageViewWidth || this.getPageTurnWidth());
    const height = Math.max(1, this.pageViewHeight || this.getPageTurnHeight());
    if (this.readerEffectivePageTurnMode() === 2) {
      return this.commitReaderTapZone(this.getTapZoneIndex(x, y, width, height));
    }
    if (y < height * 0.3) {
      this.turnPrev();
      return true;
    }
    if (y > height * 0.7) {
      this.turnNext();
      return true;
    }
    if (x < width / 3) {
      this.turnPrev();
      return true;
    }
    if (x > width * 2 / 3) {
      this.turnNext();
      return true;
    }
    this.updateReaderMenuAnchorByPoint(x);
    this.showMenu = true;
    return true;
  }

  getTapZoneIndex(x: number, y: number, width: number, height: number): number {
    const column = Math.max(0, Math.min(2, Math.floor(Math.max(0, x) / Math.max(1, width / 3))));
    const row = Math.max(0, Math.min(2, Math.floor(Math.max(0, y) / Math.max(1, height / 3))));
    return row * 3 + column;
  }

  commitReaderTapZone(index: number): boolean {
    return this.commitReaderTapAction(this.readerTapZoneActionAt(index));
  }

  commitReaderTapAction(action: number): boolean {
    if (this.isReaderInteractiveActionActive()) {
      return true;
    }
    switch (action) {
      case 1:
        this.showMenu = true;
        return true;
      case 2:
        this.turnNext();
        return true;
      case 3:
        this.turnPrev();
        return true;
      case 0:
      default:
        return true;
    }
  }

  readerTapZoneActionsList(): number[] {
    const fallback = [3, 3, 3, 3, 1, 2, 2, 2, 2];
    const parts = (this.readerTapZoneActions || '').split(',');
    const result: number[] = [];
    for (let i = 0; i < 9; i++) {
      const parsed = Number(parts[i]);
      result.push(Number.isFinite(parsed) && parsed >= 0 && parsed <= 3 ? Math.round(parsed) : fallback[i]);
    }
    return result;
  }

  readerTapZoneActionAt(index: number): number {
    const actions = this.readerTapZoneActionsList();
    const safeIndex = Math.max(0, Math.min(8, Math.round(index)));
    return actions[safeIndex];
  }

  cycleTapZoneAction(index: number): void {
    const actions = this.readerTapZoneActionsList();
    const safeIndex = Math.max(0, Math.min(8, Math.round(index)));
    actions[safeIndex] = (actions[safeIndex] + 1) % 4;
    this.setTapZoneActions(actions.join(','));
  }

  setTapZoneActions(actions: string): void {
    const normalized = this.normalizeTapZoneActions(actions);
    this.readerTapZoneActions = normalized;
    ReaderSettingsStore.saveTapZoneActions(getContext(this), normalized).catch((e: Error) => {
      console.error('保存点击区域动作失败:', e);
    });
  }

  normalizeTapZoneActions(actions: string): string {
    const fallback = [3, 3, 3, 3, 1, 2, 2, 2, 2];
    const parts = (actions || '').split(',');
    const result: number[] = [];
    for (let i = 0; i < 9; i++) {
      const parsed = Number(parts[i]);
      result.push(Number.isFinite(parsed) && parsed >= 0 && parsed <= 3 ? Math.round(parsed) : fallback[i]);
    }
    return result.join(',');
  }

  tapActionLabel(action: number): string {
    switch (action) {
      case 1:
        return '菜单';
      case 2:
        return '下一页';
      case 3:
        return '上一页';
      case 0:
      default:
        return '无动作';
    }
  }

  tapZoneCellColor(action: number): string {
    if (action === 1) {
      return '#332A6FCC';
    }
    if (action === 2) {
      return '#2239A86B';
    }
    if (action === 3) {
      return '#22A85C39';
    }
    return '#14000000';
  }

  tapZoneSummaryText(): string {
    const actions = this.readerTapZoneActionsList();
    let menuCount = 0;
    let nextCount = 0;
    let prevCount = 0;
    let noneCount = 0;
    for (const action of actions) {
      if (action === 1) {
        menuCount++;
      } else if (action === 2) {
        nextCount++;
      } else if (action === 3) {
        prevCount++;
      } else {
        noneCount++;
      }
    }
    return `菜单${menuCount} · 下一页${nextCount} · 上一页${prevCount} · 无动作${noneCount}`;
  }

  isReaderTouchMoved(offsetX: number, offsetY: number): boolean {
    return Math.abs(offsetX) > this.readerTapSlop || Math.abs(offsetY) > this.readerTapSlop;
  }

  consumeSuppressedReaderTapClick(): boolean {
    if (this.isReaderInteractiveActionActive()) {
      this.suppressReaderTapClick = false;
      return true;
    }
    if (!this.suppressReaderTapClick) {
      return false;
    }
    this.suppressReaderTapClick = false;
    return true;
  }

  getReaderPageTurnGestureOffset(offsetX: number, offsetY: number): number {
    return this.isVerticalPageTurnAnimation() ? offsetY : offsetX;
  }

  isReaderPageTurnCommitGesture(offsetX: number, offsetY: number): boolean {
    const commitDistance = this.readerPageTurnCommitDistance;
    const directionRatio = this.readerPageTurnDirectionRatio;
    if (this.isVerticalPageTurnAnimation()) {
      return Math.abs(offsetY) >= commitDistance &&
        Math.abs(offsetY) > Math.abs(offsetX) * directionRatio;
    }
    return Math.abs(offsetX) >= commitDistance &&
      Math.abs(offsetX) > Math.abs(offsetY) * directionRatio;
  }

  commitReaderMove(offsetX: number, offsetY: number, releaseVelocity: number = 0): void {
    if (this.readerPageTurnGestureCommitted) {
      return;
    }
    this.readerPageTurnGestureCommitted = true;
    this.readerGestureTurnGuardUntil = Date.now() + 2500;
    this.readerGestureTurnAllowance = 1;
    // Touch and PanGesture both observe the same pointer stream. Closing both sides here makes
    // whichever callback arrives second a no-op instead of committing a second page.
    this.readerTouchActive = false;
    this.readerPanActive = false;
    if (this.isVerticalPageTurnAnimation()) {
      this.commitReaderVerticalMove(offsetY, releaseVelocity);
      return;
    }
    this.commitReaderHorizontalMove(offsetX, releaseVelocity);
  }

  commitReaderVerticalMove(offsetY: number, releaseVelocity: number = 0): void {
    if (!this.isVerticalPageTurnAnimation() || this.showToc || this.showSettings ||
      this.chapters.length === 0) {
      return;
    }
    const commitDistance = this.readerPageTurnCommitDistance;
    if (offsetY <= -commitDistance) {
      this.runPageTurnAnimation(1, 'gesture', false, releaseVelocity);
    } else if (offsetY >= commitDistance) {
      this.runPageTurnAnimation(-1, 'gesture', false, releaseVelocity);
    } else {
      this.resetSlidePageEffect();
    }
  }

  commitReaderHorizontalMove(offsetX: number, releaseVelocity: number = 0): void {
    if ((this.readerEffectivePageTurnMode() !== 1 && this.readerEffectivePageTurnMode() !== 2) ||
      this.showToc || this.showSettings ||
      this.chapters.length === 0) {
      return;
    }
    const commitDistance = this.readerPageTurnCommitDistance;
    if (offsetX <= -commitDistance) {
      this.runPageTurnAnimation(1, 'gesture', false, releaseVelocity);
    } else if (offsetX >= commitDistance) {
      this.runPageTurnAnimation(-1, 'gesture', false, releaseVelocity);
    } else {
      this.resetSlidePageEffect();
    }
  }

  @Builder
  settingsPanel() {
    Column({ space: 12 }) {
      Row() {
        Text(this.settingsPanelTitle())
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.getTextColor())

        Blank()
          .layoutWeight(1)

        ImmersiveBackButton({
          icon: $r('sys.symbol.xmark'),
          iconOffsetX: 0,
          iconColor: this.getTextColor(),
          darkMode: this.isReaderThemeDark(),
          buttonSize: 40,
          containerWidth: 40,
          containerHeight: 40,
          startInset: 0,
          materialScale: 0.83,
          compactLayout: true,
          accessibilityLabel: '关闭设置',
          onBack: () => this.closeSettingsPanelKeepMenu()
        })
      }
      .width('100%')
      .padding({ right: this.readerSettingsContentRightPadding() })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: 14 }) {
          if (this.settingsPanelTab === 0) {
            Column() {
              this.readerQuickSettingsPanel()
            }
            .width('100%')
            .transition(this.readerSettingsContentTransition(-1))
          } else if (this.settingsPanelTab === 1) {
            Column() {
              this.ttsQuickSettingsPanel()
            }
            .width('100%')
            .transition(this.readerSettingsContentTransition(1))
          } else {
            Column() {
              this.readerTypographySettingsPanel()
            }
            .width('100%')
            .transition(this.readerSettingsContentTransition(1))
          }
        }
        .width('100%')
        .padding({ right: this.readerSettingsContentRightPadding() })
      }
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .scrollBarColor(this.isReaderThemeDark() ? '#668A8F98' : '#667A6F63')
    }
    .width(this.readerFloatingBarWidth())
    .height(520)
    .padding({ left: 20, right: this.readerSettingsScrollBarRightInset(), top: 16, bottom: 0 })
    .borderRadius(ThemeRuntime.glassCornerRadius(28, 'panel'))
    .clip(true)
    .backgroundColor(this.readerGlassPanelColor())
    .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
    .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: this.readerGlassBorderColor() })
    .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: this.readerGlassShadowColor(), offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
    .position({ x: this.readerFloatingBarLeft(), y: '100%' })
    .translate({ y: -(520 + this.readerFloatingPanelBottomInset()) })
    .transition(this.readerPanelTransition())
  }

  settingsPanelTitle(): string {
    if (this.settingsPanelTab === 1) return '朗读设置';
    if (this.settingsPanelTab === 2) return '排版设置';
    return '阅读设置';
  }

  readerSettingsScrollBarRightInset(): number {
    // 目录、设置面板与底部操作栏现在共用同一宽度和边缘，不再需要百分比补偿。
    return 0;
  }

  readerSettingsContentRightPadding(): number {
    return Math.max(0, 20 - this.readerSettingsScrollBarRightInset());
  }

  @Builder
  readerTypographySettingsPanel() {
    Column({ space: 4 }) {
      this.readerFontEntryItem()

      this.readerSwitchSettingItem('正文扩展至状态栏', '开启后正文同时延伸到顶部状态栏和底部系统安全区', this.readerExtendToStatusBar,
        (checked: boolean) => {
          this.setReaderExtendToStatusBar(checked);
        })

      this.readerTypographySlider('字号', 0, 14, 50, 1)
      this.readerTypographySlider('行距', 1, 0, 52, 1)
      this.readerTypographySlider('段距', 2, 0, 32, 1)
      this.readerTypographySlider('左边距', 3, 0, 80, 1)
      this.readerTypographySlider('右边距', 4, 0, 80, 1)
      this.readerTypographySlider('上边距', 5, 0, 120, 1)
      this.readerTypographySlider('下边距', 6, 0, 120, 1)
    }
    .width('100%')
  }

  @Builder
  readerTypographySlider(label: string, settingIndex: number, min: number, max: number, step: number) {
    Column({ space: 6 }) {
      Row() {
        Text(label)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.getTextColor())
        Blank()
        Text(`${Math.round(this.readerTypographyValue(settingIndex))}`)
          .id(`reader_typography_value_${settingIndex}_${this.readerTypographyValueRevision}_` +
            `${Math.round(this.readerTypographyValue(settingIndex))}`)
          .fontSize(13)
          .fontColor(this.accentColor())
          .textAlign(TextAlign.Center)
          .constraintSize({ minWidth: 32 })
      }
      .width('100%')

      Row({ space: 8 }) {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.minus'))
            .fontSize(16)
            .fontColor([this.readerTypographyValue(settingIndex) > min ?
              this.getTextColor() : this.getSubTextColor()])
        }
        .width(34)
        .height(34)
        .padding(0)
        .enabled(this.readerTypographyValue(settingIndex) > min)
        .backgroundColor(this.isReaderThemeDark() ? '#24272D' : '#EEF0F3')
        .accessibilityText(`减少${label}`)
        .onClick(() => this.stepReaderTypographyValue(settingIndex, -step))
        Slider({ value: this.readerTypographyValue(settingIndex), min: min, max: max, step: step })
          .layoutWeight(1)
          .height(28)
          .trackThickness(4)
          .blockSize({ width: 20, height: 20 })
          .selectedColor(this.accentColor())
          .trackColor(this.isReaderThemeDark() ? '#2FFFFFFF' : '#16000000')
          .blockColor(this.readerSolidPanelColor())
          .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .onChange((nextValue: number) => this.applyReaderTypographyValue(settingIndex, nextValue))
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(16)
            .fontColor([this.readerTypographyValue(settingIndex) < max ?
              this.getTextColor() : this.getSubTextColor()])
        }
        .width(34)
        .height(34)
        .padding(0)
        .enabled(this.readerTypographyValue(settingIndex) < max)
        .backgroundColor(this.isReaderThemeDark() ? '#24272D' : '#EEF0F3')
        .accessibilityText(`增加${label}`)
        .onClick(() => this.stepReaderTypographyValue(settingIndex, step))
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 5, bottom: 5 })
  }

  readerTypographyValue(settingIndex: number): number {
    if (settingIndex === 0) return this.readerTypographyFontSize;
    if (settingIndex === 1) return this.readerTypographyLineHeight;
    if (settingIndex === 2) return this.readerTypographyParagraphSpacing;
    if (settingIndex === 3) return this.readerTypographyMarginLeft;
    if (settingIndex === 4) return this.readerTypographyMarginRight;
    if (settingIndex === 5) return this.readerTypographyMarginTop;
    return this.readerTypographyMarginBottom;
  }

  applyReaderTypographyValue(settingIndex: number, value: number): void {
    const rounded = Math.round(value);
    if (settingIndex === 0) {
      this.readerTypographyFontSize = Math.max(14, Math.min(rounded, 50));
    } else if (settingIndex === 1) {
      this.readerTypographyLineHeight = Math.max(0, Math.min(rounded, 52));
    } else if (settingIndex === 2) {
      this.readerTypographyParagraphSpacing = Math.max(0, Math.min(rounded, 32));
    } else if (settingIndex === 3) {
      this.readerTypographyMarginLeft = Math.max(0, Math.min(rounded, 80));
    } else if (settingIndex === 4) {
      this.readerTypographyMarginRight = Math.max(0, Math.min(rounded, 80));
    } else if (settingIndex === 5) {
      this.readerTypographyMarginTop = Math.max(0, Math.min(rounded, 120));
    } else {
      this.readerTypographyMarginBottom = Math.max(0, Math.min(rounded, 120));
    }
    this.readerTypographyDraftPending = true;
    this.readerTypographyValueRevision++;
    this.scheduleReaderTypographyChange();
  }

  stepReaderTypographyValue(settingIndex: number, delta: number): void {
    const nextValue = this.readerTypographyValue(settingIndex) + delta;
    this.applyReaderTypographyValue(settingIndex, nextValue);
  }

  syncReaderTypographyDraft(): void {
    this.readerTypographyFontSize = this.readerFontSize;
    this.readerTypographyLineHeight = this.readerLineHeight;
    this.readerTypographyParagraphSpacing = this.readerParagraphSpacing;
    this.readerTypographyMarginLeft = this.readerMarginLeft;
    this.readerTypographyMarginRight = this.readerMarginRight;
    this.readerTypographyMarginTop = this.readerMarginTop;
    this.readerTypographyMarginBottom = this.readerMarginBottom;
    this.readerTypographyValueRevision++;
  }

  commitReaderTypographyDraft(): void {
    if (!this.readerTypographyDraftPending) return;
    this.readerLayoutCommitInProgress = true;
    this.readerFontSize = this.readerTypographyFontSize;
    this.readerLineHeight = this.readerTypographyLineHeight;
    this.readerParagraphSpacing = this.readerTypographyParagraphSpacing;
    this.readerMarginLeft = this.readerTypographyMarginLeft;
    this.readerMarginRight = this.readerTypographyMarginRight;
    this.readerMarginTop = this.readerTypographyMarginTop;
    this.readerMarginBottom = this.readerTypographyMarginBottom;
    this.readerLayoutCommitInProgress = false;
    this.readerTypographyDraftPending = false;
  }

  @Builder
  readerQuickSettingsPanel() {
    Column({ space: 14 }) {
      this.readerReplaceRulesEntryItem()

      this.readerSelectSettingItem('翻页方式', '选择上下滑动、横向滑动或滚动阅读',
        this.pageTurnModeOptions(), this.pageTurnModeSelectedIndex(), (index: number) => {
          this.switchPageTurnMode(this.pageTurnModeByIndex(index));
        }, 'reader_page_turn_mode_select')

      if (this.readerPageTurnMode === 2) {
        this.readerTapZoneSettingItem()
      }

      if (this.readerPageTurnMode === 2) {
        this.readerSelectSettingItem('翻页动画', '选择翻页时使用的页面切换效果',
          this.pageTurnAnimationOptions(), this.pageTurnAnimationSelectedIndex(), (index: number) => {
            this.setReaderPageTurnAnimationType(index);
          }, 'reader_page_turn_animation_select_horizontal')
      } else if (this.readerPageTurnMode === 0) {
        this.readerSelectSettingItem('翻页动画', '选择翻页时使用的页面切换效果',
          this.pageTurnAnimationOptions(), this.pageTurnAnimationSelectedIndex(), (index: number) => {
            this.setReaderPageTurnAnimationType(index);
          }, 'reader_page_turn_animation_select_vertical')
      }

      this.readerSwitchSettingItem('使用双翻页', '横屏或折叠屏展开等宽屏状态下同时显示左右两页',
        this.readerLandscapeDoublePage, (checked: boolean) => {
          this.setReaderLandscapeDoublePage(checked);
        })

      this.readerSelectSettingItem('屏幕方向', '设置正文阅读时使用的屏幕方向',
        this.screenOrientationOptions(), this.screenOrientationSelectedIndex(), (index: number) => {
          this.setReaderScreenOrientationByIndex(index);
        }, 'reader_screen_orientation_select')

      this.readerSwitchSettingItem('音量键翻页', '阅读页获得焦点时使用音量上/下键翻页', this.readerVolumeTurnPage,
        (checked: boolean) => {
          this.setReaderVolumeTurnPage(checked);
        })

      this.readerSelectSettingItem('亮屏时间设置', '无操作达到所选时长后恢复系统息屏',
        this.screenTimeoutOptions(), this.screenTimeoutSelectedIndex(), (index: number) => {
          this.setReaderScreenTimeoutByIndex(index);
        }, 'reader_screen_timeout_select')

      Row({ space: 10 }) {
        ForEach(this.currentReaderThemes(), (theme: ReaderThemeItem, index: number) => {
          Text(index === ReaderThemeHelper.CUSTOM_THEME_INDEX ? '自' :
            (index === ReaderThemeHelper.APP_THEME_INDEX ? '主' : ''))
            .width(42)
            .height(42)
            .borderRadius(21)
            .fontSize(13)
            .fontColor(theme.textColor)
            .textAlign(TextAlign.Center)
            .backgroundColor(theme.backgroundColor)
            .backgroundImage(theme.backgroundImageUri || '', ImageRepeat.NoRepeat)
            .backgroundImageSize(ImageSize.Cover)
            .border({
              width: this.currentReaderThemeIndex() === index ? 3 : 1,
              color: this.currentReaderThemeIndex() === index ? this.accentColor() : '#22000000'
            })
            .onClick(() => {
              this.applyReaderThemeIndex(index);
            })
        })
      }
      .width('100%')

      if (this.currentReaderThemeIndex() === ReaderThemeHelper.CUSTOM_THEME_INDEX) {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Select(this.customThemeOptions())
              .selected(this.currentCustomThemeSelectedIndex())
              .value(this.currentCustomThemeScheme().name)
              .font({ size: 14 })
              .fontColor(this.getTextColor())
              .backgroundColor(this.appDarkMode ? '#24FFFFFF' : '#12000000')
              .layoutWeight(1)
              .optionBgColor(Color.Transparent)
              .optionFontColor(this.getTextColor())
              .selectedOptionFontColor(this.accentColor())
              .selectedOptionBgColor(ThemeRuntime.accentSurfaceColor(this.isReaderThemeDark()))
              .menuBackgroundColor(ThemeRuntime.dropdownPanelColor(this.isReaderThemeDark(), this.getBackgroundColor()))
              .menuBackgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
              .onSelect((index: number) => {
                this.selectCustomTheme(index);
              })
            Button('新增')
              .height(36)
              .fontSize(13)
              .backgroundColor(this.accentColor())
              .fontColor('#FFFFFF')
              .onClick(() => {
                this.addCustomTheme();
              })
            Button('删除')
              .height(36)
              .fontSize(13)
              .backgroundColor(this.appDarkMode ? '#24FFFFFF' : '#12000000')
              .fontColor(this.getTextColor())
              .onClick(() => {
                this.deleteCurrentCustomTheme();
              })
          }
          .width('100%')
          TextInput({ text: this.customThemeNameDraft, placeholder: '输入方案名称' })
            .fontSize(14)
            .fontColor(this.getTextColor())
            .height(36)
            .padding({ left: 10, right: 10 })
            .backgroundColor(this.appDarkMode ? '#24FFFFFF' : '#12000000')
            .borderRadius(8)
            .onChange((value: string) => {
              this.customThemeNameDraft = value.substring(0, 20);
            })
            .onSubmit(() => {
              this.renameCurrentCustomTheme(this.customThemeNameDraft);
            })
            .onBlur(() => {
              this.renameCurrentCustomTheme(this.customThemeNameDraft);
            })
          Row() {
            Text('背景设置')
              .fontSize(14)
              .fontColor(this.getTextColor())
            Blank()
            Select([{ value: '背景色' }, { value: '背景图片' }])
              .selected(this.currentCustomThemeBackgroundTypeIndex())
              .value(this.currentCustomThemeBackgroundTypeIndex() === 1 ? '背景图片' : '背景色')
              .font({ size: 14 })
              .fontColor(this.getTextColor())
              .backgroundColor(this.appDarkMode ? '#24FFFFFF' : '#12000000')
              .optionBgColor(Color.Transparent)
              .optionFontColor(this.getTextColor())
              .selectedOptionFontColor(this.accentColor())
              .selectedOptionBgColor(ThemeRuntime.accentSurfaceColor(this.isReaderThemeDark()))
              .menuBackgroundColor(ThemeRuntime.dropdownPanelColor(this.isReaderThemeDark(), this.getBackgroundColor()))
              .menuBackgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
              .onSelect((index: number) => {
                this.setCurrentCustomThemeBackgroundType(index);
              })
          }
          .width('100%')
          if (this.currentCustomThemeBackgroundTypeIndex() === 0) {
            ColorCodePicker({
              value: this.currentCustomThemeBackgroundColor(),
              placeholder: this.currentCustomThemeBackgroundColor(),
              appDarkMode: this.appDarkMode,
              accentColor: this.accentColor(),
              optionTitle: '背景颜色',
              onColorChange: (value: string) => {
                this.setCurrentThemeBackgroundColor(value);
              }
            })
          } else {
            Row({ space: 8 }) {
              Button(this.currentCustomThemeScheme().backgroundImageUri ? '更换背景图片' : '选择背景图片')
                .height(36)
                .fontSize(13)
                .backgroundColor(this.accentColor())
                .fontColor('#FFFFFF')
                .onClick(() => {
                  this.chooseCurrentCustomThemeImage();
                })
              if (this.currentCustomThemeScheme().backgroundImageUri) {
                Button('移除图片')
                  .height(36)
                  .fontSize(13)
                  .backgroundColor(this.appDarkMode ? '#24FFFFFF' : '#12000000')
                  .fontColor(this.getTextColor())
                  .onClick(() => {
                    this.clearCurrentCustomThemeImage();
                  })
                Select([{ value: '裁剪填充' }, { value: '完整显示' }, { value: '拉伸铺满' }])
                  .selected(this.customThemeFitSelectedIndex())
                  .value(['裁剪填充', '完整显示', '拉伸铺满'][this.customThemeFitSelectedIndex()])
                  .font({ size: 13 })
                  .fontColor(this.getTextColor())
                  .backgroundColor(this.appDarkMode ? '#24FFFFFF' : '#12000000')
                  .layoutWeight(1)
                  .optionBgColor(Color.Transparent)
                  .optionFontColor(this.getTextColor())
                  .selectedOptionFontColor(this.accentColor())
                  .selectedOptionBgColor(ThemeRuntime.accentSurfaceColor(this.isReaderThemeDark()))
                  .menuBackgroundColor(ThemeRuntime.dropdownPanelColor(this.isReaderThemeDark(), this.getBackgroundColor()))
                  .menuBackgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
                  .onSelect((index: number) => {
                    this.setCurrentCustomThemeImageFit(index);
                  })
              }
            }
            .width('100%')
          }
          ColorCodePicker({
            value: this.currentCustomThemeTextColor(),
            placeholder: this.currentCustomThemeTextColor(),
            appDarkMode: this.appDarkMode,
            accentColor: this.accentColor(),
            optionTitle: '文字颜色',
            onColorChange: (value: string) => {
              this.setCurrentThemeTextColor(value);
            }
          })
        }
        .width('100%')
      }

      this.readerPreloadSettingItem()
    }
    .width('100%')
  }

  @Builder
  readerFontEntryItem() {
    Row() {
      Column() {
        Text('阅读字体')
          .fontSize(15)
          .fontColor(this.getTextColor())
        Text('正文 / 标题 / 正则样式设置')
          .fontSize(12)
          .fontColor(this.getSubTextColor())
          .margin({ top: 4 })
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([this.getSubTextColor()])
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      router.pushUrl({ url: 'pages/ReaderFontSettings' });
    })
  }

  @Builder
  readerReplaceRulesEntryItem() {
    Row() {
      Column() {
        Text('替换净化')
          .fontSize(15)
          .fontColor(this.getTextColor())
        Text('管理正文与章节标题的替换规则')
          .fontSize(12)
          .fontColor(this.getSubTextColor())
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([this.getSubTextColor()])
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.returningFromReaderReplaceRules = true;
      router.pushUrl({ url: 'pages/ReaderReplaceRules' });
    })
  }

  @Builder
  ttsQuickSettingsPanel() {
    Column({ space: 14 }) {
      Row() {
        Text('朗读倍速')
          .fontSize(15)
          .fontColor(this.getTextColor())
          .layoutWeight(1)
        Text(`${this.ttsSpeed.toFixed(1)}x`)
          .fontSize(14)
          .fontColor(this.getSubTextColor())
      }
      .width('100%')

      Row({ space: 10 }) {
        this.readerSliderStepButton($r('sys.symbol.minus'), '降低朗读倍速', this.ttsSpeed > 0.5, () => {
          this.applyTtsSpeed(this.ttsSpeed - 0.1);
        })
        Slider({ value: this.ttsSpeed, min: 0.5, max: 2, step: 0.1 })
          .layoutWeight(1)
          .selectedColor(this.accentColor())
          .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .onChange((value: number) => {
            this.applyTtsSpeed(value);
          })
        this.readerSliderStepButton($r('sys.symbol.plus'), '提高朗读倍速', this.ttsSpeed !== 2, () => {
          this.applyTtsSpeed(this.ttsSpeed + 0.1);
        })
      }
      .width('100%')

      Row({ space: 8 }) {
        this.ttsSpeedChip(0.8)
        this.ttsSpeedChip(1.0)
        this.ttsSpeedChip(1.2)
        this.ttsSpeedChip(1.5)
        this.ttsSpeedChip(2.0)
      }
      .width('100%')

      Row() {
        Text('朗读音色')
          .fontSize(15)
          .fontColor(this.getTextColor())
          .layoutWeight(1)
        if (this.ttsVoicesLoading) {
          Text('加载中')
            .fontSize(12)
            .fontColor(this.getSubTextColor())
        }
      }
      .width('100%')

      Row() {
        Text(this.selectedTtsVoiceTitle())
          .fontSize(14)
          .fontColor(this.getTextColor())
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(16)
          .fontColor([this.getSubTextColor()])
          .margin({ left: 10 })
      }
        .width('100%')
        .height(44)
        .padding({ left: 14, right: 14 })
        .backgroundColor(this.isReaderThemeDark() ? '#24272D' : '#EEF0F3')
        .borderRadius(8)
        .onClick(() => {
          this.showTtsVoiceDropdown = true;
        })

      Row() {
        Text('朗读定时')
          .fontSize(15)
          .fontColor(this.getTextColor())
          .layoutWeight(1)
        Text(this.ttsSleepTimerMinutes > 0 ?
          `剩余 ${Math.max(1, Math.ceil(this.ttsSleepTimerRemainingSeconds / 60))} 分钟` : '未设置')
          .fontSize(12)
          .fontColor(this.getSubTextColor())
      }
      .width('100%')

      Row({ space: 8 }) {
        this.ttsSleepTimerChip(15)
        this.ttsSleepTimerChip(30)
        this.ttsSleepTimerChip(60)
        this.ttsSleepTimerChip(90)
        this.ttsSleepTimerChip(120)
      }
      .width('100%')

      Button(this.isTtsSpeaking ? '停止朗读' : '开始朗读')
        .width('100%')
        .height(40)
        .backgroundColor(this.isTtsSpeaking ? '#E53935' : this.buttonColor())
        .fontColor('#FFFFFF')
        .onClick(() => {
          this.toggleTtsReading();
        })
    }
    .width('100%')
  }

  @Builder
  ttsVoiceDropdownPanel() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showTtsVoiceDropdown = false;
        })

      Column() {
        Row() {
          Text('朗读音色')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.getTextColor())

          Blank()
            .layoutWeight(1)

          ImmersiveBackButton({
            icon: $r('sys.symbol.xmark'),
            iconOffsetX: 0,
            iconColor: this.getTextColor(),
            darkMode: this.isReaderThemeDark(),
            buttonSize: 40,
            containerWidth: 40,
            containerHeight: 40,
            startInset: 0,
            materialScale: 0.83,
            compactLayout: true,
            accessibilityLabel: '关闭音色选择',
            onBack: () => {
              this.showTtsVoiceDropdown = false;
            }
          })
        }
        .width('100%')
        .padding({ left: 20, right: 16, top: 12, bottom: 10 })
        .alignItems(VerticalAlign.Center)

        Scroll() {
          Column() {
            if (this.ttsCloudVoices.length > 0) {
              this.ttsVoiceDropdownSectionTitle('云端音色')
              ForEach(this.ttsCloudVoices, (voice: TtsVoiceInfo) => {
                this.ttsVoiceDropdownOption(this.ttsCloudVoiceTitle(voice),
                  this.isCurrentCloudTtsVoice(voice), () => {
                    this.showTtsVoiceDropdown = false;
                    this.applyCloudTtsVoice(voice, true);
                  })
              }, (voice: TtsVoiceInfo) => this.ttsCloudVoiceKey(voice))
            }

            if (this.selectableCustomTtsVoices().length > 0) {
              this.ttsVoiceDropdownSectionTitle('自定义音色')
              ForEach(this.selectableCustomTtsVoices(), (voice: HttpTTS) => {
                this.ttsVoiceDropdownOption(this.ttsCustomVoiceTitle(voice),
                  this.isCurrentCustomTtsVoice(voice), () => {
                    this.showTtsVoiceDropdown = false;
                    this.applyCustomTtsVoice(voice, true);
                  })
              }, (voice: HttpTTS) => this.ttsCustomVoiceKey(voice))
            }

            if (this.selectableSystemTtsVoices().length > 0) {
              this.ttsVoiceDropdownSectionTitle('系统音色')
              ForEach(this.selectableSystemTtsVoices(), (voice: TtsVoiceOption) => {
                this.ttsVoiceDropdownOption(this.ttsVoiceTitle(voice),
                  this.isCurrentTtsVoice(voice), () => {
                    this.showTtsVoiceDropdown = false;
                    this.applyTtsVoice(voice, true);
                  })
              }, (voice: TtsVoiceOption) => this.ttsVoiceKey(voice))
            }
          }
          .width('100%')
          .padding({ left: 12, right: 12, bottom: 16 })
        }
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .scrollBarColor(this.isReaderThemeDark() ? '#668A8F98' : '#667A6F63')
      }
      .width(this.readerFloatingBarWidth())
      .height(this.readerTocPanelHeight())
      .borderRadius(ThemeRuntime.glassCornerRadius(28, 'panel'))
      .clip(true)
      .backgroundColor(this.readerGlassPanelColor())
      .backdropBlur(ThemeRuntime.glassBlur('panel', 22))
      .border({ width: ThemeRuntime.glassBorderWidth('panel'), color: this.readerGlassBorderColor() })
      .shadow({ radius: ThemeRuntime.glassShadowRadius('panel'), color: this.readerGlassShadowColor(),
        offsetX: ThemeRuntime.glassShadowOffsetX('panel'), offsetY: ThemeRuntime.glassShadowOffsetY('panel') })
      .position({ x: this.readerFloatingBarLeft(), y: '100%' })
      .translate({ y: -(this.readerTocPanelHeight() + this.readerFloatingPanelBottomInset()) })
      .transition(this.readerPanelTransition())
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  ttsVoiceDropdownSectionTitle(title: string) {
    Text(title)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.getSubTextColor())
      .width('100%')
      .padding({ left: 10, right: 10, top: 12, bottom: 6 })
  }

  @Builder
  ttsVoiceDropdownOption(title: string, selected: boolean, action: () => void) {
    Row() {
      Text(title)
        .fontSize(14)
        .fontColor(this.getTextColor())
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (selected) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(18)
          .fontColor([this.accentColor()])
          .margin({ left: 10 })
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 48 })
    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
    .borderRadius(8)
    .backgroundColor(selected ? this.tocSelectedBackgroundColor() : Color.Transparent)
    .onClick(action)
  }

  @Builder
  ttsSpeedChip(value: number) {
    Text(`${value.toFixed(1)}x`)
      .fontSize(13)
      .fontColor(Math.abs(this.ttsSpeed - value) < 0.01 ? '#FFFFFF' : this.getTextColor())
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(32)
      .borderRadius(16)
      .backgroundColor(Math.abs(this.ttsSpeed - value) < 0.01 ? this.accentColor() :
        (this.isReaderThemeDark() ? '#24272D' : '#EEF0F3'))
      .onClick(() => {
        this.applyTtsSpeed(value);
      })
  }

  @Builder
  ttsSleepTimerChip(minutes: number) {
    Text(`${minutes}分`)
      .fontSize(13)
      .fontColor(this.ttsSleepTimerMinutes === minutes ? '#FFFFFF' : this.getTextColor())
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(32)
      .borderRadius(16)
      .backgroundColor(this.ttsSleepTimerMinutes === minutes ? this.accentColor() :
        (this.isReaderThemeDark() ? '#24272D' : '#EEF0F3'))
      .accessibilityText(this.ttsSleepTimerMinutes === minutes ?
        `关闭 ${minutes} 分钟朗读定时` : `设置 ${minutes} 分钟朗读定时`)
      .onClick(() => {
        this.setTtsSleepTimer(this.ttsSleepTimerMinutes === minutes ? 0 : minutes);
      })
  }

  @Builder
  readerSliderStepButton(icon: Resource, accessibilityText: string, enabled: boolean, action: () => void) {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph(icon)
        .fontSize(16)
        .fontColor([enabled ? this.getTextColor() : this.getSubTextColor()])
    }
    .width(34)
    .height(34)
    .padding(0)
    .enabled(enabled)
    .backgroundColor(this.isReaderThemeDark() ? '#24272D' : '#EEF0F3')
    .accessibilityText(accessibilityText)
    .onClick(action)
  }

  pageTurnModeOptions(): SelectOption[] {
    return [
      { value: '上下滑动' },
      { value: '横向滑动' },
      { value: '滚动阅读' }
    ];
  }

  pageTurnModeTypes(): number[] {
    return [0, 2, 3];
  }

  pageTurnModeByIndex(index: number): number {
    const types = this.pageTurnModeTypes();
    return index >= 0 && index < types.length ? types[index] : 2;
  }

  pageTurnModeSelectedIndex(): number {
    const index = this.pageTurnModeTypes().indexOf(this.readerPageTurnMode);
    return index >= 0 ? index : 1;
  }

  pageTurnAnimationOptions(): SelectOption[] {
    const options: SelectOption[] = [
      { value: '无动画' },
      { value: '平移' },
      { value: '淡入' },
      { value: '叠页' }
    ];
    if (this.readerPageTurnMode === 2) options.push({ value: '仿真' });
    return options;
  }

  pageTurnAnimationTypes(): number[] {
    const types: number[] = [
      ReaderSettingsStore.PAGE_TURN_ANIMATION_NONE,
      ReaderSettingsStore.PAGE_TURN_ANIMATION_SLIDE,
      ReaderSettingsStore.PAGE_TURN_ANIMATION_FADE,
      ReaderSettingsStore.PAGE_TURN_ANIMATION_STACK
    ];
    if (this.readerPageTurnMode === 2) types.push(ReaderSettingsStore.PAGE_TURN_ANIMATION_SIMULATION);
    return types;
  }

  pageTurnAnimationSelectedIndex(): number {
    const types = this.pageTurnAnimationTypes();
    const value = this.normalizePageTurnAnimationType(this.readerPageTurnAnimationType);
    for (let i = 0; i < types.length; i++) {
      if (types[i] === value) {
        return i;
      }
    }
    return 0;
  }

  pageTurnAnimationValue(): string {
    const options = this.pageTurnAnimationOptions();
    const index = this.pageTurnAnimationSelectedIndex();
    const option = options[index];
    return option && typeof option.value === 'string' ? option.value : '无动画';
  }

  screenTimeoutOptions(): SelectOption[] {
    return [
      { value: '跟随系统' },
      { value: '1分钟' },
      { value: '5分钟' },
      { value: '10分钟' },
      { value: '常亮' }
    ];
  }

  screenTimeoutValues(): number[] {
    return [
      ReaderSettingsStore.SCREEN_TIMEOUT_FOLLOW_SYSTEM,
      1,
      5,
      10,
      ReaderSettingsStore.SCREEN_TIMEOUT_ALWAYS_ON
    ];
  }

  screenTimeoutSelectedIndex(): number {
    const values = this.screenTimeoutValues();
    const current = ReaderSettingsStore.normalizeScreenTimeoutMinutes(this.readerScreenTimeoutMinutes);
    for (let i = 0; i < values.length; i++) {
      if (values[i] === current) {
        return i;
      }
    }
    return 0;
  }

  screenOrientationOptions(): SelectOption[] {
    return [
      { value: '跟随系统' },
      { value: '强制竖屏' },
      { value: '强制横屏' }
    ];
  }

  screenOrientationValues(): string[] {
    return [
      ReaderSettingsStore.SCREEN_ORIENTATION_SYSTEM,
      ReaderSettingsStore.SCREEN_ORIENTATION_PORTRAIT,
      ReaderSettingsStore.SCREEN_ORIENTATION_LANDSCAPE
    ];
  }

  screenOrientationSelectedIndex(): number {
    const value = ReaderSettingsStore.normalizeScreenOrientation(this.readerScreenOrientation);
    const values = this.screenOrientationValues();
    for (let i = 0; i < values.length; i++) {
      if (values[i] === value) return i;
    }
    return 0;
  }

  @Builder
  readerTapZoneSettingItem() {
    Row() {
      Column() {
        Text('点击区域动作')
          .fontSize(15)
          .fontColor(this.getTextColor())
        Text(this.tapZoneSummaryText())
          .fontSize(12)
          .fontColor(this.getSubTextColor())
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button('配置')
        .height(34)
        .fontSize(13)
        .backgroundColor(this.buttonColor())
        .fontColor('#FFFFFF')
        .margin({ left: 12 })
        .onClick(() => {
          this.showTapZoneSettings = true;
        })
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  tapZoneSettingsDialog() {
    Column() {
      Column({ space: 14 }) {
        Row() {
          Text('点击区域动作')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .layoutWeight(1)

          Button('×')
            .fontSize(26)
            .fontColor('#FFFFFF')
            .width(48)
            .height(48)
            .backgroundColor('#00000000')
            .padding(0)
            .onClick(() => {
              this.showTapZoneSettings = false;
            })
        }
        .width('calc(100% - 40vp)')
        .height(52)
        .alignItems(VerticalAlign.Center)

        Column() {
          ForEach([0, 1, 2], (row: number) => {
            Row() {
              ForEach([0, 1, 2], (column: number) => {
                this.tapZoneCell(row * 3 + column)
              }, (column: number) => `${row}_${column}`)
            }
            .width('100%')
            .layoutWeight(1)
            .clip(true)
          }, (row: number) => `${row}`)
        }
        .width('calc(100% - 40vp)')
        .layoutWeight(1)
        .border({ width: 1, color: '#33FFFFFF' })
        .clip(true)

        Row({ space: 12 }) {
          Button('重置默认')
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .backgroundColor('#33383E')
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.setTapZoneActions('3,3,3,3,1,2,2,2,2');
            })

          Button('完成')
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .backgroundColor(this.accentColor())
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.showTapZoneSettings = false;
            })
        }
        .width('calc(100% - 40vp)')
      }
      .width('100%')
      .height('100%')
      .padding({ top: 18, bottom: 22 })
      .alignItems(HorizontalAlign.Center)
      .backgroundColor('#D9000000')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
  }

  @Builder
  tapZoneCell(index: number) {
    Text(this.tapActionLabel(this.readerTapZoneActionAt(index)))
      .fontSize(18)
      .fontWeight(FontWeight.Medium)
      .fontColor('#FFFFFF')
      .textAlign(TextAlign.Center)
      .width('100%')
      .height('100%')
      .layoutWeight(1)
      .backgroundColor(this.tapZoneCellColor(this.readerTapZoneActionAt(index)))
      .border({ width: 0.5, color: '#33FFFFFF' })
      .clip(true)
      .onClick(() => {
        this.cycleTapZoneAction(index);
      })
  }

  @Builder
  readerSelectSettingItem(title: string, description: string, options: SelectOption[], selected: number,
    onSelect: (index: number) => void, controlId: string) {
    Row() {
      Column() {
        Text(title)
          .fontSize(15)
          .fontColor(this.getTextColor())
        Text(description)
          .fontSize(12)
          .fontColor(this.getSubTextColor())
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Select(options)
        .id(controlId)
        .selected(selected)
        .value(this.readerSelectOptionValue(options, selected))
        .font({ size: 14 })
        .fontColor(this.getSubTextColor())
        .backgroundColor(Color.Transparent)
        .arrowPosition(ArrowPosition.END)
        .padding({ left: 0, right: 0 })
        .borderRadius(0)
        .border({ width: 0 })
        .optionBgColor(Color.Transparent)
        .optionFontColor(this.getTextColor())
        .selectedOptionFontColor(this.accentColor())
        .selectedOptionBgColor(ThemeRuntime.accentSurfaceColor(this.isReaderThemeDark()))
        .menuBackgroundColor(ThemeRuntime.dropdownPanelColor(this.isReaderThemeDark(), this.getBackgroundColor()))
        .menuBackgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
        .onSelect((index: number) => {
          onSelect(index);
        })
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .alignItems(VerticalAlign.Center)
  }

  readerSelectOptionValue(options: SelectOption[], index: number): ResourceStr {
    if (index >= 0 && index < options.length) {
      return options[index].value;
    }
    return options.length > 0 ? options[0].value : '';
  }

  @Builder
  readerSwitchSettingItem(title: string, description: string, checked: boolean, onChange: (checked: boolean) => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(15)
          .fontColor(this.getTextColor())
        Text(description)
          .fontSize(12)
          .fontColor(this.getSubTextColor())
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: checked })
        .selectedColor(this.buttonColor())
        .onChange((value: boolean) => {
          onChange(value);
        })
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  readerPreloadSettingItem() {
    Column() {
      Row() {
        Column() {
          Text('预缓存设置')
            .fontSize(15)
            .fontColor(this.getTextColor())
          Text(this.readerPreloadEnabled ? '阅读过程中提前缓存后续章节' : '已关闭自动预缓存')
            .fontSize(12)
            .fontColor(this.getSubTextColor())
            .margin({ top: 4 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.readerPreloadEnabled })
          .selectedColor(this.buttonColor())
          .onChange((value: boolean) => {
            this.setReaderPreloadEnabled(value);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.readerPreloadEnabled) {
        Row() {
          Text('下一章节数')
            .fontSize(13)
            .fontColor(this.getTextColor())
            .layoutWeight(1)
          Text(`${this.readerPreloadChapterCount}章`)
            .fontSize(13)
            .fontColor(this.getSubTextColor())
        }
        .width('100%')
        .margin({ top: 10 })

        Row({ space: 10 }) {
          this.readerSliderStepButton($r('sys.symbol.minus'), '减少预缓存章节数',
            this.readerPreloadChapterCount > 1, () => {
            this.setReaderPreloadChapterCount(this.readerPreloadChapterCount - 1);
          })
          Slider({ value: this.readerPreloadChapterCount, min: 1, max: 10, step: 1 })
            .layoutWeight(1)
            .selectedColor(this.accentColor())
            .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
            .onChange((sliderValue: number) => {
              this.setReaderPreloadChapterCount(sliderValue);
            })
          this.readerSliderStepButton($r('sys.symbol.plus'), '增加预缓存章节数',
            this.readerPreloadChapterCount !== 10, () => {
            this.setReaderPreloadChapterCount(this.readerPreloadChapterCount + 1);
          })
        }
        .width('100%')
        .margin({ top: 6 })
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
  }

  switchPageTurnMode(mode: number) {
    if (this.readerPageTurnMode === mode) {
      return;
    }
    this.stopTtsReading();
    this.readerPageTurnMode = mode;
    if (mode === 0 && Math.round(this.readerPageTurnAnimationType) ===
      ReaderSettingsStore.PAGE_TURN_ANIMATION_SIMULATION) {
      this.readerPageTurnAnimationType = ReaderSettingsStore.PAGE_TURN_ANIMATION_STACK;
      this.resetSlidePageEffect();
      ReaderSettingsStore.savePageTurnAnimationType(getContext(this), this.readerPageTurnAnimationType)
        .catch((e: Error) => {
          console.error('降级上下滑动翻页动画失败:', e);
        });
    }
    ReaderSettingsStore.savePageTurnMode(getContext(this), mode).catch((e: Error) => {
      console.error('保存翻页方式失败:', e);
    });
    this.currentPageIndex = 0;
    this.pendingRestorePageIndex = 0;
    this.paginateContent(this.content);
    this.saveReadingProgress();
    this.saveReadConfig();
  }

  setReaderPageTurnAnimationType(index: number): void {
    const types = this.pageTurnAnimationTypes();
    const type = index >= 0 && index < types.length ? types[index] : ReaderSettingsStore.PAGE_TURN_ANIMATION_SLIDE;
    this.readerPageTurnAnimationType = this.normalizePageTurnAnimationType(type);
    this.resetSlidePageEffect();
    ReaderSettingsStore.savePageTurnAnimationType(getContext(this), this.readerPageTurnAnimationType).catch((e: Error) => {
      console.error('保存翻页动画失败:', e);
    });
    this.saveReadConfig();
  }

  normalizePageTurnAnimationType(type: number): number {
    const value = Math.round(type);
    if (this.readerPageTurnMode === 0 && value === ReaderSettingsStore.PAGE_TURN_ANIMATION_SIMULATION) {
      return ReaderSettingsStore.PAGE_TURN_ANIMATION_STACK;
    }
    if (value === ReaderSettingsStore.PAGE_TURN_ANIMATION_NONE ||
      value === ReaderSettingsStore.PAGE_TURN_ANIMATION_SLIDE ||
      value === ReaderSettingsStore.PAGE_TURN_ANIMATION_FADE ||
      value === ReaderSettingsStore.PAGE_TURN_ANIMATION_STACK ||
      value === ReaderSettingsStore.PAGE_TURN_ANIMATION_SIMULATION) {
      return value;
    }
    return ReaderSettingsStore.PAGE_TURN_ANIMATION_SLIDE;
  }

  isPageTurnAnimationEnabled(): boolean {
    return this.normalizePageTurnAnimationType(this.readerPageTurnAnimationType) !== ReaderSettingsStore.PAGE_TURN_ANIMATION_NONE;
  }

  saveReaderLayoutSettings(): void {
    ReaderSettingsStore.saveLayoutSettings(
      getContext(this),
      this.readerFontSize,
      this.readerLineHeight,
      this.readerParagraphSpacing,
      this.readerMarginLeft,
      this.readerMarginRight,
      this.readerMarginTop,
      this.readerMarginBottom
    ).catch((e: Error) => {
      console.warn('保存阅读排版设置失败:', e);
    });
  }

  setReaderLandscapeDoublePage(enabled: boolean): void {
    this.readerLandscapeDoublePage = enabled;
    ReaderSettingsStore.saveLandscapeDoublePage(getContext(this), enabled).catch((e: Error) => {
      console.error('保存双翻页设置失败:', e);
    });
  }

  setReaderScreenOrientationByIndex(index: number): void {
    const values = this.screenOrientationValues();
    this.readerScreenOrientation = index >= 0 && index < values.length ? values[index] :
      ReaderSettingsStore.SCREEN_ORIENTATION_SYSTEM;
    this.applyReaderScreenOrientation();
    ReaderSettingsStore.saveScreenOrientation(getContext(this), this.readerScreenOrientation).catch((e: Error) => {
      console.error('保存阅读屏幕方向失败:', e);
    });
  }

  applyReaderThemeIndex(index: number): void {
    const nextThemeIndex = ReaderThemeHelper.normalizeIndex(index);
    if (nextThemeIndex === this.currentReaderThemeIndex()) {
      return;
    }
    if (this.appDarkMode) {
      this.readerDarkThemeIndex = nextThemeIndex;
    } else {
      this.readerLightThemeIndex = nextThemeIndex;
    }
    this.saveReaderThemeSettings();
    this.saveReadConfig();
  }

  saveReaderThemeSettings(): void {
    ReaderSettingsStore.saveThemeSettings(
      getContext(this),
      this.readerLightThemeIndex,
      this.readerDarkThemeIndex,
      this.readerLightCustomThemeBackgroundColor,
      this.readerLightCustomThemeTextColor,
      this.readerDarkCustomThemeBackgroundColor,
      this.readerDarkCustomThemeTextColor,
      this.appDarkMode,
      this.readerCustomThemesRaw
    ).catch((e: Error) => {
      console.warn('保存阅读配色设置失败:', e);
    });
  }

  setCurrentThemeBackgroundColor(color: string): void {
    const value = this.normalizeColor(color, this.currentCustomThemeBackgroundColor());
    const data = this.customThemeData();
    ReaderCustomThemeHelper.selected(data, this.appDarkMode).backgroundColor = value;
    this.persistCustomThemeData(data);
  }

  setCurrentThemeTextColor(color: string): void {
    const value = this.normalizeColor(color, this.currentCustomThemeTextColor());
    const data = this.customThemeData();
    ReaderCustomThemeHelper.selected(data, this.appDarkMode).textColor = value;
    this.persistCustomThemeData(data);
  }

  persistCustomThemeData(data: ReaderCustomThemeData): void {
    const selected = ReaderCustomThemeHelper.selected(data, this.appDarkMode);
    if (this.appDarkMode) {
      this.readerDarkCustomThemeBackgroundColor = selected.backgroundColor;
      this.readerDarkCustomThemeTextColor = selected.textColor;
    } else {
      this.readerLightCustomThemeBackgroundColor = selected.backgroundColor;
      this.readerLightCustomThemeTextColor = selected.textColor;
    }
    this.readerCustomThemesRaw = ReaderCustomThemeHelper.stringify(data);
    this.saveReaderThemeSettings();
    this.saveReadConfig();
  }

  addCustomTheme(): void {
    const data = this.customThemeData();
    const item = ReaderCustomThemeHelper.add(data, this.appDarkMode);
    this.customThemeNameDraft = item.name;
    this.persistCustomThemeData(data);
  }

  deleteCurrentCustomTheme(): void {
    const data = this.customThemeData();
    if (ReaderCustomThemeHelper.schemesForMode(data, this.appDarkMode).length <= 1) {
      promptAction.showToast({ message: '至少保留一套自定义背景' });
      return;
    }
    ReaderCustomThemeHelper.removeSelected(data, this.appDarkMode);
    this.customThemeNameDraft = ReaderCustomThemeHelper.selected(data, this.appDarkMode).name;
    this.persistCustomThemeData(data);
  }

  selectCustomTheme(index: number): void {
    const data = this.customThemeData();
    const schemes = ReaderCustomThemeHelper.schemesForMode(data, this.appDarkMode);
    if (index < 0 || index >= schemes.length) {
      return;
    }
    ReaderCustomThemeHelper.select(data, this.appDarkMode, schemes[index].id);
    this.customThemeNameDraft = schemes[index].name;
    this.persistCustomThemeData(data);
  }

  renameCurrentCustomTheme(name: string): void {
    const data = this.customThemeData();
    const current = ReaderCustomThemeHelper.selected(data, this.appDarkMode);
    const value = (name || '').trim().substring(0, 20);
    if (!value) {
      this.customThemeNameDraft = current.name;
      return;
    }
    current.name = value;
    this.customThemeNameDraft = value;
    this.persistCustomThemeData(data);
  }

  async chooseCurrentCustomThemeImage(): Promise<void> {
    const data = this.customThemeData();
    const current = ReaderCustomThemeHelper.selected(data, this.appDarkMode);
    try {
      const imageUri = await ReaderBackgroundImageStore.pickAndSave(getContext(this), current.id);
      if (!imageUri) {
        return;
      }
      current.backgroundImageUri = imageUri;
      current.backgroundType = 'image';
      this.persistCustomThemeData(data);
    } catch (e) {
      console.error('选择阅读背景图片失败:', e);
      promptAction.showToast({ message: '选择背景图片失败' });
    }
  }

  clearCurrentCustomThemeImage(): void {
    const data = this.customThemeData();
    const current = ReaderCustomThemeHelper.selected(data, this.appDarkMode);
    current.backgroundImageUri = '';
    current.backgroundType = 'color';
    this.persistCustomThemeData(data);
  }

  setCurrentCustomThemeBackgroundType(index: number): void {
    const data = this.customThemeData();
    ReaderCustomThemeHelper.selected(data, this.appDarkMode).backgroundType = index === 1 ? 'image' : 'color';
    this.persistCustomThemeData(data);
  }

  setCurrentCustomThemeImageFit(index: number): void {
    const fits = ['cover', 'contain', 'fill'];
    const data = this.customThemeData();
    ReaderCustomThemeHelper.selected(data, this.appDarkMode).backgroundImageFit = fits[index] || 'cover';
    this.persistCustomThemeData(data);
  }

  saveReaderInteractionSettings(): void {
    ReaderSettingsStore.saveReadingInteractionSettings(
      getContext(this),
      this.readerVolumeTurnPage,
      this.readerScreenTimeoutMinutes,
      this.readerExtendToStatusBar
    ).catch((e: Error) => {
      console.error('保存阅读交互设置失败:', e);
    });
  }

  setReaderVolumeTurnPage(enabled: boolean): void {
    this.readerVolumeTurnPage = enabled;
    this.updateVolumeKeySubscription();
    this.saveReaderInteractionSettings();
    this.saveReadConfig();
  }

  setReaderScreenTimeoutByIndex(index: number): void {
    const values = this.screenTimeoutValues();
    this.readerScreenTimeoutMinutes = index >= 0 && index < values.length ?
      values[index] :
      ReaderSettingsStore.SCREEN_TIMEOUT_FOLLOW_SYSTEM;
    this.applyReaderScreenTimeout();
    this.saveReaderInteractionSettings();
    this.saveReadConfig();
  }

  setReaderExtendToStatusBar(enabled: boolean): void {
    if (this.readerExtendToStatusBar === enabled) return;
    const readingOffset = this.getCurrentPageStartOffset();
    this.readerExtendLayoutReadingOffset = readingOffset;
    this.readerExtendToStatusBar = enabled;
    this.syncReaderPageHeightForContentTopPadding();
    // StorageLink watchers can be delivered in a later UI task. Calling the coalesced refresh here
    // makes the switch responsive, while a subsequent watch notification only restarts the same timer.
    this.scheduleReaderExtendLayoutRefresh(readingOffset);
    this.saveReaderInteractionSettings();
    this.saveReadConfig();
  }

  setReaderPreloadEnabled(enabled: boolean): void {
    this.readerPreloadEnabled = enabled;
    ReaderSettingsStore.savePreloadEnabled(getContext(this), enabled).catch((e: Error) => {
      console.error('保存预缓存开关失败:', e);
    });
    if (enabled) {
      this.preloadReaderContentLater();
    }
    this.saveReadConfig();
  }

  setReaderPreloadChapterCount(count: number): void {
    const value = Math.max(1, Math.min(Math.round(count), 10));
    this.readerPreloadChapterCount = value;
    ReaderSettingsStore.savePreloadChapterCount(getContext(this), value).catch((e: Error) => {
      console.error('保存预缓存章节数失败:', e);
    });
    this.preloadReaderContentLater();
    this.saveReadConfig();
  }

  publishTtsFloatingSession(): void {
    ReaderTtsFloatingSession.attach(
      this.ttsFloatingSessionOwnerId,
      this.bookUrl,
      this.book?.name || '正在朗读',
      this.getChapterTitle(),
      this.isTtsPaused,
      () => this.toggleTtsReading(),
      () => this.isTtsPaused || this.ttsReader.isPaused(),
      () => this.stopTtsFloatingSession()
    );
    ReaderTtsFloatingSession.configureControls(
      this.ttsFloatingSessionOwnerId,
      () => { this.playPreviousChapterFromMediaSession(); },
      () => { this.playNextChapterFromMediaSession(); },
      (value: number) => this.applyTtsSpeed(value),
      (minutes: number) => this.setTtsSleepTimer(minutes)
    );
    ReaderTtsFloatingSession.configurePositionControl(
      this.ttsFloatingSessionOwnerId,
      (chapterIndex: number, pageIndex: number) => {
        this.playPositionFromFloatingSession(chapterIndex, pageIndex);
      }
    );
    this.updateTtsFloatingSession();
  }

  updateTtsFloatingSession(): void {
    ReaderTtsFloatingSession.update(
      this.ttsFloatingSessionOwnerId,
      this.book?.name || '正在朗读',
      this.getChapterTitle(),
      this.isTtsPaused
    );
    ReaderTtsFloatingSession.updateDetails(
      this.ttsFloatingSessionOwnerId,
      this.ttsPanelFollowingText() || this.ttsQuickSentencePreview(),
      this.ttsPanelTextBefore(),
      this.ttsCurrentSentence(),
      this.ttsPanelTextAfter(),
      this.getTtsFloatingCover(),
      this.shouldUseTtsThemeBookCover() ? this.activeTtsThemeShelfFrame() : '',
      `${this.currentChapterIndex + 1}/${Math.max(1, this.chapters.length)}章`,
      this.ttsSpeed,
      this.ttsSleepTimerMinutes,
      this.ttsSleepTimerRemainingSeconds,
      this.canPlayPreviousTtsChapter(),
      this.canPlayNextTtsChapter()
    );
  }

  stopTtsFloatingSession(): void {
    this.stopTtsReading();
    if (!this.readerPageVisible) {
      this.ttsReader.shutdown();
    }
  }

  async toggleTtsReading(): Promise<void> {
    if (this.isReaderComicModeActive()) return;
    if (this.isTtsSpeaking || this.ttsReader.isSpeaking()) {
      try {
        if (this.isTtsPaused || this.ttsReader.isPaused()) {
          this.isTtsPaused = false;
          if (await this.ttsReader.resume()) {
            this.isTtsSpeaking = true;
            this.updateTtsFloatingSession();
            await this.updateTtsAvSessionPlaybackState(avSession.PlaybackState.PLAYBACK_STATE_PLAY);
            promptAction.showToast({ message: '继续朗读' });
          } else {
            this.isTtsPaused = true;
          }
        } else {
          this.isTtsPaused = true;
          if (await this.ttsReader.pause()) {
            this.updateTtsFloatingSession();
            await this.updateTtsAvSessionPlaybackState(avSession.PlaybackState.PLAYBACK_STATE_PAUSE);
            promptAction.showToast({ message: '已暂停朗读' });
          } else {
            this.isTtsPaused = false;
          }
        }
      } catch (error) {
        this.isTtsPaused = this.ttsReader.isPaused();
        this.updateTtsFloatingSession();
        console.warn('切换朗读暂停状态失败:', error);
        promptAction.showToast({ message: '切换朗读状态失败' });
      }
      return;
    }
    this.ttsMediaControlsExpanded = false;
    await this.startTtsReadingFromCurrentPosition(true);
  }

  setTtsPagedScrollOverride(enabled: boolean): void {
    const next = enabled && this.readerPageTurnMode === 3 && !this.isReaderComicModeActive();
    if (this.ttsPagedScrollOverride === next) return;
    this.ttsPagedScrollOverride = next;
    this.resetSlidePageEffect();
    if (next) {
      // 取消纵向连续列表尚未执行的定位任务，朗读期间使用原有分页滚动与逐句高亮。
      this.readerComicScrollRestoreSerial++;
      this.readerComicScrollRestoring = false;
    } else if (this.readerPageTurnMode === 3) {
      this.scheduleReaderComicScrollRestore();
    }
  }

  async startTtsReadingFromCurrentPosition(showToast: boolean,
    manualPageTurnResume: boolean = false, manualPageTurnResumeSerial: number = -1): Promise<void> {
    if (!manualPageTurnResume) {
      this.cancelManualPageTurnTtsResume();
    } else if (!this.isManualPageTurnTtsResumeCurrent(manualPageTurnResumeSerial)) {
      return;
    }
    if (this.isReaderComicModeActive()) {
      this.finishTtsReading();
      return;
    }
    this.ttsMediaControlsExpanded = false;
    this.setTtsPagedScrollOverride(true);
    const text = this.getTtsReadingText();
    if (!text) {
      this.finishTtsReading();
      if (showToast) {
        promptAction.showToast({ message: '当前没有可朗读内容' });
      }
      return;
    }
    const token = ++this.ttsReadToken;
    await ReaderTtsFloatingSession.stopOther(this.ttsFloatingSessionOwnerId);
    // A later page turn or explicit stop supersedes this async start. The stale task must not
    // restore auto-continue or tear down the newer page-turn resume that replaced it.
    if (token !== this.ttsReadToken ||
      (manualPageTurnResume && !this.isManualPageTurnTtsResumeCurrent(manualPageTurnResumeSerial))) {
      return;
    }
    this.ttsAutoContinue = true;
    this.isTtsPaused = false;
    this.ttsDisplayText = this.currentPageText;
    this.ttsHighlightStart = -1;
    this.ttsHighlightEnd = -1;
    this.ttsLastFocusChunk = null;
    this.ttsLastFocusPageIndex = -1;
    this.persistTtsReadPosition(this.getCurrentPageStartOffset(), this.getCurrentPageStartOffset());
    try {
      this.isTtsSpeaking = true;
      this.updateVolumeKeySubscription();
      if (manualPageTurnResume) {
        // The page-turn path already scheduled adjacent-page/chapter preloading. Repeating it here
        // competes with the first resumed audio buffer on the UI thread.
        this.preloadReaderContentLater();
      } else {
        this.preloadReaderContent();
      }
      const backgroundStarted = await this.startTtsBackgroundRunning();
      if (!backgroundStarted && showToast) {
        promptAction.showToast({ message: '后台朗读任务启动失败，息屏后可能中断' });
      }
      if (token !== this.ttsReadToken ||
        (manualPageTurnResume && !this.isManualPageTurnTtsResumeCurrent(manualPageTurnResumeSerial))) {
        return;
      }
      if (!this.ttsAutoContinue) {
        if (!manualPageTurnResume) this.stopTtsReading(false);
        return;
      }
      this.publishTtsFloatingSession();
      const cloudVoice = this.findCurrentCloudTtsVoice();
      await this.ttsReader.start(text, {
        onFinished: () => {
          this.continueTtsReading(token).catch((e: Error) => {
            console.warn('连续朗读续播失败:', e);
            if (token === this.ttsReadToken) {
              this.finishTtsReading();
            }
          });
        },
        onError: (message: string) => {
          if (token !== this.ttsReadToken) {
            return;
          }
          this.finishTtsReading();
          promptAction.showToast({ message: message || '系统朗读失败' });
        },
        onChunkStart: (chunk: TtsChunk) => {
          if (token !== this.ttsReadToken) {
            return;
          }
          this.followTtsChunk(chunk);
        },
        onAudioStart: () => {
          if (token !== this.ttsReadToken) {
            return;
          }
          this.onTtsAudioStarted();
        },
        cloudVoiceId: cloudVoice?.id || '',
        cloudVoiceName: cloudVoice?.name || '',
        cloudVoiceTier: cloudVoice?.tier || 'STANDARD',
        person: this.ttsPerson,
        online: this.ttsOnline,
        style: this.ttsStyle,
        language: this.ttsLanguage,
        speed: this.ttsSpeed,
        focusBreakOffsets: this.getTtsFocusBreakOffsets(text.length),
        // Continuous reading should keep one renderer/audio route across
        // chapter boundaries; explicit stop/pause paths still release it.
        keepAudioOutputOnFinish: true
      });
      if (showToast && token === this.ttsReadToken) {
        promptAction.showToast({ message: '开始连续朗读' });
      }
    } catch (error) {
      if (token !== this.ttsReadToken ||
        (manualPageTurnResume && !this.isManualPageTurnTtsResumeCurrent(manualPageTurnResumeSerial))) {
        return;
      }
      this.finishTtsReading();
      promptAction.showToast({ message: '当前系统不支持朗读或 TTS 初始化失败' });
      console.error('启动系统 TTS 失败:', error);
    }
  }

  stopTtsReading(userCancelled: boolean = true): void {
    this.cancelManualPageTurnTtsResume();
    this.flushTtsReadPosition();
    this.clearTtsSleepTimer();
    this.isTtsPaused = false;
    ReaderTtsFloatingSession.clear(this.ttsFloatingSessionOwnerId);
    if (userCancelled) {
      this.ttsAutoContinue = false;
      this.ttsReadToken++;
    }
    this.ttsAutoTurningPage = false;
    this.ttsPendingTargetPageIndex = -1;
    this.ttsPendingHighlightChunk = null;
    this.ttsLastFocusChunk = null;
    this.ttsLastFocusPageIndex = -1;
    this.ttsMediaControlsExpanded = false;
    this.ttsPageTurnSerial++;
    this.stopTtsBackgroundRunning();
    if (!this.isTtsSpeaking && !this.ttsReader.isSpeaking()) {
      this.isTtsSpeaking = false;
      this.updateVolumeKeySubscription();
      this.clearTtsHighlight();
      this.setTtsPagedScrollOverride(false);
      return;
    }
    this.ttsReader.stop();
    this.isTtsSpeaking = false;
    this.updateVolumeKeySubscription();
    this.ttsPageTurnSerial++;
    this.clearTtsHighlight();
    this.ttsLastFocusChunk = null;
    this.ttsLastFocusPageIndex = -1;
    this.setTtsPagedScrollOverride(false);
  }

  stopTtsReaderForChapterSwitch(): void {
    this.cancelManualPageTurnTtsResume();
    this.flushTtsReadPosition();
    this.ttsAutoContinue = false;
    this.isTtsPaused = false;
    this.ttsReadToken++;
    this.ttsAutoTurningPage = false;
    this.ttsPendingTargetPageIndex = -1;
    this.ttsPendingHighlightChunk = null;
    this.ttsLastFocusChunk = null;
    this.ttsLastFocusPageIndex = -1;
    this.ttsPageTurnSerial++;
    this.ttsReader.stop();
    this.isTtsSpeaking = false;
    this.clearTtsHighlight();
    this.setTtsPagedScrollOverride(false);
  }

  clearManualPageTurnTtsResumeTimer(): void {
    if (this.ttsManualPageTurnResumeTimerId < 0) return;
    clearTimeout(this.ttsManualPageTurnResumeTimerId);
    this.ttsManualPageTurnResumeTimerId = -1;
  }

  cancelManualPageTurnTtsResume(): void {
    this.clearManualPageTurnTtsResumeTimer();
    this.ttsManualPageTurnResumeSerial++;
    this.ttsManualPageTurnResumePending = false;
    this.ttsManualPageTurnStartedAt = 0;
  }

  deferManualPageTurnTtsResume(): void {
    this.clearManualPageTurnTtsResumeTimer();
    this.ttsManualPageTurnResumeSerial++;
  }

  isManualPageTurnTtsResumeCurrent(serial: number): boolean {
    return serial >= 0 && this.ttsManualPageTurnResumePending &&
      serial === this.ttsManualPageTurnResumeSerial;
  }

  prepareTtsForManualPageTurn(): void {
    this.deferManualPageTurnTtsResume();
    if (!this.ttsManualPageTurnResumePending) {
      this.ttsManualPageTurnResumePending = true;
      this.ttsManualPageTurnStartedAt = Date.now();
      this.flushTtsReadPosition();
    }
    // This also cancels a deferred start that already passed its debounce window. Previously the
    // early return left that start alive; once it noticed its stale token it performed a full stop
    // and accidentally removed the newest resume timer.
    this.ttsAutoContinue = false;
    this.isTtsPaused = false;
    this.ttsReadToken++;
    this.ttsAutoTurningPage = false;
    this.ttsPendingTargetPageIndex = -1;
    this.ttsPendingHighlightChunk = null;
    this.ttsLastFocusChunk = null;
    this.ttsLastFocusPageIndex = -1;
    this.ttsPageTurnSerial++;
    // Preserve the visible speaking/highlight state while the outgoing page animates. Clearing it
    // here used to rebuild the whole reader subtree immediately before the page-turn animation.
    this.ttsReader.stop();
  }

  scheduleTtsResumeAfterManualPageTurn(): void {
    if (!this.ttsManualPageTurnResumePending) return;
    this.deferManualPageTurnTtsResume();
    const serial = this.ttsManualPageTurnResumeSerial;
    this.ttsManualPageTurnResumeTimerId = setTimeout(() => {
      this.ttsManualPageTurnResumeTimerId = -1;
      if (serial !== this.ttsManualPageTurnResumeSerial || !this.ttsManualPageTurnResumePending) return;
      if (this.isPageTurning || this.queuedPageTurnCount > 0 || this.queuedPageTurnDirection !== 0) {
        this.scheduleTtsResumeAfterManualPageTurn();
        return;
      }
      const startedAt = this.ttsManualPageTurnStartedAt;
      const chapterIndex = this.currentChapterIndex;
      const pageIndex = this.currentPageIndex;
      this.startTtsReadingFromCurrentPosition(false, true, serial)
        .then(() => {
          if (!this.isManualPageTurnTtsResumeCurrent(serial)) return;
          this.ttsManualPageTurnResumePending = false;
          console.info(`[TTS-Turn] resumed chapter=${chapterIndex},page=${pageIndex},` +
            `elapsed=${Math.max(0, Date.now() - startedAt)}ms`);
          this.ttsManualPageTurnStartedAt = 0;
        })
        .catch((error: Error) => {
          if (serial !== this.ttsManualPageTurnResumeSerial) return;
          console.warn('[TTS-Turn] deferred resume failed:', error);
          this.finishTtsReading();
        });
    }, 120);
  }

  async continueTtsReading(token: number): Promise<void> {
    if (token !== this.ttsReadToken || !this.ttsAutoContinue) {
      return;
    }
    if (this.ttsChapterSwitching) {
      return;
    }
    const advanced = await this.advanceTtsReadingToNextChapter();
    if (token !== this.ttsReadToken || !this.ttsAutoContinue) {
      return;
    }
    if (!advanced) {
      this.finishTtsReading();
      return;
    }
    await this.startTtsReadingFromCurrentPosition(false);
  }

  async advanceTtsReadingToNextChapter(): Promise<boolean> {
    if (this.chapters.length === 0 || this.currentChapterIndex >= this.chapters.length - 1) {
      return false;
    }
    if (this.ttsChapterSwitching) {
      return false;
    }
    this.ttsChapterSwitching = true;
    try {
      this.ttsAutoTurningPage = false;
      this.ttsPendingTargetPageIndex = -1;
      this.ttsPendingHighlightChunk = null;
      this.ttsPageTurnSerial++;
      this.currentPageIndex = 0;
      this.pendingRestorePageIndex = 0;
      await this.loadContent(true, this.currentChapterIndex + 1);
      this.persistTtsReadPosition(0, 0);
      await this.saveReadingProgress();
      this.updateTtsFloatingSession();
      await this.updateTtsAvSessionPlaybackState(avSession.PlaybackState.PLAYBACK_STATE_PLAY);
      return true;
    } finally {
      this.ttsChapterSwitching = false;
    }
  }

  async advanceTtsReadingTarget(): Promise<boolean> {
    if (this.chapters.length === 0) {
      return false;
    }
    if (this.canTurnPage(1)) {
      await this.runTtsPageTurnAnimation(1);
      return true;
    }
    return false;
  }

  finishTtsReading(): void {
    this.cancelManualPageTurnTtsResume();
    this.flushTtsReadPosition();
    this.clearTtsSleepTimer();
    this.ttsAutoContinue = false;
    this.isTtsSpeaking = false;
    this.isTtsPaused = false;
    ReaderTtsFloatingSession.clear(this.ttsFloatingSessionOwnerId);
    this.updateVolumeKeySubscription();
    this.ttsMediaControlsExpanded = false;
    this.ttsReader.stop();
    this.stopTtsBackgroundRunning();
    this.ttsPageTurnSerial++;
    this.clearTtsHighlight();
    this.ttsLastFocusChunk = null;
    this.ttsLastFocusPageIndex = -1;
    this.setTtsPagedScrollOverride(false);
    if (!this.readerPageVisible) {
      this.ttsReader.shutdown();
    }
  }

  async loadReaderSettings(): Promise<void> {
    try {
      const settings = await ReaderSettingsStore.load(getContext(this));
      ReaderSettingsStore.applyToStorage(settings);
      this.applyLoadedReaderSettings(settings);
      const registered = await this.registerReaderFontBySettings(
        settings.fontFamily,
        settings.fontFilePath,
        settings.fontSourceName
      );
      if (registered || !this.readerFontFilePath) {
        this.refreshReaderTextRender();
      }
      this.paginateContent(this.content);
    } catch (e) {
      console.warn('读取阅读设置失败:', e);
    }
  }

  async startTtsBackgroundRunning(): Promise<boolean> {
    this.ttsBackgroundDesired = true;
    if (this.ttsBackgroundRunning) {
      if (!this.ttsAvSession && !this.ttsAvSessionRequesting) {
        const agent = await this.createTtsBackgroundWantAgent();
        await this.startTtsAvSession(agent);
      }
      await this.updateTtsAvSessionPlaybackState(this.ttsAvPlaybackState());
      this.startTtsBackgroundHeartbeat();
      return !!this.ttsAvSession;
    }
    if (this.ttsBackgroundRequesting) {
      return this.ttsBackgroundRunning;
    }
    this.ttsBackgroundRequesting = true;
    try {
      const agent = await this.createTtsBackgroundWantAgent();
      await this.startTtsAvSession(agent);
      await backgroundTaskManager.startBackgroundRunning(
        getContext(this),
        ['audioPlayback'],
        agent
      );
      if (this.ttsBackgroundDesired) {
        this.ttsBackgroundRunning = true;
        this.startTtsBackgroundHeartbeat();
        console.info(`[TTS-BG] background audio task started: ${this.ttsBackgroundDebugState()}`);
      } else {
        await backgroundTaskManager.stopBackgroundRunning(getContext(this));
        await this.stopTtsAvSession();
      }
      return this.ttsBackgroundRunning;
    } catch (error) {
      this.ttsBackgroundRunning = false;
      this.stopTtsBackgroundHeartbeat();
      console.warn(`[TTS-BG] start background audio task failed: ${this.formatTtsBackgroundError(error as Object)}; ${this.ttsBackgroundDebugState()}`, error);
      return false;
    } finally {
      this.ttsBackgroundRequesting = false;
    }
  }

  async stopTtsBackgroundRunning(): Promise<void> {
    this.ttsBackgroundDesired = false;
    this.stopTtsBackgroundHeartbeat();
    await this.stopTtsAvSession();
    if (!this.ttsBackgroundRunning && !this.ttsBackgroundRequesting) {
      return;
    }
    if (this.ttsBackgroundRequesting && !this.ttsBackgroundRunning) {
      return;
    }
    this.ttsBackgroundRunning = false;
    if (this.fullTextCaching) {
      this.fullTextCacheBackgroundRunning = true;
      return;
    }
    if (this.fullTextCacheBackgroundRunning) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(getContext(this));
      console.info(`[TTS-BG] background audio task stopped: ${this.ttsBackgroundDebugState()}`);
    } catch (error) {
      console.warn(`[TTS-BG] stop background audio task failed: ${this.formatTtsBackgroundError(error as Object)}; ${this.ttsBackgroundDebugState()}`, error);
    }
  }

  startTtsBackgroundHeartbeat(): void {
    if (this.ttsBackgroundHeartbeatId >= 0) {
      return;
    }
    this.ttsBackgroundHeartbeatId = setInterval(() => {
      this.keepTtsBackgroundAlive().catch((error: Error) => {
        console.warn(`[TTS-BG] heartbeat failed: ${this.formatTtsBackgroundError(error as Object)}; ${this.ttsBackgroundDebugState()}`, error);
      });
    }, 30000);
  }

  stopTtsBackgroundHeartbeat(): void {
    if (this.ttsBackgroundHeartbeatId < 0) {
      return;
    }
    clearInterval(this.ttsBackgroundHeartbeatId);
    this.ttsBackgroundHeartbeatId = -1;
  }

  async keepTtsBackgroundAlive(): Promise<void> {
    if (!this.ttsBackgroundDesired || (!this.isTtsSpeaking && !this.ttsReader.isSpeaking())) {
      this.stopTtsBackgroundHeartbeat();
      return;
    }
    if (!this.ttsBackgroundRunning && !this.ttsBackgroundRequesting) {
      await this.startTtsBackgroundRunning();
      return;
    }
    await this.syncTtsSystemMediaControls();
    const now = Date.now();
    if (now - this.ttsBackgroundLastLogAt >= 120000) {
      this.ttsBackgroundLastLogAt = now;
      console.info(`[TTS-BG] heartbeat: ${this.ttsBackgroundDebugState()}`);
    }
  }

  onTtsAudioStarted(): void {
    console.info(`[TTS-BG] audio started: ${this.ttsBackgroundDebugState()}`);
    this.refreshTtsBackgroundAfterAudioStarted().catch((error: Error) => {
      console.warn(`[TTS-BG] refresh after audio started failed: ${this.formatTtsBackgroundError(error as Object)}; ${this.ttsBackgroundDebugState()}`, error);
    });
  }

  async refreshTtsBackgroundAfterAudioStarted(): Promise<void> {
    if (!this.ttsBackgroundRunning && !this.ttsBackgroundRequesting) {
      await this.startTtsBackgroundRunning();
      return;
    }
    await this.syncTtsSystemMediaControls();
  }

  async startTtsAvSession(agent: WantAgent): Promise<void> {
    if (this.ttsAvSessionRequesting) {
      return;
    }
    this.ttsAvSessionRequesting = true;
    try {
      if (!this.ttsAvSession) {
        this.ttsAvSession = await avSession.createAVSession(getContext(this), 'LegadoReaderTts', 'audio');
        this.registerTtsAvSessionCommands(this.ttsAvSession);
      }
      await this.ttsAvSession.setLaunchAbility(agent);
      await this.ttsAvSession.setAVQueueTitle(this.book?.name || '听书');
      await this.refreshTtsMediaImage();
      await this.ttsAvSession.setAVMetadata(this.getTtsAvMetadata());
      await this.ttsAvSession.setExtras({
        bookUrl: this.bookUrl || '',
        chapterIndex: this.currentChapterIndex,
        chapterTitle: this.getChapterTitle()
      });
      await this.updateTtsAvSessionPlaybackState(this.ttsAvPlaybackState());
      await this.ttsAvSession.activate();
      await this.syncTtsSystemMediaControls();
      console.info(`[TTS-BG] AVSession activated: ${this.ttsBackgroundDebugState()}`);
    } catch (error) {
      console.warn(`[TTS-BG] start AVSession failed: ${this.formatTtsBackgroundError(error as Object)}; ${this.ttsBackgroundDebugState()}`, error);
    } finally {
      this.ttsAvSessionRequesting = false;
    }
  }

  registerTtsAvSessionCommands(session: avSession.AVSession): void {
    session.on('play', () => {
      if (this.isTtsPaused || this.ttsReader.isPaused()) {
        this.toggleTtsReading();
      } else if (!this.isTtsSpeaking && !this.ttsReader.isSpeaking()) {
        this.startTtsReadingFromCurrentPosition(false);
      }
    });
    session.on('pause', () => {
      if (!this.isTtsPaused && (this.isTtsSpeaking || this.ttsReader.isSpeaking())) {
        this.toggleTtsReading();
      }
    });
    session.on('stop', () => {
      this.stopTtsReading();
    });
    session.on('playNext', () => {
      this.playNextChapterFromMediaSession();
    });
    session.on('playPrevious', () => {
      this.playPreviousChapterFromMediaSession();
    });
    session.on('setSpeed', (speed: number) => {
      this.applyTtsSpeed(speed);
    });
  }

  unregisterTtsAvSessionCommands(session: avSession.AVSession): void {
    try { session.off('play'); } catch (_) {}
    try { session.off('pause'); } catch (_) {}
    try { session.off('stop'); } catch (_) {}
    try { session.off('playNext'); } catch (_) {}
    try { session.off('playPrevious'); } catch (_) {}
    try { session.off('setSpeed'); } catch (_) {}
  }

  async playNextChapterFromMediaSession(): Promise<void> {
    if (!this.canPlayNextTtsChapter()) {
      return;
    }
    const sourceChapterIndex = this.currentChapterIndex;
    const sourcePageIndex = this.currentPageIndex;
    const targetChapterIndex = sourceChapterIndex + 1;
    const now = Date.now();
    if (this.ttsChapterSwitching || now - this.ttsLastMediaChapterCommandAt < 1000) {
      return;
    }
    this.ttsLastMediaChapterCommandAt = now;
    this.ttsChapterSwitching = true;
    try {
      const shouldResume = this.isTtsSpeaking || this.ttsReader.isSpeaking() ||
        ReaderTtsFloatingSession.isOwner(this.ttsFloatingSessionOwnerId);
      console.info(`[TTS] media next chapter: source=${sourceChapterIndex},target=${targetChapterIndex},` +
        `resume=${shouldResume}`);
      if (shouldResume) {
        this.stopTtsReaderForChapterSwitch();
        await this.updateTtsAvSessionPlaybackState(avSession.PlaybackState.PLAYBACK_STATE_BUFFERING);
      } else {
        this.stopTtsReading();
      }
      this.currentPageIndex = 0;
      this.pendingRestorePageIndex = 0;
      await this.loadContent(true, targetChapterIndex);
      const switched = this.currentChapterIndex === targetChapterIndex;
      if (switched) {
        await this.saveReadingProgress();
      } else {
        this.currentPageIndex = sourcePageIndex;
        this.pendingRestorePageIndex = sourcePageIndex;
        if (this.currentChapterIndex !== sourceChapterIndex) {
          await this.loadContent(true, sourceChapterIndex);
        } else {
          this.syncCurrentPageText();
        }
        console.warn(`[TTS] next chapter switch did not reach target: target=${targetChapterIndex},` +
          `actual=${this.currentChapterIndex}`);
        promptAction.showToast({ message: '下一章加载失败，已保留当前朗读位置' });
      }
      if (shouldResume) {
        await this.startTtsReadingFromCurrentPosition(false);
      } else {
        await this.updateTtsAvSessionPlaybackState(avSession.PlaybackState.PLAYBACK_STATE_STOP);
      }
    } finally {
      this.ttsChapterSwitching = false;
    }
  }

  async playPreviousChapterFromMediaSession(): Promise<void> {
    if (!this.canPlayPreviousTtsChapter()) {
      return;
    }
    const sourceChapterIndex = this.currentChapterIndex;
    const sourcePageIndex = this.currentPageIndex;
    const targetChapterIndex = sourceChapterIndex - 1;
    const now = Date.now();
    if (this.ttsChapterSwitching || now - this.ttsLastMediaChapterCommandAt < 1000) {
      return;
    }
    this.ttsLastMediaChapterCommandAt = now;
    this.ttsChapterSwitching = true;
    try {
      const shouldResume = this.isTtsSpeaking || this.ttsReader.isSpeaking() ||
        ReaderTtsFloatingSession.isOwner(this.ttsFloatingSessionOwnerId);
      console.info(`[TTS] media previous chapter: source=${sourceChapterIndex},target=${targetChapterIndex},` +
        `resume=${shouldResume}`);
      if (shouldResume) {
        this.stopTtsReaderForChapterSwitch();
        await this.updateTtsAvSessionPlaybackState(avSession.PlaybackState.PLAYBACK_STATE_BUFFERING);
      } else {
        this.stopTtsReading();
      }
      this.currentPageIndex = 0;
      this.pendingRestorePageIndex = 0;
      await this.loadContent(true, targetChapterIndex);
      const switched = this.currentChapterIndex === targetChapterIndex;
      if (switched) {
        await this.saveReadingProgress();
      } else {
        this.currentPageIndex = sourcePageIndex;
        this.pendingRestorePageIndex = sourcePageIndex;
        if (this.currentChapterIndex !== sourceChapterIndex) {
          await this.loadContent(true, sourceChapterIndex);
        } else {
          this.syncCurrentPageText();
        }
        console.warn(`[TTS] previous chapter switch did not reach target: target=${targetChapterIndex},` +
          `actual=${this.currentChapterIndex}`);
        promptAction.showToast({ message: '上一章加载失败，已保留当前朗读位置' });
      }
      if (shouldResume) {
        await this.startTtsReadingFromCurrentPosition(false);
      } else {
        await this.updateTtsAvSessionPlaybackState(avSession.PlaybackState.PLAYBACK_STATE_STOP);
      }
    } finally {
      this.ttsChapterSwitching = false;
    }
  }

  async playPositionFromFloatingSession(targetChapterIndex: number, targetPageIndex: number): Promise<void> {
    const normalizedChapterIndex = this.clampChapterIndex(targetChapterIndex);
    const normalizedPageIndex = Math.max(0, Math.round(targetPageIndex));
    if (normalizedChapterIndex === this.currentChapterIndex && normalizedPageIndex === this.currentPageIndex) {
      return;
    }
    const sourceChapterIndex = this.currentChapterIndex;
    const sourcePageIndex = this.currentPageIndex;
    const now = Date.now();
    if (this.ttsChapterSwitching || now - this.ttsLastMediaChapterCommandAt < 500) {
      return;
    }
    this.ttsLastMediaChapterCommandAt = now;
    this.ttsChapterSwitching = true;
    try {
      const shouldResume = this.isTtsSpeaking || this.ttsReader.isSpeaking() ||
        ReaderTtsFloatingSession.isOwner(this.ttsFloatingSessionOwnerId);
      console.info(`[TTS] floating position: source=${sourceChapterIndex}/${sourcePageIndex},` +
        `target=${normalizedChapterIndex}/${normalizedPageIndex},resume=${shouldResume}`);
      if (shouldResume) {
        this.stopTtsReaderForChapterSwitch();
        await this.updateTtsAvSessionPlaybackState(avSession.PlaybackState.PLAYBACK_STATE_BUFFERING);
      }
      this.currentPageIndex = normalizedPageIndex;
      this.pendingRestorePageIndex = normalizedPageIndex;
      await this.loadContent(true, normalizedChapterIndex);
      const switched = this.currentChapterIndex === normalizedChapterIndex;
      if (switched) {
        this.currentPageIndex = this.normalizeReaderSpreadPageIndex(
          Math.min(normalizedPageIndex, Math.max(0, this.contentPages.length - 1)));
        this.pendingRestorePageIndex = -1;
        this.syncCurrentPageText();
        await this.saveReadingProgress();
      } else {
        this.currentPageIndex = sourcePageIndex;
        this.pendingRestorePageIndex = sourcePageIndex;
        if (this.currentChapterIndex !== sourceChapterIndex) {
          await this.loadContent(true, sourceChapterIndex);
        } else {
          this.syncCurrentPageText();
        }
        promptAction.showToast({ message: '章节加载失败，已保留当前朗读位置' });
      }
      if (shouldResume) {
        await this.startTtsReadingFromCurrentPosition(false);
      }
    } finally {
      this.ttsChapterSwitching = false;
    }
  }

  async updateTtsAvSessionPlaybackState(state: avSession.PlaybackState): Promise<void> {
    if (!this.ttsAvSession) {
      return;
    }
    try {
      await this.refreshTtsMediaImage();
      await this.ttsAvSession.setAVMetadata(this.getTtsAvMetadata());
      await this.ttsAvSession.setAVPlaybackState({
        state: state,
        speed: AppStorage.get<number>('ttsSpeed') || 1,
        position: {
          elapsedTime: this.getTtsPlaybackElapsedTime(),
          updateTime: Date.now()
        },
        bufferedTime: this.getTtsPlaybackDuration(),
        loopMode: avSession.LoopMode.LOOP_MODE_SEQUENCE,
        activeItemId: this.currentChapterIndex
      });
      if (state === avSession.PlaybackState.PLAYBACK_STATE_PLAY ||
        state === avSession.PlaybackState.PLAYBACK_STATE_BUFFERING) {
        await this.ttsAvSession.activate();
      }
    } catch (error) {
      console.warn(`[TTS-BG] update AVSession playback state failed: ${this.formatTtsBackgroundError(error as Object)}; ${this.ttsBackgroundDebugState()}`, error);
    }
  }

  async syncTtsSystemMediaControls(): Promise<void> {
    if (!this.isTtsSpeaking && !this.ttsReader.isSpeaking()) {
      return;
    }
    try {
      if (!this.ttsAvSession) {
        await this.startTtsBackgroundRunning();
        return;
      }
      await this.ttsAvSession.activate();
      await this.updateTtsAvSessionPlaybackState(this.ttsAvPlaybackState());
    } catch (error) {
      console.warn(`[TTS-BG] sync media controls failed: ${this.formatTtsBackgroundError(error as Object)}; ${this.ttsBackgroundDebugState()}`, error);
    }
  }

  ttsAvPlaybackState(): avSession.PlaybackState {
    return this.isTtsPaused || this.ttsReader.isPaused() ?
      avSession.PlaybackState.PLAYBACK_STATE_PAUSE : avSession.PlaybackState.PLAYBACK_STATE_PLAY;
  }

  getTtsAvMetadata(): avSession.AVMetadata {
    const metadata: avSession.AVMetadata = {
      assetId: this.getTtsAvAssetId(),
      title: this.book?.name || '朗读',
      subtitle: this.getTtsAvSubtitle(),
      artist: this.book?.author || '阅读',
      author: this.book?.author || '阅读',
      album: this.book?.name || '听书',
      duration: this.getTtsPlaybackDuration(),
      previousAssetId: this.canPlayPreviousTtsChapter() ? this.getTtsChapterAssetId(this.currentChapterIndex - 1) : '',
      nextAssetId: this.canPlayNextTtsChapter() ? this.getTtsChapterAssetId(this.currentChapterIndex + 1) : '',
      avQueueName: this.book?.name || '听书',
      avQueueId: this.bookUrl || 'reader_tts'
    };
    if (this.ttsMediaPixelMap) {
      metadata.mediaImage = this.ttsMediaPixelMap;
      metadata.avQueueImage = this.ttsMediaPixelMap;
    } else if (this.ttsMediaImage) {
      metadata.mediaImage = this.ttsMediaImage;
      metadata.avQueueImage = this.ttsMediaImage;
    }
    return metadata;
  }

  async refreshTtsMediaImage(): Promise<void> {
    const serial = ++this.ttsMediaImageRefreshSerial;
    const raw = this.getBookshelfDisplayCoverRaw();
    if (raw && raw === this.ttsMediaImageRaw && this.ttsMediaPixelMap) {
      return;
    }
    if (!raw) {
      if (serial === this.ttsMediaImageRefreshSerial) {
        this.ttsMediaImage = '';
        this.ttsMediaImageRaw = '';
        this.releaseTtsMediaPixelMap();
      }
      return;
    }
    let resolved = raw;
    let pixelMap: image.PixelMap | null = null;
    try {
      const context = getContext(this);
      const coverPath = await BookCoverCache.prepareCoverFile(context, raw);
      if (coverPath) {
        pixelMap = await this.createTtsMediaPixelMap(coverPath);
        resolved = pixelMap ? coverPath : await BookCoverCache.resolveCover(context, raw);
      } else {
        resolved = await BookCoverCache.resolveCover(context, raw);
      }
    } catch (error) {
      console.warn('解析朗读媒体封面失败:', error);
    }
    if (serial === this.ttsMediaImageRefreshSerial) {
      this.releaseTtsMediaPixelMap();
      this.ttsMediaImage = resolved || raw;
      this.ttsMediaImageRaw = raw;
      this.ttsMediaPixelMap = pixelMap;
    } else if (pixelMap) {
      pixelMap.release().catch((e: Error) => {
        console.warn('释放过期朗读媒体封面失败:', e);
      });
    }
  }

  async createTtsMediaPixelMap(path: string): Promise<image.PixelMap | null> {
    let file: fs.File | null = null;
    let source: image.ImageSource | null = null;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      source = image.createImageSource(file.fd);
      return await source.createPixelMap({
        desiredSize: {
          width: 512,
          height: 512
        }
      });
    } catch (error) {
      console.warn('创建朗读媒体封面 PixelMap 失败:', error);
      return null;
    } finally {
      if (source) {
        try {
          await source.release();
        } catch (e) {
        }
      }
      if (file) {
        try {
          fs.closeSync(file);
        } catch (e) {
        }
      }
    }
  }

  releaseTtsMediaPixelMap(): void {
    if (!this.ttsMediaPixelMap) {
      return;
    }
    try {
      this.ttsMediaPixelMap.release().catch((e: Error) => {
        console.warn('释放朗读媒体封面失败:', e);
      });
    } catch (e) {
      console.warn('释放朗读媒体封面失败:', e);
    }
    this.ttsMediaPixelMap = null;
  }

  shouldUseTtsThemeBookCover(): boolean {
    return this.themeBookCoverEnabled &&
      ThemeAssetRegistry.themeBookCovers(ThemeRuntime.bookTokens(this.appDarkMode).coverAssetId).length > 0;
  }

  activeTtsThemeBookCovers(): ResourceStr[] {
    const covers = ThemeAssetRegistry.themeBookCovers(ThemeRuntime.bookTokens(this.appDarkMode).coverAssetId);
    if (covers.length <= 1) {
      return covers;
    }
    const result: ResourceStr[] = [];
    const seed = this.ttsThemeBookCoverSeed();
    const start = seed % covers.length;
    const direction = seed % 2 === 0 ? 1 : covers.length - 1;
    for (let index = 0; index < covers.length; index++) {
      result.push(covers[(start + index * direction) % covers.length]);
    }
    return result;
  }

  ttsThemeBookCoverSeed(): number {
    const key = `${this.book?.bookUrl || this.bookUrl}|${this.book?.name || ''}|${this.book?.author || ''}`;
    let hash = 17;
    for (let index = 0; index < key.length; index++) {
      hash = (hash * 31 + key.charCodeAt(index)) & 0x7FFFFFFF;
    }
    return hash;
  }

  ttsThemeBookCoverInterval(): number {
    return 3200 + this.ttsThemeBookCoverSeed() % 5 * 420;
  }

  activeTtsThemeShelfFrame(): ResourceStr {
    return ThemeAssetRegistry.themeShelfFrame(ThemeRuntime.bookTokens(this.appDarkMode).shelfFrameAssetId);
  }

  getTtsPanelCoverList(): string[] {
    if (!this.book) {
      return [];
    }
    const covers = CoverGallerySettings.getDisplayCoverList(
      this.book,
      this.appDarkMode,
      this.bookshelfCoverAlbums,
      this.bookshelfLightCoverAlbumId,
      this.bookshelfDarkCoverAlbumId,
      this.bookshelfCoverApplyScope,
      this.bookshelfCoverTargetBooks,
      this.bookshelfIgnoreSourceCover,
      this.bookshelfCoverMode
    );
    const displayCovers: string[] = [];
    const context = getContext(this);
    for (const raw of covers) {
      const cached = BookCoverCache.resolveCachedCover(context, raw);
      displayCovers.push(cached || raw);
    }
    return displayCovers;
  }

  getTtsFloatingCover(): ResourceStr {
    if (this.shouldUseTtsThemeBookCover()) {
      const themeCovers = this.activeTtsThemeBookCovers();
      return themeCovers.length > 0 ? themeCovers[0] : '';
    }
    const covers = this.getTtsPanelCoverList();
    return covers.length > 0 ? covers[0] : '';
  }

  getTtsCoverPlaceholderColor(): string {
    const name = this.book?.name || '';
    if (!name) return '#007DFF';
    const colors: string[] = ['#007DFF', '#E53935', '#43A047', '#EF6C00',
      '#8E24AA', '#00ACC1', '#D81B60', '#5E35B1'];
    let hash = 0;
    for (let index = 0; index < name.length; index++) {
      hash = name.charCodeAt(index) + ((hash << 5) - hash);
    }
    return colors[Math.abs(hash) % colors.length];
  }

  getBookshelfDisplayCoverRaw(): string {
    if (!this.book) {
      return '';
    }
    const albumCover = this.getTtsGalleryCoverRaw();
    if (albumCover) {
      return albumCover;
    }
    const covers = CoverGallerySettings.getDisplayCoverList(
      this.book,
      this.appDarkMode,
      this.bookshelfCoverAlbums,
      this.bookshelfLightCoverAlbumId,
      this.bookshelfDarkCoverAlbumId,
      this.bookshelfCoverApplyScope,
      this.bookshelfCoverTargetBooks,
      this.bookshelfIgnoreSourceCover,
      this.bookshelfCoverMode
    );
    return this.pickStableTtsCover(covers);
  }

  getTtsGalleryCoverRaw(): string {
    if (!this.book) {
      return '';
    }
    if (this.bookshelfCoverApplyScope === 'books' &&
      !CoverGallerySettings.parseTargetBooks(this.bookshelfCoverTargetBooks).includes(this.book.bookUrl)) {
      return '';
    }
    const albumId = CoverGallerySettings.selectedAlbumId(
      this.appDarkMode,
      this.bookshelfLightCoverAlbumId,
      this.bookshelfDarkCoverAlbumId
    );
    const album = CoverGallerySettings.getAlbum(CoverGallerySettings.parseAlbums(this.bookshelfCoverAlbums), albumId);
    return album ? this.pickStableTtsCover(album.covers) : '';
  }

  pickStableTtsCover(covers: string[]): string {
    const cleaned: string[] = [];
    for (const cover of covers) {
      const value = (cover || '').trim();
      if (value && !cleaned.includes(value)) {
        cleaned.push(value);
      }
    }
    if (cleaned.length === 0) {
      return '';
    }
    if (cleaned.length === 1) {
      return cleaned[0];
    }
    const seed = `${this.bookUrl || this.book?.bookUrl || ''}_${this.book?.name || ''}_` +
      `${this.appDarkMode}_${this.bookshelfLightCoverAlbumId}_${this.bookshelfDarkCoverAlbumId}_` +
      `${this.bookshelfCoverMode}`;
    return cleaned[Math.abs(this.hashTtsText(seed)) % cleaned.length];
  }

  hashTtsText(value: string): number {
    let hash = 0;
    for (let i = 0; i < value.length; i++) {
      hash = value.charCodeAt(i) + ((hash << 5) - hash);
    }
    return hash;
  }

  getTtsPlaybackElapsedTime(): number {
    const pageCount = Math.max(this.contentPages.length, 1);
    const clampedPageIndex = Math.max(0, Math.min(this.currentPageIndex, pageCount - 1));
    return Math.round((clampedPageIndex / pageCount) * this.getTtsPlaybackDuration());
  }

  getTtsPlaybackDuration(): number {
    const charCount = Math.max((this.content || this.currentPageText || '').length, 1);
    const charsPerMinute = 260 * Math.max(this.ttsSpeed || 1, 0.5);
    return Math.max(60000, Math.round((charCount / charsPerMinute) * 60000));
  }

  getTtsAvAssetId(): string {
    return `${this.getTtsChapterAssetId(this.currentChapterIndex)}_${this.currentPageIndex}_${this.getTtsMediaImageIdentity()}`;
  }

  getTtsChapterAssetId(chapterIndex: number): string {
    return `${this.bookUrl || 'reader_tts'}_${chapterIndex}`;
  }

  getTtsMediaImageIdentity(): string {
    const value = this.ttsMediaImageRaw || this.ttsMediaImage || 'cover';
    let hash = 0;
    for (let i = 0; i < value.length; i++) {
      hash = value.charCodeAt(i) + ((hash << 5) - hash);
    }
    return Math.abs(hash).toString(16);
  }

  getTtsAvSubtitle(): string {
    const progress = this.getProgressText();
    const chapter = this.getChapterTitle();
    return progress ? `${chapter} · ${progress}` : chapter;
  }

  async stopTtsAvSession(): Promise<void> {
    if (!this.ttsAvSession) {
      return;
    }
    const session = this.ttsAvSession;
    this.ttsAvSession = null;
    this.unregisterTtsAvSessionCommands(session);
    try {
      await session.setAVPlaybackState({
        state: avSession.PlaybackState.PLAYBACK_STATE_STOP
      });
    } catch (error) {
      console.warn(`[TTS-BG] mark AVSession stopped failed: ${this.formatTtsBackgroundError(error as Object)}`, error);
    }
    try {
      await session.deactivate();
    } catch (error) {
      console.warn(`[TTS-BG] deactivate AVSession failed: ${this.formatTtsBackgroundError(error as Object)}`, error);
    }
    try {
      await session.destroy();
      console.info('[TTS-BG] AVSession destroyed');
    } catch (error) {
      console.warn(`[TTS-BG] destroy AVSession failed: ${this.formatTtsBackgroundError(error as Object)}`, error);
    } finally {
      this.ttsMediaImage = '';
      this.ttsMediaImageRaw = '';
      this.releaseTtsMediaPixelMap();
    }
  }

  async createTtsBackgroundWantAgent(): Promise<WantAgent> {
    const context = getContext(this) as common.UIAbilityContext;
    return await wantAgent.getWantAgent({
      wants: [{
        bundleName: context.abilityInfo.bundleName,
        abilityName: 'EntryAbility'
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 1001,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
  }

  ttsBackgroundDebugState(): string {
    return `desired=${this.ttsBackgroundDesired},running=${this.ttsBackgroundRunning},requesting=${this.ttsBackgroundRequesting},speaking=${this.isTtsSpeaking},readerSpeaking=${this.ttsReader.isSpeaking()},avSession=${this.ttsAvSession ? 'yes' : 'no'},audio=${this.ttsReader.audioDebugState()}`;
  }

  formatTtsBackgroundError(error: Object | null | undefined): string {
    if (!error) {
      return 'unknown';
    }
    const record = error as Record<string, Object>;
    const code = record['code'];
    const message = record['message'];
    const parts: string[] = [];
    if (code !== undefined) {
      parts.push(`code=${String(code)}`);
    }
    if (message !== undefined) {
      parts.push(`message=${String(message)}`);
    }
    return parts.length > 0 ? parts.join(',') : String(error);
  }

  clearTtsHighlight(): void {
    if (!this.ttsDisplayText && this.ttsHighlightStart < 0 && this.ttsHighlightEnd < 0 &&
      this.ttsTextStartOffset === 0) {
      return;
    }
    this.ttsDisplayText = '';
    this.ttsHighlightStart = -1;
    this.ttsHighlightEnd = -1;
    this.ttsTextStartOffset = 0;
    this.ttsHighlightRenderVersion++;
    this.scrollTtsPanelToCurrentSentence();
  }

  getTtsReadingText(): string {
    const start = this.getCurrentPageStartOffset();
    this.ttsTextStartOffset = start;
    const source = this.pagedContentText || this.getPagedSourceText();
    return ReaderActionMarker.strip(LocalBookService.stripEpubImageMarkers(source.substring(start), true), true);
  }

  getTtsFocusBreakOffsets(textLength: number): number[] {
    const result: number[] = [];
    for (const pageStart of this.contentPageStarts) {
      const offset = pageStart - this.ttsTextStartOffset;
      if (offset > 0 && offset < textLength) {
        result.push(offset);
      }
    }
    return result;
  }

  normalizeReaderText(text: string): string {
    return this.trimReaderContentText((text || '')
      .replace(/\r\n/g, '\n')
      .replace(/\u00A0/g, ' ')
      .replace(/\n{3,}/g, '\n\n'));
  }

  getPagedSourceText(): string {
    return this.buildPagedSourceText(this.currentChapterIndex, this.content || '');
  }

  buildPagedSourceText(chapterIndex: number, content: string): string {
    const title = this.getChapterTitle(chapterIndex).trim();
    const leadingAction = ReaderActionMarker.findFirst(content || '');
    const titleAction = leadingAction && leadingAction.start === 0 && leadingAction.data.title === '章评' ?
      leadingAction.marker : '';
    const contentBody = titleAction && leadingAction ?
      (content || '').substring(leadingAction.end).replace(/^\s+/, '') :
      (content || '');
    const sourceBody = this.stripDuplicatedChapterTitle(this.normalizeChapterBody(contentBody), title);
    const body = this.buildIndentedChapterBody(sourceBody);
    if (LocalBookService.hasEpubImageMarkers(body) &&
      !LocalBookService.stripEpubImageMarkers(body).trim()) {
      return body;
    }
    if (!title) {
      return body;
    }
    return titleAction ? `${title}${titleAction}\n\n${body}` : `${title}\n\n${body}`;
  }

  normalizeChapterBody(text: string): string {
    return this.mergeSoftWrappedChapterLines(this.trimReaderContentText((text || '')
      .replace(/\r\n/g, '\n')
      .replace(/\u00A0/g, ' ')
      .replace(/\n{3,}/g, '\n\n')));
  }

  mergeSoftWrappedChapterLines(text: string): string {
    if (!text || text.indexOf('\n') < 0) {
      return text;
    }
    const rawLines = text.split('\n');
    const result: string[] = [];
    let current = '';
    for (const rawLine of rawLines) {
      const line = rawLine.trim();
      if (!line) {
        if (current) {
          result.push(current);
          current = '';
        }
        if (result.length > 0 && result[result.length - 1] !== '') {
          result.push('');
        }
        continue;
      }
      if (!current) {
        current = line;
        continue;
      }
      if (this.shouldMergeReaderSoftLine(current, rawLine)) {
        current += this.readerSoftLineJoiner(current, line) + line;
      } else {
        result.push(current);
        current = line;
      }
    }
    if (current) {
      result.push(current);
    }
    return result.join('\n').replace(/\n{3,}/g, '\n\n').trim();
  }

  readerSoftLineJoiner(previous: string, next: string): string {
    const left = (previous || '').trim();
    const right = (next || '').trim();
    if (!left || !right || /[-‐‑‒–—]$/.test(left)) {
      return '';
    }
    return /[A-Za-z0-9,.:;\'"）)\]]$/.test(left) && /^[A-Za-z0-9]/.test(right) ? ' ' : '';
  }

  shouldMergeReaderSoftLine(previous: string, nextRaw: string): boolean {
    const prev = (previous || '').trim();
    const next = (nextRaw || '').trim();
    if (ReaderActionMarker.has(prev) || ReaderActionMarker.has(next)) {
      return false;
    }
    if (!prev || !next) {
      return false;
    }
    if (/^[　\s]/.test(nextRaw)) {
      return false;
    }
    if (/^[第卷章节回番外序楔引]\s*[\d一二三四五六七八九十百千万零〇壹贰叁肆伍陆柒捌玖拾]/.test(next)) {
      return false;
    }
    if (/^[，,。！？!?；;：:、」』”）)]/.test(next)) {
      return true;
    }
    if (/[。！？!?；;」』”）)]$/.test(prev)) {
      return false;
    }
    return prev.length < 48 && next.length < 48;
  }

  buildIndentedChapterBody(text: string): string {
    const normalized = this.normalizeChapterBody(text);
    if (!normalized) {
      return '';
    }
    return normalized
      .split('\n')
      .map((line: string) => this.indentReaderLine(line))
      .join('\n');
  }

  indentReaderLine(line: string): string {
    if (!line || line.trim().length === 0) {
      return line;
    }
    const trimmed = line.trim();
    // 图片标记是结构数据，不是正文段落；给它添加两个全角空格会被分页器拆成一张不可见的文本页。
    if (LocalBookService.isEpubImageMarker(trimmed)) {
      return trimmed;
    }
    if (line.startsWith('　　')) {
      return line;
    }
    return `　　${line.replace(/^[　\s]+/g, '')}`;
  }

  stripDuplicatedChapterTitle(body: string, title: string): string {
    if (!body || !title) {
      return body;
    }
    const lines = body.split('\n');
    const firstLine = (lines[0] || '').replace(/^[　\s]+/g, '').trim();
    if (firstLine !== title) {
      return body;
    }
    return this.trimReaderContentText(lines.slice(1).join('\n').replace(/^\n+/, ''));
  }

  isReaderTrimChar(value: string): boolean {
    return value === ' ' || value === '\t' || value === '\n' || value === '\r' ||
      value === '\u00A0' || value === '\u3000' || value === '\uFEFF' || value === '\u200B' ||
      value === '\u200C' || value === '\u200D' || value === '\u2060';
  }

  isReaderEdgeTrimChar(value: string): boolean {
    return this.isReaderTrimChar(value) || value === '\u3000';
  }

  trimReaderContentText(text: string): string {
    const source = text || '';
    let start = 0;
    let end = source.length;
    while (start < end && this.isReaderEdgeTrimChar(source.charAt(start))) {
      start++;
    }
    while (end > start && this.isReaderEdgeTrimChar(source.charAt(end - 1))) {
      end--;
    }
    return source.substring(start, end);
  }

  pushReaderPage(source: string, rawStart: number, rawEnd: number, pages: string[], starts: number[], ends: number[]): void {
    let pageStart = Math.max(0, Math.min(rawStart, source.length));
    let pageEnd = Math.max(pageStart, Math.min(rawEnd, source.length));
    while (pageStart < pageEnd && this.isReaderTrimChar(source.charAt(pageStart))) {
      pageStart++;
    }
    while (pageEnd > pageStart && this.isReaderTrimChar(source.charAt(pageEnd - 1))) {
      pageEnd--;
    }
    const pageText = source.substring(pageStart, pageEnd);
    if (!pageText) {
      return;
    }
    pages.push(pageText);
    starts.push(pageStart);
    ends.push(pageEnd);
  }

  adjustReaderActionMarkerPageEnd(source: string, start: number, rawEnd: number): number {
    const end = Math.max(start + 1, Math.min(rawEnd, source.length));
    let searchStart = start;
    while (searchStart < end) {
      let markerStart = -1;
      for (const prefix of [ReaderActionMarker.PREFIX, ReaderActionMarker.LEGACY_PREFIX,
        ReaderActionMarker.ORIGINAL_PREFIX]) {
        const index = source.indexOf(prefix, searchStart);
        if (index >= 0 && (markerStart < 0 || index < markerStart)) markerStart = index;
      }
      if (markerStart < 0) return end;
      const suffix = source.indexOf(ReaderActionMarker.SUFFIX, markerStart);
      if (suffix < 0) return end;
      const markerEnd = suffix + ReaderActionMarker.SUFFIX.length;
      const previousChar = markerStart > 0 ? source.charAt(markerStart - 1) : '';
      const inlineMarker = markerStart > 0 && previousChar !== '\n' && previousChar !== '\r';
      if (markerStart === end) {
        return inlineMarker ? markerEnd : end;
      }
      if (markerStart > end) return end;
      if (end < markerEnd) {
        return inlineMarker ? markerEnd : (markerStart > start ? markerStart : markerEnd);
      }
      searchStart = markerEnd;
    }
    return end;
  }

  findMeasuredPageEnd(source: string, start: number, availableWidth: number, availableHeight: number,
    chapterIndex: number = this.currentChapterIndex): number {
    let safeStart = Math.max(0, Math.min(start, source.length));
    while (safeStart < source.length && this.isReaderTrimChar(source.charAt(safeStart))) {
      safeStart++;
    }
    if (safeStart >= source.length) {
      return source.length;
    }

    // All content uses the same block paginator. The previous pure-text path could repeatedly rebuild every
    // earlier paragraph when paragraph spacing was enabled, while interactive text already measured complete
    // paragraphs once. Keeping one algorithm makes the inexpensive path available to every source.
    const blockWindowEnd = Math.min(source.length, safeStart + Math.max(4000,
      this.getReaderLayoutWindowSize(availableWidth, availableHeight)));
    const blockEnd = this.findBlockParagraphPageEnd(source, safeStart, blockWindowEnd,
      availableWidth, availableHeight, chapterIndex);
    if (blockEnd > safeStart) return blockEnd;

    // The precise paragraph path intentionally falls back when interactive markers are present because its
    // shortened display label no longer has a 1:1 source offset. Never binary-search the rest of the whole
    // chapter in that case: each probe would rebuild every following comment bubble and dense chapters can
    // block ArkUI for several seconds. The layout window is already at least twice the estimated visible text,
    // so it preserves the exact bubble-aware measurement while keeping every probe local to the current page.
    const layoutWindowEnd = Math.min(source.length,
      safeStart + this.getReaderLayoutWindowSize(availableWidth, availableHeight));
    let low = safeStart + 1;
    let high = layoutWindowEnd;
    let best = low;
    while (low <= high) {
      const mid = Math.floor((low + high) / 2);
      const candidate = source.substring(safeStart, mid);
      if (this.measureReaderTextHeight(candidate, availableWidth, chapterIndex, source, safeStart) <=
        availableHeight) {
        best = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }

    const end = this.chooseReaderPageBreak(source, safeStart, best);
    return Math.max(safeStart + 1, end);
  }

  findBlockParagraphPageEnd(source: string, start: number, windowEnd: number, availableWidth: number,
    availableHeight: number, chapterIndex: number = this.currentChapterIndex): number {
    const layoutText = source.substring(start, Math.max(start + 1, windowEnd));
    const paragraphs = this.getReaderTextParagraphs(layoutText);
    const spacing = this.getMeasuredReaderParagraphBoundarySpacingPx();
    let usedHeight = 0;
    let best = start;
    for (let index = 0; index < paragraphs.length; index++) {
      const paragraph = paragraphs[index];
      const paragraphStart = start + paragraph.start;
      const paragraphEnd = start + paragraph.end;
      const beforeSpacing = index > 0 ? spacing : 0;
      const paragraphHeight = this.measureReaderSingleParagraphHeight(paragraph.text, availableWidth,
        chapterIndex, source, paragraphStart);
      if (usedHeight + beforeSpacing + paragraphHeight <= availableHeight) {
        usedHeight += beforeSpacing + paragraphHeight;
        best = paragraphEnd;
        continue;
      }

      // Use the space left after the complete paragraphs instead of moving the whole next paragraph to the
      // following page. Comment-heavy sources frequently append a marker to every paragraph; treating all of
      // those paragraphs as atomic left several visible lines empty at the bottom of every page.
      const remainingHeight = Math.max(0, availableHeight - usedHeight - beforeSpacing);
      if (remainingHeight <= 0 && best > start) return best;

      // One native layout gives exact line ends for an ordinary paragraph and for the visible text before
      // an inline action. Rebuilding that paragraph for every binary-search probe is both slower and a source
      // of long main-thread stalls.
      const inlineAction = ReaderActionMarker.findFirst(paragraph.text);
      const directText = inlineAction && inlineAction.start > 0 ?
        paragraph.text.substring(0, inlineAction.start) : paragraph.text;
      const canUseDirectLineOffsets = !!directText &&
        !this.hasMeasuredThemeRegexDecoration(directText, source, paragraphStart);
      if (canUseDirectLineOffsets) {
        const plainEnd = this.findSingleParagraphLineEnd(directText, availableWidth, remainingHeight,
          chapterIndex, source, paragraphStart);
        if (plainEnd > 0 && plainEnd < directText.length) {
          const directEnd = this.chooseReaderPageBreak(source, paragraphStart, paragraphStart + plainEnd);
          return Math.max(paragraphStart + 1, directEnd);
        }
      }

      // Keep marker boundaries atomic while finding the largest fitting source range, so compact action payloads
      // can never leak into rendered text when the text portion of an interactive paragraph is split across pages.
      let low = paragraphStart + 1;
      let high = paragraphEnd;
      let paragraphBest = paragraphStart;
      while (low <= high) {
        const mid = Math.floor((low + high) / 2);
        const candidateEnd = Math.min(paragraphEnd,
          this.adjustReaderActionMarkerPageEnd(source, paragraphStart, mid));
        const candidate = source.substring(paragraphStart, candidateEnd);
        if (this.measureReaderSingleParagraphHeight(candidate, availableWidth, chapterIndex,
          source, paragraphStart) <= remainingHeight) {
          paragraphBest = Math.max(paragraphBest, candidateEnd);
          low = mid + 1;
        } else {
          high = mid - 1;
        }
      }
      if (paragraphBest <= paragraphStart && best > start) return best;
      const breakEnd = this.chooseReaderPageBreak(source, paragraphStart, paragraphBest);
      return Math.max(paragraphStart + 1,
        this.adjustReaderActionMarkerPageEnd(source, paragraphStart, breakEnd));
    }
    return best;
  }

  findSingleParagraphLineEnd(text: string, availableWidth: number, availableHeight: number,
    chapterIndex: number, documentSource: string, absoluteStart: number): number {
    if (!text || availableHeight <= 0) return -1;
    const metrics = this.readerParagraphMetrics(text, availableWidth, chapterIndex, documentSource, absoluteStart);
    let end = -1;
    for (let index = 0; index < metrics.lineEnds.length; index++) {
      const lineBottom = metrics.lineBottomsPx[index] || metrics.heightPx;
      if (lineBottom > availableHeight) break;
      end = Math.max(end, metrics.lineEnds[index]);
    }
    return end;
  }

  refineMeasuredPageEnd(source: string, start: number, initialEnd: number, availableWidth: number,
    availableHeight: number, chapterIndex: number = this.currentChapterIndex): number {
    let best = Math.max(start + 1, Math.min(initialEnd, source.length));
    if (best >= source.length) {
      return source.length;
    }
    if (!this.doesMeasuredReaderPageFit(source, start, best, availableWidth, availableHeight, chapterIndex)) {
      return best;
    }

    let step = Math.max(16, Math.min(512, best - start));
    let upper = Math.min(source.length, best + step);
    while (upper < source.length &&
      this.doesMeasuredReaderPageFit(source, start, upper, availableWidth, availableHeight, chapterIndex)) {
      best = upper;
      step = Math.min(step * 2, 4096);
      upper = Math.min(source.length, best + step);
    }
    if (upper === source.length &&
      this.doesMeasuredReaderPageFit(source, start, upper, availableWidth, availableHeight, chapterIndex)) {
      return source.length;
    }

    let low = best + 1;
    let high = Math.max(low, upper - 1);
    while (low <= high) {
      const mid = Math.floor((low + high) / 2);
      if (this.doesMeasuredReaderPageFit(source, start, mid, availableWidth, availableHeight, chapterIndex)) {
        best = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }

    const end = this.chooseReaderPageBreak(source, start, best);
    return Math.max(start + 1, end);
  }

  doesMeasuredReaderPageFit(source: string, start: number, end: number, availableWidth: number,
    availableHeight: number, chapterIndex: number = this.currentChapterIndex): boolean {
    const safeEnd = Math.max(start + 1, Math.min(end, source.length));
    return this.measureReaderTextHeight(source.substring(start, safeEnd), availableWidth, chapterIndex,
      source, start) <= availableHeight;
  }

  findParagraphLayoutPageEnd(source: string, start: number, availableWidth: number, availableHeight: number,
    chapterIndex: number = this.currentChapterIndex): number {
    const windowEnd = Math.min(source.length, start + this.getReaderLayoutWindowSize(availableWidth, availableHeight));
    const layoutText = source.substring(start, windowEnd);
    if (!layoutText) {
      return -1;
    }
    if (this.readerParagraphSpacing > 0 && /\n/.test(layoutText)) {
      return -1;
    }
    // Placeholder spans occupy a paragraph index but do not correspond to a
    // source-text character. Use the precise height-search path for decorated
    // theme bubbles so line metric indexes are never mistaken for source
    // offsets.
    if (this.hasMeasuredThemeRegexDecoration(layoutText, source, start)) {
      return -1;
    }
    if (ReaderActionMarker.has(layoutText)) {
      return -1;
    }
    try {
      const paragraph = this.buildMeasuredReaderParagraph(layoutText, availableWidth, chapterIndex, source, start);
      const metrics = paragraph.getLineMetrics();
      if (metrics.length === 0) {
        return -1;
      }

      const safeHeight = Math.max(1, availableHeight - 1);
      let end = -1;
      for (let i = 0; i < metrics.length; i++) {
        const metric = metrics[i];
        if (metric.baseline + metric.descent > safeHeight) {
          break;
        }
        end = Math.max(end, metric.endIndex);
      }

      if (end <= 0) {
        const firstRange = paragraph.getActualTextRange(0, true);
        end = Math.max(1, firstRange.end);
      }
      if (end >= layoutText.length && windowEnd < source.length) {
        return -1;
      }
      return Math.max(start + 1, Math.min(source.length, start + end));
    } catch (error) {
      console.error('官方段落布局分页失败，回退到文本测量分页:', error);
      return -1;
    }
  }

  getReaderLayoutWindowSize(availableWidth: number, availableHeight: number): number {
    const charsPerLine = Math.max(8, Math.floor(availableWidth / Math.max(1, this.readerFontSize * 0.95)));
    const visibleLines = Math.max(1, Math.ceil(availableHeight / this.getEffectiveReaderLineHeight()));
    return Math.min(12000, Math.max(800, charsPerLine * (visibleLines + 6) * 2));
  }

  getReaderPaginationHeightTolerancePx(): number {
    return 0;
  }

  getReaderPaginationRenderGuardHeight(): number {
    // 用户设置的上下边距就是正文边界，不能再暗中扣除固定 vp。测量与渲染的亚像素差异由
    // 自适应行距保留的 0.5px 处理，不牺牲一整行或额外的可见留白。
    return 0;
  }

  getReaderTextParagraphs(text: string): ReaderTextParagraph[] {
    const source = (text || '')
      .replace(/\r\n/g, '\n')
      .replace(/\n{3,}/g, '\n\n');
    const paragraphs: ReaderTextParagraph[] = [];
    const separatorRegex = /\n+/g;
    let start = 0;
    let index = 0;
    let match = separatorRegex.exec(source);
    while (match) {
      if (match.index > start) {
        const paragraphText = source.substring(start, match.index);
        paragraphs.push({
          text: paragraphText,
          start: start,
          end: match.index,
          index: index,
          isLast: false,
          key: `paragraph_${index}_${start}_${match.index}_${this.buildTextSliceKey(paragraphText)}`
        });
        index++;
      }
      start = match.index + match[0].length;
      match = separatorRegex.exec(source);
    }
    if (start < source.length) {
      const paragraphText = source.substring(start);
      paragraphs.push({
        text: paragraphText,
        start: start,
        end: source.length,
        index: index,
        isLast: false,
        key: `paragraph_${index}_${start}_${source.length}_${this.buildTextSliceKey(paragraphText)}`
      });
    }
    if (paragraphs.length === 0) {
      paragraphs.push({
        text: source,
        start: 0,
        end: source.length,
        index: 0,
        isLast: true,
        key: `paragraph_empty_${this.buildTextSliceKey(source)}`
      });
      return paragraphs;
    }
    const lastIndex = paragraphs.length - 1;
    for (let i = 0; i < paragraphs.length; i++) {
      paragraphs[i].isLast = i === lastIndex;
      paragraphs[i].index = i;
    }
    return paragraphs;
  }

  measureReaderTextHeight(text: string, availableWidth: number,
    chapterIndex: number = this.currentChapterIndex, documentSource: string = text,
    absoluteStart: number = 0): number {
    if (!text) {
      return 0;
    }
    const paragraphs = this.getReaderTextParagraphs(text);
    if (paragraphs.length > 1) {
      let totalHeight = 0;
      for (const paragraph of paragraphs) {
        totalHeight += this.measureReaderSingleParagraphHeight(paragraph.text, availableWidth, chapterIndex,
          documentSource, absoluteStart + paragraph.start);
        if (!paragraph.isLast) {
          totalHeight += this.getMeasuredReaderParagraphBoundarySpacingPx();
        }
      }
      return totalHeight;
    }
    return this.measureReaderSingleParagraphHeight(text, availableWidth, chapterIndex, documentSource, absoluteStart);
  }

  measureReaderSingleParagraphHeight(text: string, availableWidth: number,
    chapterIndex: number = this.currentChapterIndex, documentSource: string = text,
    absoluteStart: number = 0): number {
    return this.readerParagraphMetrics(text, availableWidth, chapterIndex, documentSource, absoluteStart).heightPx;
  }

  readerParagraphMetrics(text: string, availableWidth: number,
    chapterIndex: number = this.currentChapterIndex, documentSource: string = text,
    absoluteStart: number = 0): ReaderParagraphMetrics {
    if (!text) return { heightPx: 0, lineEnds: [], lineBottomsPx: [], lineCount: 0 };
    const key = `${chapterIndex}_${absoluteStart}_${Math.round(availableWidth * 10)}_` +
      `${this.readerTypographyCacheIdentity()}_${this.buildTextSliceKey(documentSource)}_` +
      `${text.length}_${this.hashText(text)}`;
    const cached = this.readerParagraphMetricsCache.get(key);
    if (cached) return cached;

    let result: ReaderParagraphMetrics;
    if (ReaderActionMarker.parse(text)) {
      result = {
        heightPx: this.toMeasurePx(Math.max(this.getEffectiveReaderLineHeight(), 32)),
        lineEnds: [text.length],
        lineBottomsPx: [this.toMeasurePx(Math.max(this.getEffectiveReaderLineHeight(), 32))],
        lineCount: 1
      };
      this.cacheReaderParagraphMetrics(key, result);
      return result;
    }
    const measuredText = this.readerActionMeasurementText(text, documentSource, absoluteStart);
    try {
      const paragraph = this.buildMeasuredReaderParagraph(text, availableWidth, chapterIndex,
        documentSource, absoluteStart);
      const nativeMetrics = paragraph.getLineMetrics();
      if (nativeMetrics.length > 0) {
        const lineEnds: number[] = [];
        const lineBottomsPx: number[] = [];
        const renderedLineBoxPx = this.getRenderedReaderParagraphLineBoxPx(text, chapterIndex,
          documentSource, absoluteStart);
        const renderedLineSpacingPx = this.toMeasureNonNegativePx(Math.max(0, this.readerLineHeight));
        for (let index = 0; index < nativeMetrics.length; index++) {
          const metric = nativeMetrics[index];
          lineEnds.push(metric.endIndex);
          lineBottomsPx.push((index + 1) * renderedLineBoxPx + index * renderedLineSpacingPx);
        }
        // graphics.text exposes the exact wrapping offsets, but custom-font ascent/descent can differ
        // from ArkUI Text's fp-sized row box. Reconstruct height from the same fp row and vp spacing
        // units used by the renderer, retaining native offsets only for line breaking.
        const height = lineBottomsPx[lineBottomsPx.length - 1];
        if (height > 0) {
          result = {
            heightPx: height,
            lineEnds: lineEnds,
            lineBottomsPx: lineBottomsPx,
            lineCount: nativeMetrics.length
          };
          this.cacheReaderParagraphMetrics(key, result);
          return result;
        }
      }
    } catch (error) {
      console.error('官方段落布局测量阅读文本高度失败，回退到组件测量:', error);
    }
    const fallbackStyle = this.getParagraphFallbackMeasureStyle(measuredText, chapterIndex);
    const options: MeasureOptions = {
        textContent: measuredText,
        constraintWidth: Math.max(1, availableWidth),
        fontSize: fallbackStyle.fontSize,
        fontFamily: fallbackStyle.fontFamily,
        lineHeight: this.getEffectiveReaderLineHeight(),
        letterSpacing: this.getReaderAdaptiveLetterSpacing(),
      fontWeight: FontWeight.Normal,
      textAlign: TextAlign.JUSTIFY,
      wordBreak: WordBreak.BREAK_WORD
    };
    try {
      const size = this.getUIContext().getMeasureUtils().measureTextSize(options);
      const height = Number(size.height);
      if (height > 0) {
        const fallbackLineHeightPx = this.toMeasurePx(this.getEffectiveReaderLineHeight());
        result = {
          heightPx: height,
          lineEnds: [],
          lineBottomsPx: [],
          lineCount: Math.max(1, Math.round(height / Math.max(1, fallbackLineHeightPx)))
        };
        this.cacheReaderParagraphMetrics(key, result);
        return result;
      }
    } catch (error) {
      console.error('测量阅读文本高度失败:', error);
    }
    const charsPerLine = Math.max(8, Math.floor(availableWidth / Math.max(1, this.readerFontSize * 1.08)));
    const lines = Math.max(1, Math.ceil(measuredText.length / charsPerLine));
    result = {
      heightPx: this.toMeasurePx(lines * this.getEffectiveReaderLineHeight()),
      lineEnds: [],
      lineBottomsPx: [],
      lineCount: lines
    };
    this.cacheReaderParagraphMetrics(key, result);
    return result;
  }

  cacheReaderParagraphMetrics(key: string, metrics: ReaderParagraphMetrics): void {
    this.readerParagraphMetricsCache.set(key, metrics);
    while (this.readerParagraphMetricsCache.size > 640) {
      const oldestKey = this.readerParagraphMetricsCache.keys().next().value as string | undefined;
      if (!oldestKey) break;
      this.readerParagraphMetricsCache.delete(oldestKey);
    }
  }

  readerActionMeasurementText(text: string, documentSource: string, absoluteStart: number): string {
    const value = text || '';
    const source = documentSource || value;
    const rangeStart = Math.max(0, Math.min(absoluteStart, source.length));
    const rangeEnd = Math.min(source.length, rangeStart + value.length);
    let searchStart = rangeStart;
    let localCursor = 0;
    let result = '';
    while (searchStart < rangeEnd) {
      let markerStart = -1;
      for (const prefix of [ReaderActionMarker.PREFIX, ReaderActionMarker.LEGACY_PREFIX,
        ReaderActionMarker.ORIGINAL_PREFIX]) {
        const index = source.indexOf(prefix, searchStart);
        if (index >= 0 && (markerStart < 0 || index < markerStart)) markerStart = index;
      }
      if (markerStart < 0 || markerStart >= rangeEnd) break;
      const suffix = source.indexOf(ReaderActionMarker.SUFFIX, markerStart);
      if (suffix < 0) break;
      const markerEnd = suffix + ReaderActionMarker.SUFFIX.length;
      const localStart = Math.max(0, markerStart - rangeStart);
      const localEnd = Math.max(localStart, Math.min(value.length, markerEnd - rangeStart));
      result += value.substring(localCursor, localStart);
      const marker = source.substring(markerStart, markerEnd);
      const previousChar = markerStart > 0 ? source.charAt(markerStart - 1) : '';
      const inlineMarker = markerStart > 0 && previousChar !== '\n' && previousChar !== '\r';
      result += inlineMarker ? this.readerInlineSourceActionLabel(marker) :
        (ReaderActionMarker.parse(marker)?.label || '打开');
      localCursor = localEnd;
      if (markerEnd >= rangeEnd) break;
      searchStart = markerEnd;
    }
    if (localCursor === 0) return value;
    return `${result}${value.substring(localCursor)}`;
  }

  buildReaderMeasureTextStyle(fontSize: number, fontFamily: string): graphicsText.TextStyle {
    return {
      // ArkUI Text.fontSize(number) is expressed in fp and follows the system font scale. Widths,
      // line spacing and margins are vp. Keeping those conversions separate is essential on devices
      // whose font scale is not 1.0; vp2px(fontSize) otherwise overestimates every page substantially.
      fontSize: this.toMeasureFontPx(fontSize),
      letterSpacing: this.toMeasureFontOffsetPx(this.getReaderAdaptiveLetterSpacing()),
      fontFamilies: [fontFamily || this.getBodyReaderFontFamily()],
      fontWeight: graphicsText.FontWeight.W400,
      halfLeading: false,
      heightOnly: true,
      heightScale: 1,
      locale: 'zh-Hans'
    };
  }

  buildMeasuredReaderParagraph(text: string, availableWidth: number,
    chapterIndex: number = this.currentChapterIndex, documentSource: string = text,
    absoluteStart: number = 0): graphicsText.Paragraph {
    const bodyStyle = this.buildReaderMeasureTextStyle(this.readerFontSize, this.getBodyReaderFontFamily());
    const paragraphStyle: graphicsText.ParagraphStyle = {
      textStyle: bodyStyle,
      align: graphicsText.TextAlign.JUSTIFY,
      textDirection: graphicsText.TextDirection.LTR,
      wordBreak: graphicsText.WordBreak.BREAK_WORD,
      // Keep native page measurement on the same bounded breaker as the ArkUI Text nodes.
      breakStrategy: graphicsText.BreakStrategy.GREEDY,
      trailingSpaceOptimized: true,
      lineSpacing: this.toMeasureNonNegativePx(Math.max(0, this.readerLineHeight)),
      includeFontPadding: false
    };
    const builder = new graphicsText.ParagraphBuilder(paragraphStyle, graphicsText.FontCollection.getGlobalInstance());
    this.addMeasuredReaderText(builder, text || '', chapterIndex, bodyStyle, documentSource, absoluteStart);
    const paragraph = builder.build();
    paragraph.layoutSync(this.toMeasurePx(availableWidth));
    return paragraph;
  }

  addMeasuredReaderText(builder: graphicsText.ParagraphBuilder, text: string, chapterIndex: number,
    bodyStyle: graphicsText.TextStyle, documentSource: string = text, absoluteStart: number = 0): void {
    if (this.shouldUseTitleStyle(text, chapterIndex)) {
      const title = this.getChapterTitle(chapterIndex).trim();
      const titleLength = Math.min(title.length, text.length);
      const titleStyle = this.buildReaderMeasureTextStyle(this.readerTitleFontSize, this.getTitleReaderFontFamily());
      builder.pushStyle(titleStyle);
      builder.addText(text.substring(0, titleLength));
      builder.popStyle();
      const rest = text.substring(titleLength);
      if (rest) {
        // Inline provider actions can be stored immediately after the reader-generated title. Measuring the
        // compact marker as ordinary text disagrees with the rendered action pill and makes title pages
        // substantially more expensive to paginate.
        const inlineAction = this.findMeasuredReaderInlineAction(rest, documentSource,
          absoluteStart + titleLength);
        if (inlineAction) {
          this.addMeasuredReaderInlineActionText(builder, rest, chapterIndex, bodyStyle, documentSource,
            absoluteStart + titleLength, inlineAction);
        } else {
          this.addMeasuredRegexReaderText(builder, rest, bodyStyle, documentSource, absoluteStart + titleLength);
        }
      }
      return;
    }
    const inlineAction = this.findMeasuredReaderInlineAction(text, documentSource, absoluteStart);
    if (inlineAction) {
      this.addMeasuredReaderInlineActionText(builder, text, chapterIndex, bodyStyle, documentSource,
        absoluteStart, inlineAction);
      return;
    }
    this.addMeasuredRegexReaderText(builder, text, bodyStyle, documentSource, absoluteStart);
  }

  findMeasuredReaderInlineAction(text: string, documentSource: string,
    absoluteStart: number): ReaderActionMatch | null {
    const source = documentSource || text || '';
    const rangeStart = Math.max(0, Math.min(absoluteStart, source.length));
    const match = ReaderActionMarker.findFirst(source.substring(rangeStart));
    if (!match || match.start < 0 || match.start >= (text || '').length) return null;
    const markerStart = rangeStart + match.start;
    const previousChar = markerStart > 0 ? source.charAt(markerStart - 1) : '';
    return markerStart > 0 && previousChar !== '\n' && previousChar !== '\r' ? match : null;
  }

  addMeasuredReaderInlineActionText(builder: graphicsText.ParagraphBuilder, text: string, chapterIndex: number,
    bodyStyle: graphicsText.TextStyle, documentSource: string, absoluteStart: number,
    match: ReaderActionMatch): void {
    const markerStart = Math.max(0, Math.min(match.start, text.length));
    const markerEnd = Math.max(markerStart, Math.min(match.end, text.length));
    const before = text.substring(0, markerStart);
    const after = match.end <= text.length ? text.substring(markerEnd) : '';
    if (before) {
      this.addMeasuredRegexReaderText(builder, before, bodyStyle, documentSource, absoluteStart);
    }
    if (after) {
      this.addMeasuredRegexReaderText(builder, after, bodyStyle, documentSource, absoluteStart + match.end);
    }
    const actionStyle = this.buildReaderMeasureTextStyle(
      this.readerInlineSourceActionFontSize(match.marker), this.getBodyReaderFontFamily());
    builder.pushStyle(actionStyle);
    builder.addText(this.readerInlineSourceActionLabel(match.marker));
    builder.popStyle();
  }

  addMeasuredRegexReaderText(builder: graphicsText.ParagraphBuilder, text: string,
    bodyStyle: graphicsText.TextStyle, documentSource: string = text, absoluteStart: number = 0): void {
    if (!this.readerRegexFontEnabled) {
      builder.pushStyle(bodyStyle);
      builder.addText(text);
      builder.popStyle();
      return;
    }
    const slices = this.getRegexTextSlicesForDocumentRange(text, documentSource, absoluteStart);
    for (const slice of slices) {
      const style = slice.highlighted ?
        this.buildReaderMeasureTextStyle(this.getRegexSliceFontSize(slice), this.getRegexSliceFontFamily(slice)) :
        bodyStyle;
      if (this.shouldUseFullThemeRegexDecoration(slice)) {
        this.addMeasuredRegexBubbleCap(builder, slice);
      }
      builder.pushStyle(style);
      builder.addText(slice.text);
      builder.popStyle();
      if (this.shouldUseFullThemeRegexDecoration(slice)) {
        this.addMeasuredRegexBubbleCap(builder, slice);
      }
    }
  }

  addMeasuredRegexBubbleCap(builder: graphicsText.ParagraphBuilder, slice: ReadTextSlice): void {
    const capSize = this.toMeasurePx(this.getRegexBubbleCapSize(slice));
    builder.addPlaceholder({
      width: capSize,
      height: capSize,
      align: graphicsText.PlaceholderAlignment.CENTER_OF_ROW_BOX,
      baseline: graphicsText.TextBaseline.IDEOGRAPHIC,
      baselineOffset: 0
    });
  }

  hasMeasuredThemeRegexDecoration(text: string, documentSource: string, absoluteStart: number): boolean {
    if (!this.readerRegexFontEnabled || !text) {
      return false;
    }
    const slices = this.getRegexTextSlicesForDocumentRange(text, documentSource, absoluteStart);
    for (const slice of slices) {
      if (this.shouldUseFullThemeRegexDecoration(slice)) {
        return true;
      }
    }
    return false;
  }

  getParagraphFallbackMeasureStyle(text: string, chapterIndex: number): ReaderParagraphMeasureFallback {
    if (this.shouldUseTitleStyle(text, chapterIndex)) {
      return {
        fontSize: this.readerTitleFontSize,
        fontFamily: this.getTitleReaderFontFamily()
      };
    }
    if (this.readerRegexFontEnabled) {
      const slices = this.getRegexTextSlices(text);
      for (const slice of slices) {
        if (slice.highlighted) {
          return {
            fontSize: this.getRegexSliceFontSize(slice),
            fontFamily: this.getRegexSliceFontFamily(slice)
          };
        }
      }
    }
    return {
      fontSize: this.readerFontSize,
      fontFamily: this.getBodyReaderFontFamily()
    };
  }

  toMeasurePx(value: number): number {
    try {
      return Math.max(1, vp2px(value));
    } catch (_) {
      return Math.max(1, value);
    }
  }

  toMeasureNonNegativePx(value: number): number {
    if (!Number.isFinite(value) || value <= 0) return 0;
    try {
      return Math.max(0, vp2px(value));
    } catch (_) {
      return Math.max(0, value);
    }
  }

  getRenderedReaderParagraphLineBoxPx(text: string, chapterIndex: number,
    documentSource: string = text, absoluteStart: number = 0): number {
    // ArkUI's actual glyph row is slightly taller than the configured fp size even with font padding
    // disabled. The factor matches Text's tight row box while avoiding custom font ascent inflation.
    let lineBoxPx = this.toMeasureFontPx(this.readerFontSize) * 1.09;
    if (this.shouldUseTitleStyle(text, chapterIndex)) {
      lineBoxPx = Math.max(lineBoxPx, this.toMeasureFontPx(this.readerTitleFontSize) * 1.09);
    }
    if (this.readerRegexFontEnabled) {
      const slices = this.getRegexTextSlicesForDocumentRange(text, documentSource, absoluteStart);
      for (const slice of slices) {
        if (!slice.highlighted) continue;
        lineBoxPx = Math.max(lineBoxPx, this.toMeasureFontPx(this.getRegexSliceFontSize(slice)) * 1.09);
        if (this.shouldUseFullThemeRegexDecoration(slice)) {
          lineBoxPx = Math.max(lineBoxPx, this.toMeasurePx(this.getRegexBubbleCapSize(slice)));
        }
      }
    }
    const inlineAction = this.findMeasuredReaderInlineAction(text, documentSource, absoluteStart);
    if (inlineAction) {
      lineBoxPx = Math.max(lineBoxPx,
        this.toMeasureFontPx(this.readerInlineSourceActionFontSize(inlineAction.marker)) * 1.09);
    }
    return Math.max(1, lineBoxPx);
  }

  toMeasureFontPx(value: number): number {
    try {
      return Math.max(1, fp2px(value));
    } catch (_) {
      return this.toMeasurePx(value);
    }
  }

  toMeasureFontOffsetPx(value: number): number {
    if (!Number.isFinite(value) || value === 0) return 0;
    try {
      return fp2px(value);
    } catch (_) {
      return value;
    }
  }

  chooseReaderPageBreak(source: string, start: number, best: number): number {
    if (best >= source.length) {
      return source.length;
    }
    const safeBest = Math.max(start + 1, Math.min(best, source.length));
    if (safeBest > start && safeBest < source.length) {
      const previousCode = source.charCodeAt(safeBest - 1);
      const nextCode = source.charCodeAt(safeBest);
      const splitsSurrogatePair = previousCode >= 0xD800 && previousCode <= 0xDBFF &&
        nextCode >= 0xDC00 && nextCode <= 0xDFFF;
      if (splitsSurrogatePair && safeBest - 1 > start) {
        return safeBest - 1;
      }
    }
    return safeBest;
  }

  followTtsChunk(chunk: TtsChunk): void {
    setTimeout(() => {
      if (!this.isTtsSpeaking || !this.ttsAutoContinue) {
        return;
      }
      this.applyTtsChunkFocus(chunk);
      this.updateTtsFloatingSession();
    }, 0);
  }

  applyTtsChunkFocus(chunk: TtsChunk): void {
    const pageIndex = this.resolveTtsChunkPageIndex(chunk);
    const spreadPageIndex = this.normalizeReaderSpreadPageIndex(pageIndex);
    this.ttsLastFocusChunk = chunk;
    this.ttsLastFocusPageIndex = pageIndex;
    if (spreadPageIndex !== this.currentPageIndex) {
      this.animateTtsToPage(spreadPageIndex, chunk);
      return;
    }
    this.updateTtsChunkHighlight(chunk, pageIndex);
  }

  syncTtsFocusAfterResumeLater(delayMs: number): void {
    const serial = ++this.ttsResumeSyncSerial;
    setTimeout(() => {
      if (serial < this.ttsResumeSyncSerial - 1) {
        return;
      }
      this.syncTtsFocusAfterResume();
    }, delayMs);
  }

  syncTtsFocusAfterResume(): void {
    if (!this.isTtsSpeaking || !this.ttsAutoContinue || this.contentPages.length === 0) {
      return;
    }
    if (!this.ttsLastFocusChunk && !this.restorePersistedTtsFocus()) return;
    if (!this.ttsLastFocusChunk) return;
    const pageIndex = this.resolveTtsChunkPageIndex(this.ttsLastFocusChunk);
    if (pageIndex < 0 || pageIndex >= this.contentPages.length) {
      return;
    }
    this.ttsLastFocusPageIndex = pageIndex;
    this.ttsPendingTargetPageIndex = -1;
    this.ttsPendingHighlightChunk = null;
    this.ttsAutoTurningPage = false;
    this.ttsPageTurnSerial++;
    this.finishPageTurnAnimation();
    const spreadPageIndex = this.normalizeReaderSpreadPageIndex(pageIndex);
    if (spreadPageIndex !== this.currentPageIndex) {
      this.currentPageIndex = spreadPageIndex;
      this.saveReadingProgress().catch((error: Error) => {
        console.warn('同步朗读恢复页码失败:', error);
      });
    }
    this.syncCurrentPageText();
    this.updateTtsChunkHighlight(this.ttsLastFocusChunk, pageIndex);
    console.info(`[TTS] resume focus synced: page=${pageIndex},highlight=${this.ttsHighlightStart}-${this.ttsHighlightEnd}`);
  }

  resolveTtsChunkPageIndex(chunk: TtsChunk): number {
    const absoluteStart = this.ttsTextStartOffset + chunk.start;
    return this.findPageIndexByOffset(absoluteStart);
  }

  updateTtsChunkHighlight(chunk: TtsChunk, pageIndex: number): void {
    const absoluteStart = this.ttsTextStartOffset + chunk.start;
    const absoluteEnd = this.ttsTextStartOffset + chunk.end;
    const pageStart = this.getPageStartOffset(pageIndex);
    const pageEnd = this.getPageEndOffset(pageIndex);
    const pageText = this.getPageText(pageIndex);
    this.ttsDisplayText = pageText;
    if (pageIndex === this.currentPageIndex &&
      (this.currentPageText !== pageText || this.displayPageText !== pageText ||
        this.displayPageChapterIndex !== this.currentChapterIndex || this.displayPageIndex !== this.currentPageIndex)) {
      this.setCurrentPageText(pageText);
    }
    this.ttsHighlightStart = Math.max(0, Math.min(absoluteStart - pageStart, pageText.length));
    this.ttsHighlightEnd = Math.max(this.ttsHighlightStart, Math.min(absoluteEnd, pageEnd) - pageStart);
    this.persistTtsReadPosition(absoluteStart, absoluteEnd);
    this.ttsHighlightRenderVersion++;
  }

  persistTtsReadPosition(absoluteStart: number, absoluteEnd: number): void {
    if (!this.book) return;
    const sourceLength = (this.pagedContentText || this.getPagedSourceText()).length;
    const start = Math.max(0, Math.min(Math.round(absoluteStart), sourceLength));
    const end = Math.max(start, Math.min(Math.round(absoluteEnd), sourceLength));
    this.book.putVariable('ttsReadChapterIndex', `${this.currentChapterIndex}`);
    this.book.putVariable('ttsReadOffsetStart', `${start}`);
    this.book.putVariable('ttsReadOffsetEnd', `${end}`);
    ReaderTtsFloatingSession.updatePosition(
      this.ttsFloatingSessionOwnerId, this.currentChapterIndex, start, end, !this.readerPageVisible);
    if (this.ttsProgressSaveTimerId >= 0) return;
    this.ttsProgressSaveTimerId = setTimeout(() => {
      this.ttsProgressSaveTimerId = -1;
      this.saveReadingProgress().catch((error: Error) => {
        console.warn('保存朗读句子位置失败:', error);
      });
    }, 3000);
  }

  flushTtsReadPosition(): void {
    if (this.ttsProgressSaveTimerId < 0) return;
    clearTimeout(this.ttsProgressSaveTimerId);
    this.ttsProgressSaveTimerId = -1;
    this.saveReadingProgress().catch((error: Error) => {
      console.warn('立即保存朗读句子位置失败:', error);
    });
  }

  async flushReadingProgressCheckpoint(): Promise<void> {
    // Normal page turns are debounced. Cancel every delayed writer and persist the current chapter/page snapshot
    // immediately before Harmony freezes the UI in Home or lock-screen background transitions.
    this.clearReaderComicProgressSaveTimer();
    this.clearReaderPagedProgressSaveTimer();
    if (this.ttsProgressSaveTimerId >= 0) {
      clearTimeout(this.ttsProgressSaveTimerId);
      this.ttsProgressSaveTimerId = -1;
    }
    await this.saveReadingProgress(true);
  }

  restorePersistedTtsFocus(): boolean {
    if (!this.book) return false;
    const chapterRaw = this.book.getVariable('ttsReadChapterIndex');
    const startRaw = this.book.getVariable('ttsReadOffsetStart');
    const endRaw = this.book.getVariable('ttsReadOffsetEnd');
    if (!chapterRaw || !startRaw) return false;
    const chapterIndex = Number(chapterRaw);
    const absoluteStart = Number(startRaw);
    const absoluteEnd = Number(endRaw);
    if (!Number.isFinite(chapterIndex) || chapterIndex !== this.currentChapterIndex ||
      !Number.isFinite(absoluteStart) || absoluteStart < this.ttsTextStartOffset) {
      return false;
    }
    const source = this.pagedContentText || this.getPagedSourceText();
    const start = Math.max(this.ttsTextStartOffset, Math.min(Math.round(absoluteStart), source.length));
    const end = Math.max(start, Math.min(Number.isFinite(absoluteEnd) ? Math.round(absoluteEnd) : start,
      source.length));
    this.ttsLastFocusChunk = {
      text: source.substring(start, end),
      start: start - this.ttsTextStartOffset,
      end: end - this.ttsTextStartOffset
    };
    return true;
  }

  activeMirroredTtsChapterIndex(): number {
    if (!this.globalTtsActive || ReaderTtsFloatingSession.isOwner(this.ttsFloatingSessionOwnerId) ||
      !this.bookUrl || this.globalTtsBookUrl !== this.bookUrl || !Number.isFinite(this.globalTtsChapterIndex)) {
      return -1;
    }
    const chapterIndex = Math.round(this.globalTtsChapterIndex);
    return chapterIndex >= 0 && chapterIndex < this.chapters.length ? chapterIndex : -1;
  }

  isMirroringActiveTtsForCurrentBook(): boolean {
    return this.globalTtsActive && this.globalTtsMode === 'tts' && !!this.bookUrl &&
      this.globalTtsBookUrl === this.bookUrl &&
      !ReaderTtsFloatingSession.isOwner(this.ttsFloatingSessionOwnerId);
  }

  async syncMirroredTtsFocus(): Promise<void> {
    const serial = ++this.mirroredTtsFocusSyncSerial;
    const chapterIndex = this.activeMirroredTtsChapterIndex();
    if (chapterIndex < 0 || !this.book || this.contentPages.length === 0) {
      this.clearMirroredTtsFocus();
      return;
    }
    if (chapterIndex !== this.currentChapterIndex) {
      await this.loadContent(true, chapterIndex);
      if (serial !== this.mirroredTtsFocusSyncSerial) return;
    }
    const source = this.pagedContentText || this.getPagedSourceText();
    if (!source || !Number.isFinite(this.globalTtsOffsetStart)) {
      this.clearMirroredTtsFocus();
      return;
    }
    const absoluteStart = Math.max(0, Math.min(Math.round(this.globalTtsOffsetStart), source.length));
    const absoluteEnd = Math.max(absoluteStart,
      Math.min(Number.isFinite(this.globalTtsOffsetEnd) ? Math.round(this.globalTtsOffsetEnd) : absoluteStart,
        source.length));
    if (absoluteEnd <= absoluteStart) {
      this.clearMirroredTtsFocus();
      return;
    }
    const pageIndex = this.findPageIndexByOffset(absoluteStart);
    if (pageIndex < 0 || pageIndex >= this.contentPages.length) {
      this.clearMirroredTtsFocus();
      return;
    }
    const pageStart = this.getPageStartOffset(pageIndex);
    const pageEnd = this.getPageEndOffset(pageIndex);
    const pageText = this.getPageText(pageIndex);
    this.mirroredTtsFocusActive = true;
    this.currentPageIndex = this.normalizeReaderSpreadPageIndex(pageIndex);
    this.syncCurrentPageText();
    this.ttsDisplayText = pageText;
    this.ttsHighlightStart = Math.max(0, Math.min(absoluteStart - pageStart, pageText.length));
    this.ttsHighlightEnd = Math.max(this.ttsHighlightStart,
      Math.min(absoluteEnd, pageEnd) - pageStart);
    this.ttsHighlightRenderVersion++;
  }

  clearMirroredTtsFocus(): void {
    if (!this.mirroredTtsFocusActive) return;
    this.mirroredTtsFocusActive = false;
    this.clearTtsHighlight();
  }

  shouldRenderTtsFocus(): boolean {
    return this.isTtsSpeaking || this.mirroredTtsFocusActive;
  }

  animateTtsToPage(targetPageIndex: number, chunk: TtsChunk): void {
    const target = this.normalizeReaderSpreadPageIndex(
      Math.max(0, Math.min(targetPageIndex, Math.max(0, this.contentPages.length - 1)))
    );
    if (target <= this.currentPageIndex) {
      this.updateTtsChunkHighlight(chunk, this.resolveTtsChunkPageIndex(chunk));
      return;
    }
    this.ttsPendingTargetPageIndex = Math.max(this.ttsPendingTargetPageIndex, target);
    this.ttsPendingHighlightChunk = chunk;
    if (this.ttsAutoTurningPage) {
      return;
    }
    this.runPendingTtsPageTurn();
  }

  async runPendingTtsPageTurn(): Promise<void> {
    this.ttsAutoTurningPage = true;
    const turnSerial = this.ttsPageTurnSerial;
    try {
      while (turnSerial === this.ttsPageTurnSerial && this.isTtsSpeaking && this.ttsAutoContinue &&
        this.ttsPendingTargetPageIndex > this.currentPageIndex && this.canTurnPage(1)) {
        await this.runTtsPageTurnAnimation(1, turnSerial);
        if (turnSerial !== this.ttsPageTurnSerial) {
          return;
        }
      }
      if (turnSerial === this.ttsPageTurnSerial && this.isTtsSpeaking && this.ttsPendingHighlightChunk) {
        this.updateTtsChunkHighlight(this.ttsPendingHighlightChunk,
          this.resolveTtsChunkPageIndex(this.ttsPendingHighlightChunk));
      }
    } finally {
      if (turnSerial === this.ttsPageTurnSerial) {
        this.ttsAutoTurningPage = false;
        this.ttsPendingTargetPageIndex = -1;
        this.ttsPendingHighlightChunk = null;
      }
      // A user turn can arrive while the automatic TTS page animation is in
      // progress. It is queued by runPageTurnAnimation and must run as soon as
      // the automatic animation releases the page-turn lock.
      if (!this.ttsAutoTurningPage && !this.isPageTurning) {
        this.runQueuedPageTurnLater();
      }
    }
  }

  async runTtsPageTurnAnimation(direction: number, turnSerial: number = this.ttsPageTurnSerial): Promise<void> {
    if (this.isPageTurning || !this.canTurnPage(direction)) {
      return;
    }
    this.isPageTurning = true;
    try {
      if (!this.isPageTurnAnimationEnabled()) {
        await this.applyTtsPageTurn(direction, turnSerial);
        const targetText = this.getCurrentPageText();
        this.commitVisibleCurrentPageText(targetText);
        this.finishPageTurnAnimation();
        this.commitCurrentPageTextLater(this.currentChapterIndex, this.currentPageIndex, targetText);
      } else if (this.readerEffectivePageTurnMode() === 1) {
        await this.runTtsSlidePageTurn(direction, turnSerial);
      } else {
        await this.runTtsTapPageTurn(direction, turnSerial);
      }
    } finally {
      this.isPageTurning = false;
    }
  }

  async runTtsTapPageTurn(direction: number, turnSerial: number): Promise<void> {
    const distance = this.getPageTurnDistance();
    this.prepareSlidePageTurn(direction, 0);
    if (this.isSimulationPageTurnAnimation()) {
      await this.completeSimulationPageTurnMotion(direction);
    } else {
      const duration = 220;
      animateTo({ duration: duration, curve: this.pageTurnAnimationCurve() }, () => {
        this.setPageSlideAxisOffset(direction > 0 ? -distance : distance);
        this.pageTransitionOpacity = 1;
      });
      await this.delay(duration + 10);
    }
    await this.applyTtsPageTurn(direction, turnSerial);
    await this.finishAnimatedPageTurn();
  }

  async runTtsSlidePageTurn(direction: number, turnSerial: number): Promise<void> {
    const distance = this.getPageTurnDistance();
    this.prepareSlidePageTurn(direction, this.getPageSlideAxisOffset());
    if (this.isSimulationPageTurnAnimation()) {
      await this.completeSimulationPageTurnMotion(direction);
    } else {
      const duration = 240;
      animateTo({ duration: duration, curve: this.pageTurnAnimationCurve() }, () => {
        this.setPageSlideAxisOffset(direction > 0 ? -distance : distance);
        this.pageTransitionOpacity = 1;
      });
      await this.delay(duration + 10);
    }
    await this.applyTtsPageTurn(direction, turnSerial);
    await this.finishAnimatedPageTurn();
  }

  async applyTtsPageTurn(direction: number, turnSerial: number): Promise<void> {
    if (turnSerial !== this.ttsPageTurnSerial || !this.isTtsSpeaking || !this.ttsAutoContinue) {
      return;
    }
    if (direction > 0) {
      const localPageIndex = this.getLocalPageTurnTargetPageIndex(direction);
      if (localPageIndex >= 0) {
        this.currentPageIndex = localPageIndex;
        this.syncCurrentPageText();
        if (this.contentPages.length - this.currentPageIndex <= 3) {
          this.preloadReaderContent();
        }
        await this.saveReadingProgress();
      } else {
        await this.loadNextChapter();
      }
      return;
    }

    const localPageIndex = this.getLocalPageTurnTargetPageIndex(direction);
    if (localPageIndex >= 0) {
      this.currentPageIndex = localPageIndex;
      this.syncCurrentPageText();
      await this.saveReadingProgress();
    } else {
      await this.loadPrevChapter(true);
    }
  }

  delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => resolve(), ms);
    });
  }

  @Builder
  readerSlidingPageTurnSurface(currentText: string, currentRenderVersion: number, ttsRenderVersion: number) {
    Stack() {
      if (this.shouldRenderSlidingPageTurn()) {
        if (this.isSimulationPageTurnAnimation()) {
          this.readerSimulationPageTurnSurface(currentRenderVersion, currentText, ttsRenderVersion)
        } else if (this.isStackPageTurnAnimation()) {
          this.readerCurrentPageSurface(currentRenderVersion, currentText, ttsRenderVersion)
          this.readerIncomingPageSurface(this.pageTurnIncomingRenderVersion, this.getVisiblePageTurnIncomingText())
        } else {
          this.readerIncomingPageSurface(this.pageTurnIncomingRenderVersion, this.getVisiblePageTurnIncomingText())
          this.readerCurrentPageSurface(currentRenderVersion, currentText, ttsRenderVersion)
        }
      } else {
        this.readerCurrentPageSurface(currentRenderVersion, currentText, ttsRenderVersion)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.readerContentLayerColor())
    .clip(true)
    .expandSafeArea([SafeAreaType.SYSTEM], this.getReaderPageTurnSurfaceSafeAreaEdges())
  }

  @Builder
  readerSlidingPageTurnSurfaceAlternate(currentText: string, currentRenderVersion: number, ttsRenderVersion: number) {
    Stack() {
      if (this.shouldRenderSlidingPageTurn()) {
        if (this.isSimulationPageTurnAnimation()) {
          this.readerSimulationPageTurnSurface(currentRenderVersion, currentText, ttsRenderVersion)
        } else if (this.isStackPageTurnAnimation()) {
          this.readerCurrentPageSurfaceAlternate(currentRenderVersion, currentText, ttsRenderVersion)
          this.readerIncomingPageSurface(this.pageTurnIncomingRenderVersion, this.getVisiblePageTurnIncomingText())
        } else {
          this.readerIncomingPageSurface(this.pageTurnIncomingRenderVersion, this.getVisiblePageTurnIncomingText())
          this.readerCurrentPageSurfaceAlternate(currentRenderVersion, currentText, ttsRenderVersion)
        }
      } else {
        this.readerCurrentPageSurfaceAlternate(currentRenderVersion, currentText, ttsRenderVersion)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.readerContentLayerColor())
    .clip(true)
    .expandSafeArea([SafeAreaType.SYSTEM], this.getReaderPageTurnSurfaceSafeAreaEdges())
  }

  @Builder
  readerSimulationPageTurnSurface(currentRenderVersion: number, currentText: string, ttsRenderVersion: number) {
    if (this.isLandscapeDoublePageActive()) {
      this.readerSimulationDoublePageTurnSurface(currentRenderVersion, currentText, ttsRenderVersion)
    } else {
      this.readerSimulationSinglePageTurnSurface(currentRenderVersion, currentText, ttsRenderVersion)
    }
  }

  @Builder
  readerSimulationSinglePageTurnSurface(currentRenderVersion: number, currentText: string,
    ttsRenderVersion: number) {
    Stack() {
      Stack() {
        this.readerSimulationPaperBackground()
        Column() {
          this.readerIncomingPageLayer(this.pageTurnIncomingRenderVersion,
            this.getVisiblePageTurnIncomingText())
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.getReaderPageContentTopPadding() })
      }
      .width('100%')
      .height('100%')
      .id('reader_page_curl_back_single')
      .renderGroup(true)

      this.readerSimulationPaperBackground()
      this.readerIncomingPageSurface(this.pageTurnIncomingRenderVersion, this.getVisiblePageTurnIncomingText())

      Stack() {
        this.readerSimulationPaperBackground()
        Column() {
          this.readerCurrentPageLayer(currentRenderVersion, currentText, ttsRenderVersion)
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.getReaderPageContentTopPadding() })

      }
      .width('100%')
      .height('100%')
      .id('reader_page_curl_front_single')
      .renderGroup(true)
      .opacity(this.readerPageCurlSnapshotReady ? 0 : 1)

      this.readerSimulationCurlCanvas()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.readerContentLayerColor())
    .clip(true)
  }

  @Builder
  readerSimulationDoublePageTurnSurface(currentRenderVersion: number, currentText: string,
    ttsRenderVersion: number) {
    Stack() {
      Stack() {
        // The back of the turning leaf belongs to the opposite half of the target spread.
        // Crop it from one spread-sized background instead of fitting a second wallpaper
        // inside this half-width snapshot.
        this.readerSimulationHalfPaperBackground(this.pageSlideDirection < 0)
        if (this.pageSlideDirection > 0) {
          this.readerSimulationIncomingHalfPage(this.pageTurnIncomingText, this.pageTurnIncomingPageIndex,
            this.pageTurnIncomingPageStart, this.pageTurnIncomingRenderVersion, 'leaf_back_capture')
        } else {
          this.readerSimulationIncomingHalfPage(this.pageTurnIncomingSecondaryText,
            this.pageTurnIncomingPageIndex + 1, this.pageTurnIncomingSecondaryPageStart,
            this.pageTurnIncomingRenderVersion, 'leaf_back_capture')
        }
      }
      .width('50%')
      .height('100%')
      .position({ x: this.pageSlideDirection > 0 ? '50%' : 0, y: 0 })
      .id('reader_page_curl_back_double')
      .renderGroup(true)

      this.readerSimulationPaperBackground()

      Row() {
        if (this.pageSlideDirection > 0) {
          this.readerSimulationCurrentHalfPage(currentText, this.currentPageIndex, currentRenderVersion,
            ttsRenderVersion, 'base_left', true)
          this.readerSimulationIncomingHalfPage(this.pageTurnIncomingSecondaryText,
            this.pageTurnIncomingPageIndex + 1, this.pageTurnIncomingSecondaryPageStart,
            this.pageTurnIncomingRenderVersion, 'base_right', true)
        } else {
          this.readerSimulationIncomingHalfPage(this.pageTurnIncomingText, this.pageTurnIncomingPageIndex,
            this.pageTurnIncomingPageStart, this.pageTurnIncomingRenderVersion, 'base_left', true)
          this.readerSimulationCurrentHalfPage(this.getSecondaryPageText(), this.currentPageIndex + 1,
            currentRenderVersion, ttsRenderVersion, 'base_right', true)
        }
      }
      .width('100%')
      .height('100%')

      Column()
        .width(2)
        .height('94%')
        .position({ x: '50%', y: '3%' })
        .translate({ x: -1 })
        .linearGradient({
          angle: 0,
          colors: [['#00000000', 0], [this.getSimulationSpineColor(), 0.5], ['#00000000', 1]]
        })

      Stack() {
        // The front of the leaf is the current right page when moving forward and the
        // current left page when moving backward.
        this.readerSimulationHalfPaperBackground(this.pageSlideDirection > 0)
        if (this.pageSlideDirection > 0) {
          this.readerSimulationCurrentHalfPage(this.getSecondaryPageText(), this.currentPageIndex + 1,
            currentRenderVersion, ttsRenderVersion, 'leaf_front')
        } else {
          this.readerSimulationCurrentHalfPage(currentText, this.currentPageIndex, currentRenderVersion,
            ttsRenderVersion, 'leaf_front')
        }
      }
      .width('50%')
      .height('100%')
      .position({ x: this.pageSlideDirection > 0 ? '50%' : 0, y: 0 })
      .id('reader_page_curl_front_double')
      .renderGroup(true)
      .opacity(this.readerPageCurlSnapshotReady ? 0 : 1)

      this.readerSimulationCurlCanvas()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.readerContentLayerColor())
    .clip(true)
  }

  @Builder
  readerSimulationCurlCanvas() {
    Canvas(this.readerPageCurlContext)
      .width('100%')
      .height('100%')
      .opacity(this.readerPageCurlSnapshotReady ? 1 : 0)
      .hitTestBehavior(HitTestMode.None)
      .onReady(() => {
        this.readerPageCurlCanvasReady = true;
        this.drawReaderPageCurl();
      })
  }

  @Builder
  readerSimulationPaperBackground() {
    ReaderThemeBackground({
      surfaceColor: this.getBackgroundColor(),
      backgroundAssetId: this.getBackgroundAssetId(),
      customImage: this.currentReaderTheme().backgroundImageUri,
      customImageFit: this.getBackgroundImageFit(),
      viewportWidthHint: this.getPageTurnWidth(),
      viewportHeightHint: this.getReaderBackgroundViewportHeight()
    })
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  readerSimulationHalfPaperBackground(rightHalf: boolean) {
    Stack() {
      ReaderThemeBackground({
        surfaceColor: this.getBackgroundColor(),
        backgroundAssetId: this.getBackgroundAssetId(),
        customImage: this.currentReaderTheme().backgroundImageUri,
        customImageFit: this.getBackgroundImageFit(),
        viewportWidthHint: this.getPageTurnWidth(),
        viewportHeightHint: this.getReaderBackgroundViewportHeight()
      })
        .width(this.getPageTurnWidth())
        .height('100%')
        .position({ x: rightHalf ? -this.getPageTurnWidth() / 2 : 0, y: 0 })
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  readerSimulationCurrentHalfPage(text: string, pageIndex: number, renderVersion: number,
    ttsRenderVersion: number, identity: string, halfWidth: boolean = false) {
    Column() {
      this.styledCurrentReaderText(text, this.getReaderContentBottomPadding(), this.currentChapterIndex,
        ttsRenderVersion, renderVersion,
        `${this.currentReaderPageRenderIdentity(renderVersion, ttsRenderVersion)}_simulation_${identity}`,
        pageIndex)
    }
    .width(halfWidth ? '50%' : '100%')
    .height('100%')
    .padding({ top: this.getReaderPageContentTopPadding() })
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  readerSimulationIncomingHalfPage(text: string, pageIndex: number, pageStart: number,
    renderVersion: number, identity: string, halfWidth: boolean = false) {
    Column() {
      this.styledReaderText(text, this.getReaderContentBottomPadding(), this.pageTurnIncomingChapterIndex, 0,
        renderVersion, `${this.incomingReaderPageRenderIdentity(renderVersion, text)}_simulation_${identity}`,
        pageIndex, this.readerMarginTop, pageStart, this.pageTurnIncomingDocumentSource)
    }
    .width(halfWidth ? '50%' : '100%')
    .height('100%')
    .padding({ top: this.getReaderPageContentTopPadding() })
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  readerCurrentPageSurface(renderVersion: number, text: string, ttsRenderVersion: number) {
    Column() {
      this.readerCurrentPageLayer(renderVersion, text, ttsRenderVersion)
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.getReaderPageContentTopPadding() })
    .id(`reader_current_${this.currentChapterIndex}_${this.currentPageIndex}_${this.displayPageRenderKey}_${renderVersion}_${ttsRenderVersion}`)
    .backgroundColor(this.readerContentLayerColor())
    .translate({ x: this.getCurrentPageTurnX(), y: this.getCurrentPageTurnY() + this.bookmarkPullOffsetY })
    .opacity(this.getCurrentPageTurnOpacity())
  }

  @Builder
  readerCurrentPageSurfaceAlternate(renderVersion: number, text: string, ttsRenderVersion: number) {
    Column() {
      this.readerCurrentPageLayer(renderVersion, text, ttsRenderVersion)
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.getReaderPageContentTopPadding() })
    .id(`reader_current_alt_${this.currentChapterIndex}_${this.currentPageIndex}_${this.displayPageRenderKey}_${renderVersion}_${ttsRenderVersion}`)
    .backgroundColor(this.readerContentLayerColor())
    .translate({ x: this.getCurrentPageTurnX(), y: this.getCurrentPageTurnY() + this.bookmarkPullOffsetY })
    .opacity(this.getCurrentPageTurnOpacity())
  }

  @Builder
  readerIncomingPageSurface(renderVersion: number, text: string) {
    Stack() {
      if (this.isStackPageTurnAnimation()) {
        this.readerIncomingPageBackground()
      }
      Column() {
        this.readerIncomingPageLayer(renderVersion, text)
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.getReaderPageContentTopPadding() })
    }
    .width('100%')
    .height('100%')
    .id(`reader_incoming_${this.pageTurnIncomingChapterIndex}_${this.pageTurnIncomingPageIndex}_${renderVersion}`)
    .backgroundColor(this.readerContentLayerColor())
    .renderGroup(true)
    .translate({ x: this.getIncomingSlideX(), y: this.getIncomingSlideY() })
    .opacity(this.getVisiblePageTurnIncomingOpacity())
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  readerIncomingPageBackground() {
    ReaderThemeBackground({
      surfaceColor: this.getBackgroundColor(),
      backgroundAssetId: this.getBackgroundAssetId(),
      customImage: this.currentReaderTheme().backgroundImageUri,
      customImageFit: this.getBackgroundImageFit(),
      viewportWidthHint: this.pageViewWidth,
      viewportHeightHint: this.getReaderBackgroundViewportHeight()
    })
      .id('reader_incoming_theme_background')
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  readerCurrentPageLayer(renderVersion: number, text: string, ttsRenderVersion: number) {
    if (this.isLandscapeDoublePageActive()) {
      Row() {
        Column() {
          this.styledCurrentReaderText(text, this.getReaderContentBottomPadding(), this.currentChapterIndex,
            ttsRenderVersion, renderVersion,
            `${this.currentReaderPageRenderIdentity(renderVersion, ttsRenderVersion)}_left`, this.currentPageIndex)
        }
        .layoutWeight(1)
        .height('100%')

        Blank()
          .width(READER_DOUBLE_PAGE_DIVIDER_WIDTH)
          .height('88%')
          .backgroundColor(this.getSubTextColor())
          .opacity(0.22)

        Column() {
          this.styledCurrentReaderText(this.getSecondaryPageText(), this.getReaderContentBottomPadding(),
            this.currentChapterIndex, ttsRenderVersion, renderVersion,
            `${this.currentReaderPageRenderIdentity(renderVersion, ttsRenderVersion)}_right`, this.currentPageIndex + 1)
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .alignItems(VerticalAlign.Center)
      .backgroundColor(this.readerContentLayerColor())
    } else {
      Column() {
        this.styledCurrentReaderText(text, this.getReaderContentBottomPadding(),
          this.currentChapterIndex,
          ttsRenderVersion, renderVersion, this.currentReaderPageRenderIdentity(renderVersion, ttsRenderVersion),
          this.currentPageIndex)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(this.readerContentLayerColor())
      .id(`reader_layer_${this.currentReaderPageRenderIdentity(renderVersion, ttsRenderVersion)}`)
    }
  }

  @Builder
  readerIncomingPageLayer(renderVersion: number, text: string) {
    if (this.isLandscapeDoublePageActive()) {
      Row() {
        Column() {
          this.styledReaderText(text, this.getReaderContentBottomPadding(), this.pageTurnIncomingChapterIndex, 0,
            renderVersion, `${this.incomingReaderPageRenderIdentity(renderVersion, text)}_left`,
            this.pageTurnIncomingPageIndex, this.readerMarginTop, this.pageTurnIncomingPageStart,
            this.pageTurnIncomingDocumentSource)
        }
        .layoutWeight(1)
        .height('100%')

        Blank()
          .width(READER_DOUBLE_PAGE_DIVIDER_WIDTH)
          .height('88%')
          .backgroundColor(this.getSubTextColor())
          .opacity(0.22)

        Column() {
          this.styledReaderText(this.pageTurnIncomingSecondaryText, this.getReaderContentBottomPadding(),
            this.pageTurnIncomingChapterIndex, 0, renderVersion,
            `${this.incomingReaderPageRenderIdentity(renderVersion, text)}_right`, this.pageTurnIncomingPageIndex + 1,
            this.readerMarginTop, this.pageTurnIncomingSecondaryPageStart, this.pageTurnIncomingDocumentSource)
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .alignItems(VerticalAlign.Center)
      .backgroundColor(this.readerContentLayerColor())
    } else {
      Column() {
        this.styledReaderText(text, this.getReaderContentBottomPadding(),
          this.pageTurnIncomingChapterIndex, 0,
          renderVersion, this.incomingReaderPageRenderIdentity(renderVersion, text), this.pageTurnIncomingPageIndex,
          this.readerMarginTop, this.pageTurnIncomingPageStart, this.pageTurnIncomingDocumentSource)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(this.readerContentLayerColor())
      .id(`reader_incoming_layer_${this.incomingReaderPageRenderIdentity(renderVersion, text)}`)
    }
  }

  currentReaderPageRenderIdentity(renderVersion: number = this.pageRenderVersion,
    ttsRenderVersion: number = this.ttsHighlightRenderVersion): string {
    return this.readerPageRenderIdentity(
      'current',
      this.displayPageChapterIndex,
      this.displayPageIndex,
      renderVersion,
      ttsRenderVersion,
      this.visibleCurrentPageText(),
      this.displayPageRenderKey
    );
  }

  incomingReaderPageRenderIdentity(renderVersion: number, text: string): string {
    return this.readerPageRenderIdentity(
      'incoming',
      this.pageTurnIncomingChapterIndex,
      this.pageTurnIncomingPageIndex,
      renderVersion,
      0,
      text,
      this.pageTurnIncomingRenderVersion
    );
  }

  readerPageRenderIdentity(prefix: string, chapterIndex: number, pageIndex: number, renderVersion: number,
    ttsRenderVersion: number, text: string, displayKey: number = 0): string {
    return `${prefix}_${chapterIndex}_${pageIndex}_${displayKey}_${renderVersion}_${ttsRenderVersion}_` +
      `${this.buildTextSliceKey(text || '')}`;
  }

  effectiveReaderPageRenderIdentity(pageRenderIdentity: string, chapterIndex: number, renderVersion: number,
    ttsRenderVersion: number, text: string): string {
    return pageRenderIdentity || this.readerPageRenderIdentity(
      'paragraph',
      chapterIndex,
      this.currentPageIndex,
      renderVersion,
      ttsRenderVersion,
      text
    );
  }

  @Builder
  styledCurrentReaderText(text: string, bottomPadding: number, chapterIndex: number = this.currentChapterIndex,
    ttsRenderVersion: number = this.ttsHighlightRenderVersion, contentRenderVersion: number = this.pageRenderVersion,
    pageRenderIdentity: string = this.currentReaderPageRenderIdentity(contentRenderVersion, ttsRenderVersion),
    pageIndex: number = this.currentPageIndex) {
    Column() {
      ForEach(this.getReaderTextParagraphGroups(text), (group: ReaderTextParagraphGroup) => {
        this.styledReaderParagraphGroup(group, chapterIndex, this.hasActiveTtsHighlight(text), ttsRenderVersion,
          contentRenderVersion, pageRenderIdentity, this.getPageStartOffset(pageIndex), this.pagedContentText,
          this.getReaderAdaptivePageLineHeight(text, chapterIndex, pageIndex,
            this.getPageStartOffset(pageIndex), this.pagedContentText))
      }, (group: ReaderTextParagraphGroup) => `${pageRenderIdentity}_${group.key}`)
    }
    .width('100%')
    .id(`reader_text_${pageRenderIdentity}`)
    .padding({
      left: this.getReaderPageHorizontalPadding(text, this.readerMarginLeft),
      right: this.getReaderPageHorizontalPadding(text, this.readerMarginRight),
      top: this.getReaderPageVerticalPadding(text, this.readerMarginTop),
      bottom: this.getReaderPageVerticalPadding(text, bottomPadding)
    })
  }

  @Builder
  styledReaderText(text: string, bottomPadding: number, chapterIndex: number = this.currentChapterIndex,
    ttsRenderVersion: number = this.ttsHighlightRenderVersion, contentRenderVersion: number = this.pageRenderVersion,
    pageRenderIdentity: string = this.readerPageRenderIdentity('text', chapterIndex, this.currentPageIndex,
      contentRenderVersion, ttsRenderVersion, text), pageIndex: number = this.currentPageIndex,
    topPadding: number = this.readerMarginTop, pageStartOverride: number = -2,
    documentSourceOverride: string = '') {
    Column() {
      ForEach(this.getReaderTextParagraphGroups(text), (group: ReaderTextParagraphGroup) => {
        this.styledReaderParagraphGroup(group, chapterIndex, this.hasActiveTtsHighlight(text), ttsRenderVersion,
          contentRenderVersion, pageRenderIdentity,
          pageStartOverride >= -1 ? pageStartOverride :
            (chapterIndex === this.currentChapterIndex ? this.getPageStartOffset(pageIndex) : -1),
          documentSourceOverride || (chapterIndex === this.currentChapterIndex ? this.pagedContentText : ''),
          this.getReaderAdaptivePageLineHeight(text, chapterIndex, pageIndex,
            pageStartOverride >= -1 ? pageStartOverride :
              (chapterIndex === this.currentChapterIndex ? this.getPageStartOffset(pageIndex) : -1),
            documentSourceOverride || (chapterIndex === this.currentChapterIndex ? this.pagedContentText : '')))
      }, (group: ReaderTextParagraphGroup) => `${pageRenderIdentity}_${group.key}`)
    }
    .width('100%')
    .id(`reader_text_${pageRenderIdentity}`)
    .padding({
      left: this.getReaderPageHorizontalPadding(text, this.readerMarginLeft),
      right: this.getReaderPageHorizontalPadding(text, this.readerMarginRight),
      top: this.getReaderPageVerticalPadding(text, topPadding),
      bottom: this.getReaderPageVerticalPadding(text, bottomPadding)
    })
  }

  getReaderTextParagraphGroups(text: string): ReaderTextParagraphGroup[] {
    const paragraphs = this.getReaderTextParagraphs(text);
    const groups: ReaderTextParagraphGroup[] = [];
    let mergeableParagraphs: ReaderTextParagraph[] = [];
    const flushMergeableParagraphs = (): void => {
      if (mergeableParagraphs.length === 0) return;
      groups.push({
        paragraphs: mergeableParagraphs,
        mergeable: true,
        key: `merged_${mergeableParagraphs[0].index}_${mergeableParagraphs[mergeableParagraphs.length - 1].index}`
      });
      mergeableParagraphs = [];
    };
    for (const paragraph of paragraphs) {
      // Inline actions need their own TextController and touch stream. Merging them into the page-wide
      // selectable Text makes Span clicks compete with the reader tap layer, and some platform versions
      // never expose a LayoutManager for the merged node.
      if (LocalBookService.isEpubImageMarker(paragraph.text) || ReaderActionMarker.parse(paragraph.text) ||
        this.hasInlineReaderSourceAction(paragraph.text)) {
        flushMergeableParagraphs();
        groups.push({
          paragraphs: [paragraph],
          mergeable: false,
          key: `special_${paragraph.key}`
        });
      } else {
        mergeableParagraphs.push(paragraph);
        // A visible paragraph spacing value applies to every paragraph boundary. Keep those paragraphs
        // as independent Text nodes so the gap is rendered where it belongs instead of once at page end.
        if (this.readerParagraphSpacing > 0) flushMergeableParagraphs();
      }
    }
    flushMergeableParagraphs();
    return groups;
  }

  @Builder
  styledReaderParagraphGroup(group: ReaderTextParagraphGroup, chapterIndex: number,
    ttsHighlightActive: boolean, ttsRenderVersion: number, contentRenderVersion: number,
    pageRenderIdentity: string, pageStart: number, documentSource: string, pageLineHeight: number) {
    if (group.mergeable) {
      this.styledMergedReaderParagraphs(group.paragraphs, chapterIndex, ttsHighlightActive, ttsRenderVersion,
        contentRenderVersion, `${pageRenderIdentity}_${group.key}`, pageStart, documentSource, pageLineHeight)
      this.readerParagraphGap(group.paragraphs[group.paragraphs.length - 1], pageLineHeight)
    } else {
      ForEach(group.paragraphs, (paragraph: ReaderTextParagraph) => {
        this.styledReaderParagraph(paragraph, chapterIndex, ttsHighlightActive, ttsRenderVersion,
          contentRenderVersion, pageRenderIdentity, pageStart, documentSource, pageLineHeight)
        this.readerParagraphGap(paragraph, pageLineHeight)
      }, (paragraph: ReaderTextParagraph) => `${pageRenderIdentity}_${paragraph.key}`)
    }
  }

  mergedReaderParagraphText(paragraphs: ReaderTextParagraph[]): string {
    return paragraphs.map((paragraph: ReaderTextParagraph) => {
      if (!this.hasInlineReaderSourceAction(paragraph.text)) return paragraph.text;
      return `${this.readerInlineSourceActionText(paragraph.text)}${this.readerInlineSourceActionLabel(paragraph.text)}`;
    }).join('\n');
  }

  readerSelectablePageTextKey(pageRenderIdentity: string, contentRenderVersion: number,
    ttsRenderVersion: number, text: string): string {
    return `${pageRenderIdentity}_${contentRenderVersion}_${ttsRenderVersion}_merged_${this.buildTextSliceKey(text)}`;
  }

  @Builder
  styledMergedReaderParagraphs(paragraphs: ReaderTextParagraph[], chapterIndex: number,
    ttsHighlightActive: boolean, ttsRenderVersion: number, contentRenderVersion: number,
    pageRenderIdentity: string, pageStart: number, documentSource: string, pageLineHeight: number) {
    Text('', { controller: this.readerSelectableTextController(this.readerSelectablePageTextKey(
      pageRenderIdentity, contentRenderVersion, ttsRenderVersion, this.mergedReaderParagraphText(paragraphs))) }) {
      ForEach(paragraphs, (paragraph: ReaderTextParagraph, paragraphIndex: number) => {
        if (paragraphIndex > 0) {
          Span('\n')
            .fontSize(this.readerFontSize)
            .fontFamily(this.getBodyReaderFontFamily())
        }
        if (this.hasInlineReaderSourceAction(paragraph.text)) {
          if (this.shouldUseTitleStyle(paragraph.text, chapterIndex)) {
            ForEach(this.getTitleTextSlices(this.readerInlineSourceActionParagraphData(paragraph), chapterIndex,
              ttsHighlightActive), (slice: ReadTextSlice) => {
              Span(slice.text)
                .fontSize(this.readerTitleFontSize)
                .fontFamily(this.getTitleReaderFontFamily())
                .fontColor(slice.ttsHighlighted ? this.getTtsHighlightTextColor() : this.getTextColor())
                .textBackgroundStyle(slice.ttsHighlighted ? {
                  color: this.getTtsHighlightColor(),
                  radius: 4
                } : {})
            }, (slice: ReadTextSlice) =>
              `merged_inline_title_${pageRenderIdentity}_${paragraph.key}_${slice.key}`)
          } else {
            ForEach(this.getStyledParagraphTextSlices(this.readerInlineSourceActionParagraphData(paragraph),
              ttsHighlightActive, pageStart, documentSource), (slice: ReadTextSlice) => {
              this.styledRegexSlice(slice)
            }, (slice: ReadTextSlice) =>
              `merged_inline_${pageRenderIdentity}_${paragraph.key}_${slice.key}`)
          }
          Span(this.readerInlineSourceActionLabel(paragraph.text))
            .fontSize(this.readerInlineSourceActionFontSize(paragraph.text))
            .fontColor(this.readerInlineSourceActionFontColor(paragraph.text))
            .textBackgroundStyle({
              color: this.readerInlineSourceActionBackgroundColor(paragraph.text),
              radius: this.readerInlineSourceActionRadius(paragraph.text)
            })
            .textShadow(this.readerInlineSourceActionTextShadow(paragraph.text))
            .onClick(() => {
              const match = this.readerInlineSourceActionMatch(paragraph.text);
              if (match) {
                this.beginReaderInteractiveAction();
                this.openReaderSourceAction(match.marker);
              }
            })
        } else if (this.shouldUseTitleStyle(paragraph.text, chapterIndex)) {
          ForEach(this.getTitleTextSlices(paragraph, chapterIndex, ttsHighlightActive), (slice: ReadTextSlice) => {
            Span(slice.text)
              .fontSize(this.readerTitleFontSize)
              .fontFamily(this.getTitleReaderFontFamily())
              .fontColor(slice.ttsHighlighted ? this.getTtsHighlightTextColor() : this.getTextColor())
              .textBackgroundStyle(slice.ttsHighlighted ? {
                color: this.getTtsHighlightColor(),
                radius: 4
              } : {})
          }, (slice: ReadTextSlice) =>
            `merged_title_${pageRenderIdentity}_${paragraph.key}_${slice.key}`)
          ForEach(this.getTitleBodyTextSlices(paragraph, chapterIndex, ttsHighlightActive, pageStart,
            documentSource), (slice: ReadTextSlice) => {
            this.styledRegexSlice(slice)
          }, (slice: ReadTextSlice) =>
            `merged_title_body_${pageRenderIdentity}_${paragraph.key}_${slice.key}`)
        } else {
          ForEach(this.getStyledParagraphTextSlices(paragraph, ttsHighlightActive, pageStart, documentSource),
            (slice: ReadTextSlice) => {
            this.styledRegexSlice(slice)
          }, (slice: ReadTextSlice) =>
            `merged_body_${pageRenderIdentity}_${paragraph.key}_${slice.key}`)
        }
      }, (paragraph: ReaderTextParagraph) => `merged_${pageRenderIdentity}_${paragraph.key}`)
    }
    .lineSpacing(LengthMetrics.vp(this.getReaderPageLineSpacing(pageLineHeight)), { onlyBetweenLines: true })
    .halfLeading(false)
    .includeFontPadding(false)
    .fontColor(this.getTextColor())
    .letterSpacing(this.getReaderAdaptiveLetterSpacing())
    .textAlign(TextAlign.JUSTIFY)
    .wordBreak(WordBreak.BREAK_WORD)
    .lineBreakStrategy(LineBreakStrategy.GREEDY)
    .copyOption(CopyOptions.LocalDevice)
    .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
    .width('100%')
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const mergedText = this.mergedReaderParagraphText(paragraphs);
      const selectableKey = this.readerSelectablePageTextKey(pageRenderIdentity, contentRenderVersion,
        ttsRenderVersion, mergedText);
      this.rememberReaderSelectableText(
        selectableKey,
        mergedText,
        newValue
      );
      this.rememberMergedReaderInlineSourceActionAreas(paragraphs, selectableKey, pageRenderIdentity, newValue);
    })
    .id(`reader_merged_${pageRenderIdentity}_${this.buildTextSliceKey(this.mergedReaderParagraphText(paragraphs))}`)
  }

  rememberMergedReaderInlineSourceActionAreas(paragraphs: ReaderTextParagraph[], selectableKey: string,
    pageIdentity: string, area: Area): void {
    const left = Number(area.globalPosition.x);
    const top = Number(area.globalPosition.y);
    const width = this.parseAreaDimension(area.width);
    const height = this.parseAreaDimension(area.height);
    if (!Number.isFinite(left) || !Number.isFinite(top) || width <= 0 || height <= 0) return;
    this.readerPendingMergedActionBounds.set(selectableKey, {
      paragraphs: paragraphs,
      selectableKey: selectableKey,
      left: left,
      top: top,
      pageIdentity: pageIdentity,
      attempts: 0
    });
    this.scheduleReaderSourceActionBoundsFlush();
  }

  registerMergedReaderInlineSourceActionBounds(task: ReaderMergedActionBoundsTask, visibleText: string): boolean {
    let hasVisibleMarker = false;
    for (const paragraph of task.paragraphs) {
      const match = this.readerInlineSourceActionMatch(paragraph.text);
      if (match && visibleText.includes(match.marker)) {
        hasVisibleMarker = true;
        break;
      }
    }
    if (!hasVisibleMarker) return true;
    try {
      const manager = this.readerSelectableTextController(task.selectableKey).getLayoutManager();
      if (!manager) {
        if (task.attempts >= 7) console.warn('合并正文段评布局尚未就绪，点击区域注册失败');
        return false;
      }
      let cursor = 0;
      for (let paragraphIndex = 0; paragraphIndex < task.paragraphs.length; paragraphIndex++) {
        const paragraph = task.paragraphs[paragraphIndex];
        const bodyText = this.hasInlineReaderSourceAction(paragraph.text) ?
          this.readerInlineSourceActionText(paragraph.text) : paragraph.text;
        const label = this.hasInlineReaderSourceAction(paragraph.text) ?
          this.readerInlineSourceActionLabel(paragraph.text) : '';
        if (label) {
          const match = this.readerInlineSourceActionMatch(paragraph.text);
          if (match && visibleText.includes(match.marker)) {
            const labelStart = cursor + bodyText.length;
            const labelEnd = labelStart + label.length;
            const boxes: graphicsText.TextBox[] = manager.getRectsForRange({ start: labelStart, end: labelEnd },
              graphicsText.RectWidthStyle.TIGHT, graphicsText.RectHeightStyle.MAX);
            for (const box of boxes) {
              const localLeft = px2vp(box.rect.left);
              const localTop = px2vp(box.rect.top);
              const localRight = px2vp(box.rect.right);
              const localBottom = px2vp(box.rect.bottom);
              this.rememberReaderSourceActionBounds(match.marker, task.left + localLeft, task.top + localTop,
                task.left + localRight, task.top + localBottom);
            }
          }
        }
        cursor += bodyText.length + label.length;
        if (paragraphIndex < task.paragraphs.length - 1) cursor++;
      }
      return true;
    } catch (error) {
      if (task.attempts >= 7) console.warn('合并正文段评点击区域计算失败:', error);
      return false;
    }
  }

  @Builder
  styledReaderParagraph(paragraph: ReaderTextParagraph, chapterIndex: number = this.currentChapterIndex,
    ttsHighlightActive: boolean = true, ttsRenderVersion: number = this.ttsHighlightRenderVersion,
    contentRenderVersion: number = this.pageRenderVersion, pageRenderIdentity: string = '', pageStart: number = -1,
    documentSource: string = this.pagedContentText, pageLineHeight: number = this.getEffectiveReaderLineHeight()) {
    if (LocalBookService.isEpubImageMarker(paragraph.text)) {
      this.readerEpubImage(paragraph.text)
    } else if (this.hasInlineReaderSourceAction(paragraph.text)) {
      this.readerInlineSourceActionParagraph(paragraph, chapterIndex, ttsHighlightActive, ttsRenderVersion,
        contentRenderVersion, pageRenderIdentity, pageStart, documentSource, pageLineHeight)
    } else if (ReaderActionMarker.parse(paragraph.text)) {
      this.readerSourceAction(paragraph.text)
    } else if (this.shouldUseTitleStyle(paragraph.text, chapterIndex)) {
      Text('', { controller: this.readerSelectableTextController(
        this.readerSelectableTextKey('title', pageRenderIdentity, contentRenderVersion, ttsRenderVersion,
          paragraph)) }) {
        ForEach(this.getTitleTextSlices(paragraph, chapterIndex, ttsHighlightActive), (slice: ReadTextSlice) => {
          Span(slice.text)
            .fontSize(this.readerTitleFontSize)
            .fontFamily(this.getTitleReaderFontFamily())
            .fontColor(slice.ttsHighlighted ? this.getTtsHighlightTextColor() : this.getTextColor())
            .textBackgroundStyle(slice.ttsHighlighted ? {
              color: this.getTtsHighlightColor(),
              radius: 4
            } : {})
        }, (slice: ReadTextSlice) =>
          `title_${this.effectiveReaderPageRenderIdentity(pageRenderIdentity, chapterIndex, contentRenderVersion,
            ttsRenderVersion, paragraph.text)}_${paragraph.key}_${slice.key}`)
        ForEach(this.getTitleBodyTextSlices(paragraph, chapterIndex, ttsHighlightActive, pageStart, documentSource),
          (slice: ReadTextSlice) => {
          this.styledRegexSlice(slice)
        }, (slice: ReadTextSlice) =>
          `title_body_${this.effectiveReaderPageRenderIdentity(pageRenderIdentity, chapterIndex, contentRenderVersion,
            ttsRenderVersion, paragraph.text)}_${paragraph.key}_${slice.key}`)
      }
      .lineSpacing(LengthMetrics.vp(this.getReaderPageLineSpacing(pageLineHeight)), { onlyBetweenLines: true })
      .halfLeading(false)
      .includeFontPadding(false)
      .fontColor(this.getTextColor())
      .letterSpacing(this.getReaderAdaptiveLetterSpacing())
      .textAlign(TextAlign.JUSTIFY)
      .wordBreak(WordBreak.BREAK_WORD)
      .lineBreakStrategy(LineBreakStrategy.GREEDY)
      .copyOption(CopyOptions.LocalDevice)
      .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
      .width('100%')
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        this.rememberReaderSelectableText(
          this.readerSelectableTextKey('title', pageRenderIdentity, contentRenderVersion, ttsRenderVersion,
            paragraph),
          paragraph.text,
          newValue
        );
      })
      .id(`reader_title_${this.effectiveReaderPageRenderIdentity(pageRenderIdentity, chapterIndex, contentRenderVersion,
        ttsRenderVersion, paragraph.text)}_${paragraph.key}`)
    } else if (this.readerRegexFontEnabled) {
      this.regexReaderText(paragraph, ttsHighlightActive, ttsRenderVersion, contentRenderVersion,
        this.effectiveReaderPageRenderIdentity(pageRenderIdentity, chapterIndex, contentRenderVersion,
          ttsRenderVersion, paragraph.text), pageStart, documentSource, pageLineHeight)
    } else {
      Text('', { controller: this.readerSelectableTextController(
        this.readerSelectableTextKey('plain', pageRenderIdentity, contentRenderVersion, ttsRenderVersion,
          paragraph)) }) {
        ForEach(this.getStyledParagraphTextSlices(paragraph, ttsHighlightActive, pageStart, documentSource),
          (slice: ReadTextSlice) => {
          Span(slice.text)
            .fontSize(this.readerFontSize)
            .fontFamily(this.getBodyReaderFontFamily())
            .fontColor(this.getStyledSliceFontColor(slice))
            .textBackgroundStyle(this.getStyledSliceBackgroundStyle(slice))
            .textShadow(this.getStyledSliceTextShadow(slice))
            .decoration(this.getStyledSliceDecoration(slice))
        }, (slice: ReadTextSlice) =>
          `${this.effectiveReaderPageRenderIdentity(pageRenderIdentity, chapterIndex, contentRenderVersion,
            ttsRenderVersion, paragraph.text)}_${paragraph.key}_${slice.key}`)
      }
        .lineSpacing(LengthMetrics.vp(this.getReaderPageLineSpacing(pageLineHeight)), { onlyBetweenLines: true })
        .halfLeading(false)
        .includeFontPadding(false)
        .fontColor(this.getTextColor())
        .letterSpacing(this.getReaderAdaptiveLetterSpacing())
        .textAlign(TextAlign.JUSTIFY)
        .wordBreak(WordBreak.BREAK_WORD)
        .lineBreakStrategy(LineBreakStrategy.GREEDY)
        .copyOption(CopyOptions.LocalDevice)
        .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
        .width('100%')
        .onAreaChange((_oldValue: Area, newValue: Area) => {
          this.rememberReaderSelectableText(
            this.readerSelectableTextKey('plain', pageRenderIdentity, contentRenderVersion, ttsRenderVersion,
              paragraph),
            paragraph.text,
            newValue
          );
        })
        .id(`reader_plain_${this.effectiveReaderPageRenderIdentity(pageRenderIdentity, chapterIndex,
          contentRenderVersion, ttsRenderVersion, paragraph.text)}_${paragraph.key}`)
    }
  }

  @Builder
  readerEpubImage(marker: string) {
    Image(this.getReaderEpubImageUri(marker))
      .width('100%')
      .height(this.getReaderEpubImageHeight())
      // sourceSize 同时指定宽高会在解码阶段把漫画压成屏幕比例，
      // 这里交给 ImageFit.Contain 按原始宽高比缩放。
      .objectFit(ImageFit.Contain)
      .draggable(false)
      .clip(true)
  }

  @Builder
  readerSourceAction(marker: string) {
    Row({ space: 5 }) {
      SymbolGlyph($r('sys.symbol.arrow_right_up_and_square'))
        .fontSize(13)
        .fontColor([this.getTextColor()])
      Text(ReaderActionMarker.parse(marker)?.label || '打开')
        .fontSize(Math.max(11, this.readerFontSize - 3))
        .fontColor(this.getTextColor())
        .maxLines(1)
    }
    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
    .border({ width: 1, color: this.getTextColor() })
    .borderRadius(14)
    .opacity(0.72)
    .hitTestBehavior(HitTestMode.Block)
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.rememberReaderSourceActionArea(marker, newValue);
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down || event.type === TouchType.Move || event.type === TouchType.Up) {
        this.beginReaderInteractiveAction();
      }
    })
    .onClick(() => {
      this.beginReaderInteractiveAction();
      this.openReaderSourceAction(marker);
    })
    .priorityGesture(
      TapGesture().onAction(() => {
        this.beginReaderInteractiveAction();
        this.openReaderSourceAction(marker);
      }),
      GestureMask.IgnoreInternal
    )
    .monopolizeEvents(true)
  }

  hasInlineReaderSourceAction(text: string): boolean {
    const match = this.readerInlineSourceActionMatch(text);
    return !!match && (match.start > 0 || match.end < (text || '').length);
  }

  readerInlineSourceActionMatch(text: string): ReaderActionMatch | null {
    const source = text || '';
    const cached = this.readerActionMatchCache.get(source);
    if (cached) return cached;
    const match = ReaderActionMarker.findFirst(source);
    if (!match) return null;
    this.readerActionMatchCache.set(source, match);
    while (this.readerActionMatchCache.size > 192) {
      const oldest = this.readerActionMatchCache.keys().next().value as string | undefined;
      if (oldest === undefined) break;
      this.readerActionMatchCache.delete(oldest);
    }
    return match;
  }

  @Builder
  readerInlineSourceActionParagraph(paragraph: ReaderTextParagraph, chapterIndex: number = this.currentChapterIndex,
    ttsHighlightActive: boolean = true, ttsRenderVersion: number = this.ttsHighlightRenderVersion,
    contentRenderVersion: number = this.pageRenderVersion, pageRenderIdentity: string = '', pageStart: number = -1,
    documentSource: string = this.pagedContentText, pageLineHeight: number = this.getEffectiveReaderLineHeight()) {
    Text('', { controller: this.readerInlineActionTextController(paragraph.text) }) {
      if (this.shouldUseTitleStyle(paragraph.text, chapterIndex)) {
        ForEach(this.getTitleTextSlices(this.readerInlineSourceActionParagraphData(paragraph), chapterIndex,
          ttsHighlightActive), (slice: ReadTextSlice) => {
          Span(slice.text)
            .fontSize(this.readerTitleFontSize)
            .fontFamily(this.getTitleReaderFontFamily())
            .fontColor(slice.ttsHighlighted ? this.getTtsHighlightTextColor() : this.getTextColor())
            .textBackgroundStyle(slice.ttsHighlighted ? {
              color: this.getTtsHighlightColor(),
              radius: 4
            } : {})
        }, (slice: ReadTextSlice) =>
          `inline_title_${this.effectiveReaderPageRenderIdentity(pageRenderIdentity, chapterIndex,
            contentRenderVersion, ttsRenderVersion, paragraph.text)}_${paragraph.key}_${slice.key}`)
      } else {
        ForEach(this.getStyledParagraphTextSlices(this.readerInlineSourceActionParagraphData(paragraph),
          ttsHighlightActive, pageStart, documentSource), (slice: ReadTextSlice) => {
          this.styledRegexSlice(slice)
        }, (slice: ReadTextSlice) =>
          `inline_${this.effectiveReaderPageRenderIdentity(pageRenderIdentity, chapterIndex, contentRenderVersion,
            ttsRenderVersion, paragraph.text)}_${paragraph.key}_${slice.key}`)
      }
      Span(this.readerInlineSourceActionLabel(paragraph.text))
        .fontSize(this.readerInlineSourceActionFontSize(paragraph.text))
        .fontColor(this.readerInlineSourceActionFontColor(paragraph.text))
        .textBackgroundStyle({
          color: this.readerInlineSourceActionBackgroundColor(paragraph.text),
          radius: this.readerInlineSourceActionRadius(paragraph.text)
        })
        .textShadow(this.readerInlineSourceActionTextShadow(paragraph.text))
        .onClick(() => {
          const match = this.readerInlineSourceActionMatch(paragraph.text);
          if (match) {
            this.beginReaderInteractiveAction();
            this.openReaderSourceAction(match.marker);
          }
        })
    }
    .lineSpacing(LengthMetrics.vp(this.getReaderPageLineSpacing(pageLineHeight)), { onlyBetweenLines: true })
    .halfLeading(false)
    .includeFontPadding(false)
    .fontColor(this.getTextColor())
    .letterSpacing(this.getReaderAdaptiveLetterSpacing())
    .textAlign(TextAlign.JUSTIFY)
    .wordBreak(WordBreak.BREAK_WORD)
    .lineBreakStrategy(LineBreakStrategy.GREEDY)
    .copyOption(CopyOptions.LocalDevice)
    .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
    .width('100%')
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.rememberReaderInlineSourceActionArea(paragraph.text, pageRenderIdentity, newValue);
      this.rememberReaderSelectableText(
        this.readerSelectableTextKey('inline', pageRenderIdentity, contentRenderVersion, ttsRenderVersion,
          paragraph),
        paragraph.text,
        newValue,
        this.readerInlineActionTextController(paragraph.text)
      );
    })
    .onClick((event: ClickEvent) => {
      const match = this.readerInlineSourceActionMatch(paragraph.text);
      if (match && this.isReaderInlineActionTextPoint(paragraph.text, event.x, event.y)) {
        this.beginReaderInteractiveAction();
        this.openReaderSourceAction(match.marker);
      }
    })
    .onTouch((event: TouchEvent) => this.handleReaderInlineActionTextTouch(paragraph.text, event))
    .id(`reader_inline_${this.effectiveReaderPageRenderIdentity(pageRenderIdentity, chapterIndex,
      contentRenderVersion, ttsRenderVersion, paragraph.text)}_${paragraph.key}`)
  }

  readerInlineActionTextController(text: string): TextController {
    const match = this.readerInlineSourceActionMatch(text);
    const key = match ? match.marker : text;
    let controller = this.readerInlineActionTextControllers.get(key);
    if (!controller) {
      controller = new TextController();
      this.readerInlineActionTextControllers.set(key, controller);
      while (this.readerInlineActionTextControllers.size > 80) {
        const oldest = this.readerInlineActionTextControllers.keys().next().value as string | undefined;
        if (!oldest) break;
        this.readerInlineActionTextControllers.delete(oldest);
      }
    }
    return controller;
  }

  handleReaderInlineActionTextTouch(text: string, event: TouchEvent): void {
    const match = this.readerInlineSourceActionMatch(text);
    if (!match) return;
    const point = event.changedTouches && event.changedTouches.length > 0 ? event.changedTouches[0] :
      (event.touches && event.touches.length > 0 ? event.touches[0] : null);
    if (!point) return;
    const hit = this.isReaderInlineActionTextPoint(text, Number(point.x), Number(point.y));
    if (event.type === TouchType.Down) {
      this.readerInlineTouchActionMarker = hit ? match.marker : '';
      if (hit) this.beginReaderInteractiveAction();
      return;
    }
    if (event.type === TouchType.Up) {
      const marker = this.readerInlineTouchActionMarker;
      this.readerInlineTouchActionMarker = '';
      if (hit && marker === match.marker) {
        this.beginReaderInteractiveAction();
        this.openReaderSourceAction(marker);
      }
      return;
    }
    if (event.type === TouchType.Cancel) this.readerInlineTouchActionMarker = '';
  }

  isReaderInlineActionTextPoint(text: string, x: number, y: number): boolean {
    const match = this.readerInlineSourceActionMatch(text);
    if (!match) return false;
    const bounds = this.readerInlineActionLocalBounds(text, this.readerInlineActionExpectedWidth(),
      this.pageViewHeight);
    for (let index = 0; index + 3 < bounds.length; index += 4) {
      if (x >= bounds[index] - this.readerSourceActionHitSlopX &&
        x <= bounds[index + 2] + this.readerSourceActionHitSlopX &&
        y >= bounds[index + 1] - this.readerSourceActionHitSlopY &&
        y <= bounds[index + 3] + this.readerSourceActionHitSlopY) {
        return true;
      }
    }
    try {
      const manager = this.readerInlineActionTextController(text).getLayoutManager();
      const lineCount = manager.getLineCount();
      if (lineCount <= 0) return false;
      const layoutEnd = manager.getLineMetrics(lineCount - 1).endIndex;
      const labelLength = this.readerInlineSourceActionLabel(text).length;
      const position = manager.getGlyphPositionAtCoordinate(x, y).position;
      return position >= Math.max(0, layoutEnd - labelLength - 1) && position <= layoutEnd;
    } catch (_) {
      return false;
    }
  }

  readerInlineActionExpectedWidth(): number {
    const spreadWidth = this.getReaderPageColumnWidth();
    return Math.max(1, spreadWidth - this.readerMarginLeft - this.readerMarginRight);
  }

  readerInlineActionLocalBounds(text: string, componentWidth: number, componentHeight: number): number[] {
    const match = this.readerInlineSourceActionMatch(text);
    if (!match) return [];
    try {
      const manager = this.readerInlineActionTextController(text).getLayoutManager();
      const lineCount = manager.getLineCount();
      if (lineCount <= 0) return [];
      const lastMetric = manager.getLineMetrics(lineCount - 1);
      const layoutEnd = lastMetric.endIndex;
      const labelLength = this.readerInlineSourceActionLabel(text).length;
      const labelStart = Math.max(0, layoutEnd - labelLength);
      const boxes: graphicsText.TextBox[] = manager.getRectsForRange({ start: labelStart, end: layoutEnd },
        graphicsText.RectWidthStyle.TIGHT, graphicsText.RectHeightStyle.MAX);
      const rawBounds: number[] = [];
      for (const box of boxes) {
        if (box.rect.right > box.rect.left && box.rect.bottom > box.rect.top) {
          rawBounds.push(box.rect.left, box.rect.top, box.rect.right, box.rect.bottom);
        }
      }
      if (rawBounds.length === 0) {
        const estimatedWidth = Math.min(lastMetric.width,
          this.toMeasurePx(Math.max(28, labelLength * this.readerInlineSourceActionFontSize(text) * 0.58)));
        const top = Math.max(0, lastMetric.baseline - lastMetric.ascent);
        rawBounds.push(Math.max(lastMetric.left, lastMetric.left + lastMetric.width - estimatedWidth), top,
          lastMetric.left + lastMetric.width, top + lastMetric.height);
      }
      let maxRight = 0;
      let maxBottom = 0;
      for (let index = 0; index + 3 < rawBounds.length; index += 4) {
        maxRight = Math.max(maxRight, rawBounds[index + 2]);
        maxBottom = Math.max(maxBottom, rawBounds[index + 3]);
      }
      const pxCoordinates = (componentWidth > 0 && maxRight > componentWidth * 1.5) ||
        (componentHeight > 0 && maxBottom > componentHeight * 1.5);
      if (!pxCoordinates) return rawBounds;
      const bounds: number[] = [];
      for (const value of rawBounds) {
        try {
          bounds.push(px2vp(value));
        } catch (_) {
          bounds.push(value);
        }
      }
      return bounds;
    } catch (_) {
      return [];
    }
  }

  rememberReaderInlineSourceActionArea(text: string, pageIdentity: string, area: Area): void {
    const match = this.readerInlineSourceActionMatch(text);
    if (!match) return;
    const left = Number(area.globalPosition.x);
    const top = Number(area.globalPosition.y);
    const width = this.parseAreaDimension(area.width);
    const height = this.parseAreaDimension(area.height);
    if (!Number.isFinite(left) || !Number.isFinite(top) || width <= 0 || height <= 0) return;
    this.readerPendingInlineActionBounds.set(match.marker, {
      text: text,
      marker: match.marker,
      left: left,
      top: top,
      width: width,
      height: height,
      pageIdentity: pageIdentity,
      attempts: 0
    });
    this.scheduleReaderSourceActionBoundsFlush();
  }

  clearPendingReaderSourceActionBounds(): void {
    this.readerPendingInlineActionBounds.clear();
    this.readerPendingMergedActionBounds.clear();
  }

  scheduleReaderSourceActionBoundsFlush(delayMs: number = 56): void {
    if (this.readerSourceActionBoundsFlushPending) return;
    this.readerSourceActionBoundsFlushPending = true;
    setTimeout(() => {
      this.readerSourceActionBoundsFlushPending = false;
      this.flushPendingReaderSourceActionBounds();
    }, delayMs);
  }

  flushPendingReaderSourceActionBounds(): void {
    if (this.isPageTurning || this.pageTurnAnimating || this.pageSlideDirection !== 0) {
      this.scheduleReaderSourceActionBoundsFlush(72);
      return;
    }
    const visibleText = this.visibleCurrentPageText();
    const actionDocumentText = this.isReaderNovelContinuousScrollModeActive() ?
      (this.pagedContentText || this.content) : visibleText;
    const inlineRetries: ReaderInlineActionBoundsTask[] = [];
    const mergedRetries: ReaderMergedActionBoundsTask[] = [];
    let remainingBudget = 6;
    for (const entry of this.readerPendingInlineActionBounds.entries()) {
      if (remainingBudget <= 0) break;
      const marker = entry[0];
      const task = entry[1];
      this.readerPendingInlineActionBounds.delete(marker);
      if (actionDocumentText.includes(marker)) {
        const registered = this.registerReaderInlineSourceActionBounds(task.text, task.marker, task.left, task.top,
          task.width, task.height);
        if (!registered && task.attempts < 8) {
          task.attempts++;
          inlineRetries.push(task);
        } else if (!registered) {
          console.warn('正文段评布局尚未就绪，点击区域注册失败');
        }
      }
      remainingBudget--;
    }
    if (remainingBudget > 0) {
      for (const entry of this.readerPendingMergedActionBounds.entries()) {
        if (remainingBudget <= 0) break;
        const selectableKey = entry[0];
        const task = entry[1];
        this.readerPendingMergedActionBounds.delete(selectableKey);
        const registered = this.registerMergedReaderInlineSourceActionBounds(task, actionDocumentText);
        if (!registered && task.attempts < 8) {
          task.attempts++;
          mergedRetries.push(task);
        }
        remainingBudget--;
      }
    }
    for (const task of inlineRetries) this.readerPendingInlineActionBounds.set(task.marker, task);
    for (const task of mergedRetries) this.readerPendingMergedActionBounds.set(task.selectableKey, task);
    if (this.readerPendingInlineActionBounds.size > 0 || this.readerPendingMergedActionBounds.size > 0) {
      this.scheduleReaderSourceActionBoundsFlush(16);
    }
  }

  registerReaderInlineSourceActionBounds(text: string, marker: string, left: number, top: number,
    width: number, height: number): boolean {
    if (!marker || !Number.isFinite(left) || !Number.isFinite(top)) return true;
    const localBounds = this.readerInlineActionLocalBounds(text,
      width > 0 ? width : this.readerInlineActionExpectedWidth(), height > 0 ? height : this.pageViewHeight);
    if (localBounds.length < 4) return false;
    const globalBounds: number[] = [];
    for (let index = 0; index + 3 < localBounds.length; index += 4) {
      globalBounds.push(left + localBounds[index], top + localBounds[index + 1],
        left + localBounds[index + 2], top + localBounds[index + 3]);
    }
    this.readerSourceActionAreas.set(marker, globalBounds);
    return true;
  }

  readerInlineSourceActionParagraphData(paragraph: ReaderTextParagraph): ReaderTextParagraph {
    const text = this.readerInlineSourceActionText(paragraph.text);
    return {
      text: text,
      start: paragraph.start,
      end: paragraph.start + text.length,
      index: paragraph.index,
      isLast: paragraph.isLast,
      key: `${paragraph.key}_inline_${this.buildTextSliceKey(text)}`
    };
  }

  readerInlineSourceActionText(text: string): string {
    const match: ReaderActionMatch | null = this.readerInlineSourceActionMatch(text);
    if (!match) return text || '';
    return `${text.substring(0, match.start)}${text.substring(match.end)}`;
  }

  readerInlineSourceActionLabel(text: string): string {
    const match: ReaderActionMatch | null = this.readerInlineSourceActionMatch(text);
    if (!match) return '';
    const count = (match.data.label || '').match(/(99\+|\d+)\s*$/);
    // Keep the compact comment pill together and bind it to the preceding sentence. Normal spaces
    // let the counter fall onto a line by itself (for example a lone "338" at the bottom of a page).
    const prefix = '\u2060\u00A0\u00A0◌\u00A0';
    const suffix = '\u00A0\u00A0';
    if (count && count[1]) return `${prefix}${count[1]}${suffix}`;
    if (/本章说/.test(match.data.label || '')) return `${prefix}本章说${suffix}`;
    return /段评|评论/.test(match.data.label || '') ? `${prefix}段评${suffix}` : `${prefix}${suffix}`;
  }

  readerInlineSourceActionFontSize(text: string): number {
    if (!this.readerUsesConfiguredCommentBubble(text)) return Math.max(10, this.readerFontSize - 5);
    return this.readerSourceSettingEnabled('气泡增大') ? Math.max(12, this.readerFontSize - 2) :
      Math.max(10, this.readerFontSize - 5);
  }

  readerInlineSourceActionFontColor(text: string): string {
    if (!this.readerUsesConfiguredCommentBubble(text)) {
      return this.isReaderThemeDark() ? '#B8D6FF' : '#2A6FCC';
    }
    return this.readerSourceColorSetting('段评字体颜色', '#A7A7A7');
  }

  readerInlineSourceActionBackgroundColor(text: string): string {
    if (!this.readerUsesConfiguredCommentBubble(text)) {
      return this.isReaderThemeDark() ? '#263A5066' : '#142A6FCC';
    }
    return this.readerSourceColorSetting('段评填充颜色', '#00000000');
  }

  readerInlineSourceActionRadius(text: string): number {
    if (!this.readerUsesConfiguredCommentBubble(text)) return 9;
    const style = this.readerSourceSettingValue('段评样式') || '0';
    if (style === '3' || style === '4') return 3;
    if (style === '0' || style === '2') return 6;
    return 12;
  }

  readerInlineSourceActionTextShadow(text: string): ShadowOptions {
    if (!this.readerUsesConfiguredCommentBubble(text)) {
      return { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 };
    }
    return {
      radius: 0.8,
      color: this.readerSourceColorSetting('段评边框颜色', '#A7A7A7'),
      offsetX: 0,
      offsetY: 0
    };
  }

  readerUsesConfiguredCommentBubble(text: string): boolean {
    const match = this.readerInlineSourceActionMatch(text);
    if (!match || !/段评|评论|本章说/.test(match.data.label || '')) return false;
    const source = this.currentReaderSource();
    if (!source) return false;
    this.ensureReaderSourceSettingCache(source);
    return this.readerSourceHasCommentBubbleScript || !!this.readerSourceSettingValue('段评样式');
  }

  readerSourceSettingValue(key: string): string {
    const source = this.currentReaderSource();
    if (!source || !key) return '';
    this.ensureReaderSourceSettingCache(source);
    return BookSourceRuntimeSnapshotStore.get(source).getString(key);
  }

  ensureReaderSourceSettingCache(source: BookSource): void {
    const snapshot = BookSourceRuntimeSnapshotStore.get(source);
    const sourceKey = source.bookSourceUrl || source.bookSourceName || '__anonymous_source__';
    const contentRule = source.contentRule?.content || '';
    const jsLib = source.jsLib || '';
    if (this.readerSourceSettingCacheKey === sourceKey &&
      this.readerSourceSettingCacheRevision === snapshot.signature &&
      this.readerSourceSettingCacheContentRule === contentRule &&
      this.readerSourceSettingCacheJsLib === jsLib) {
      return;
    }
    this.readerSourceSettingCacheKey = sourceKey;
    this.readerSourceSettingCacheRevision = snapshot.signature;
    this.readerSourceSettingCacheContentRule = contentRule;
    this.readerSourceSettingCacheJsLib = jsLib;
    this.readerSourceHasCommentBubbleScript = contentRule.includes('段评样式') || jsLib.includes('段评样式');
  }

  readerSourceSettingEnabled(key: string): boolean {
    return BookSourceSettingValue.state(this.readerSourceSettingValue(key)) > 0;
  }

  readerSourceColorSetting(key: string, fallback: string): string {
    const value = this.readerSourceSettingValue(key).trim();
    if (!value) return fallback;
    if (value.toLowerCase() === 'transparent') return '#00000000';
    return /^#[0-9a-f]{3,8}$/i.test(value) ? value : fallback;
  }

  beginReaderInteractiveAction(): void {
    this.readerInteractiveActionUntil = Date.now() + 700;
    this.deferReaderPaginationForInteraction(700);
    this.suppressReaderTapClick = true;
    this.readerTouchActive = false;
    this.readerPanActive = false;
  }

  isReaderInteractiveActionActive(): boolean {
    return Date.now() < this.readerInteractiveActionUntil;
  }

  rememberReaderSourceActionArea(marker: string, area: Area): void {
    const position = area.globalPosition;
    this.rememberReaderSourceActionBounds(marker, Number(position.x), Number(position.y),
      Number(position.x) + Number(area.width), Number(position.y) + Number(area.height));
  }

  rememberReaderSourceActionBounds(marker: string, left: number, top: number, right: number, bottom: number): void {
    if (!marker || !Number.isFinite(left) || !Number.isFinite(top) || !Number.isFinite(right) ||
      !Number.isFinite(bottom) || right <= left || bottom <= top) return;
    const values = this.readerSourceActionAreas.get(marker) || [];
    for (let index = 0; index + 3 < values.length; index += 4) {
      if (Math.abs(values[index] - left) < 1 && Math.abs(values[index + 1] - top) < 1 &&
        Math.abs(values[index + 2] - right) < 1 && Math.abs(values[index + 3] - bottom) < 1) return;
    }
    values.push(left, top, right, bottom);
    while (values.length > 48) values.splice(0, 4);
    this.readerSourceActionAreas.set(marker, values);
    while (this.readerSourceActionAreas.size > 40) {
      const oldest = this.readerSourceActionAreas.keys().next().value as string | undefined;
      if (!oldest) break;
      this.readerSourceActionAreas.delete(oldest);
    }
  }

  rememberReaderTapLayerArea(area: Area): void {
    this.readerTapLayerGlobalX = Number(area.globalPosition.x);
    this.readerTapLayerGlobalY = Number(area.globalPosition.y);
  }

  readerSourceActionAtPoint(globalX: number, globalY: number): string {
    const visibleText = this.isReaderNovelContinuousScrollModeActive() ?
      (this.pagedContentText || this.content) : this.visibleCurrentPageText();
    for (const entry of this.readerSourceActionAreas.entries()) {
      const marker = entry[0];
      const bounds = entry[1];
      if (!visibleText.includes(marker) || bounds.length < 4) continue;
      for (let index = 0; index + 3 < bounds.length; index += 4) {
        if (globalX >= bounds[index] - this.readerSourceActionHitSlopX &&
          globalX <= bounds[index + 2] + this.readerSourceActionHitSlopX &&
          globalY >= bounds[index + 1] - this.readerSourceActionHitSlopY &&
          globalY <= bounds[index + 3] + this.readerSourceActionHitSlopY) {
          return marker;
        }
      }
    }
    return '';
  }

  openReaderSourceAction(marker: string): void {
    const now = Date.now();
    if (now - this.readerSourceActionOpenedAt < 500) return;
    const action: ReaderActionData | null = ReaderActionMarker.parse(marker);
    const source = this.currentReaderSource();
    if (action && source) {
      action.url = ReaderInteractionProviderRegistry.expandAction(source, action.url);
    }
    if (action && source && ReaderActionMarker.sourceScript(action.url)) {
      this.openReaderSourceScriptAction(source, action, marker);
      return;
    }
    if (!action || !/^https?:\/\//i.test(action.url)) {
      promptAction.showToast({ message: '书源操作地址无效' });
      return;
    }
    this.readerSourceActionOpenedAt = now;
    const title = action.title || action.label || '网页内容';
    const commentMode = this.isReaderCommentAction(action);
    if (commentMode) {
      if (source) {
        VerificationSupport.requestVerification(action.url, title, source);
      }
      this.openReaderCommentPanel(action.url, title, marker);
      return;
    }
    if (source) {
      VerificationSupport.requestVerification(action.url, title, source);
    }
    router.pushUrl({
      url: 'pages/VerifyWeb',
      params: {
        url: action.url,
        title: title,
        requireLoginCookie: 'false',
        readerCommentMode: 'false'
      }
    }).catch((error: Error) => {
      this.readerSourceActionOpenedAt = 0;
      console.error('打开网页失败:', error);
      promptAction.showToast({ message: `打开失败：${error.message || '路由跳转异常'}` });
    });
  }

  async openReaderSourceScriptAction(source: BookSource, action: ReaderActionData, marker: string): Promise<void> {
    const code = ReaderActionMarker.sourceScript(action.url);
    if (!code || !this.book) {
      promptAction.showToast({ message: '书源操作无效' });
      return;
    }
    const runtime = BookSourceStageWebRuntime.get();
    if (!await runtime.waitUntilAvailable(5000)) {
      promptAction.showToast({ message: '书源脚本运行环境未就绪' });
      return;
    }
    const request = new StageWebRuntimeRequest();
    request.applyStageBudget(SourceRuntimeStage.CONTENT);
    request.source = source;
    request.book = this.book;
    request.chapter = this.chapters.length > 0 ? this.chapters[this.clampChapterIndex(this.currentChapterIndex)] : null;
    request.baseUrl = request.chapter?.url || this.book.bookUrl || source.bookSourceUrl;
    request.code = code;
    request.readerActionMode = true;
    request.maxRequestCount = 3;
    request.maxResponseBytes = 2 * 1024 * 1024;
    request.maxTotalResponseBytes = 3 * 1024 * 1024;
    this.readerSourceActionOpenedAt = Date.now();
    try {
      const result = await runtime.execute(request);
      const target = (result.requestedUrl || '').trim();
      if (!/^https?:\/\//i.test(target)) {
        promptAction.showToast({ message: '书源操作未返回有效地址' });
        this.readerSourceActionOpenedAt = 0;
        return;
      }
      VerificationSupport.requestVerification(target, action.title || action.label || '段评', source);
      this.openReaderCommentPanel(target, action.title || action.label || '段评', marker,
        result.requestedHtml || '');
    } catch (error) {
      this.readerSourceActionOpenedAt = 0;
      const message = error instanceof Error ? error.message : String(error || '');
      promptAction.showToast({ message: `评论加载失败${message ? `：${message}` : ''}` });
    }
  }

  isReaderCommentAction(action: ReaderActionData): boolean {
    const metadata = `${action.label || ''}\n${action.title || ''}`;
    if (/段评|章评|神评论|评论|本章说/.test(metadata)) return true;
    return /\/(?:get_review|get_para_review|para_idea)(?:[/?#]|$)|[?&](?:review|comment)=/i.test(action.url || '');
  }

  openReaderCommentPanel(url: string, title: string, marker: string, sourceHtml: string = ''): void {
    const normalizedUrl = (url || '').trim();
    if (!/^https?:\/\//i.test(normalizedUrl)) {
      promptAction.showToast({ message: '评论地址无效' });
      return;
    }
    this.readerSourceActionOpenedAt = Date.now();
    this.readerCommentPanelLoadSerial++;
    if (this.readerCommentPanelReadyTimerId >= 0) {
      clearTimeout(this.readerCommentPanelReadyTimerId);
      this.readerCommentPanelReadyTimerId = -1;
    }
    this.readerCommentPanelTitle = title || '段评';
    this.readerCommentPanelHeightRatio = 0.6;
    this.readerCommentPanelDragStartRatio = 0.6;
    const providerPanel = ReaderInteractionProviderRegistry.buildPanel(normalizedUrl);
    if (sourceHtml) {
      this.readerCommentPanelHtmlLoaded = false;
      this.readerCommentPanelHtml = sourceHtml;
      this.readerCommentPanelBaseUrl = normalizedUrl;
      this.readerCommentPanelUrl = 'about:blank';
    } else if (providerPanel) {
      this.readerCommentPanelHtmlLoaded = false;
      this.readerCommentPanelHtml = providerPanel.html;
      this.readerCommentPanelBaseUrl = providerPanel.baseUrl;
      this.readerCommentPanelUrl = 'about:blank';
    } else {
      this.readerCommentPanelHtml = '';
      this.readerCommentPanelBaseUrl = '';
      this.readerCommentPanelUrl = normalizedUrl;
    }
    this.readerCommentPanelMarker = marker;
    this.readerCommentPanelProgress = 0;
    this.readerCommentPanelLoading = true;
    const markerBottom = this.getReaderSourceActionAnchorBottom(marker);
    this.readerCommentPanelAnchorBottom = markerBottom > 0 ? markerBottom :
      (this.readerCommentPageAreaTop >= 0 ? (this.readerCommentPageAreaTop + this.readerCommentPageAreaHeight) : -1);
    this.showReaderCommentPanel = true;
  }

  loadReaderCommentPanelHtmlIfNeeded(): boolean {
    if (!this.showReaderCommentPanel || !this.readerCommentPanelHtml || this.readerCommentPanelHtmlLoaded) {
      return false;
    }
    this.readerCommentPanelHtmlLoaded = true;
    try {
      const baseUrl = this.readerCommentPanelBaseUrl || 'about:blank';
      this.readerCommentPanelController.loadData(this.readerCommentPanelHtml, 'text/html', 'UTF-8', baseUrl, baseUrl);
      // Some ArkWeb versions do not emit a second onPageEnd for loadData. The embedded page owns its
      // network loading state, so reveal it after the document has been handed to the controller.
      this.scheduleReaderCommentPanelHostReady(180);
      return true;
    } catch (error) {
      this.readerCommentPanelHtmlLoaded = false;
      console.warn('加载原生评论面板失败:', error);
      this.scheduleReaderCommentPanelHostReady(0);
      return false;
    }
  }

  scheduleReaderCommentPanelHostReady(delayMs: number): void {
    if (this.readerCommentPanelReadyTimerId >= 0) clearTimeout(this.readerCommentPanelReadyTimerId);
    const serial = this.readerCommentPanelLoadSerial;
    this.readerCommentPanelReadyTimerId = setTimeout(() => {
      this.readerCommentPanelReadyTimerId = -1;
      if (!this.showReaderCommentPanel || serial !== this.readerCommentPanelLoadSerial) return;
      this.syncReaderCommentPanelWebTheme().finally(() => {
        if (this.showReaderCommentPanel && serial === this.readerCommentPanelLoadSerial) {
          this.readerCommentPanelLoading = false;
        }
      });
    }, Math.max(0, delayMs));
  }

  closeReaderCommentPanel(): void {
    this.readerCommentPanelLoadSerial++;
    if (this.readerCommentPanelReadyTimerId >= 0) {
      clearTimeout(this.readerCommentPanelReadyTimerId);
      this.readerCommentPanelReadyTimerId = -1;
    }
    this.showReaderCommentPanel = false;
    this.readerCommentPanelUrl = '';
    this.readerCommentPanelMarker = '';
    this.readerCommentPanelAnchorBottom = -1;
    this.readerCommentPanelProgress = 0;
    this.readerCommentPanelLoading = false;
    this.readerCommentPanelHtml = '';
    this.readerCommentPanelBaseUrl = '';
    this.readerCommentPanelHtmlLoaded = false;
    this.readerCommentPanelHeightRatio = 0.6;
    this.readerCommentPanelDragStartRatio = 0.6;
    this.readerCommentPanelController = new webview.WebviewController();
    this.readerSourceActionOpenedAt = 0;
  }

  async syncReaderCommentPanelWebTheme(): Promise<void> {
    if (!this.showReaderCommentPanel || !this.readerCommentPanelUrl) return;
    const scheme = this.appDarkMode ? 'dark' : 'light';
    const dark = this.appDarkMode ? 'true' : 'false';
    const script = `(function(){var scheme='${scheme}',dark=${dark};` +
      `var root=document.documentElement;if(root){root.style.colorScheme=scheme;` +
      `root.setAttribute('data-legado-color-scheme',scheme);}` +
      `var body=document.body,themeToggle=document.getElementById('themeToggle');` +
      `if(body&&themeToggle&&typeof window.toggleCmtTheme==='function'){` +
      `var pageDark=body.classList.contains('dark');` +
      `if(pageDark!==dark){window.toggleCmtTheme();}` +
      `try{window.localStorage.setItem('cmt-theme',scheme);}catch(_){}` +
      `body.classList.toggle('dark',dark);}` +
      `window.__LEGADO_COLOR_SCHEME__=scheme;window.__LEGADO_DARK_MODE__=dark;` +
      `window.dispatchEvent(new CustomEvent('legado-color-scheme-change',` +
      `{detail:{colorScheme:scheme,dark:dark}}));return scheme;})()`;
    try {
      await this.readerCommentPanelController.runJavaScript(script);
    } catch (error) {
      console.warn('同步评论面板深浅色模式失败:', error);
    }
  }

  readerCommentPanelHeight(): number {
    if (this.readerCommentPageAreaHeight <= 0) {
      return 432;
    }
    return Math.max(1, this.readerCommentPageAreaHeight *
      Math.max(0.6, Math.min(0.9, this.readerCommentPanelHeightRatio)));
  }

  readerCommentPanelContentHeight(): number {
    return this.readerCommentPanelHeight();
  }

  readerCommentPanelDragHandleHeight(): number {
    return 24;
  }

  getReaderSourceActionAnchorBottom(marker: string): number {
    const bounds = this.readerSourceActionAreas.get(marker) || [];
    if (bounds.length < 4) return -1;
    return bounds[bounds.length - 1];
  }

  getReaderEpubImageUri(marker: string): string {
    const path = LocalBookService.epubImagePathFromMarker(marker);
    if (!path) return '';
    if (/^(?:https?:|data:|file:)/i.test(path)) return path;
    try {
      return fileUri.getUriFromPath(path);
    } catch (_) {
      return path;
    }
  }

  getReaderEpubImageHeight(): number {
    const availableHeight = this.getReaderPaginationViewportHeight() -
      this.getReaderPaginationBottomInfoBarHeight();
    return Math.max(120, availableHeight);
  }

  @Builder
  readerParagraphGap(paragraph: ReaderTextParagraph,
    pageLineHeight: number = this.getEffectiveReaderLineHeight()) {
    if (!paragraph.isLast) {
      Blank()
        .height(this.getReaderParagraphBoundarySpacing(pageLineHeight))
        .width('100%')
    }
  }

  @Builder
  regexReaderText(paragraph: ReaderTextParagraph, ttsHighlightActive: boolean = true,
    ttsRenderVersion: number = this.ttsHighlightRenderVersion, contentRenderVersion: number = this.pageRenderVersion,
    pageRenderIdentity: string = '', pageStart: number = -1,
    documentSource: string = this.pagedContentText, pageLineHeight: number = this.getEffectiveReaderLineHeight()) {
    Text('', { controller: this.readerSelectableTextController(
      this.readerSelectableTextKey('regex', pageRenderIdentity, contentRenderVersion, ttsRenderVersion, paragraph)) }) {
      ForEach(this.getStyledParagraphTextSlices(paragraph, ttsHighlightActive, pageStart, documentSource),
        (slice: ReadTextSlice) => {
        this.styledRegexSlice(slice)
      }, (slice: ReadTextSlice) =>
        `${this.effectiveReaderPageRenderIdentity(pageRenderIdentity, this.currentChapterIndex, contentRenderVersion,
          ttsRenderVersion, paragraph.text)}_${paragraph.key}_${slice.key}`)
    }
    .lineSpacing(LengthMetrics.vp(this.getReaderPageLineSpacing(pageLineHeight)), { onlyBetweenLines: true })
    .halfLeading(false)
    .includeFontPadding(false)
    .fontColor(this.getTextColor())
    .letterSpacing(this.getReaderAdaptiveLetterSpacing())
    .textAlign(TextAlign.JUSTIFY)
    .wordBreak(WordBreak.BREAK_WORD)
    .lineBreakStrategy(LineBreakStrategy.GREEDY)
    .copyOption(CopyOptions.LocalDevice)
    .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
    .width('100%')
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.rememberReaderSelectableText(
        this.readerSelectableTextKey('regex', pageRenderIdentity, contentRenderVersion, ttsRenderVersion, paragraph),
        paragraph.text,
        newValue
      );
    })
    .id(`reader_regex_${this.effectiveReaderPageRenderIdentity(pageRenderIdentity, this.currentChapterIndex,
      contentRenderVersion, ttsRenderVersion, paragraph.text)}_${paragraph.key}`)
  }

  readerSelectableTextKey(kind: string, pageRenderIdentity: string, contentRenderVersion: number,
    ttsRenderVersion: number, paragraph: ReaderTextParagraph): string {
    return `${pageRenderIdentity}_${contentRenderVersion}_${ttsRenderVersion}_${kind}_${paragraph.key}`;
  }

  readerSelectableTextController(key: string): TextController {
    let controller = this.readerSelectableTextControllers.get(key);
    if (!controller) {
      controller = new TextController();
      this.readerSelectableTextControllers.set(key, controller);
      while (this.readerSelectableTextControllers.size > 160) {
        const oldest = this.readerSelectableTextControllers.keys().next().value as string | undefined;
        if (!oldest) break;
        this.readerSelectableTextControllers.delete(oldest);
      }
    }
    return controller;
  }

  rememberReaderSelectableText(key: string, text: string, area: Area,
    controller: TextController | null = null): void {
    const position = area.globalPosition;
    const left = Number(position.x);
    const top = Number(position.y);
    const right = left + Number(area.width);
    const bottom = top + Number(area.height);
    if (!key || !text || !Number.isFinite(left) || !Number.isFinite(top) ||
      !Number.isFinite(right) || !Number.isFinite(bottom) || right <= left || bottom <= top) return;
    this.readerSelectableTextAreas.set(key, [left, top, right, bottom]);
    this.readerSelectableTextValues.set(key, text);
    if (controller) this.readerSelectableTextControllers.set(key, controller);
    while (this.readerSelectableTextAreas.size > 160) {
      const oldest = this.readerSelectableTextAreas.keys().next().value as string | undefined;
      if (!oldest) break;
      this.readerSelectableTextAreas.delete(oldest);
      this.readerSelectableTextValues.delete(oldest);
      this.readerSelectableTextControllers.delete(oldest);
    }
  }

  selectReaderTextAtGlobalPoint(event: GestureEvent): void {
    if (event.fingerList.length === 0) return;
    const finger = event.fingerList[0];
    const globalX = Number(finger.globalX);
    const globalY = Number(finger.globalY);
    const currentIdentity = this.currentReaderPageRenderIdentity(this.pageRenderVersion,
      this.ttsHighlightRenderVersion);
    const continuousNovel = this.isReaderNovelContinuousScrollModeActive();
    let selectedKey = '';
    let selectedArea: number[] = [];
    let selectedAreaSize = Number.POSITIVE_INFINITY;
    for (const entry of this.readerSelectableTextAreas.entries()) {
      const key = entry[0];
      const area = entry[1];
      if ((!continuousNovel && !key.startsWith(currentIdentity)) || area.length < 4) continue;
      if (globalX >= area[0] && globalX <= area[2] && globalY >= area[1] && globalY <= area[3]) {
        const areaSize = (area[2] - area[0]) * (area[3] - area[1]);
        if (areaSize < selectedAreaSize) {
          selectedKey = key;
          selectedArea = area;
          selectedAreaSize = areaSize;
        }
      }
    }
    if (!selectedKey || selectedArea.length < 4) return;
    const text = this.readerSelectableTextValues.get(selectedKey) || '';
    this.showReaderTextSelection(selectedKey, text, globalX - selectedArea[0], globalY - selectedArea[1]);
  }

  showReaderTextSelection(key: string, text: string, localX: number, localY: number): void {
    if (!text) return;
    try {
      const controller = this.readerSelectableTextController(key);
      const layout = controller.getLayoutManager();
      // GestureEvent and Area coordinates are reported in vp, while the native text
      // typography queried by LayoutManager uses physical pixels.
      let position = layout.getGlyphPositionAtCoordinate(vp2px(localX), vp2px(localY)).position;
      position = Math.max(0, Math.min(text.length - 1, position));
      while (position < text.length - 1 && /\s/.test(text.charAt(position))) position++;
      while (position > 0 && /\s/.test(text.charAt(position))) position--;
      let start = position;
      let end = Math.min(text.length, position + 1);
      const wordPattern = /[A-Za-z0-9_]/;
      if (wordPattern.test(text.charAt(position))) {
        while (start > 0 && wordPattern.test(text.charAt(start - 1))) start--;
        while (end < text.length && wordPattern.test(text.charAt(end))) end++;
      } else {
        const code = text.charCodeAt(position);
        if (code >= 0xDC00 && code <= 0xDFFF && start > 0) start--;
        if (code >= 0xD800 && code <= 0xDBFF && end < text.length) end++;
      }
      this.readerTextSelectionUntil = Date.now() + 900;
      this.suppressReaderTapClick = true;
      this.readerTouchActive = false;
      this.readerPanActive = false;
      controller.setTextSelection(start, end, { menuPolicy: MenuPolicy.SHOW });
    } catch (error) {
      console.warn('正文长按选择失败:', error);
    }
  }

  @Builder
  styledRegexSlice(slice: ReadTextSlice) {
    if (this.shouldUseFullThemeRegexDecoration(slice)) {
      ContainerSpan() {
        ImageSpan(ThemeAssetRegistry.regexBubbleCap(this.getRegexSliceBubbleStyleId(slice)))
          .width(this.getRegexBubbleCapSize(slice))
          .height(this.getRegexBubbleCapSize(slice))
          .objectFit(ImageFit.Contain)
          .verticalAlign(ImageSpanAlignment.CENTER)
        Span(slice.text)
          .fontSize(this.getRegexSliceFontSize(slice))
          .fontFamily(this.getRegexSliceFontFamily(slice))
          .fontColor(this.getStyledSliceFontColor(slice))
          .textBackgroundStyle(slice.ttsHighlighted ? {
            color: this.getTtsHighlightColor(),
            radius: 4
          } : {})
          .textShadow(this.getStyledSliceTextShadow(slice))
          .decoration({ type: TextDecorationType.None })
        ImageSpan(ThemeAssetRegistry.regexBubbleCap(this.getRegexSliceBubbleStyleId(slice)))
          .width(this.getRegexBubbleCapSize(slice))
          .height(this.getRegexBubbleCapSize(slice))
          .objectFit(ImageFit.Contain)
          .verticalAlign(ImageSpanAlignment.CENTER)
          .rotate({ angle: 180 })
      }
      .textBackgroundStyle(this.getStyledSliceBackgroundStyle(slice))
    } else {
      Span(slice.text)
        .fontSize(slice.highlighted ? this.getRegexSliceFontSize(slice) : this.readerFontSize)
        .fontFamily(slice.highlighted ? this.getRegexSliceFontFamily(slice) : this.getBodyReaderFontFamily())
        .fontColor(this.getStyledSliceFontColor(slice))
        .textBackgroundStyle(this.getStyledSliceBackgroundStyle(slice))
        .textShadow(this.getStyledSliceTextShadow(slice))
        .decoration(this.getStyledSliceDecoration(slice))
    }
  }

  shouldUseFullThemeRegexDecoration(slice: ReadTextSlice): boolean {
    if (!slice.highlighted) return false;
    const style = this.resolvedRegexEmphasis(this.getRegexRuleBySlice(slice));
    return style.bubbleDecorationEnabled && ThemeAssetRegistry.hasRegexBubbleCap(style.bubbleStyleId);
  }

  getRegexSliceBubbleStyleId(slice: ReadTextSlice): string {
    return this.resolvedRegexEmphasis(this.getRegexRuleBySlice(slice)).bubbleStyleId;
  }

  getRegexBubbleCapSize(slice: ReadTextSlice): number {
    return Math.max(15, Math.min(22, this.getRegexSliceFontSize(slice) * 0.72));
  }

  @Builder
  framedRegexReaderText(paragraph: ReaderTextParagraph, ttsHighlightActive: boolean = true,
    ttsRenderVersion: number = this.ttsHighlightRenderVersion, contentRenderVersion: number = this.pageRenderVersion,
    pageRenderIdentity: string = '', pageStart: number = -1,
    documentSource: string = this.pagedContentText, pageLineHeight: number = this.getEffectiveReaderLineHeight()) {
    Text('', { controller: this.readerSelectableTextController(
      this.readerSelectableTextKey('frame', pageRenderIdentity, contentRenderVersion, ttsRenderVersion,
        paragraph)) }) {
      ForEach(this.getStyledParagraphTextSlices(paragraph, ttsHighlightActive, pageStart, documentSource),
        (slice: ReadTextSlice) => {
        Span(slice.text)
          .fontSize(slice.highlighted ? this.getRegexSliceFontSize(slice) : this.readerFontSize)
          .fontFamily(slice.highlighted ? this.getRegexSliceFontFamily(slice) : this.getBodyReaderFontFamily())
          .fontColor(this.getStyledSliceFontColor(slice))
          .textBackgroundStyle(slice.ttsHighlighted ? {
            color: this.getTtsHighlightColor(),
            radius: 4
          } : {})
          .textShadow(this.getStyledSliceTextShadow(slice))
          .decoration({ type: TextDecorationType.None })
      }, (slice: ReadTextSlice) =>
        `framed_${this.effectiveReaderPageRenderIdentity(pageRenderIdentity, this.currentChapterIndex,
          contentRenderVersion, ttsRenderVersion, paragraph.text)}_${paragraph.key}_${slice.key}`)
    }
    .lineSpacing(LengthMetrics.vp(this.getReaderPageLineSpacing(pageLineHeight)), { onlyBetweenLines: true })
    .halfLeading(false)
    .includeFontPadding(false)
    .fontColor(this.getTextColor())
    .letterSpacing(this.getReaderAdaptiveLetterSpacing())
    .textAlign(TextAlign.JUSTIFY)
    .wordBreak(WordBreak.BREAK_WORD)
    .lineBreakStrategy(LineBreakStrategy.GREEDY)
    .copyOption(CopyOptions.LocalDevice)
    .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
    .width('100%')
    .padding({
      left: this.getRegexFrameHorizontalPadding(paragraph, pageStart),
      right: this.getRegexFrameHorizontalPadding(paragraph, pageStart),
      top: this.getRegexFrameVerticalPadding(paragraph, pageStart),
      bottom: this.getRegexFrameVerticalPadding(paragraph, pageStart)
    })
    .backgroundColor(this.getRegexFrameBackgroundColor(paragraph, pageStart))
    .border({
      width: this.getRegexFrameBorderWidth(paragraph, pageStart),
      color: this.getRegexFrameBorderColor(paragraph, pageStart),
      style: this.getRegexFrameBorderStyle(paragraph, pageStart)
    })
    .borderRadius(this.getRegexFrameBorderRadius(paragraph, pageStart))
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.rememberReaderSelectableText(
        this.readerSelectableTextKey('frame', pageRenderIdentity, contentRenderVersion, ttsRenderVersion,
          paragraph),
        paragraph.text,
        newValue
      );
    })
    .overlay(() => {
      Image(this.getRegexParagraphFrame(paragraph, pageStart))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Fill)
        .resizable({
          slice: {
            left: this.getRegexFrameHorizontalSlice(paragraph, pageStart),
            right: this.getRegexFrameHorizontalSlice(paragraph, pageStart),
            top: this.getRegexFrameVerticalSlice(paragraph, pageStart),
            bottom: this.getRegexFrameVerticalSlice(paragraph, pageStart)
          }
        })
        .draggable(false)
        .hitTestBehavior(HitTestMode.None)
    }, { align: Alignment.Center })
    .id(`reader_regex_frame_${this.effectiveReaderPageRenderIdentity(pageRenderIdentity, this.currentChapterIndex,
      contentRenderVersion, ttsRenderVersion, paragraph.text)}_${paragraph.key}`)
  }

  shouldUseRegexParagraphFrame(paragraph: ReaderTextParagraph, pageStart: number = -1): boolean {
    return !!this.getRegexParagraphFrameStyleId(paragraph, pageStart);
  }

  getRegexParagraphFrame(paragraph: ReaderTextParagraph, pageStart: number = -1): ResourceStr {
    return ThemeAssetRegistry.regexBubbleFrame(this.getRegexParagraphFrameStyleId(paragraph, pageStart));
  }

  getRegexParagraphFrameStyleId(paragraph: ReaderTextParagraph, pageStart: number = -1): string {
    this.getRegexRules();
    const cacheKey = `${this.readerRegexFontEnabled ? '1' : '0'}_${this.cachedRegexRulesKey}_` +
      `${this.pageRenderVersion}_${pageStart}_${paragraph.key}`;
    if (this.regexFrameStyleCache.has(cacheKey)) {
      return this.regexFrameStyleCache.get(cacheKey) || '';
    }
    let styleId = '';
    if (this.readerRegexFontEnabled && paragraph.text.trim()) {
      const absoluteStart = pageStart < 0 ? -1 : pageStart + paragraph.start;
      styleId = this.getRegexFrameStyleIdFromSlices(this.getRegexTextSlicesAt(paragraph.text, absoluteStart));
    }
    if (this.regexFrameStyleCache.size >= 512) {
      this.regexFrameStyleCache.clear();
    }
    this.regexFrameStyleCache.set(cacheKey, styleId);
    return styleId;
  }

  getRegexParagraphFrameStyleIdForText(text: string): string {
    if (!this.readerRegexFontEnabled || !text.trim()) {
      return '';
    }
    return this.getRegexFrameStyleIdFromSlices(this.getRegexTextSlices(text));
  }

  getRegexFrameStyleIdFromSlices(slices: ReadTextSlice[]): string {
    let ruleIndex = -1;
    for (const slice of slices) {
      if (slice.highlighted) {
        if (ruleIndex < 0) {
          ruleIndex = slice.ruleIndex;
        } else if (ruleIndex !== slice.ruleIndex) {
          return '';
        }
      } else if (slice.text.trim()) {
        return '';
      }
    }
    const rules = this.getRegexRules();
    if (ruleIndex < 0 || ruleIndex >= rules.length) {
      return '';
    }
    const style = this.resolvedRegexEmphasis(rules[ruleIndex]);
    if (!style.bubbleDecorationEnabled) {
      return '';
    }
    return ThemeAssetRegistry.hasRegexBubbleFrame(style.bubbleStyleId) ? style.bubbleStyleId : '';
  }

  getRegexFrameHorizontalPadding(paragraph: ReaderTextParagraph, pageStart: number = -1): number {
    return this.getRegexFrameHorizontalPaddingForStyle(this.getRegexParagraphFrameStyleId(paragraph, pageStart));
  }

  getRegexFrameHorizontalPaddingForStyle(styleId: string): number {
    if (styleId === 'rose-frame') return 18;
    if (styleId === 'celadon-slip') return 16;
    if (styleId === 'strawberry-ribbon' || styleId === 'moon-halo') return 16;
    if (styleId === 'crimson-stamp' || styleId === 'warm-scroll') return 15;
    if (styleId === 'sword-talisman') return 16;
    if (styleId === 'qingluan-jade') return 18;
    if (styleId === 'pipi-soft-paw') return 18;
    return 14;
  }

  getRegexFrameVerticalPadding(paragraph: ReaderTextParagraph, pageStart: number = -1): number {
    return this.getRegexFrameVerticalPaddingForStyle(this.getRegexParagraphFrameStyleId(paragraph, pageStart));
  }

  getRegexFrameVerticalPaddingForStyle(styleId: string): number {
    if (styleId === 'rose-frame' || styleId === 'celadon-slip') return 7;
    if (styleId === 'strawberry-ribbon' || styleId === 'moon-halo') return 6;
    if (styleId === 'sword-talisman') return 6;
    if (styleId === 'qingluan-jade') return 7;
    if (styleId === 'pipi-soft-paw') return 7;
    return 5;
  }

  getRegexFrameBackgroundColor(paragraph: ReaderTextParagraph, pageStart: number = -1): string {
    const styleId = this.getRegexParagraphFrameStyleId(paragraph, pageStart);
    if (styleId === 'classic-glass') return this.isReaderThemeDark() ? '#162D6EA3' : '#104B9DE1';
    if (styleId === 'warm-scroll') return this.isReaderThemeDark() ? '#183C2B1E' : '#18E8CFA5';
    if (styleId === 'forest-dew') return this.isReaderThemeDark() ? '#163C6750' : '#1478A98A';
    if (styleId === 'ink-brush') return this.isReaderThemeDark() ? '#18283038' : '#105F6B74';
    if (styleId === 'neon-pulse') return this.isReaderThemeDark() ? '#1811162A' : '#1000D5FF';
    if (styleId === 'strawberry-ribbon') return this.isReaderThemeDark() ? '#18263544' : '#14F1B6BC';
    if (styleId === 'crimson-stamp') return this.isReaderThemeDark() ? '#188D211C' : '#109A2923';
    if (styleId === 'celadon-slip') return this.isReaderThemeDark() ? '#1828342D' : '#14E6EEE7';
    if (styleId === 'rose-frame') return this.isReaderThemeDark() ? '#182B171C' : '#14F8E7E1';
    if (styleId === 'moon-halo') return this.isReaderThemeDark() ? '#180A1627' : '#12DCEBFF';
    if (styleId === 'sword-talisman') return this.isReaderThemeDark() ? '#1822302B' : '#16476963';
    if (styleId === 'qingluan-jade') return this.isReaderThemeDark() ? '#1A263735' : '#18E3EBE7';
    if (styleId === 'pipi-soft-paw') return this.isReaderThemeDark() ? '#1A332721' : '#18FFF4E8';
    return '#00000000';
  }

  getRegexFrameBorderColor(paragraph: ReaderTextParagraph, pageStart: number = -1): string {
    const styleId = this.getRegexParagraphFrameStyleId(paragraph, pageStart);
    if (styleId === 'classic-glass') return '#804B9DE1';
    if (styleId === 'warm-scroll') return '#8CA9753D';
    if (styleId === 'forest-dew') return '#824F8063';
    if (styleId === 'ink-brush') return this.isReaderThemeDark() ? '#995F6B74' : '#8A283038';
    if (styleId === 'neon-pulse') return '#A000D5FF';
    if (styleId === 'strawberry-ribbon') return '#8FE1767D';
    if (styleId === 'crimson-stamp') return '#9A9A2923';
    if (styleId === 'celadon-slip') return '#94A96B5C';
    if (styleId === 'rose-frame') return '#A0A84550';
    if (styleId === 'moon-halo') return '#9678B9F3';
    if (styleId === 'sword-talisman') return '#9A6E817B';
    if (styleId === 'qingluan-jade') return '#A2B4935C';
    if (styleId === 'pipi-soft-paw') return this.isReaderThemeDark() ? '#9AE8A06F' : '#9AC46F45';
    return '#00000000';
  }

  getRegexFrameBorderWidth(paragraph: ReaderTextParagraph, pageStart: number = -1): number {
    const styleId = this.getRegexParagraphFrameStyleId(paragraph, pageStart);
    return styleId === 'neon-pulse' || styleId === 'ink-brush' ? 1.5 : 1;
  }

  getRegexFrameBorderStyle(paragraph: ReaderTextParagraph, pageStart: number = -1): BorderStyle {
    const styleId = this.getRegexParagraphFrameStyleId(paragraph, pageStart);
    if (styleId === 'forest-dew' || styleId === 'strawberry-ribbon') return BorderStyle.Dotted;
    if (styleId === 'ink-brush' || styleId === 'crimson-stamp') return BorderStyle.Dashed;
    return BorderStyle.Solid;
  }

  getRegexFrameBorderRadius(paragraph: ReaderTextParagraph, pageStart: number = -1): number {
    const styleId = this.getRegexParagraphFrameStyleId(paragraph, pageStart);
    if (styleId === 'forest-dew') return 18;
    if (styleId === 'classic-glass' || styleId === 'strawberry-ribbon') return 12;
    if (styleId === 'rose-frame' || styleId === 'moon-halo') return 10;
    if (styleId === 'sword-talisman') return 4;
    if (styleId === 'qingluan-jade') return 12;
    if (styleId === 'pipi-soft-paw') return 16;
    if (styleId === 'neon-pulse') return 5;
    return 1;
  }

  getRegexFrameHorizontalSlice(paragraph: ReaderTextParagraph, pageStart: number = -1): number {
    const styleId = this.getRegexParagraphFrameStyleId(paragraph, pageStart);
    if (styleId === 'rose-frame') return 46;
    if (styleId === 'celadon-slip') return 32;
    if (styleId === 'strawberry-ribbon' || styleId === 'crimson-stamp') return 40;
    if (styleId === 'sword-talisman') return 38;
    if (styleId === 'qingluan-jade') return 44;
    if (styleId === 'pipi-soft-paw') return 44;
    return 34;
  }

  getRegexFrameVerticalSlice(paragraph: ReaderTextParagraph, pageStart: number = -1): number {
    const styleId = this.getRegexParagraphFrameStyleId(paragraph, pageStart);
    if (styleId === 'rose-frame') return 28;
    if (styleId === 'celadon-slip') return 24;
    if (styleId === 'sword-talisman') return 24;
    if (styleId === 'qingluan-jade') return 28;
    if (styleId === 'pipi-soft-paw') return 28;
    return 22;
  }

  getTitleTextSlices(paragraph: ReaderTextParagraph, chapterIndex: number,
    ttsHighlightActive: boolean = true): ReadTextSlice[] {
    const title = this.getChapterTitle(chapterIndex);
    const titleText = paragraph.text.substring(0, Math.min(title.length, paragraph.text.length));
    return this.splitSliceByTtsHighlight({
      text: titleText,
      start: 0,
      end: titleText.length,
      highlighted: false,
      ruleIndex: -1,
      key: `title_plain_${this.buildTextSliceKey(titleText)}`
    }, paragraph.start, 0, ttsHighlightActive);
  }

  getTitleBodyTextSlices(paragraph: ReaderTextParagraph, chapterIndex: number,
    ttsHighlightActive: boolean = true, pageStart: number = -1,
    documentSource: string = this.pagedContentText): ReadTextSlice[] {
    const titleLength = Math.min(this.getChapterTitle(chapterIndex).length, paragraph.text.length);
    const bodyText = paragraph.text.substring(titleLength);
    return this.splitSlicesByTtsHighlight(
      this.getRegexTextSlicesAt(bodyText, pageStart < 0 ? -1 : pageStart + paragraph.start + titleLength,
        documentSource),
      paragraph.start, titleLength,
      ttsHighlightActive);
  }

  handleTocCurrentPositionClick(): void {
    if (this.tocQuickJumpArmed) {
      this.tocQuickJumpDraft = '';
      this.tocQuickJumpInputVisible = true;
      this.tocQuickJumpArmed = false;
      setTimeout(() => {
        focusControl.requestFocus('tocQuickJumpChapterInput');
      }, 50);
      return;
    }
    this.scrollTocToCurrentChapter();
    this.tocQuickJumpArmed = true;
  }

  submitTocQuickJump(): void {
    if (this.chapters.length === 0) {
      promptAction.showToast({ message: '暂无可定位的章节' });
      return;
    }
    const chapterNumber = Number.parseInt(this.tocQuickJumpDraft, 10);
    if (!Number.isFinite(chapterNumber) || chapterNumber < 1 || chapterNumber > this.chapters.length) {
      promptAction.showToast({ message: `章节序号范围为 1～${this.chapters.length}，请重新输入` });
      setTimeout(() => {
        focusControl.requestFocus('tocQuickJumpChapterInput');
      }, 50);
      return;
    }
    this.tocQuickJumpInputVisible = false;
    this.tocQuickJumpDraft = '';
    this.tocQuickJumpArmed = false;
    this.scrollTocToChapter(chapterNumber - 1, ScrollAlign.CENTER);
  }

  getStyledParagraphTextSlices(paragraph: ReaderTextParagraph, ttsHighlightActive: boolean = true,
    pageStart: number = -1, documentSource: string = this.pagedContentText): ReadTextSlice[] {
    return this.splitSlicesByTtsHighlight(
      this.getRegexTextSlicesAt(paragraph.text, pageStart < 0 ? -1 : pageStart + paragraph.start, documentSource),
      paragraph.start, 0,
      ttsHighlightActive);
  }

  splitSlicesByTtsHighlight(slices: ReadTextSlice[], paragraphStart: number, segmentOffset: number,
    ttsHighlightActive: boolean = true): ReadTextSlice[] {
    const result: ReadTextSlice[] = [];
    for (const slice of slices) {
      result.push(...this.splitSliceByTtsHighlight(slice, paragraphStart, segmentOffset, ttsHighlightActive));
    }
    return result;
  }

  splitSliceByTtsHighlight(slice: ReadTextSlice, paragraphStart: number, segmentOffset: number,
    ttsHighlightActive: boolean = true): ReadTextSlice[] {
    const sliceStart = segmentOffset + slice.start;
    const sliceEnd = segmentOffset + slice.end;
    const localHighlightStart = this.ttsHighlightStart - paragraphStart;
    const localHighlightEnd = this.ttsHighlightEnd - paragraphStart;
    if (!ttsHighlightActive || !this.shouldRenderTtsFocus() || this.ttsHighlightStart < 0 ||
      this.ttsHighlightEnd <= this.ttsHighlightStart || localHighlightEnd <= sliceStart ||
      localHighlightStart >= sliceEnd) {
      return [this.cloneStyledSlice(slice, sliceStart, sliceEnd, slice.text, false, 'plain')];
    }

    const overlapStart = Math.max(sliceStart, localHighlightStart);
    const overlapEnd = Math.min(sliceEnd, localHighlightEnd);
    const result: ReadTextSlice[] = [];
    if (overlapStart > sliceStart) {
      const beforeText = slice.text.substring(0, overlapStart - sliceStart);
      result.push(this.cloneStyledSlice(slice, sliceStart, overlapStart, beforeText, false, 'before_tts'));
    }
    const highlightText = slice.text.substring(overlapStart - sliceStart, overlapEnd - sliceStart);
    result.push(this.cloneStyledSlice(slice, overlapStart, overlapEnd, highlightText, true, 'tts'));
    if (overlapEnd < sliceEnd) {
      const afterText = slice.text.substring(overlapEnd - sliceStart);
      result.push(this.cloneStyledSlice(slice, overlapEnd, sliceEnd, afterText, false, 'after_tts'));
    }
    return result;
  }

  cloneStyledSlice(source: ReadTextSlice, start: number, end: number, text: string, ttsHighlighted: boolean,
    keyPrefix: string): ReadTextSlice {
    return {
      text: text,
      start: start,
      end: end,
      highlighted: source.highlighted,
      ruleIndex: source.ruleIndex,
      ttsHighlighted: ttsHighlighted,
      key: `${keyPrefix}_${start}_${end}_${source.ruleIndex}_${this.buildTextSliceKey(text)}`
    };
  }

  getStyledSliceFontColor(slice: ReadTextSlice): string {
    if (slice.ttsHighlighted) {
      return this.getTtsHighlightTextColor();
    }
    if (slice.highlighted) {
      return this.resolvedRegexEmphasis(this.getRegexRuleBySlice(slice)).textColor;
    }
    return this.getTextColor();
  }

  getStyledSliceBackgroundStyle(slice: ReadTextSlice): TextBackgroundStyle {
    if (slice.ttsHighlighted) {
      return { color: this.getTtsHighlightColor(), radius: 4 };
    }
    if (!slice.highlighted) {
      return {};
    }
    const style = this.resolvedRegexEmphasis(this.getRegexRuleBySlice(slice));
    if (!style.backgroundEnabled) {
      return {};
    }
    return {
      color: style.backgroundColor,
      radius: {
        topLeft: style.radiusTopLeft,
        topRight: style.radiusTopRight,
        bottomLeft: style.radiusBottomLeft,
        bottomRight: style.radiusBottomRight
      }
    };
  }

  getStyledSliceTextShadow(slice: ReadTextSlice): ShadowOptions | ShadowOptions[] {
    if (slice.ttsHighlighted || !slice.highlighted) {
      return { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 };
    }
    const style = this.resolvedRegexEmphasis(this.getRegexRuleBySlice(slice));
    if (style.textShadows.length > 0) {
      return style.textShadows;
    }
    return {
      radius: style.textShadowRadius,
      color: style.textShadowColor,
      offsetX: style.textShadowOffsetX,
      offsetY: style.textShadowOffsetY
    };
  }

  shouldUseTitleStyle(text: string, chapterIndex: number = this.currentChapterIndex): boolean {
    const title = this.getChapterTitle(chapterIndex).trim();
    return !!title && (text || '').startsWith(title);
  }

  shouldUseRegexStyle(text: string): boolean {
    return this.hasRegexMatch(text);
  }

  hasRegexMatch(text: string): boolean {
    if (!this.readerRegexFontEnabled) {
      return false;
    }
    const rules = this.getRegexRules();
    for (const rule of rules) {
      if (!rule.pattern.trim()) {
        continue;
      }
      try {
        if (new RegExp(rule.pattern).test(text || '')) {
          return true;
        }
      } catch (e) {
      }
    }
    return false;
  }

  getRegexRules(): ReaderRegexFontRule[] {
    const key = `${this.readerRegexFontRulesRaw}\n${this.readerRegexFontPattern}\n${this.readerRegexFontMode}\n` +
      `${this.readerRegexFontFamily}\n${this.readerRegexFontSize}\n${this.readerRegexShadowColor}`;
    if (key === this.cachedRegexRulesKey) {
      return this.cachedRegexRules;
    }
    const legacy = new ReaderRegexLegacySettings();
    legacy.pattern = this.readerRegexFontPattern;
    legacy.fontMode = this.readerRegexFontMode;
    legacy.fontFamily = this.readerRegexFontFamily;
    legacy.fontSize = this.readerRegexFontSize;
    legacy.shadowColor = this.readerRegexShadowColor;
    this.cachedRegexRules = ReaderRegexFontCodec.decode(this.readerRegexFontRulesRaw, legacy);
    this.cachedRegexRulesKey = key;
    return this.cachedRegexRules;
  }

  themeRegexEmphasisMode(): string {
    return ThemeRuntime.regexEmphasisMode();
  }

  themeRegexBubbleStyleId(): string {
    return ThemeRuntime.regexBubbleStyle();
  }

  themeRegexEmphasisColor(): string {
    return ThemeRuntime.regexEmphasisColor(this.appDarkMode);
  }

  readerRegexEmphasisContext(): ReaderRegexEmphasisContext {
    const context = new ReaderRegexEmphasisContext();
    context.inheritedMode = this.themeRegexEmphasisMode();
    context.inheritedBubbleStyleId = this.themeRegexBubbleStyleId();
    context.inheritedColor = this.themeRegexEmphasisColor();
    context.inheritedTextColor = ThemeRuntime.regexEmphasisTextColor(this.appDarkMode);
    context.accentColor = this.accentColor();
    context.surfaceColor = this.getBackgroundColor();
    context.normalTextColor = this.getTextColor();
    context.darkMode = this.isReaderThemeDark();
    return context;
  }

  resolvedRegexEmphasis(rule: ReaderRegexFontRule | null): ReaderResolvedRegexEmphasis {
    return ReaderRegexBubbleStyleResolver.resolve(rule, this.readerRegexEmphasisContext());
  }

  getRegexTextSlices(text: string): ReadTextSlice[] {
    const displayText = text || '';
    const rules = this.getRegexRules();
    if (!this.readerRegexFontEnabled || rules.length === 0) {
      return [{
        text: displayText,
        start: 0,
        end: displayText.length,
        highlighted: false,
        ruleIndex: -1,
        key: `plain_regex_${this.buildTextSliceKey(displayText)}`
      }];
    }
    try {
      const matched: ReadTextSlice[] = [];
      for (let ruleIndex = 0; ruleIndex < rules.length; ruleIndex++) {
        const rule = rules[ruleIndex];
        if (!rule.pattern.trim()) {
          continue;
        }
        let regex: RegExp;
        try {
          regex = new RegExp(rule.pattern, 'g');
        } catch (e) {
          continue;
        }
        let match = regex.exec(displayText);
        while (match && match.index >= 0) {
          const start = Math.max(0, match.index);
          const end = Math.max(start, Math.min(displayText.length, match.index + (match[0] || '').length));
          if (end <= start) {
            if (start >= displayText.length || regex.lastIndex >= displayText.length) {
              break;
            }
            regex.lastIndex = Math.max(regex.lastIndex + 1, start + 1);
            match = regex.exec(displayText);
            continue;
          }
          if (!this.hasOverlappedRegexSlice(matched, start, end)) {
            const matchText = displayText.substring(start, end);
            matched.push({
              text: matchText,
              start: start,
              end: end,
              highlighted: true,
              ruleIndex: ruleIndex,
              key: `regex_hit_${ruleIndex}_${start}_${end}_${this.buildTextSliceKey(matchText)}`
            });
          }
          regex.lastIndex = Math.max(regex.lastIndex, end);
          match = regex.exec(displayText);
        }
      }
      if (matched.length === 0) {
        return [{
          text: displayText,
          start: 0,
          end: displayText.length,
          highlighted: false,
          ruleIndex: -1,
          key: `plain_regex_${this.buildTextSliceKey(displayText)}`
        }];
      }
      matched.sort((a: ReadTextSlice, b: ReadTextSlice) => a.start - b.start);
      const slices: ReadTextSlice[] = [];
      let cursor = 0;
      for (const item of matched) {
        const start = Math.max(cursor, item.start);
        const end = Math.max(start, item.end);
        if (start > cursor) {
          const beforeText = displayText.substring(cursor, start);
          slices.push({
            text: beforeText,
            start: cursor,
            end: start,
            highlighted: false,
            ruleIndex: -1,
            key: `regex_plain_${cursor}_${start}_${this.buildTextSliceKey(beforeText)}`
          });
        }
        const matchText = displayText.substring(start, end);
        slices.push({
          text: matchText,
          start: start,
          end: end,
          highlighted: true,
          ruleIndex: item.ruleIndex,
          key: `regex_hit_${item.ruleIndex}_${start}_${end}_${this.buildTextSliceKey(matchText)}`
        });
        cursor = end;
      }
      if (cursor < displayText.length) {
        const afterText = displayText.substring(cursor);
        slices.push({
          text: afterText,
          start: cursor,
          end: displayText.length,
          highlighted: false,
          ruleIndex: -1,
          key: `regex_plain_${cursor}_${displayText.length}_${this.buildTextSliceKey(afterText)}`
        });
      }
      return slices;
    } catch (e) {
      return [{
        text: displayText,
        start: 0,
        end: displayText.length,
        highlighted: false,
        ruleIndex: -1,
        key: `plain_regex_error_${this.buildTextSliceKey(displayText)}`
      }];
    }
  }

  /**
   * 从整章的正则匹配结果中截取当前页面/段落。这样匹配范围即使跨过分页点，
   * 两页上的可见部分也会保持同一条高亮规则。
   */
  getRegexTextSlicesAt(text: string, absoluteStart: number,
    documentSource: string = this.pagedContentText): ReadTextSlice[] {
    const displayText = text || '';
    const source = documentSource || '';
    if (absoluteStart < 0 || !source) {
      return this.getRegexTextSlices(displayText);
    }
    return this.getRegexTextSlicesForDocumentRange(displayText, source, absoluteStart);
  }

  getRegexTextSlicesForDocumentRange(text: string, documentSource: string,
    absoluteStart: number): ReadTextSlice[] {
    const displayText = text || '';
    const source = documentSource || displayText;
    if (!displayText || absoluteStart < 0 || !source) {
      return this.getRegexTextSlices(displayText);
    }
    this.getRegexRules();
    const documentRulesKey = `${this.readerRegexFontEnabled ? '1' : '0'}_${this.cachedRegexRulesKey}`;
    if (this.cachedDocumentRegexSource !== source ||
      this.cachedDocumentRegexRulesKey !== documentRulesKey) {
      this.cachedDocumentRegexSource = source;
      this.cachedDocumentRegexRulesKey = documentRulesKey;
      this.cachedDocumentRegexSlices = this.getRegexTextSlices(source);
    }
    const absoluteEnd = Math.min(source.length, absoluteStart + displayText.length);
    const result: ReadTextSlice[] = [];
    let low = 0;
    let high = this.cachedDocumentRegexSlices.length;
    while (low < high) {
      const middle = Math.floor((low + high) / 2);
      if (this.cachedDocumentRegexSlices[middle].end <= absoluteStart) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    for (let index = low; index < this.cachedDocumentRegexSlices.length; index++) {
      const slice = this.cachedDocumentRegexSlices[index];
      if (slice.start >= absoluteEnd) break;
      const overlapStart = Math.max(slice.start, absoluteStart);
      const overlapEnd = Math.min(slice.end, absoluteEnd);
      if (overlapEnd <= overlapStart) continue;
      const localStart = overlapStart - absoluteStart;
      const localEnd = overlapEnd - absoluteStart;
      const sliceText = displayText.substring(localStart, localEnd);
      result.push({
        text: sliceText,
        start: localStart,
        end: localEnd,
        highlighted: slice.highlighted,
        ruleIndex: slice.ruleIndex,
        key: `document_regex_${slice.ruleIndex}_${overlapStart}_${overlapEnd}_` +
          `${this.buildTextSliceKey(sliceText)}`
      });
    }
    return result.length > 0 ? result : this.getRegexTextSlices(displayText);
  }

  hasOverlappedRegexSlice(slices: ReadTextSlice[], start: number, end: number): boolean {
    for (const slice of slices) {
      if (start < slice.end && end > slice.start) {
        return true;
      }
    }
    return false;
  }

  getRegexRuleBySlice(slice: ReadTextSlice): ReaderRegexFontRule | null {
    const rules = this.getRegexRules();
    if (!slice.highlighted || slice.ruleIndex < 0 || slice.ruleIndex >= rules.length) {
      return null;
    }
    return rules[slice.ruleIndex];
  }

  getRegexSliceFontSize(slice: ReadTextSlice): number {
    const rule = this.getRegexRuleBySlice(slice);
    return rule ? rule.fontSize : this.readerRegexFontSize;
  }

  getRegexSliceFontFamily(slice: ReadTextSlice): string {
    const rule = this.getRegexRuleBySlice(slice);
    return rule ? this.resolveStyledReaderFontFamily(rule.fontMode, rule.fontFamily) : this.getRegexReaderFontFamily();
  }

  getReadingTextSlices(text: string): ReadTextSlice[] {
    const displayText = this.getReadingRenderText(text);
    const start = this.ttsHighlightStart;
    const end = this.ttsHighlightEnd;
    if (!this.shouldRenderTtsFocus() || !this.ttsDisplayText || start < 0 || end <= start ||
      displayText !== this.ttsDisplayText) {
      return [{
        text: displayText,
        start: 0,
        end: displayText.length,
        highlighted: false,
        ruleIndex: -1,
        key: `plain_${this.buildTextSliceKey(displayText)}`
      }];
    }
    const clampedStart = Math.max(0, Math.min(start, displayText.length));
    const clampedEnd = Math.max(clampedStart, Math.min(end, displayText.length));
    const slices: ReadTextSlice[] = [];
    if (clampedStart > 0) {
      slices.push({
        text: displayText.substring(0, clampedStart),
        start: 0,
        end: clampedStart,
        highlighted: false,
        ruleIndex: -1,
        key: `before_${clampedStart}_${this.buildTextSliceKey(displayText.substring(0, clampedStart))}`
      });
    }
    const highlightedText = displayText.substring(clampedStart, clampedEnd);
    slices.push({
      text: highlightedText,
      start: clampedStart,
      end: clampedEnd,
      highlighted: true,
      ruleIndex: -1,
      key: `highlight_${clampedStart}_${clampedEnd}_${this.buildTextSliceKey(highlightedText)}`
    });
    if (clampedEnd < displayText.length) {
      const afterText = displayText.substring(clampedEnd);
      slices.push({
        text: afterText,
        start: clampedEnd,
        end: displayText.length,
        highlighted: false,
        ruleIndex: -1,
        key: `after_${clampedEnd}_${this.buildTextSliceKey(afterText)}`
      });
    }
    return slices;
  }

  getReadingTextSlicesInRange(text: string, start: number, end: number): ReadTextSlice[] {
    const displayText = text || '';
    if (!this.shouldRenderTtsFocus() || start < 0 || end <= start) {
      return [{
        text: displayText,
        start: 0,
        end: displayText.length,
        highlighted: false,
        ruleIndex: -1,
        key: `plain_${this.buildTextSliceKey(displayText)}`
      }];
    }
    const clampedStart = Math.max(0, Math.min(start, displayText.length));
    const clampedEnd = Math.max(clampedStart, Math.min(end, displayText.length));
    const slices: ReadTextSlice[] = [];
    if (clampedStart > 0) {
      const beforeText = displayText.substring(0, clampedStart);
      slices.push({
        text: beforeText,
        start: 0,
        end: clampedStart,
        highlighted: false,
        ruleIndex: -1,
        key: `before_${clampedStart}_${this.buildTextSliceKey(beforeText)}`
      });
    }
    const highlightedText = displayText.substring(clampedStart, clampedEnd);
    slices.push({
      text: highlightedText,
      start: clampedStart,
      end: clampedEnd,
      highlighted: true,
      ruleIndex: -1,
      key: `highlight_${clampedStart}_${clampedEnd}_${this.buildTextSliceKey(highlightedText)}`
    });
    if (clampedEnd < displayText.length) {
      const afterText = displayText.substring(clampedEnd);
      slices.push({
        text: afterText,
        start: clampedEnd,
        end: displayText.length,
        highlighted: false,
        ruleIndex: -1,
        key: `after_${clampedEnd}_${this.buildTextSliceKey(afterText)}`
      });
    }
    return slices;
  }

  hasActiveTtsHighlight(text: string): boolean {
    const displayText = this.getReadingRenderText(text);
    return this.shouldRenderTtsFocus() && !!this.ttsDisplayText &&
      this.ttsHighlightStart >= 0 && this.ttsHighlightEnd > this.ttsHighlightStart &&
      displayText === this.ttsDisplayText;
  }

  getReadingRenderText(text: string): string {
    const normalized = (text || '')
      .replace(/\r\n/g, '\n')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
    if (this.shouldRenderTtsFocus() && this.ttsDisplayText && normalized === this.ttsDisplayText) {
      return this.ttsDisplayText;
    }
    return text || '';
  }

  buildTextSliceKey(text: string): string {
    const value = text || '';
    const first = value.substring(0, Math.min(12, value.length));
    const last = value.substring(Math.max(0, value.length - 12));
    return `${value.length}_${this.hashText(first + last)}`;
  }

  hashText(text: string): number {
    let hash = 0;
    for (let i = 0; i < text.length; i++) {
      hash = ((hash * 31) + text.charCodeAt(i)) & 0x7fffffff;
    }
    return hash;
  }

  getTtsHighlightColor(): string {
    return this.isReaderThemeDark() ? '#5A4A24' : '#FFE58A';
  }

  getTtsHighlightTextColor(): string {
    return this.isReaderThemeDark() ? '#FFF4BF' : '#2F261D';
  }

  @Builder
  menuDismissLayer() {
    Blank()
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        this.hideReaderPanels();
      })
      .gesture(
        PanGesture({ direction: PanDirection.Horizontal })
          .onActionStart(() => {
            this.hideReaderPanels();
          })
      )
  }

  @Builder
  settingsDismissLayer() {
    Column() {
      Blank()
        .width('100%')
        .layoutWeight(1)
        .onClick(() => {
          this.closeSettingsPanelKeepMenu();
        })
      Blank()
        .width('100%')
        .height(520)
    }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
  }

  hideReaderPanels() {
    this.menuChapterPreviewIndex = this.currentChapterIndex;
    this.menuChapterSliderActive = false;
    this.menuChapterTooltipVisible = false;
    this.showReaderActionMenu = false;
    this.showLayoutElementSettings = false;
    if (!this.txtCharsetApplying) this.showTxtCharsetDialog = false;
    this.showMenu = false;
    this.showTtsVoiceDropdown = false;
    this.showSettings = false;
    if (this.showReaderCommentPanel) {
      this.closeReaderCommentPanel();
    }
  }

  async exitReaderPage(): Promise<void> {
    if (this.readerExitProgressSaved) {
      return;
    }
    this.clearReaderPagedProgressSaveTimer();
    this.hideReaderPanels();
    if (this.openedFromShortcut) {
      this.readerExitProgressSaved = true;
      this.saveReadingProgress(true).then(() => {
        return CloudSyncCoordinator.syncAutomatically(
          getContext(this), CloudSyncCoordinator.TRIGGER_CHANGE);
      }).catch((error: Error) => {
        console.error('快捷入口返回时保存进度失败:', error);
      });
      try {
        if (this.shortcutReplacedPreviousPage) {
          await router.replaceUrl({ url: 'pages/Index' });
        } else {
          router.back();
        }
      } catch (e) {
        console.error('快捷入口返回书架失败:', e);
      }
      return;
    }
    try {
      await this.saveReadingProgress(true);
      this.readerExitProgressSaved = true;
      CloudSyncCoordinator.syncAutomatically(
        getContext(this), CloudSyncCoordinator.TRIGGER_CHANGE).catch((error: Error) => {
        console.warn('离开阅读页同步进度失败:', error);
      });
    } catch (e) {
      console.error('返回阅读页时保存进度失败:', e);
    }
    if (this.openedWithShelfAnimation) {
      AppStorage.setOrCreate('shelfBookCloseAnimationUrl', this.bookUrl);
      AppStorage.setOrCreate('shelfBookCloseAnimationNonce', Date.now());
    }
    router.back();
  }

  paginateReaderSourceText(source: string, chapterIndex: number = this.currentChapterIndex): ReaderPaginationResult {
    const text = source || '';
    if (!text || this.pageViewWidth <= 0 || this.pageViewHeight <= 0) {
      return {
        source: text,
        pages: text ? [text] : [],
        starts: text ? [0] : [],
        ends: text ? [text.length] : []
      };
    }
    if (LocalBookService.hasEpubImageMarkers(text)) {
      return this.paginateReaderImageSourceText(text, chapterIndex);
    }

    const horizontalPadding = this.readerMarginLeft + this.readerMarginRight;
    const verticalPadding = this.readerMarginTop + this.getReaderContentBottomPadding() +
      this.getReaderPaginationBottomInfoBarHeight() + this.getReaderPaginationRenderGuardHeight();
    const columnWidth = this.getReaderPageColumnWidth();
    const availableWidth = Math.max(1, columnWidth - horizontalPadding);
    const availableHeight = Math.max(1, this.getReaderPaginationViewportHeight() - verticalPadding);
    const measuredAvailableHeight = this.toMeasurePx(availableHeight) + this.getReaderPaginationHeightTolerancePx();
    const pages: string[] = [];
    const starts: number[] = [];
    const ends: number[] = [];
    let cursor = 0;

    while (cursor < text.length) {
      const measuredEnd = this.findMeasuredPageEnd(text, cursor, availableWidth, measuredAvailableHeight, chapterIndex);
      const end = this.adjustReaderActionMarkerPageEnd(text, cursor, measuredEnd);
      if (end <= cursor) {
        break;
      }
      this.pushReaderPage(text, cursor, end, pages, starts, ends);
      cursor = end;
    }

    return {
      source: text,
      pages: pages.length > 0 ? pages : [text],
      starts: starts.length > 0 ? starts : [0],
      ends: ends.length > 0 ? ends : [text.length]
    };
  }

  getStyledSliceDecoration(slice: ReadTextSlice): DecorationStyleInterface {
    if (slice.ttsHighlighted || !slice.highlighted) {
      return { type: TextDecorationType.None };
    }
    const style = this.resolvedRegexEmphasis(this.getRegexRuleBySlice(slice));
    if (!style.decorationEnabled) {
      return { type: TextDecorationType.None };
    }
    return {
      type: TextDecorationType.Underline,
      color: style.decorationColor,
      style: this.regexDecorationStyle(style.decorationStyleId)
    };
  }

  regexDecorationStyle(styleId: string): TextDecorationStyle {
    if (styleId === 'double') return TextDecorationStyle.DOUBLE;
    if (styleId === 'dotted') return TextDecorationStyle.DOTTED;
    if (styleId === 'dashed') return TextDecorationStyle.DASHED;
    if (styleId === 'wavy') return TextDecorationStyle.WAVY;
    return TextDecorationStyle.SOLID;
  }

  paginateReaderImageSourceText(source: string,
    chapterIndex: number = this.currentChapterIndex): ReaderPaginationResult {
    const pages: string[] = [];
    const starts: number[] = [];
    const ends: number[] = [];
    let cursor = 0;
    while (cursor < source.length) {
      const markerStart = source.indexOf(LocalBookService.EPUB_IMAGE_MARKER_PREFIX, cursor);
      if (markerStart < 0) {
        this.appendReaderTextSegmentPages(source, cursor, source.length, chapterIndex, pages, starts, ends);
        break;
      }
      this.appendReaderTextSegmentPages(source, cursor, markerStart, chapterIndex, pages, starts, ends);
      const suffix = source.indexOf(LocalBookService.EPUB_IMAGE_MARKER_SUFFIX,
        markerStart + LocalBookService.EPUB_IMAGE_MARKER_PREFIX.length);
      if (suffix < 0) {
        this.appendReaderTextSegmentPages(source, markerStart, source.length, chapterIndex, pages, starts, ends);
        break;
      }
      const markerEnd = suffix + LocalBookService.EPUB_IMAGE_MARKER_SUFFIX.length;
      pages.push(source.substring(markerStart, markerEnd));
      starts.push(markerStart);
      ends.push(markerEnd);
      cursor = markerEnd;
    }
    return {
      source: source,
      pages: pages.length > 0 ? pages : [source],
      starts: starts.length > 0 ? starts : [0],
      ends: ends.length > 0 ? ends : [source.length]
    };
  }

  appendReaderTextSegmentPages(source: string, start: number, end: number, chapterIndex: number,
    pages: string[], starts: number[], ends: number[]): void {
    if (end <= start) return;
    const segment = source.substring(start, end);
    if (!segment.trim()) return;
    const result = this.paginateReaderSourceText(segment, chapterIndex);
    for (let i = 0; i < result.pages.length; i++) {
      pages.push(result.pages[i]);
      starts.push(start + (result.starts[i] || 0));
      ends.push(start + (result.ends[i] || segment.length));
    }
  }

  buildReaderPaginationCacheKey(chapterIndex: number, source: string): string {
    // Bump whenever page-boundary semantics change. Reusing offsets produced before action-marker-aware
    // pagination can make a valid comment marker appear as raw text even though the chapter body is unchanged.
    return `reader_page_v34_${chapterIndex}_${this.pageViewWidth}_${this.getReaderPaginationViewportHeight()}_` +
      `${this.readerExtendToStatusBar}_${this.isLandscapeDoublePageActive()}_${this.readerTypographyCacheIdentity()}_` +
      `${source.length}_${this.hashText(source)}`;
  }

  readerTypographyCacheIdentity(): string {
    const regexIdentity = `${this.readerRegexFontEnabled}_${this.readerRegexFontRulesRaw}_` +
      `${this.readerRegexFontPattern}_${this.readerRegexFontMode}_${this.readerRegexFontFamily}_` +
      `${this.readerRegexFontSize}_${this.readerRegexShadowColor}_${this.themeRevision}_` +
      `${this.themeRegexEmphasisMode()}_${this.themeRegexBubbleStyleId()}_reader_action_layout_v4`;
    return `${this.readerFontSize}_${this.readerLineHeight}_${this.readerParagraphSpacing}_` +
      `${this.readerMarginLeft}_${this.readerMarginRight}_${this.readerMarginTop}_${this.readerMarginBottom}_` +
      `${this.readerBodyFontMode}_${this.readerBodyFontFamily}_${this.getBodyReaderFontFamily()}_` +
      `${this.readerTitleFontSize}_${this.readerTitleFontMode}_${this.readerTitleFontFamily}_` +
      `${this.getTitleReaderFontFamily()}_${this.getReaderFontFamily()}_${this.hashText(regexIdentity)}`;
  }

  getCachedReaderPagination(chapterIndex: number, source: string): ReaderPaginationResult | null {
    const key = this.buildReaderPaginationCacheKey(chapterIndex, source);
    return this.readerPaginationCache.get(key) || null;
  }

  getOrCreateReaderPagination(chapterIndex: number, source: string,
    preferredInitialPageCount: number = 0): ReaderPaginationResult {
    const key = this.buildReaderPaginationCacheKey(chapterIndex, source);
    let result = this.readerPaginationCache.get(key);
    const defaultDesiredPageCount = chapterIndex === this.currentChapterIndex ?
      Math.max(READER_CURRENT_PAGINATION_AHEAD_PAGE_COUNT,
        (this.pendingRestorePageIndex >= 0 ? this.pendingRestorePageIndex : this.currentPageIndex) +
        READER_CURRENT_PAGINATION_AHEAD_PAGE_COUNT) : READER_ADJACENT_PAGINATION_PREVIEW_PAGE_COUNT;
    const desiredPageCount = preferredInitialPageCount > 0 ?
      Math.max(1, Math.round(preferredInitialPageCount)) : defaultDesiredPageCount;
    if (!result) {
      result = this.createIncrementalReaderPagination(source, chapterIndex, desiredPageCount);
      this.readerPaginationCache.set(key, result);
      while (this.readerPaginationCache.size > 6) {
        const oldestKey = this.readerPaginationCache.keys().next().value as string | undefined;
        if (!oldestKey) break;
        this.readerPaginationCache.delete(oldestKey);
      }
    } else if (!result.complete && result.pages.length < desiredPageCount) {
      this.appendReaderPaginationBatch(result, chapterIndex, desiredPageCount - result.pages.length);
    }
    if (chapterIndex === this.currentChapterIndex) {
      this.updateReaderComicPaginationProgress(chapterIndex, result);
    }
    if (chapterIndex === this.currentChapterIndex && !result.complete) {
      this.scheduleReaderPaginationCompletion(chapterIndex, key, result);
    } else if (result.complete) {
      this.persistReaderPagination(chapterIndex, key, result);
    }
    return result;
  }

  createIncrementalReaderPagination(source: string, chapterIndex: number,
    initialPageCount: number): ReaderPaginationResult {
    const text = source || '';
    if (!text || this.pageViewWidth <= 0 || this.pageViewHeight <= 0) {
      const completeResult = this.paginateReaderSourceText(text, chapterIndex);
      completeResult.cursor = text.length;
      completeResult.complete = true;
      return completeResult;
    }
    const result: ReaderPaginationResult = {
      source: text,
      pages: [],
      starts: [],
      ends: [],
      cursor: 0,
      complete: false
    };
    // Publish only the first visible spread synchronously. Restoring a later page and preparing adjacent
    // chapters continue through the cooperative scheduler instead of measuring many pages in one ArkUI turn.
    const visibleSpreadSize = this.isLandscapeDoublePageActive() ? 2 : 1;
    const initialBatchSize = Math.min(visibleSpreadSize, Math.max(1, initialPageCount));
    // appendReaderPaginationBatch yields after its time budget once it has produced at least one page.
    // On a slower first layout that can leave a double-page spread with only its left page until the
    // next interaction publishes more pagination. Complete the small visible spread here; background
    // pagination remains cooperative and incremental for everything after it.
    while (!result.complete && result.pages.length < initialBatchSize) {
      const previousPageCount = result.pages.length;
      this.appendReaderPaginationBatch(result, chapterIndex, initialBatchSize - previousPageCount);
      if (result.pages.length <= previousPageCount) break;
    }
    return result;
  }

  appendReaderPaginationBatch(result: ReaderPaginationResult, chapterIndex: number, maxPages: number,
    timeBudgetMs: number = 8): void {
    if (result.complete || maxPages <= 0) return;
    const batchStartedAt = Date.now();
    const text = result.source || '';
    if (!text || this.pageViewWidth <= 0 || this.pageViewHeight <= 0) {
      result.complete = true;
      result.cursor = text.length;
      return;
    }
    const horizontalPadding = this.readerMarginLeft + this.readerMarginRight;
    const verticalPadding = this.readerMarginTop + this.getReaderContentBottomPadding() +
      this.getReaderPaginationBottomInfoBarHeight() + this.getReaderPaginationRenderGuardHeight();
    const columnWidth = this.getReaderPageColumnWidth();
    const availableWidth = Math.max(1, columnWidth - horizontalPadding);
    const availableHeight = Math.max(1, this.getReaderPaginationViewportHeight() - verticalPadding);
    const measuredHeight = this.toMeasurePx(availableHeight) + this.getReaderPaginationHeightTolerancePx();
    let cursor = Math.max(0, Math.min(result.cursor || 0, text.length));
    let appended = 0;
    while (cursor < text.length && appended < maxPages) {
      while (cursor < text.length && this.isReaderTrimChar(text.charAt(cursor))) cursor++;
      if (cursor >= text.length) break;

      // Remote sources also use the EPUB image marker for inline illustrations,
      // paragraph-comment SVG bubbles and author cards. Keep those markers intact
      // but paginate them incrementally; completing the whole mixed chapter inside
      // one vSync can block ArkUI long enough for the system watchdog to kill us.
      const imageMarkerStart = text.indexOf(LocalBookService.EPUB_IMAGE_MARKER_PREFIX, cursor);
      let imageMarkerEnd = -1;
      if (imageMarkerStart >= 0) {
        const suffix = text.indexOf(LocalBookService.EPUB_IMAGE_MARKER_SUFFIX,
          imageMarkerStart + LocalBookService.EPUB_IMAGE_MARKER_PREFIX.length);
        if (suffix >= 0) imageMarkerEnd = suffix + LocalBookService.EPUB_IMAGE_MARKER_SUFFIX.length;
      }
      if (imageMarkerStart === cursor && imageMarkerEnd > cursor) {
        this.pushReaderPage(text, cursor, imageMarkerEnd, result.pages, result.starts, result.ends);
        cursor = imageMarkerEnd;
        appended++;
        if (Date.now() - batchStartedAt >= Math.max(1, timeBudgetMs)) break;
        continue;
      }

      const beforeCount = result.pages.length;
      let measuredEnd = 0;
      if (imageMarkerStart > cursor && imageMarkerEnd > imageMarkerStart) {
        const textSegment = text.substring(cursor, imageMarkerStart);
        const segmentEnd = this.findMeasuredPageEnd(textSegment, 0, availableWidth, measuredHeight, chapterIndex);
        measuredEnd = cursor + segmentEnd;
      } else {
        measuredEnd = this.findMeasuredPageEnd(text, cursor, availableWidth, measuredHeight, chapterIndex);
      }
      const end = this.adjustReaderActionMarkerPageEnd(text, cursor, measuredEnd);
      if (end <= cursor) break;
      this.pushReaderPage(text, cursor, end, result.pages, result.starts, result.ends);
      cursor = end;
      if (result.pages.length > beforeCount) appended++;
      if (appended > 0 && Date.now() - batchStartedAt >= Math.max(1, timeBudgetMs)) break;
    }
    while (cursor < text.length && this.isReaderTrimChar(text.charAt(cursor))) cursor++;
    result.cursor = cursor;
    result.complete = cursor >= text.length;
    CooperativeScheduler.reportSynchronousOperation('reader/pagination-batch', Date.now() - batchStartedAt,
      `pages=${appended},cursor=${cursor}/${text.length}`);
  }

  scheduleReaderPaginationCompletion(chapterIndex: number, key: string,
    result: ReaderPaginationResult): void {
    const serial = ++this.readerPaginationWorkSerial;
    const imageOnlyPagination = this.isReaderImageOnlySource(result.source);
    const batchDelay = ReaderActionMarker.has(result.source) ?
      READER_INTERACTIVE_PAGINATION_BATCH_DELAY_MS : READER_PAGINATION_BATCH_DELAY_MS;
    const runBatch = (): void => {
      if (serial !== this.readerPaginationWorkSerial || chapterIndex !== this.currentChapterIndex ||
        this.readerPaginationCache.get(key) !== result) {
        return;
      }
      if (this.isReaderPaginationInteractionBusy()) {
        setTimeout(runBatch, READER_PAGINATION_BUSY_RETRY_DELAY_MS);
        return;
      }
      // Text measurement and paragraph layout both run on the UI thread. Keep each idle batch small and do not
      // publish every intermediate array: repeated @State replacements rebuild the reader while a page is moving.
      const batchStartedAt = Date.now();
      // A pure comic page is already delimited by an image marker and requires no text measurement. Parse a small
      // group per idle slice so large comics finish promptly without turning the whole chapter into one UI task.
      this.appendReaderPaginationBatch(result, chapterIndex, imageOnlyPagination ? 8 : 1);
      const batchElapsedMs = Math.max(0, Date.now() - batchStartedAt);
      if (result.complete) {
        this.publishCurrentReaderPagination(result);
        this.persistReaderPagination(chapterIndex, key, result);
        this.updateReaderComicPaginationProgress(chapterIndex, result);
        return;
      }
      this.updateReaderComicPaginationProgress(chapterIndex, result);
      const adaptiveDelay = batchElapsedMs >= CooperativeScheduler.SLOW_OPERATION_MS ?
        Math.min(240, Math.max(batchDelay, batchElapsedMs * 2)) : batchDelay;
      setTimeout(runBatch, adaptiveDelay);
    };
    setTimeout(runBatch, batchDelay);
  }

  isReaderPaginationInteractionBusy(): boolean {
    return this.showReaderCommentPanel || this.isPageTurning || this.readerPanActive || this.readerTouchActive ||
      this.readerComicPanMoved || this.readerComicBoundaryDirection !== 0 || this.readerComicChapterSwitching ||
      this.pageSlideDirection !== 0 || this.pageTurnAnimating || Date.now() < this.readerPaginationInteractionIdleUntil;
  }

  deferReaderPaginationForInteraction(idleDelayMs: number = 420): void {
    this.readerPaginationInteractionIdleUntil = Math.max(this.readerPaginationInteractionIdleUntil,
      Date.now() + Math.max(0, idleDelayMs));
  }

  publishCurrentReaderPagination(result: ReaderPaginationResult): void {
    if (this.currentChapterIndex < 0 || this.pagedContentText !== result.source) return;
    const pendingRestore = this.pendingRestorePageIndex;
    const secondaryPageIndex = this.currentPageIndex + 1;
    const shouldRefreshCompletedSpread = this.isLandscapeDoublePageActive() &&
      secondaryPageIndex >= this.contentPages.length && secondaryPageIndex < result.pages.length;
    this.contentPages = [...result.pages];
    this.contentPageStarts = [...result.starts];
    this.contentPageEnds = [...result.ends];
    this.restorePendingPageIndex(result.complete === true);
    this.readerInitialPageReady = this.pendingRestorePageIndex < 0;
    if (pendingRestore >= 0 && this.pendingRestorePageIndex < 0) {
      this.setCurrentPageText(this.contentPages[this.currentPageIndex] || '');
    } else if (shouldRefreshCompletedSpread) {
      // The current page surface is keyed by its render version. Merely replacing contentPages updates
      // counters, but a retained ForEach surface can keep the formerly empty right page until a turn.
      this.refreshReaderTextRender();
    }
    const restoredPendingPosition = pendingRestore >= 0 && this.pendingRestorePageIndex < 0;
    if (this.isReaderContinuousScrollSurfaceActive()) {
      if (restoredPendingPosition) this.readerComicScrollRestoring = true;
      this.syncReaderComicPageDataSource();
      if (restoredPendingPosition) this.scheduleReaderComicScrollRestore();
    }
  }

  persistReaderPagination(chapterIndex: number, key: string, result: ReaderPaginationResult): void {
    if (!result.complete || !this.bookUrl || result.starts.length === 0 ||
      result.starts.length !== result.ends.length) {
      return;
    }
    AppDatabase.getInstance().saveReaderPaginationCache(this.bookUrl, chapterIndex, key,
      result.starts, result.ends).catch((error: Error) => {
      console.warn('保存阅读分页缓存失败:', error);
    });
  }

  applyPreparedReaderPagination(content: string, chapterIndex: number, createIfMissing: boolean): boolean {
    if (!content || !this.hasPagedReaderArea()) return false;
    const source = this.buildPagedSourceText(chapterIndex, content);
    const cached = this.getCachedReaderPagination(chapterIndex, source);
    if (!cached && !createIfMissing) return false;
    // Crossing a chapter only needs its first spread immediately. Measuring eight pages or waiting for the
    // persisted cache before publishing page one makes the completed swipe appear frozen on fast input.
    const result = this.getOrCreateReaderPagination(chapterIndex, source,
      createIfMissing ? READER_ADJACENT_PAGINATION_PREVIEW_PAGE_COUNT : 0);
    this.applyReaderPaginationResult(result, content);
    return true;
  }

  async restorePersistedReaderPagination(content: string, chapterIndex: number): Promise<boolean> {
    if (!content || !this.bookUrl || !this.hasPagedReaderArea()) return false;
    const source = this.buildPagedSourceText(chapterIndex, content);
    const key = this.buildReaderPaginationCacheKey(chapterIndex, source);
    const record = await AppDatabase.getInstance().getReaderPaginationCache(this.bookUrl, chapterIndex, key);
    if (!record || record.starts.length !== record.ends.length) return false;
    const pages: string[] = [];
    let previousEnd = 0;
    for (let i = 0; i < record.starts.length; i++) {
      const start = record.starts[i];
      const end = record.ends[i];
      if (start < 0 || end <= start || end > source.length || start < previousEnd) return false;
      pages.push(source.substring(start, end));
      previousEnd = end;
    }
    if (pages.length === 0) return false;
    const result: ReaderPaginationResult = {
      source: source,
      pages: pages,
      starts: record.starts,
      ends: record.ends,
      cursor: source.length,
      complete: true
    };
    this.readerPaginationCache.set(key, result);
    this.updateReaderComicPaginationProgress(chapterIndex, result);
    this.applyReaderPaginationResult(result, content);
    return true;
  }

  preloadNextChapterPaginationLater(delayMs: number = 120): void {
    if (!this.readerPreloadEnabled || !this.hasPagedReaderArea() ||
      this.currentChapterIndex >= this.chapters.length - 1) {
      return;
    }
    const sourceChapterIndex = this.currentChapterIndex;
    const targetChapterIndex = sourceChapterIndex + 1;
    const serial = ++this.adjacentPaginationPreloadSerial;
    setTimeout(() => {
      if (serial !== this.adjacentPaginationPreloadSerial ||
        (this.currentChapterIndex !== sourceChapterIndex && this.currentChapterIndex !== targetChapterIndex)) {
        return;
      }
      ReadBookEngine.get().peekContent(targetChapterIndex)
        .then(async (body: string): Promise<void> => {
          if (!body || serial !== this.adjacentPaginationPreloadSerial ||
            (this.currentChapterIndex !== sourceChapterIndex && this.currentChapterIndex !== targetChapterIndex)) {
            return;
          }
          const processed = await this.prepareReaderContentRules(body, targetChapterIndex);
          const source = this.buildPagedSourceText(targetChapterIndex, processed);
          const key = this.buildReaderPaginationCacheKey(targetChapterIndex, source);
          const result = this.getCachedReaderPagination(targetChapterIndex, source) ||
            this.getOrCreateReaderPagination(targetChapterIndex, source);
          this.scheduleNextChapterPaginationCompletion(sourceChapterIndex, targetChapterIndex, key, result, serial);
        })
        .catch((err: Error) => {
          console.error('预排版下一章失败:', err);
        });
    }, Math.max(0, delayMs));
  }

  scheduleNextChapterPaginationCompletion(sourceChapterIndex: number, targetChapterIndex: number, key: string,
    result: ReaderPaginationResult, serial: number): void {
    if (result.complete) {
      this.persistReaderPagination(targetChapterIndex, key, result);
      return;
    }
    const batchDelay = ReaderActionMarker.has(result.source) ?
      READER_INTERACTIVE_PAGINATION_BATCH_DELAY_MS : READER_PAGINATION_BATCH_DELAY_MS;
    const runBatch = (): void => {
      if (serial !== this.adjacentPaginationPreloadSerial || this.currentChapterIndex !== sourceChapterIndex ||
        this.readerPaginationCache.get(key) !== result) return;
      if (this.isReaderPaginationInteractionBusy()) {
        setTimeout(runBatch, READER_PAGINATION_BUSY_RETRY_DELAY_MS);
        return;
      }
      const startedAt = Date.now();
      this.appendReaderPaginationBatch(result, targetChapterIndex, 1);
      if (result.complete) {
        this.persistReaderPagination(targetChapterIndex, key, result);
        console.info(`[ReaderPreload] next chapter=${targetChapterIndex} pages=${result.pages.length} ` +
          `lastBatch=${Date.now() - startedAt}ms`);
        return;
      }
      const elapsedMs = Math.max(0, Date.now() - startedAt);
      const nextDelay = elapsedMs >= CooperativeScheduler.SLOW_OPERATION_MS ?
        Math.min(240, Math.max(batchDelay, elapsedMs * 2)) : batchDelay;
      setTimeout(runBatch, nextDelay);
    };
    setTimeout(runBatch, batchDelay);
  }

  preloadPreviousChapterPaginationLater(delayMs: number = 180): void {
    if (!this.readerPreloadEnabled || !this.hasPagedReaderArea() || this.currentChapterIndex <= 0) return;
    const sourceChapterIndex = this.currentChapterIndex;
    const targetChapterIndex = sourceChapterIndex - 1;
    const serial = ++this.previousPaginationPreloadSerial;
    setTimeout(() => {
      if (serial !== this.previousPaginationPreloadSerial || this.currentChapterIndex !== sourceChapterIndex) return;
      ReadBookEngine.get().peekContent(targetChapterIndex)
        .then(async (body: string): Promise<void> => {
          if (!body || serial !== this.previousPaginationPreloadSerial ||
            this.currentChapterIndex !== sourceChapterIndex) return;
          const processed = await this.prepareReaderContentRules(body, targetChapterIndex);
          if (serial !== this.previousPaginationPreloadSerial || this.currentChapterIndex !== sourceChapterIndex) {
            return;
          }
          const source = this.buildPagedSourceText(targetChapterIndex, processed);
          const key = this.buildReaderPaginationCacheKey(targetChapterIndex, source);
          const result = this.getCachedReaderPagination(targetChapterIndex, source) ||
            this.getOrCreateReaderPagination(targetChapterIndex, source);
          this.schedulePreviousChapterPaginationCompletion(sourceChapterIndex, targetChapterIndex, key, result,
            serial);
        })
        .catch((error: Error) => {
          console.error('预排版上一章失败:', error);
        });
    }, Math.max(0, delayMs));
  }

  schedulePreviousChapterPaginationCompletion(sourceChapterIndex: number, targetChapterIndex: number, key: string,
    result: ReaderPaginationResult, serial: number): void {
    if (result.complete) {
      this.persistReaderPagination(targetChapterIndex, key, result);
      return;
    }
    const batchDelay = ReaderActionMarker.has(result.source) ?
      READER_INTERACTIVE_PAGINATION_BATCH_DELAY_MS : READER_PAGINATION_BATCH_DELAY_MS;
    const runBatch = (): void => {
      if (serial !== this.previousPaginationPreloadSerial || this.currentChapterIndex !== sourceChapterIndex ||
        this.readerPaginationCache.get(key) !== result) return;
      if (this.isReaderPaginationInteractionBusy()) {
        setTimeout(runBatch, READER_PAGINATION_BUSY_RETRY_DELAY_MS);
        return;
      }
      const startedAt = Date.now();
      this.appendReaderPaginationBatch(result, targetChapterIndex, 1);
      if (result.complete) {
        this.persistReaderPagination(targetChapterIndex, key, result);
        console.info(`[ReaderPreload] previous chapter=${targetChapterIndex} pages=${result.pages.length} ` +
          `lastBatch=${Date.now() - startedAt}ms`);
        return;
      }
      const elapsedMs = Math.max(0, Date.now() - startedAt);
      const nextDelay = elapsedMs >= CooperativeScheduler.SLOW_OPERATION_MS ?
        Math.min(240, Math.max(batchDelay, elapsedMs * 2)) : batchDelay;
      setTimeout(runBatch, nextDelay);
    };
    setTimeout(runBatch, batchDelay);
  }

  paginateContent(sourceContent?: string, chapterIndex: number = this.currentChapterIndex) {
    const content = sourceContent !== undefined ? sourceContent : this.content;
    if (!content) {
      this.clearReaderComicPaginationProgress();
      this.contentPages = [];
      this.pagedContentText = '';
      this.contentPageStarts = [];
      this.contentPageEnds = [];
      this.setCurrentPageText('');
      return;
    }

    if (!this.hasPagedReaderArea()) {
      this.clearReaderComicPaginationProgress();
      this.contentPages = [];
      this.pagedContentText = '';
      this.contentPageStarts = [];
      this.contentPageEnds = [];
      this.setCurrentPageText(content);
      return;
    }

    const safeChapterIndex = this.clampChapterIndex(chapterIndex);
    const pagedSource = this.buildPagedSourceText(safeChapterIndex, content);
    const result = this.getOrCreateReaderPagination(safeChapterIndex, pagedSource);
    this.applyReaderPaginationResult(result, content);
  }

  applyReaderPaginationResult(result: ReaderPaginationResult, fallbackContent: string): void {
    const pages: string[] = result.pages.length > 0 ? result.pages : [fallbackContent];
    if (!result.complete && this.pendingRestorePageIndex < 0 && this.currentPageIndex >= pages.length) {
      // Incremental pagination (especially chapters containing paragraph-comment markers) may initially expose
      // only page one. Preserve the authoritative page until enough boundaries have been rebuilt instead of
      // clamping it to zero and later persisting that temporary fallback as the reading progress.
      this.pendingRestorePageIndex = this.currentPageIndex;
    }
    this.pagedContentText = result.source;
    // Render from a snapshot. Incremental pagination continues in its private cache and is published once complete,
    // so background layout cannot mutate or replace the visible page collection every few milliseconds.
    this.contentPages = [...pages];
    this.contentPageStarts = result.starts.length > 0 ? [...result.starts] : [0];
    this.contentPageEnds = result.ends.length > 0 ? [...result.ends] : [this.pagedContentText.length];
    this.restorePendingPageIndex(result.complete === true);
    if (this.currentPageIndex >= pages.length) {
      this.currentPageIndex = Math.max(0, pages.length - 1);
    }
    const pageIndex = this.normalizeReaderSpreadPageIndex(
      Math.max(0, Math.min(this.currentPageIndex, Math.max(0, pages.length - 1)))
    );
    this.currentPageIndex = pageIndex;
    this.setCurrentPageText(pages[pageIndex] || '');
    // Incremental pagination may initially contain only page one. Do not expose that temporary page while
    // the saved position is still waiting for enough page boundaries to be rebuilt.
    this.readerInitialPageReady = this.pendingRestorePageIndex < 0;
    this.syncReaderComicPageDataSource();
    this.scheduleReaderComicScrollRestore();
  }

  async turnNext() {
    if (this.isReaderContinuousScrollSurfaceActive()) {
      this.scrollReaderComicByPage(1);
      return;
    }
    await this.runPageTurnAnimation(1, this.readerEffectivePageTurnMode() === 1 ? 'slide' : 'tap');
  }

  async turnPrev() {
    if (this.isReaderContinuousScrollSurfaceActive()) {
      this.scrollReaderComicByPage(-1);
      return;
    }
    await this.runPageTurnAnimation(-1, this.readerEffectivePageTurnMode() === 1 ? 'slide' : 'tap');
  }

  scrollReaderComicByPage(direction: number): void {
    if (!this.isReaderContinuousScrollSurfaceActive() || this.contentPages.length === 0) return;
    const targetIndex = this.currentPageIndex + (direction > 0 ? 1 : -1);
    if (targetIndex >= 0 && targetIndex < this.contentPages.length) {
      this.readerComicScroller.scrollToIndex(targetIndex, true, ScrollAlign.START);
      return;
    }
    if (direction > 0) {
      this.loadNextChapter(false, true);
    } else {
      this.loadPrevChapter(true, false, true);
    }
  }

  preloadReaderContent(): void {
    if (this.chapters.length === 0 || !this.readerPreloadEnabled) {
      return;
    }
    const engine = ReadBookEngine.get();
    engine.preloadAround(this.currentChapterIndex, this.normalizePreloadChapterCount(this.readerPreloadChapterCount), 0);
    this.preloadNextChapterPaginationLater();
    this.preloadPreviousChapterPaginationLater();
  }

  normalizePreloadChapterCount(count: number): number {
    return Math.max(1, Math.min(Math.round(count), 10));
  }

  preloadReaderContentLater(): void {
    setTimeout(() => {
      this.preloadReaderContent();
    }, 0);
  }

  canTurnPage(direction: number): boolean {
    if (this.chapters.length === 0) {
      return false;
    }
    if (direction > 0) {
      const targetPageIndex = this.currentPageIndex + this.getReaderPageTurnStep();
      if (targetPageIndex >= this.contentPages.length) {
        this.ensureCurrentReaderPaginationAhead(targetPageIndex + 2);
      }
      return this.currentPageIndex + this.getReaderPageTurnStep() < this.contentPages.length ||
        this.currentChapterIndex < this.chapters.length - 1;
    }
    return this.currentPageIndex > 0 || this.currentChapterIndex > 0;
  }

  ensureCurrentReaderPaginationAhead(requiredPageCount: number): void {
    if (!this.pagedContentText) return;
    const key = this.buildReaderPaginationCacheKey(this.currentChapterIndex, this.pagedContentText);
    const result = this.readerPaginationCache.get(key);
    if (!result) return;
    if (!result.complete && result.pages.length < requiredPageCount) {
      // Normally the idle worker stays well ahead. This is only a boundary fallback for exceptionally fast input.
      this.appendReaderPaginationBatch(result, this.currentChapterIndex,
        Math.max(1, requiredPageCount - result.pages.length));
    }
    if (result.pages.length > this.contentPages.length) this.publishCurrentReaderPagination(result);
    if (result.complete) this.persistReaderPagination(this.currentChapterIndex, key, result);
  }

  async applyPageTurn(direction: number, targetPreview: PageTurnPreview | null = null,
    commitText: boolean = true): Promise<void> {
    const localPageIndex = this.getLocalPageTurnTargetPageIndex(direction);
    if (direction > 0) {
      if (localPageIndex >= 0) {
        this.applyLocalPageTurnTarget(localPageIndex, targetPreview, commitText);
        if (this.contentPages.length - this.currentPageIndex <= 3) {
          this.preloadReaderContentLater();
          this.preloadNextChapterPaginationLater(0);
        }
        this.scheduleReaderPagedProgressSave();
      } else {
        await this.loadNextChapter();
      }
      return;
    }

    if (localPageIndex >= 0) {
      this.applyLocalPageTurnTarget(localPageIndex, targetPreview, commitText);
      if (this.currentPageIndex <= 2) {
        this.preloadReaderContentLater();
      }
      this.scheduleReaderPagedProgressSave();
    } else {
      await this.loadPrevChapter(true);
    }
  }

  applyLocalPageTurnTarget(targetPageIndex: number, targetPreview: PageTurnPreview | null = null,
    commitText: boolean = true): void {
    const safePageIndex = Math.max(0, Math.min(targetPageIndex, Math.max(0, this.contentPages.length - 1)));
    this.currentPageIndex = safePageIndex;
    if (!commitText) {
      return;
    }
    if (targetPreview && targetPreview.chapterIndex === this.currentChapterIndex &&
      targetPreview.pageIndex === safePageIndex && targetPreview.text) {
      this.setCurrentPageText(targetPreview.text);
      this.refreshReaderTextRender();
      return;
    }
    if (this.pageTurnIncomingChapterIndex === this.currentChapterIndex &&
      this.pageTurnIncomingPageIndex === safePageIndex && this.pageTurnIncomingText) {
      this.setCurrentPageText(this.pageTurnIncomingText);
      this.refreshReaderTextRender();
      return;
    }
    this.syncCurrentPageText();
    this.refreshReaderTextRender();
  }

  capturePageTurnCommitTarget(direction: number): PageTurnPreview | null {
    const localPageIndex = this.getLocalPageTurnTargetPageIndex(direction);
    if (localPageIndex >= 0) {
      return {
        text: this.getPageText(localPageIndex),
        secondaryText: this.getSecondaryPageText(localPageIndex),
        pageIndex: localPageIndex,
        chapterIndex: this.currentChapterIndex,
        pageStart: this.getPageStartOffset(localPageIndex),
        secondaryPageStart: this.isLandscapeDoublePageActive() ? this.getPageStartOffset(localPageIndex + 1) : -1,
        documentSource: this.pagedContentText
      };
    }
    if (this.pageTurnIncomingText) {
      return {
        text: this.pageTurnIncomingText,
        secondaryText: this.pageTurnIncomingSecondaryText,
        pageIndex: this.pageTurnIncomingPageIndex,
        chapterIndex: this.pageTurnIncomingChapterIndex,
        pageStart: this.pageTurnIncomingPageStart,
        secondaryPageStart: this.pageTurnIncomingSecondaryPageStart,
        documentSource: this.pageTurnIncomingDocumentSource
      };
    }
    return null;
  }
  async runPageTurnAnimation(direction: number, style: string, fromQueue: boolean = false,
    releaseVelocity: number = 0): Promise<void> {
    if (!fromQueue && Date.now() < this.readerGestureTurnGuardUntil) {
      if (style === 'gesture' && this.readerGestureTurnAllowance > 0) {
        this.readerGestureTurnAllowance = 0;
      } else {
        return;
      }
    }
    if (this.isPageTurning) {
      // Touch.Up and PanGesture.onActionEnd can both report the same physical swipe.
      // commitReaderMove already de-duplicates them, so one subsequent physical swipe can safely be queued.
      // Keep a tiny bounded queue so rapid input flows into the next animation instead of being swallowed.
      // Two slots cover animation/chapter handoff jitter without letting a long input backlog run away.
      if (this.queuedPageTurnDirection === direction && this.queuedPageTurnStyle === style) {
        this.queuedPageTurnCount = Math.min(2, this.queuedPageTurnCount + 1);
        this.queuedPageTurnVelocity = Math.max(this.queuedPageTurnVelocity, releaseVelocity);
      } else {
        this.queuedPageTurnDirection = direction;
        this.queuedPageTurnStyle = style;
        this.queuedPageTurnCount = 1;
        this.queuedPageTurnVelocity = releaseVelocity;
      }
      return;
    }
    if (!this.canTurnPage(direction)) {
      this.queuedPageTurnDirection = 0;
      this.queuedPageTurnStyle = '';
      this.queuedPageTurnCount = 0;
      this.queuedPageTurnVelocity = 0;
      this.resetSlidePageEffect();
      if (direction > 0 && this.chapters.length > 0 &&
        this.currentChapterIndex >= this.chapters.length - 1 &&
        this.getLocalPageTurnTargetPageIndex(1) < 0) {
        promptAction.showToast({ message: '本书已阅读完成' });
      }
      return;
    }
    const turnRequestStartedAt = Date.now();
    const resumeTtsAfterTurn = this.ttsManualPageTurnResumePending ||
      this.isTtsSpeaking || this.ttsReader.isSpeaking();
    let ttsPrepareElapsed = 0;
    if (resumeTtsAfterTurn) {
      // Stop only synthesis/audio. Do not synchronously refresh AVSession metadata or clear the
      // highlighted subtree before the visual turn; both operations are much more expensive than
      // the animation itself. Rapid/queued turns share one deferred restart at the final page.
      this.prepareTtsForManualPageTurn();
      ttsPrepareElapsed = Math.max(0, Date.now() - turnRequestStartedAt);
    }
    const visualStartedAt = Date.now();
    this.isPageTurning = true;
    let turnCompleted = false;
    try {
      if (!this.isPageTurnAnimationEnabled()) {
        await this.runNoAnimationPageTurn(direction);
      } else if (style === 'slide' || style === 'gesture') {
        await this.runSlidePageTurn(direction, fromQueue && style === 'gesture', releaseVelocity);
      } else {
        await this.runTapPageTurn(direction);
      }
      turnCompleted = true;
    } finally {
      this.isPageTurning = false;
    }
    if (resumeTtsAfterTurn) {
      console.info(`[TTS-Turn] visual ${turnCompleted ? 'completed' : 'cancelled'} in ` +
        `${Math.max(0, Date.now() - visualStartedAt)}ms,request=${Math.max(0, Date.now() - turnRequestStartedAt)}ms,` +
        `prepare=${ttsPrepareElapsed}ms,chapter=${this.currentChapterIndex},` +
        `page=${this.currentPageIndex},queued=${this.queuedPageTurnCount}`);
    }
    this.runQueuedPageTurnLater();
    if (resumeTtsAfterTurn) this.scheduleTtsResumeAfterManualPageTurn();
  }

  runQueuedPageTurnLater(): void {
    const direction = this.queuedPageTurnDirection;
    const style = this.queuedPageTurnStyle;
    const releaseVelocity = this.queuedPageTurnVelocity;
    if (direction === 0 || this.queuedPageTurnCount <= 0) return;
    this.queuedPageTurnCount--;
    if (this.queuedPageTurnCount <= 0) {
      this.queuedPageTurnDirection = 0;
      this.queuedPageTurnStyle = '';
      this.queuedPageTurnVelocity = 0;
    }
    setTimeout(() => {
      this.runPageTurnAnimation(direction, style, true, releaseVelocity);
    }, 0);
  }

  async runNoAnimationPageTurn(direction: number): Promise<void> {
    this.readerTouchActive = false;
    this.readerPanActive = false;
    this.resetSlidePageState();
    const localPageIndex = this.getLocalPageTurnTargetPageIndex(direction);
    if (localPageIndex >= 0) {
      this.currentPageIndex = localPageIndex;
      const targetText = this.getPageText(localPageIndex);
      this.commitVisibleCurrentPageText(targetText);
      this.finishPageTurnAnimation(false);
      if (direction > 0 && this.contentPages.length - this.currentPageIndex <= 3) {
        this.preloadReaderContentLater();
        this.preloadNextChapterPaginationLater(0);
      } else if (direction < 0 && this.currentPageIndex <= 2) {
        this.preloadReaderContentLater();
      }
      this.scheduleReaderPagedProgressSave();
      this.commitCurrentPageTextLater(this.currentChapterIndex, this.currentPageIndex, targetText);
      return;
    }

    if (direction > 0) {
      await this.loadNextChapter();
    } else {
      await this.loadPrevChapter(true);
    }
    const targetText = this.getCurrentPageText();
    this.finishPageTurnAnimation(false);
    this.commitVisibleCurrentPageText(targetText, true);
    this.commitCurrentPageTextLater(this.currentChapterIndex, this.currentPageIndex, targetText);
  }

  commitVisibleCurrentPageText(text: string = this.visibleCurrentPageText(), forceRender: boolean = false): void {
    const nextText = text || '';
    if (!forceRender && this.currentPageText === nextText && this.displayPageText === nextText &&
      this.displayPageChapterIndex === this.currentChapterIndex && this.displayPageIndex === this.currentPageIndex) {
      return;
    }
    this.readerSourceActionAreas.clear();
    this.clearPendingReaderSourceActionBounds();
    this.currentPageText = nextText;
    this.displayPageText = nextText;
    this.displayPageChapterIndex = this.currentChapterIndex;
    this.displayPageIndex = this.currentPageIndex;
    this.displayPageRenderKey++;
    this.forceCurrentReaderPageRender();
  }

  commitVisibleCurrentPageTextLater(chapterIndex: number, pageIndex: number): void {
    this.commitCurrentPageTextLater(chapterIndex, pageIndex, '');
  }

  commitCurrentPageTextLater(chapterIndex: number, pageIndex: number, expectedText: string): void {
    this.commitCurrentPageTextAfterDelay(chapterIndex, pageIndex, expectedText, 0);
  }

  commitCurrentPageTextAfterDelay(chapterIndex: number, pageIndex: number, expectedText: string, delayMs: number): void {
    setTimeout(() => {
      if (this.currentChapterIndex === chapterIndex && this.currentPageIndex === pageIndex) {
        const liveText = this.getCurrentPageText();
        const pageText = liveText || expectedText;
        this.commitVisibleCurrentPageText(pageText);
      }
    }, delayMs);
  }

  async runLegacyPageTurn(direction: number): Promise<void> {
    const subtleOffset = direction > 0 ? -10 : 10;
    this.pageSlideDirection = 0;
    this.pageTransitionOpacity = 1;
    this.pageTurnIncomingOpacity = 1;
    this.setPageTurnIncomingState(this.currentPageIndex, '', false);
    this.clearPageTurnPreviewState();
    animateTo({ duration: 120, curve: Curve.EaseOut }, () => {
      this.setPageSlideAxisOffset(subtleOffset);
    });
    await this.delay(130);
    await this.applyPageTurn(direction, null, false);
    await this.finishAnimatedPageTurn();
  }

  async runTapPageTurn(direction: number): Promise<void> {
    const distance = this.getPageTurnDistance();
    this.prepareSlidePageTurn(direction, 0);
    const targetPreview = this.capturePageTurnCommitTarget(direction);
    if (this.isSimulationPageTurnAnimation()) {
      await this.completeSimulationPageTurnMotion(direction);
    } else {
      const duration = 220;
      animateTo({ duration: duration, curve: this.pageTurnAnimationCurve() }, () => {
        this.setPageSlideAxisOffset(direction > 0 ? -distance : distance);
        this.pageTransitionOpacity = 1;
      });
      await this.delay(duration + 10);
    }
    await this.applyPageTurn(direction, targetPreview, false);
    await this.finishAnimatedPageTurn();
  }

  readerSlideCompletionDuration(remaining: number, distance: number, releaseVelocity: number,
    queuedGesture: boolean): number {
    const safeDistance = Math.max(1, distance);
    const remainingRatio = Math.max(0, Math.min(1, remaining / safeDistance));
    if (queuedGesture) {
      return Math.max(70, Math.min(100, Math.round(100 * remainingRatio)));
    }
    let durationCap = 160;
    if (releaseVelocity >= 2800) {
      durationCap = 90;
    } else if (releaseVelocity >= 1400) {
      durationCap = 115;
    } else if (releaseVelocity >= 700) {
      durationCap = 140;
    }
    return Math.max(90, Math.min(durationCap, Math.round(160 * remainingRatio)));
  }

  async runSlidePageTurn(direction: number, queuedGesture: boolean = false,
    releaseVelocity: number = 0): Promise<void> {
    const distance = this.getPageTurnDistance();
    this.prepareSlidePageTurn(direction, this.getPageSlideAxisOffset());
    const targetPreview = this.capturePageTurnCommitTarget(direction);
    const targetOffset = direction > 0 ? -distance : distance;
    const remaining = Math.abs(targetOffset - this.getPageSlideAxisOffset());
    if (this.isSimulationPageTurnAnimation()) {
      await this.completeSimulationPageTurnMotion(direction);
    } else {
      const duration = this.readerSlideCompletionDuration(remaining, distance, releaseVelocity, queuedGesture);
      animateTo({ duration: duration, curve: this.pageTurnAnimationCurve() }, () => {
        this.setPageSlideAxisOffset(targetOffset);
        this.pageTransitionOpacity = 1;
      });
      await this.delay(duration + 10);
    }
    await this.applyPageTurn(direction, targetPreview, false);
    await this.finishAnimatedPageTurn();
  }

  async finishAnimatedPageTurn(): Promise<void> {
    const chapterIndex = this.currentChapterIndex;
    const pageIndex = this.currentPageIndex;
    const targetText = this.getCurrentPageText();
    // The incoming surface is already at the viewport origin. Commit and lay out the new current surface behind it,
    // then remove the incoming surface on the next frame. Removing it first caused an intermittent background flash.
    const keepIncomingVisible = this.pageSlideDirection !== 0 && !!this.pageTurnIncomingText;
    this.commitVisibleCurrentPageText(targetText);
    if (keepIncomingVisible) {
      // Cross-chapter pages may contain many bubble ImageSpans. Keep the already-complete preview on top
      // for a few frames while the new current render group is rasterized behind it.
      await this.delay(this.pageTurnCrossChapterHandoff ? 48 : 16);
      if (chapterIndex !== this.currentChapterIndex || pageIndex !== this.currentPageIndex) return;
    }
    this.finishPageTurnAnimation(false);
    this.commitCurrentPageTextLater(chapterIndex, pageIndex, targetText);
  }

  prepareIncomingPageTurn(direction: number): void {
    this.updatePageTurnIncomingForDirection(direction);
    this.pageTurnIncomingX = 0;
    this.pageTurnIncomingOpacity = 1;
  }

  prepareSlidePageTurn(direction: number, offset: number): void {
    const distance = this.getPageTurnDistance();
    const clampedOffset = Math.max(-distance, Math.min(distance, offset));
    this.pageSlideDirection = direction;
    this.setPageSlideAxisOffset(clampedOffset);
    this.pageTransitionOpacity = 1;
    this.pageTurnIncomingOpacity = 1;
    this.prepareIncomingPageTurn(direction);
    this.requestReaderPageCurlCapture();
  }

  finishPageTurnAnimation(releaseTurnLock: boolean = true): void {
    this.resetReaderPageCurl();
    this.pageTransitionX = 0;
    this.pageTransitionOpacity = 1;
    this.pageSlideOffsetX = 0;
    this.pageSlideOffsetY = 0;
    this.pageSlideDirection = 0;
    this.pageTurnIncomingX = 0;
    this.pageTurnIncomingOpacity = 1;
    this.setPageTurnIncomingState(this.currentPageIndex, '', false);
    this.clearPageTurnPreviewState();
    if (releaseTurnLock) this.isPageTurning = false;
  }

  finishPageTurnAnimationLater(): void {
    const serial = ++this.slideResetSerial;
    setTimeout(() => {
      if (serial === this.slideResetSerial) {
        this.finishPageTurnAnimation();
        this.refreshReaderTextRender();
      }
    }, 0);
  }

  setPageTurnIncomingState(pageIndex: number, text: string, animating: boolean = true,
    chapterIndex: number = this.currentChapterIndex, secondaryText: string = '', pageStart: number = -1,
    secondaryPageStart: number = -1, documentSource: string = ''): void {
    const safeText = text || '';
    const safeSecondaryText = secondaryText || '';
    const safeDocumentSource = documentSource || '';
    const nextAnimating = animating && !!safeText;
    if (this.pageTurnIncomingPageIndex !== pageIndex || this.pageTurnIncomingChapterIndex !== chapterIndex ||
      this.pageTurnIncomingText !== safeText || this.pageTurnIncomingSecondaryText !== safeSecondaryText ||
      this.pageTurnIncomingPageStart !== pageStart ||
      this.pageTurnIncomingSecondaryPageStart !== secondaryPageStart ||
      this.pageTurnIncomingDocumentSource !== safeDocumentSource || this.pageTurnAnimating !== nextAnimating) {
      this.pageTurnIncomingRenderVersion++;
    }
    this.pageTurnIncomingPageIndex = pageIndex;
    this.pageTurnIncomingChapterIndex = chapterIndex;
    this.pageTurnIncomingText = safeText;
    this.pageTurnIncomingSecondaryText = safeSecondaryText;
    this.pageTurnIncomingPageStart = pageStart;
    this.pageTurnIncomingSecondaryPageStart = secondaryPageStart;
    this.pageTurnIncomingDocumentSource = safeDocumentSource;
    this.pageTurnAnimating = nextAnimating;
  }

  getPageTurnTargetText(direction: number): string {
    const localPageIndex = this.getLocalPageTurnTargetPageIndex(direction);
    if (localPageIndex >= 0) {
      return this.getPageText(localPageIndex);
    }

    const targetChapterIndex = this.getAdjacentPageTurnChapterIndex(direction);
    if (targetChapterIndex >= 0) {
      const preview = this.buildCachedAdjacentPageTurnPreview(direction, targetChapterIndex);
      return preview.text || this.getPageTurnLoadingText(targetChapterIndex);
    }
    return '';
  }

  getPageTurnTargetPageIndex(direction: number = 0): number {
    const localPageIndex = this.getLocalPageTurnTargetPageIndex(direction);
    if (localPageIndex >= 0) {
      return localPageIndex;
    }
    return direction === 0 ? this.currentPageIndex : this.pageTurnIncomingPageIndex;
  }

  getLocalPageTurnTargetPageIndex(direction: number): number {
    const step = this.getReaderPageTurnStep();
    if (direction > 0 && this.currentPageIndex + step >= this.contentPages.length) {
      this.ensureCurrentReaderPaginationAhead(this.currentPageIndex + step + 2);
    }
    if (direction > 0 && this.currentPageIndex + step < this.contentPages.length) {
      return this.currentPageIndex + step;
    }
    if (direction < 0 && this.currentPageIndex > 0) {
      return Math.max(0, this.currentPageIndex - step);
    }
    return -1;
  }

  getAdjacentPageTurnChapterIndex(direction: number): number {
    if (direction > 0 && this.currentPageIndex + this.getReaderPageTurnStep() >= this.contentPages.length &&
      this.currentChapterIndex < this.chapters.length - 1) {
      return this.currentChapterIndex + 1;
    }
    if (direction < 0 && this.currentPageIndex <= 0 && this.currentChapterIndex > 0) {
      return this.currentChapterIndex - 1;
    }
    return -1;
  }

  updatePageTurnIncomingForDirection(direction: number): void {
    const localPageIndex = this.getLocalPageTurnTargetPageIndex(direction);
    if (localPageIndex >= 0) {
      this.pageTurnCrossChapterHandoff = false;
      this.pageTurnPreviewKey = `local_${localPageIndex}`;
      this.setPageTurnIncomingState(localPageIndex, this.getPageText(localPageIndex), true,
        this.currentChapterIndex, this.getSecondaryPageText(localPageIndex),
        this.getPageStartOffset(localPageIndex),
        this.isLandscapeDoublePageActive() ? this.getPageStartOffset(localPageIndex + 1) : -1,
        this.pagedContentText);
      return;
    }

    const targetChapterIndex = this.getAdjacentPageTurnChapterIndex(direction);
    if (targetChapterIndex < 0) {
      this.pageTurnCrossChapterHandoff = false;
      this.setPageTurnIncomingState(this.currentPageIndex, '', false);
      return;
    }
    this.pageTurnCrossChapterHandoff = true;

    const key = this.buildPageTurnPreviewKey(direction, targetChapterIndex);
    if (this.pageTurnPreviewKey === key && this.pageTurnIncomingText &&
      this.pageTurnIncomingChapterIndex === targetChapterIndex) {
      return;
    }
    if (this.pageTurnPreviewKey !== key) {
      this.pageTurnPreviewKey = key;
    }

    const preview = this.buildCachedAdjacentPageTurnPreview(direction, targetChapterIndex);
    if (preview.text) {
      this.applyPageTurnPreview(preview);
      return;
    }

    this.setPageTurnIncomingState(0, this.getPageTurnLoadingText(targetChapterIndex), true, targetChapterIndex);
    this.loadAdjacentPageTurnPreview(direction, targetChapterIndex, key);
  }

  buildPageTurnPreviewKey(direction: number, chapterIndex: number): string {
    return `${direction}_${chapterIndex}_${this.pageViewWidth}_${this.pageViewHeight}_` +
      `${this.readerExtendToStatusBar}_${this.getReaderPageContentTopPadding()}_` +
      `${this.isLandscapeDoublePageActive()}_${this.readerTypographyCacheIdentity()}`;
  }

  buildCachedAdjacentPageTurnPreview(direction: number, chapterIndex: number): PageTurnPreview {
    const body = ReadBookEngine.get().getCachedContent(chapterIndex);
    if (!body) {
      return { text: '', pageIndex: 0, chapterIndex: chapterIndex };
    }
    const prepared = this.getPreparedReaderContent(body, chapterIndex);
    if (!prepared && ReaderContentPreprocessor.hasActiveContentRules(this.readerReplaceRules)) {
      return { text: '', pageIndex: 0, chapterIndex: chapterIndex };
    }
    return this.buildAdjacentPageTurnPreview(direction, chapterIndex, prepared || body);
  }

  buildAdjacentPageTurnPreview(direction: number, chapterIndex: number, preparedBody: string): PageTurnPreview {
    const source = this.buildPagedSourceText(chapterIndex, preparedBody);
    const result = this.getOrCreateReaderPagination(chapterIndex, source);
    if (result.pages.length === 0) {
      return { text: '', pageIndex: 0, chapterIndex: chapterIndex };
    }
    const pageIndex = direction > 0 ? 0 : this.normalizeReaderSpreadPageIndex(result.pages.length - 1);
    return {
      text: result.pages[pageIndex],
      secondaryText: this.isLandscapeDoublePageActive() ? (result.pages[pageIndex + 1] || '') : '',
      pageIndex: pageIndex,
      chapterIndex: chapterIndex,
      pageStart: result.starts[pageIndex] ?? 0,
      secondaryPageStart: this.isLandscapeDoublePageActive() ? (result.starts[pageIndex + 1] ?? -1) : -1,
      documentSource: result.source
    };
  }

  getPageTurnLoadingText(chapterIndex: number): string {
    const title = this.getChapterTitle(chapterIndex).trim();
    return title ? `${title}\n\n正在加载章节内容...` : '正在加载章节内容...';
  }

  applyPageTurnPreview(preview: PageTurnPreview): void {
    this.setPageTurnIncomingState(preview.pageIndex, preview.text, true, preview.chapterIndex,
      preview.secondaryText || '', preview.pageStart ?? -1, preview.secondaryPageStart ?? -1,
      preview.documentSource || '');
    this.pageTurnIncomingOpacity = 1;
    this.requestReaderPageCurlCapture();
  }

  loadAdjacentPageTurnPreview(direction: number, chapterIndex: number, key: string): void {
    if (this.pageTurnPreviewLoadingKey === key) {
      return;
    }
    this.pageTurnPreviewLoadingKey = key;
    ReadBookEngine.get().peekContent(chapterIndex)
      .then(async (body: string): Promise<void> => {
        if (this.pageTurnPreviewKey !== key || this.pageSlideDirection !== direction) {
          return;
        }
        const prepared = await this.prepareReaderContentRules(body, chapterIndex);
        if (this.pageTurnPreviewKey !== key || this.pageSlideDirection !== direction) return;
        const preview = this.buildAdjacentPageTurnPreview(direction, chapterIndex, prepared);
        if (preview.text) {
          this.applyPageTurnPreview(preview);
        }
      })
      .catch((err: Error) => {
        console.error('加载翻页预览失败:', err);
      })
      .finally(() => {
        if (this.pageTurnPreviewLoadingKey === key) {
          this.pageTurnPreviewLoadingKey = '';
        }
      });
  }

  updateSlidePageEffect(offset: number): void {
    if (this.isPageTurning) {
      return;
    }
    if (!this.isPageTurnAnimationEnabled()) {
      this.resetSlidePageState();
      return;
    }
    const distance = this.getPageTurnDistance();
    const clamped = Math.max(-distance, Math.min(distance, offset));
    if (Math.abs(clamped) < 1) {
      this.resetSlidePageState();
      return;
    }
    const direction = clamped < 0 ? 1 : -1;
    if (!this.canTurnPage(direction)) {
      this.resetSlidePageState();
      return;
    }
    this.pageSlideDirection = direction;
    this.setPageSlideAxisOffset(clamped);
    this.pageTransitionOpacity = 1;
    this.pageTurnIncomingOpacity = 1;
    this.updatePageTurnIncomingForDirection(direction);
    this.requestReaderPageCurlCapture();
  }

  updateLegacySlidePageEffect(offset: number): void {
    const distance = this.getPageTurnDistance();
    const clamped = Math.max(-distance, Math.min(distance, offset));
    if (Math.abs(clamped) < 1) {
      this.resetSlidePageState();
      return;
    }
    const direction = clamped < 0 ? 1 : -1;
    if (!this.canTurnPage(direction)) {
      this.resetSlidePageState();
      return;
    }
    const subtleOffset = Math.min(10, Math.max(2, Math.abs(clamped) * 0.08));
    this.pageSlideDirection = 0;
    this.setPageSlideAxisOffset(direction > 0 ? -subtleOffset : subtleOffset);
    this.pageTransitionOpacity = 1;
    this.pageTurnIncomingOpacity = 1;
    this.setPageTurnIncomingState(this.currentPageIndex, '', false);
    this.clearPageTurnPreviewState();
  }

  rollbackSlidePageEffect(): void {
    const offset = Math.abs(this.getPageSlideAxisOffset());
    if (offset < 0.5) {
      this.resetSlidePageState();
      return;
    }
    const distance = this.getPageTurnDistance();
    const duration = Math.max(80, Math.min(180, Math.round(180 * offset / distance)));
    const serial = ++this.slideResetSerial;
    if (this.isSimulationPageTurnAnimation()) {
      this.rollbackReaderPageCurl(duration, serial).catch((error: Error) => {
        console.warn('回弹仿真翻页失败:', error);
        if (this.slideResetSerial === serial && !this.isPageTurning) this.resetSlidePageState();
      });
      return;
    }
    animateTo({ duration: duration, curve: Curve.EaseOut }, () => {
      this.setPageSlideAxisOffset(0);
      this.pageTransitionOpacity = 1;
      this.pageTurnIncomingOpacity = 1;
    });
    setTimeout(() => {
      if (this.slideResetSerial === serial && !this.isPageTurning) {
        this.resetSlidePageState();
      }
    }, duration + 20);
  }

  async rollbackReaderPageCurl(duration: number, serial: number): Promise<void> {
    const ready = await this.ensureReaderPageCurlReady();
    if (!ready) {
      if (this.slideResetSerial === serial && !this.isPageTurning) this.resetSlidePageState();
      return;
    }
    await this.animateReaderPageCurlOffset(0, duration);
    if (this.slideResetSerial === serial && !this.isPageTurning) this.resetSlidePageState();
  }

  resetSlidePageEffect(): void {
    this.resetSlidePageState();
  }

  getVisiblePageTurnIncomingText(): string {
    if (!this.shouldRenderSlidingPageTurn()) {
      return '';
    }
    if (this.pageTurnIncomingText) {
      return this.pageTurnIncomingText;
    }
    if (this.pageSlideDirection === 0) {
      return '';
    }
    return this.getPageTurnTargetText(this.pageSlideDirection);
  }

  getVisiblePageTurnIncomingOpacity(): number {
    if (!this.shouldRenderSlidingPageTurn()) {
      return 0;
    }
    const type = this.normalizePageTurnAnimationType(this.readerPageTurnAnimationType);
    if (type === ReaderSettingsStore.PAGE_TURN_ANIMATION_FADE) {
      return Math.max(0, Math.min(1, this.pageTurnIncomingOpacity * this.getPageTurnProgress()));
    }
    if (type === ReaderSettingsStore.PAGE_TURN_ANIMATION_STACK) {
      return this.pageTurnIncomingOpacity;
    }
    return this.pageTurnIncomingOpacity;
  }

  getPageTurnWidth(): number {
    return Math.max(1, this.pageViewWidth > 0 ? this.pageViewWidth : 360);
  }

  getPageTurnHeight(): number {
    const contentHeight = this.pageViewHeight > 0 ? this.pageViewHeight : 640;
    // The declarative page-turn surface expands through the bottom system safe area. pageViewHeight is measured
    // before that expansion, so omitting the navigation inset scales a full-height snapshot into a shorter canvas
    // and makes the entire page visibly squeeze upward while it is turning.
    return Math.max(1, contentHeight + this.getReaderPageContentTopPadding() + Math.max(0, this.navBarHeight));
  }

  isVerticalPageTurnAnimation(): boolean {
    return this.readerEffectivePageTurnMode() === 0 && !this.isSimulationPageTurnAnimation();
  }

  isStackPageTurnAnimation(): boolean {
    return this.normalizePageTurnAnimationType(this.readerPageTurnAnimationType) ===
      ReaderSettingsStore.PAGE_TURN_ANIMATION_STACK;
  }

  isSimulationPageTurnAnimation(): boolean {
    return this.normalizePageTurnAnimationType(this.readerPageTurnAnimationType) ===
      ReaderSettingsStore.PAGE_TURN_ANIMATION_SIMULATION;
  }

  pageTurnAnimationCurve(): Curve {
    return this.isSimulationPageTurnAnimation() ? Curve.EaseInOut : Curve.EaseOut;
  }

  getReaderPageCurlCanvasHeight(): number {
    // Prefer the actual captured component height. It stays correct for gesture-navigation variants, split-screen
    // windows and devices whose bottom avoid area differs from the globally cached navigation height.
    return this.readerPageCurlSnapshotHeight > 0 ? this.readerPageCurlSnapshotHeight : this.getPageTurnHeight();
  }

  readerPageCurlKey(): string {
    return `${this.pageSlideDirection}_${this.currentChapterIndex}_${this.currentPageIndex}_` +
      `${this.pageRenderVersion}_${this.ttsHighlightRenderVersion}_${this.pageTurnIncomingChapterIndex}_` +
      `${this.pageTurnIncomingPageIndex}_${this.pageTurnIncomingRenderVersion}_` +
      `${this.isLandscapeDoublePageActive() ? 1 : 0}_${this.getPageTurnWidth()}_${this.getPageTurnHeight()}_` +
      `${this.getReaderPageContentTopPadding()}_${this.navBarHeight}_${this.readerExtendToStatusBar ? 1 : 0}`;
  }

  drawReaderPageCurl(): void {
    if (!this.readerPageCurlCanvasReady || !this.readerPageCurlSnapshotReady ||
      !this.readerPageCurlFront || !this.readerPageCurlBack || this.pageSlideDirection === 0) {
      return;
    }
    this.readerPageCurlPainter.draw(this.readerPageCurlContext, this.readerPageCurlFront,
      this.readerPageCurlBack, this.getPageTurnWidth(), this.getReaderPageCurlCanvasHeight(),
      this.getPageTurnProgress(), this.pageSlideDirection, this.isLandscapeDoublePageActive(),
      this.isReaderThemeDark(), this.getReaderPageContentTopPadding());
  }

  requestReaderPageCurlCapture(): void {
    if (!this.isSimulationPageTurnAnimation() || this.pageSlideDirection === 0 ||
      !this.shouldRenderSlidingPageTurn()) {
      return;
    }
    const key = this.readerPageCurlKey();
    if (key === this.readerPageCurlCaptureKey &&
      (this.readerPageCurlSnapshotReady || this.readerPageCurlCapturePending)) {
      // The gesture/animator already paints after publishing the latest offset. Repainting here
      // made every double-page drag update submit the same expensive textured mesh twice.
      return;
    }
    this.readerPageCurlCaptureKey = key;
    this.readerPageCurlCapturePending = true;
    this.readerPageCurlSnapshotReady = false;
    const serial = ++this.readerPageCurlCaptureSerial;
    setTimeout(() => {
      this.captureReaderPageCurlSnapshots(serial, key).catch((error: Error) => {
        if (serial === this.readerPageCurlCaptureSerial) {
          this.readerPageCurlCapturePending = false;
        }
        console.warn('生成仿真翻页快照失败:', error);
      });
    }, 0);
  }

  async captureReaderPageCurlSnapshots(serial: number, key: string): Promise<void> {
    for (let attempt = 0; attempt < 30 && this.pageTurnPreviewLoadingKey; attempt++) {
      if (serial !== this.readerPageCurlCaptureSerial || key !== this.readerPageCurlCaptureKey) return;
      await this.delay(20);
    }
    // Let the incoming cross-chapter preview and its ImageSpans finish one layout pass before rasterizing.
    await this.delay(this.pageTurnCrossChapterHandoff ? 32 : 0);
    if (serial !== this.readerPageCurlCaptureSerial || key !== this.readerPageCurlCaptureKey ||
      this.pageSlideDirection === 0) return;
    const snapshot = this.getUIContext().getComponentSnapshot();
    const suffix = this.isLandscapeDoublePageActive() ? 'double' : 'single';
    let front: image.PixelMap | null = null;
    let back: image.PixelMap | null = null;
    // A tap can request the snapshot in the same task that publishes the simulation subtree.
    // The component IDs become available on a following render frame, so retry transient 100001
    // failures instead of letting tap turns miss the curl while drag turns happen to work.
    for (let attempt = 0; attempt < 24; attempt++) {
      try {
        front = await snapshot.get(`reader_page_curl_front_${suffix}`);
        back = await snapshot.get(`reader_page_curl_back_${suffix}`);
        break;
      } catch (error) {
        if (front) front.release().catch(() => {});
        if (back) back.release().catch(() => {});
        front = null;
        back = null;
        if (serial !== this.readerPageCurlCaptureSerial || key !== this.readerPageCurlCaptureKey ||
          this.pageSlideDirection === 0) return;
        if (attempt >= 23) throw new Error(`获取仿真翻页快照失败: ${error}`);
        await this.delay(16);
      }
    }
    if (!front || !back) return;
    let snapshotHeight = this.getPageTurnHeight();
    try {
      const frontInfo = await front.getImageInfo();
      snapshotHeight = px2vp(Math.max(1, frontInfo.size.height));
    } catch (error) {
      console.warn('读取仿真翻页快照尺寸失败，使用页面布局高度:', error);
    }
    if (serial !== this.readerPageCurlCaptureSerial || key !== this.readerPageCurlCaptureKey ||
      this.pageSlideDirection === 0) {
      front.release().catch(() => {});
      back.release().catch(() => {});
      return;
    }
    const oldFront = this.readerPageCurlFront;
    const oldBack = this.readerPageCurlBack;
    this.readerPageCurlFront = front;
    this.readerPageCurlBack = back;
    this.readerPageCurlSnapshotHeight = snapshotHeight;
    this.readerPageCurlCapturePending = false;
    this.readerPageCurlSnapshotReady = true;
    this.drawReaderPageCurl();
    if (oldFront) oldFront.release().catch(() => {});
    if (oldBack) oldBack.release().catch(() => {});
  }

  async ensureReaderPageCurlReady(): Promise<boolean> {
    if (!this.isSimulationPageTurnAnimation() || this.pageSlideDirection === 0) return false;
    this.requestReaderPageCurlCapture();
    const key = this.readerPageCurlCaptureKey;
    for (let attempt = 0; attempt < 120; attempt++) {
      if (this.readerPageCurlSnapshotReady && key === this.readerPageCurlCaptureKey) return true;
      if (this.pageSlideDirection === 0 || key !== this.readerPageCurlCaptureKey) return false;
      await this.delay(16);
    }
    return false;
  }

  async completeSimulationPageTurnMotion(direction: number): Promise<void> {
    const ready = await this.ensureReaderPageCurlReady();
    if (!ready) {
      // Keep navigation usable if the platform snapshot service is temporarily unavailable.
      // The normal cleanup path will clear the unpublished simulation surface after the commit.
      console.warn('仿真翻页快照未就绪，直接完成本次翻页');
      return;
    }
    const distance = this.getPageTurnDistance();
    const targetOffset = direction > 0 ? -distance : distance;
    const remaining = Math.abs(targetOffset - this.getPageSlideAxisOffset());
    // A long symmetric EaseInOut made the last part of the sheet appear to stop before the
    // incoming page was committed. Finish with a shorter, momentum-preserving edge motion.
    const duration = Math.max(110, Math.min(340, Math.round(340 * remaining / distance)));
    await this.animateReaderPageCurlOffset(targetOffset, duration, true);
  }

  resetReaderPageCurl(): void {
    this.readerPageCurlCaptureSerial++;
    this.readerPageCurlCapturePending = false;
    this.readerPageCurlCaptureKey = '';
    this.readerPageCurlSnapshotReady = false;
    this.readerPageCurlAnimationSerial++;
    const activeAnimator = this.readerPageCurlAnimator;
    this.readerPageCurlAnimator = null;
    if (activeAnimator) activeAnimator.cancel();
    this.readerPageCurlOffset = 0;
    this.readerPageCurlSnapshotHeight = 0;
    const front = this.readerPageCurlFront;
    const back = this.readerPageCurlBack;
    this.readerPageCurlFront = null;
    this.readerPageCurlBack = null;
    setTimeout(() => {
      if (front) front.release().catch(() => {});
      if (back) back.release().catch(() => {});
    }, 0);
  }

  animateReaderPageCurlOffset(targetOffset: number, duration: number,
    completingPageTurn: boolean = false): Promise<void> {
    const activeAnimator = this.readerPageCurlAnimator;
    this.readerPageCurlAnimator = null;
    if (activeAnimator) activeAnimator.cancel();
    const serial = ++this.readerPageCurlAnimationSerial;
    const startOffset = this.getPageSlideAxisOffset();
    return new Promise<void>((resolve) => {
      let settled = false;
      const settle = (): void => {
        if (settled) return;
        settled = true;
        resolve();
      };
      const pageCurlAnimator = Animator.create({
        duration: Math.max(1, duration),
        easing: completingPageTurn ? 'cubic-bezier(0.18, 0.68, 0.32, 0.98)' :
          'cubic-bezier(0.65, 0, 0.35, 1)',
        delay: 0,
        fill: 'forwards',
        direction: 'normal',
        iterations: 1,
        begin: startOffset,
        end: targetOffset
      });
      this.readerPageCurlAnimator = pageCurlAnimator;
      pageCurlAnimator.onFrame = (value: number): void => {
        if (serial !== this.readerPageCurlAnimationSerial) return;
        this.setPageSlideAxisOffset(value);
      };
      pageCurlAnimator.onFinish = (): void => {
        if (serial === this.readerPageCurlAnimationSerial) {
          this.setPageSlideAxisOffset(targetOffset);
          this.readerPageCurlAnimator = null;
        }
        settle();
      };
      pageCurlAnimator.onCancel = (): void => {
        if (this.readerPageCurlAnimator === pageCurlAnimator) this.readerPageCurlAnimator = null;
        settle();
      };
      pageCurlAnimator.play();
    });
  }

  getSimulationSpineColor(): string {
    return this.isReaderThemeDark() ? '#66000000' : '#36000000';
  }

  getPageTurnDistance(): number {
    return this.isVerticalPageTurnAnimation() ? this.getPageTurnHeight() : this.getPageTurnWidth();
  }

  getPageSlideAxisOffset(): number {
    if (this.isSimulationPageTurnAnimation()) return this.readerPageCurlOffset;
    return this.isVerticalPageTurnAnimation() ? this.pageSlideOffsetY : this.pageSlideOffsetX;
  }

  setPageSlideAxisOffset(offset: number): void {
    if (this.isSimulationPageTurnAnimation()) {
      this.readerPageCurlOffset = offset;
      this.drawReaderPageCurl();
      return;
    }
    if (this.isVerticalPageTurnAnimation()) {
      this.pageSlideOffsetX = 0;
      this.pageSlideOffsetY = offset;
      this.drawReaderPageCurl();
      return;
    }
    this.pageSlideOffsetX = offset;
    this.pageSlideOffsetY = 0;
    this.drawReaderPageCurl();
  }

  shouldRenderSlidingPageTurn(): boolean {
    return this.isPageTurnAnimationEnabled() && this.pageSlideDirection !== 0 &&
      (this.pageTurnAnimating || this.canTurnPage(this.pageSlideDirection));
  }

  getPageTurnProgress(): number {
    const distance = this.getPageTurnDistance();
    if (distance <= 0) {
      return 0;
    }
    return Math.max(0, Math.min(1, Math.abs(this.getPageSlideAxisOffset()) / distance));
  }

  getCurrentPageTurnX(): number {
    if (!this.shouldRenderSlidingPageTurn()) {
      return this.pageTransitionX + this.pageSlideOffsetX;
    }
    if (this.isVerticalPageTurnAnimation()) {
      return 0;
    }
    const type = this.normalizePageTurnAnimationType(this.readerPageTurnAnimationType);
    if (type === ReaderSettingsStore.PAGE_TURN_ANIMATION_FADE) {
      return 0;
    }
    if (type === ReaderSettingsStore.PAGE_TURN_ANIMATION_STACK) {
      return 0;
    }
    return this.pageTransitionX + this.pageSlideOffsetX;
  }

  getCurrentPageTurnY(): number {
    if (!this.shouldRenderSlidingPageTurn()) {
      return this.pageSlideOffsetY;
    }
    if (!this.isVerticalPageTurnAnimation()) {
      return 0;
    }
    const type = this.normalizePageTurnAnimationType(this.readerPageTurnAnimationType);
    if (type === ReaderSettingsStore.PAGE_TURN_ANIMATION_FADE) {
      return 0;
    }
    if (type === ReaderSettingsStore.PAGE_TURN_ANIMATION_STACK) {
      return 0;
    }
    return this.pageSlideOffsetY;
  }

  getCurrentPageTurnOpacity(): number {
    if (!this.shouldRenderSlidingPageTurn()) {
      return this.pageTransitionOpacity;
    }
    const type = this.normalizePageTurnAnimationType(this.readerPageTurnAnimationType);
    if (type === ReaderSettingsStore.PAGE_TURN_ANIMATION_FADE) {
      return Math.max(0.12, 1 - this.getPageTurnProgress());
    }
    if (type === ReaderSettingsStore.PAGE_TURN_ANIMATION_STACK) {
      return 1;
    }
    return this.pageTransitionOpacity;
  }

  getSlideIncomingX(direction: number, offsetX: number, width: number = this.getPageTurnWidth()): number {
    const type = this.normalizePageTurnAnimationType(this.readerPageTurnAnimationType);
    if (type === ReaderSettingsStore.PAGE_TURN_ANIMATION_SIMULATION) {
      return 0;
    }
    if (type === ReaderSettingsStore.PAGE_TURN_ANIMATION_FADE) {
      return 0;
    }
    if (type === ReaderSettingsStore.PAGE_TURN_ANIMATION_STACK) {
      return direction > 0 ? width + offsetX : offsetX - width;
    }
    return direction > 0 ? width + offsetX : offsetX - width;
  }

  getIncomingSlideX(): number {
    if (this.pageSlideDirection === 0 || this.isVerticalPageTurnAnimation()) {
      return 0;
    }
    return this.getSlideIncomingX(this.pageSlideDirection, this.pageSlideOffsetX);
  }

  getSlideIncomingY(direction: number, offsetY: number, height: number = this.getPageTurnHeight()): number {
    const type = this.normalizePageTurnAnimationType(this.readerPageTurnAnimationType);
    if (type === ReaderSettingsStore.PAGE_TURN_ANIMATION_SIMULATION) {
      return 0;
    }
    if (type === ReaderSettingsStore.PAGE_TURN_ANIMATION_FADE) {
      return 0;
    }
    if (type === ReaderSettingsStore.PAGE_TURN_ANIMATION_STACK) {
      return direction > 0 ? height + offsetY : offsetY - height;
    }
    return direction > 0 ? height + offsetY : offsetY - height;
  }

  getIncomingSlideY(): number {
    if (this.pageSlideDirection === 0 || !this.isVerticalPageTurnAnimation()) {
      return 0;
    }
    return this.getSlideIncomingY(this.pageSlideDirection, this.pageSlideOffsetY);
  }

  resetSlidePageState(): void {
    this.resetReaderPageCurl();
    this.pageSlideOffsetX = 0;
    this.pageSlideOffsetY = 0;
    this.pageSlideDirection = 0;
    this.pageTransitionOpacity = 1;
    this.pageTurnIncomingX = 0;
    this.pageTurnIncomingOpacity = 1;
    this.setPageTurnIncomingState(this.currentPageIndex, '', false);
    this.clearPageTurnPreviewState();
  }

  clearPageTurnPreviewState(): void {
    this.pageTurnPreviewKey = '';
    this.pageTurnPreviewLoadingKey = '';
    this.pageTurnCrossChapterHandoff = false;
  }

  buildBookPreview(): string {
    if (!this.book) return '';

    let text = `${this.book.name}\n\n作者：${this.book.author || '未知'}\n来源：${this.book.originName || this.book.origin}`;
    if (this.book.latestChapterTitle) {
      text += `\n最新章节：${this.book.latestChapterTitle}`;
    }
    if (this.book.intro) {
      text += `\n\n简介：${this.book.intro}`;
    }
    if (this.book.origin !== 'local') {
      this.updatePendingVerification();
      if (this.verificationUrl) {
        text += '\n\n当前书源需要先完成网页验证。请点击右上角“更多操作”，选择“登录”，完成后返回，再从该菜单选择“重试”。';
      } else {
        text += '\n\n当前书源暂未解析出目录。请点击右上角“更多操作”，选择“重试”重新获取，或在书源管理中为该书源补充目录规则。';
        const stageError = AppStorage.get<string>('bookSourceStageLastError') || '';
        if (stageError) text += `\n诊断：${stageError}`;
      }
    }
    return text;
  }

  async jumpToAdjacentChapterFirstPage(direction: number): Promise<void> {
    // Reopening the currently narrated book creates a new reader page while the hidden
    // original page still owns TTS. Route the chapter bar command to that owner; changing
    // only this mirrored page is immediately overwritten by the owner's position update.
    if (this.isMirroringActiveTtsForCurrentBook()) {
      if (direction < 0 && !this.globalTtsCanPrevious) {
        promptAction.showToast({ message: '已经是第一章' });
        return;
      }
      if (direction > 0 && !this.globalTtsCanNext) {
        promptAction.showToast({ message: '本书已阅读完成' });
        return;
      }
      if (direction > 0) {
        ReaderTtsFloatingSession.next();
      } else {
        ReaderTtsFloatingSession.previous();
      }
      return;
    }
    const targetChapterIndex = this.currentChapterIndex + (direction > 0 ? 1 : -1);
    if (targetChapterIndex < 0) {
      promptAction.showToast({ message: '已经是第一章' });
      return;
    }
    if (targetChapterIndex >= this.chapters.length) {
      promptAction.showToast({ message: '本书已阅读完成' });
      return;
    }

    const shouldResumeTts = this.isTtsSpeaking || this.ttsReader.isSpeaking();
    if (shouldResumeTts) {
      this.stopTtsReaderForChapterSwitch();
      await this.updateTtsAvSessionPlaybackState(avSession.PlaybackState.PLAYBACK_STATE_BUFFERING);
    }
    this.finishPageTurnAnimation();
    this.isLoading = true;
    this.loadStatus = '正在切换章节...';
    await this.delay(0);
    try {
      this.currentPageIndex = 0;
      this.pendingRestorePageIndex = 0;
      await this.loadContent(true, targetChapterIndex, true);
      if (this.currentChapterIndex !== targetChapterIndex) {
        return;
      }

      this.currentPageIndex = 0;
      this.pendingRestorePageIndex = -1;
      const targetPageText = this.contentPages[0] || this.content || '';
      this.setCurrentPageText(targetPageText);
      this.finishPageTurnAnimation();
      this.refreshReaderTextRender();
      await this.delay(16);
    } finally {
      this.isLoading = false;
      this.loadStatus = '';
    }
    this.saveReadingProgress();
    if (shouldResumeTts) {
      await this.startTtsReadingFromCurrentPosition(false);
    }
  }

  async loadNextChapter(showLoading: boolean = false, showBoundaryToast: boolean = false): Promise<void> {
    if (this.currentChapterIndex >= this.chapters.length - 1) {
      if (showBoundaryToast) {
        promptAction.showToast({ message: '本书已阅读完成' });
      }
      return;
    }
    const targetChapterIndex = this.currentChapterIndex + 1;
    this.currentPageIndex = 0;
    this.pendingRestorePageIndex = 0;
    await this.loadContent(!showLoading, targetChapterIndex, true);
    this.saveReadingProgress();
  }

  async loadPrevChapter(toLastPage: boolean = false, showLoading: boolean = false,
    showBoundaryToast: boolean = false): Promise<void> {
    if (this.currentChapterIndex <= 0) {
      if (showBoundaryToast) {
        promptAction.showToast({ message: '已经是第一章' });
      }
      return;
    }
    const targetChapterIndex = this.currentChapterIndex - 1;
    this.currentPageIndex = 0;
    this.pendingRestorePageIndex = toLastPage ? Number.MAX_SAFE_INTEGER : 0;
    await this.loadContent(!showLoading, targetChapterIndex);
    this.saveReadingProgress();
  }
}
