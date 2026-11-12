ALTER TABLE task_leases ADD COLUMN phase TEXT NOT NULL DEFAULT 'active' CHECK (phase IN ('active', 'waiting'));
UPDATE task_leases SET expires_at='', hard_deadline_at='';
