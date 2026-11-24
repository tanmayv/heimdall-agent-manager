import React from 'react';
import { Button, Select, Alert } from '@ui';
import { useActionPlacementCandidatesQuery, type PlacementRule, type PlacementCandidates } from '../../api/endpoints/actions';

export const ANYWHERE_TEXT = 'Anywhere (the hub picks the first available machine)';
export function bridgeOptionLabel(bridge: PlacementCandidates['bridges'][number]) {
  const reason = bridge.reason === 'missing_feature' ? 'needs a bridge update to run actions' : bridge.reason.replaceAll('_', ' ');
  return bridge.label + (bridge.eligible ? '' : ' · ' + (reason || 'unavailable'));
}
export function updateRule(rule: PlacementRule, key: keyof PlacementRule, value: string): PlacementRule {
  return { ...rule, [key]: value, ...(key === 'provider' ? { model: '*' } : {}) };
}
export function moveRule(rules: PlacementRule[], index: number, delta: number) {
  const next = [...rules]; const to = index + delta;
  if (to < 0 || to >= next.length) return next;
  [next[index], next[to]] = [next[to], next[index]];
  return next;
}
export default function PlacementRulesEditor({ agentId, value, onChange, maxRules }: { agentId: string; value: PlacementRule[]; onChange: (rules: PlacementRule[]) => void; maxRules: number }) {
  const query = useActionPlacementCandidatesQuery({ agent_id: agentId });
  return <div className="flex flex-col gap-3">
    {query.error ? <Alert tone="danger" title="Couldn't load placement options" /> : null}
    {query.isLoading ? <p>Loading placement options…</p> : null}
    {!value.length ? <p>{ANYWHERE_TEXT}</p> : null}
    {value.map((rule, i) => {
      const providers = query.data?.providers || [];
      const models = providers.find(p => p.provider === rule.provider)?.models || [];
      const change = (key: keyof PlacementRule, v: string) => onChange(value.map((r, n) => n === i ? updateRule(r, key, v) : r));
      return <div key={i} className="flex flex-wrap items-center gap-2">
        <span>{i + 1}.</span>
        <Select aria-label={'Machine rule ' + (i + 1)} data-debug-id={'action-rule-bridge-' + i} value={rule.bridge_id} onChange={v => change('bridge_id', v)} options={[{ value: '*', label: 'Any machine' }, ...(query.data?.bridges || []).map(b => ({ value: b.bridge_id, label: bridgeOptionLabel(b) }))]} />
        <Select aria-label={'Provider rule ' + (i + 1)} data-debug-id={'action-rule-provider-' + i} value={rule.provider} onChange={v => change('provider', v)} options={[{ value: '*', label: 'Any provider' }, ...providers.map(p => ({ value: p.provider, label: p.label }))]} />
        <Select aria-label={'Model rule ' + (i + 1)} data-debug-id={'action-rule-model-' + i} value={rule.model} disabled={rule.provider === '*'} onChange={v => change('model', v)} options={[{ value: '*', label: 'Any model' }, ...models.map(m => ({ value: m, label: m }))]} />
        <Button type="button" variant="secondary" disabled={i === 0} data-debug-id={'action-rule-up-' + i} onClick={() => onChange(moveRule(value, i, -1))}>Move up</Button>
        <Button type="button" variant="secondary" disabled={i === value.length - 1} data-debug-id={'action-rule-down-' + i} onClick={() => onChange(moveRule(value, i, 1))}>Move down</Button>
        <Button type="button" variant="danger" data-debug-id={'action-rule-remove-' + i} onClick={() => onChange(value.filter((_, n) => n !== i))}>Remove</Button>
      </div>;
    })}
    <Button type="button" variant="secondary" disabled={value.length >= maxRules || !query.data} data-debug-id="action-rule-add" onClick={() => onChange([...value, { bridge_id: '*', provider: '*', model: '*' }])}>Add rule</Button>
  </div>;
}
