ALTER TABLE sync_user_usage
  ADD COLUMN IF NOT EXISTS initial_sync_started_at TIMESTAMPTZ;

COMMENT ON COLUMN sync_user_usage.initial_sync_started_at IS
  'Starts the account one-time enlarged initial-sync write window.';
