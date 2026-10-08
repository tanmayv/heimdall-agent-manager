-- REQ-IMPL-3 (REQ-ENROLL-13, design §7.2/§7.4/§9.3): the expiring bridge credential
-- pair and the rotation state that makes refresh-token THEFT detectable.
--
-- WHY A SEPARATE TABLE AND NOT MORE COLUMNS ON `bridges`. A bridge holds a PAIR of
-- credentials (`hba_` access, `hbf_` refresh) and, across rotations, a LINEAGE of
-- them. Reuse detection (§7.4.3) needs to answer "was this exact refresh token
-- already spent?" after a newer generation exists, so a consumed row must survive
-- its own replacement — which a single current-credential column cannot express.
-- `bridges.bridge_token_hash` is deliberately left alone: it holds the legacy
-- non-expiring `hbr_` credential, which REQ-IMPL-6 removes, not this migration.
--
-- token_id IS THE PUBLIC LOOKUP KEY, and that is settled 6 (chain description). The
-- token is `<prefix><token_id>.<secret>`; the row is found by this primary key and the
-- secret is then verified in constant time against token_hash. This is what allows a
-- per-token random salt at all — the old `WHERE token_hash = ?` shape forced the
-- stored value to be a deterministic function of the secret and therefore unsaltable.
--
-- family_id IS THE UNIT OF REVOCATION. Every generation of a rotation lineage carries
-- the same family_id, so detecting one replayed refresh token revokes the lineage in
-- one UPDATE rather than by walking a parent chain. One family per enrollment: a
-- re-enrolled machine gets a new family, so revoking the old one cannot disturb it.
--
-- NO FOREIGN KEY to bridges(bridge_id), matching every other table in this schema
-- (shell_sessions, lsp_server_configs). Enforcement lives in the service layer here,
-- and adding the hub's first FK in the one table on the authentication hot path is
-- not the place to change that convention.
CREATE TABLE IF NOT EXISTS bridge_tokens (
  token_id   TEXT PRIMARY KEY,
  bridge_id  TEXT NOT NULL,
  kind       TEXT NOT NULL,                 -- 'access' | 'refresh'
  token_hash TEXT NOT NULL,                 -- sha256:v1:<salt_hex>:<digest_hex>
  family_id  TEXT NOT NULL,
  generation INTEGER NOT NULL DEFAULT 0,
  scope      TEXT NOT NULL DEFAULT 'bridge:runtime',
  issued_at  TEXT NOT NULL,
  expires_at TEXT NOT NULL,                 -- RFC3339 UTC; '' is never written
  family_expires_at TEXT NOT NULL DEFAULT '', -- absolute cap (§7.4.5); outlives sliding renewal
  rotated_at TEXT NOT NULL DEFAULT '',      -- non-empty => spent; presenting it again is theft
  revoked_at TEXT NOT NULL DEFAULT ''
);

-- Per-bridge revocation (§11.7) walks every row of one machine: "revoke bridge A"
-- must touch nothing belonging to bridge B.
CREATE INDEX IF NOT EXISTS bridge_tokens_bridge ON bridge_tokens(bridge_id);
-- Family revocation on reuse detection (§7.4.3) is the hot write path of this table.
CREATE INDEX IF NOT EXISTS bridge_tokens_family ON bridge_tokens(family_id);
