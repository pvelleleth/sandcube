CREATE TABLE IF NOT EXISTS host_capacity (
  singleton integer PRIMARY KEY DEFAULT 1 CHECK(singleton = 1),
  cpu bigint NOT NULL CHECK(cpu > 0),
  memory_mb bigint NOT NULL CHECK(memory_mb > 0),
  disk_mb bigint NOT NULL CHECK(disk_mb > 0)
);
