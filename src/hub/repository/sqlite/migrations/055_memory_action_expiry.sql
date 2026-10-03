ALTER TABLE memories ADD COLUMN expires_at TEXT NOT NULL DEFAULT '';
UPDATE memories SET expires_at = strftime('%Y-%m-%dT%H:%M:%SZ', datetime(created_at, '+24 hours')) WHERE status = 'pending';
UPDATE cards SET ttl_at = strftime('%Y-%m-%dT%H:%M:%SZ', datetime(created_at, '+24 hours')) WHERE status = 'pending' AND (ttl_at IS NULL OR ttl_at = '');
