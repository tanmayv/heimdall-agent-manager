ALTER TABLE memories ADD COLUMN description TEXT NOT NULL DEFAULT '';
DELETE FROM memories WHERE owner_user_id = 'system' AND (type = 'skill' OR memory_id LIKE 'mem_system_%');
