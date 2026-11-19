-- Ack lookups start at event_id, never at an agent's entire delivery history.
CREATE INDEX event_deliveries_event ON event_deliveries(event_id,subscription_id);
ALTER TABLE event_deliveries ADD COLUMN recorded_at TEXT NOT NULL DEFAULT '';
UPDATE event_deliveries SET recorded_at=strftime('%Y-%m-%dT%H:%M:%SZ','now');
CREATE INDEX event_deliveries_recorded_at ON event_deliveries(recorded_at);
