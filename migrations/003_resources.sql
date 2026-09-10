ALTER TABLE sandboxes ADD COLUMN IF NOT EXISTS reserved_cpu bigint NOT NULL DEFAULT 0;
ALTER TABLE sandboxes ADD COLUMN IF NOT EXISTS reserved_memory_mb bigint NOT NULL DEFAULT 0;
ALTER TABLE sandboxes ADD COLUMN IF NOT EXISTS reserved_disk_mb bigint NOT NULL DEFAULT 0;
-- Initialize only legacy records. Journal reservations survive every later startup.
UPDATE sandboxes SET
  reserved_cpu=CASE WHEN status IN ('stopped','deleted') AND intent IS NULL THEN 0 ELSE (config->>'cpu')::bigint END,
  reserved_memory_mb=CASE WHEN status IN ('stopped','deleted') AND intent IS NULL THEN 0 ELSE (config->>'memory_mb')::bigint END,
  reserved_disk_mb=CASE WHEN status='deleted' THEN 0 ELSE 1024 END,
  config=config || '{"disk_mb":1024}'::jsonb
WHERE NOT config ? 'disk_mb';
CREATE TABLE IF NOT EXISTS host_capacity (
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
  cpu bigint NOT NULL CHECK(cpu > 0),
  memory_mb bigint NOT NULL CHECK(memory_mb > 0),
  disk_mb bigint NOT NULL CHECK(disk_mb > 0)
);
