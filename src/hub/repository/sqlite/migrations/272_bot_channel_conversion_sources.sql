-- Internal, immutable evidence for scoped vault conversion. No provider
-- plaintext, encrypted message body or vault key is stored here.
-- Legacy binding rows receive no grant. Future pairing can attest only a new
-- binding generation; a grant never makes a revoked binding active again.
CREATE TABLE IF NOT EXISTS bot_channel_conversion_bindings (
    binding_id TEXT PRIMARY KEY NOT NULL,
    activation_generation INTEGER NOT NULL CHECK (activation_generation > 0),
    binding_generation INTEGER NOT NULL CHECK (binding_generation > 0),
    pairing_update_key TEXT NOT NULL DEFAULT ''
);

-- Written with the canonical inbound by trusted adapter code. Keep the
-- reference after purge so a vanished input never gets a replacement identity.
CREATE TABLE IF NOT EXISTS bot_channel_conversion_origins (
    inbound_message_id TEXT PRIMARY KEY NOT NULL,
    binding_id TEXT NOT NULL REFERENCES bot_channel_conversion_bindings(binding_id),
    provider_update_key TEXT NOT NULL CHECK (provider_update_key <> ''),
    external_message_id TEXT NOT NULL DEFAULT '',
    UNIQUE (provider_update_key)
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

-- A reply is enqueued only with its immutable conversion proof. Store no
-- plaintext or attachment data in the outbox. Claimed parts are never resent.
CREATE TABLE bot_channel_reply_outbox (
    reply_message_id TEXT PRIMARY KEY REFERENCES bot_channel_conversion_replies(reply_message_id),
    owner_user_id TEXT NOT NULL,
    provider TEXT NOT NULL,
    binding_id TEXT NOT NULL REFERENCES bot_channel_conversion_bindings(binding_id),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','held','sent','failed','unknown','stale')),
    hold_anchor TEXT NOT NULL DEFAULT '',
    next_attempt_ms INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX bot_channel_reply_outbox_pending
    ON bot_channel_reply_outbox(provider, next_attempt_ms, reply_message_id) WHERE status IN ('pending','held');
CREATE TABLE bot_channel_reply_parts (
    reply_message_id TEXT NOT NULL REFERENCES bot_channel_reply_outbox(reply_message_id),
    part_index INTEGER NOT NULL CHECK (part_index >= 0),
    status TEXT NOT NULL CHECK (status IN ('sending','sent','held','failed','unknown')),
    provider_message_id TEXT NOT NULL DEFAULT '',
    window_anchor TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (reply_message_id, part_index)
);

CREATE INDEX bot_channel_reply_parts_provider_id ON bot_channel_reply_parts(provider_message_id) WHERE provider_message_id<>'';

-- Feedback is a durable, coalescing hint. The shared R7 evidence contains
-- only actual agent consumption, not a web read or a preview.
CREATE TABLE bot_channel_feedback (
    inbound_message_id TEXT PRIMARY KEY REFERENCES bot_channel_conversion_origins(inbound_message_id),
    reaction TEXT NOT NULL CHECK (reaction IN ('queued','read')),
    dispatched INTEGER NOT NULL DEFAULT 0 CHECK (dispatched IN (0,1))
);
CREATE INDEX bot_channel_feedback_pending ON bot_channel_feedback(inbound_message_id) WHERE dispatched=0;
CREATE TRIGGER canonical_channel_consumption_feedback AFTER INSERT ON chat_input_consumptions
BEGIN
    INSERT INTO bot_channel_feedback(inbound_message_id,reaction)
    SELECT NEW.message_id,'read' FROM bot_channel_conversion_origins o
    JOIN channel_bindings b ON b.binding_id=o.binding_id
    WHERE o.inbound_message_id=NEW.message_id AND o.external_message_id<>'' AND b.owner_user_id=NEW.owner_user_id
    ON CONFLICT(inbound_message_id) DO UPDATE SET reaction='read',dispatched=0 WHERE reaction='queued';
END;

-- Only authenticated WhatsApp callbacks may enter this metadata-only queue.
-- They may beat the original HTTP acknowledgement to durable storage.
CREATE TABLE bot_channel_whatsapp_receipts (
    event_id TEXT PRIMARY KEY,
    provider_message_id TEXT NOT NULL,
    recipient TEXT NOT NULL,
    provider_code INTEGER NOT NULL,
    received_at TEXT NOT NULL,
    processed INTEGER NOT NULL DEFAULT 0 CHECK (processed IN (0,1))
);
CREATE INDEX bot_channel_whatsapp_receipts_pending ON bot_channel_whatsapp_receipts(provider_message_id) WHERE processed=0;
