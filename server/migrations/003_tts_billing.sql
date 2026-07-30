ALTER TABLE point_wallets
  ADD COLUMN IF NOT EXISTS paid_balance BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS promo_balance BIGINT NOT NULL DEFAULT 0;

-- Rebuild the two balance buckets from the existing ledger. Historical theme
-- redemptions consume promotional points first so no paid balance is lost.
WITH wallet_history AS (
  SELECT
    w.user_id,
    w.balance,
    COALESCE(SUM(CASE WHEN l.reason = 'WELCOME_GRANT' AND l.delta > 0 THEN l.delta ELSE 0 END), 0)
      AS promo_credits,
    COALESCE(SUM(CASE WHEN l.delta < 0 THEN -l.delta ELSE 0 END), 0) AS spent
  FROM point_wallets w
  LEFT JOIN point_ledger l ON l.user_id = w.user_id
  GROUP BY w.user_id, w.balance
),
rebuilt AS (
  SELECT
    user_id,
    GREATEST(0, LEAST(balance, promo_credits - spent))::BIGINT AS promo_remaining,
    balance
  FROM wallet_history
)
UPDATE point_wallets w
SET
  promo_balance = r.promo_remaining,
  paid_balance = r.balance - r.promo_remaining
FROM rebuilt r
WHERE w.user_id = r.user_id;

ALTER TABLE point_wallets
  DROP CONSTRAINT IF EXISTS point_wallets_paid_balance_check,
  DROP CONSTRAINT IF EXISTS point_wallets_promo_balance_check,
  DROP CONSTRAINT IF EXISTS point_wallets_balance_components_check;

ALTER TABLE point_wallets
  ADD CONSTRAINT point_wallets_paid_balance_check CHECK (paid_balance >= 0),
  ADD CONSTRAINT point_wallets_promo_balance_check CHECK (promo_balance >= 0),
  ADD CONSTRAINT point_wallets_balance_components_check
    CHECK (balance = paid_balance + promo_balance);

CREATE TABLE IF NOT EXISTS tts_quota_grants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  tier TEXT NOT NULL CHECK (tier IN ('STANDARD', 'PREMIUM')),
  source TEXT NOT NULL CHECK (source IN ('TRIAL', 'POINT_REDEEM', 'ADMIN', 'REFUND')),
  total_chars BIGINT NOT NULL CHECK (total_chars > 0),
  remaining_chars BIGINT NOT NULL CHECK (remaining_chars >= 0 AND remaining_chars <= total_chars),
  expires_at TIMESTAMPTZ NOT NULL,
  reference_id TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS tts_quota_grants_available_idx
  ON tts_quota_grants(user_id, tier, expires_at, created_at)
  WHERE remaining_chars > 0;

CREATE TABLE IF NOT EXISTS tts_quota_ledger (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  grant_id UUID REFERENCES tts_quota_grants(id) ON DELETE SET NULL,
  tier TEXT NOT NULL CHECK (tier IN ('STANDARD', 'PREMIUM')),
  delta_chars BIGINT NOT NULL,
  balance_after BIGINT NOT NULL CHECK (balance_after >= 0),
  reason TEXT NOT NULL,
  reference_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS tts_quota_ledger_user_created_idx
  ON tts_quota_ledger(user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS tts_usage (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  request_id TEXT NOT NULL,
  voice_id TEXT NOT NULL,
  tier TEXT NOT NULL CHECK (tier IN ('STANDARD', 'PREMIUM')),
  raw_chars INTEGER NOT NULL CHECK (raw_chars > 0),
  charged_chars INTEGER NOT NULL CHECK (charged_chars >= raw_chars),
  status TEXT NOT NULL CHECK (status IN ('RESERVED', 'SUCCEEDED', 'FAILED', 'REFUNDED')),
  huawei_trace_id TEXT,
  error_code TEXT,
  retry_count INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
  audio_hash TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  UNIQUE (user_id, request_id)
);

CREATE INDEX IF NOT EXISTS tts_usage_user_created_idx
  ON tts_usage(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS tts_usage_reserved_created_idx
  ON tts_usage(created_at)
  WHERE status = 'RESERVED';

CREATE TABLE IF NOT EXISTS tts_package_redemptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  sku TEXT NOT NULL,
  tier TEXT NOT NULL CHECK (tier IN ('STANDARD', 'PREMIUM')),
  chars BIGINT NOT NULL CHECK (chars > 0),
  points_spent BIGINT NOT NULL CHECK (points_spent > 0),
  point_ledger_id UUID NOT NULL REFERENCES point_ledger(id) ON DELETE RESTRICT,
  quota_grant_id UUID NOT NULL REFERENCES tts_quota_grants(id) ON DELETE RESTRICT,
  request_id TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, request_id)
);

CREATE INDEX IF NOT EXISTS tts_package_redemptions_user_created_idx
  ON tts_package_redemptions(user_id, created_at DESC);
