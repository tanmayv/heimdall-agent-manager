-- MSG-1: index chat MESSAGE bodies for search (today only conversation titles are
-- indexed, via chat_conversations_fts). External-content fts5 over chat_messages,
-- synced by AI/AD/AU triggers exactly like the other tables (029/030).
CREATE VIRTUAL TABLE IF NOT EXISTS chat_messages_fts USING fts5(
  body,
  content='chat_messages',
  content_rowid='rowid',
  tokenize='unicode61'
);

CREATE TRIGGER IF NOT EXISTS chat_messages_fts_ai AFTER INSERT ON chat_messages BEGIN
  INSERT INTO chat_messages_fts(rowid, body) VALUES (new.rowid, new.body);
END;

CREATE TRIGGER IF NOT EXISTS chat_messages_fts_ad AFTER DELETE ON chat_messages BEGIN
  INSERT INTO chat_messages_fts(chat_messages_fts, rowid, body) VALUES('delete', old.rowid, old.body);
END;

CREATE TRIGGER IF NOT EXISTS chat_messages_fts_au AFTER UPDATE ON chat_messages BEGIN
  INSERT INTO chat_messages_fts(chat_messages_fts, rowid, body) VALUES('delete', old.rowid, old.body);
  INSERT INTO chat_messages_fts(rowid, body) VALUES (new.rowid, new.body);
END;

-- Populate with the CORRECT external-content op. Do NOT use
-- 'INSERT ... SELECT ... WHERE rowid NOT IN (SELECT rowid FROM chat_messages_fts)':
-- on an external-content table that subquery reads THROUGH to the base table, so it
-- excludes every row and indexes nothing (the 029/030 backfill bug fixed here too).
INSERT INTO chat_messages_fts(chat_messages_fts) VALUES('rebuild');
