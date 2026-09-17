CREATE TABLE IF NOT EXISTS images (
  id text PRIMARY KEY,
  name text,
  status text NOT NULL CHECK (status IN ('BUILDING','READY','ERROR','DELETING','DELETED')),
  oci_reference text NOT NULL UNIQUE,
  oci_digest text,
  dockerfile text NOT NULL,
  created_at text NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at text NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  error_message text
);
-- Reservations precede runtime creation and survive failed rollback/restarts.
CREATE TABLE IF NOT EXISTS sandbox_images (
  sandbox_id text PRIMARY KEY,
  image_id text NOT NULL REFERENCES images(id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS sandbox_images_image_id ON sandbox_images(image_id);
