-- History also counts terminal batch members; routed-only membership is insufficient.
CREATE INDEX action_runs_delivery_history ON action_runs(delivery_id) WHERE delivery_id <> '';
