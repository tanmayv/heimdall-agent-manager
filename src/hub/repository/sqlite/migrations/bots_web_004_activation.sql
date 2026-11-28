-- Permanent identity of the fresh chat and current opt-in generation. Disabling
-- never deletes this row, which also fences admission to the legacy bot.
CREATE TABLE IF NOT EXISTS bot_web_activations (
    owner_user_id TEXT PRIMARY KEY NOT NULL,
    bot_id TEXT NOT NULL UNIQUE,
    agent_instance_id TEXT NOT NULL UNIQUE,
    conversation_id TEXT NOT NULL UNIQUE,
    enabled INTEGER NOT NULL CHECK (enabled IN (0,1)),
    generation INTEGER NOT NULL CHECK (generation >= 1)
);

-- Accepted request identities outlive payload retention. No plaintext,
-- ciphertext, fingerprint or separate copy of the message is stored here.
CREATE TABLE IF NOT EXISTS conversation_message_requests (
    message_id TEXT PRIMARY KEY NOT NULL
);
