ALTER TABLE chat_messages ADD COLUMN message_type TEXT NOT NULL DEFAULT 'text';
ALTER TABLE chat_messages ADD COLUMN message_status TEXT NOT NULL DEFAULT 'complete';
ALTER TABLE chat_messages ADD COLUMN metadata_json TEXT NOT NULL DEFAULT '{}';
