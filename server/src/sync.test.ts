import assert from 'node:assert/strict';
import test from 'node:test';

process.env.DATABASE_URL ||= 'postgresql://test:test@127.0.0.1:5432/test';
process.env.SESSION_SECRET ||= 'test-session-secret-that-is-long-enough';
process.env.HUAWEI_CLIENT_ID ||= 'test-client';
process.env.HUAWEI_CLIENT_SECRET ||= 'test-secret';
process.env.HUAWEI_APP_ID ||= 'test-app';
process.env.HUAWEI_IAP_KEY_ID ||= 'test-key';
process.env.HUAWEI_IAP_ISSUER_ID ||= 'test-issuer';
process.env.HUAWEI_IAP_PRIVATE_KEY_PATH ||= 'test-private-key.pem';
process.env.HUAWEI_IAP_ROOT_CA_PATH ||= 'test-root-ca.pem';
process.env.HUAWEI_IAP_ROOT_URL ||= 'https://example.com';
process.env.HUAWEI_IAP_DELIVERABLE_STATUSES ||= '0,PAID';

const { ensureSyncQuota, normalizeOperation, SyncApiError } = await import('./sync.js');

const OP_ID = '123e4567-e89b-42d3-a456-426614174000';

test('book source payloads may exceed the default 64KB limit', () => {
  const normalized = normalizeOperation({
    opId: OP_ID,
    entityType: 'book_source',
    entityId: 'source_test',
    operation: 'upsert',
    baseRevision: 0,
    payload: { rules: 'x'.repeat(96 * 1024) }
  });
  assert.equal(normalized.entityType, 'book_source');
});

test('non-book-source payloads keep the 64KB limit', () => {
  assert.throws(() => normalizeOperation({
    opId: OP_ID,
    entityType: 'reader_settings',
    entityId: 'global',
    operation: 'upsert',
    baseRevision: 0,
    payload: { settings: 'x'.repeat(96 * 1024) }
  }), (error: unknown) =>
    error instanceof SyncApiError &&
    error.statusCode === 413 &&
    error.code === 'SYNC_PAYLOAD_TOO_LARGE');
});

test('book source payloads cannot exceed 256KB', () => {
  assert.throws(() => normalizeOperation({
    opId: OP_ID,
    entityType: 'book_source',
    entityId: 'source_test',
    operation: 'upsert',
    baseRevision: 0,
    payload: { rules: 'x'.repeat(257 * 1024) }
  }), (error: unknown) =>
    error instanceof SyncApiError &&
    error.statusCode === 413 &&
    error.code === 'SYNC_PAYLOAD_TOO_LARGE');
});

test('sync quotas reject unbounded daily writes and storage growth', () => {
  assert.throws(() => ensureSyncQuota({
    entityCount: 1,
    entityBytes: 1,
    changeCount: 1,
    changeBytes: 1,
    dailyWrites: 5001
  }), (error: unknown) => error instanceof SyncApiError && error.code === 'SYNC_DAILY_WRITE_LIMITED');
  assert.throws(() => ensureSyncQuota({
    entityCount: 10_001,
    entityBytes: 1,
    changeCount: 1,
    changeBytes: 1,
    dailyWrites: 1
  }), (error: unknown) => error instanceof SyncApiError && error.code === 'SYNC_STORAGE_QUOTA_EXCEEDED');
});
