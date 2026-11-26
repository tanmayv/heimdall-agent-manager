import { readableAgentFallback } from './taskNames';

export function formatFleetRoleName(agentId?: string, identities?: any[]): string {
  if (!agentId) return 'Worker';
  const found = identities?.find((a) => String(a.agent_id || a.agentId || a.id || '') === agentId);
  return found?.name || found?.display_name || readableAgentFallback(agentId);
}
