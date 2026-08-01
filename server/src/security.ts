import { pool } from './db.js';

export class AccountRateLimitError extends Error {
  constructor(readonly retryAfterSeconds: number) {
    super('请求过于频繁，请稍后重试');
  }
}

export async function enforceAccountRateLimit(
  userId: string,
  scope: string,
  maxRequests: number
): Promise<void> {
  const result = await pool.query<{ request_count: number; retry_after: number }>(
    `WITH current_window AS (
       SELECT date_trunc('minute', clock_timestamp()) AS window_start
     ), counted AS (
       INSERT INTO api_rate_limits (scope, subject_id, window_start, request_count)
       SELECT $1, $2, window_start, 1
       FROM current_window
       ON CONFLICT (scope, subject_id, window_start) DO UPDATE SET
         request_count = api_rate_limits.request_count + 1
       RETURNING request_count, window_start
     )
     SELECT request_count,
            GREATEST(1, ceil(extract(epoch FROM
              (window_start + interval '1 minute' - clock_timestamp())))::integer
            ) AS retry_after
     FROM counted`,
    [scope, userId]
  );
  const row = result.rows[0]!;
  if (Number(row.request_count) > maxRequests) {
    throw new AccountRateLimitError(Number(row.retry_after));
  }
}

export async function cleanupExpiredSecurityRows(): Promise<void> {
  await Promise.all([
    pool.query(`DELETE FROM api_rate_limits WHERE window_start < now() - interval '1 hour'`),
    pool.query(`DELETE FROM auth_sessions WHERE expires_at < now()`)
  ]);
}
