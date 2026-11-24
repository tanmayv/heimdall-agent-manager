-- Config is the source of truth on every subsequent save. Rewrite it together
-- with the derived tree; subjects already pin the same entity and stay intact.
BEGIN IMMEDIATE;
UPDATE action_triggers
SET data_filter = CASE
 WHEN (SELECT count(*) FROM json_each(config, '$.data')) = 0 THEN '{}'
 ELSE json_object('all', json((
  SELECT json_group_array(json_object('field','data.' || key,'op','eq','value',value))
  FROM (SELECT key,value FROM json_each(action_triggers.config,'$.data') ORDER BY key)
 ))) END
WHERE kind = 'event';

UPDATE action_triggers
SET config = CASE
 WHEN json_type(config,'$.chain_id') IS NOT NULL
 THEN json_set(json_remove(config,'$.chain_id','$.data'),'$.entity_id',json_extract(config,'$.chain_id'))
 ELSE json_remove(config,'$.data') END
WHERE kind = 'event';

UPDATE action_triggers
SET config = CASE
 WHEN json_type(config,'$.entity_id') IS NOT NULL AND data_filter <> '{}'
 THEN json_object('entity_id',json_extract(config,'$.entity_id'),'event_type',json_extract(config,'$.event_type'),'filter',json(data_filter))
 WHEN json_type(config,'$.entity_id') IS NOT NULL
 THEN json_object('entity_id',json_extract(config,'$.entity_id'),'event_type',json_extract(config,'$.event_type'))
 WHEN data_filter <> '{}'
 THEN json_object('event_type',json_extract(config,'$.event_type'),'filter',json(data_filter))
 ELSE json_object('event_type',json_extract(config,'$.event_type')) END
WHERE kind = 'event';
COMMIT;
