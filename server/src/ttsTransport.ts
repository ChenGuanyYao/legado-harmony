import { Buffer } from 'node:buffer';

export const TIMED_TTS_BINARY_CONTENT_TYPE = 'application/vnd.qingye.tts-timed';
const MAGIC = Buffer.from('QYTB', 'ascii');
const PREFIX_BYTES = 8;

export interface TimedTtsBinaryMetadata {
  version: 2;
  sampleRate: number;
  timingMode: string;
  timings: unknown[];
}

export function encodeTimedTtsBinary(
  audio: Buffer,
  sampleRate: number,
  timingMode: string,
  timings: unknown[]
): Buffer {
  const metadata: TimedTtsBinaryMetadata = {
    version: 2,
    sampleRate,
    timingMode,
    timings
  };
  const metadataBuffer = Buffer.from(JSON.stringify(metadata), 'utf8');
  const prefix = Buffer.allocUnsafe(PREFIX_BYTES);
  MAGIC.copy(prefix, 0);
  prefix.writeUInt32BE(metadataBuffer.length, 4);
  return Buffer.concat([prefix, metadataBuffer, audio], PREFIX_BYTES + metadataBuffer.length + audio.length);
}

