import { PoolClient } from 'pg';
import { Buffer } from 'node:buffer';
import { config } from './config.js';
import { inTransaction, pool } from './db.js';

export class SyncApiError extends Error {
  constructor(
    readonly statusCode: number,
    readonly code: string,
    message: string
  ) {
    super(message);
  }
}

export interface SyncOperationBody {
  opId?: string;
  entityType?: string;
  entityId?: string;
  operation?: string;
  baseRevision?: number;
  payload?: unknown;
}

export interface SyncExchangeBody {
  protocolVersion?: number;
  deviceId?: string;
  deviceName?: string;
  platform?: string;
  appVersion?: string;
  deviceKind?: string;
  conflictPolicy?: string;
  cursor?: number;
  operations?: SyncOperationBody[];
}

interface NormalizedOperation {
  opId: string;
  entityType: string;
  entityId: string;
  operation: 'upsert' | 'delete';
  baseRevision: number;
  payload: unknown | null;
}

interface EntityRow {
  revision: string;
  payload: unknown | null;
  deleted: boolean;
}

interface ReceiptRow {
  operation_id: string;
  accepted: boolean;
  revision: string;
  sequence_id: string | null;
  conflict_payload: unknown | null;
  conflict_deleted: boolean;
}

export interface SyncQuotaUsage {
  entityCount: number;
  entityBytes: number;
  changeCount: number;
  changeBytes: number;
  dailyWrites: number;
}

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ENTITY_ID_PATTERN = /^[a-zA-Z0-9:_-]{1,160}$/;
const ALLOWED_ENTITY_TYPES = new Set([
  'bookshelf_item',
  'book_group',
  'reading_progress',
  'bookmark',
  'reader_settings',
  'replace_rule',
  'theme_settings',
  'appearance_mode',
  'bookshelf_display',
  'search_preferences',
  'custom_theme_schemes',
  'book_source'
]);
const DEVICE_KINDS = new Set(['phone', 'tablet', 'foldable', 'unknown']);
const MAX_OPERATIONS = 100;
const MAX_PAYLOAD_BYTES = 64 * 1024;
const MAX_BOOK_SOURCE_PAYLOAD_BYTES = 256 * 1024;
const PULL_LIMIT = 20;

export async function exchangeSync(userId: string, body: SyncExchangeBody) {
  const request = normalizeExchange(body);
  return inTransaction(async (client) => {
    await client.query(
      'SELECT pg_advisory_xact_lock(hashtextextended($1, 0))',
      [`sync-user:${userId}`]
    );
    await registerDevice(
      client,
      userId,
      request.deviceId,
      request.deviceName,
      request.platform,
      request.appVersion,
      request.deviceKind,
      request.cursor
    );
    const quota = await loadSyncQuotaUsage(client, userId);

    const acknowledgements = [];
    const receipts = await existingReceipts(
      client,
      userId,
      request.operations.map((operation) => operation.opId)
    );
    for (const operation of request.operations) {
      const receipt = receipts.get(operation.opId);
      if (receipt) {
        acknowledgements.push(receiptAck(receipt));
        continue;
      }
      acknowledgements.push(await applyOperation(
        client, userId, request.deviceId, operation, request.conflictPolicy, quota));
    }
    await persistSyncQuotaUsage(client, userId, quota);

    const acknowledgementBytes = Buffer.byteLength(JSON.stringify(acknowledgements), 'utf8');
    if (acknowledgementBytes > Math.floor(config.sync.responseBodyLimitBytes / 2)) {
      throw new SyncApiError(
        413,
        'SYNC_RESPONSE_TOO_LARGE',
        '同步冲突数据过多，请减小批次后重试'
      );
    }

    const changesResult = await client.query<{
      sequence_id: string;
      entity_type: string;
      entity_id: string;
      revision: string;
      operation: string;
      payload: unknown | null;
      device_id: string;
      created_at_ms: string;
    }>(
      `SELECT
         sequence_id, entity_type, entity_id, revision, operation, payload,
         device_id, (extract(epoch FROM created_at) * 1000)::bigint AS created_at_ms
       FROM sync_changes
       WHERE user_id = $1 AND sequence_id > $2
       ORDER BY sequence_id
       LIMIT $3`,
      [userId, request.cursor, PULL_LIMIT + 1]
    );
    const sourceRows = changesResult.rows.slice(0, PULL_LIMIT);
    const changes = [];
    let changeBytes = 0;
    const changeBudget = Math.max(
      1024,
      config.sync.responseBodyLimitBytes - acknowledgementBytes - 2048
    );
    for (const row of sourceRows) {
      const change = {
        sequenceId: Number(row.sequence_id),
        entityType: row.entity_type,
        entityId: row.entity_id,
        revision: Number(row.revision),
        operation: row.operation,
        payload: row.payload,
        deviceId: row.device_id,
        createdAt: Number(row.created_at_ms)
      };
      const bytes = Buffer.byteLength(JSON.stringify(change), 'utf8');
      if (changes.length > 0 && changeBytes + bytes > changeBudget) break;
      changes.push(change);
      changeBytes += bytes;
    }
    const hasMore = changesResult.rows.length > changes.length;
    const nextCursor = changes.length > 0 ?
      changes[changes.length - 1]!.sequenceId : request.cursor;
    return {
      protocolVersion: 1,
      acknowledgements,
      changes,
      nextCursor,
      hasMore,
      serverTime: Date.now()
    };
  });
}

export async function listSyncDevices(userId: string) {
  const result = await pool.query<{
    id: string;
    device_name: string;
    platform: string;
    app_version: string;
    device_kind: string;
    created_at_ms: string;
    last_seen_at_ms: string;
    revoked_at_ms: string | null;
  }>(
    `SELECT
       id, device_name, platform, app_version, device_kind,
       (extract(epoch FROM created_at) * 1000)::bigint AS created_at_ms,
       (extract(epoch FROM last_seen_at) * 1000)::bigint AS last_seen_at_ms,
       CASE WHEN revoked_at IS NULL THEN NULL
         ELSE (extract(epoch FROM revoked_at) * 1000)::bigint END AS revoked_at_ms
     FROM sync_devices
     WHERE user_id = $1
     ORDER BY last_seen_at DESC`,
    [userId]
  );
  return {
    devices: result.rows.map((row) => ({
      deviceId: row.id,
      deviceName: row.device_name,
      platform: row.platform,
      appVersion: row.app_version,
      deviceKind: row.device_kind || 'unknown',
      createdAt: Number(row.created_at_ms),
      lastSeenAt: Number(row.last_seen_at_ms),
      revokedAt: row.revoked_at_ms ? Number(row.revoked_at_ms) : null
    }))
  };
}

export async function syncSummary(userId: string) {
  const result = await pool.query<{ active_count: string }>(
    `SELECT count(*)::bigint AS active_count
     FROM sync_entities
     WHERE user_id = $1 AND deleted_at IS NULL`,
    [userId]
  );
  return { activeEntityCount: Number(result.rows[0]?.active_count || 0) };
}

export async function renameSyncDevice(userId: string, deviceId: string, deviceName: string): Promise<void> {
  if (!UUID_PATTERN.test(deviceId)) {
    throw new SyncApiError(400, 'INVALID_DEVICE_ID', '设备标识无效');
  }
  const normalizedName = normalizeLabel(deviceName, 80);
  if (!normalizedName) {
    throw new SyncApiError(400, 'INVALID_DEVICE_NAME', '设备名称不能为空');
  }
  const result = await pool.query(
    `UPDATE sync_devices
     SET device_name = $3, name_customized = TRUE
     WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL`,
    [deviceId, userId, normalizedName]
  );
  if (!result.rowCount) {
    throw new SyncApiError(404, 'SYNC_DEVICE_NOT_FOUND', '同步设备不存在');
  }
}

export async function revokeSyncDevice(userId: string, deviceId: string): Promise<void> {
  if (!UUID_PATTERN.test(deviceId)) {
    throw new SyncApiError(400, 'INVALID_DEVICE_ID', '设备标识无效');
  }
  const result = await pool.query(
    `UPDATE sync_devices
     SET revoked_at = COALESCE(revoked_at, now())
     WHERE id = $1 AND user_id = $2`,
    [deviceId, userId]
  );
  if (!result.rowCount) {
    throw new SyncApiError(404, 'SYNC_DEVICE_NOT_FOUND', '同步设备不存在');
  }
}

function normalizeExchange(body: SyncExchangeBody) {
  if (body?.protocolVersion !== 1) {
    throw new SyncApiError(400, 'UNSUPPORTED_SYNC_PROTOCOL', '同步协议版本不受支持');
  }
  const deviceId = body.deviceId?.trim() || '';
  if (!UUID_PATTERN.test(deviceId)) {
    throw new SyncApiError(400, 'INVALID_DEVICE_ID', '设备标识无效');
  }
  const cursor = Number(body.cursor || 0);
  if (!Number.isSafeInteger(cursor) || cursor < 0) {
    throw new SyncApiError(400, 'INVALID_SYNC_CURSOR', '同步游标无效');
  }
  const sourceOperations = body.operations || [];
  if (!Array.isArray(sourceOperations) || sourceOperations.length > MAX_OPERATIONS) {
    throw new SyncApiError(400, 'TOO_MANY_SYNC_OPERATIONS', `单次最多同步 ${MAX_OPERATIONS} 项`);
  }
  return {
    deviceId,
    deviceName: normalizeLabel(body.deviceName, 80),
    platform: normalizeLabel(body.platform, 30),
    appVersion: normalizeLabel(body.appVersion, 40),
    deviceKind: normalizeDeviceKind(body.deviceKind),
    conflictPolicy: body.conflictPolicy === 'local' ? 'local' : 'cloud',
    cursor,
    operations: sourceOperations.map(normalizeOperation)
  };
}

export function normalizeOperation(source: SyncOperationBody): NormalizedOperation {
  const opId = source?.opId?.trim() || '';
  if (!UUID_PATTERN.test(opId)) {
    throw new SyncApiError(400, 'INVALID_OPERATION_ID', '同步操作标识无效');
  }
  const entityType = source.entityType?.trim() || '';
  if (!ALLOWED_ENTITY_TYPES.has(entityType)) {
    throw new SyncApiError(400, 'INVALID_ENTITY_TYPE', '同步数据类型无效');
  }
  const entityId = source.entityId?.trim() || '';
  if (!ENTITY_ID_PATTERN.test(entityId)) {
    throw new SyncApiError(400, 'INVALID_ENTITY_ID', '同步数据标识无效');
  }
  if (source.operation !== 'upsert' && source.operation !== 'delete') {
    throw new SyncApiError(400, 'INVALID_SYNC_OPERATION', '同步操作类型无效');
  }
  const baseRevision = Number(source.baseRevision || 0);
  if (!Number.isSafeInteger(baseRevision) || baseRevision < 0) {
    throw new SyncApiError(400, 'INVALID_BASE_REVISION', '同步基础版本无效');
  }
  let payload: unknown | null = null;
  if (source.operation === 'upsert') {
    if (!source.payload || typeof source.payload !== 'object' || Array.isArray(source.payload)) {
      throw new SyncApiError(400, 'INVALID_SYNC_PAYLOAD', '同步数据内容无效');
    }
    const serialized = JSON.stringify(source.payload);
    const maxPayloadBytes = entityType === 'book_source' ?
      MAX_BOOK_SOURCE_PAYLOAD_BYTES : MAX_PAYLOAD_BYTES;
    if (Buffer.byteLength(serialized, 'utf8') > maxPayloadBytes) {
      const limit = entityType === 'book_source' ? '256KB' : '64KB';
      throw new SyncApiError(413, 'SYNC_PAYLOAD_TOO_LARGE', `单项同步数据不能超过 ${limit}`);
    }
    payload = source.payload;
  }
  return {
    opId,
    entityType,
    entityId,
    operation: source.operation,
    baseRevision,
    payload
  };
}

async function registerDevice(
  client: PoolClient,
  userId: string,
  deviceId: string,
  deviceName: string,
  platform: string,
  appVersion: string,
  deviceKind: string,
  cursor: number
): Promise<void> {
  const existing = await client.query<{ user_id: string; revoked: boolean }>(
    `SELECT user_id, revoked_at IS NOT NULL AS revoked
     FROM sync_devices
     WHERE id = $1
     FOR UPDATE`,
    [deviceId]
  );
  if (existing.rowCount) {
    const row = existing.rows[0]!;
    if (row.user_id !== userId) {
      throw new SyncApiError(403, 'SYNC_DEVICE_ACCOUNT_MISMATCH', '该设备已绑定其他账号');
    }
    if (row.revoked) {
      throw new SyncApiError(403, 'SYNC_DEVICE_REVOKED', '该同步设备已被移除');
    }
    await client.query(
      `UPDATE sync_devices
       SET device_name = CASE WHEN name_customized THEN device_name ELSE $2 END,
           platform = $3, app_version = $4, device_kind = $5,
           last_seen_at = now(),
           last_sync_cursor = GREATEST(last_sync_cursor, $6),
           last_cursor_at = CASE WHEN $6 > last_sync_cursor THEN now() ELSE last_cursor_at END
       WHERE id = $1`,
      [deviceId, deviceName, platform, appVersion, deviceKind, cursor]
    );
    return;
  }
  await client.query(
    `DELETE FROM sync_devices
     WHERE id IN (
       SELECT id FROM sync_devices
       WHERE user_id = $1 AND revoked_at < now() - interval '30 days'
       ORDER BY revoked_at
       LIMIT 20
     )`,
    [userId]
  );
  const deviceCount = await client.query<{ active_count: string; total_count: string }>(
    `SELECT
       count(*) FILTER (WHERE revoked_at IS NULL)::bigint AS active_count,
       count(*)::bigint AS total_count
     FROM sync_devices
     WHERE user_id = $1`,
    [userId]
  );
  if (
    Number(deviceCount.rows[0]?.active_count || 0) >= config.sync.maxDevicesPerUser
    || Number(deviceCount.rows[0]?.total_count || 0) >= config.sync.maxDevicesPerUser * 5
  ) {
    throw new SyncApiError(409, 'SYNC_DEVICE_LIMIT_EXCEEDED', '同步设备数量已达到上限');
  }
  await client.query(
    `INSERT INTO sync_devices (
       id, user_id, device_name, platform, app_version, device_kind,
       last_sync_cursor, last_cursor_at
     ) VALUES ($1, $2, $3, $4, $5, $6, $7, now())`,
    [deviceId, userId, deviceName, platform, appVersion, deviceKind, cursor]
  );
}

async function existingReceipts(
  client: PoolClient,
  userId: string,
  operationIds: string[]
): Promise<Map<string, ReceiptRow>> {
  if (operationIds.length === 0) return new Map();
  const result = await client.query<ReceiptRow>(
    `SELECT operation_id, accepted, revision, sequence_id,
            conflict_payload, conflict_deleted
     FROM sync_operation_receipts
     WHERE user_id = $1 AND operation_id = ANY($2::uuid[])`,
    [userId, operationIds]
  );
  return new Map(result.rows.map((row) => [row.operation_id, row]));
}

async function applyOperation(
  client: PoolClient,
  userId: string,
  deviceId: string,
  operation: NormalizedOperation,
  conflictPolicy: string,
  quota: SyncQuotaUsage
) {
  const currentResult = await client.query<EntityRow>(
    `SELECT revision, payload, deleted_at IS NOT NULL AS deleted
     FROM sync_entities
     WHERE user_id = $1 AND entity_type = $2 AND entity_id = $3
     FOR UPDATE`,
    [userId, operation.entityType, operation.entityId]
  );
  const current = currentResult.rows[0];
  const currentRevision = current ? Number(current.revision) : 0;
  if (currentRevision !== operation.baseRevision && conflictPolicy !== 'local') {
    await client.query(
      `INSERT INTO sync_operation_receipts (
         user_id, operation_id, device_id, entity_type, entity_id,
         accepted, revision, conflict_payload, conflict_deleted
       ) VALUES ($1, $2, $3, $4, $5, FALSE, $6, $7::jsonb, $8)`,
      [
        userId,
        operation.opId,
        deviceId,
        operation.entityType,
        operation.entityId,
        currentRevision,
        current?.payload === null || current?.payload === undefined ?
          null : JSON.stringify(current.payload),
        current?.deleted === true
      ]
    );
    return {
      opId: operation.opId,
      accepted: false,
      revision: currentRevision,
      sequenceId: null,
      conflict: {
        payload: current?.payload || null,
        deleted: current?.deleted === true
      }
    };
  }

  const currentPayloadBytes = current?.payload === null || current?.payload === undefined
    ? 0
    : Buffer.byteLength(JSON.stringify(current.payload), 'utf8');
  const nextPayloadBytes = operation.payload === null
    ? 0
    : Buffer.byteLength(JSON.stringify(operation.payload), 'utf8');
  const nextEntityCount = quota.entityCount + (current ? 0 : 1);
  const nextEntityBytes = quota.entityBytes - currentPayloadBytes + nextPayloadBytes;
  const nextChangeCount = quota.changeCount + 1;
  const nextChangeBytes = quota.changeBytes + nextPayloadBytes;
  const nextDailyWrites = quota.dailyWrites + 1;
  ensureSyncQuota({
    entityCount: nextEntityCount,
    entityBytes: nextEntityBytes,
    changeCount: nextChangeCount,
    changeBytes: nextChangeBytes,
    dailyWrites: nextDailyWrites
  });

  const revision = currentRevision + 1;
  const payloadJson = operation.payload === null ? null : JSON.stringify(operation.payload);
  const write = await client.query<{ sequence_id: string }>(
    `WITH entity_write AS (
       INSERT INTO sync_entities (
         user_id, entity_type, entity_id, revision, payload, deleted_at,
         updated_at, updated_by_device
       ) VALUES (
         $1, $2, $3, $4, $5::jsonb,
         CASE WHEN $6 = 'delete' THEN now() ELSE NULL END,
         now(), $7
       )
       ON CONFLICT (user_id, entity_type, entity_id) DO UPDATE SET
         revision = EXCLUDED.revision,
         payload = EXCLUDED.payload,
         deleted_at = EXCLUDED.deleted_at,
         updated_at = now(),
         updated_by_device = EXCLUDED.updated_by_device
       RETURNING revision
     ),
     change_write AS (
       INSERT INTO sync_changes (
         user_id, entity_type, entity_id, revision, operation, payload, device_id
       )
       SELECT $1, $2, $3, revision, $6, $5::jsonb, $7
       FROM entity_write
       RETURNING sequence_id
     ),
     receipt_write AS (
       INSERT INTO sync_operation_receipts (
         user_id, operation_id, device_id, entity_type, entity_id,
         accepted, revision, sequence_id
       )
       SELECT $1, $8, $7, $2, $3, TRUE, $4, sequence_id
       FROM change_write
       RETURNING sequence_id
     )
     SELECT sequence_id FROM receipt_write`,
    [
      userId,
      operation.entityType,
      operation.entityId,
      revision,
      payloadJson,
      operation.operation,
      deviceId,
      operation.opId
    ]
  );
  const sequenceId = Number(write.rows[0]!.sequence_id);
  quota.entityCount = nextEntityCount;
  quota.entityBytes = nextEntityBytes;
  quota.changeCount = nextChangeCount;
  quota.changeBytes = nextChangeBytes;
  quota.dailyWrites = nextDailyWrites;
  return {
    opId: operation.opId,
    accepted: true,
    revision,
    sequenceId
  };
}

async function loadSyncQuotaUsage(client: PoolClient, userId: string): Promise<SyncQuotaUsage> {
  await client.query(
    `INSERT INTO sync_user_usage (user_id)
     VALUES ($1)
     ON CONFLICT (user_id) DO NOTHING`,
    [userId]
  );
  await client.query(
    `UPDATE sync_user_usage
     SET daily_write_date = CURRENT_DATE, daily_writes = 0, updated_at = now()
     WHERE user_id = $1 AND daily_write_date <> CURRENT_DATE`,
    [userId]
  );
  const result = await client.query<{
    entity_count: string;
    entity_bytes: string;
    change_count: string;
    change_bytes: string;
    daily_writes: string;
  }>(
    `SELECT entity_count, entity_bytes, change_count, change_bytes, daily_writes
     FROM sync_user_usage
     WHERE user_id = $1
     FOR UPDATE`,
    [userId]
  );
  const row = result.rows[0]!;
  return {
    entityCount: Number(row.entity_count),
    entityBytes: Number(row.entity_bytes),
    changeCount: Number(row.change_count),
    changeBytes: Number(row.change_bytes),
    dailyWrites: Number(row.daily_writes)
  };
}

async function persistSyncQuotaUsage(
  client: PoolClient,
  userId: string,
  usage: SyncQuotaUsage
): Promise<void> {
  await client.query(
    `UPDATE sync_user_usage
     SET entity_count = $2, entity_bytes = $3,
         change_count = $4, change_bytes = $5,
         daily_write_date = CURRENT_DATE, daily_writes = $6,
         updated_at = now()
     WHERE user_id = $1`,
    [
      userId,
      usage.entityCount,
      usage.entityBytes,
      usage.changeCount,
      usage.changeBytes,
      usage.dailyWrites
    ]
  );
}

export function ensureSyncQuota(usage: SyncQuotaUsage): void {
  if (usage.dailyWrites > config.sync.maxDailyWritesPerUser) {
    throw new SyncApiError(429, 'SYNC_DAILY_WRITE_LIMITED', '今日同步写入次数已达到上限');
  }
  if (
    usage.entityCount > config.sync.maxEntitiesPerUser
    || usage.entityBytes > config.sync.maxEntityBytesPerUser
    || usage.changeCount > config.sync.maxChangesPerUser
    || usage.changeBytes > config.sync.maxChangeBytesPerUser
  ) {
    throw new SyncApiError(409, 'SYNC_STORAGE_QUOTA_EXCEEDED', '云同步存储空间已达到上限');
  }
}

function receiptAck(receipt: ReceiptRow) {
  return {
    opId: receipt.operation_id,
    accepted: receipt.accepted,
    revision: Number(receipt.revision),
    sequenceId: receipt.sequence_id ? Number(receipt.sequence_id) : null,
    conflict: receipt.accepted ? undefined : {
      payload: receipt.conflict_payload,
      deleted: receipt.conflict_deleted
    }
  };
}

function normalizeLabel(value: string | undefined, maxLength: number): string {
  return (value || '').trim().replace(/[\u0000-\u001f\u007f]/g, '').slice(0, maxLength);
}

function normalizeDeviceKind(value: string | undefined): string {
  const normalized = (value || '').trim().toLowerCase();
  return DEVICE_KINDS.has(normalized) ? normalized : 'unknown';
}
