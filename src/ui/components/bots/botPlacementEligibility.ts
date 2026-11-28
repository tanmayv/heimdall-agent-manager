import type { BotPlacementCandidate } from '../../api/endpoints/bots';

/** Preferred affects automatic ranking, not whether a manual choice is allowed. */
export function botPlacementAllows(rules: BotPlacementCandidate[], bridgeId: string, provider?: string, model?: string) {
  return rules.length === 0 || rules.some(rule =>
    (rule.bridge_id === '*' || rule.bridge_id === bridgeId) &&
    (provider === undefined || rule.provider === '*' || rule.provider === provider) &&
    (model === undefined || rule.model === '*' || rule.model === model));
}
