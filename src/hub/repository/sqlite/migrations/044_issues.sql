-- 044_issues.sql: Create issues, issue_comments, and issue_votes tables (REQ-ISSUES-BACKEND-SCHEMA-SERVICE)

CREATE TABLE IF NOT EXISTS issues (
  issue_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  created_by TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'new',
  scope_type TEXT NOT NULL DEFAULT 'global',
  target_id TEXT NOT NULL DEFAULT '',
  chain_id TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  closed_at TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_issues_owner ON issues(owner_user_id);
CREATE INDEX IF NOT EXISTS idx_issues_owner_status ON issues(owner_user_id, status);
CREATE INDEX IF NOT EXISTS idx_issues_owner_scope ON issues(owner_user_id, scope_type, target_id);
CREATE INDEX IF NOT EXISTS idx_issues_chain ON issues(chain_id);
CREATE TRIGGER IF NOT EXISTS issues_owner_immutable BEFORE UPDATE OF owner_user_id ON issues BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;

CREATE TABLE IF NOT EXISTS issue_comments (
  comment_id TEXT PRIMARY KEY,
  issue_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  author_id TEXT NOT NULL,
  author_name TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT '',
  FOREIGN KEY (issue_id) REFERENCES issues(issue_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_issue_comments_issue ON issue_comments(issue_id, created_at);
CREATE INDEX IF NOT EXISTS idx_issue_comments_owner ON issue_comments(owner_user_id);
CREATE TRIGGER IF NOT EXISTS issue_comments_owner_immutable BEFORE UPDATE OF owner_user_id ON issue_comments BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;

CREATE TABLE IF NOT EXISTS issue_votes (
  issue_id TEXT NOT NULL,
  voter_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  voter_name TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  PRIMARY KEY (issue_id, voter_id),
  FOREIGN KEY (issue_id) REFERENCES issues(issue_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_issue_votes_issue ON issue_votes(issue_id);
CREATE INDEX IF NOT EXISTS idx_issue_votes_voter ON issue_votes(voter_id);
CREATE TRIGGER IF NOT EXISTS issue_votes_owner_immutable BEFORE UPDATE OF owner_user_id ON issue_votes BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
