BEGIN;

SET LOCAL lock_timeout = '30s';
SET LOCAL statement_timeout = 0;
LOCK TABLE sync_entities IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE sync_changes IN ACCESS EXCLUSIVE MODE;

-- sync_entities is the authoritative current state. Keep only the newest change
-- marker for each entity so a device starting at cursor 0 can still rebuild the
-- complete state without retaining every historical payload.
WITH ranked_changes AS (
  SELECT
    sequence_id,
    row_number() OVER (
      PARTITION BY user_id, entity_type, entity_id
      ORDER BY sequence_id DESC
    ) AS position
  FROM sync_changes
)
DELETE FROM sync_changes marker
USING ranked_changes ranked
WHERE marker.sequence_id = ranked.sequence_id
  AND ranked.position > 1;

-- Remove impossible legacy orphans before enforcing the one-marker invariant.
DELETE FROM sync_changes marker
WHERE NOT EXISTS (
  SELECT 1
  FROM sync_entities entity
  WHERE entity.user_id = marker.user_id
    AND entity.entity_type = marker.entity_type
    AND entity.entity_id = marker.entity_id
);

CREATE UNIQUE INDEX IF NOT EXISTS sync_changes_entity_marker_uidx
  ON sync_changes(user_id, entity_type, entity_id);

ALTER TABLE sync_changes
  DROP COLUMN IF EXISTS revision,
  DROP COLUMN IF EXISTS operation,
  DROP COLUMN IF EXISTS payload,
  DROP COLUMN IF EXISTS device_id,
  DROP COLUMN IF EXISTS created_at;

-- Repair any legacy entity that did not have a corresponding history row. This
-- runs after dropping the old NOT NULL metadata columns, so the migration is
-- safe to rerun if deployment verification is interrupted.
INSERT INTO sync_changes (user_id, entity_type, entity_id)
SELECT entity.user_id, entity.entity_type, entity.entity_id
FROM sync_entities entity
WHERE NOT EXISTS (
  SELECT 1
  FROM sync_changes marker
  WHERE marker.user_id = entity.user_id
    AND marker.entity_type = entity.entity_type
    AND marker.entity_id = entity.entity_id
)
ON CONFLICT (user_id, entity_type, entity_id) DO NOTHING;

COMMENT ON TABLE sync_changes IS
  'One lightweight latest-change marker per sync entity; payload lives only in sync_entities.';

UPDATE sync_user_usage
SET change_count = 0,
    change_bytes = 0,
    updated_at = now();

UPDATE sync_user_usage usage
SET change_count = marker_count.change_count,
    updated_at = now()
FROM (
  SELECT user_id, count(*)::bigint AS change_count
  FROM sync_changes
  GROUP BY user_id
) marker_count
WHERE usage.user_id = marker_count.user_id;

ALTER TABLE sync_entities SET (
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_analyze_scale_factor = 0.01
);

ALTER TABLE sync_changes SET (
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_analyze_scale_factor = 0.01
);

COMMIT;

-- The migration removes large TOAST-backed JSON values. The service must remain
-- stopped while this exclusive rewrite returns their disk space immediately.
VACUUM (FULL, ANALYZE) sync_changes;
ANALYZE sync_entities;
