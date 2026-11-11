-- Timely D1 schema
CREATE TABLE IF NOT EXISTS users (
  id          TEXT PRIMARY KEY,
  email       TEXT NOT NULL UNIQUE,
  pw_hash     TEXT NOT NULL,   -- base64 PBKDF2-SHA256
  pw_salt     TEXT NOT NULL,   -- base64
  pw_iter     INTEGER NOT NULL,
  created_at  INTEGER NOT NULL
);

-- Every login / paired install is a device with its own bearer token.
CREATE TABLE IF NOT EXISTS devices (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  platform    TEXT NOT NULL,   -- android | linux | windows
  token_hash  TEXT NOT NULL UNIQUE,
  created_at  INTEGER NOT NULL,
  last_seen   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS devices_user ON devices(user_id);

CREATE TABLE IF NOT EXISTS pair_codes (
  code_hash   TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at  INTEGER NOT NULL
);

-- One compressed blob per device per local day.
-- kind 0 = full sessions, 1 = hourly rollup (older than retention window)
CREATE TABLE IF NOT EXISTS chunks (
  user_id     TEXT NOT NULL,
  device_id   TEXT NOT NULL,
  day         TEXT NOT NULL,   -- YYYY-MM-DD
  kind        INTEGER NOT NULL DEFAULT 0,
  data        BLOB NOT NULL,   -- gzip(JSON)
  updated_at  INTEGER NOT NULL,
  PRIMARY KEY (device_id, day)
);
CREATE INDEX IF NOT EXISTS chunks_user_updated ON chunks(user_id, updated_at);
CREATE INDEX IF NOT EXISTS chunks_kind_day ON chunks(kind, day);

CREATE TABLE IF NOT EXISTS settings (
  user_id     TEXT PRIMARY KEY,
  data        TEXT NOT NULL,
  updated_at  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS rate_limits (
  key         TEXT PRIMARY KEY,
  count       INTEGER NOT NULL,
  window_start INTEGER NOT NULL
);
