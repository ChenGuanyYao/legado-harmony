export class ReaderTtsFloatingSession {
  private static ownerId: string = '';
  private static toggleAction: (() => Promise<void>) | null = null;
  private static pausedState: (() => boolean) | null = null;
  private static stopAction: (() => void) | null = null;
  private static previousAction: (() => void) | null = null;
  private static nextAction: (() => void) | null = null;
  private static speedAction: ((value: number) => void) | null = null;
  private static timerAction: ((minutes: number) => void) | null = null;

  static attach(ownerId: string, bookUrl: string, bookName: string, chapterTitle: string,
    paused: boolean, toggleAction: () => Promise<void>, pausedState: () => boolean,
    stopAction: () => void): void {
    ReaderTtsFloatingSession.ownerId = ownerId;
    ReaderTtsFloatingSession.toggleAction = toggleAction;
    ReaderTtsFloatingSession.pausedState = pausedState;
    ReaderTtsFloatingSession.stopAction = stopAction;
    AppStorage.setOrCreate('globalTtsActive', true);
    AppStorage.setOrCreate('globalTtsPaused', paused);
    AppStorage.setOrCreate('globalTtsBookUrl', bookUrl);
    AppStorage.setOrCreate('globalTtsBookName', bookName || '正在朗读');
    AppStorage.setOrCreate('globalTtsChapterTitle', chapterTitle || '');
    ReaderTtsFloatingSession.notifyChanged();
  }

  static update(ownerId: string, bookName: string, chapterTitle: string, paused: boolean): void {
    if (!ReaderTtsFloatingSession.isOwner(ownerId)) {
      return;
    }
    AppStorage.setOrCreate('globalTtsActive', true);
    AppStorage.setOrCreate('globalTtsPaused', paused);
    AppStorage.setOrCreate('globalTtsBookName', bookName || '正在朗读');
    AppStorage.setOrCreate('globalTtsChapterTitle', chapterTitle || '');
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

  static updateDetails(ownerId: string, content: string, cover: ResourceStr, coverFrame: ResourceStr,
    chapterProgress: string, speed: number, timerMinutes: number, timerRemainingSeconds: number,
    canPrevious: boolean, canNext: boolean): void {
    if (!ReaderTtsFloatingSession.isOwner(ownerId)) {
      return;
    }
    AppStorage.setOrCreate<ResourceStr>('globalTtsCover', cover);
    AppStorage.setOrCreate<ResourceStr>('globalTtsCoverFrame', coverFrame);
    AppStorage.setOrCreate('globalTtsContent', content);
    AppStorage.setOrCreate('globalTtsChapterProgress', chapterProgress);
    AppStorage.setOrCreate('globalTtsSpeed', speed);
    AppStorage.setOrCreate('globalTtsTimerMinutes', timerMinutes);
    AppStorage.setOrCreate('globalTtsTimerRemainingSeconds', timerRemainingSeconds);
    AppStorage.setOrCreate('globalTtsCanPrevious', canPrevious);
    AppStorage.setOrCreate('globalTtsCanNext', canNext);
    ReaderTtsFloatingSession.notifyChanged();
  }

  static updateTimer(ownerId: string, timerMinutes: number, timerRemainingSeconds: number): void {
    if (!ReaderTtsFloatingSession.isOwner(ownerId)) {
      return;
    }
    AppStorage.setOrCreate('globalTtsTimerMinutes', timerMinutes);
    AppStorage.setOrCreate('globalTtsTimerRemainingSeconds', timerRemainingSeconds);
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
      action();
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
      action();
      await Promise.resolve();
    } else {
      ReaderTtsFloatingSession.clear();
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
    ReaderTtsFloatingSession.speedAction = null;
    ReaderTtsFloatingSession.timerAction = null;
    AppStorage.setOrCreate('globalTtsActive', false);
    AppStorage.setOrCreate('globalTtsPaused', false);
    AppStorage.setOrCreate('globalTtsBookUrl', '');
    AppStorage.setOrCreate('globalTtsBookName', '');
    AppStorage.setOrCreate('globalTtsChapterTitle', '');
    AppStorage.setOrCreate<ResourceStr>('globalTtsCover', '');
    AppStorage.setOrCreate<ResourceStr>('globalTtsCoverFrame', '');
    AppStorage.setOrCreate('globalTtsContent', '');
    AppStorage.setOrCreate('globalTtsChapterProgress', '');
    AppStorage.setOrCreate('globalTtsSpeed', 1);
    AppStorage.setOrCreate('globalTtsTimerMinutes', 0);
    AppStorage.setOrCreate('globalTtsTimerRemainingSeconds', 0);
    AppStorage.setOrCreate('globalTtsCanPrevious', false);
    AppStorage.setOrCreate('globalTtsCanNext', false);
    ReaderTtsFloatingSession.notifyChanged();
  }

  private static notifyChanged(): void {
    const revision = AppStorage.get<number>('globalTtsRevision') || 0;
    AppStorage.setOrCreate('globalTtsRevision', revision + 1);
  }
}
