import { audio } from '@kit.AudioKit';

interface PcmPlaybackMark {
  frame: number;
  callback: () => void;
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
  private armedMark: PcmPlaybackMark | null = null;
  private armedMarkCallback: ((frame: number) => void) | null = null;

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
    this.writeChain = this.writeChain
      .then(async () => {
        if (generation !== this.playGeneration) {
          return;
        }
        const renderer = await this.ensureRenderer(normalizedSampleRate);
        if (generation !== this.playGeneration) {
          return;
        }
        if (renderer.state !== audio.AudioState.STATE_RUNNING) {
          await renderer.start();
        }
        if (generation !== this.playGeneration) {
          return;
        }
        this.armNextPlaybackMark(renderer, generation);
        await this.writeAll(renderer, audioData, generation);
      })
      .catch((error: Error) => {
        console.warn('[TTS] write pcm audio failed:', error);
      });
    return this.writeChain;
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
    const renderer = this.renderer;
    const generation = this.playGeneration;
    if (!renderer || generation !== this.playGeneration ||
      renderer.state !== audio.AudioState.STATE_RUNNING) {
      return;
    }
    await renderer.drain();
  }

  stop(): void {
    this.playGeneration++;
    this.writeChain = Promise.resolve();
    const renderer = this.renderer;
    this.clearPlaybackTimeline(renderer);
    this.renderer = null;
    if (!renderer) {
      return;
    }
    this.releaseRenderer(renderer);
  }

  release(): void {
    this.stop();
  }

  debugState(): string {
    if (!this.renderer) {
      return `renderer=none,queuedFrames=${this.queuedFrames},marks=${this.playbackMarks.length}`;
    }
    return `renderer=${this.audioStateName(this.renderer.state)},sampleRate=${this.currentSampleRate},` +
      `generation=${this.playGeneration},queuedFrames=${this.queuedFrames},marks=${this.playbackMarks.length}`;
  }

  private async writeAll(renderer: audio.AudioRenderer, data: ArrayBuffer, generation: number): Promise<void> {
    let offset = 0;
    while (offset < data.byteLength && generation === this.playGeneration) {
      const remaining = offset === 0 ? data : data.slice(offset);
      const written = await renderer.write(remaining);
      if (written <= 0) {
        throw new Error('PCM播放器未写入音频数据');
      }
      offset += written;
    }
  }

  private armNextPlaybackMark(renderer: audio.AudioRenderer, generation: number): void {
    if (generation !== this.playGeneration || this.armedMark || this.playbackMarks.length === 0) {
      return;
    }
    const mark = this.playbackMarks.shift() as PcmPlaybackMark;
    if (mark.frame <= 0) {
      this.invokePlaybackMark(mark, generation);
      this.armNextPlaybackMark(renderer, generation);
      return;
    }
    const callback = (): void => {
      if (generation !== this.playGeneration) {
        return;
      }
      try {
        renderer.off('markReach', callback);
      } catch (_) {
      }
      this.armedMark = null;
      this.armedMarkCallback = null;
      this.invokePlaybackMark(mark, generation);
      this.armNextPlaybackMark(renderer, generation);
    };
    this.armedMark = mark;
    this.armedMarkCallback = callback;
    try {
      renderer.on('markReach', mark.frame, callback);
    } catch (error) {
      console.warn(`[TTS] register pcm playback mark failed: frame=${mark.frame}`, error);
      this.armedMark = null;
      this.armedMarkCallback = null;
      this.invokePlaybackMark(mark, generation);
      this.armNextPlaybackMark(renderer, generation);
    }
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
    if (renderer && this.armedMarkCallback) {
      try {
        renderer.off('markReach', this.armedMarkCallback);
      } catch (_) {
      }
    }
    this.queuedFrames = 0;
    this.queuedSampleRate = 0;
    this.playbackMarks = [];
    this.armedMark = null;
    this.armedMarkCallback = null;
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
    this.renderer = null;
    if (previousRenderer) {
      await this.releaseRenderer(previousRenderer);
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
    this.renderer = await audio.createAudioRenderer(options);
    console.info(`[TTS] audio renderer created: ${this.debugState()}`);
    return this.renderer;
  }

  private async releaseRenderer(renderer: audio.AudioRenderer): Promise<void> {
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
