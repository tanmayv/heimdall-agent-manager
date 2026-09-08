ALTER TABLE projects ADD COLUMN project_type TEXT NOT NULL DEFAULT 'local';
ALTER TABLE projects ADD COLUMN workspace_name TEXT NOT NULL DEFAULT '';
ALTER TABLE projects ADD COLUMN relative_path TEXT NOT NULL DEFAULT '';
CREATE INDEX IF NOT EXISTS idx_projects_owner_type ON projects(owner_user_id, project_type);
