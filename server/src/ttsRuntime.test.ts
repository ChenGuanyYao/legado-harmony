import assert from 'node:assert/strict';
import test from 'node:test';
import {
  ByteLimitedLruCache,
  decideTtsReplay,
  TtsConcurrencyLimiter,
  TtsServerBusyError
} from './ttsRuntime.js';
import { encodeTimedTtsBinary } from './ttsTransport.js';

test('byte limited cache evicts least recently used values', () => {
  const cache = new ByteLimitedLruCache<string>(10, 8, 1000);
  assert.equal(cache.set('a', 'a', 4, 0), true);
  assert.equal(cache.set('b', 'b', 4, 0), true);
  assert.equal(cache.get('a', 1), 'a');
  assert.equal(cache.set('c', 'c', 4, 1), true);
  assert.equal(cache.get('b', 2), null);
  assert.equal(cache.get('a', 2), 'a');
  assert.deepEqual(cache.snapshot(), { entries: 2, bytes: 8 });
});

test('byte limited cache rejects oversized values and expires entries', () => {
  const cache = new ByteLimitedLruCache<string>(10, 5, 100);
  assert.equal(cache.set('large', 'large', 6, 0), false);
  assert.equal(cache.set('ok', 'ok', 5, 0), true);
  assert.equal(cache.get('ok', 100), null);
  assert.deepEqual(cache.snapshot(), { entries: 0, bytes: 0 });
});

test('successful TTS replay never calls the provider after its cache expires', () => {
  assert.equal(decideTtsReplay('SUCCEEDED', true), 'RETURN_CACHE');
  assert.equal(decideTtsReplay('SUCCEEDED', false), 'RESULT_EXPIRED');
  assert.equal(decideTtsReplay('RESERVED', false), 'IN_PROGRESS');
  assert.equal(decideTtsReplay('REFUNDED', false), 'REFUNDED');
});

test('concurrency limiter enforces global and per-user limits', async () => {
  const limiter = new TtsConcurrencyLimiter(2, 1, 2, 1000);
  const releaseA = await limiter.acquire('a');
  const releaseB = await limiter.acquire('b');
  const waitingA = limiter.acquire('a');
  assert.deepEqual(limiter.snapshot(), { active: 2, queued: 1 });
  releaseB();
  assert.deepEqual(limiter.snapshot(), { active: 1, queued: 1 });
  releaseA();
  const releaseNextA = await waitingA;
  assert.deepEqual(limiter.snapshot(), { active: 1, queued: 0 });
  releaseNextA();
});

test('concurrency limiter rejects when queue is full', async () => {
  const limiter = new TtsConcurrencyLimiter(1, 1, 0, 1000);
  const release = await limiter.acquire('a');
  await assert.rejects(limiter.acquire('b'), TtsServerBusyError);
  release();
});

test('binary timed TTS envelope contains metadata followed by raw audio', () => {
  const audio = Buffer.from([1, 2, 3, 4]);
  const encoded = encodeTimedTtsBinary(audio, 16000, 'WORD', [{ startTime: 0 }]);
  assert.equal(encoded.subarray(0, 4).toString('ascii'), 'QYTB');
  const metadataLength = encoded.readUInt32BE(4);
  const metadata = JSON.parse(encoded.subarray(8, 8 + metadataLength).toString('utf8'));
  assert.equal(metadata.version, 2);
  assert.equal(metadata.sampleRate, 16000);
  assert.deepEqual(encoded.subarray(8 + metadataLength), audio);
});
