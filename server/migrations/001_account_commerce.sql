CREATE TABLE IF NOT EXISTS app_users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  huawei_open_id TEXT NOT NULL UNIQUE,
  huawei_union_id TEXT,
  display_name TEXT NOT NULL DEFAULT '华为用户',
  avatar_url TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS point_wallets (
  user_id UUID PRIMARY KEY REFERENCES app_users(id) ON DELETE CASCADE,
  balance BIGINT NOT NULL DEFAULT 0 CHECK (balance >= 0),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS point_ledger (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  delta BIGINT NOT NULL,
  balance_after BIGINT NOT NULL CHECK (balance_after >= 0),
  reason TEXT NOT NULL,
  reference_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS point_ledger_user_created_idx
  ON point_ledger(user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS theme_entitlements (
  user_id UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  theme_id TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, theme_id)
);

CREATE TABLE IF NOT EXISTS iap_orders (
  purchase_order_id TEXT PRIMARY KEY,
  purchase_token TEXT NOT NULL UNIQUE,
  user_id UUID NOT NULL REFERENCES app_users(id) ON DELETE RESTRICT,
  product_id TEXT NOT NULL,
  credited_points BIGINT NOT NULL CHECK (credited_points > 0),
  verified_payload JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS iap_orders_user_created_idx
  ON iap_orders(user_id, created_at DESC);
