import { pool } from './db.js';

export async function cleanupExpiredSyncReceipts(
  retentionDays: number,
  batchSize = 5000
): Promise<number> {
  const safeRetentionDays = Math.max(1, Math.floor(retentionDays));
  const safeBatchSize = Math.max(1, Math.min(20_000, Math.floor(batchSize)));
  const result = await pool.query(
    `DELETE FROM sync_operation_receipts
     WHERE ctid IN (
       SELECT ctid
       FROM sync_operation_receipts
       WHERE created_at < now() - make_interval(days => $1)
       ORDER BY created_at
       LIMIT $2
     )`,
    [safeRetentionDays, safeBatchSize]
  );
  return result.rowCount || 0;
}

export async function cleanupExpiredTtsUsage(
  retentionDays: number,
  batchSize = 5000
): Promise<number> {
  const safeRetentionDays = Math.max(1, Math.floor(retentionDays));
  const safeBatchSize = Math.max(1, Math.min(20_000, Math.floor(batchSize)));
  const result = await pool.query(
    `DELETE FROM tts_usage
     WHERE ctid IN (
       SELECT ctid
       FROM tts_usage
       WHERE status IN ('SUCCEEDED', 'FAILED', 'REFUNDED')
         AND created_at < now() - make_interval(days => $1)
         AND (completed_at IS NULL OR completed_at < now() - make_interval(days => $1))
       ORDER BY created_at
       LIMIT $2
     )`,
    [safeRetentionDays, safeBatchSize]
  );
  return result.rowCount || 0;
}
