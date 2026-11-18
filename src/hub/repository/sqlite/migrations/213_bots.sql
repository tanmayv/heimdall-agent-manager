-- 209_bots.sql: bots slice 1 (experiment "bots")

CREATE TABLE IF NOT EXISTS bots (
  bot_id              TEXT PRIMARY KEY,                 -- "bot_..."
  owner_user_id       TEXT NOT NULL UNIQUE,             -- one bot per user
  agent_id            TEXT NOT NULL,                    -- "agt_..." (template tmpl_bot)
  agent_instance_id   TEXT NOT NULL DEFAULT '',         -- "" until first dispatch
  display_name        TEXT NOT NULL DEFAULT 'Ninjy bot',
  placement_revision  INTEGER NOT NULL DEFAULT 1,
  created_at          TEXT NOT NULL,
  updated_at          TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS bot_placement_candidates (
  bot_id     TEXT NOT NULL REFERENCES bots(bot_id) ON DELETE CASCADE,
  position   INTEGER NOT NULL CHECK (position >= 0),
  bridge_id  TEXT NOT NULL,                             -- "brg_..." or "*"
  provider   TEXT NOT NULL,                             -- catalog provider id or "*"
  model      TEXT NOT NULL,                             -- model id or "*"
  tier       TEXT NOT NULL CHECK (tier IN ('preferred','allowed')),
  PRIMARY KEY (bot_id, position),
  CHECK (NOT (provider = '*' AND model <> '*'))
);

CREATE TABLE IF NOT EXISTS channel_bindings (
  binding_id         TEXT PRIMARY KEY,                  -- "chb_..."
  owner_user_id      TEXT NOT NULL,
  bot_id             TEXT NOT NULL,
  provider           TEXT NOT NULL CHECK (provider IN ('telegram')),
  external_chat_id   TEXT NOT NULL,                     -- Telegram chat.id as decimal text
  external_user_id   TEXT NOT NULL,                     -- Telegram from.id as decimal text
  external_display   TEXT NOT NULL DEFAULT '',          -- "@username" or first name
  state              TEXT NOT NULL CHECK (state IN ('active','revoked')),
  created_at         TEXT NOT NULL,
  revoked_at         TEXT NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX IF NOT EXISTS channel_bindings_active_chat
  ON channel_bindings(provider, external_chat_id) WHERE state = 'active';
CREATE UNIQUE INDEX IF NOT EXISTS channel_bindings_active_owner
  ON channel_bindings(owner_user_id, provider) WHERE state = 'active';

CREATE TABLE IF NOT EXISTS channel_pairings (
  code_hash      TEXT PRIMARY KEY,                      -- hex SHA-256 of the code
  owner_user_id  TEXT NOT NULL,
  bot_id         TEXT NOT NULL,
  provider       TEXT NOT NULL CHECK (provider IN ('telegram')),
  created_at     TEXT NOT NULL,
  expires_at     TEXT NOT NULL,
  consumed_at    TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS channel_pairings_owner ON channel_pairings(owner_user_id, provider);

CREATE TABLE IF NOT EXISTS channel_cursors (
  provider    TEXT PRIMARY KEY,                         -- "telegram"
  cursor      TEXT NOT NULL,                            -- Telegram: next offset as decimal text
  updated_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS channel_messages (
  message_id           TEXT PRIMARY KEY,                -- "chm_..."
  binding_id           TEXT NOT NULL,
  owner_user_id        TEXT NOT NULL,
  bot_id               TEXT NOT NULL,
  direction            TEXT NOT NULL CHECK (direction IN ('inbound','outbound')),
  provider_update_key  TEXT NOT NULL DEFAULT '',        -- inbound: "telegram:<bot_user_id>:<update_id>"
  external_message_id  TEXT NOT NULL DEFAULT '',
  body                 TEXT NOT NULL,                   -- plaintext; '' once purged
  body_purged          INTEGER NOT NULL DEFAULT 0 CHECK (body_purged IN (0,1)),
  send_state           TEXT NOT NULL DEFAULT '' CHECK (send_state IN ('','pending','sent','failed')),
  send_error           TEXT NOT NULL DEFAULT '',
  created_at           TEXT NOT NULL,
  read_at              TEXT NOT NULL DEFAULT '',
  replied_at           TEXT NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX IF NOT EXISTS channel_messages_update_key
  ON channel_messages(provider_update_key) WHERE provider_update_key <> '';
CREATE INDEX IF NOT EXISTS channel_messages_bot_pending
  ON channel_messages(bot_id, direction, replied_at, created_at);

CREATE TABLE IF NOT EXISTS bot_deliveries (
  delivery_id          TEXT PRIMARY KEY,                -- "bdl_..."
  bot_id               TEXT NOT NULL,
  owner_user_id        TEXT NOT NULL,
  through_message_id   TEXT NOT NULL,                   -- newest inbound message covered
  state                TEXT NOT NULL CHECK (state IN ('pending','dispatched','waiting','acted','abandoned')),
  round                INTEGER NOT NULL DEFAULT 1,
  waiting_reason       TEXT NOT NULL DEFAULT '',
  waiting_notice_at    TEXT NOT NULL DEFAULT '',
  finish_reason        TEXT NOT NULL DEFAULT '',
  created_at           TEXT NOT NULL,
  updated_at           TEXT NOT NULL,
  finished_at          TEXT NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX IF NOT EXISTS bot_deliveries_one_open
  ON bot_deliveries(bot_id) WHERE state IN ('pending','dispatched','waiting');

CREATE TABLE IF NOT EXISTS bot_delivery_attempts (
  attempt_id        TEXT PRIMARY KEY,                   -- "bda_..."
  delivery_id       TEXT NOT NULL REFERENCES bot_deliveries(delivery_id) ON DELETE CASCADE,
  round             INTEGER NOT NULL,
  bridge_id         TEXT NOT NULL,
  state             TEXT NOT NULL CHECK (state IN ('relocating','sent','accepted','acted','exhausted','busy','disconnected','deadline','cancelled')),
  relocation_key    TEXT NOT NULL DEFAULT '',           -- idempotency key used for begin_instance_reconfiguration
  candidates_json   TEXT NOT NULL DEFAULT '[]',         -- expanded candidates sent to the bridge
  report_json       TEXT NOT NULL DEFAULT '{}',         -- last bot_delivery_report payload
  report_seq        INTEGER NOT NULL DEFAULT 0,
  sent_at           TEXT NOT NULL DEFAULT '',
  accepted_at       TEXT NOT NULL DEFAULT '',
  last_report_at    TEXT NOT NULL DEFAULT '',
  disconnected_at   TEXT NOT NULL DEFAULT '',
  created_at        TEXT NOT NULL,
  finished_at       TEXT NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX IF NOT EXISTS bot_delivery_attempts_round_bridge
  ON bot_delivery_attempts(delivery_id, round, bridge_id);
CREATE INDEX IF NOT EXISTS bot_delivery_attempts_open
  ON bot_delivery_attempts(state) WHERE state IN ('relocating','sent','accepted');
