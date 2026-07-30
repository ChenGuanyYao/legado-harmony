ALTER TABLE tts_usage
  ADD COLUMN IF NOT EXISTS input_hash TEXT NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS tts_usage_created_idx
  ON tts_usage(created_at DESC);

CREATE TABLE IF NOT EXISTS tts_usage_allocations (
  usage_id UUID NOT NULL REFERENCES tts_usage(id) ON DELETE CASCADE,
  grant_id UUID NOT NULL REFERENCES tts_quota_grants(id) ON DELETE RESTRICT,
  reserved_chars BIGINT NOT NULL CHECK (reserved_chars > 0),
  refunded_at TIMESTAMPTZ,
  PRIMARY KEY (usage_id, grant_id)
);

CREATE INDEX IF NOT EXISTS tts_usage_allocations_grant_idx
  ON tts_usage_allocations(grant_id);
