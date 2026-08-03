export class ReaderTtsFloatingSession {
  private static ownerId: string = '';
  private static toggleAction: (() => Promise<void>) | null = null;
  private static pausedState: (() => boolean) | null = null;
  private static stopAction: (() => Promise<void> | void) | null = null;
  private static previousAction: (() => void) | null = null;
  private static nextAction: (() => void) | null = null;
  private static positionAction: ((chapterIndex: number, pageIndex: number) => void) | null = null;
  private static speedAction: ((value: number) => void) | null = null;
  private static timerAction: ((minutes: number) => void) | null = null;
  private static voiceAction: (() => void) | null = null;
  private static catalogAction: (() => void) | null = null;
  private static audioCatalogTitles: string[] = [];
  private static audioCatalogIndex: number = 0;
  private static audioCatalogSelectAction: ((index: number) => void) | null = null;

  static attach(ownerId: string, bookUrl: string, bookName: string, chapterTitle: string,
    paused: boolean, toggleAction: () => Promise<void>, pausedState: () => boolean,
    stopAction: () => Promise<void> | void): void {
    ReaderTtsFloatingSession.ownerId = ownerId;
    ReaderTtsFloatingSession.toggleAction = toggleAction;
    ReaderTtsFloatingSession.pausedState = pausedState;
    ReaderTtsFloatingSession.stopAction = stopAction;
    AppStorage.setOrCreate('globalTtsActive', true);
    AppStorage.setOrCreate('globalTtsPaused', paused);
    AppStorage.setOrCreate('globalTtsBookUrl', bookUrl);
    AppStorage.setOrCreate('globalTtsBookName', bookName || '正在朗读');
    AppStorage.setOrCreate('globalTtsChapterTitle', chapterTitle || '');
    AppStorage.setOrCreate('globalTtsMode', 'tts');
    AppStorage.setOrCreate('globalTtsVoiceCode', '');
    ReaderTtsFloatingSession.notifyChanged();
  }

  static update(ownerId: string, bookName: string, chapterTitle: string, paused: boolean): void {
    if (!ReaderTtsFloatingSession.isOwner(ownerId)) {
      return;
    }
    const nextName = bookName || '正在朗读';
    const nextTitle = chapterTitle || '';
    const changed = AppStorage.get<boolean>('globalTtsPaused') !== paused ||
      AppStorage.get<string>('globalTtsBookName') !== nextName ||
      AppStorage.get<string>('globalTtsChapterTitle') !== nextTitle;
    if (!changed) return;
    AppStorage.setOrCreate('globalTtsActive', true);
    AppStorage.setOrCreate('globalTtsPaused', paused);
    AppStorage.setOrCreate('globalTtsBookName', nextName);
    AppStorage.setOrCreate('globalTtsChapterTitle', nextTitle);
    ReaderTtsFloatingSession.notifyChanged();
  }

  static configureControls(ownerId: string, previousAction: () => void, nextAction: () => void,
    speedAction: (value: number) => void, timerAction: (minutes: number) => void): void {
    if (!ReaderTtsFloatingSession.isOwner(ownerId)) {
      return;
    }
    ReaderTtsFloatingSession.previousAction = previousAction;
    ReaderTtsFloatingSession.nextAction = nextAction;
    ReaderTtsFloatingSession.speedAction = speedAction;
    ReaderTtsFloatingSession.timerAction = timerAction;
  }

  static configurePositionControl(ownerId: string,
    positionAction: (chapterIndex: number, pageIndex: number) => void): void {
    if (!ReaderTtsFloatingSession.isOwner(ownerId)) {
      return;
    }
    ReaderTtsFloatingSession.positionAction = positionAction;
  }

  static configureAudioControls(ownerId: string, voiceCode: string,
    voiceAction: () => void, catalogAction: () => void): void {
    if (!ReaderTtsFloatingSession.isOwner(ownerId)) return;
    ReaderTtsFloatingSession.voiceAction = voiceAction;
    ReaderTtsFloatingSession.catalogAction = catalogAction;
    AppStorage.setOrCreate('globalTtsMode', 'audio');
    AppStorage.setOrCreate('globalTtsVoiceCode', voiceCode || '默认');
  }

  static openVoice(): void {
    const action = ReaderTtsFloatingSession.voiceAction;
    if (action) action();
  }

  static openCatalog(): void {
    const action = ReaderTtsFloatingSession.catalogAction;
    if (action) action();
  }

  static configureAudioCatalog(ownerId: string, titles: string[], currentIndex: number,
    selectAction: (index: number) => void): void {
    if (!ReaderTtsFloatingSession.isOwner(ownerId)) return;
    ReaderTtsFloatingSession.audioCatalogTitles = titles.slice();
    ReaderTtsFloatingSession.audioCatalogIndex = currentIndex;
    ReaderTtsFloatingSession.audioCatalogSelectAction = selectAction;
    ReaderTtsFloatingSession.updateAudioChapterAvailability(currentIndex);
  }

  static updateAudioCatalogIndex(ownerId: string, currentIndex: number): void {
    if (!ReaderTtsFloatingSession.isOwner(ownerId)) return;
    ReaderTtsFloatingSession.audioCatalogIndex = currentIndex;
    ReaderTtsFloatingSession.updateAudioChapterAvailability(currentIndex);
  }

  static catalogTitles(): string[] {
    return ReaderTtsFloatingSession.audioCatalogTitles.slice();
  }

  static catalogIndex(): number {
    return ReaderTtsFloatingSession.audioCatalogIndex;
  }

  static selectCatalogIndex(index: number): void {
    const action = ReaderTtsFloatingSession.audioCatalogSelectAction;
    if (action) action(index);
  }

  static updateDetails(ownerId: string, content: string, textBefore: string, currentText: string,
    textAfter: string, cover: ResourceStr, coverFrame: ResourceStr,
    chapterProgress: string, speed: number, timerMinutes: number, timerRemainingSeconds: number,
    canPrevious: boolean, canNext: boolean): void {
    if (!ReaderTtsFloatingSession.isOwner(ownerId)) {
      return;
    }
    if (AppStorage.get<ResourceStr>('globalTtsCover') !== cover) {
      AppStorage.setOrCreate<ResourceStr>('globalTtsCover', cover);
    }
    if (AppStorage.get<ResourceStr>('globalTtsCoverFrame') !== coverFrame) {
      AppStorage.setOrCreate<ResourceStr>('globalTtsCoverFrame', coverFrame);
    }
    if (AppStorage.get<string>('globalTtsContent') !== content) {
      AppStorage.setOrCreate('globalTtsContent', content);
    }
    if (AppStorage.get<string>('globalTtsTextBefore') !== textBefore) {
      AppStorage.setOrCreate('globalTtsTextBefore', textBefore);
    }
    if (AppStorage.get<string>('globalTtsCurrentText') !== currentText) {
      AppStorage.setOrCreate('globalTtsCurrentText', currentText);
    }
    if (AppStorage.get<string>('globalTtsTextAfter') !== textAfter) {
      AppStorage.setOrCreate('globalTtsTextAfter', textAfter);
    }
    if (AppStorage.get<string>('globalTtsChapterProgress') !== chapterProgress) {
      AppStorage.setOrCreate('globalTtsChapterProgress', chapterProgress);
    }
    if (AppStorage.get<number>('globalTtsSpeed') !== speed) {
      AppStorage.setOrCreate('globalTtsSpeed', speed);
    }
    if (AppStorage.get<number>('globalTtsTimerMinutes') !== timerMinutes) {
      AppStorage.setOrCreate('globalTtsTimerMinutes', timerMinutes);
    }
    if (AppStorage.get<number>('globalTtsTimerRemainingSeconds') !== timerRemainingSeconds) {
      AppStorage.setOrCreate('globalTtsTimerRemainingSeconds', timerRemainingSeconds);
    }
    if (AppStorage.get<boolean>('globalTtsCanPrevious') !== canPrevious) {
      AppStorage.setOrCreate('globalTtsCanPrevious', canPrevious);
    }
    if (AppStorage.get<boolean>('globalTtsCanNext') !== canNext) {
      AppStorage.setOrCreate('globalTtsCanNext', canNext);
    }
    // These fields are StorageLink-backed and update their consumers directly. Bumping the
    // global revision for every audio position tick rebuilt the capsule once per second.
  }

  static updateTimer(ownerId: string, timerMinutes: number, timerRemainingSeconds: number): void {
    if (!ReaderTtsFloatingSession.isOwner(ownerId)) {
      return;
    }
    if (AppStorage.get<number>('globalTtsTimerMinutes') !== timerMinutes) {
      AppStorage.setOrCreate('globalTtsTimerMinutes', timerMinutes);
    }
    if (AppStorage.get<number>('globalTtsTimerRemainingSeconds') !== timerRemainingSeconds) {
      AppStorage.setOrCreate('globalTtsTimerRemainingSeconds', timerRemainingSeconds);
    }
  }

  static updatePosition(ownerId: string, chapterIndex: number, offsetStart: number, offsetEnd: number): void {
    if (!ReaderTtsFloatingSession.isOwner(ownerId)) {
      return;
    }
    AppStorage.setOrCreate('globalTtsChapterIndex', chapterIndex);
    AppStorage.setOrCreate('globalTtsOffsetStart', offsetStart);
    AppStorage.setOrCreate('globalTtsOffsetEnd', offsetEnd);
    ReaderTtsFloatingSession.notifyChanged();
  }

  static isOwner(ownerId: string): boolean {
    return !!ownerId && ReaderTtsFloatingSession.ownerId === ownerId &&
      (AppStorage.get<boolean>('globalTtsActive') || false);
  }

  static isActive(): boolean {
    return !!ReaderTtsFloatingSession.ownerId &&
      (AppStorage.get<boolean>('globalTtsActive') || false);
  }

  static async toggle(): Promise<void> {
    const action = ReaderTtsFloatingSession.toggleAction;
    if (action) {
      await action();
      const pausedState = ReaderTtsFloatingSession.pausedState;
      if (pausedState && ReaderTtsFloatingSession.isActive()) {
        AppStorage.setOrCreate('globalTtsPaused', pausedState());
        ReaderTtsFloatingSession.notifyChanged();
      }
    }
  }

  static stop(): void {
    const action = ReaderTtsFloatingSession.stopAction;
    if (action) {
      Promise.resolve(action()).catch((error: Error) => {
        console.warn('停止后台播放失败:', error);
      });
      return;
    }
    ReaderTtsFloatingSession.clear();
  }

  static previous(): void {
    const action = ReaderTtsFloatingSession.previousAction;
    if (action) action();
  }

  static next(): void {
    const action = ReaderTtsFloatingSession.nextAction;
    if (action) action();
  }

  static jumpToPosition(chapterIndex: number, pageIndex: number): void {
    const action = ReaderTtsFloatingSession.positionAction;
    if (action) action(chapterIndex, pageIndex);
  }

  static setSpeed(value: number): void {
    const action = ReaderTtsFloatingSession.speedAction;
    if (action) action(value);
  }

  static setTimer(minutes: number): void {
    const action = ReaderTtsFloatingSession.timerAction;
    if (action) action(minutes);
  }

  static async stopOther(ownerId: string): Promise<void> {
    if (!ReaderTtsFloatingSession.isActive() || ReaderTtsFloatingSession.isOwner(ownerId)) {
      return;
    }
    const action = ReaderTtsFloatingSession.stopAction;
    if (action) {
      await Promise.resolve(action());
    } else {
      ReaderTtsFloatingSession.clear();
    }
  }

  private static updateAudioChapterAvailability(currentIndex: number): void {
    const count = ReaderTtsFloatingSession.audioCatalogTitles.length;
    const canPrevious = count > 0 && currentIndex > 0;
    const canNext = count > 0 && currentIndex < count - 1;
    if (AppStorage.get<boolean>('globalTtsCanPrevious') !== canPrevious) {
      AppStorage.setOrCreate('globalTtsCanPrevious', canPrevious);
    }
    if (AppStorage.get<boolean>('globalTtsCanNext') !== canNext) {
      AppStorage.setOrCreate('globalTtsCanNext', canNext);
    }
  }

  static clear(ownerId: string = ''): void {
    if (ownerId && ReaderTtsFloatingSession.ownerId !== ownerId) {
      return;
    }
    ReaderTtsFloatingSession.ownerId = '';
    ReaderTtsFloatingSession.toggleAction = null;
    ReaderTtsFloatingSession.pausedState = null;
    ReaderTtsFloatingSession.stopAction = null;
    ReaderTtsFloatingSession.previousAction = null;
    ReaderTtsFloatingSession.nextAction = null;
    ReaderTtsFloatingSession.positionAction = null;
    ReaderTtsFloatingSession.speedAction = null;
    ReaderTtsFloatingSession.timerAction = null;
    ReaderTtsFloatingSession.voiceAction = null;
    ReaderTtsFloatingSession.catalogAction = null;
    ReaderTtsFloatingSession.audioCatalogTitles = [];
    ReaderTtsFloatingSession.audioCatalogIndex = 0;
    ReaderTtsFloatingSession.audioCatalogSelectAction = null;
    AppStorage.setOrCreate('globalTtsActive', false);
    AppStorage.setOrCreate('globalTtsPaused', false);
    AppStorage.setOrCreate('globalTtsBookUrl', '');
    AppStorage.setOrCreate('globalTtsBookName', '');
    AppStorage.setOrCreate('globalTtsChapterTitle', '');
    AppStorage.setOrCreate('globalTtsMode', '');
    AppStorage.setOrCreate('globalTtsVoiceCode', '');
    AppStorage.setOrCreate<ResourceStr>('globalTtsCover', '');
    AppStorage.setOrCreate<ResourceStr>('globalTtsCoverFrame', '');
    AppStorage.setOrCreate('globalTtsContent', '');
    AppStorage.setOrCreate('globalTtsTextBefore', '');
    AppStorage.setOrCreate('globalTtsCurrentText', '');
    AppStorage.setOrCreate('globalTtsTextAfter', '');
    AppStorage.setOrCreate('globalTtsChapterProgress', '');
    AppStorage.setOrCreate('globalTtsSpeed', 1);
    AppStorage.setOrCreate('globalTtsTimerMinutes', 0);
    AppStorage.setOrCreate('globalTtsTimerRemainingSeconds', 0);
    AppStorage.setOrCreate('globalTtsCanPrevious', false);
    AppStorage.setOrCreate('globalTtsCanNext', false);
    AppStorage.setOrCreate('globalTtsChapterIndex', -1);
    AppStorage.setOrCreate('globalTtsOffsetStart', -1);
    AppStorage.setOrCreate('globalTtsOffsetEnd', -1);
    ReaderTtsFloatingSession.notifyChanged();
  }

  private static notifyChanged(): void {
    const revision = AppStorage.get<number>('globalTtsRevision') || 0;
    AppStorage.setOrCreate('globalTtsRevision', revision + 1);
  }
}
