import { Buffer } from 'node:buffer';
import { BasicCredentials } from '@huaweicloud/huaweicloud-sdk-core';
import { AKSKSigner } from '@huaweicloud/huaweicloud-sdk-core/auth/AKSKSigner.js';
import {
  PostCustomTTSReq,
  RunTtsRequest,
  SisClient,
  TtsConfig
} from '@huaweicloud/huaweicloud-sdk-sis';
import WebSocket, { RawData } from 'ws';
import { config } from './config.js';

export interface SisSynthesizeInput {
  text: string;
  property: string;
  speed: number;
  pitch: number;
  volume: number;
  wordTimestamps?: boolean;
}

export interface SisSynthesizeResult {
  audio: Buffer;
  traceId: string;
}

export type SisTimingMode = 'WORD' | 'SILENCE_ALIGNED';

export interface SisSpeechTiming {
  startTime: number;
  endTime: number;
  text: string;
  wordIndex: number;
  startOffset: number;
  endOffset: number;
}

export interface SisTimedSynthesizeResult extends SisSynthesizeResult {
  sampleRate: number;
  timingMode: SisTimingMode;
  timings: SisSpeechTiming[];
}

interface SisRttsTiming {
  start_time?: number;
  end_time?: number;
  text?: string;
  word_index?: number;
}

interface SisRttsMessage {
  resp_type?: string;
  trace_id?: string;
  error_code?: string;
  error_msg?: string;
  result?: SisRttsTiming[];
}

interface TextTimelineRange {
  start: number;
  end: number;
}

export class HuaweiSisError extends Error {
  constructor(
    readonly code: string,
    message: string
  ) {
    super(message);
  }
}

const configured = Boolean(
  config.sis.ak
  && config.sis.sk
  && config.sis.projectId
  && config.sis.endpoint
);
const sisOptions = {
  axiosRequestConfig: { timeout: 45_000 }
};

const client = configured
  ? SisClient.newBuilder()
      .withEndpoint(config.sis.endpoint)
      .withCredential(
        new BasicCredentials()
          .withAk(config.sis.ak)
          .withSk(config.sis.sk)
          .withProjectId(config.sis.projectId)
          .withRegionId(config.sis.region)
      )
      .withOptions(sisOptions)
      .build()
  : null;
const rttsCredentials = configured
  ? new BasicCredentials()
      .withAk(config.sis.ak)
      .withSk(config.sis.sk)
      .withProjectId(config.sis.projectId)
      .withRegionId(config.sis.region)
  : null;

export function isHuaweiSisConfigured(): boolean {
  return configured;
}

export async function synthesizeWithHuaweiSis(
  input: SisSynthesizeInput
): Promise<SisSynthesizeResult> {
  if (!client) {
    throw new HuaweiSisError('TTS_NOT_CONFIGURED', '在线朗读服务尚未配置');
  }

  const ttsConfig = new TtsConfig()
    .withAudioFormat('mp3')
    .withSampleRate('16000')
    .withProperty(input.property)
    .withSpeed(input.speed)
    .withPitch(input.pitch)
    .withVolume(input.volume);
  const body = new PostCustomTTSReq(input.text).withConfig(ttsConfig);

  try {
    const response = await client.runTts(new RunTtsRequest().withBody(body));
    const encoded = response.result?.data || '';
    if (
      !encoded
      || encoded.length > 20 * 1024 * 1024
      || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)
    ) {
      throw new HuaweiSisError('SIS_INVALID_RESPONSE', '语音服务返回了无效音频');
    }
    const audio = Buffer.from(encoded, 'base64');
    if (!audio.length || audio.length > 15 * 1024 * 1024) {
      throw new HuaweiSisError('SIS_INVALID_RESPONSE', '语音服务返回了无效音频');
    }
    return {
      audio,
      traceId: response.traceId || ''
    };
  } catch (error) {
    if (error instanceof HuaweiSisError) throw error;
    throw new HuaweiSisError('SIS_SYNTHESIS_FAILED', '在线语音合成失败，请稍后重试');
  }
}

export async function synthesizeTimedWithHuaweiSis(
  input: SisSynthesizeInput
): Promise<SisTimedSynthesizeResult> {
  if (!configured || !rttsCredentials) {
    throw new HuaweiSisError('TTS_NOT_CONFIGURED', '在线朗读服务尚未配置');
  }

  const sampleRate = 16_000;
  const endpoint = config.sis.endpoint
    .replace(/^https:/i, 'wss:')
    .replace(/^http:/i, 'ws:');
  const websocketUrl = `${endpoint}/v1/${encodeURIComponent(config.sis.projectId)}/rtts`;
  const signingUrl = websocketUrl
    .replace(/^wss:/i, 'https:')
    .replace(/^ws:/i, 'http:');
  const signedHeaders = AKSKSigner.sign(
    {
      endpoint: signingUrl,
      method: 'GET',
      headers: {},
      queryParams: {}
    },
    rttsCredentials
  ) as Record<string, string>;
  delete signedHeaders.host;

  return new Promise<SisTimedSynthesizeResult>((resolve, reject) => {
    let settled = false;
    let traceId = '';
    let receivedEnd = false;
    let audioBytes = 0;
    const audioChunks: Buffer[] = [];
    const rawTimings: SisRttsTiming[] = [];
    const socket = new WebSocket(websocketUrl, {
      headers: signedHeaders,
      handshakeTimeout: 10_000
    });
    const timeout = setTimeout(() => {
      fail(new HuaweiSisError('SIS_RTTS_TIMEOUT', '实时语音合成超时'));
    }, 60_000);

    const closeSocket = () => {
      try {
        socket.close(1000);
      } catch {
      }
    };
    const fail = (error: Error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      closeSocket();
      reject(error);
    };
    const complete = () => {
      if (settled) return;
      const receivedAudio = Buffer.concat(audioChunks);
      if (!receivedAudio.length || receivedAudio.length > 20 * 1024 * 1024) {
        fail(new HuaweiSisError('SIS_INVALID_RESPONSE', '语音服务返回了无效音频'));
        return;
      }
      const audio = trimTrailingPcmSilence(input.text, receivedAudio, sampleRate);
      const wordTimings = input.wordTimestamps
        ? normalizeWordTimings(input.text, rawTimings, audio.length, sampleRate)
        : [];
      const timingMode: SisTimingMode = wordTimings.length > 0 ? 'WORD' : 'SILENCE_ALIGNED';
      const timings = wordTimings.length > 0
        ? wordTimings
        : deriveSilenceAlignedTimings(input.text, audio, sampleRate);
      settled = true;
      clearTimeout(timeout);
      closeSocket();
      resolve({
        audio,
        traceId,
        sampleRate,
        timingMode,
        timings
      });
    };

    socket.on('open', () => {
      socket.send(JSON.stringify({
        command: 'START',
        text: input.text,
        config: {
          audio_format: 'pcm',
          sample_rate: String(sampleRate),
          property: input.property,
          speed: input.speed,
          pitch: input.pitch,
          volume: input.volume,
          ...(input.wordTimestamps ? { subtitle: 'word_level' } : {})
        }
      }));
    });

    socket.on('message', (data: RawData, isBinary: boolean) => {
      if (settled) return;
      if (isBinary) {
        const chunk = rawDataBuffer(data);
        audioBytes += chunk.length;
        if (audioBytes > 20 * 1024 * 1024) {
          fail(new HuaweiSisError('SIS_INVALID_RESPONSE', '语音服务返回音频过大'));
          return;
        }
        audioChunks.push(chunk);
        return;
      }
      let message: SisRttsMessage;
      try {
        message = JSON.parse(rawDataBuffer(data).toString('utf8')) as SisRttsMessage;
      } catch {
        fail(new HuaweiSisError('SIS_INVALID_RESPONSE', '语音服务返回了无效消息'));
        return;
      }
      if (message.trace_id) traceId = message.trace_id;
      if (message.resp_type === 'RESULT' && Array.isArray(message.result)) {
        rawTimings.push(...message.result);
      } else if (message.resp_type === 'END') {
        receivedEnd = true;
        complete();
      } else if (message.resp_type === 'ERROR' || message.resp_type === 'FATAL_ERROR') {
        fail(new HuaweiSisError(
          message.error_code || 'SIS_SYNTHESIS_FAILED',
          message.error_msg || '在线语音合成失败'
        ));
      }
    });

    socket.on('unexpected-response', (_request, response) => {
      fail(new HuaweiSisError(
        'SIS_RTTS_HANDSHAKE_FAILED',
        `实时语音合成连接失败（${response.statusCode}）`
      ));
    });
    socket.on('error', () => {
      fail(new HuaweiSisError('SIS_RTTS_CONNECTION_FAILED', '实时语音合成连接失败'));
    });
    socket.on('close', () => {
      if (!settled) {
        if (receivedEnd && audioBytes > 0) {
          complete();
        } else {
          fail(new HuaweiSisError('SIS_RTTS_CLOSED', '实时语音合成连接意外关闭'));
        }
      }
    });
  });
}

/**
 * Huawei RTTS can append a sizeable zero/near-zero tail after the last spoken
 * syllable. It is valid PCM, so both AudioRenderer and chapter handoff wait for
 * it unless it is removed before the timeline is generated.
 */
export function trimTrailingPcmSilence(
  text: string,
  pcm: Buffer,
  sampleRate: number
): Buffer {
  const safeSampleRate = Math.max(8_000, Math.round(sampleRate || 16_000));
  const totalFrames = Math.floor(pcm.length / 2);
  if (totalFrames < Math.round(safeSampleRate * 0.35)) return pcm;

  const windowFrames = Math.max(32, Math.round(safeSampleRate * 0.01));
  let lastActiveFrame = -1;
  for (let windowEnd = totalFrames; windowEnd > 0; windowEnd -= windowFrames) {
    const windowStart = Math.max(0, windowEnd - windowFrames);
    let absoluteSum = 0;
    let peak = 0;
    let samples = 0;
    for (let frame = windowStart; frame < windowEnd; frame += 2) {
      const amplitude = Math.abs(pcm.readInt16LE(frame * 2));
      absoluteSum += amplitude;
      peak = Math.max(peak, amplitude);
      samples++;
    }
    const average = samples > 0 ? absoluteSum / samples : 0;
    if (average >= 64 || peak >= 320) {
      lastActiveFrame = windowEnd;
      break;
    }
  }
  if (lastActiveFrame < 0) return pcm;

  const keepFrames = Math.round(safeSampleRate * trailingPauseSeconds(text));
  const targetFrames = Math.min(totalFrames, lastActiveFrame + keepFrames);
  const removableFrames = totalFrames - targetFrames;
  if (removableFrames < Math.round(safeSampleRate * 0.12)) return pcm;
  return pcm.subarray(0, targetFrames * 2);
}

function trailingPauseSeconds(text: string): number {
  const value = (text || '').trim();
  let index = value.length - 1;
  while (index >= 0 && isClosingPunctuation(value[index]!)) index--;
  const last = index >= 0 ? value[index]! : '';
  if ('。！？!?'.includes(last)) return 0.22;
  if ('；;：:'.includes(last)) return 0.16;
  if ('，,、'.includes(last)) return 0.12;
  return 0.1;
}

function rawDataBuffer(data: RawData): Buffer {
  if (Buffer.isBuffer(data)) return data;
  if (Array.isArray(data)) return Buffer.concat(data);
  if (data instanceof ArrayBuffer) return Buffer.from(data);
  return Buffer.alloc(0);
}

export function normalizeWordTimings(
  text: string,
  values: SisRttsTiming[],
  audioBytes: number,
  sampleRate: number
): SisSpeechTiming[] {
  const durationMs = Math.floor(audioBytes * 1000 / (sampleRate * 2));
  const sorted = values
    .filter((item) =>
      Number.isFinite(item.start_time)
      && Number.isFinite(item.end_time)
      && Number(item.end_time) >= Number(item.start_time)
    )
    .sort((left, right) =>
      Number(left.start_time) - Number(right.start_time)
      || Number(left.word_index) - Number(right.word_index)
    );
  const result: SisSpeechTiming[] = [];
  let cursor = 0;
  let lastStartTime = -1;
  for (const item of sorted) {
    const token = item.text || '';
    if (!token) continue;
    const startTime = Math.max(0, Math.min(durationMs, Math.round(Number(item.start_time))));
    const endTime = Math.max(startTime, Math.min(durationMs, Math.round(Number(item.end_time))));
    if (startTime < lastStartTime) continue;
    const range = locateTokenRange(text, token, cursor, Number(item.word_index));
    if (!range) continue;
    result.push({
      startTime,
      endTime,
      text: token,
      wordIndex: Number.isFinite(item.word_index) ? Math.round(Number(item.word_index)) : result.length,
      startOffset: range.start,
      endOffset: range.end
    });
    cursor = Math.max(cursor, range.end);
    lastStartTime = startTime;
  }
  return result;
}

function locateTokenRange(
  source: string,
  token: string,
  cursor: number,
  wordIndex: number
): TextTimelineRange | null {
  const hintedIndex = Number.isFinite(wordIndex) ? Math.max(0, Math.round(wordIndex)) : -1;
  if (
    hintedIndex >= 0
    && hintedIndex + token.length <= source.length
    && source.slice(hintedIndex, hintedIndex + token.length) === token
  ) {
    return { start: hintedIndex, end: hintedIndex + token.length };
  }
  let start = source.indexOf(token, Math.max(0, cursor));
  if (start < 0) start = source.indexOf(token);
  if (start < 0) return null;
  return { start, end: start + token.length };
}

export function deriveSilenceAlignedTimings(
  text: string,
  audio: Buffer,
  sampleRate: number
): SisSpeechTiming[] {
  const ranges = splitTimelineText(text);
  if (ranges.length === 0) return [];
  const totalFrames = Math.floor(audio.length / 2);
  if (ranges.length === 1 || totalFrames <= sampleRate / 4) {
    return [{
      startTime: 0,
      endTime: Math.floor(totalFrames * 1000 / sampleRate),
      text: text.slice(ranges[0]!.start, ranges[0]!.end),
      wordIndex: 0,
      startOffset: ranges[0]!.start,
      endOffset: ranges[0]!.end
    }];
  }

  const weights = ranges.map((range) => timelineTextWeight(text.slice(range.start, range.end)));
  const totalWeight = Math.max(1, weights.reduce((sum, value) => sum + value, 0));
  const boundaries: number[] = [0];
  let consumedWeight = 0;
  for (let index = 0; index + 1 < ranges.length; index++) {
    consumedWeight += weights[index]!;
    const expectedFrame = Math.round(totalFrames * consumedWeight / totalWeight);
    const previousFrame = boundaries[boundaries.length - 1]!;
    const remainingSegments = ranges.length - index - 1;
    const minimumFrame = Math.min(
      totalFrames,
      previousFrame + Math.max(1, Math.round(sampleRate * 0.08))
    );
    const maximumFrame = Math.max(
      minimumFrame,
      totalFrames - Math.round(remainingSegments * sampleRate * 0.08)
    );
    const expectedSegmentFrames = Math.max(sampleRate / 2, expectedFrame - previousFrame);
    const searchRadius = Math.max(
      Math.round(sampleRate * 0.22),
      Math.min(Math.round(sampleRate * 0.8), Math.round(expectedSegmentFrames * 0.45))
    );
    boundaries.push(findQuietBoundary(
      audio,
      sampleRate,
      expectedFrame,
      Math.max(minimumFrame, expectedFrame - searchRadius),
      Math.min(maximumFrame, expectedFrame + searchRadius)
    ));
  }
  boundaries.push(totalFrames);

  return ranges.map((range, index) => ({
    startTime: Math.floor(boundaries[index]! * 1000 / sampleRate),
    endTime: Math.floor(boundaries[index + 1]! * 1000 / sampleRate),
    text: text.slice(range.start, range.end),
    wordIndex: index,
    startOffset: range.start,
    endOffset: range.end
  }));
}

function splitTimelineText(text: string): TextTimelineRange[] {
  const result: TextTimelineRange[] = [];
  const preferredLength = 28;
  const maximumLength = 42;
  const minimumLength = 10;
  let start = 0;
  while (start < text.length) {
    const limit = Math.min(text.length, start + maximumLength);
    const preferredEnd = Math.min(limit, start + preferredLength);
    let end = findTimelineBreak(text, start + minimumLength, preferredEnd, true, true);
    if (end <= start && preferredEnd < limit) {
      end = findTimelineBreak(text, preferredEnd, limit, true, false);
    }
    if (end <= start) {
      end = findTimelineBreak(text, start + minimumLength, limit, false, true);
    }
    if (end <= start) end = limit;
    while (end < limit && isClosingPunctuation(text[end]!)) end++;
    result.push({ start, end });
    start = end;
  }
  return result;
}

function findTimelineBreak(
  text: string,
  from: number,
  to: number,
  strong: boolean,
  backwards: boolean
): number {
  if (backwards) {
    for (let index = Math.min(text.length, to) - 1; index >= Math.max(0, from); index--) {
      if (isTimelineBreak(text[index]!, strong)) return index + 1;
    }
    return -1;
  }
  for (let index = Math.max(0, from); index < Math.min(text.length, to); index++) {
    if (isTimelineBreak(text[index]!, strong)) return index + 1;
  }
  return -1;
}

function isTimelineBreak(value: string, strong: boolean): boolean {
  if (strong) {
    return '。！？；;.!?\n'.includes(value);
  }
  return '，,、：:'.includes(value);
}

function isClosingPunctuation(value: string): boolean {
  return '”’"\'）)】]》〉」』'.includes(value);
}

function timelineTextWeight(text: string): number {
  let weight = 0;
  for (const value of Array.from(text)) {
    if (/\s/.test(value)) continue;
    weight += isTimelineBreak(value, true) ? 1.8 : isTimelineBreak(value, false) ? 1.35 : 1;
  }
  return Math.max(1, weight);
}

function findQuietBoundary(
  pcm: Buffer,
  sampleRate: number,
  expectedFrame: number,
  minimumFrame: number,
  maximumFrame: number
): number {
  const totalFrames = Math.floor(pcm.length / 2);
  const minFrame = Math.max(0, Math.min(totalFrames, minimumFrame));
  const maxFrame = Math.max(minFrame, Math.min(totalFrames, maximumFrame));
  const windowFrames = Math.max(16, Math.round(sampleRate * 0.018));
  const stepFrames = Math.max(8, Math.round(sampleRate * 0.006));
  let bestFrame = Math.max(minFrame, Math.min(maxFrame, expectedFrame));
  let bestScore = Number.POSITIVE_INFINITY;
  for (let frame = minFrame; frame <= maxFrame; frame += stepFrames) {
    const windowStart = Math.max(0, frame - Math.floor(windowFrames / 2));
    const windowEnd = Math.min(totalFrames, windowStart + windowFrames);
    let sum = 0;
    let count = 0;
    for (let sample = windowStart; sample < windowEnd; sample += 2) {
      sum += Math.abs(pcm.readInt16LE(sample * 2));
      count++;
    }
    const energy = count > 0 ? sum / count : 0;
    const distancePenalty = Math.abs(frame - expectedFrame) * 120 / sampleRate;
    const score = energy + distancePenalty;
    if (score < bestScore) {
      bestScore = score;
      bestFrame = frame;
    }
  }
  return bestFrame;
}
