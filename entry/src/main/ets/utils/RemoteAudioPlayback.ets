import { audio } from '@kit.AudioKit';
import { media } from '@kit.MediaKit';

export interface RemoteAudioPlaybackListener {
  onStateChanged(state: string): void;
  onPositionChanged(positionMs: number, durationMs: number): void;
  onPlaybackCompleted(): void;
  onPlaybackError(message: string): void;
}

/** Process-local remote audiobook player. It keeps playing when the page is temporarily hidden. */
export class RemoteAudioPlayback {
  private static instance: RemoteAudioPlayback | null = null;
  private player: media.AVPlayer | null = null;
  private listener: RemoteAudioPlaybackListener | null = null;
  private generation: number = 0;
  private interruptPaused: boolean = false;
  private sleepTimerId: number = -1;
  private sleepEndAt: number = 0;

  bookUrl: string = '';
  chapterIndex: number = -1;
  mediaUrl: string = '';
  state: string = 'idle';
  positionMs: number = 0;
  durationMs: number = 0;
  speed: number = 1;

  static get(): RemoteAudioPlayback {
    if (!RemoteAudioPlayback.instance) RemoteAudioPlayback.instance = new RemoteAudioPlayback();
    return RemoteAudioPlayback.instance;
  }

  attach(listener: RemoteAudioPlaybackListener): void {
    this.listener = listener;
    listener.onStateChanged(this.state);
    listener.onPositionChanged(this.positionMs, this.durationMs);
  }

  detach(listener: RemoteAudioPlaybackListener): void {
    if (this.listener === listener) this.listener = null;
  }

  matches(bookUrl: string, chapterIndex: number): boolean {
    return !!this.player && this.bookUrl === bookUrl && this.chapterIndex === chapterIndex && !!this.mediaUrl;
  }

  async play(bookUrl: string, chapterIndex: number, url: string, headers: Record<string, string>,
    startPositionMs: number, speed: number): Promise<void> {
    const generation = ++this.generation;
    this.interruptPaused = false;
    await this.releasePlayer();
    this.bookUrl = bookUrl;
    this.chapterIndex = chapterIndex;
    this.mediaUrl = url;
    this.positionMs = Math.max(0, startPositionMs || 0);
    this.durationMs = 0;
    this.speed = this.normalizeSpeed(speed);
    this.setState('loading');

    const player = await media.createAVPlayer();
    if (generation !== this.generation) {
      await player.release();
      return;
    }
    this.player = player;
    player.on('stateChange', (state: string): void => {
      if (generation !== this.generation) return;
      // createAVPlayer starts in idle. While a media source is being attached, keep the public
      // state as loading instead of briefly advertising an idle player that cannot be resumed.
      this.setState(state === 'idle' && !!this.mediaUrl ? 'loading' : state);
      if (state === 'completed') this.listener?.onPlaybackCompleted();
    });
    player.on('timeUpdate', (position: number): void => {
      if (generation !== this.generation) return;
      // Some AVPlayer implementations do not fan out multiple stateChange callbacks reliably.
      // Keep the public state in sync from the player's authoritative state as a fallback.
      this.syncPlayerState(player, generation);
      this.positionMs = Math.max(0, position || 0);
      this.listener?.onPositionChanged(this.positionMs, this.durationMs);
    });
    player.on('durationUpdate', (duration: number): void => {
      if (generation !== this.generation) return;
      this.durationMs = Math.max(0, duration || 0);
      this.listener?.onPositionChanged(this.positionMs, this.durationMs);
    });
    player.on('error', (error: Error): void => {
      if (generation !== this.generation) return;
      this.setState('error');
      this.listener?.onPlaybackError(error.message || String(error));
    });
    player.on('audioInterrupt', (event: audio.InterruptEvent): void => {
      this.handleAudioInterrupt(player, generation, event);
    });

    try {
      const mediaSource = media.createMediaSourceWithUrl(url, headers);
      await player.setMediaSource(mediaSource);
      if (generation !== this.generation) return;
      // setMediaSource() completing does not guarantee that AVPlayer has emitted initialized yet.
      // prepare() is only legal after that transition; calling it while still idle produces
      // "Prepare operation only supports stopped/initialized" on real devices.
      await this.waitForInitialized(player, generation);
      if (generation !== this.generation) return;
      player.audioRendererInfo = {
        content: audio.ContentType.CONTENT_TYPE_SPEECH,
        usage: audio.StreamUsage.STREAM_USAGE_AUDIOBOOK,
        rendererFlags: 0
      };
      await player.prepare();
      if (generation !== this.generation) return;
      this.durationMs = Math.max(0, player.duration || this.durationMs);
      this.applySpeed(player, this.speed);
      if (this.positionMs > 0 && (this.durationMs <= 0 || this.positionMs < this.durationMs - 1000)) {
        player.seek(this.positionMs, media.SeekMode.SEEK_CLOSEST);
      }
      await player.play();
      if (generation === this.generation && player === this.player) this.setState('playing');
    } catch (error) {
      if (generation !== this.generation) return;
      const message = error instanceof Error ? error.message : String(error);
      this.setState('error');
      throw new Error(message);
    }
  }

  async pause(): Promise<void> {
    const player = this.player;
    if (!player || player.state !== 'playing') return;
    await player.pause();
    if (player === this.player) this.setState('paused');
  }

  async resume(): Promise<void> {
    const player = this.player;
    if (!player) return;
    if (player.state === 'paused' || player.state === 'prepared' || player.state === 'completed') {
      if (player.state === 'completed') player.seek(0, media.SeekMode.SEEK_CLOSEST);
      await player.play();
      if (player === this.player) this.setState('playing');
    }
  }

  seek(positionMs: number): void {
    const player = this.player;
    if (!player) return;
    const target = Math.max(0, this.durationMs > 0 ? Math.min(positionMs, this.durationMs) : positionMs);
    this.positionMs = target;
    try {
      player.seek(target, media.SeekMode.SEEK_CLOSEST);
    } catch (_) {}
    this.listener?.onPositionChanged(this.positionMs, this.durationMs);
  }

  setSpeed(speed: number): void {
    this.speed = this.normalizeSpeed(speed);
    const player = this.player;
    if (player) this.applySpeed(player, this.speed);
  }

  setSleepTimer(minutes: number): void {
    this.clearSleepTimer();
    if (minutes <= 0) return;
    this.sleepEndAt = Date.now() + minutes * 60 * 1000;
    this.sleepTimerId = setInterval((): void => {
      if (this.sleepEndAt > Date.now()) return;
      this.clearSleepTimer();
      this.pause().catch(() => {});
    }, 1000);
  }

  sleepRemainingSeconds(): number {
    return this.sleepEndAt > 0 ? Math.max(0, Math.ceil((this.sleepEndAt - Date.now()) / 1000)) : 0;
  }

  async stop(): Promise<void> {
    this.generation++;
    this.interruptPaused = false;
    this.clearSleepTimer();
    await this.releasePlayer();
    this.bookUrl = '';
    this.chapterIndex = -1;
    this.mediaUrl = '';
    this.positionMs = 0;
    this.durationMs = 0;
    this.setState('idle');
  }

  private setState(state: string): void {
    if (this.state === state) return;
    this.state = state || 'idle';
    this.listener?.onStateChanged(this.state);
  }

  private syncPlayerState(player: media.AVPlayer, generation: number): void {
    if (generation !== this.generation || player !== this.player) return;
    const state = player.state || '';
    if (state === 'playing' || state === 'paused' || state === 'completed' || state === 'prepared' ||
      state === 'initialized' || state === 'stopped' || state === 'released' || state === 'error') {
      this.setState(state);
    }
  }

  private normalizeSpeed(speed: number): number {
    return Math.max(0.5, Math.min(2.5, speed || 1));
  }

  private applySpeed(player: media.AVPlayer, speed: number): void {
    try {
      player.setPlaybackRate(speed);
    } catch (_) {
      try {
        if (speed <= 0.8) player.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_0_75_X);
        else if (speed <= 1.15) player.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_1_00_X);
        else if (speed <= 1.6) player.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_1_25_X);
        else player.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_2_00_X);
      } catch (_) {}
    }
  }

  private handleAudioInterrupt(player: media.AVPlayer, generation: number,
    event: audio.InterruptEvent): void {
    if (generation !== this.generation || player !== this.player) return;
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
      if (this.interruptPaused && (player.state === 'paused' || player.state === 'prepared')) {
        this.interruptPaused = false;
        player.play().catch(() => {});
      } else {
        this.interruptPaused = false;
      }
    }
  }

  private async releasePlayer(): Promise<void> {
    const player = this.player;
    this.player = null;
    if (!player) return;
    try {
      if (player.state === 'playing' || player.state === 'paused' || player.state === 'prepared' ||
        player.state === 'completed') await player.stop();
    } catch (_) {}
    try {
      await player.release();
    } catch (_) {}
  }

  private waitForInitialized(player: media.AVPlayer, generation: number): Promise<void> {
    if (generation !== this.generation || player.state === 'initialized' || player.state === 'stopped') {
      return Promise.resolve();
    }
    return new Promise<void>((resolve, reject) => {
      let settled = false;
      const finish = (error?: Error): void => {
        if (settled) return;
        settled = true;
        clearInterval(pollId);
        clearTimeout(timeoutId);
        if (error) reject(error);
        else resolve();
      };
      // Do not register a second stateChange/error callback here. On some HarmonyOS devices
      // AVPlayer keeps only the last callback for an event, which used to replace the public
      // playback-state listener and leave the UI permanently at "loading" while audio played.
      const pollId = setInterval((): void => {
        if (generation !== this.generation || player !== this.player) {
          finish();
          return;
        }
        const state = player.state || '';
        if (state === 'initialized' || state === 'stopped') finish();
        else if (state === 'released' || state === 'error') {
          finish(new Error(`音频播放器初始化失败：${state}`));
        }
      }, 20);
      const timeoutId = setTimeout((): void => {
        finish(new Error(`音频播放器初始化超时，当前状态：${player.state || 'unknown'}`));
      }, 10000);
      // Close the narrow race where initialized is emitted between the first state check and
      // polling registration.
      if (player.state === 'initialized' || player.state === 'stopped') finish();
    });
  }

  private clearSleepTimer(): void {
    if (this.sleepTimerId >= 0) clearInterval(this.sleepTimerId);
    this.sleepTimerId = -1;
    this.sleepEndAt = 0;
  }
}
