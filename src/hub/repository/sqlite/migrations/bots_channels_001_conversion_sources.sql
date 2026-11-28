-- Internal, immutable evidence for scoped vault conversion. No provider
-- plaintext, encrypted message body or vault key is stored here.
-- Legacy binding rows receive no grant. Future pairing can attest only a new
-- binding generation; a grant never makes a revoked binding active again.
CREATE TABLE IF NOT EXISTS bot_channel_conversion_bindings (
    binding_id TEXT PRIMARY KEY NOT NULL,
    activation_generation INTEGER NOT NULL CHECK (activation_generation > 0),
    binding_generation INTEGER NOT NULL CHECK (binding_generation > 0)
);

-- Written with the canonical inbound by trusted adapter code. Keep the
-- reference after purge so a vanished input never gets a replacement identity.
CREATE TABLE IF NOT EXISTS bot_channel_conversion_origins (
    inbound_message_id TEXT PRIMARY KEY NOT NULL,
    binding_id TEXT NOT NULL REFERENCES bot_channel_conversion_bindings(binding_id),
    provider_update_key TEXT NOT NULL CHECK (provider_update_key <> ''),
    UNIQUE (binding_id, provider_update_key)
);

-- A unique, chosen input, written by the trusted turn-routing service. An
-- ambiguous or unsupported route does not get a conversion grant.
CREATE TABLE IF NOT EXISTS bot_channel_conversion_replies (
    reply_message_id TEXT PRIMARY KEY NOT NULL,
    inbound_message_id TEXT NOT NULL REFERENCES bot_channel_conversion_origins(inbound_message_id),
    source_proof TEXT NOT NULL CHECK (length(source_proof) = 64 AND source_proof NOT GLOB '*[^0-9a-f]*')
);

-- Zero identifies a legacy invitation. Canonical issuance alone sets a
-- positive generation, and neither consume path accepts the other's codes.
ALTER TABLE channel_pairings ADD COLUMN activation_generation INTEGER NOT NULL DEFAULT 0 CHECK (activation_generation >= 0);
