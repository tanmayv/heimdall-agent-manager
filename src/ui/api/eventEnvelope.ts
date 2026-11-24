/** Public producer envelope; internal timer messages use their own shape. */
export interface EventEnvelope {
  event_id: string;
  type: string;
  class: 'state' | 'occurrence' | 'resolvable';
  owner_user_id: string;
  entity: { kind: 'chain' | 'task' | 'memory' | 'webhook'; id: string };
  entity_version: number;
  actor: string;
  occurred_at: string;
  data: Record<string, unknown>;
  topic_key?: string;
  topic_generation?: number;
}
