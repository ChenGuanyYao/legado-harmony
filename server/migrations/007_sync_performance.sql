ALTER TABLE sync_devices
  ADD COLUMN IF NOT EXISTS last_sync_cursor BIGINT NOT NULL DEFAULT 0;

ALTER TABLE sync_devices
  ADD COLUMN IF NOT EXISTS last_cursor_at TIMESTAMPTZ;

UPDATE sync_devices
SET last_cursor_at = COALESCE(last_cursor_at, last_seen_at, created_at)
WHERE last_cursor_at IS NULL;

CREATE INDEX IF NOT EXISTS sync_devices_user_cursor_idx
  ON sync_devices(user_id, last_sync_cursor)
  WHERE revoked_at IS NULL;
