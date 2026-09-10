CREATE TABLE IF NOT EXISTS sandboxes (
  id text PRIMARY KEY,
  config jsonb NOT NULL,
  status text NOT NULL DEFAULT 'creating',
  intent text,
  expires_at timestamptz,
  error_message text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS sandboxes_expiration ON sandboxes(expires_at) WHERE status != 'deleted';
CREATE TABLE IF NOT EXISTS lifecycle_requests (
  key text PRIMARY KEY,
  fingerprint text NOT NULL,
  sandbox_id text NOT NULL REFERENCES sandboxes(id),
  action text NOT NULL,
  response text,
  response_status integer NOT NULL DEFAULT 200,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS reliability_counters (
  name text PRIMARY KEY,
  value bigint NOT NULL DEFAULT 0
);

ALTER TABLE lifecycle_requests ADD COLUMN IF NOT EXISTS response_status integer NOT NULL DEFAULT 200;
