CREATE TABLE IF NOT EXISTS sandboxes (
  id text PRIMARY KEY,
  config text NOT NULL,
  status text NOT NULL DEFAULT 'creating',
  intent text,
  expires_at text,
  error_message text,
  reserved_cpu integer NOT NULL DEFAULT 0,
  reserved_memory_mb integer NOT NULL DEFAULT 0,
  reserved_disk_mb integer NOT NULL DEFAULT 0,
  created_at text NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at text NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS sandboxes_expiration ON sandboxes(expires_at) WHERE status != 'deleted';
CREATE TABLE IF NOT EXISTS lifecycle_requests (
  key text PRIMARY KEY,
  fingerprint text NOT NULL,
  sandbox_id text NOT NULL REFERENCES sandboxes(id),
  action text NOT NULL,
  response text,
  response_status integer NOT NULL DEFAULT 200,
  created_at text NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE TABLE IF NOT EXISTS reliability_counters (
  name text PRIMARY KEY,
  value bigint NOT NULL DEFAULT 0
);
