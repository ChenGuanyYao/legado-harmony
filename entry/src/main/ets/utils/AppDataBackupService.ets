import fs from '@ohos.file.fs';
import fileUri from '@ohos.file.fileuri';
import zlib from '@ohos.zlib';
import util from '@ohos.util';
import preferences from '@ohos.data.preferences';
import { Context } from '@kit.AbilityKit';
import { statfs } from '@kit.CoreFileKit';
import { AppDatabase } from '../model/data/AppDatabase';
import { Book, BookGroup, Bookmark, BookSource, ReadConfig, SearchKeyword } from '../model/data/Book';
import { LocalBookService } from '../core/book/LocalBookService';
import { BackupCrypto } from './BackupCrypto';

export class AppDataBackupSelection {
  sources: boolean = true;
  bookshelf: boolean = true;
  progress: boolean = true;
  bookmarks: boolean = true;
  localBooks: boolean = true;
  settings: boolean = true;
  searchHistory: boolean = false;
}

export class BookProgressBackup {
  bookUrl: string = '';
  durChapterTitle: string = '';
  durChapterIndex: number = 0;
  durChapterPos: number = 0;
  durChapterTime: number = 0;
  variable: string = '';
}

export class AppDataBackupManifest {
  format: string = 'legado-harmony-backup';
  version: number = 2;
  createdAt: number = 0;
  sensitiveDataExcluded: boolean = true;
  sourceFilesDir: string = '';
  categories: string[] = [];
  sources: BookSource[] = [];
  books: Book[] = [];
  bookGroups: BookGroup[] = [];
  progress: BookProgressBackup[] = [];
  bookmarks: Bookmark[] = [];
  localBooks: Book[] = [];
  localFiles: Record<string, string> = {};
  preferenceStores: Record<string, string> = {};
  sourceGroupPreferences: string = '';
  searchKeywords: SearchKeyword[] = [];
  bookshelfSortMode: string = 'recentRead';
}

export class AppDataBackupExportResult {
  archivePath: string = '';
  manifest: AppDataBackupManifest = new AppDataBackupManifest();
}

export class AppDataBackupImportSession {
  tempRootPath: string = '';
  rootPath: string = '';
  encrypted: boolean = false;
  manifest: AppDataBackupManifest = new AppDataBackupManifest();
}

export class AppDataBackupImportResult {
  sources: number = 0;
  books: number = 0;
  localBooks: number = 0;
  progress: number = 0;
  bookmarks: number = 0;
  settings: number = 0;
  searchKeywords: number = 0;

  summary(): string {
    const parts: string[] = [];
    if (this.sources > 0) parts.push(`书源 ${this.sources}`);
    if (this.books > 0) parts.push(`书架 ${this.books}`);
    if (this.localBooks > 0) parts.push(`本地图书 ${this.localBooks}`);
    if (this.progress > 0) parts.push(`进度 ${this.progress}`);
    if (this.bookmarks > 0) parts.push(`书签 ${this.bookmarks}`);
    if (this.settings > 0) parts.push(`设置 ${this.settings}`);
    if (this.searchKeywords > 0) parts.push(`搜索记录 ${this.searchKeywords}`);
    return parts.length > 0 ? parts.join('、') : '没有可导入的数据';
  }
}

export class AppDataBackupService {
  static readonly PASSWORD_REQUIRED_MESSAGE: string = '备份已加密，请输入密码';
  static readonly CATEGORY_SOURCES: string = 'sources';
  static readonly CATEGORY_BOOKSHELF: string = 'bookshelf';
  static readonly CATEGORY_PROGRESS: string = 'progress';
  static readonly CATEGORY_BOOKMARKS: string = 'bookmarks';
  static readonly CATEGORY_LOCAL_BOOKS: string = 'localBooks';
  static readonly CATEGORY_SETTINGS: string = 'settings';
  static readonly CATEGORY_SEARCH_HISTORY: string = 'searchHistory';

  private static readonly SETTINGS_STORES: string[] = [
    'app_icon_settings',
    'app_theme_mode',
    'app_theme_settings',
    'bookshelf_display_settings',
    'cover_gallery_settings',
    'glass_settings',
    'reader_replace_rules',
    'reader_settings',
    'search_explore_settings',
    'startup_cover_texts',
    'tts_settings'
  ];

  private static readonly ASSET_DIRS: string[] = [
    'reader_fonts',
    'reader_backgrounds',
    'theme_startups',
    'cover_albums',
    'covers'
  ];

  private static readonly PROGRESS_VARIABLE_KEYS: string[] = [
    'readStarted',
    'lastReadTime',
    'readProgressChapterIndex',
    'readProgressPageCount'
  ];

  static async createBackup(context: Context, selection: AppDataBackupSelection,
    password: string, onProgress?: (message: string, percent: number) => void):
    Promise<AppDataBackupExportResult> {
    if ((password || '').length < 8) throw new Error('备份密码至少需要 8 个字符');
    AppDataBackupService.reportProgress(onProgress, '正在读取应用数据...', 3);
    const db = AppDatabase.getInstance();
    await db.initWithContext(context);
    const root = `${context.tempDir}/app_backup_${Date.now()}`;
    const payloadRoot = `${root}/payload`;
    const innerArchivePath = `${root}/payload.zip`;
    const envelopeRoot = `${root}/encrypted`;
    const encryptedPayloadPath = `${envelopeRoot}/payload.bin`;
    // zlib.compressFile() produces a ZIP archive and requires a ZIP output
    // path on some HarmonyOS versions. The user-facing picker can still save
    // these bytes with the custom .qingyebak extension.
    const archivePath = `${root}/legado_backup.zip`;
    const manifest = new AppDataBackupManifest();
    manifest.createdAt = Date.now();
    manifest.sourceFilesDir = context.filesDir;
    let archiveReady = false;
    try {

    if (selection.sources) {
      manifest.categories.push(AppDataBackupService.CATEGORY_SOURCES);
      manifest.sources = (await db.getAllBookSources()).map((source: BookSource): BookSource =>
        AppDataBackupService.sanitizeBookSource(source));
      manifest.sourceGroupPreferences = await AppDataBackupService.readPreferenceStore(context, 'book_source_groups');
    }

    const allBooks = await db.getAllBooks();
    AppDataBackupService.reportProgress(onProgress, '正在检查可用空间...', 8);
    await AppDataBackupService.ensureEnoughTempSpace(context, selection, allBooks);
    await AppDataBackupService.ensureDir(payloadRoot);
    await AppDataBackupService.ensureDir(envelopeRoot);
    if (selection.bookshelf || selection.localBooks) {
      manifest.bookGroups = await db.getCustomBookGroups();
    }
    if (selection.bookshelf) {
      manifest.categories.push(AppDataBackupService.CATEGORY_BOOKSHELF);
      manifest.books = allBooks.filter((book: Book): boolean => !LocalBookService.isLocalBook(book))
        .map((book: Book): Book => AppDataBackupService.sanitizeBook(book));
      manifest.bookshelfSortMode = AppStorage.get<string>('bookshelfSortMode') || 'recentRead';
    }

    if (selection.progress) {
      manifest.categories.push(AppDataBackupService.CATEGORY_PROGRESS);
      manifest.progress = allBooks.map((book: Book): BookProgressBackup => {
        const progress = new BookProgressBackup();
        progress.bookUrl = book.bookUrl;
        progress.durChapterTitle = book.durChapterTitle;
        progress.durChapterIndex = book.durChapterIndex;
        progress.durChapterPos = book.durChapterPos;
        progress.durChapterTime = book.durChapterTime;
        progress.variable = AppDataBackupService.progressVariables(book);
        return progress;
      });
    }

    if (selection.bookmarks) {
      manifest.categories.push(AppDataBackupService.CATEGORY_BOOKMARKS);
      manifest.bookmarks = await db.getAllBookmarks();
    }

    if (selection.localBooks) {
      AppDataBackupService.reportProgress(onProgress, '正在整理本地图书...', 22);
      manifest.categories.push(AppDataBackupService.CATEGORY_LOCAL_BOOKS);
      const localSourceBooks = allBooks.filter((book: Book): boolean => LocalBookService.isLocalBook(book));
      manifest.localBooks = localSourceBooks
        .map((book: Book): Book => AppDataBackupService.sanitizeBook(book));
      const localRoot = `${payloadRoot}/local_books`;
      await AppDataBackupService.ensureDir(localRoot);
      for (let index = 0; index < manifest.localBooks.length; index++) {
        const book = localSourceBooks[index];
        const sourcePath = book.getVariable('localFilePath');
        if (!sourcePath || !AppDataBackupService.exists(sourcePath)) continue;
        const format = book.getVariable('localFormat') || (book.type === LocalBookService.TYPE_EPUB ? 'epub' : 'txt');
        const archiveName = `${index}.${format}`;
        await AppDataBackupService.copyFile(sourcePath, `${localRoot}/${archiveName}`);
        manifest.localFiles[book.bookUrl] = archiveName;
        const progress = manifest.localBooks.length > 0 ?
          22 + Math.floor((index + 1) * 13 / manifest.localBooks.length) : 35;
        AppDataBackupService.reportProgress(onProgress, '正在整理本地图书...', progress);
      }
    }

    if (selection.settings) {
      AppDataBackupService.reportProgress(onProgress, '正在整理设置和自定义资源...', 36);
      manifest.categories.push(AppDataBackupService.CATEGORY_SETTINGS);
      for (const storeName of AppDataBackupService.SETTINGS_STORES) {
        manifest.preferenceStores[storeName] = AppDataBackupService.sanitizeStructuredText(
          await AppDataBackupService.readPreferenceStore(context, storeName));
      }
      const assetsRoot = `${payloadRoot}/assets`;
      for (let index = 0; index < AppDataBackupService.ASSET_DIRS.length; index++) {
        const dirName = AppDataBackupService.ASSET_DIRS[index];
        const source = `${context.filesDir}/${dirName}`;
        if (AppDataBackupService.exists(source)) {
          await AppDataBackupService.copyDirectory(source, `${assetsRoot}/${dirName}`);
        }
        AppDataBackupService.reportProgress(onProgress, '正在整理设置和自定义资源...',
          36 + Math.floor((index + 1) * 9 / AppDataBackupService.ASSET_DIRS.length));
      }
    }

    if (selection.searchHistory) {
      manifest.categories.push(AppDataBackupService.CATEGORY_SEARCH_HISTORY);
      manifest.searchKeywords = await db.getSearchKeywords();
    }

      AppDataBackupService.reportProgress(onProgress, '正在生成备份清单...', 48);
      await AppDataBackupService.writeText(`${payloadRoot}/manifest.json`, JSON.stringify(manifest));
      AppDataBackupService.reportProgress(onProgress, '正在压缩备份数据...', 52);
      try {
        await zlib.compressFile(payloadRoot, innerArchivePath,
          { level: zlib.CompressLevel.COMPRESS_LEVEL_BEST_SPEED });
      } catch (error) {
        throw new Error(`压缩备份数据失败：${error instanceof Error ? error.message : String(error)}`);
      }
      await AppDataBackupService.removeDirectory(payloadRoot);
      AppDataBackupService.reportProgress(onProgress, '正在加密备份...', 68);
      const encryption = await BackupCrypto.encryptFile(innerArchivePath, encryptedPayloadPath, password,
        (processed: number, total: number): void => {
          const ratio = total > 0 ? processed / total : 1;
          AppDataBackupService.reportProgress(onProgress, '正在加密备份...',
            68 + Math.min(17, Math.floor(ratio * 17)));
        });
      AppDataBackupService.reportProgress(onProgress, '加密完成，正在清理中间文件...', 86);
      await AppDataBackupService.removeFile(innerArchivePath);
      await AppDataBackupService.writeText(`${envelopeRoot}/encryption.json`, JSON.stringify(encryption));
      AppDataBackupService.reportProgress(onProgress, '正在封装备份文件...', 88);
      try {
        await zlib.compressFile(envelopeRoot, archivePath,
          { level: zlib.CompressLevel.COMPRESS_LEVEL_NO_COMPRESSION });
        const archiveStat = await fs.stat(archivePath);
        if (archiveStat.size <= 0) throw new Error('生成的归档文件为空');
      } catch (error) {
        throw new Error(`封装备份文件失败：${error instanceof Error ? error.message : String(error)}`);
      }
      await AppDataBackupService.removeDirectory(envelopeRoot);
      archiveReady = true;
      AppDataBackupService.reportProgress(onProgress, '备份文件已生成', 96);
    } finally {
      await AppDataBackupService.removeDirectory(payloadRoot);
      await AppDataBackupService.removeFile(innerArchivePath);
      await AppDataBackupService.removeDirectory(envelopeRoot);
      if (!archiveReady) await AppDataBackupService.removeFile(archivePath);
    }
    const result = new AppDataBackupExportResult();
    result.archivePath = archivePath;
    result.manifest = manifest;
    return result;
  }

  static async cleanupStaleTempFiles(context: Context): Promise<void> {
    const staleBeforeSeconds = Math.floor(Date.now() / 1000) - 24 * 60 * 60;
    let names: string[] = [];
    try {
      names = await fs.listFile(context.tempDir);
    } catch (_) {
      return;
    }
    for (const name of names) {
      if (!name.startsWith('app_backup_')) continue;
      const path = `${context.tempDir}/${name}`;
      try {
        const stat = await fs.stat(path);
        // A system picker can temporarily background and recreate the page.
        // Keep active/recent exports; only remove leftovers older than one day.
        if (stat.mtime >= staleBeforeSeconds) continue;
        if (stat.isDirectory()) await AppDataBackupService.removeDirectory(path);
        else await AppDataBackupService.removeFile(path);
      } catch (_) {}
    }
  }

  static async prepareImport(context: Context, sourceUri: string, password: string = '',
    onProgress?: (message: string, percent: number) => void): Promise<AppDataBackupImportSession> {
    const root = `${context.tempDir}/app_backup_import_${Date.now()}`;
    const archivePath = `${root}/source.zip`;
    const outRoot = `${root}/out`;
    AppDataBackupService.reportProgress(onProgress, '正在准备导入空间...', 3);
    await AppDataBackupService.ensureDir(root);
    await AppDataBackupService.ensureDir(outRoot);
    try {
      AppDataBackupService.reportProgress(onProgress, '正在复制备份文件...', 8);
      await AppDataBackupService.copyFile(sourceUri, archivePath);
      AppDataBackupService.reportProgress(onProgress, '正在解包备份文件...', 20);
      await zlib.decompressFile(archivePath, outRoot);
      AppDataBackupService.reportProgress(onProgress, '正在检查备份结构...', 42);
      const encryptionPath = await AppDataBackupService.findFile(outRoot, 'encryption.json');
      let manifestSearchRoot = outRoot;
      if (encryptionPath) {
        if (!password) throw new Error(AppDataBackupService.PASSWORD_REQUIRED_MESSAGE);
        AppDataBackupService.reportProgress(onProgress, '正在校验备份密码...', 46);
        const metadata = BackupCrypto.parseMetadata(await AppDataBackupService.readText(encryptionPath));
        const envelopeRoot = AppDataBackupService.parentPath(encryptionPath);
        const encryptedPayload = `${envelopeRoot}/${metadata.payloadFile}`;
        if (!AppDataBackupService.exists(encryptedPayload)) throw new Error('加密备份载荷不存在');
        const decryptedArchive = `${root}/decrypted.zip`;
        const decryptedRoot = `${root}/decrypted`;
        await AppDataBackupService.ensureDir(decryptedRoot);
        await BackupCrypto.decryptFile(encryptedPayload, decryptedArchive, password, metadata,
          (processed: number, total: number): void => {
            const ratio = total > 0 ? processed / total : 1;
            AppDataBackupService.reportProgress(onProgress, '正在解密备份数据...',
              48 + Math.min(30, Math.floor(ratio * 30)));
          });
        try {
          AppDataBackupService.reportProgress(onProgress, '正在解包应用数据...', 80);
          await zlib.decompressFile(decryptedArchive, decryptedRoot);
          AppDataBackupService.reportProgress(onProgress, '应用数据解包完成', 94);
        } finally {
          await AppDataBackupService.removeFile(decryptedArchive);
        }
        manifestSearchRoot = decryptedRoot;
      } else {
        AppDataBackupService.reportProgress(onProgress, '备份数据解包完成', 90);
      }
      AppDataBackupService.reportProgress(onProgress, '正在读取备份清单...', 96);
      const manifestPath = await AppDataBackupService.findFile(manifestSearchRoot, 'manifest.json');
      if (!manifestPath) throw new Error('不是有效的 Legado Harmony 备份文件');
      const raw = await AppDataBackupService.readText(manifestPath);
      const manifest = JSON.parse(raw) as AppDataBackupManifest;
      if (manifest.format !== 'legado-harmony-backup' ||
        (manifest.version !== 1 && manifest.version !== 2)) {
        throw new Error('备份格式不支持或版本过新');
      }
      const session = new AppDataBackupImportSession();
      session.tempRootPath = root;
      session.rootPath = AppDataBackupService.parentPath(manifestPath);
      session.encrypted = !!encryptionPath;
      session.manifest = manifest;
      AppDataBackupService.reportProgress(onProgress, '备份文件读取完成', 100);
      return session;
    } catch (error) {
      await AppDataBackupService.removeDirectory(root);
      throw new Error(error instanceof Error ? error.message : String(error));
    }
  }

  static async discardExport(archivePath: string): Promise<void> {
    if (!archivePath) return;
    await AppDataBackupService.removeDirectory(AppDataBackupService.parentPath(archivePath));
  }

  static async discardImport(session: AppDataBackupImportSession | null): Promise<void> {
    if (!session || !session.tempRootPath) return;
    await AppDataBackupService.removeDirectory(session.tempRootPath);
    session.tempRootPath = '';
  }

  static async importBackup(context: Context, session: AppDataBackupImportSession,
    selection: AppDataBackupSelection): Promise<AppDataBackupImportResult> {
    const db = AppDatabase.getInstance();
    await db.initWithContext(context);
    const manifest = session.manifest;
    const result = new AppDataBackupImportResult();

    if ((selection.bookshelf || selection.localBooks) && (manifest.bookGroups || []).length > 0) {
      for (const group of manifest.bookGroups) {
        await db.restoreBookGroup(group);
      }
    }

    if (selection.sources && AppDataBackupService.hasCategory(manifest, AppDataBackupService.CATEGORY_SOURCES)) {
      for (const raw of manifest.sources || []) {
        await db.restoreBookSource(raw);
        result.sources++;
      }
      if (manifest.sourceGroupPreferences) {
        await AppDataBackupService.restorePreferenceStore(context, 'book_source_groups',
          manifest.sourceGroupPreferences, manifest.sourceFilesDir);
      }
    }

    if (selection.bookshelf && AppDataBackupService.hasCategory(manifest, AppDataBackupService.CATEGORY_BOOKSHELF)) {
      for (const raw of manifest.books || []) {
        const book = AppDataBackupService.hydrateBook(raw, manifest.sourceFilesDir, context.filesDir);
        await AppDataBackupService.restoreBookWithoutUnexpectedProgress(db, book, selection.progress);
        result.books++;
      }
      AppStorage.setOrCreate('bookshelfSortMode', manifest.bookshelfSortMode || 'recentRead');
    }

    if (selection.localBooks && AppDataBackupService.hasCategory(manifest, AppDataBackupService.CATEGORY_LOCAL_BOOKS)) {
      const targetRoot = `${context.filesDir}/local_books`;
      await AppDataBackupService.ensureDir(targetRoot);
      for (const raw of manifest.localBooks || []) {
        const archiveName = (manifest.localFiles || {})[raw.bookUrl] || '';
        const archivePath = archiveName ? `${session.rootPath}/local_books/${archiveName}` : '';
        if (!archivePath || !AppDataBackupService.exists(archivePath)) continue;
        const book = AppDataBackupService.hydrateBook(raw, manifest.sourceFilesDir, context.filesDir);
        const id = book.bookUrl.startsWith('local://') ? book.bookUrl.substring('local://'.length) :
          `${Math.abs(AppDataBackupService.hashText(book.bookUrl))}`;
        const format = book.getVariable('localFormat') || (book.type === LocalBookService.TYPE_EPUB ? 'epub' : 'txt');
        const targetPath = `${targetRoot}/${id}.${format}`;
        await AppDataBackupService.copyFile(archivePath, targetPath);
        book.putVariable('localFilePath', targetPath);
        book.putVariable('localSourceUri', fileUri.getUriFromPath(targetPath));
        book.putVariable('localExtractRoot', '');
        book.putVariable('localParserVersion', '');
        await AppDataBackupService.restoreBookWithoutUnexpectedProgress(db, book, selection.progress);
        await LocalBookService.ensureLocalParserCurrent(context, book);
        result.localBooks++;
      }
    }

    if (selection.progress && AppDataBackupService.hasCategory(manifest, AppDataBackupService.CATEGORY_PROGRESS)) {
      for (const progress of manifest.progress || []) {
        const book = await db.getBook(progress.bookUrl);
        if (!book) continue;
        book.durChapterTitle = progress.durChapterTitle;
        book.durChapterIndex = progress.durChapterIndex;
        book.durChapterPos = progress.durChapterPos;
        book.durChapterTime = progress.durChapterTime;
        AppDataBackupService.applyProgressVariables(book, progress.variable);
        await db.updateBook(book);
        result.progress++;
      }
    }

    if (selection.bookmarks && AppDataBackupService.hasCategory(manifest, AppDataBackupService.CATEGORY_BOOKMARKS)) {
      for (const bookmark of manifest.bookmarks || []) {
        if (!await db.getBook(bookmark.bookUrl)) continue;
        await db.restoreBookmark(bookmark);
        result.bookmarks++;
      }
    }

    if (selection.settings && AppDataBackupService.hasCategory(manifest, AppDataBackupService.CATEGORY_SETTINGS)) {
      const assetsRoot = `${session.rootPath}/assets`;
      for (const dirName of AppDataBackupService.ASSET_DIRS) {
        const source = `${assetsRoot}/${dirName}`;
        if (AppDataBackupService.exists(source)) {
          await AppDataBackupService.copyDirectory(source, `${context.filesDir}/${dirName}`);
        }
      }
      const stores = manifest.preferenceStores || {};
      for (const storeName of Object.keys(stores)) {
        await AppDataBackupService.restorePreferenceStore(context, storeName, stores[storeName],
          manifest.sourceFilesDir);
        result.settings++;
      }
    }

    if (selection.searchHistory &&
      AppDataBackupService.hasCategory(manifest, AppDataBackupService.CATEGORY_SEARCH_HISTORY)) {
      for (const keyword of manifest.searchKeywords || []) {
        await db.restoreSearchKeyword(keyword);
        result.searchKeywords++;
      }
    }

    AppStorage.setOrCreate('shelfUpdateTime', Date.now());
    return result;
  }

  static hasCategory(manifest: AppDataBackupManifest, category: string): boolean {
    return (manifest.categories || []).includes(category);
  }

  private static async restoreBookWithoutUnexpectedProgress(db: AppDatabase, book: Book,
    importProgress: boolean): Promise<void> {
    if (!importProgress) {
      const existing = await db.getBook(book.bookUrl);
      AppDataBackupService.stripProgressVariables(book);
      if (existing) {
        book.durChapterTitle = existing.durChapterTitle;
        book.durChapterIndex = existing.durChapterIndex;
        book.durChapterPos = existing.durChapterPos;
        book.durChapterTime = existing.durChapterTime;
        AppDataBackupService.applyProgressVariables(book, AppDataBackupService.progressVariables(existing));
      } else {
        book.durChapterTitle = '';
        book.durChapterIndex = 0;
        book.durChapterPos = 0;
        book.durChapterTime = 0;
      }
    }
    await db.restoreBook(book);
  }

  private static hydrateBook(raw: Book, oldRoot: string, newRoot: string): Book {
    const book = new Book();
    book.bookUrl = raw.bookUrl || '';
    book.tocUrl = raw.tocUrl || '';
    book.origin = raw.origin || 'local';
    book.originName = raw.originName || '';
    book.name = raw.name || '';
    book.author = raw.author || '';
    book.kind = raw.kind || '';
    book.customTag = raw.customTag || '';
    book.coverUrl = AppDataBackupService.replaceRoot(raw.coverUrl || '', oldRoot, newRoot);
    book.customCoverUrl = AppDataBackupService.replaceRoot(raw.customCoverUrl || '', oldRoot, newRoot);
    book.intro = raw.intro || '';
    book.customIntro = raw.customIntro || '';
    book.charset = raw.charset || '';
    book.type = raw.type || 0;
    book.group = raw.group || 0;
    book.latestChapterTitle = raw.latestChapterTitle || '';
    book.latestChapterTime = raw.latestChapterTime || 0;
    book.lastCheckTime = raw.lastCheckTime || 0;
    book.lastCheckCount = raw.lastCheckCount || 0;
    book.totalChapterNum = raw.totalChapterNum || 0;
    book.durChapterTitle = raw.durChapterTitle || '';
    book.durChapterIndex = raw.durChapterIndex || 0;
    book.durChapterPos = raw.durChapterPos || 0;
    book.durChapterTime = raw.durChapterTime || 0;
    book.wordCount = raw.wordCount || '';
    book.canUpdate = raw.canUpdate !== false;
    book.order = raw.order || 0;
    book.originOrder = raw.originOrder || 0;
    book.replaceVariable(AppDataBackupService.replaceRoot(raw.variable || '{}', oldRoot, newRoot));
    if (raw.readConfig) {
      book.readConfig = JSON.parse(JSON.stringify(raw.readConfig)) as ReadConfig;
    }
    book.syncTime = raw.syncTime || 0;
    return book;
  }

  private static async readPreferenceStore(context: Context, storeName: string): Promise<string> {
    const store = await preferences.getPreferences(context, storeName);
    return JSON.stringify(await store.getAll());
  }

  private static sanitizeBookSource(source: BookSource): BookSource {
    const value = JSON.parse(JSON.stringify(source)) as BookSource;
    // Source definitions contain legitimate script identifiers such as `${token}` and URL
    // parameters named token/password. Generic text redaction corrupts those programs. Only
    // remove user-specific runtime credentials; keep imported definitions and unknown fields.
    value.loginHeader = '';
    value.loginInfo = '';
    value.rawSourceJson = AppDataBackupService.sanitizeRawBookSourceJson(value.rawSourceJson || '');
    return value;
  }

  private static sanitizeRawBookSourceJson(raw: string): string {
    if (!(raw || '').trim()) return '';
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return raw;
      const clean: Record<string, Object> = {};
      for (const key of Object.keys(parsed)) {
        if (key !== 'loginHeader' && key !== 'loginInfo') clean[key] = parsed[key];
      }
      return JSON.stringify(clean);
    } catch (_) {
      return raw;
    }
  }

  private static sanitizeBook(source: Book): Book {
    const book = JSON.parse(JSON.stringify(source)) as Book;
    book.variable = AppDataBackupService.sanitizeStructuredText(book.variable || '{}');
    return book;
  }

  private static sanitizeStructuredText(raw: string): string {
    const value = (raw || '').trim();
    if (!value) return raw || '';
    try {
      const parsed = JSON.parse(value) as Object;
      return JSON.stringify(AppDataBackupService.sanitizeValue(parsed));
    } catch (_) {
      return AppDataBackupService.redactSensitiveText(raw);
    }
  }

  private static sanitizeValue(value: Object): Object {
    if (typeof value === 'string') {
      const text = value.trim();
      if ((text.startsWith('{') && text.endsWith('}')) ||
        (text.startsWith('[') && text.endsWith(']'))) {
        try {
          return JSON.stringify(AppDataBackupService.sanitizeValue(JSON.parse(text) as Object));
        } catch (_) {}
      }
      return AppDataBackupService.redactSensitiveText(value);
    }
    if (Array.isArray(value)) {
      const result: Object[] = [];
      for (const item of value as Object[]) result.push(AppDataBackupService.sanitizeValue(item));
      return result;
    }
    if (value !== null && typeof value === 'object') {
      const source = value as Record<string, Object>;
      const result: Record<string, Object> = {};
      for (const key of Object.keys(source)) {
        result[key] = AppDataBackupService.isSensitiveKey(key) ? '' :
          AppDataBackupService.sanitizeValue(source[key]);
      }
      return result;
    }
    return value;
  }

  private static isSensitiveKey(key: string): boolean {
    const normalized = (key || '').toLowerCase().replace(/[_\-\s]/g, '');
    return normalized.includes('cookie') ||
      normalized.includes('密码') ||
      normalized.includes('password') ||
      normalized.includes('passwd') ||
      normalized.includes('credential') ||
      normalized === 'pwd' ||
      normalized.includes('token') ||
      normalized.includes('authorization') ||
      normalized.includes('loginheader') ||
      normalized.includes('secret') ||
      normalized.includes('apikey') ||
      normalized.includes('accesskey') ||
      normalized.includes('sessionid');
  }

  private static redactSensitiveText(raw: string): string {
    return (raw || '')
      .replace(/(^|\r?\n)\s*(cookie|authorization|proxy-authorization|x-api-key|x-access-token)\s*:[^\r\n]*/gi,
        '$1')
      .replace(/([?&](?:access_?token|refresh_?token|token|password|passwd|pwd|api_?key|secret|session_?id)=)[^&#\s"'\\]+/gi,
        '$1[removed]')
      .replace(/((?:cookie|authorization|access_?token|refresh_?token|token|password|passwd|pwd|api_?key|secret)\s*[:=]\s*["'])[^"'\r\n]*(["'])/gi,
        '$1[removed]$2');
  }

  private static async restorePreferenceStore(context: Context, storeName: string, raw: string,
    oldRoot: string): Promise<void> {
    const store = await preferences.getPreferences(context, storeName);
    const values = JSON.parse(AppDataBackupService.replaceRoot(raw || '{}', oldRoot, context.filesDir)) as
      Record<string, preferences.ValueType>;
    await store.clear();
    for (const key of Object.keys(values)) {
      await store.put(key, values[key]);
    }
    await store.flush();
  }

  private static replaceRoot(value: string, oldRoot: string, newRoot: string): string {
    if (!value || !oldRoot || oldRoot === newRoot) return value;
    return value.split(oldRoot).join(newRoot);
  }

  private static progressVariables(book: Book): string {
    const values: Record<string, string> = {};
    for (const key of AppDataBackupService.PROGRESS_VARIABLE_KEYS) {
      const value = book.getVariable(key);
      if (value) values[key] = value;
    }
    return JSON.stringify(values);
  }

  private static applyProgressVariables(book: Book, raw: string): void {
    let values: Record<string, string> = {};
    try {
      values = JSON.parse(raw || '{}') as Record<string, string>;
    } catch (_) {
      return;
    }
    for (const key of AppDataBackupService.PROGRESS_VARIABLE_KEYS) {
      const value = values[key];
      if (value !== undefined) book.putVariable(key, `${value}`);
    }
  }

  private static stripProgressVariables(book: Book): void {
    let source: Record<string, string> = {};
    try {
      source = JSON.parse(book.variable || '{}') as Record<string, string>;
    } catch (_) {
      source = {};
    }
    const clean: Record<string, string> = {};
    for (const key of Object.keys(source)) {
      if (!AppDataBackupService.PROGRESS_VARIABLE_KEYS.includes(key)) clean[key] = source[key];
    }
    book.replaceVariable(JSON.stringify(clean));
  }

  private static reportProgress(onProgress: ((message: string, percent: number) => void) | undefined,
    message: string, percent: number): void {
    if (onProgress) onProgress(message, Math.max(0, Math.min(100, percent)));
  }

  private static async ensureEnoughTempSpace(context: Context, selection: AppDataBackupSelection,
    allBooks: Book[]): Promise<void> {
    let sourceBytes = 0;
    const countedPaths: string[] = [];
    if (selection.localBooks) {
      for (const book of allBooks) {
        if (!LocalBookService.isLocalBook(book)) continue;
        const path = book.getVariable('localFilePath');
        if (!path || countedPaths.includes(path) || !AppDataBackupService.exists(path)) continue;
        countedPaths.push(path);
        sourceBytes += await AppDataBackupService.pathSize(path);
      }
    }
    if (selection.settings) {
      for (const dirName of AppDataBackupService.ASSET_DIRS) {
        const path = `${context.filesDir}/${dirName}`;
        if (AppDataBackupService.exists(path)) sourceBytes += await AppDataBackupService.pathSize(path);
      }
    }

    const reserve = 32 * 1024 * 1024;
    const minimum = 64 * 1024 * 1024;
    const required = Math.max(minimum, Math.ceil(sourceBytes * 2.25) + reserve);
    let free = 0;
    try {
      free = await statfs.getFreeSize(context.tempDir);
    } catch (error) {
      console.warn('读取备份临时空间失败，将继续备份:', error);
      return;
    }
    if (free < required) {
      throw new Error(`存储空间不足：预计需要 ${AppDataBackupService.formatBytes(required)} 临时空间，` +
        `当前可用 ${AppDataBackupService.formatBytes(free)}`);
    }
  }

  private static async pathSize(path: string): Promise<number> {
    const stat = await fs.stat(path);
    if (!stat.isDirectory()) return stat.size;
    let size = 0;
    const names = await fs.listFile(path);
    for (const name of names) size += await AppDataBackupService.pathSize(`${path}/${name}`);
    return size;
  }

  private static formatBytes(bytes: number): string {
    if (bytes >= 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`;
    return `${Math.max(1, Math.ceil(bytes / (1024 * 1024)))} MB`;
  }

  private static async copyDirectory(source: string, target: string): Promise<void> {
    await AppDataBackupService.ensureDir(target);
    const names = await fs.listFile(source);
    for (const name of names) {
      const sourcePath = `${source}/${name}`;
      const targetPath = `${target}/${name}`;
      const stat = await fs.stat(sourcePath);
      if (stat.isDirectory()) {
        await AppDataBackupService.copyDirectory(sourcePath, targetPath);
      } else {
        await AppDataBackupService.copyFile(sourcePath, targetPath);
      }
    }
  }

  private static async copyFile(source: string, target: string): Promise<void> {
    await AppDataBackupService.ensureDir(AppDataBackupService.parentPath(target));
    let sourceFile: fs.File | null = null;
    let targetFile: fs.File | null = null;
    try {
      sourceFile = await fs.open(source, fs.OpenMode.READ_ONLY);
      targetFile = await fs.open(target,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      await fs.copyFile(sourceFile.fd, targetFile.fd);
    } finally {
      if (sourceFile) {
        try { await fs.close(sourceFile); } catch (_) {}
      }
      if (targetFile) {
        try { await fs.close(targetFile); } catch (_) {}
      }
    }
  }

  private static async removeDirectory(path: string): Promise<void> {
    if (!AppDataBackupService.exists(path)) return;
    const names = await fs.listFile(path);
    for (const name of names) {
      const child = `${path}/${name}`;
      const stat = await fs.stat(child);
      if (stat.isDirectory()) {
        await AppDataBackupService.removeDirectory(child);
      } else {
        await AppDataBackupService.removeFile(child);
      }
    }
    try { await fs.rmdir(path); } catch (_) {}
  }

  private static async removeFile(path: string): Promise<void> {
    try {
      if (AppDataBackupService.exists(path)) await fs.unlink(path);
    } catch (_) {}
  }

  private static async writeText(path: string, value: string): Promise<void> {
    const bytes = new util.TextEncoder().encodeInto(value);
    const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      await fs.write(file.fd, bytes.buffer, { offset: 0, length: bytes.byteLength });
    } finally {
      await fs.close(file);
    }
  }

  private static async readText(path: string): Promise<string> {
    const stat = await fs.stat(path);
    const file = await fs.open(path, fs.OpenMode.READ_ONLY);
    try {
      const buffer = new ArrayBuffer(stat.size);
      await fs.read(file.fd, buffer, { offset: 0, length: stat.size });
      return util.TextDecoder.create('utf-8').decodeWithStream(new Uint8Array(buffer), { stream: false });
    } finally {
      await fs.close(file);
    }
  }

  private static async findFile(root: string, fileName: string): Promise<string> {
    const names = await fs.listFile(root);
    for (const name of names) {
      const path = `${root}/${name}`;
      const stat = await fs.stat(path);
      if (stat.isDirectory()) {
        const nested = await AppDataBackupService.findFile(path, fileName);
        if (nested) return nested;
      } else if (name === fileName) {
        return path;
      }
    }
    return '';
  }

  private static async ensureDir(path: string): Promise<void> {
    try { await fs.mkdir(path, true); } catch (_) {}
  }

  private static parentPath(path: string): string {
    const normalized = path.replace(/\\/g, '/');
    const index = normalized.lastIndexOf('/');
    return index > 0 ? normalized.substring(0, index) : normalized;
  }

  private static exists(path: string): boolean {
    try { return fs.accessSync(path); } catch (_) { return false; }
  }

  private static hashText(value: string): number {
    let hash = 0;
    for (let i = 0; i < value.length; i++) hash = (hash * 31 + value.charCodeAt(i)) | 0;
    return hash;
  }
}
