CREATE VIRTUAL TABLE IF NOT EXISTS task_comments_fts USING fts5(
  body,
  content='task_comments',
  content_rowid='rowid',
  tokenize='unicode61'
);

CREATE TRIGGER IF NOT EXISTS task_comments_ai AFTER INSERT ON task_comments BEGIN
  INSERT INTO task_comments_fts(rowid, body) VALUES (new.rowid, new.body);
END;

CREATE TRIGGER IF NOT EXISTS task_comments_ad AFTER DELETE ON task_comments BEGIN
  INSERT INTO task_comments_fts(task_comments_fts, rowid, body) VALUES('delete', old.rowid, old.body);
END;

CREATE TRIGGER IF NOT EXISTS task_comments_au AFTER UPDATE ON task_comments BEGIN
  INSERT INTO task_comments_fts(task_comments_fts, rowid, body) VALUES('delete', old.rowid, old.body);
  INSERT INTO task_comments_fts(rowid, body) VALUES (new.rowid, new.body);
END;

INSERT INTO task_comments_fts(rowid, body)
  SELECT rowid, body FROM task_comments
  WHERE rowid NOT IN (SELECT rowid FROM task_comments_fts);
