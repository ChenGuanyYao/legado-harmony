import { audio } from '@kit.AudioKit';

export class TtsAudioSession {
  private static manager: audio.AudioSessionManager | null = null;
  private static owners: Set<string> = new Set<string>();
  private static activationPromise: Promise<void> | null = null;
  private static deactivateTimerId: number = -1;

  static async acquire(owner: string): Promise<void> {
    if (!owner) return;
    TtsAudioSession.owners.add(owner);
    TtsAudioSession.cancelPendingDeactivate();
    const manager = TtsAudioSession.getManager();
    if (!manager) return;
    try {
      if (manager.isAudioSessionActivated()) return;
    } catch (_) {
    }
    if (!TtsAudioSession.activationPromise) {
      const strategy: audio.AudioSessionStrategy = {
        concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_PAUSE_OTHERS
      };
      const activation = manager.activateAudioSession(strategy);
      TtsAudioSession.activationPromise = activation;
      activation.then(() => {
        console.info('[TTS] audio session activated: mode=PAUSE_OTHERS');
      }).catch((error: Error) => {
        console.warn('[TTS] activate audio session failed:', error);
      }).finally(() => {
        if (TtsAudioSession.activationPromise === activation) {
          TtsAudioSession.activationPromise = null;
        }
      });
    }
    await TtsAudioSession.activationPromise?.catch(() => {
    });
  }

  static release(owner: string): void {
    if (!owner) return;
    TtsAudioSession.owners.delete(owner);
    if (TtsAudioSession.owners.size > 0) return;
    TtsAudioSession.cancelPendingDeactivate();
    TtsAudioSession.deactivateTimerId = setTimeout(() => {
      TtsAudioSession.deactivateTimerId = -1;
      TtsAudioSession.deactivateIfIdle();
    }, 300);
  }

  private static getManager(): audio.AudioSessionManager | null {
    if (TtsAudioSession.manager) return TtsAudioSession.manager;
    try {
      TtsAudioSession.manager = audio.getAudioManager().getSessionManager();
    } catch (error) {
      console.warn('[TTS] get audio session manager failed:', error);
    }
    return TtsAudioSession.manager;
  }

  private static cancelPendingDeactivate(): void {
    if (TtsAudioSession.deactivateTimerId < 0) return;
    clearTimeout(TtsAudioSession.deactivateTimerId);
    TtsAudioSession.deactivateTimerId = -1;
  }

  private static deactivateIfIdle(): void {
    if (TtsAudioSession.owners.size > 0) return;
    const manager = TtsAudioSession.getManager();
    if (!manager) return;
    const deactivate = (): void => {
      if (TtsAudioSession.owners.size > 0) return;
      try {
        if (!manager.isAudioSessionActivated()) return;
      } catch (_) {
      }
      manager.deactivateAudioSession().then(() => {
        console.info('[TTS] audio session deactivated');
      }).catch((error: Error) => {
        console.warn('[TTS] deactivate audio session failed:', error);
      });
    };
    if (TtsAudioSession.activationPromise) {
      TtsAudioSession.activationPromise.finally(deactivate);
      return;
    }
    deactivate();
  }
}
