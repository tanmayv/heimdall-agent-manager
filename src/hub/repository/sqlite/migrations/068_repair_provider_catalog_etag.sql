-- Migration 067 changed the canonical provider catalog body but shipped the
-- previous body's hash. Runtime code derives the etag from the canonical body,
-- so this row is audit metadata only; repair it for existing installations and
-- for operators inspecting the database directly.
DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag)
VALUES ('sha256:fed00363892f968c89acaa087d42921d892853e33f2919015fdced7dfccd604b');
