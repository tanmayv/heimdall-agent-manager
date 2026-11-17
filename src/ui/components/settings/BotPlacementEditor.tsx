import { Button } from '@ui';
import { useState } from 'react';
import { useGetBotPlacementQuery, useGetBotPlacementOptionsQuery, usePutBotPlacementMutation, type BotPlacementCandidate } from '../../api/endpoints/bots';
import { apiErrorText } from '../../api/cookieFetch';
import { validateBotPlacement } from './botsView';

export default function BotPlacementEditor() {
  const placement = useGetBotPlacementQuery();
  const options = useGetBotPlacementOptionsQuery();
  const [put, saving] = usePutBotPlacementMutation();
  // A draft keeps the revision it was edited from, even when WS/polls refresh the cache.
  const [draft, setDraft] = useState<{ revision: number; rows: BotPlacementCandidate[] } | null>(null);
  const [error, setError] = useState('');
  const rows = draft?.rows ?? placement.data?.candidates ?? [];
  const bridges = options.data?.bridges ?? [];
  const providers = [...new Map(bridges.flatMap((b) => b.providers).map((p) => [p.provider, p])).values()];
  function change(next: BotPlacementCandidate[]) {
    if (!placement.data) return;
    setDraft({ revision: draft?.revision ?? placement.data.placement_revision, rows: next });
    setError('');
  }
  function update(index: number, patch: Partial<BotPlacementCandidate>) {
    change(rows.map((row, i) => i === index ? { ...row, ...patch } : row));
  }
  async function save() {
    if (!placement.data || !options.data) return;
    const validation = validateBotPlacement(rows, options.data);
    if (validation) {
      const messages: Record<string, string> = {
        too_many_candidates: 'Use at most 32 placement rules.',
        unknown_bridge: 'Choose one of your machines.',
        unknown_provider: 'Choose an available provider.',
        model_requires_provider: 'Choose a provider before choosing a model.',
        duplicate_candidate: 'Each machine, provider and model rule must be unique.',
      };
      setError(messages[validation]);
      return;
    }
    setError('');
    try {
      await put({ expected_revision: draft?.revision ?? placement.data.placement_revision, candidates: rows }).unwrap();
      setDraft(null);
    } catch (e) {
      setError((e as { details?: { code?: string } })?.details?.code === 'placement_revision_changed'
        ? 'Placement changed elsewhere. Reload and try again.' : apiErrorText(e));
    }
  }
  return <details className="space-y-3 rounded-xl border border-subtle p-4">
    <summary data-debug-id="settings-bots-placement-toggle" className="cursor-pointer font-semibold">Where your bot runs</summary>
    <p className="text-sm text-muted">By default your bot can use any of your machines and models.</p>
    {placement.isError || options.isError ? <p role="alert">{apiErrorText(placement.error || options.error)}</p> : null}
    {rows.map((row, index) => {
      const models = [...new Set(bridges.flatMap((bridge) => bridge.providers.filter((provider) => provider.provider === row.provider).flatMap((provider) => provider.models)))];
      return <div key={index} data-debug-id={`settings-bots-placement-row-${index}`} className="flex flex-wrap gap-2 py-2">
        <select className="min-h-10 max-w-full rounded-lg border border-subtle bg-surface px-2 text-sm text-primary" aria-label="Machine" data-debug-id={`settings-bots-placement-bridge-${index}`} value={row.bridge_id} onChange={(e) => update(index, { bridge_id: e.target.value })}>
          <option value="*">Any machine</option>{bridges.map((b) => <option key={b.bridge_id} value={b.bridge_id}>{b.label}</option>)}
          {row.bridge_id !== '*' && !bridges.some((b) => b.bridge_id === row.bridge_id) ? <option value={row.bridge_id}>{row.bridge_id}</option> : null}
        </select>
        <select className="min-h-10 max-w-full rounded-lg border border-subtle bg-surface px-2 text-sm text-primary" aria-label="Provider" data-debug-id={`settings-bots-placement-provider-${index}`} value={row.provider} onChange={(e) => update(index, { provider: e.target.value, model: '*' })}>
          <option value="*">Any provider</option>{providers.map((p) => <option key={p.provider} value={p.provider}>{p.label}</option>)}
          {row.provider !== '*' && !providers.some((p) => p.provider === row.provider) ? <option value={row.provider}>{row.provider}</option> : null}
        </select>
        <select className="min-h-10 max-w-full rounded-lg border border-subtle bg-surface px-2 text-sm text-primary" aria-label="Model" data-debug-id={`settings-bots-placement-model-${index}`} value={row.model} disabled={row.provider === '*'} onChange={(e) => update(index, { model: e.target.value })}>
          <option value="*">Any model</option>{models.map((model) => <option key={model} value={model}>{model}</option>)}
          {row.model !== '*' && !models.includes(row.model) ? <option value={row.model}>{row.model}</option> : null}
        </select>
        <select className="min-h-10 max-w-full rounded-lg border border-subtle bg-surface px-2 text-sm text-primary" aria-label="Tier" data-debug-id={`settings-bots-placement-tier-${index}`} value={row.tier} onChange={(e) => update(index, { tier: e.target.value as BotPlacementCandidate['tier'] })}>
          <option value="preferred">Preferred</option><option value="allowed">Allowed</option>
        </select>
        <Button variant="secondary" type="button" aria-label="Remove rule" data-debug-id={`settings-bots-placement-remove-${index}`} onClick={() => change(rows.filter((_, i) => i !== index))}>Remove</Button>
      </div>;
    })}
    <div className="flex gap-3">
      <Button variant="secondary" type="button" data-debug-id="settings-bots-placement-add-btn" disabled={!placement.data || !options.data || saving.isLoading || rows.length >= 32} onClick={() => change([...rows, { bridge_id: '*', provider: '*', model: '*', tier: 'allowed' }])}>Add rule</Button>
      <Button variant="secondary" type="button" data-debug-id="settings-bots-placement-save-btn" disabled={!placement.data || !options.data || saving.isLoading} onClick={save}>Save</Button>
    </div>
    {error ? <p role="alert" data-debug-id="settings-bots-placement-error" className="text-danger">{error}</p> : null}
  </details>;
}
