CREATE TABLE IF NOT EXISTS auth_sessions (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  issued_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ,
  created_ip INET
);

CREATE INDEX IF NOT EXISTS auth_sessions_user_active_idx
  ON auth_sessions(user_id, expires_at DESC)
  WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS api_rate_limits (
  scope TEXT NOT NULL,
  subject_id TEXT NOT NULL,
  window_start TIMESTAMPTZ NOT NULL,
  request_count INTEGER NOT NULL CHECK (request_count > 0),
  PRIMARY KEY (scope, subject_id, window_start)
);

CREATE INDEX IF NOT EXISTS api_rate_limits_window_idx
  ON api_rate_limits(window_start);

CREATE TABLE IF NOT EXISTS sync_user_usage (
  user_id UUID PRIMARY KEY REFERENCES app_users(id) ON DELETE CASCADE,
  entity_count BIGINT NOT NULL DEFAULT 0 CHECK (entity_count >= 0),
  entity_bytes BIGINT NOT NULL DEFAULT 0 CHECK (entity_bytes >= 0),
  change_count BIGINT NOT NULL DEFAULT 0 CHECK (change_count >= 0),
  change_bytes BIGINT NOT NULL DEFAULT 0 CHECK (change_bytes >= 0),
  daily_write_date DATE NOT NULL DEFAULT CURRENT_DATE,
  daily_writes BIGINT NOT NULL DEFAULT 0 CHECK (daily_writes >= 0),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO sync_user_usage (user_id)
SELECT id FROM app_users
ON CONFLICT (user_id) DO NOTHING;

UPDATE sync_user_usage usage
SET entity_count = source.entity_count,
    entity_bytes = source.entity_bytes
FROM (
  SELECT user_id, count(*)::bigint AS entity_count,
         COALESCE(sum(octet_length(payload::text)), 0)::bigint AS entity_bytes
  FROM sync_entities
  GROUP BY user_id
) source
WHERE usage.user_id = source.user_id;

UPDATE sync_user_usage usage
SET change_count = source.change_count,
    change_bytes = source.change_bytes,
    daily_writes = source.daily_writes,
    daily_write_date = CURRENT_DATE
FROM (
  SELECT user_id, count(*)::bigint AS change_count,
         COALESCE(sum(octet_length(payload::text)), 0)::bigint AS change_bytes,
         count(*) FILTER (WHERE created_at >= date_trunc('day', now()))::bigint AS daily_writes
  FROM sync_changes
  GROUP BY user_id
) source
WHERE usage.user_id = source.user_id;

CREATE TABLE IF NOT EXISTS account_debts (
  user_id UUID PRIMARY KEY REFERENCES app_users(id) ON DELETE CASCADE,
  iap_debt_points BIGINT NOT NULL DEFAULT 0 CHECK (iap_debt_points >= 0),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE iap_orders
  ADD COLUMN IF NOT EXISTS order_status TEXT NOT NULL DEFAULT 'CREDITED',
  ADD COLUMN IF NOT EXISTS last_checked_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS reversed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS debt_offset_points BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS reversed_points BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS debt_points BIGINT NOT NULL DEFAULT 0;

ALTER TABLE iap_orders
  DROP CONSTRAINT IF EXISTS iap_orders_reversed_points_check,
  DROP CONSTRAINT IF EXISTS iap_orders_debt_offset_points_check,
  DROP CONSTRAINT IF EXISTS iap_orders_debt_points_check;

ALTER TABLE iap_orders
  ADD CONSTRAINT iap_orders_reversed_points_check
    CHECK (reversed_points >= 0 AND reversed_points <= credited_points),
  ADD CONSTRAINT iap_orders_debt_offset_points_check
    CHECK (debt_offset_points >= 0 AND debt_offset_points <= credited_points),
  ADD CONSTRAINT iap_orders_debt_points_check
    CHECK (debt_points >= 0 AND debt_points <= credited_points);

CREATE INDEX IF NOT EXISTS iap_orders_reconciliation_idx
  ON iap_orders((COALESCE(last_checked_at, created_at)), created_at)
  WHERE reversed_at IS NULL;
