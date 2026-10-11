import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { syncSystemBars } from '../utils/SystemBars';
import { AppDatabase } from '../model/data/AppDatabase';
import { Book } from '../model/data/Book';
import { CoverAlbum, CoverGallerySettings } from '../utils/CoverGallerySettings';
import { CoverGalleryStore, CoverGallerySnapshot } from '../utils/CoverGalleryStore';
import { RecentReadCardUpdater } from '../utils/RecentReadCardUpdater';
import { ImmersiveBackButton } from '../components/ImmersiveBackButton';
import { BookshelfDisplaySettings, BookshelfDisplaySettingsStore } from '../utils/BookshelfDisplaySettingsStore';
import { SearchExplorePendingBook } from '../utils/SearchExplorePendingBook';
import { ThemeRuntime } from '../theme/ThemeRuntime';
import { ImmersiveMaterialRuntime } from '../utils/ImmersiveMaterialRuntime';
import { PrivateShelfStore } from '../utils/PrivateShelfStore';
import { SystemDialogSession } from '../utils/SystemDialogSession';
import { HdsFeedback } from '../utils/HdsFeedback';
import { LocalBookService } from '../core/book/LocalBookService';
import { BookDisplayHelper } from '../utils/BookDisplayHelper';
import { BookCoverCache } from '../utils/BookCoverCache';
import { AdaptiveSwitch } from '../components/AdaptiveSwitch';

@Entry
@Component
struct BookshelfSettingsPage {
  @StorageLink('bookshelfShowTags') bookshelfShowTags: boolean = true;
  @StorageLink('bookshelfShowSource') bookshelfShowSource: boolean = true;
  @StorageLink('bookshelfShowIntro') bookshelfShowIntro: boolean = true;
  @StorageLink('bookshelfShowFullIntro') bookshelfShowFullIntro: boolean = false;
  @StorageLink('bookshelfShowProgressBar') bookshelfShowProgressBar: boolean = false;
  @StorageLink('bookshelfShowLastReadTime') bookshelfShowLastReadTime: boolean = true;
  @StorageLink('bookshelfShowLastReadChapter') bookshelfShowLastReadChapter: boolean = false;
  @StorageLink('bookshelfShowTypeBadge') bookshelfShowTypeBadge: boolean = true;
  @StorageLink('bookshelfLayoutMode') bookshelfLayoutMode: string = 'compact';
  @StorageLink('bookshelfLastReadLeafMode') bookshelfLastReadLeafMode: string = 'adaptive';
  @StorageLink('bookshelfBookOpenAnimation') bookshelfBookOpenAnimation: boolean = true;
  @StorageLink('bookshelfCoverAlbums') @Watch('onCoverAlbumsChanged') bookshelfCoverAlbums: string = '';
  @StorageLink('bookshelfLightCoverAlbumId') bookshelfLightCoverAlbumId: string = '';
  @StorageLink('bookshelfDarkCoverAlbumId') bookshelfDarkCoverAlbumId: string = '';
  @StorageLink('bookshelfCoverApplyScope') bookshelfCoverApplyScope: string = 'all';
  @StorageLink('bookshelfCoverTargetBooks') bookshelfCoverTargetBooks: string = '';
  @StorageLink('bookshelfIgnoreSourceCover') bookshelfIgnoreSourceCover: boolean = false;
  @StorageLink('bookshelfCoverMode') bookshelfCoverMode: string = 'sequence';
  @StorageLink('coverGalleryUpdateTime') @Watch('onCoverGalleryUpdateTimeChanged') coverGalleryUpdateTime: number = 0;
  @StorageLink('appDarkMode') appDarkMode: boolean = false;
  @StorageLink('themeRevision') themeRevision: number = 0;
  @StorageLink('appLightButtonColor') appLightButtonColor: string = '#007DFF';
  @StorageLink('appDarkButtonColor') appDarkButtonColor: string = '#3F8CFF';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;

  @State albums: CoverAlbum[] = [];
  @State albumSelectOptions: SelectOption[] = [{ value: '不使用图集' }];
  @State books: Book[] = [];
  @State targetBookUrls: string[] = [];
  @State targetBooksLoading: boolean = false;
  @State showTargetBookList: boolean = false;
  @State settingsRenderTick: number = 0;
  @StorageLink('privateShelfEnabled') @Watch('onPrivateShelfEnabledChanged') privateShelfEnabled: boolean = false;
  @StorageLink('privateShelfHasPassword') privateShelfHasPassword: boolean = false;
  // 开关的显示值。关闭需要先验证密码，验证期间它与真实状态可以暂时不一致。
  @State privateShelfSwitchOn: boolean = false;
  // 'disable'：关闭隐私书架前验证密码；'password'：设置、修改或清除密码。
  @State privatePasswordDialogMode: string = 'password';
  @State privatePasswordCurrent: string = '';
  @State privatePasswordNew: string = '';
  @State privatePasswordConfirm: string = '';
  @State privatePasswordError: string = '';
  @State privateShelfBusy: boolean = false;
  private privatePasswordDialogSession: SystemDialogSession = new SystemDialogSession();
  private skipNextCoverGalleryReload: boolean = false;

  aboutToAppear(): void {
    this.reloadCoverSettings();
    this.reloadDisplaySettings();
    this.reloadPrivateShelfSettings();
    this.syncBars();
  }

  aboutToDisappear(): void {
    this.privatePasswordDialogSession.close(this.getUIContext());
  }

  onPageShow(): void {
    this.reloadCoverSettings();
    this.reloadDisplaySettings();
    this.syncBars();
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Scroll() {
        Column() {
          this.sectionTitle('书籍信息')
          Column() {
          this.switchItem('书籍打开动画', '开启后点击书籍时显示封面展开动画', this.bookshelfBookOpenAnimation, (value: boolean) => {
            this.bookshelfBookOpenAnimation = value;
            this.onDisplaySettingChanged();
          })
          this.itemDivider()
          this.switchItem('类型标识', '在书名前显示“书／漫／声”，区分普通书、漫画和有声书', this.bookshelfShowTypeBadge, (value: boolean) => {
            this.bookshelfShowTypeBadge = value;
            this.onDisplaySettingChanged();
          })
          this.itemDivider()
          this.switchItem('书籍标签', '控制书架卡片是否显示书籍标签', this.bookshelfShowTags, (value: boolean) => {
            this.bookshelfShowTags = value;
            this.onDisplaySettingChanged();
          })
          this.itemDivider()
          this.switchItem('书籍来源', '控制书架卡片是否显示书籍来源', this.bookshelfShowSource, (value: boolean) => {
            this.bookshelfShowSource = value;
            this.onDisplaySettingChanged();
          })
          this.itemDivider()
          this.switchItem('书籍简介', '开启后显示书源抓取的简介内容', this.bookshelfShowIntro, (value: boolean) => {
            this.bookshelfShowIntro = value;
            this.onDisplaySettingChanged();
          })
          if (this.bookshelfShowIntro) {
            this.itemDivider()
            this.switchItem('显示全部简介', '开启后书架卡片显示完整简介内容', this.bookshelfShowFullIntro, (value: boolean) => {
              this.bookshelfShowFullIntro = value;
              this.onDisplaySettingChanged();
            })
          }
          this.itemDivider()
          this.switchItem('使用阅读进度条', '开启后在书架卡片底部显示阅读百分比和阅读信息', this.bookshelfShowProgressBar, (value: boolean) => {
            this.bookshelfShowProgressBar = value;
            this.onDisplaySettingChanged();
          })
          if (this.bookshelfShowProgressBar) {
            this.itemDivider()
            this.switchItem('显示最后阅读时间', '开启后阅读进度条旁显示最近一次阅读时间', this.bookshelfShowLastReadTime, (value: boolean) => {
              this.bookshelfShowLastReadTime = value;
              this.onDisplaySettingChanged();
            })
            this.itemDivider()
            this.switchItem('显示最后阅读章节', '开启后阅读进度条旁显示最近一次阅读章节', this.bookshelfShowLastReadChapter, (value: boolean) => {
              this.bookshelfShowLastReadChapter = value;
              this.onDisplaySettingChanged();
            })
          }
          this.itemDivider()
          this.selectItem('书架布局', '切换列表信息密度或封面平铺展示',
            this.bookshelfLayoutOptions(), this.bookshelfLayoutSelectedIndex(), (index: number) => {
              this.bookshelfLayoutMode = index === 2 ? 'tile' : (index === 1 ? 'loose' : 'compact');
              this.onDisplaySettingChanged();
            })
          if (this.bookshelfLayoutMode === 'tile') {
            this.itemDivider()
            this.selectItem('上次阅读扉页设置', '设置最近阅读书籍封面右侧的展示内容',
              this.lastReadLeafOptions(), this.lastReadLeafSelectedIndex(), (index: number) => {
                this.bookshelfLastReadLeafMode = index === 0 ? 'bookInfo' :
                  (index === 1 ? 'contentPreview' : 'adaptive');
                this.onDisplaySettingChanged();
              })
          }

          }
          .width('calc(100% - 24vp)')
          .margin({ left: 12, right: 12 })
          .borderRadius(ThemeRuntime.cardRadius())
          .clip(true)
          .backgroundColor(this.cardColor())

          this.sectionTitle('隐私书架')
          Column() {
            this.privateShelfSwitchItem()
            if (this.privateShelfEnabled) {
              this.itemDivider()
              this.actionItem('隐私书架密码',
                this.privateShelfHasPassword ? '已设置，进入隐私书架时需要输入' : '未设置，设置后进入隐私书架需要输入密码',
                this.primaryTextColor(), () => {
                  this.openPrivatePasswordDialog('password');
                })
              this.itemDivider()
              this.actionItem('重置隐私书架', '删除所有隐私书籍并关闭隐私书架，忘记密码时使用', '#E53935', () => {
                this.confirmResetPrivateShelf();
              })
            }
          }
          .width('calc(100% - 24vp)')
          .margin({ left: 12, right: 12 })
          .borderRadius(ThemeRuntime.cardRadius())
          .clip(true)
          .backgroundColor(this.cardColor())

          this.sectionTitle('封面设置')
          Column() {
          this.switchItem('忽略原始封面', '开启后书架封面只使用当前应用的封面图集', this.bookshelfIgnoreSourceCover, (value: boolean) => {
            this.bookshelfIgnoreSourceCover = value;
            this.onCoverSettingChanged();
          })
          this.itemDivider()
          this.selectItem('封面模式', '控制多张封面的展示顺序',
            this.modeOptions(), this.modeSelectedIndex(), (index: number) => {
              this.bookshelfCoverMode = index === 1 ? 'random' : 'sequence';
              this.onCoverSettingChanged();
            })
          this.itemDivider()
          this.albumSelectItem('浅色配色图集', '浅色模式下使用的封面图集', false)
          this.itemDivider()
          this.albumSelectItem('深色配色图集', '深色模式下使用的封面图集', true)
          this.itemDivider()
          this.selectItem('图集应用范围', '选择图集作用于全部书籍或指定书籍',
            this.scopeOptions(), this.scopeSelectedIndex(), (index: number) => {
              this.setCoverApplyScope(index === 1 ? 'books' : 'all');
            })

          if (this.showTargetBookList) {
            this.itemDivider()
            this.targetBooksPanel()
          }
          }
          .width('calc(100% - 24vp)')
          .margin({ left: 12, right: 12 })
          .borderRadius(ThemeRuntime.cardRadius())
          .clip(true)
          .backgroundColor(this.cardColor())

          this.sectionTitle('封面图集')
          Column() {
            this.navItem('图集管理', '新建图集、导入图片、重命名和预览封面', 'pages/CoverGalleryManager')
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  loadAlbums(): void {
    this.syncAlbums(this.bookshelfCoverAlbums);
  }

  onCoverAlbumsChanged(): void {
    this.loadAlbums();
  }

  onCoverGalleryUpdateTimeChanged(): void {
    if (this.skipNextCoverGalleryReload) {
      this.skipNextCoverGalleryReload = false;
      return;
    }
    this.reloadCoverSettings();
  }

  async reloadCoverSettings(): Promise<void> {
    try {
      const snapshot = await CoverGalleryStore.load(getContext(this));
      this.applySnapshot(snapshot);
    } catch (e) {
      console.warn('重新加载封面图集设置失败:', e);
      this.loadAlbums();
    }
  }

  async reloadDisplaySettings(): Promise<void> {
    try {
      const settings = await BookshelfDisplaySettingsStore.load(getContext(this));
      this.bookshelfShowTags = settings.showTags;
      this.bookshelfShowSource = settings.showSource;
      this.bookshelfShowIntro = settings.showIntro;
      this.bookshelfShowFullIntro = settings.showFullIntro;
      this.bookshelfShowProgressBar = settings.showProgressBar;
      this.bookshelfShowLastReadTime = settings.showLastReadTime;
      this.bookshelfShowLastReadChapter = settings.showLastReadChapter;
      this.bookshelfShowTypeBadge = settings.showTypeBadge;
      this.bookshelfLayoutMode = settings.layoutMode;
      this.bookshelfLastReadLeafMode = settings.lastReadLeafMode;
      this.bookshelfBookOpenAnimation = settings.bookOpenAnimation;
    } catch (e) {
      console.warn('重新加载书架显示设置失败:', e);
    }
  }

  async reloadPrivateShelfSettings(): Promise<void> {
    try {
      await PrivateShelfStore.load(getContext(this));
    } catch (e) {
      console.warn('加载隐私书架设置失败:', e);
    }
    this.privateShelfSwitchOn = this.privateShelfEnabled;
  }

  onPrivateShelfEnabledChanged(): void {
    this.privateShelfSwitchOn = this.privateShelfEnabled;
  }

  onPrivateShelfSwitchChanged(value: boolean): void {
    if (value === this.privateShelfEnabled) return;
    this.privateShelfSwitchOn = value;
    if (!value && this.privateShelfHasPassword) {
      this.openPrivatePasswordDialog('disable');
      return;
    }
    this.applyPrivateShelfEnabled(value);
  }

  async applyPrivateShelfEnabled(enabled: boolean): Promise<void> {
    try {
      await PrivateShelfStore.setEnabled(getContext(this), enabled);
    } catch (e) {
      console.warn('保存隐私书架开关失败:', e);
      HdsFeedback.showToast('保存失败');
    }
    this.privateShelfSwitchOn = this.privateShelfEnabled;
  }

  openPrivatePasswordDialog(mode: string): void {
    this.privatePasswordDialogMode = mode;
    this.privatePasswordCurrent = '';
    this.privatePasswordNew = '';
    this.privatePasswordConfirm = '';
    this.privatePasswordError = '';
    // 只能用按钮关闭：点蒙层关掉的话，“关闭隐私书架”的开关会停在错误的位置。
    this.privatePasswordDialogSession.open(this.getUIContext(), (): void => {
      this.privatePasswordDialogContent();
    }, {
      autoCancel: false,
      maskColor: this.appDarkMode ? '#99000000' : '#33000000',
      warnTag: '显示隐私书架密码弹窗失败:'
    });
  }

  closePrivatePasswordDialog(): void {
    this.privatePasswordDialogSession.close(this.getUIContext());
    this.privatePasswordCurrent = '';
    this.privatePasswordNew = '';
    this.privatePasswordConfirm = '';
    this.privatePasswordError = '';
    this.privateShelfSwitchOn = this.privateShelfEnabled;
  }

  async submitPrivatePasswordDialog(): Promise<void> {
    if (this.privateShelfBusy) return;
    this.privateShelfBusy = true;
    try {
      const context = getContext(this);
      if (this.privateShelfHasPassword &&
        !(await PrivateShelfStore.verifyPassword(context, this.privatePasswordCurrent))) {
        this.privatePasswordError = '当前密码不正确';
        return;
      }
      if (this.privatePasswordDialogMode === 'disable') {
        await PrivateShelfStore.setEnabled(context, false);
        this.closePrivatePasswordDialog();
        return;
      }
      if (this.privatePasswordNew !== this.privatePasswordConfirm) {
        this.privatePasswordError = '两次输入的新密码不一致';
        return;
      }
      if (!this.privatePasswordNew && !this.privateShelfHasPassword) {
        this.privatePasswordError = '请输入密码';
        return;
      }
      const cleared = !this.privatePasswordNew;
      await PrivateShelfStore.setPassword(context, this.privatePasswordNew);
      this.closePrivatePasswordDialog();
      HdsFeedback.showToast(cleared ? '已清除隐私书架密码' : '隐私书架密码已设置');
    } catch (e) {
      console.warn('保存隐私书架密码失败:', e);
      this.privatePasswordError = '保存失败，请重试';
    } finally {
      this.privateShelfBusy = false;
    }
  }

  async confirmResetPrivateShelf(): Promise<void> {
    const confirmation = await promptAction.showDialog({
      title: '重置隐私书架',
      message: '该操作会删除所有隐私书籍，包括进度、书签等，并关闭隐私书架选项',
      buttons: [{ text: '取消', color: this.subTextColor() }, { text: '确认', color: '#D9485F' }]
    });
    if (confirmation.index !== 1 || this.privateShelfBusy) return;
    this.privateShelfBusy = true;
    try {
      const context = getContext(this);
      const db = AppDatabase.getInstance();
      await db.initWithContext(context);
      const privateBooks = (await db.getAllBooks()).filter((book: Book) => book.isPrivate);
      for (const book of privateBooks) {
        const covers = [
          ...BookDisplayHelper.decodeCoverList(book.customCoverUrl),
          ...BookDisplayHelper.decodeCoverList(book.coverUrl)
        ];
        for (const cover of covers) {
          BookCoverCache.deleteCachedCover(context, cover);
        }
        LocalBookService.deleteLocalBookFiles(context, book);
        await db.deleteBook(book.bookUrl, 'private_shelf_reset');
        // 阅读时长的 dayKey 形如 2026-10-10，这个区间覆盖全部日期。
        await db.deleteReadStatsForBook(book.bookUrl, '0000-00-00', '9999-99-99');
      }
      await PrivateShelfStore.reset(context);
      AppStorage.setOrCreate('shelfUpdateTime', Date.now());
      HdsFeedback.showToast('隐私书架已重置');
    } catch (e) {
      console.error('重置隐私书架失败:', e);
      HdsFeedback.showToast('重置失败');
    } finally {
      this.privateShelfBusy = false;
      this.privateShelfSwitchOn = this.privateShelfEnabled;
    }
  }

  onDisplaySettingChanged(): void {
    AppStorage.setOrCreate('shelfUpdateTime', Date.now());
    const settings = new BookshelfDisplaySettings();
    settings.showTags = this.bookshelfShowTags;
    settings.showSource = this.bookshelfShowSource;
    settings.showIntro = this.bookshelfShowIntro;
    settings.showFullIntro = this.bookshelfShowFullIntro;
    settings.showProgressBar = this.bookshelfShowProgressBar;
    settings.showLastReadTime = this.bookshelfShowLastReadTime;
    settings.showLastReadChapter = this.bookshelfShowLastReadChapter;
    settings.showTypeBadge = this.bookshelfShowTypeBadge;
    settings.layoutMode = this.bookshelfLayoutMode;
    settings.lastReadLeafMode = this.bookshelfLastReadLeafMode;
    settings.bookOpenAnimation = this.bookshelfBookOpenAnimation;
    BookshelfDisplaySettingsStore.applyToStorage(settings);
    BookshelfDisplaySettingsStore.save(getContext(this), settings).catch((e: Error) => {
      console.warn('保存书架显示设置失败:', e);
    });
  }

  applySnapshot(snapshot: CoverGallerySnapshot): void {
    const localAlbumsRaw = this.bookshelfCoverAlbums;
    const albumsRaw = this.hasAlbumPayload(snapshot.albumsRaw) || !this.hasAlbumPayload(localAlbumsRaw) ?
      snapshot.albumsRaw : localAlbumsRaw;
    this.bookshelfCoverAlbums = albumsRaw;
    this.bookshelfLightCoverAlbumId = snapshot.lightAlbumId;
    this.bookshelfDarkCoverAlbumId = snapshot.darkAlbumId;
    this.bookshelfCoverApplyScope = snapshot.applyScope;
    this.showTargetBookList = snapshot.applyScope === 'books';
    this.bookshelfCoverTargetBooks = snapshot.targetBooksRaw;
    this.targetBookUrls = CoverGallerySettings.parseTargetBooks(snapshot.targetBooksRaw);
    this.bookshelfIgnoreSourceCover = snapshot.ignoreSourceCover;
    this.bookshelfCoverMode = snapshot.coverMode;
    this.syncAlbums(albumsRaw);
    this.bumpSettingsRender();
    if (this.showTargetBookList) {
      this.loadBooks();
    } else {
      this.books = [];
      this.targetBooksLoading = false;
    }
  }

  async loadBooks(): Promise<void> {
    this.targetBooksLoading = true;
    this.bumpSettingsRender();
    try {
      const db = AppDatabase.getInstance();
      await db.initWithContext(getContext(this));
      this.books = PrivateShelfStore.publicBooks(
        SearchExplorePendingBook.filterShelfBooks(await db.getAllBooks())).slice();
    } catch (e) {
      console.warn('加载书籍列表失败:', e);
      this.books = [];
    } finally {
      this.targetBooksLoading = false;
      this.bumpSettingsRender();
    }
  }

  setCoverApplyScope(scope: string): void {
    const nextScope = scope === 'books' ? 'books' : 'all';
    this.showTargetBookList = nextScope === 'books';
    this.bookshelfCoverApplyScope = nextScope;
    this.bumpSettingsRender();
    if (this.showTargetBookList) {
      this.loadBooks();
    } else {
      this.books = [];
      this.targetBooksLoading = false;
    }
    this.onCoverSettingChanged();
  }

  setThemeAlbum(dark: boolean, albumId: string): void {
    if (dark) {
      this.bookshelfDarkCoverAlbumId = albumId;
    } else {
      this.bookshelfLightCoverAlbumId = albumId;
    }
    this.onCoverSettingChanged();
  }

  toggleTargetBook(book: Book, selected: boolean): void {
    this.toggleTargetBookUrl(book.bookUrl, selected);
  }

  toggleTargetBookUrl(bookUrl: string, selected: boolean): void {
    if (!bookUrl) {
      return;
    }
    const targets = this.targetBookUrls.slice();
    if (selected && !targets.includes(bookUrl)) {
      targets.push(bookUrl);
    }
    if (!selected) {
      const index = targets.indexOf(bookUrl);
      if (index >= 0) {
        targets.splice(index, 1);
      }
    }
    this.targetBookUrls = targets.slice();
    this.bookshelfCoverTargetBooks = CoverGallerySettings.encodeTargetBooks(this.targetBookUrls);
    this.bumpSettingsRender();
    this.onCoverSettingChanged();
  }

  bumpSettingsRender(): void {
    this.settingsRenderTick++;
  }

  onCoverSettingChanged(): void {
    const snapshot = this.currentSnapshot();
    CoverGalleryStore.applyToStorage(snapshot);
    AppStorage.setOrCreate('shelfUpdateTime', Date.now());
    this.skipNextCoverGalleryReload = true;
    AppStorage.setOrCreate('coverGalleryUpdateTime', Date.now());
    CoverGalleryStore.save(getContext(this), snapshot).then(() => {
      RecentReadCardUpdater.reload(getContext(this) as common.UIAbilityContext);
    }).catch((e: Error) => {
      console.warn('保存封面图集设置失败:', e);
    });
  }

  currentSnapshot(): CoverGallerySnapshot {
    const snapshot = new CoverGallerySnapshot();
    snapshot.albumsRaw = this.bookshelfCoverAlbums;
    snapshot.lightAlbumId = this.bookshelfLightCoverAlbumId;
    snapshot.darkAlbumId = this.bookshelfDarkCoverAlbumId;
    snapshot.applyScope = this.showTargetBookList ? 'books' : 'all';
    snapshot.targetBooksRaw = this.bookshelfCoverTargetBooks;
    snapshot.ignoreSourceCover = this.bookshelfIgnoreSourceCover;
    snapshot.coverMode = this.bookshelfCoverMode;
    return snapshot;
  }

  isTargetBook(book: Book): boolean {
    return this.isTargetBookUrl(book.bookUrl);
  }

  isTargetBookUrl(bookUrl: string): boolean {
    return !!bookUrl && this.targetBookUrls.includes(bookUrl);
  }

  targetBookKey(book: Book): string {
    const bookUrl = book.bookUrl || `${book.origin}_${book.name}_${book.author}`;
    return `${bookUrl}_${this.settingsRenderTick}_${this.isTargetBookUrl(book.bookUrl) ? 'on' : 'off'}`;
  }

  modeOptions(): SelectOption[] {
    return [{ value: '顺序' }, { value: '随机' }];
  }

  modeSelectedIndex(): number {
    return this.bookshelfCoverMode === 'random' ? 1 : 0;
  }

  albumOptions(): SelectOption[] {
    return this.albumSelectOptions;
  }

  syncAlbums(raw: string): void {
    this.albums = CoverGallerySettings.parseAlbums(raw);
    const options: SelectOption[] = [{ value: '不使用图集' }];
    for (const album of this.albums) {
      options.push({ value: `${album.name}(${album.covers.length})` });
    }
    this.albumSelectOptions = options;
  }

  refreshAlbumOptionsForMenu(): void {
    const latestRaw = AppStorage.get<string>('bookshelfCoverAlbums');
    const raw = latestRaw !== undefined ? latestRaw : this.bookshelfCoverAlbums;
    if (raw !== this.bookshelfCoverAlbums) {
      this.bookshelfCoverAlbums = raw;
    }
    this.syncAlbums(raw);
    this.bumpSettingsRender();
  }

  hasAlbumPayload(raw: string): boolean {
    return (raw || '').trim().length > 0;
  }

  albumSelectedIndex(dark: boolean): number {
    const selectedId = dark ? this.bookshelfDarkCoverAlbumId : this.bookshelfLightCoverAlbumId;
    for (let i = 0; i < this.albums.length; i++) {
      if (this.albums[i].id === selectedId) {
        return i + 1;
      }
    }
    return 0;
  }

  albumIdByIndex(index: number): string {
    if (index <= 0 || index - 1 >= this.albums.length) {
      return '';
    }
    return this.albums[index - 1].id;
  }

  scopeOptions(): SelectOption[] {
    return [{ value: '全部应用' }, { value: '指定书籍' }];
  }

  bookshelfLayoutOptions(): SelectOption[] {
    return [{ value: '紧凑' }, { value: '宽松' }, { value: '平铺' }];
  }

  bookshelfLayoutSelectedIndex(): number {
    return this.bookshelfLayoutMode === 'tile' ? 2 : (this.bookshelfLayoutMode === 'loose' ? 1 : 0);
  }

  lastReadLeafOptions(): SelectOption[] {
    return [{ value: '书籍信息' }, { value: '内容预览' }, { value: '自适应' }];
  }

  lastReadLeafSelectedIndex(): number {
    return this.bookshelfLastReadLeafMode === 'bookInfo' ? 0 :
      (this.bookshelfLastReadLeafMode === 'contentPreview' ? 1 : 2);
  }

  scopeSelectedIndex(): number {
    return this.showTargetBookList ? 1 : 0;
  }

  optionValue(options: SelectOption[], index: number): ResourceStr {
    if (index >= 0 && index < options.length) {
      return options[index].value;
    }
    return '';
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

  inputColor(): string {
    return ThemeRuntime.inputColor(this.appDarkMode);
  }

  buttonColor(): string {
    return ThemeRuntime.buttonColor(this.appDarkMode);
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
      Text('书架设置')
        .fontSize(20)
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
      .fontSize(13)
      .fontColor(this.subTextColor())
      .width('100%')
      .padding({ left: 16, right: 16, top: 20, bottom: 8 })
  }

  @Builder
  itemDivider() {
    Divider()
      .strokeWidth(0.5)
      .color(this.appDarkMode ? '#24FFFFFF' : '#14000000')
      .width('calc(100% - 32vp)')
      .margin({ left: 16, right: 16 })
  }

  @Builder
  switchItem(title: string, desc: string, value: boolean, onChange: (value: boolean) => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(16)
          .fontColor(this.primaryTextColor())
        Text(desc)
          .fontSize(12)
          .fontColor(this.subTextColor())
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      AdaptiveSwitch({
        isOn: value,
        onChange: (checked: boolean) => {
          onChange(checked);
        }
      })
    }
    .width('calc(100% - 32vp)')
    .constraintSize({ minHeight: 64 })
    .padding({ left: 0, right: 0, top: 10, bottom: 10 })
    .margin({ left: 16, right: 16 })
    .backgroundColor(Color.Transparent)
  }

  @Builder
  selectItem(title: string, desc: string, options: SelectOption[], selected: number, onSelect: (index: number) => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(16)
          .fontColor(this.primaryTextColor())
        Text(desc)
          .fontSize(12)
          .fontColor(this.subTextColor())
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Select(options)
        .selected(selected)
        .value(this.optionValue(options, selected))
        .font({ size: 14 })
        .fontColor(this.subTextColor())
        .backgroundColor(Color.Transparent)
        .arrowPosition(ArrowPosition.END)
        .padding({ left: 0, right: 0 })
        .borderRadius(16)
        .border({ width: 0 })
        .optionBgColor(Color.Transparent)
        .divider(null)
        .optionFontColor(this.primaryTextColor())
        .selectedOptionFontColor(ThemeRuntime.accentColor(this.appDarkMode))
        .selectedOptionBgColor(ThemeRuntime.accentSurfaceColor(this.appDarkMode))
        .menuBackgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode))
        .menuBackgroundBlurStyle(BlurStyle.NONE)
        .attributeModifier(ImmersiveMaterialRuntime.selectMenuModifier())
        .onSelect((index: number) => {
          onSelect(index);
        })
    }
    .width('calc(100% - 32vp)')
    .constraintSize({ minHeight: 66 })
    .padding({ left: 0, right: 0, top: 10, bottom: 10 })
    .margin({ left: 16, right: 16 })
    .backgroundColor(Color.Transparent)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  albumSelectItem(title: string, desc: string, dark: boolean) {
    Row() {
      Column() {
        Text(title)
          .fontSize(16)
          .fontColor(this.primaryTextColor())
        Text(desc)
          .fontSize(12)
          .fontColor(this.subTextColor())
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Select(this.albumOptions())
        .selected(this.albumSelectedIndex(dark))
        .value(this.optionValue(this.albumOptions(), this.albumSelectedIndex(dark)))
        .font({ size: 14 })
        .fontColor(this.subTextColor())
        .backgroundColor(Color.Transparent)
        .arrowPosition(ArrowPosition.END)
        .padding({ left: 0, right: 0 })
        .borderRadius(16)
        .border({ width: 0 })
        .optionBgColor(Color.Transparent)
        .divider(null)
        .optionFontColor(this.primaryTextColor())
        .selectedOptionFontColor(ThemeRuntime.accentColor(this.appDarkMode))
        .selectedOptionBgColor(ThemeRuntime.accentSurfaceColor(this.appDarkMode))
        .menuBackgroundColor(ThemeRuntime.dropdownPanelColor(this.appDarkMode))
        .menuBackgroundBlurStyle(BlurStyle.NONE)
        .attributeModifier(ImmersiveMaterialRuntime.selectMenuModifier())
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.refreshAlbumOptionsForMenu();
          }
        })
        .onSelect((index: number) => {
          this.setThemeAlbum(dark, this.albumIdByIndex(index));
        })
    }
    .width('calc(100% - 32vp)')
    .constraintSize({ minHeight: 66 })
    .padding({ left: 0, right: 0, top: 10, bottom: 10 })
    .margin({ left: 16, right: 16 })
    .backgroundColor(Color.Transparent)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  targetBooksPanel() {
    Column({ space: 2 }) {
      if (this.targetBooksLoading) {
        Text('正在加载书籍...')
          .fontSize(13)
          .fontColor(this.subTextColor())
          .width('100%')
          .height(48)
          .padding({ left: 16, right: 16 })
          .textAlign(TextAlign.Start)
      } else if (this.books.length === 0) {
        Text('暂无可选择书籍')
          .fontSize(13)
          .fontColor(this.subTextColor())
          .width('100%')
          .height(48)
          .padding({ left: 16, right: 16 })
          .textAlign(TextAlign.Start)
      } else {
        ForEach(this.books, (book: Book) => {
          Row() {
            Text(book.name || '未命名书籍')
              .fontSize(14)
              .fontColor(this.primaryTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            this.targetBookSwitch(book, this.isTargetBook(book))
          }
          .width('100%')
          .height(48)
          .padding({ left: 16, right: 16 })
        }, (book: Book) => this.targetBookKey(book))
      }
    }
    .width('100%')
    .backgroundColor(this.cardColor())
  }

  @Builder
  targetBookSwitch(book: Book, selected: boolean) {
    AdaptiveSwitch({
      isOn: selected,
      onChange: (checked: boolean) => {
        this.toggleTargetBook(book, checked);
      }
    })
  }

  // 不走 switchItem：取消关闭时开关要能弹回去，按值传参的 Builder 不会跟随状态刷新。
  @Builder
  privateShelfSwitchItem() {
    Row() {
      Column() {
        Text('隐私书架')
          .fontSize(16)
          .fontColor(this.primaryTextColor())
        Text('开启后书架左上角增加“隐私”入口；关闭后隐私书籍继续隐藏')
          .fontSize(12)
          .fontColor(this.subTextColor())
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      AdaptiveSwitch({
        isOn: this.privateShelfSwitchOn,
        onChange: (checked: boolean) => {
          this.onPrivateShelfSwitchChanged(checked);
        }
      })
    }
    .width('calc(100% - 32vp)')
    .constraintSize({ minHeight: 64 })
    .padding({ left: 0, right: 0, top: 10, bottom: 10 })
    .margin({ left: 16, right: 16 })
    .backgroundColor(Color.Transparent)
  }

  @Builder
  actionItem(title: string, desc: string, titleColor: string, onClick: () => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(16)
          .fontColor(titleColor)
        Text(desc)
          .fontSize(12)
          .fontColor(this.subTextColor())
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([this.subTextColor()])
        .width(24)
    }
    .width('calc(100% - 32vp)')
    .constraintSize({ minHeight: 66 })
    .padding({ left: 0, right: 0, top: 10, bottom: 10 })
    .margin({ left: 16, right: 16 })
    .backgroundColor(Color.Transparent)
    .alignItems(VerticalAlign.Center)
    .onClick(onClick)
  }

  @Builder
  privatePasswordField(placeholder: string, value: string, onChange: (value: string) => void) {
    TextInput({ placeholder: placeholder, text: value })
      .type(InputType.Password)
      .width('100%')
      .height(44)
      .fontColor(this.primaryTextColor())
      .placeholderColor(this.subTextColor())
      .backgroundColor(this.inputColor())
      .borderRadius(ThemeRuntime.mediumRadius())
      .margin({ bottom: 10 })
      .onChange((text: string) => {
        onChange(text);
      })
  }

  @Builder
  privatePasswordDialogContent() {
    Column() {
      Text(this.privatePasswordDialogMode === 'disable' ? '关闭隐私书架' : '隐私书架密码')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryTextColor())
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 18 })

      if (this.privateShelfHasPassword) {
        this.privatePasswordField('当前密码', this.privatePasswordCurrent, (value: string) => {
          this.privatePasswordCurrent = value;
          this.privatePasswordError = '';
        })
      }
      if (this.privatePasswordDialogMode !== 'disable') {
        this.privatePasswordField(this.privateShelfHasPassword ? '新密码（留空则清除密码）' : '密码',
          this.privatePasswordNew, (value: string) => {
            this.privatePasswordNew = value;
            this.privatePasswordError = '';
          })
        this.privatePasswordField(this.privateShelfHasPassword ? '再次输入新密码' : '再次输入密码',
          this.privatePasswordConfirm, (value: string) => {
            this.privatePasswordConfirm = value;
            this.privatePasswordError = '';
          })
      }

      if (this.privatePasswordError) {
        Text(this.privatePasswordError)
          .fontSize(12)
          .fontColor('#E53935')
          .width('100%')
      }

      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .backgroundColor(this.inputColor())
          .fontColor(this.primaryTextColor())
          .onClick(() => this.closePrivatePasswordDialog())

        Button(this.privatePasswordDialogMode === 'disable' ? '关闭' : '保存')
          .layoutWeight(1)
          .height(44)
          .backgroundColor(this.buttonColor())
          .fontColor('#FFFFFF')
          .onClick(() => {
            this.submitPrivatePasswordDialog();
          })
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .padding(20)
  }

  @Builder
  navItem(title: string, desc: string, url: string) {
    Row() {
      Column() {
        Text(title)
          .fontSize(16)
          .fontColor(this.primaryTextColor())
        Text(desc)
          .fontSize(12)
          .fontColor(this.subTextColor())
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([this.subTextColor()])
        .width(24)
    }
    .width('calc(100% - 32vp)')
    .constraintSize({ minHeight: 66 })
    .padding({ left: 0, right: 0, top: 10, bottom: 10 })
    .margin({ left: 16, right: 16 })
    .backgroundColor(Color.Transparent)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      router.pushUrl({ url });
    })
  }
}
