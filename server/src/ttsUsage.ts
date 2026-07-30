import { PoolClient } from 'pg';
import { config } from './config.js';
import { inTransaction, pool } from './db.js';
import { TtsTier } from './tts.js';

export type TtsUsageStatus = 'RESERVED' | 'SUCCEEDED' | 'FAILED' | 'REFUNDED';

export interface TtsUsageRecord {
  id: string;
  userId: string;
  requestId: string;
  voiceId: string;
  tier: TtsTier;
  rawChars: number;
  chargedChars: number;
  status: TtsUsageStatus;
  inputHash: string;
  errorCode: string;
}

export class TtsQuotaError extends Error {
  constructor(
    readonly code:
      | 'INSUFFICIENT_TTS_QUOTA'
      | 'TTS_RATE_LIMITED'
      | 'TTS_DAILY_BUDGET_EXHAUSTED',
    message: string
  ) {
    super(message);
  }
}

interface UsageRow {
  id: string;
  user_id: string;
  request_id: string;
  voice_id: string;
  tier: TtsTier;
  raw_chars: number;
  charged_chars: number;
  status: TtsUsageStatus;
  input_hash: string;
  error_code: string | null;
}

interface GrantRow {
  id: string;
  remaining_chars: string;
}

export async function reserveTtsUsage(
  userId: string,
  requestId: string,
  voiceId: string,
  tier: TtsTier,
  rawChars: number,
  chargedChars: number,
  inputHash: string
): Promise<{ duplicate: boolean; usage: TtsUsageRecord }> {
  return inTransaction(async (client) => {
    await client.query(
      'SELECT pg_advisory_xact_lock(hashtextextended($1, 0))',
      [`tts-user-usage:${userId}`]
    );
    await lockTier(client, userId, tier);
    const existing = await client.query<UsageRow>(
      `${usageSelect}
       WHERE user_id = $1 AND request_id = $2
       FOR UPDATE`,
      [userId, requestId]
    );
    if (existing.rowCount) {
      return { duplicate: true, usage: mapUsage(existing.rows[0]!) };
    }

    const recent = await client.query<{ request_count: string }>(
      `SELECT COUNT(*)::bigint AS request_count
       FROM tts_usage
       WHERE user_id = $1
         AND created_at > now() - interval '1 minute'`,
      [userId]
    );
    if (Number(recent.rows[0]?.request_count || 0) >= config.sis.perUserRequestsPerMinute) {
      throw new TtsQuotaError('TTS_RATE_LIMITED', '在线朗读请求过于频繁，请稍后重试');
    }

    await client.query(
      'SELECT pg_advisory_xact_lock(hashtextextended($1, 0))',
      ['tts-daily-billing-budget']
    );
    const daily = await client.query<{ billing_units: string }>(
      `SELECT COALESCE(SUM(
         CASE WHEN tier = 'PREMIUM'
           THEN charged_chars / 50
           ELSE charged_chars / 100
         END
       ), 0)::bigint AS billing_units
       FROM tts_usage
       WHERE status IN ('RESERVED', 'SUCCEEDED')
         AND created_at >= date_trunc('day', now())`
    );
    const requestUnits = chargedChars / (tier === 'PREMIUM' ? 50 : 100);
    if (
      Number(daily.rows[0]?.billing_units || 0) + requestUnits
      > config.sis.dailyBillingUnitLimit
    ) {
      throw new TtsQuotaError(
        'TTS_DAILY_BUDGET_EXHAUSTED',
        '今日在线朗读服务额度已用完，请明天再试'
      );
    }

    const grants = await client.query<GrantRow>(
      `SELECT id, remaining_chars
       FROM tts_quota_grants
       WHERE user_id = $1
         AND tier = $2
         AND remaining_chars > 0
         AND expires_at > now()
       ORDER BY expires_at, created_at, id
       FOR UPDATE`,
      [userId, tier]
    );
    const available = grants.rows.reduce(
      (total, grant) => total + Number(grant.remaining_chars),
      0
    );
    if (available < chargedChars) {
      throw new TtsQuotaError('INSUFFICIENT_TTS_QUOTA', '在线朗读字数不足');
    }

    const inserted = await client.query<UsageRow>(
      `INSERT INTO tts_usage (
         user_id, request_id, voice_id, tier, raw_chars,
         charged_chars, status, input_hash
       ) VALUES ($1, $2, $3, $4, $5, $6, 'RESERVED', $7)
       RETURNING
         id, user_id, request_id, voice_id, tier, raw_chars,
         charged_chars, status, input_hash, error_code`,
      [userId, requestId, voiceId, tier, rawChars, chargedChars, inputHash]
    );
    const usage = mapUsage(inserted.rows[0]!);

    let remaining = chargedChars;
    let balanceAfter = available;
    for (const grant of grants.rows) {
      if (remaining <= 0) break;
      const allocated = Math.min(remaining, Number(grant.remaining_chars));
      remaining -= allocated;
      balanceAfter -= allocated;
      await client.query(
        `UPDATE tts_quota_grants
         SET remaining_chars = remaining_chars - $2, updated_at = now()
         WHERE id = $1`,
        [grant.id, allocated]
      );
      await client.query(
        `INSERT INTO tts_usage_allocations (usage_id, grant_id, reserved_chars)
         VALUES ($1, $2, $3)`,
        [usage.id, grant.id, allocated]
      );
      await client.query(
        `INSERT INTO tts_quota_ledger (
           user_id, grant_id, tier, delta_chars, balance_after,
           reason, reference_id, idempotency_key
         ) VALUES ($1, $2, $3, $4, $5, 'TTS_RESERVE', $6, $7)`,
        [
          userId,
          grant.id,
          tier,
          -allocated,
          balanceAfter,
          requestId,
          `tts-reserve:${userId}:${requestId}:${grant.id}`
        ]
      );
    }
    return { duplicate: false, usage };
  });
}

export async function markTtsUsageSucceeded(
  usageId: string,
  traceId: string,
  audioHash: string
): Promise<void> {
  await pool.query(
    `UPDATE tts_usage
     SET status = 'SUCCEEDED',
         huawei_trace_id = NULLIF($2, ''),
         audio_hash = $3,
         error_code = NULL,
         completed_at = now()
     WHERE id = $1 AND status = 'RESERVED'`,
    [usageId, traceId, audioHash]
  );
}

export async function refundTtsUsage(usageId: string, errorCode: string): Promise<boolean> {
  return inTransaction(async (client) => {
    const identity = await client.query<{ user_id: string; tier: TtsTier }>(
      `SELECT user_id, tier
       FROM tts_usage
       WHERE id = $1`,
      [usageId]
    );
    if (!identity.rowCount) return false;
    const { user_id: userId, tier } = identity.rows[0]!;
    await lockTier(client, userId, tier);

    const usage = await client.query<{ request_id: string; status: TtsUsageStatus }>(
      `SELECT request_id, status
       FROM tts_usage
       WHERE id = $1
       FOR UPDATE`,
      [usageId]
    );
    if (!usage.rowCount || usage.rows[0]!.status !== 'RESERVED') return false;

    const balanceResult = await client.query<{ balance: string }>(
      `SELECT COALESCE(SUM(remaining_chars), 0)::bigint AS balance
       FROM tts_quota_grants
       WHERE user_id = $1 AND tier = $2 AND expires_at > now()`,
      [userId, tier]
    );
    let balanceAfter = Number(balanceResult.rows[0]?.balance || 0);
    const allocations = await client.query<{
      grant_id: string;
      reserved_chars: string;
      is_active: boolean;
    }>(
      `SELECT
         a.grant_id,
         a.reserved_chars,
         g.expires_at > now() AS is_active
       FROM tts_usage_allocations a
       JOIN tts_quota_grants g ON g.id = a.grant_id
       WHERE a.usage_id = $1 AND a.refunded_at IS NULL
       ORDER BY g.expires_at, g.created_at, g.id
       FOR UPDATE OF a, g`,
      [usageId]
    );
    for (const allocation of allocations.rows) {
      const chars = Number(allocation.reserved_chars);
      await client.query(
        `UPDATE tts_quota_grants
         SET remaining_chars = remaining_chars + $2, updated_at = now()
         WHERE id = $1`,
        [allocation.grant_id, chars]
      );
      await client.query(
        `UPDATE tts_usage_allocations
         SET refunded_at = now()
         WHERE usage_id = $1 AND grant_id = $2`,
        [usageId, allocation.grant_id]
      );
      if (allocation.is_active) balanceAfter += chars;
      await client.query(
        `INSERT INTO tts_quota_ledger (
           user_id, grant_id, tier, delta_chars, balance_after,
           reason, reference_id, idempotency_key
         ) VALUES ($1, $2, $3, $4, $5, 'TTS_REFUND', $6, $7)
         ON CONFLICT (idempotency_key) DO NOTHING`,
        [
          userId,
          allocation.grant_id,
          tier,
          chars,
          balanceAfter,
          usage.rows[0]!.request_id,
          `tts-refund:${usageId}:${allocation.grant_id}`
        ]
      );
    }
    await client.query(
      `UPDATE tts_usage
       SET status = 'REFUNDED', error_code = $2, completed_at = now()
       WHERE id = $1`,
      [usageId, errorCode]
    );
    return true;
  });
}

export async function refundStaleTtsReservations(): Promise<number> {
  const stale = await pool.query<{ id: string }>(
    `SELECT id
     FROM tts_usage
     WHERE status = 'RESERVED'
       AND created_at < now() - interval '5 minutes'
     ORDER BY created_at
     LIMIT 100`
  );
  let refunded = 0;
  for (const row of stale.rows) {
    if (await refundTtsUsage(row.id, 'SIS_RESERVATION_TIMEOUT')) refunded += 1;
  }
  return refunded;
}

const usageSelect = `
  SELECT
    id, user_id, request_id, voice_id, tier, raw_chars,
    charged_chars, status, input_hash, error_code
  FROM tts_usage`;

function mapUsage(row: UsageRow): TtsUsageRecord {
  return {
    id: row.id,
    userId: row.user_id,
    requestId: row.request_id,
    voiceId: row.voice_id,
    tier: row.tier,
    rawChars: Number(row.raw_chars),
    chargedChars: Number(row.charged_chars),
    status: row.status,
    inputHash: row.input_hash,
    errorCode: row.error_code || ''
  };
}

async function lockTier(client: PoolClient, userId: string, tier: TtsTier): Promise<void> {
  await client.query(
    'SELECT pg_advisory_xact_lock(hashtextextended($1, 0))',
    [`tts-quota:${userId}:${tier}`]
  );
}
