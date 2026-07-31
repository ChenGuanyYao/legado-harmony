import { audio } from '@kit.AudioKit';
import deviceInfo from '@ohos.deviceInfo';

interface PcmPlaybackMark {
  frame: number;
  callback: () => void;
}

interface PendingPcmWrite {
  data: Uint8Array;
  offset: number;
  generation: number;
  resolve: () => void;
}

export interface PcmPlaybackCue {
  frameOffset: number;
  callback: () => void;
}

export class TtsPcmAudioPlayer {
  private renderer: audio.AudioRenderer | null = null;
  private currentSampleRate: audio.AudioSamplingRate = audio.AudioSamplingRate.SAMPLE_RATE_16000;
  private playGeneration: number = 0;
  private writeChain: Promise<void> = Promise.resolve();
  private queuedFrames: number = 0;
  private queuedSampleRate: number = 0;
  private playbackMarks: PcmPlaybackMark[] = [];
  private timelineBaseFrame: number = 0;
  private timelineStartedAt: number = 0;
  private timelineTimerId: number = -1;
  private lastReachedFrame: number = 0;
  private rendererFrameOrigin: number = -1;
  private rendererLogicalFrameOrigin: number = 0;
  private timestampFailureLogged: boolean = false;
  private progressMode: string = 'CLOCK_FALLBACK';
  private rendererStartPromise: Promise<void> | null = null;
  private rendererWriteCallback: audio.AudioRendererWriteDataCallback | null = null;
  private pendingWrites: PendingPcmWrite[] = [];
  private pendingWriteBytes: number = 0;
  private paused: boolean = false;
  private resumeWaiters: Array<() => void> = [];

  async play(data: ArrayBuffer, sampleRate: number): Promise<void> {
    await this.write(data, sampleRate);
    await this.drain();
  }

  write(data: ArrayBuffer, sampleRate: number): Promise<void> {
    return this.enqueueWrite(data, sampleRate);
  }

  writeSegment(data: ArrayBuffer, sampleRate: number, onPlaybackStart: () => void): Promise<void> {
    return this.enqueueWrite(data, sampleRate, [{
      frameOffset: 0,
      callback: onPlaybackStart
    }]);
  }

  writeTimedSegment(data: ArrayBuffer, sampleRate: number, cues: PcmPlaybackCue[]): Promise<void> {
    return this.enqueueWrite(data, sampleRate, cues);
  }

  private enqueueWrite(data: ArrayBuffer, sampleRate: number,
    cues?: PcmPlaybackCue[]): Promise<void> {
    if (!data || data.byteLength === 0) {
      return this.writeChain;
    }
    const normalizedSampleRate = Math.max(1, Math.round(sampleRate || 16000));
    if (this.queuedSampleRate > 0 && this.queuedSampleRate !== normalizedSampleRate) {
      console.info(`[TTS] pcm sample rate changed: ${this.queuedSampleRate} -> ${normalizedSampleRate}`);
      this.stop();
    }
    const audioData = data.slice(0);
    const generation = this.playGeneration;
    if (this.queuedSampleRate === 0) {
      this.queuedSampleRate = normalizedSampleRate;
    }
    const startFrame = this.queuedFrames;
    const segmentFrames = Math.floor(audioData.byteLength / 2);
    this.queuedFrames += segmentFrames;
    if (cues && cues.length > 0) {
      const sortedCues = cues.slice().sort((left: PcmPlaybackCue, right: PcmPlaybackCue) =>
        left.frameOffset - right.frameOffset);
      for (const cue of sortedCues) {
        const frameOffset = Math.max(0, Math.min(
          Math.max(0, segmentFrames - 1),
          Math.round(cue.frameOffset)
        ));
        this.queuePlaybackMark(startFrame + frameOffset, cue.callback);
      }
    }
    let resolveWrite: () => void = () => {
    };
    const consumedPromise = new Promise<void>((resolve: () => void) => {
      resolveWrite = resolve;
    });
    const pendingWrite: PendingPcmWrite = {
      data: new Uint8Array(audioData),
      offset: 0,
      generation: generation,
      resolve: resolveWrite
    };
    this.pendingWrites.push(pendingWrite);
    this.pendingWriteBytes += audioData.byteLength;
    const completionPromise = this.ensureRendererStarted(normalizedSampleRate, generation)
      .then(() => consumedPromise)
      .catch((error: Error) => {
        this.discardPendingWrite(pendingWrite);
        console.warn('[TTS] write pcm audio failed:', error);
      });
    const previousWrites = this.writeChain;
    this.writeChain = Promise.all([
      previousWrites.catch((_error: Error) => {
      }),
      completionPromise
    ]).then(() => {
    });
    return completionPromise;
  }

  private queuePlaybackMark(frame: number, callback: () => void): void {
    const last = this.playbackMarks.length > 0 ?
      this.playbackMarks[this.playbackMarks.length - 1] : undefined;
    if (last && last.frame === frame) {
      const previousCallback = last.callback;
      last.callback = () => {
        previousCallback();
        callback();
      };
      return;
    }
    this.playbackMarks.push({ frame, callback });
  }

  async drain(): Promise<void> {
    await this.writeChain;
    await this.waitUntilResumed();
    const renderer = this.renderer;
    const generation = this.playGeneration;
    if (!renderer || generation !== this.playGeneration ||
      renderer.state !== audio.AudioState.STATE_RUNNING) {
      return;
    }
    await renderer.drain();
    if (generation === this.playGeneration) {
      this.lastReachedFrame = Math.max(this.lastReachedFrame, this.queuedFrames);
      this.dispatchDuePlaybackMarks(generation);
      this.pausePlaybackTimelineAt(this.queuedFrames);
    }
  }

  async pause(): Promise<void> {
    if (this.paused) {
      return;
    }
    this.paused = true;
    const renderer = this.renderer;
    const generation = this.playGeneration;
    if (!renderer || renderer.state !== audio.AudioState.STATE_RUNNING) {
      return;
    }
    this.updatePlaybackTimeline(generation);
    try {
      await renderer.pause();
    } catch (error) {
      console.warn('[TTS] pause pcm renderer failed:', error);
    }
    if (generation === this.playGeneration) {
      this.pausePlaybackTimelineAt(this.lastReachedFrame);
      this.rendererFrameOrigin = -1;
      this.rendererLogicalFrameOrigin = this.lastReachedFrame;
    }
  }

  async resume(): Promise<void> {
    if (!this.paused) {
      return;
    }
    this.paused = false;
    const renderer = this.renderer;
    const generation = this.playGeneration;
    if (renderer && renderer.state === audio.AudioState.STATE_PAUSED) {
      let rendererResumed = false;
      try {
        await renderer.start();
        rendererResumed = true;
      } catch (error) {
        console.warn('[TTS] resume pcm renderer failed:', error);
      }
      if (generation === this.playGeneration && rendererResumed) {
        this.rendererFrameOrigin = -1;
        this.rendererLogicalFrameOrigin = this.lastReachedFrame;
        this.timelineBaseFrame = this.lastReachedFrame;
        this.timelineStartedAt = Date.now();
        this.updatePlaybackTimeline(generation);
      }
    }
    this.resolveResumeWaiters();
  }

  isPaused(): boolean {
    return this.paused;
  }

  stop(): void {
    this.playGeneration++;
    this.paused = false;
    this.resolveResumeWaiters();
    this.writeChain = Promise.resolve();
    this.rendererStartPromise = null;
    this.resolvePendingWrites();
    const renderer = this.renderer;
    const writeCallback = this.rendererWriteCallback;
    this.rendererWriteCallback = null;
    this.clearPlaybackTimeline(renderer);
    this.renderer = null;
    if (!renderer) {
      return;
    }
    this.releaseRenderer(renderer, writeCallback);
  }

  release(): void {
    this.stop();
  }

  debugState(): string {
    if (!this.renderer) {
      return `renderer=none,paused=${this.paused},queuedFrames=${this.queuedFrames},marks=${this.playbackMarks.length},` +
        `pendingBytes=${this.pendingWriteBytes},progress=${this.progressMode}`;
    }
    return `renderer=${this.audioStateName(this.renderer.state)},paused=${this.paused},sampleRate=${this.currentSampleRate},` +
      `generation=${this.playGeneration},queuedFrames=${this.queuedFrames},marks=${this.playbackMarks.length},` +
      `pendingBytes=${this.pendingWriteBytes},progress=${this.progressMode}`;
  }

  private async ensureRendererStarted(sampleRate: number, generation: number): Promise<void> {
    if (generation !== this.playGeneration) {
      return;
    }
    if (!this.rendererStartPromise) {
      const startPromise = this.startRenderer(sampleRate, generation);
      this.rendererStartPromise = startPromise;
      startPromise.then(() => {
        if (this.rendererStartPromise === startPromise) {
          this.rendererStartPromise = null;
        }
      }).catch((_error: Error) => {
        if (this.rendererStartPromise === startPromise) {
          this.rendererStartPromise = null;
        }
      });
    }
    await this.rendererStartPromise;
  }

  private async startRenderer(sampleRate: number, generation: number): Promise<void> {
    const renderer = await this.ensureRenderer(sampleRate);
    if (generation !== this.playGeneration) {
      await this.releaseStaleRenderer(renderer);
      return;
    }
    if (!this.paused && renderer.state !== audio.AudioState.STATE_RUNNING) {
      await renderer.start();
    }
    if (generation !== this.playGeneration) {
      await this.releaseStaleRenderer(renderer);
      return;
    }
    if (!this.paused) {
      this.ensurePlaybackTimeline(sampleRate, generation);
    }
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

  private async releaseStaleRenderer(renderer: audio.AudioRenderer): Promise<void> {
    let writeCallback: audio.AudioRendererWriteDataCallback | null = null;
    if (this.renderer === renderer) {
      this.renderer = null;
      writeCallback = this.rendererWriteCallback;
      this.rendererWriteCallback = null;
    }
    await this.releaseRenderer(renderer, writeCallback);
  }

  private ensurePlaybackTimeline(sampleRate: number, generation: number): void {
    if (generation !== this.playGeneration) {
      return;
    }
    if (this.timelineStartedAt <= 0) {
      this.timelineBaseFrame = this.lastReachedFrame;
      this.timelineStartedAt = Date.now();
      console.info(`[TTS] pcm playback clock started: frame=${this.timelineBaseFrame},` +
        `sampleRate=${sampleRate}`);
    }
    this.updatePlaybackTimeline(generation);
  }

  private dispatchDuePlaybackMarks(generation: number): void {
    if (generation !== this.playGeneration) {
      return;
    }
    while (this.playbackMarks.length > 0 &&
      this.playbackMarks[0].frame <= this.lastReachedFrame) {
      const mark = this.playbackMarks.shift() as PcmPlaybackMark;
      console.info(`[TTS] pcm playback cue reached: frame=${mark.frame},rendered=${this.lastReachedFrame}`);
      this.invokePlaybackMark(mark, generation);
    }
  }

  private updatePlaybackTimeline(generation: number): void {
    if (generation !== this.playGeneration || this.timelineStartedAt <= 0) {
      return;
    }
    this.clearPlaybackTimelineTimer();
    const sampleRate = Math.max(1, this.queuedSampleRate || Number(this.currentSampleRate) || 16000);
    const elapsedMs = Math.max(0, Date.now() - this.timelineStartedAt);
    const clockFrame = this.timelineBaseFrame + Math.round(elapsedMs * sampleRate / 1000);
    let reachedFrame = clockFrame;
    const renderer = this.renderer;
    if (deviceInfo.sdkApiVersion >= 19 && renderer &&
      renderer.state === audio.AudioState.STATE_RUNNING) {
      try {
        const timestamp = renderer.getAudioTimestampInfoSync();
        const rendererFrame = Math.max(0, Math.round(timestamp.framePos));
        if (this.rendererFrameOrigin < 0) {
          this.rendererFrameOrigin = rendererFrame;
          this.rendererLogicalFrameOrigin = Math.max(this.lastReachedFrame, clockFrame);
          console.info(`[TTS] pcm frame timestamp started: rendererFrame=${rendererFrame},` +
            `logicalFrame=${this.rendererLogicalFrameOrigin},api=${deviceInfo.sdkApiVersion}`);
        }
        reachedFrame = this.rendererLogicalFrameOrigin +
          Math.max(0, rendererFrame - this.rendererFrameOrigin);
        this.progressMode = 'FRAME_TIMESTAMP';
        this.timestampFailureLogged = false;
        this.timelineBaseFrame = Math.max(this.lastReachedFrame, reachedFrame);
        this.timelineStartedAt = Date.now();
      } catch (error) {
        this.progressMode = 'CLOCK_FALLBACK';
        if (!this.timestampFailureLogged) {
          this.timestampFailureLogged = true;
          console.warn(`[TTS] frame timestamp unavailable, using clock fallback: ` +
            `api=${deviceInfo.sdkApiVersion}`, error);
        }
      }
    } else {
      this.progressMode = 'CLOCK_FALLBACK';
    }
    this.lastReachedFrame = Math.max(this.lastReachedFrame,
      Math.min(this.queuedFrames, reachedFrame));
    this.dispatchDuePlaybackMarks(generation);
    if (this.lastReachedFrame >= this.queuedFrames) {
      this.pausePlaybackTimelineAt(this.queuedFrames);
      return;
    }
    this.timelineTimerId = setTimeout(() => {
      this.timelineTimerId = -1;
      if (generation !== this.playGeneration) {
        return;
      }
      this.updatePlaybackTimeline(generation);
    }, 50);
  }

  private pausePlaybackTimelineAt(frame: number): void {
    this.clearPlaybackTimelineTimer();
    this.lastReachedFrame = Math.max(this.lastReachedFrame, frame);
    this.timelineBaseFrame = this.lastReachedFrame;
    this.timelineStartedAt = 0;
  }

  private invokePlaybackMark(mark: PcmPlaybackMark, generation: number): void {
    if (generation !== this.playGeneration) {
      return;
    }
    try {
      mark.callback();
    } catch (error) {
      console.warn('[TTS] pcm playback mark callback failed:', error);
    }
  }

  private clearPlaybackTimeline(renderer: audio.AudioRenderer | null): void {
    this.clearPlaybackTimelineTimer();
    this.queuedFrames = 0;
    this.queuedSampleRate = 0;
    this.playbackMarks = [];
    this.timelineBaseFrame = 0;
    this.timelineStartedAt = 0;
    this.lastReachedFrame = 0;
    this.rendererFrameOrigin = -1;
    this.rendererLogicalFrameOrigin = 0;
    this.timestampFailureLogged = false;
    this.progressMode = 'CLOCK_FALLBACK';
  }

  private clearPlaybackTimelineTimer(): void {
    if (this.timelineTimerId < 0) {
      return;
    }
    clearTimeout(this.timelineTimerId);
    this.timelineTimerId = -1;
  }

  private audioStateName(state: audio.AudioState): string {
    switch (state) {
      case audio.AudioState.STATE_RUNNING:
        return 'STATE_RUNNING';
      case audio.AudioState.STATE_STOPPED:
        return 'STATE_STOPPED';
      case audio.AudioState.STATE_RELEASED:
        return 'STATE_RELEASED';
      case audio.AudioState.STATE_PAUSED:
        return 'STATE_PAUSED';
      default:
        return `STATE_${state}`;
    }
  }

  private async ensureRenderer(sampleRate: number): Promise<audio.AudioRenderer> {
    const nextSampleRate = this.toAudioSampleRate(sampleRate);
    if (this.renderer && this.currentSampleRate === nextSampleRate &&
      this.renderer.state !== audio.AudioState.STATE_RELEASED &&
      this.renderer.state !== audio.AudioState.STATE_STOPPED) {
      return this.renderer;
    }
    const previousRenderer = this.renderer;
    const previousWriteCallback = this.rendererWriteCallback;
    this.renderer = null;
    this.rendererWriteCallback = null;
    if (previousRenderer) {
      await this.releaseRenderer(previousRenderer, previousWriteCallback);
    }
    this.currentSampleRate = nextSampleRate;
    const options: audio.AudioRendererOptions = {
      streamInfo: {
        samplingRate: nextSampleRate,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
        channelLayout: audio.AudioChannelLayout.CH_LAYOUT_MONO
      },
      rendererInfo: {
        content: audio.ContentType.CONTENT_TYPE_SPEECH,
        usage: audio.StreamUsage.STREAM_USAGE_AUDIOBOOK,
        rendererFlags: 0
      }
    };
    const renderer = await audio.createAudioRenderer(options);
    const writeCallback: audio.AudioRendererWriteDataCallback = (data: ArrayBuffer):
      audio.AudioDataCallbackResult => {
      return this.handleRendererWriteData(data);
    };
    renderer.on('writeData', writeCallback);
    this.rendererWriteCallback = writeCallback;
    this.renderer = renderer;
    console.info(`[TTS] audio renderer created: ${this.debugState()}`);
    return renderer;
  }

  private async releaseRenderer(renderer: audio.AudioRenderer,
    writeCallback: audio.AudioRendererWriteDataCallback | null): Promise<void> {
    if (writeCallback) {
      try {
        renderer.off('writeData', writeCallback);
      } catch (error) {
        console.warn('[TTS] unregister pcm write callback failed:', error);
      }
    }
    try {
      if (renderer.state === audio.AudioState.STATE_RUNNING ||
        renderer.state === audio.AudioState.STATE_PAUSED) {
        await renderer.stop();
      }
    } catch (error) {
      console.warn('[TTS] stop pcm renderer failed:', error);
    }
    try {
      if (renderer.state !== audio.AudioState.STATE_RELEASED) {
        await renderer.release();
      }
    } catch (error) {
      console.warn('[TTS] release pcm renderer failed:', error);
    }
  }

  private handleRendererWriteData(data: ArrayBuffer): audio.AudioDataCallbackResult {
    if (!data || data.byteLength === 0 || this.pendingWrites.length === 0) {
      return audio.AudioDataCallbackResult.INVALID;
    }
    const output = new Uint8Array(data);
    let outputOffset = 0;
    while (outputOffset < output.length && this.pendingWrites.length > 0) {
      const pending = this.pendingWrites[0];
      if (pending.generation !== this.playGeneration) {
        this.pendingWrites.shift();
        const abandonedBytes = Math.max(0, pending.data.length - pending.offset);
        this.pendingWriteBytes = Math.max(0, this.pendingWriteBytes - abandonedBytes);
        pending.resolve();
        continue;
      }
      const remaining = pending.data.length - pending.offset;
      const copyLength = Math.min(remaining, output.length - outputOffset);
      output.set(pending.data.subarray(pending.offset, pending.offset + copyLength), outputOffset);
      pending.offset += copyLength;
      outputOffset += copyLength;
      this.pendingWriteBytes = Math.max(0, this.pendingWriteBytes - copyLength);
      if (pending.offset >= pending.data.length) {
        this.pendingWrites.shift();
        pending.resolve();
      }
    }
    if (outputOffset < output.length) {
      output.fill(0, outputOffset);
      const paddingFrames = Math.floor((output.length - outputOffset) / 2);
      this.queuedFrames += paddingFrames;
      console.info(`[TTS] pcm write tail padded: bytes=${output.length - outputOffset},` +
        `frames=${paddingFrames}`);
    }
    return audio.AudioDataCallbackResult.VALID;
  }

  private discardPendingWrite(pendingWrite: PendingPcmWrite): void {
    const index = this.pendingWrites.indexOf(pendingWrite);
    if (index >= 0) {
      this.pendingWrites.splice(index, 1);
      const remaining = Math.max(0, pendingWrite.data.length - pendingWrite.offset);
      this.pendingWriteBytes = Math.max(0, this.pendingWriteBytes - remaining);
    }
    pendingWrite.resolve();
  }

  private resolvePendingWrites(): void {
    const writes = this.pendingWrites.splice(0, this.pendingWrites.length);
    this.pendingWriteBytes = 0;
    for (const pending of writes) {
      pending.resolve();
    }
  }

  private toAudioSampleRate(sampleRate: number): audio.AudioSamplingRate {
    switch (sampleRate) {
      case 8000:
        return audio.AudioSamplingRate.SAMPLE_RATE_8000;
      case 11025:
        return audio.AudioSamplingRate.SAMPLE_RATE_11025;
      case 12000:
        return audio.AudioSamplingRate.SAMPLE_RATE_12000;
      case 22050:
        return audio.AudioSamplingRate.SAMPLE_RATE_22050;
      case 24000:
        return audio.AudioSamplingRate.SAMPLE_RATE_24000;
      case 32000:
        return audio.AudioSamplingRate.SAMPLE_RATE_32000;
      case 44100:
        return audio.AudioSamplingRate.SAMPLE_RATE_44100;
      case 48000:
        return audio.AudioSamplingRate.SAMPLE_RATE_48000;
      case 96000:
        return audio.AudioSamplingRate.SAMPLE_RATE_96000;
      case 16000:
      default:
        return audio.AudioSamplingRate.SAMPLE_RATE_16000;
    }
  }
}
