-- G6: the runtime transport (PTY/ACP) is chosen per provider profile. 211 let
-- only the canonical row (profile_id = provider) hold a transport. SQLite
-- cannot drop a CHECK, so bridge_provider_settings is rebuilt with the same
-- columns, key and foreign key; nothing references it and it has no triggers
-- or secondary indexes. The named constraint marks completion for
-- run_migrations.
--
-- Backfill: a provider-wide choice applied to every profile of that provider
-- on the bridge, so it is copied to each of them. Existing rows keep their
-- enabled value; a profile with no settings row gets one with the implicit
-- enabled value the provider view shows for it, exactly as a per-profile
-- transport save materializes it (set_provider_transport_sqlite). NULL stays
-- NULL (catalog default). Every profile therefore resolves as before.
BEGIN;
CREATE TABLE bridge_provider_settings_v269 (
 bridge_id TEXT NOT NULL, profile_id TEXT NOT NULL, provider TEXT NOT NULL REFERENCES provider_catalog(provider),
 enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN (0,1)), updated_at TEXT NOT NULL,
 transport TEXT DEFAULT NULL CONSTRAINT profile_transport CHECK (transport IS NULL OR transport IN ('pty','acp')),
 PRIMARY KEY(bridge_id,profile_id)
);
INSERT INTO bridge_provider_settings_v269(bridge_id,profile_id,provider,enabled,updated_at,transport)
 SELECT bridge_id,profile_id,provider,enabled,updated_at,transport FROM bridge_provider_settings;
DROP TABLE bridge_provider_settings;
ALTER TABLE bridge_provider_settings_v269 RENAME TO bridge_provider_settings;

UPDATE bridge_provider_settings SET transport=(
  SELECT c.transport FROM bridge_provider_settings c
  WHERE c.bridge_id=bridge_provider_settings.bridge_id AND c.provider=bridge_provider_settings.provider AND c.profile_id=c.provider)
WHERE profile_id<>provider AND transport IS NULL AND EXISTS (
  SELECT 1 FROM bridge_provider_settings c
  WHERE c.bridge_id=bridge_provider_settings.bridge_id AND c.provider=bridge_provider_settings.provider
    AND c.profile_id=c.provider AND c.transport IS NOT NULL);

INSERT INTO bridge_provider_settings(bridge_id,profile_id,provider,enabled,updated_at,transport)
 SELECT p.bridge_id,p.profile_id,p.provider,
  CASE WHEN EXISTS (SELECT 1 FROM bridge_provider_status st WHERE st.bridge_id=p.bridge_id AND st.provider=p.provider AND st.profile_id=p.profile_id AND st.state='present')
   AND p.enabled=1 AND p.state<>'missing' THEN 1 ELSE 0 END,
  c.updated_at,c.transport
 FROM bridge_provider_profiles p
 JOIN bridge_provider_settings c ON c.bridge_id=p.bridge_id AND c.provider=p.provider AND c.profile_id=c.provider
 WHERE p.profile_id<>p.provider AND c.transport IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM bridge_provider_settings s WHERE s.bridge_id=p.bridge_id AND s.profile_id=p.profile_id);
COMMIT;
