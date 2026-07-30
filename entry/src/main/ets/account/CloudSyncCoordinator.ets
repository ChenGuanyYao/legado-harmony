import { Context } from '@kit.AbilityKit';
import { bundleManager } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { connection } from '@kit.NetworkKit';
import deviceInfo from '@ohos.deviceInfo';
import display from '@ohos.display';
import { AccountCommerceApi } from './AccountCommerceApi';
import { AccountSessionStore } from './AccountSessionStore';
import {
  CloudSyncAcknowledgement,
  CloudSyncChange,
  CloudSyncExchangeRequest,
  CloudSyncExchangeResponse,
  CloudSyncOperation
} from './CloudSyncModels';
import { CloudSyncSettings, CloudSyncSettingsStore } from './CloudSyncSettingsStore';
import { CloudSyncChangeSnapshot, CloudSyncChangeTracker } from './CloudSyncChangeTracker';
import {
  CloudSyncEntityState,
  CloudSyncLocalState,
  CloudSyncStateStore
} from './CloudSyncStateStore';
import { AppDatabase } from '../model/data/AppDatabase';
import {
  Book,
  BookGroup,
  BookInfoRule,
  BookListRule,
  BookSource,
  Bookmark,
  ContentRule,
  ExploreRule,
  ReadConfig,
  SearchRule,
  TocRule
} from '../model/data/Book';
import { ReaderSettings, ReaderSettingsStore } from '../utils/ReaderSettingsStore';
import {
  ReaderReplaceRule,
  ReaderReplaceRuleStore
} from '../utils/ReaderReplaceRuleStore';
import { AppThemeSettings, AppThemeSettingsStore } from '../utils/AppThemeSettingsStore';
import { AppThemeModeStore } from '../utils/AppThemeModeStore';
import {
  BookshelfDisplaySettings,
  BookshelfDisplaySettingsStore
} from '../utils/BookshelfDisplaySettingsStore';
import {
  SearchExploreSettingsStore
} from '../utils/SearchExploreSettingsStore';
import {
  CustomThemeScheme,
  CustomThemeSchemeStore
} from '../utils/CustomThemeSchemeStore';

class BookshelfSyncPayload {
  bookUrl: string = '';
  tocUrl: string = '';
  origin: string = '';
  originName: string = '';
  name: string = '';
  author: string = '';
  kind: string = '';
  customTag: string = '';
  coverUrl: string = '';
  customCoverUrl: string = '';
  intro: string = '';
  customIntro: string = '';
  charset: string = '';
  type: number = 0;
  groupName: string = '';
  latestChapterTitle: string = '';
  latestChapterTime: number = 0;
  totalChapterNum: number = 0;
  wordCount: string = '';
  canUpdate: boolean = true;
  order: number = 0;
  originOrder: number = 0;
  readConfig: ReadConfig | null = null;
}

class ReadingProgressSyncPayload {
  bookUrl: string = '';
  origin: string = '';
  chapterTitle: string = '';
  chapterIndex: number = 0;
  chapterPos: number = 0;
  updatedAt: number = 0;
}

class BookGroupSyncPayload {
  name: string = '';
  order: number = 0;
  show: boolean = true;
  enableRefresh: boolean = true;
}

class BookmarkSyncPayload {
  bookUrl: string = '';
  bookName: string = '';
  bookAuthor: string = '';
  chapterIndex: number = 0;
  chapterName: string = '';
  pageIndex: number = 0;
  startPos: number = 0;
  endPos: number = 0;
  content: string = '';
  createTime: number = 0;
}

class BookSourceSyncPayload {
  bookSourceUrl: string = '';
  bookSourceName: string = '';
  bookSourceType: number = 0;
  bookSourceGroup: string = '';
  bookSourceComment: string = '';
  loginUrl: string = '';
  loginUi: string = '';
  loginCheckJs: string = '';
  loginHeader: string = '';
  bookUrlPattern: string = '';
  searchUrl: string = '';
  exploreUrl: string = '';
  jsLib: string = '';
  header: string = '';
  bookListRule: BookListRule = new BookListRule();
  searchRule: SearchRule = new SearchRule();
  exploreRule: ExploreRule = new ExploreRule();
  bookInfoRule: BookInfoRule = new BookInfoRule();
  tocRule: TocRule = new TocRule();
  contentRule: ContentRule = new ContentRule();
  variableComment: string = '';
  respondTime: number = 180000;
  customOrder: number = 0;
  customButton: boolean = false;
  eventListener: boolean = false;
  isPinned: boolean = false;
  enabled: boolean = true;
  enabledExplore: boolean = true;
  isLocked: boolean = false;
  weight: number = 0;
  concurrentRate: string = '';
  enabledCookieJar: boolean = true;
}

class AppearanceModeSyncPayload {
  mode: string = 'system';
}

class SearchPreferencesSyncPayload {
  showResultCover: boolean = true;
  useBookshelfCoverGallery: boolean = false;
  showResultTags: boolean = true;
  promptAddToShelfOnBack: boolean = true;
  exactSearch: boolean = false;
  exactSearchMatchAuthor: boolean = true;
  showSearchProgress: boolean = true;
}

class CustomThemeSchemesSyncPayload {
  schemes: CustomThemeScheme[] = [];
}

class LocalSyncEntity {
  entityType: string = '';
  entityId: string = '';
  payloadJson: string = '';
  contentHash: string = '';
  localKey: string = '';
}

export class CloudSyncRunResult {
  uploaded: number = 0;
  downloaded: number = 0;
  conflicts: number = 0;
}

export class CloudSyncCoordinator {
  static readonly TRIGGER_CHANGE: string = 'change';
  static readonly TRIGGER_FOREGROUND: string = 'foreground';
  static readonly TRIGGER_BACKGROUND: string = 'background';

  private static running: Promise<CloudSyncRunResult> | null = null;
  private static lastSyncAttemptAt: number = 0;
  private static deferredAutomaticTimer: number = -1;
  private static readonly AUTOMATIC_MIN_INTERVAL_MS: number = 15 * 1000;
  private static readonly FOREGROUND_REFRESH_INTERVAL_MS: number = 30 * 60 * 1000;
  private static readonly MAX_BATCH_OPERATIONS: number = 100;
  private static readonly MAX_BATCH_BYTES: number = 400 * 1024;
  private static readonly MAX_EXCHANGE_PAGES: number = 1000;

  static async syncNow(context: Context, conflictPolicy: string = 'cloud'): Promise<CloudSyncRunResult> {
    if (CloudSyncCoordinator.running) {
      return await CloudSyncCoordinator.running;
    }
    AppStorage.setOrCreate(CloudSyncSettingsStore.STORAGE_RUNTIME_ACTIVE, true);
    const task = CloudSyncCoordinator.run(context, conflictPolicy === 'local' ? 'local' : 'cloud');
    CloudSyncCoordinator.running = task;
    CloudSyncCoordinator.lastSyncAttemptAt = Date.now();
    try {
      return await task;
    } finally {
      if (CloudSyncCoordinator.running === task) {
        CloudSyncCoordinator.running = null;
      }
      AppStorage.setOrCreate(CloudSyncSettingsStore.STORAGE_RUNTIME_ACTIVE, false);
    }
  }

  static isRunning(): boolean {
    return CloudSyncCoordinator.running !== null;
  }

  static async needsInitialConflictChoice(context: Context): Promise<boolean> {
    await AccountSessionStore.load(context);
    if (!AccountSessionStore.isLoggedIn()) {
      return false;
    }
    const userId = AccountSessionStore.account().userId;
    const state = await CloudSyncStateStore.load(context, userId);
    if (state.cursor > 0 || Object.keys(state.entities).length > 0) {
      return false;
    }
    const summary = await AccountCommerceApi.fetchSyncSummary(AccountSessionStore.token());
    return Math.max(0, Math.floor(Number(summary.activeEntityCount) || 0)) > 0;
  }

  static async syncAutomatically(context: Context,
    trigger: string = CloudSyncCoordinator.TRIGGER_FOREGROUND): Promise<void> {
    const localChangeTrigger = trigger === CloudSyncCoordinator.TRIGGER_CHANGE;
    const backgroundTrigger = trigger === CloudSyncCoordinator.TRIGGER_BACKGROUND;
    const hasLocalChanges = CloudSyncChangeTracker.hasUnsyncedChanges();
    if ((localChangeTrigger || backgroundTrigger) && !hasLocalChanges) {
      return;
    }
    if (CloudSyncCoordinator.running) {
      if (hasLocalChanges) {
        CloudSyncCoordinator.scheduleDeferredAutomaticSync(context, 2000);
      }
      return;
    }
    await AccountSessionStore.load(context);
    if (!AccountSessionStore.isLoggedIn()) {
      return;
    }
    const userId = AccountSessionStore.account().userId;
    const settings = await CloudSyncSettingsStore.load(context, userId);
    if (!settings.enabled || !settings.autoSyncEnabled ||
      (trigger === CloudSyncCoordinator.TRIGGER_FOREGROUND && !settings.foregroundSyncEnabled)) {
      return;
    }
    const now = Date.now();
    if (trigger === CloudSyncCoordinator.TRIGGER_FOREGROUND && !hasLocalChanges &&
      settings.lastSuccessAt > 0 &&
      now - settings.lastSuccessAt < CloudSyncCoordinator.FOREGROUND_REFRESH_INTERVAL_MS) {
      return;
    }
    if (settings.wifiOnly && !CloudSyncCoordinator.isWifiConnected()) {
      return;
    }
    const throttleRemaining = CloudSyncCoordinator.AUTOMATIC_MIN_INTERVAL_MS -
      (now - CloudSyncCoordinator.lastSyncAttemptAt);
    if (!backgroundTrigger && throttleRemaining > 0) {
      if (localChangeTrigger) {
        CloudSyncCoordinator.scheduleDeferredAutomaticSync(context, throttleRemaining + 100);
      }
      return;
    }
    try {
      await CloudSyncCoordinator.syncNow(context);
    } catch (error) {
      console.warn('自动同步失败:', error);
    }
  }

  private static scheduleDeferredAutomaticSync(context: Context, delayMs: number): void {
    if (CloudSyncCoordinator.deferredAutomaticTimer >= 0) {
      return;
    }
    CloudSyncCoordinator.deferredAutomaticTimer = setTimeout(() => {
      CloudSyncCoordinator.deferredAutomaticTimer = -1;
      CloudSyncCoordinator.syncAutomatically(
        context, CloudSyncCoordinator.TRIGGER_CHANGE).catch((error: Error) => {
        console.warn('延迟自动同步失败:', error);
      });
    }, Math.max(500, Math.floor(delayMs)));
  }

  private static async run(context: Context, conflictPolicy: string): Promise<CloudSyncRunResult> {
    await AccountSessionStore.load(context);
    if (!AccountSessionStore.isLoggedIn()) {
      throw new Error('请先登录华为账号');
    }
    const userId = AccountSessionStore.account().userId;
    const settings = await CloudSyncSettingsStore.load(context, userId);
    if (!settings.enabled) {
      throw new Error('请先开启云同步');
    }
    const changeSnapshot: CloudSyncChangeSnapshot = CloudSyncChangeTracker.snapshot();

    const result = new CloudSyncRunResult();
    settings.status = CloudSyncSettingsStore.STATUS_SYNCING;
    settings.errorMessage = '';
    await CloudSyncSettingsStore.saveRuntimeState(context, userId, settings.status,
      settings.lastSuccessAt, settings.pendingCount, settings.errorMessage);

    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(context);
      const deviceId = await CloudSyncStateStore.deviceId(context);
      const state = await CloudSyncStateStore.load(context, userId);
      const localEntities = (await CloudSyncCoordinator.buildLocalEntities(context, db, settings))
        .filter((entity: LocalSyncEntity) =>
          CloudSyncCoordinator.scopeAllows(settings, entity.entityType));
      const operations = CloudSyncCoordinator.buildOperations(localEntities, state, settings);
      settings.pendingCount = operations.length;
      await CloudSyncSettingsStore.saveRuntimeState(context, userId, settings.status,
        settings.lastSuccessAt, settings.pendingCount, settings.errorMessage);

      let remaining = operations.slice();
      let hasMore = true;
      let exchangePages = 0;
      while (remaining.length > 0 || hasMore) {
        exchangePages++;
        if (exchangePages > CloudSyncCoordinator.MAX_EXCHANGE_PAGES) {
          throw new Error('同步分页次数异常，请稍后重试');
        }
        const batch = CloudSyncCoordinator.takeOperationBatch(remaining);
        const cursorBeforeExchange = state.cursor;
        const request = await CloudSyncCoordinator.exchangeRequest(
          context, deviceId, state.cursor, batch, conflictPolicy);
        const response = await AccountCommerceApi.exchangeSync(request, AccountSessionStore.token());
        CloudSyncCoordinator.validateResponse(response);
        const operationMap = CloudSyncCoordinator.operationEntityMap(batch, localEntities);
        CloudSyncChangeTracker.beginRemoteApply();
        try {
          result.conflicts += await CloudSyncCoordinator.applyAcknowledgements(
            context, db, response.acknowledgements || [], operationMap, state, deviceId);
          result.downloaded += await CloudSyncCoordinator.applyChanges(
            context, db, response.changes || [], state, deviceId, settings);
        } finally {
          CloudSyncChangeTracker.endRemoteApply();
        }
        result.uploaded += (response.acknowledgements || []).filter(
          (ack: CloudSyncAcknowledgement) => ack.accepted).length;
        const nextCursor = Math.max(state.cursor, Math.floor(Number(response.nextCursor) || 0));
        if (response.hasMore === true && batch.length === 0 && nextCursor <= cursorBeforeExchange) {
          throw new Error('服务端同步游标未推进，请稍后重试');
        }
        state.cursor = nextCursor;
        await CloudSyncStateStore.save(context, userId, state);
        hasMore = response.hasMore === true;
        if (batch.length === 0 && !hasMore) {
          break;
        }
      }

      settings.status = CloudSyncSettingsStore.STATUS_SYNCED;
      settings.lastSuccessAt = Date.now();
      settings.pendingCount = 0;
      settings.errorMessage = '';
      await CloudSyncSettingsStore.saveRuntimeState(context, userId, settings.status,
        settings.lastSuccessAt, settings.pendingCount, settings.errorMessage);
      CloudSyncChangeTracker.markSynced(changeSnapshot);
      if (result.downloaded > 0) {
        AppStorage.setOrCreate('shelfUpdateTime', Date.now());
      }
      return result;
    } catch (error) {
      settings.status = CloudSyncSettingsStore.STATUS_ERROR;
      settings.errorMessage = error instanceof Error ? error.message : String(error);
      await CloudSyncSettingsStore.saveRuntimeState(context, userId, settings.status,
        settings.lastSuccessAt, settings.pendingCount, settings.errorMessage);
      throw new Error(settings.errorMessage || '同步失败');
    }
  }

  private static takeOperationBatch(remaining: CloudSyncOperation[]): CloudSyncOperation[] {
    const result: CloudSyncOperation[] = [];
    let estimatedBytes = 2048;
    const encoder = new util.TextEncoder();
    while (remaining.length > 0 && result.length < CloudSyncCoordinator.MAX_BATCH_OPERATIONS) {
      const operation = remaining[0];
      if (!operation) break;
      const operationBytes = encoder.encodeInto(JSON.stringify(operation)).byteLength + 1;
      if (result.length > 0 &&
        estimatedBytes + operationBytes > CloudSyncCoordinator.MAX_BATCH_BYTES) {
        break;
      }
      remaining.shift();
      result.push(operation);
      estimatedBytes += operationBytes;
    }
    return result;
  }

  private static async buildLocalEntities(context: Context, db: AppDatabase,
    settings: CloudSyncSettings): Promise<LocalSyncEntity[]> {
    const result: LocalSyncEntity[] = [];
    const groups = await db.getCustomBookGroups();
    const groupNames: Record<string, string> = {};
    for (const group of groups) {
      groupNames[String(group.groupId)] = group.groupName;
      const payload = new BookGroupSyncPayload();
      payload.name = group.groupName;
      payload.order = group.order;
      payload.show = group.show;
      payload.enableRefresh = group.enableRefresh;
      result.push(CloudSyncCoordinator.entity(
        'book_group',
        CloudSyncCoordinator.identity('group', group.groupName),
        payload,
        group.groupName
      ));
    }

    const allBooks = await db.getAllBooks();
    const onlineBooks = allBooks.filter((book: Book) => !!book.origin && book.origin !== 'local');
    const onlineBookUrls = new Set<string>();
    for (const book of onlineBooks) {
      onlineBookUrls.add(book.bookUrl);
      const bookId = CloudSyncCoordinator.identity('book', `${book.origin}\n${book.bookUrl}`);
      const shelf = new BookshelfSyncPayload();
      shelf.bookUrl = book.bookUrl;
      shelf.tocUrl = book.tocUrl;
      shelf.origin = book.origin;
      shelf.originName = book.originName;
      shelf.name = book.name;
      shelf.author = book.author;
      shelf.kind = book.kind;
      shelf.customTag = book.customTag;
      shelf.coverUrl = book.coverUrl;
      shelf.customCoverUrl = book.customCoverUrl;
      shelf.intro = book.intro;
      shelf.customIntro = book.customIntro;
      shelf.charset = book.charset;
      shelf.type = book.type;
      shelf.groupName = groupNames[String(book.group)] || '';
      shelf.latestChapterTitle = book.latestChapterTitle;
      shelf.latestChapterTime = book.latestChapterTime;
      shelf.totalChapterNum = book.totalChapterNum;
      shelf.wordCount = book.wordCount;
      shelf.canUpdate = book.canUpdate;
      shelf.order = book.order;
      shelf.originOrder = book.originOrder;
      shelf.readConfig = book.readConfig;
      result.push(CloudSyncCoordinator.entity('bookshelf_item', bookId, shelf, book.bookUrl));

      const progress = new ReadingProgressSyncPayload();
      progress.bookUrl = book.bookUrl;
      progress.origin = book.origin;
      progress.chapterTitle = book.durChapterTitle;
      progress.chapterIndex = book.durChapterIndex;
      progress.chapterPos = book.durChapterPos;
      progress.updatedAt = book.durChapterTime;
      result.push(CloudSyncCoordinator.entity('reading_progress', bookId, progress, book.bookUrl));
    }

    const bookmarks = await db.getAllBookmarks();
    for (const bookmark of bookmarks) {
      if (!onlineBookUrls.has(bookmark.bookUrl)) {
        continue;
      }
      const payload = new BookmarkSyncPayload();
      payload.bookUrl = bookmark.bookUrl;
      payload.bookName = bookmark.bookName;
      payload.bookAuthor = bookmark.bookAuthor;
      payload.chapterIndex = bookmark.chapterIndex;
      payload.chapterName = bookmark.chapterName;
      payload.pageIndex = bookmark.pageIndex;
      payload.startPos = bookmark.startPos;
      payload.endPos = bookmark.endPos;
      payload.content = bookmark.content;
      payload.createTime = bookmark.createTime;
      const bookmarkKey = CloudSyncCoordinator.bookmarkKey(bookmark);
      result.push(CloudSyncCoordinator.entity(
        'bookmark',
        CloudSyncCoordinator.identity('bookmark', bookmarkKey),
        payload,
        bookmarkKey
      ));
    }

    if (settings.bookSourcesEnabled) {
      const bookSources = await db.getAllBookSources();
      for (const source of bookSources) {
        const payload = CloudSyncCoordinator.bookSourcePayload(source);
        result.push(CloudSyncCoordinator.entity(
          'book_source',
          CloudSyncCoordinator.identity('source', source.bookSourceUrl),
          payload,
          source.bookSourceUrl
        ));
      }
    }

    const readerSettings = await ReaderSettingsStore.load(context);
    const safeReaderSettings = JSON.parse(JSON.stringify(readerSettings)) as ReaderSettings;
    safeReaderSettings.fontFilePath = '';
    safeReaderSettings.customFontsRaw = '';
    if (safeReaderSettings.fontMode === 'custom') {
      safeReaderSettings.fontMode = 'system';
      safeReaderSettings.fontFamily = '';
      safeReaderSettings.fontSourceName = '系统默认';
    }
    result.push(CloudSyncCoordinator.entity(
      'reader_settings', 'global', safeReaderSettings, 'global'));

    const replaceRules = await ReaderReplaceRuleStore.load(context);
    for (const rule of replaceRules) {
      result.push(CloudSyncCoordinator.entity(
        'replace_rule', `rule_${Math.max(0, Math.floor(rule.id))}`, rule, String(rule.id)));
    }

    const themeSettings = await AppThemeSettingsStore.load(context);
    const safeThemeSettings = JSON.parse(JSON.stringify(themeSettings)) as AppThemeSettings;
    safeThemeSettings.customLightReaderBackgroundAssetId = '';
    safeThemeSettings.customDarkReaderBackgroundAssetId = '';
    safeThemeSettings.customLightStartupImagePath = '';
    safeThemeSettings.customDarkStartupImagePath = '';
    result.push(CloudSyncCoordinator.entity(
      'theme_settings', 'global', safeThemeSettings, 'global'));

    const appearance = new AppearanceModeSyncPayload();
    appearance.mode = await AppThemeModeStore.load(context);
    result.push(CloudSyncCoordinator.entity(
      'appearance_mode', 'global', appearance, 'global'));

    const bookshelfDisplay = await BookshelfDisplaySettingsStore.load(context);
    result.push(CloudSyncCoordinator.entity(
      'bookshelf_display', 'global', bookshelfDisplay, 'global'));

    const searchSettings = await SearchExploreSettingsStore.load(context);
    const searchPreferences = new SearchPreferencesSyncPayload();
    searchPreferences.showResultCover = searchSettings.showResultCover;
    searchPreferences.useBookshelfCoverGallery = searchSettings.useBookshelfCoverGallery;
    searchPreferences.showResultTags = searchSettings.showResultTags;
    searchPreferences.promptAddToShelfOnBack = searchSettings.promptAddToShelfOnBack;
    searchPreferences.exactSearch = searchSettings.exactSearch;
    searchPreferences.exactSearchMatchAuthor = searchSettings.exactSearchMatchAuthor;
    searchPreferences.showSearchProgress = searchSettings.showSearchProgress;
    result.push(CloudSyncCoordinator.entity(
      'search_preferences', 'global', searchPreferences, 'global'));

    const themeSchemes = await CustomThemeSchemeStore.load(context, themeSettings);
    const schemesPayload = new CustomThemeSchemesSyncPayload();
    schemesPayload.schemes = themeSchemes.map((scheme: CustomThemeScheme) => {
      const safeScheme = JSON.parse(JSON.stringify(scheme)) as CustomThemeScheme;
      safeScheme.settings.customLightReaderBackgroundAssetId = '';
      safeScheme.settings.customDarkReaderBackgroundAssetId = '';
      safeScheme.settings.customLightStartupImagePath = '';
      safeScheme.settings.customDarkStartupImagePath = '';
      return safeScheme;
    });
    result.push(CloudSyncCoordinator.entity(
      'custom_theme_schemes', 'global', schemesPayload, 'global'));
    return result;
  }

  private static buildOperations(
    entities: LocalSyncEntity[],
    state: CloudSyncLocalState,
    settings: CloudSyncSettings
  ): CloudSyncOperation[] {
    const result: CloudSyncOperation[] = [];
    const currentKeys = new Set<string>();
    for (const entity of entities) {
      const key = CloudSyncStateStore.entityKey(entity.entityType, entity.entityId);
      currentKeys.add(key);
      const previous = state.entities[key] || new CloudSyncEntityState();
      if (!previous.deleted && previous.contentHash === entity.contentHash) {
        continue;
      }
      const operation = new CloudSyncOperation();
      operation.opId = util.generateRandomUUID();
      operation.entityType = entity.entityType;
      operation.entityId = entity.entityId;
      operation.operation = 'upsert';
      operation.baseRevision = previous.revision;
      operation.payload = JSON.parse(entity.payloadJson) as Object;
      result.push(operation);
    }
    for (const key of Object.keys(state.entities)) {
      const previous = state.entities[key];
      if (!previous || previous.deleted || currentKeys.has(key)) {
        continue;
      }
      const separator = key.indexOf(':');
      if (separator <= 0) {
        continue;
      }
      const entityType = key.substring(0, separator);
      if (!CloudSyncCoordinator.scopeAllows(settings, entityType)) {
        continue;
      }
      const operation = new CloudSyncOperation();
      operation.opId = util.generateRandomUUID();
      operation.entityType = entityType;
      operation.entityId = key.substring(separator + 1);
      operation.operation = 'delete';
      operation.baseRevision = previous.revision;
      result.push(operation);
    }
    return result;
  }

  private static async exchangeRequest(
    context: Context,
    deviceId: string,
    cursor: number,
    operations: CloudSyncOperation[],
    conflictPolicy: string
  ): Promise<CloudSyncExchangeRequest> {
    const request = new CloudSyncExchangeRequest();
    request.deviceId = deviceId;
    request.deviceName = CloudSyncCoordinator.deviceName();
    request.platform = 'HarmonyOS';
    request.appVersion = CloudSyncCoordinator.appVersion();
    request.deviceKind = CloudSyncCoordinator.deviceKind();
    request.conflictPolicy = conflictPolicy === 'local' ? 'local' : 'cloud';
    request.cursor = cursor;
    request.operations = operations;
    return request;
  }

  private static appVersion(): string {
    try {
      return bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName || '';
    } catch (e) {
      return '';
    }
  }

  private static deviceName(): string {
    try {
      return deviceInfo.marketName || deviceInfo.productModelAlias ||
        deviceInfo.productModel || deviceInfo.productSeries || deviceInfo.brand || 'HarmonyOS 设备';
    } catch (e) {
      return 'HarmonyOS 设备';
    }
  }

  private static deviceKind(): string {
    try {
      if (display.isFoldable()) {
        return 'foldable';
      }
    } catch (e) {
    }
    try {
      const type = (deviceInfo.deviceType || '').toLowerCase();
      if (type.includes('tablet')) {
        return 'tablet';
      }
      if (type.includes('phone')) {
        return 'phone';
      }
    } catch (e) {
    }
    return 'unknown';
  }

  private static isWifiConnected(): boolean {
    try {
      const handle = connection.getDefaultNetSync();
      const capabilities = connection.getNetCapabilitiesSync(handle);
      return (capabilities.bearerTypes || []).includes(connection.NetBearType.BEARER_WIFI);
    } catch (e) {
      return false;
    }
  }

  private static operationEntityMap(
    operations: CloudSyncOperation[],
    entities: LocalSyncEntity[]
  ): Record<string, LocalSyncEntity> {
    const result: Record<string, LocalSyncEntity> = {};
    for (const operation of operations) {
      const entity = entities.find((item: LocalSyncEntity) =>
        item.entityType === operation.entityType && item.entityId === operation.entityId);
      if (entity) {
        result[operation.opId] = entity;
      } else {
        const deleted = new LocalSyncEntity();
        deleted.entityType = operation.entityType;
        deleted.entityId = operation.entityId;
        result[operation.opId] = deleted;
      }
    }
    return result;
  }

  private static async applyAcknowledgements(
    context: Context,
    db: AppDatabase,
    acknowledgements: CloudSyncAcknowledgement[],
    operationMap: Record<string, LocalSyncEntity>,
    state: CloudSyncLocalState,
    deviceId: string
  ): Promise<number> {
    let conflicts = 0;
    for (const ack of acknowledgements) {
      const local = operationMap[ack.opId];
      if (!local) {
        continue;
      }
      const key = CloudSyncStateStore.entityKey(local.entityType, local.entityId);
      const entityState = state.entities[key] || new CloudSyncEntityState();
      entityState.revision = Math.max(0, Math.floor(Number(ack.revision) || 0));
      entityState.localKey = local.localKey || entityState.localKey;
      state.entities[key] = entityState;
      if (ack.accepted) {
        entityState.deleted = !local.payloadJson;
        entityState.contentHash = local.contentHash;
      } else {
        conflicts++;
        const conflict = ack.conflict;
        await CloudSyncCoordinator.applyEntity(
          context,
          db,
          local.entityType,
          local.entityId,
          entityState.revision,
          conflict?.deleted === true ? 'delete' : 'upsert',
          conflict?.payload || null,
          state,
          deviceId
        );
      }
    }
    return conflicts;
  }

  private static async applyChanges(
    context: Context,
    db: AppDatabase,
    changes: CloudSyncChange[],
    state: CloudSyncLocalState,
    deviceId: string,
    settings: CloudSyncSettings
  ): Promise<number> {
    const ordered = changes.slice().sort((left: CloudSyncChange, right: CloudSyncChange) => {
      const priority = CloudSyncCoordinator.entityPriority(left.entityType) -
        CloudSyncCoordinator.entityPriority(right.entityType);
      return priority !== 0 ? priority : left.sequenceId - right.sequenceId;
    });
    let applied = 0;
    for (const change of ordered) {
      if (!CloudSyncCoordinator.scopeAllows(settings, change.entityType)) {
        continue;
      }
      const key = CloudSyncStateStore.entityKey(change.entityType, change.entityId);
      const entityState = state.entities[key] || new CloudSyncEntityState();
      if (change.revision < entityState.revision) {
        continue;
      }
      if (change.deviceId === deviceId && change.revision === entityState.revision) {
        continue;
      }
      await CloudSyncCoordinator.applyEntity(
        context,
        db,
        change.entityType,
        change.entityId,
        change.revision,
        change.operation,
        change.payload,
        state,
        deviceId
      );
      applied++;
    }
    return applied;
  }

  private static async applyEntity(
    context: Context,
    db: AppDatabase,
    entityType: string,
    entityId: string,
    revision: number,
    operation: string,
    payload: Object | null,
    state: CloudSyncLocalState,
    _deviceId: string
  ): Promise<void> {
    const key = CloudSyncStateStore.entityKey(entityType, entityId);
    const entityState = state.entities[key] || new CloudSyncEntityState();
    if (operation === 'delete') {
      await CloudSyncCoordinator.applyDelete(context, db, entityType, entityId, entityState);
      entityState.revision = revision;
      entityState.deleted = true;
      entityState.contentHash = '';
      state.entities[key] = entityState;
      return;
    }
    if (!payload) {
      return;
    }
    const raw = JSON.stringify(payload);
    if (entityType === 'book_group') {
      const group = JSON.parse(raw) as BookGroupSyncPayload;
      await CloudSyncCoordinator.restoreGroup(db, group);
      entityState.localKey = group.name;
    } else if (entityType === 'bookshelf_item') {
      const shelf = JSON.parse(raw) as BookshelfSyncPayload;
      await CloudSyncCoordinator.restoreBook(db, shelf);
      entityState.localKey = shelf.bookUrl;
    } else if (entityType === 'reading_progress') {
      const progress = JSON.parse(raw) as ReadingProgressSyncPayload;
      const book = await db.getBook(progress.bookUrl);
      if (book && progress.updatedAt >= book.durChapterTime) {
        await db.updateBookReadingProgress(
          progress.bookUrl,
          progress.chapterTitle,
          progress.chapterIndex,
          progress.chapterPos,
          progress.updatedAt,
          book.variable,
          false
        );
      }
      entityState.localKey = progress.bookUrl;
    } else if (entityType === 'bookmark') {
      const bookmarkPayload = JSON.parse(raw) as BookmarkSyncPayload;
      const bookmark = CloudSyncCoordinator.bookmarkFromPayload(bookmarkPayload);
      await db.restoreBookmark(bookmark);
      entityState.localKey = CloudSyncCoordinator.bookmarkKey(bookmark);
    } else if (entityType === 'book_source') {
      const sourcePayload = JSON.parse(raw) as BookSourceSyncPayload;
      const source = await CloudSyncCoordinator.bookSourceFromPayload(db, sourcePayload);
      if (!source) {
        return;
      }
      await db.restoreBookSource(source);
      entityState.localKey = source.bookSourceUrl;
      CloudSyncCoordinator.notifyBookSourcesChanged();
    } else if (entityType === 'reader_settings') {
      const readerSettings = JSON.parse(raw) as ReaderSettings;
      await ReaderSettingsStore.saveAll(
        context,
        readerSettings,
        AppStorage.get<boolean>('appDarkMode') || false
      );
      entityState.localKey = 'global';
    } else if (entityType === 'replace_rule') {
      const remoteRule = JSON.parse(raw) as ReaderReplaceRule;
      const rules = await ReaderReplaceRuleStore.load(context, true);
      const next = rules.filter((rule: ReaderReplaceRule) => rule.id !== remoteRule.id);
      next.push(remoteRule);
      await ReaderReplaceRuleStore.save(context, next);
      entityState.localKey = String(remoteRule.id);
    } else if (entityType === 'theme_settings') {
      const themeSettings = JSON.parse(raw) as AppThemeSettings;
      const localThemeSettings = await AppThemeSettingsStore.load(context);
      themeSettings.customLightStartupImagePath = localThemeSettings.customLightStartupImagePath;
      themeSettings.customDarkStartupImagePath = localThemeSettings.customDarkStartupImagePath;
      await AppThemeSettingsStore.save(context, themeSettings);
      AppThemeSettingsStore.applyToStorage(themeSettings);
      entityState.localKey = 'global';
    } else if (entityType === 'appearance_mode') {
      const appearance = JSON.parse(raw) as AppearanceModeSyncPayload;
      await AppThemeModeStore.save(context, appearance.mode);
      entityState.localKey = 'global';
    } else if (entityType === 'bookshelf_display') {
      const displaySettings = JSON.parse(raw) as BookshelfDisplaySettings;
      await BookshelfDisplaySettingsStore.save(context, displaySettings);
      BookshelfDisplaySettingsStore.applyToStorage(displaySettings);
      entityState.localKey = 'global';
    } else if (entityType === 'search_preferences') {
      const remoteSearch = JSON.parse(raw) as SearchPreferencesSyncPayload;
      const searchSettings = await SearchExploreSettingsStore.load(context);
      searchSettings.showResultCover = remoteSearch.showResultCover !== false;
      searchSettings.useBookshelfCoverGallery = remoteSearch.useBookshelfCoverGallery === true;
      searchSettings.showResultTags = remoteSearch.showResultTags !== false;
      searchSettings.promptAddToShelfOnBack = remoteSearch.promptAddToShelfOnBack !== false;
      searchSettings.exactSearch = remoteSearch.exactSearch === true;
      searchSettings.exactSearchMatchAuthor = remoteSearch.exactSearchMatchAuthor !== false;
      searchSettings.showSearchProgress = remoteSearch.showSearchProgress !== false;
      await SearchExploreSettingsStore.save(context, searchSettings);
      SearchExploreSettingsStore.applyToStorage(searchSettings);
      entityState.localKey = 'global';
    } else if (entityType === 'custom_theme_schemes') {
      const schemesPayload = JSON.parse(raw) as CustomThemeSchemesSyncPayload;
      const legacySettings = await AppThemeSettingsStore.load(context);
      await CustomThemeSchemeStore.replaceFromSync(
        context, legacySettings, schemesPayload.schemes || []);
      entityState.localKey = 'global';
    }
    entityState.revision = revision;
    entityState.deleted = false;
    entityState.contentHash = CloudSyncCoordinator.digest(raw);
    state.entities[key] = entityState;
  }

  private static async applyDelete(
    context: Context,
    db: AppDatabase,
    entityType: string,
    entityId: string,
    entityState: CloudSyncEntityState
  ): Promise<void> {
    if (entityType === 'bookshelf_item' && entityState.localKey) {
      await db.deleteBook(entityState.localKey);
    } else if (entityType === 'book_group' && entityState.localKey) {
      const groups = await db.getCustomBookGroups();
      const group = groups.find((item: BookGroup) => item.groupName === entityState.localKey);
      if (group) {
        await db.deleteBookGroup(group.groupId);
      }
    } else if (entityType === 'bookmark') {
      const bookmarks = await db.getAllBookmarks();
      for (const bookmark of bookmarks) {
        if (CloudSyncCoordinator.identity('bookmark',
          CloudSyncCoordinator.bookmarkKey(bookmark)) === entityId) {
          await db.deleteBookmark(bookmark.id);
          break;
        }
      }
    } else if (entityType === 'replace_rule') {
      const ruleId = Number(entityState.localKey || entityId.replace(/^rule_/, ''));
      const rules = await ReaderReplaceRuleStore.load(context, true);
      await ReaderReplaceRuleStore.save(
        context,
        rules.filter((rule: ReaderReplaceRule) => rule.id !== ruleId)
      );
    } else if (entityType === 'book_source') {
      let bookSourceUrl = entityState.localKey;
      if (!bookSourceUrl) {
        const sources = await db.getAllBookSources();
        const matched = sources.find((source: BookSource) =>
          CloudSyncCoordinator.identity('source', source.bookSourceUrl) === entityId);
        bookSourceUrl = matched?.bookSourceUrl || '';
      }
      if (bookSourceUrl) {
        await db.deleteBookSourceForSync(bookSourceUrl);
        CloudSyncCoordinator.notifyBookSourcesChanged();
      }
    }
  }

  private static async restoreGroup(db: AppDatabase, payload: BookGroupSyncPayload): Promise<BookGroup | null> {
    if (!payload.name?.trim()) {
      return null;
    }
    const groups = await db.getCustomBookGroups();
    let group = groups.find((item: BookGroup) => item.groupName === payload.name) || null;
    if (!group) {
      group = await db.addBookGroup(payload.name);
    }
    if (!group) {
      return null;
    }
    group.order = Math.max(0, Math.floor(Number(payload.order) || 0));
    group.show = payload.show !== false;
    group.enableRefresh = payload.enableRefresh !== false;
    await db.restoreBookGroup(group);
    return group;
  }

  private static async restoreBook(db: AppDatabase, payload: BookshelfSyncPayload): Promise<void> {
    if (!payload.bookUrl || !payload.origin || payload.origin === 'local') {
      return;
    }
    const existing = await db.getBook(payload.bookUrl);
    const book = existing || new Book();
    book.bookUrl = payload.bookUrl;
    book.tocUrl = payload.tocUrl || '';
    book.origin = payload.origin;
    book.originName = payload.originName || '';
    book.name = payload.name || '';
    book.author = payload.author || '';
    book.kind = payload.kind || '';
    book.customTag = payload.customTag || '';
    book.coverUrl = payload.coverUrl || '';
    book.customCoverUrl = payload.customCoverUrl || '';
    book.intro = payload.intro || '';
    book.customIntro = payload.customIntro || '';
    book.charset = payload.charset || '';
    book.type = Math.floor(Number(payload.type) || 0);
    book.latestChapterTitle = payload.latestChapterTitle || '';
    book.latestChapterTime = Math.max(0, Math.floor(Number(payload.latestChapterTime) || 0));
    book.totalChapterNum = Math.max(0, Math.floor(Number(payload.totalChapterNum) || 0));
    book.wordCount = payload.wordCount || '';
    book.canUpdate = payload.canUpdate !== false;
    book.order = Math.floor(Number(payload.order) || 0);
    book.originOrder = Math.floor(Number(payload.originOrder) || 0);
    book.readConfig = payload.readConfig || null;
    if (payload.groupName) {
      const group = await CloudSyncCoordinator.restoreGroup(db, {
        name: payload.groupName,
        order: 0,
        show: true,
        enableRefresh: true
      });
      book.group = group?.groupId || 0;
    } else {
      book.group = 0;
    }
    await db.restoreBook(book);
  }

  private static bookmarkFromPayload(payload: BookmarkSyncPayload): Bookmark {
    const bookmark = new Bookmark();
    bookmark.bookUrl = payload.bookUrl || '';
    bookmark.bookName = payload.bookName || '';
    bookmark.bookAuthor = payload.bookAuthor || '';
    bookmark.chapterIndex = Math.floor(Number(payload.chapterIndex) || 0);
    bookmark.chapterName = payload.chapterName || '';
    bookmark.pageIndex = Math.floor(Number(payload.pageIndex) || 0);
    bookmark.startPos = Math.floor(Number(payload.startPos) || 0);
    bookmark.endPos = Math.floor(Number(payload.endPos) || 0);
    bookmark.content = payload.content || '';
    bookmark.createTime = Math.max(0, Math.floor(Number(payload.createTime) || 0));
    return bookmark;
  }

  private static bookmarkKey(bookmark: Bookmark): string {
    return `${bookmark.bookUrl}\n${bookmark.chapterIndex}\n${bookmark.pageIndex}\n` +
      `${bookmark.startPos}\n${bookmark.createTime}`;
  }

  private static bookSourcePayload(source: BookSource): BookSourceSyncPayload {
    const payload = new BookSourceSyncPayload();
    payload.bookSourceUrl = source.bookSourceUrl || '';
    payload.bookSourceName = source.bookSourceName || '';
    payload.bookSourceType = Math.floor(Number(source.bookSourceType) || 0);
    payload.bookSourceGroup = source.bookSourceGroup || '';
    payload.bookSourceComment = source.bookSourceComment || '';
    payload.loginUrl = source.loginUrl || '';
    payload.loginUi = source.loginUi || '';
    payload.loginCheckJs = source.loginCheckJs || '';
    payload.loginHeader = CloudSyncCoordinator.sanitizeBookSourceHeader(source.loginHeader);
    payload.bookUrlPattern = source.bookUrlPattern || '';
    payload.searchUrl = source.searchUrl || '';
    payload.exploreUrl = source.exploreUrl || '';
    payload.jsLib = source.jsLib || '';
    payload.header = CloudSyncCoordinator.sanitizeBookSourceHeader(source.header);
    payload.bookListRule = JSON.parse(JSON.stringify(source.bookListRule || {})) as BookListRule;
    payload.searchRule = JSON.parse(JSON.stringify(source.searchRule || {})) as SearchRule;
    payload.exploreRule = JSON.parse(JSON.stringify(source.exploreRule || {})) as ExploreRule;
    payload.bookInfoRule = JSON.parse(JSON.stringify(source.bookInfoRule || {})) as BookInfoRule;
    payload.tocRule = JSON.parse(JSON.stringify(source.tocRule || {})) as TocRule;
    payload.contentRule = JSON.parse(JSON.stringify(source.contentRule || {})) as ContentRule;
    payload.variableComment = source.variableComment || '';
    payload.respondTime = Math.max(0, Math.floor(Number(source.respondTime) || 180000));
    payload.customOrder = Math.max(0, Math.floor(Number(source.customOrder) || 0));
    payload.customButton = source.customButton === true;
    payload.eventListener = source.eventListener === true;
    payload.isPinned = source.isPinned === true;
    payload.enabled = source.enabled !== false;
    payload.enabledExplore = source.enabledExplore !== false;
    payload.isLocked = source.isLocked === true;
    payload.weight = Math.floor(Number(source.weight) || 0);
    payload.concurrentRate = source.concurrentRate || '';
    payload.enabledCookieJar = source.enabledCookieJar !== false;
    return payload;
  }

  private static async bookSourceFromPayload(db: AppDatabase,
    payload: BookSourceSyncPayload): Promise<BookSource | null> {
    const bookSourceUrl = (payload.bookSourceUrl || '').trim();
    if (!bookSourceUrl) {
      return null;
    }
    const existing = await db.getBookSource(bookSourceUrl);
    const source = new BookSource();
    source.bookSourceUrl = bookSourceUrl;
    source.bookSourceName = payload.bookSourceName || '';
    source.bookSourceType = Math.floor(Number(payload.bookSourceType) || 0);
    source.bookSourceGroup = payload.bookSourceGroup || '';
    source.bookSourceComment = payload.bookSourceComment || '';
    source.loginUrl = payload.loginUrl || '';
    source.loginUi = payload.loginUi || '';
    source.loginCheckJs = payload.loginCheckJs || '';
    source.loginHeader = CloudSyncCoordinator.mergeLocalSensitiveHeaders(
      payload.loginHeader || '', existing?.loginHeader || '');
    source.rawSourceJson = existing?.rawSourceJson || '';
    source.bookUrlPattern = payload.bookUrlPattern || '';
    source.searchUrl = payload.searchUrl || '';
    source.exploreUrl = payload.exploreUrl || '';
    source.jsLib = payload.jsLib || '';
    source.header = CloudSyncCoordinator.mergeLocalSensitiveHeaders(
      payload.header || '', existing?.header || '');
    source.bookListRule = payload.bookListRule || new BookListRule();
    source.searchRule = payload.searchRule || new SearchRule();
    source.exploreRule = payload.exploreRule || new ExploreRule();
    source.bookInfoRule = payload.bookInfoRule || new BookInfoRule();
    source.tocRule = payload.tocRule || new TocRule();
    source.contentRule = payload.contentRule || new ContentRule();
    source.variableComment = payload.variableComment || '';
    source.variable = existing?.variable || '';
    source.lastUpdateTime = Date.now();
    source.respondTime = Math.max(0, Math.floor(Number(payload.respondTime) || 180000));
    source.customOrder = Math.max(0, Math.floor(Number(payload.customOrder) || 0));
    source.customButton = payload.customButton === true;
    source.eventListener = payload.eventListener === true;
    source.isPinned = payload.isPinned === true;
    source.enabled = payload.enabled !== false;
    source.enabledExplore = payload.enabledExplore !== false;
    source.isLocked = payload.isLocked === true;
    source.validationStatus = existing?.validationStatus || BookSource.VALIDATION_UNCHECKED;
    source.weight = Math.floor(Number(payload.weight) || 0);
    source.concurrentRate = payload.concurrentRate || '';
    source.enabledCookieJar = payload.enabledCookieJar !== false;
    return source;
  }

  private static sanitizeBookSourceHeader(raw: string): string {
    const value = (raw || '').trim();
    if (!value) {
      return '';
    }
    try {
      const parsed = JSON.parse(value) as Record<string, Object>;
      if (parsed && !Array.isArray(parsed)) {
        const sanitized: Record<string, Object> = {};
        for (const key of Object.keys(parsed)) {
          if (!CloudSyncCoordinator.isSensitiveHeaderName(key)) {
            sanitized[key] = parsed[key];
          }
        }
        return JSON.stringify(sanitized);
      }
    } catch (e) {
    }
    return CloudSyncCoordinator.containsSensitiveHeader(value) ? '' : value;
  }

  private static mergeLocalSensitiveHeaders(remoteRaw: string, localRaw: string): string {
    const remote = remoteRaw || '';
    const local = localRaw || '';
    if (!local) {
      return remote;
    }
    try {
      const remoteHeaders = JSON.parse(remote || '{}') as Record<string, Object>;
      const localHeaders = JSON.parse(local) as Record<string, Object>;
      if (remoteHeaders && localHeaders &&
        !Array.isArray(remoteHeaders) && !Array.isArray(localHeaders)) {
        const merged: Record<string, Object> = {};
        for (const key of Object.keys(remoteHeaders)) {
          merged[key] = remoteHeaders[key];
        }
        for (const key of Object.keys(localHeaders)) {
          if (CloudSyncCoordinator.isSensitiveHeaderName(key)) {
            merged[key] = localHeaders[key];
          }
        }
        return JSON.stringify(merged);
      }
    } catch (e) {
    }
    return CloudSyncCoordinator.containsSensitiveHeader(local) ? local : remote;
  }

  private static containsSensitiveHeader(value: string): boolean {
    return /(^|[\s{,;"'])(cookie|authorization|proxy-authorization|x-api-key|api-key)\s*[:=]/i
      .test(value || '');
  }

  private static isSensitiveHeaderName(name: string): boolean {
    const normalized = (name || '').toLowerCase().replace(/[-_\s]/g, '');
    return normalized === 'cookie' ||
      normalized === 'authorization' ||
      normalized === 'proxyauthorization' ||
      normalized === 'xapikey' ||
      normalized === 'apikey';
  }

  private static notifyBookSourcesChanged(): void {
    const revision = AppStorage.get<number>('bookSourceOrderRevision') || 0;
    AppStorage.setOrCreate('bookSourceOrderRevision', revision + 1);
  }

  private static entity(entityType: string, entityId: string, payload: Object,
    localKey: string): LocalSyncEntity {
    const result = new LocalSyncEntity();
    result.entityType = entityType;
    result.entityId = entityId;
    result.payloadJson = JSON.stringify(payload);
    result.contentHash = CloudSyncCoordinator.digest(result.payloadJson);
    result.localKey = localKey;
    return result;
  }

  private static identity(prefix: string, value: string): string {
    return `${prefix}_${CloudSyncCoordinator.digest(value)}`;
  }

  private static digest(value: string): string {
    const md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: new util.TextEncoder().encodeInto(value) });
    const data = md.digestSync().data;
    let result = '';
    for (const byte of data) {
      result += byte.toString(16).padStart(2, '0');
    }
    return result;
  }

  private static entityPriority(entityType: string): number {
    if (entityType === 'book_group') return 0;
    if (entityType === 'book_source') return 1;
    if (entityType === 'bookshelf_item') return 2;
    if (entityType === 'reading_progress') return 3;
    if (entityType === 'bookmark') return 4;
    if (entityType === 'reader_settings') return 5;
    if (entityType === 'replace_rule') return 6;
    if (entityType === 'theme_settings') return 7;
    if (entityType === 'appearance_mode') return 8;
    if (entityType === 'bookshelf_display') return 9;
    if (entityType === 'search_preferences') return 10;
    if (entityType === 'custom_theme_schemes') return 11;
    return 20;
  }

  private static scopeAllows(settings: CloudSyncSettings, entityType: string): boolean {
    if (entityType === 'book_source') {
      return settings.bookSourcesEnabled;
    }
    if (entityType === 'book_group' ||
      entityType === 'bookshelf_item' ||
      entityType === 'reading_progress' ||
      entityType === 'bookmark') {
      return settings.readingDataEnabled;
    }
    if (entityType === 'reader_settings' ||
      entityType === 'replace_rule' ||
      entityType === 'theme_settings') {
      return settings.readingPreferencesEnabled;
    }
    if (entityType === 'appearance_mode' ||
      entityType === 'bookshelf_display' ||
      entityType === 'search_preferences' ||
      entityType === 'custom_theme_schemes') {
      return settings.applicationPreferencesEnabled;
    }
    return false;
  }

  private static validateResponse(response: CloudSyncExchangeResponse): void {
    if (!response || response.protocolVersion !== 1 ||
      !Number.isSafeInteger(Number(response.nextCursor)) ||
      Number(response.nextCursor) < 0) {
      throw new Error('同步服务返回的数据格式异常');
    }
  }
}
