-- Soft-archive support for projects (REQ-PROJ-ARCHIVE-1), mirroring the agents
-- `state` column added in 002_owner_scoped_core.sql. Default 'active'; archiving
-- is reversible and never removes the row.
ALTER TABLE projects ADD COLUMN state TEXT NOT NULL DEFAULT 'active';
