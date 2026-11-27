-- G6: the runtime transport (PTY/ACP) is chosen per provider profile. 211 let
-- only the canonical row (profile_id = provider) hold a transport. SQLite
-- cannot drop a CHECK, so bridge_provider_settings is rebuilt with the same
-- columns, key and foreign key; nothing references it and it has no triggers
-- or secondary indexes. The named constraint marks completion for
-- run_migrations.
--
-- enabled becomes nullable: NULL means "no explicit enable choice", derived on
-- every read from detection and the profile exactly as with no row. A row that
-- only holds a transport therefore never pins enablement.
--
-- Backfill: a provider-wide choice applied to every profile of that provider
-- on the bridge, so it is copied to each of them. Existing rows keep their
-- enabled value; a profile with no settings row gets a transport-only row
-- (enabled NULL). NULL transport stays NULL (catalog default). Every profile
-- therefore resolves, and is enabled, exactly as before.
BEGIN IMMEDIATE;
CREATE TABLE bridge_provider_settings_v269 (
 bridge_id TEXT NOT NULL, profile_id TEXT NOT NULL, provider TEXT NOT NULL REFERENCES provider_catalog(provider),
 enabled INTEGER DEFAULT NULL CHECK(enabled IS NULL OR enabled IN (0,1)), updated_at TEXT NOT NULL,
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
 SELECT p.bridge_id,p.profile_id,p.provider,NULL,
  c.updated_at,c.transport
 FROM bridge_provider_profiles p
 JOIN bridge_provider_settings c ON c.bridge_id=p.bridge_id AND c.provider=p.provider AND c.profile_id=c.provider
 WHERE p.profile_id<>p.provider AND c.transport IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM bridge_provider_settings s WHERE s.bridge_id=p.bridge_id AND s.profile_id=p.profile_id);
COMMIT;
