import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import test from 'node:test';
import {
  TTS_PACKAGES,
  TTS_VOICES,
  chargedTtsCharacters,
  countTtsCharacters,
  findTtsPackage,
  ttsBillingUnit
} from './tts.js';

test('TTS catalog identifiers are unique', () => {
  assert.equal(new Set(TTS_VOICES.map((voice) => voice.id)).size, TTS_VOICES.length);
  assert.equal(new Set(TTS_VOICES.map((voice) => voice.property)).size, TTS_VOICES.length);
  assert.equal(new Set(TTS_PACKAGES.map((item) => item.sku)).size, TTS_PACKAGES.length);
});

test('TTS catalog contains only the current Huawei RTTS Chinese voices', () => {
  const officialProperties = [
    'chinese_xiaoqi_common',
    'chinese_xiaoyu_common',
    'chinese_xiaoyan_common',
    'chinese_xiaowang_common',
    'chinese_huaxiaomei_common',
    'chinese_huaxiaofei_common',
    'chinese_huaxiaoru_common',
    'chinese_huaxiaohan_common',
    'chinese_huaxiaorui_common',
    'chinese_huaxiaolong_common',
    'chinese_huaxiaozhen_common',
    'chinese_huaxiaohe_common',
    'chinese_huaxiaoye_common',
    'chinese_huaxiaoxue_common',
    'chinese_huaxiaojiao_common',
    'chinese_huaxiaohui_common',
    'chinese_huaxiaokang_common',
    'chinese_huaxiaokun_common',
    'chinese_huaxiaoquan_common'
  ];
  assert.equal(TTS_VOICES.length, 19);
  assert.deepEqual(
    [...TTS_VOICES.map((voice) => voice.property)].sort(),
    [...officialProperties].sort()
  );
});

test('TTS timestamp capability matches the Huawei RTTS property table', () => {
  const timestampProperties = new Set([
    'chinese_huaxiaomei_common',
    'chinese_huaxiaofei_common',
    'chinese_huaxiaohe_common',
    'chinese_huaxiaoye_common',
    'chinese_huaxiaoxue_common',
    'chinese_huaxiaojiao_common',
    'chinese_huaxiaohui_common',
    'chinese_huaxiaokang_common',
    'chinese_huaxiaokun_common',
    'chinese_huaxiaoquan_common'
  ]);
  for (const voice of TTS_VOICES) {
    assert.equal(
      voice.supportsWordTimestamps,
      timestampProperties.has(voice.property),
      voice.property
    );
  }
});

test('TTS packages preserve the approved prices', () => {
  assert.deepEqual(
    TTS_PACKAGES.map(({ sku, chars, points }) => ({ sku, chars, points })),
    [
      { sku: 'tts_standard_100k', chars: 100_000, points: 59 },
      { sku: 'tts_standard_500k', chars: 500_000, points: 269 },
      { sku: 'tts_standard_1m', chars: 1_000_000, points: 499 },
      { sku: 'tts_premium_100k', chars: 100_000, points: 99 },
      { sku: 'tts_premium_500k', chars: 500_000, points: 449 },
      { sku: 'tts_premium_1m', chars: 1_000_000, points: 899 }
    ]
  );
  assert.equal(findTtsPackage('tts_standard_100k')?.tier, 'STANDARD');
  assert.equal(findTtsPackage('missing'), undefined);
});

test('TTS character billing follows Huawei rounding units', () => {
  assert.equal(ttsBillingUnit('STANDARD'), 100);
  assert.equal(ttsBillingUnit('PREMIUM'), 50);
  assert.equal(chargedTtsCharacters('a'.repeat(91), 'STANDARD'), 100);
  assert.equal(chargedTtsCharacters('a'.repeat(101), 'STANDARD'), 200);
  assert.equal(chargedTtsCharacters('a'.repeat(47), 'PREMIUM'), 50);
  assert.equal(chargedTtsCharacters('a'.repeat(51), 'PREMIUM'), 100);
});

test('TTS character counting uses Unicode code points after NFC normalization', () => {
  assert.equal(countTtsCharacters('你好，world'), 8);
  assert.equal(countTtsCharacters('😀'), 1);
  assert.equal(countTtsCharacters('e\u0301'), 1);
});

test('Huawei SIS SDK loads with all production runtime dependencies', async () => {
  const sdk = await import('@huaweicloud/huaweicloud-sdk-sis');
  assert.equal(typeof sdk.SisClient, 'function');
});

test('RTTS word timestamps are mapped back to UTF-16 text offsets', async () => {
  const { normalizeWordTimings } = await importHuaweiSisForTimelineTests();
  const timings = normalizeWordTimings(
    'Nice to meet you.',
    [
      { start_time: 0, end_time: 200, word_index: 0, text: 'Nice' },
      { start_time: 200, end_time: 350, word_index: 1, text: 'to' },
      { start_time: 350, end_time: 550, word_index: 2, text: 'meet' },
      { start_time: 550, end_time: 800, word_index: 3, text: 'you.' }
    ],
    16_000 * 2,
    16_000
  );
  assert.deepEqual(
    timings.map(({ text, startOffset, endOffset }) => ({ text, startOffset, endOffset })),
    [
      { text: 'Nice', startOffset: 0, endOffset: 4 },
      { text: 'to', startOffset: 5, endOffset: 7 },
      { text: 'meet', startOffset: 8, endOffset: 12 },
      { text: 'you.', startOffset: 13, endOffset: 17 }
    ]
  );
});

test('fallback RTTS timeline snaps sentence boundaries to PCM silence', async () => {
  const { deriveSilenceAlignedTimings } = await importHuaweiSisForTimelineTests();
  const sampleRate = 16_000;
  const pcm = Buffer.alloc(sampleRate * 2 * 2);
  for (let frame = 0; frame < sampleRate * 2; frame++) {
    const timeMs = frame * 1000 / sampleRate;
    const sample = timeMs >= 850 && timeMs <= 1100 ? 0 : 3200;
    pcm.writeInt16LE(sample, frame * 2);
  }
  const timings = deriveSilenceAlignedTimings(
    '这是第一段需要朗读的测试文字。这是第二段需要朗读的测试文字。',
    pcm,
    sampleRate
  );
  assert.equal(timings.length, 2);
  assert.ok(timings[1]!.startTime >= 800 && timings[1]!.startTime <= 1150);
  assert.equal(timings[0]!.startOffset, 0);
  assert.equal(timings[1]!.endOffset, 30);
});

async function importHuaweiSisForTimelineTests() {
  const requiredValues: Record<string, string> = {
    DATABASE_URL: 'postgres://test:test@127.0.0.1:5432/test',
    SESSION_SECRET: 'test-session-secret-at-least-32-bytes',
    HUAWEI_CLIENT_ID: 'test-client',
    HUAWEI_CLIENT_SECRET: 'test-client-secret',
    HUAWEI_APP_ID: 'test-app',
    HUAWEI_IAP_KEY_ID: 'test-key',
    HUAWEI_IAP_ISSUER_ID: 'test-issuer',
    HUAWEI_IAP_PRIVATE_KEY_PATH: '/tmp/test-private-key',
    HUAWEI_IAP_ROOT_CA_PATH: '/tmp/test-root-ca',
    HUAWEI_IAP_ROOT_URL: 'https://example.invalid',
    HUAWEI_IAP_DELIVERABLE_STATUSES: '0,PAID'
  };
  for (const [name, value] of Object.entries(requiredValues)) {
    process.env[name] ||= value;
  }
  return import('./huaweiSis.js');
}
