import { audio } from '@kit.AudioKit';
import { media } from '@kit.MediaKit';
import fs from '@ohos.file.fs';
import { TtsAudioSession } from './TtsAudioSession';

export class TtsAvAudioPlayer {
  private readonly audioSessionOwnerPrefix: string = `tts_av_${Date.now()}_${Math.random()}`;
  private activeAudioSessionOwner: string = '';
  private player: media.AVPlayer | null = null;
  private sourceFile: fs.File | null = null;
  private playGeneration: number = 0;
  private paused: boolean = false;
  private interruptPaused: boolean = false;
  private resumeWaiters: Array<() => void> = [];

  async play(filePath: string, speed: number = 1,
    onPlaybackStart?: (durationMs: number) => void): Promise<void> {
    const generation = ++this.playGeneration;
    this.interruptPaused = false;
    await this.releaseCurrent();
    const player = await media.createAVPlayer();
    this.player = player;
    const sourceFile = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
    this.sourceFile = sourceFile;
    const normalizedSpeed = Math.max(0.125, Math.min(4, speed || 1));
    const initialized = this.waitForInitialized(player, generation);
    const audioSessionOwner = `${this.audioSessionOwnerPrefix}_${generation}`;
    try {
      player.fdSrc = { fd: sourceFile.fd };
      await initialized;
      if (generation !== this.playGeneration) {
        return;
      }
      player.audioRendererInfo = {
        content: audio.ContentType.CONTENT_TYPE_SPEECH,
        usage: audio.StreamUsage.STREAM_USAGE_AUDIOBOOK,
        rendererFlags: 0
      };
      await player.prepare();
      if (generation !== this.playGeneration) {
        return;
      }
      const ended = new Promise<void>((resolve, reject) => {
        player.on('stateChange', (state: string) => {
          if (generation !== this.playGeneration) {
            resolve();
            return;
          }
          if (state === 'completed') {
            resolve();
          } else if (state === 'stopped' || state === 'released') {
            reject(new Error(`音频播放被中断：${state}`));
          }
        });
        player.on('error', (error: Error) => {
          if (generation === this.playGeneration) {
            reject(error);
          } else {
            resolve();
          }
        });
        player.on('audioInterrupt', (event: audio.InterruptEvent): void => {
          this.handleAudioInterrupt(player, generation, event);
        });
      });
      try {
        player.setPlaybackRate(normalizedSpeed);
      } catch (_) {
        this.setDiscreteSpeed(player, normalizedSpeed);
      }
      await this.waitUntilResumed();
      if (generation !== this.playGeneration) {
        return;
      }
      await TtsAudioSession.acquire(audioSessionOwner);
      if (generation !== this.playGeneration) {
        TtsAudioSession.release(audioSessionOwner);
        return;
      }
      this.activeAudioSessionOwner = audioSessionOwner;
      player.setVolume(1);
      if (player.state !== 'playing') {
        await player.play();
      }
      if (this.paused && player.state === 'playing') {
        await player.pause();
      }
      if (onPlaybackStart) {
        try {
          const sourceDuration = player.duration;
          const playbackDuration = sourceDuration > 0 ? sourceDuration / normalizedSpeed : 0;
          onPlaybackStart(playbackDuration);
        } catch (error) {
          console.warn('[TTS] report av audio duration failed:', error);
          onPlaybackStart(0);
        }
      }
      await ended;
    } finally {
      if (this.player === player) {
        this.player = null;
      }
      if (this.sourceFile === sourceFile) {
        this.sourceFile = null;
      }
      await this.releasePlayer(player);
      this.closeFile(sourceFile);
      TtsAudioSession.release(audioSessionOwner);
      if (this.activeAudioSessionOwner === audioSessionOwner) {
        this.activeAudioSessionOwner = '';
      }
    }
  }

  stop(): void {
    this.playGeneration++;
    this.paused = false;
    this.interruptPaused = false;
    this.resolveResumeWaiters();
    TtsAudioSession.release(this.activeAudioSessionOwner);
    this.activeAudioSessionOwner = '';
    const player = this.player;
    const sourceFile = this.sourceFile;
    this.player = null;
    this.sourceFile = null;
    if (player) {
      this.releasePlayer(player).finally(() => {
        this.closeFile(sourceFile);
      });
    } else {
      this.closeFile(sourceFile);
    }
  }

  release(): void {
    this.stop();
  }

  async pause(): Promise<void> {
    if (this.paused) {
      return;
    }
    this.paused = true;
    const player = this.player;
    if (player && player.state === 'playing') {
      await player.pause();
    }
  }

  async resume(): Promise<void> {
    if (!this.paused) {
      return;
    }
    this.paused = false;
    const player = this.player;
    if (player && player.state === 'paused') {
      await TtsAudioSession.acquire(this.activeAudioSessionOwner);
      player.setVolume(1);
      await player.play();
    }
    this.resolveResumeWaiters();
  }

  isPaused(): boolean {
    return this.paused;
  }

  debugState(): string {
    return this.player ? `avPlayer=${this.player.state},paused=${this.paused},generation=${this.playGeneration}` :
      `avPlayer=none,paused=${this.paused}`;
  }

  private waitUntilResumed(): Promise<void> {
    if (!this.paused) {
      return Promise.resolve();
    }
    return new Promise<void>((resolve: () => void) => {
      this.resumeWaiters.push(resolve);
    });
  }

  private resolveResumeWaiters(): void {
    const waiters = this.resumeWaiters.splice(0, this.resumeWaiters.length);
    for (const resolve of waiters) {
      resolve();
    }
  }

  private setDiscreteSpeed(player: media.AVPlayer, speed: number): void {
    try {
      if (speed <= 0.8) {
        player.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_0_75_X);
      } else if (speed <= 1.2) {
        player.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_1_00_X);
      } else if (speed <= 1.75) {
        player.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_1_25_X);
      } else {
        player.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_2_00_X);
      }
    } catch (_) {
    }
  }

  private handleAudioInterrupt(player: media.AVPlayer, generation: number,
    event: audio.InterruptEvent): void {
    if (generation !== this.playGeneration || player !== this.player) return;
    console.info(`[TTS] av audio interrupt: hint=${event.hintType},force=${event.forceType},` +
      `state=${player.state},generation=${generation}`);
    const hint = event.hintType;
    if (hint === audio.InterruptHint.INTERRUPT_HINT_DUCK) {
      if (event.forceType === audio.InterruptForceType.INTERRUPT_SHARE) {
        try { player.setVolume(0.35); } catch (_) {}
      }
      return;
    }
    if (hint === audio.InterruptHint.INTERRUPT_HINT_UNDUCK) {
      try { player.setVolume(1); } catch (_) {}
      return;
    }
    if (hint === audio.InterruptHint.INTERRUPT_HINT_PAUSE) {
      this.interruptPaused = true;
      if (event.forceType === audio.InterruptForceType.INTERRUPT_SHARE && player.state === 'playing') {
        player.pause().catch(() => {});
      }
      return;
    }
    if (hint === audio.InterruptHint.INTERRUPT_HINT_STOP) {
      this.interruptPaused = false;
      return;
    }
    if (hint === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
      try { player.setVolume(1); } catch (_) {}
      if (this.interruptPaused && !this.paused &&
        (player.state === 'paused' || player.state === 'prepared')) {
        this.interruptPaused = false;
        player.play().catch(() => {});
      } else {
        this.interruptPaused = false;
      }
    }
  }

  private async releaseCurrent(): Promise<void> {
    const player = this.player;
    const sourceFile = this.sourceFile;
    this.player = null;
    this.sourceFile = null;
    if (player) {
      await this.releasePlayer(player);
    }
    this.closeFile(sourceFile);
  }

  private waitForInitialized(player: media.AVPlayer, generation: number): Promise<void> {
    if (player.state === 'initialized') {
      return Promise.resolve();
    }
    return new Promise<void>((resolve, reject) => {
      const timeoutId = setTimeout(() => {
        reject(new Error('音频播放器初始化超时'));
      }, 5000);
      player.on('stateChange', (state: string) => {
        if (generation !== this.playGeneration) {
          clearTimeout(timeoutId);
          resolve();
          return;
        }
        if (state === 'initialized') {
          clearTimeout(timeoutId);
          resolve();
        } else if (state === 'released' || state === 'error') {
          clearTimeout(timeoutId);
          reject(new Error(`音频播放器初始化失败：${state}`));
        }
      });
      player.on('error', (error: Error) => {
        clearTimeout(timeoutId);
        reject(error);
      });
    });
  }

  private async releasePlayer(player: media.AVPlayer): Promise<void> {
    try {
      if (player.state === 'playing' || player.state === 'paused' || player.state === 'prepared' ||
        player.state === 'completed') {
        await player.stop();
      }
    } catch (_) {
    }
    try {
      await player.release();
    } catch (_) {
    }
  }

  private closeFile(file: fs.File | null): void {
    if (!file) {
      return;
    }
    try {
      fs.closeSync(file);
    } catch (_) {
    }
  }
}
