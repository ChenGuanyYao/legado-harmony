import { audio } from '@kit.AudioKit';
import { media } from '@kit.MediaKit';
import fs from '@ohos.file.fs';

export class TtsAvAudioPlayer {
  private player: media.AVPlayer | null = null;
  private sourceFile: fs.File | null = null;
  private playGeneration: number = 0;

  async play(filePath: string, speed: number = 1,
    onPlaybackStart?: (durationMs: number) => void): Promise<void> {
    const generation = ++this.playGeneration;
    await this.releaseCurrent();
    const player = await media.createAVPlayer();
    this.player = player;
    const sourceFile = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
    this.sourceFile = sourceFile;
    const normalizedSpeed = Math.max(0.125, Math.min(4, speed || 1));
    const initialized = this.waitForInitialized(player, generation);
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
          if (state === 'completed' || state === 'stopped' || state === 'released') {
            resolve();
          }
        });
        player.on('error', (error: Error) => {
          if (generation === this.playGeneration) {
            reject(error);
          } else {
            resolve();
          }
        });
      });
      try {
        player.setPlaybackRate(normalizedSpeed);
      } catch (_) {
        this.setDiscreteSpeed(player, normalizedSpeed);
      }
      await player.play();
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
    }
  }

  stop(): void {
    this.playGeneration++;
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

  debugState(): string {
    return this.player ? `avPlayer=${this.player.state},generation=${this.playGeneration}` : 'avPlayer=none';
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
