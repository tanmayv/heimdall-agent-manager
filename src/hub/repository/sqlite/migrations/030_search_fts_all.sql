CREATE VIRTUAL TABLE IF NOT EXISTS chat_conversations_fts USING fts5(
  title,
  content='chat_conversations',
  content_rowid='rowid',
  tokenize='unicode61'
);

CREATE TRIGGER IF NOT EXISTS chat_conversations_fts_ai AFTER INSERT ON chat_conversations BEGIN
  INSERT INTO chat_conversations_fts(rowid, title) VALUES (new.rowid, new.title);
END;

CREATE TRIGGER IF NOT EXISTS chat_conversations_fts_ad AFTER DELETE ON chat_conversations BEGIN
  INSERT INTO chat_conversations_fts(chat_conversations_fts, rowid, title) VALUES('delete', old.rowid, old.title);
END;

CREATE TRIGGER IF NOT EXISTS chat_conversations_fts_au AFTER UPDATE ON chat_conversations BEGIN
  INSERT INTO chat_conversations_fts(chat_conversations_fts, rowid, title) VALUES('delete', old.rowid, old.title);
  INSERT INTO chat_conversations_fts(rowid, title) VALUES (new.rowid, new.title);
END;

INSERT INTO chat_conversations_fts(chat_conversations_fts) VALUES('rebuild');

CREATE VIRTUAL TABLE IF NOT EXISTS agents_fts USING fts5(
  name, slug, instructions,
  content='agents',
  content_rowid='rowid',
  tokenize='unicode61'
);

CREATE TRIGGER IF NOT EXISTS agents_fts_ai AFTER INSERT ON agents BEGIN
  INSERT INTO agents_fts(rowid, name, slug, instructions) VALUES (new.rowid, new.name, new.slug, new.instructions);
END;

CREATE TRIGGER IF NOT EXISTS agents_fts_ad AFTER DELETE ON agents BEGIN
  INSERT INTO agents_fts(agents_fts, rowid, name, slug, instructions) VALUES('delete', old.rowid, old.name, old.slug, old.instructions);
END;

CREATE TRIGGER IF NOT EXISTS agents_fts_au AFTER UPDATE ON agents BEGIN
  INSERT INTO agents_fts(agents_fts, rowid, name, slug, instructions) VALUES('delete', old.rowid, old.name, old.slug, old.instructions);
  INSERT INTO agents_fts(rowid, name, slug, instructions) VALUES (new.rowid, new.name, new.slug, new.instructions);
END;

INSERT INTO agents_fts(agents_fts) VALUES('rebuild');

CREATE VIRTUAL TABLE IF NOT EXISTS agent_instances_fts USING fts5(
  display_name, agent_id,
  content='agent_instances',
  content_rowid='rowid',
  tokenize='unicode61'
);

CREATE TRIGGER IF NOT EXISTS agent_instances_fts_ai AFTER INSERT ON agent_instances BEGIN
  INSERT INTO agent_instances_fts(rowid, display_name, agent_id) VALUES (new.rowid, new.display_name, new.agent_id);
END;

CREATE TRIGGER IF NOT EXISTS agent_instances_fts_ad AFTER DELETE ON agent_instances BEGIN
  INSERT INTO agent_instances_fts(agent_instances_fts, rowid, display_name, agent_id) VALUES('delete', old.rowid, old.display_name, old.agent_id);
END;

CREATE TRIGGER IF NOT EXISTS agent_instances_fts_au AFTER UPDATE ON agent_instances BEGIN
  INSERT INTO agent_instances_fts(agent_instances_fts, rowid, display_name, agent_id) VALUES('delete', old.rowid, old.display_name, old.agent_id);
  INSERT INTO agent_instances_fts(rowid, display_name, agent_id) VALUES (new.rowid, new.display_name, new.agent_id);
END;

INSERT INTO agent_instances_fts(agent_instances_fts) VALUES('rebuild');

CREATE VIRTUAL TABLE IF NOT EXISTS task_chains_fts USING fts5(
  title, description,
  content='task_chains',
  content_rowid='rowid',
  tokenize='unicode61'
);

CREATE TRIGGER IF NOT EXISTS task_chains_fts_ai AFTER INSERT ON task_chains BEGIN
  INSERT INTO task_chains_fts(rowid, title, description) VALUES (new.rowid, new.title, new.description);
END;

CREATE TRIGGER IF NOT EXISTS task_chains_fts_ad AFTER DELETE ON task_chains BEGIN
  INSERT INTO task_chains_fts(task_chains_fts, rowid, title, description) VALUES('delete', old.rowid, old.title, old.description);
END;

CREATE TRIGGER IF NOT EXISTS task_chains_fts_au AFTER UPDATE ON task_chains BEGIN
  INSERT INTO task_chains_fts(task_chains_fts, rowid, title, description) VALUES('delete', old.rowid, old.title, old.description);
  INSERT INTO task_chains_fts(rowid, title, description) VALUES (new.rowid, new.title, new.description);
END;

INSERT INTO task_chains_fts(task_chains_fts) VALUES('rebuild');

CREATE VIRTUAL TABLE IF NOT EXISTS tasks_fts USING fts5(
  title, description,
  content='tasks',
  content_rowid='rowid',
  tokenize='unicode61'
);

CREATE TRIGGER IF NOT EXISTS tasks_fts_ai AFTER INSERT ON tasks BEGIN
  INSERT INTO tasks_fts(rowid, title, description) VALUES (new.rowid, new.title, new.description);
END;

CREATE TRIGGER IF NOT EXISTS tasks_fts_ad AFTER DELETE ON tasks BEGIN
  INSERT INTO tasks_fts(tasks_fts, rowid, title, description) VALUES('delete', old.rowid, old.title, old.description);
END;

CREATE TRIGGER IF NOT EXISTS tasks_fts_au AFTER UPDATE ON tasks BEGIN
  INSERT INTO tasks_fts(tasks_fts, rowid, title, description) VALUES('delete', old.rowid, old.title, old.description);
  INSERT INTO tasks_fts(rowid, title, description) VALUES (new.rowid, new.title, new.description);
END;

INSERT INTO tasks_fts(tasks_fts) VALUES('rebuild');

CREATE VIRTUAL TABLE IF NOT EXISTS projects_fts USING fts5(
  name, slug, description,
  content='projects',
  content_rowid='rowid',
  tokenize='unicode61'
);

CREATE TRIGGER IF NOT EXISTS projects_fts_ai AFTER INSERT ON projects BEGIN
  INSERT INTO projects_fts(rowid, name, slug, description) VALUES (new.rowid, new.name, new.slug, new.description);
END;

CREATE TRIGGER IF NOT EXISTS projects_fts_ad AFTER DELETE ON projects BEGIN
  INSERT INTO projects_fts(projects_fts, rowid, name, slug, description) VALUES('delete', old.rowid, old.name, old.slug, old.description);
END;

CREATE TRIGGER IF NOT EXISTS projects_fts_au AFTER UPDATE ON projects BEGIN
  INSERT INTO projects_fts(projects_fts, rowid, name, slug, description) VALUES('delete', old.rowid, old.name, old.slug, old.description);
  INSERT INTO projects_fts(rowid, name, slug, description) VALUES (new.rowid, new.name, new.slug, new.description);
END;

INSERT INTO projects_fts(projects_fts) VALUES('rebuild');

CREATE VIRTUAL TABLE IF NOT EXISTS artifacts_fts USING fts5(
  name, description,
  content='artifacts',
  content_rowid='rowid',
  tokenize='unicode61'
);

CREATE TRIGGER IF NOT EXISTS artifacts_fts_ai AFTER INSERT ON artifacts BEGIN
  INSERT INTO artifacts_fts(rowid, name, description) VALUES (new.rowid, new.name, new.description);
END;

CREATE TRIGGER IF NOT EXISTS artifacts_fts_ad AFTER DELETE ON artifacts BEGIN
  INSERT INTO artifacts_fts(artifacts_fts, rowid, name, description) VALUES('delete', old.rowid, old.name, old.description);
END;

CREATE TRIGGER IF NOT EXISTS artifacts_fts_au AFTER UPDATE ON artifacts BEGIN
  INSERT INTO artifacts_fts(artifacts_fts, rowid, name, description) VALUES('delete', old.rowid, old.name, old.description);
  INSERT INTO artifacts_fts(rowid, name, description) VALUES (new.rowid, new.name, new.description);
END;

INSERT INTO artifacts_fts(artifacts_fts) VALUES('rebuild');

CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
  title, body,
  content='memories',
  content_rowid='rowid',
  tokenize='unicode61'
);

CREATE TRIGGER IF NOT EXISTS memories_fts_ai AFTER INSERT ON memories BEGIN
  INSERT INTO memories_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
END;

CREATE TRIGGER IF NOT EXISTS memories_fts_ad AFTER DELETE ON memories BEGIN
  INSERT INTO memories_fts(memories_fts, rowid, title, body) VALUES('delete', old.rowid, old.title, old.body);
END;

CREATE TRIGGER IF NOT EXISTS memories_fts_au AFTER UPDATE ON memories BEGIN
  INSERT INTO memories_fts(memories_fts, rowid, title, body) VALUES('delete', old.rowid, old.title, old.body);
  INSERT INTO memories_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
END;

INSERT INTO memories_fts(memories_fts) VALUES('rebuild');
