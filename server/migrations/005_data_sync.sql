CREATE TABLE IF NOT EXISTS sync_devices (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  device_name TEXT NOT NULL DEFAULT '',
  platform TEXT NOT NULL DEFAULT '',
  app_version TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS sync_devices_user_seen_idx
  ON sync_devices(user_id, last_seen_at DESC);

CREATE TABLE IF NOT EXISTS sync_entities (
  user_id UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  revision BIGINT NOT NULL CHECK (revision > 0),
  payload JSONB,
  deleted_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by_device UUID NOT NULL,
  PRIMARY KEY (user_id, entity_type, entity_id),
  CONSTRAINT sync_entities_payload_check CHECK (
    (deleted_at IS NULL AND payload IS NOT NULL) OR
    (deleted_at IS NOT NULL AND payload IS NULL)
  )
);

CREATE TABLE IF NOT EXISTS sync_changes (
  sequence_id BIGSERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  revision BIGINT NOT NULL CHECK (revision > 0),
  operation TEXT NOT NULL CHECK (operation IN ('upsert', 'delete')),
  payload JSONB,
  device_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sync_changes_user_sequence_idx
  ON sync_changes(user_id, sequence_id);

CREATE TABLE IF NOT EXISTS sync_operation_receipts (
  user_id UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  operation_id UUID NOT NULL,
  device_id UUID NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  accepted BOOLEAN NOT NULL,
  revision BIGINT NOT NULL CHECK (revision >= 0),
  sequence_id BIGINT,
  conflict_payload JSONB,
  conflict_deleted BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, operation_id)
);

CREATE INDEX IF NOT EXISTS sync_operation_receipts_created_idx
  ON sync_operation_receipts(created_at);
