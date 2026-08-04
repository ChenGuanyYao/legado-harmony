CREATE TABLE IF NOT EXISTS theme_catalog (
  theme_id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  price_points BIGINT NOT NULL DEFAULT 60,
  valid_days INTEGER NOT NULL DEFAULT 365,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT theme_catalog_id_check
    CHECK (theme_id ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND length(theme_id) <= 64),
  CONSTRAINT theme_catalog_display_name_check
    CHECK (length(btrim(display_name)) BETWEEN 1 AND 80),
  CONSTRAINT theme_catalog_price_check
    CHECK (price_points BETWEEN 1 AND 1000000),
  CONSTRAINT theme_catalog_valid_days_check
    CHECK (valid_days BETWEEN 1 AND 36500)
);

CREATE INDEX IF NOT EXISTS theme_catalog_enabled_idx
  ON theme_catalog(theme_id)
  WHERE enabled = TRUE;

-- Seed every paid theme currently shipped by the client. DO NOTHING is
-- intentional: rerunning migrations must not overwrite prices or publication
-- state that operators have changed in the database.
INSERT INTO theme_catalog (theme_id, display_name, price_points, valid_days, enabled)
VALUES
  ('classic-blue', '经典蓝', 60, 365, TRUE),
  ('warm-paper', '暖纸', 60, 365, TRUE),
  ('forest-mist', '林雾', 60, 365, TRUE),
  ('ink-wash', '水墨', 60, 365, TRUE),
  ('neon-night', '霓虹', 60, 365, TRUE),
  ('strawberry-cream', '草莓奶霜', 60, 365, TRUE),
  ('crimson-archive', '赤墨档案', 60, 365, TRUE),
  ('plum-tea', '梅影茶烟', 60, 365, TRUE),
  ('rose-letter', '玫瑰来信', 60, 365, TRUE),
  ('moon-crane', '月鹤星河', 60, 365, TRUE),
  ('sword-frost', '剑影青霜', 60, 365, TRUE)
ON CONFLICT (theme_id) DO NOTHING;

-- Migrations are normally executed through DATABASE_URL and therefore create
-- tables as the application role. Some managed environments run migrations as
-- a PostgreSQL administrator instead. In that case, mirror read access from
-- the owner of an existing commerce table so the API can query the catalog
-- without granting write access.
DO $$
DECLARE
  application_role NAME;
BEGIN
  SELECT tableowner
  INTO application_role
  FROM pg_tables
  WHERE schemaname = 'public' AND tablename = 'point_wallets';

  IF application_role IS NOT NULL AND application_role <> current_user THEN
    EXECUTE format('GRANT SELECT ON TABLE theme_catalog TO %I', application_role);
  END IF;
END
$$;
