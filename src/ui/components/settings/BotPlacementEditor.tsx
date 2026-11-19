import { Alert, Button, FormField, Panel, Select, Spinner, Text } from '@ui';
import { useRef, useState } from 'react';
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
  const pending = useRef(false);
  const rows = draft?.rows ?? placement.data?.candidates ?? [];
  const bridges = options.data?.bridges ?? [];
  const providers = [...new Map(bridges.flatMap((b) => b.providers).map((p) => [p.provider, p])).values()];
  function change(next: BotPlacementCandidate[]) {
    if (!placement.data || pending.current) return;
    setDraft({ revision: draft?.revision ?? placement.data.placement_revision, rows: next });
    setError('');
  }
  function update(index: number, patch: Partial<BotPlacementCandidate>) {
    change(rows.map((row, i) => i === index ? { ...row, ...patch } : row));
  }
  async function save() {
    if (!placement.data || !options.data || pending.current) return;
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
    pending.current = true;
    setError('');
    try {
      await put({ expected_revision: draft?.revision ?? placement.data.placement_revision, candidates: rows }).unwrap();
      setDraft(null);
    } catch (e) {
      setError((e as { details?: { code?: string } })?.details?.code === 'placement_revision_changed'
        ? 'Placement changed elsewhere. Reload and try again.' : apiErrorText(e));
    } finally { pending.current = false; }
  }
  return <Panel className="min-w-0"><details className="space-y-3">
    <summary data-debug-id="settings-bots-placement-toggle" className="cursor-pointer"><span className="inline-flex items-center gap-2"><Text as="span" role="title">Where your bot runs</Text>{placement.isLoading || options.isLoading ? <Spinner size="sm" /> : null}</span></summary>
    <Text role="body-sm" tone="muted">By default your bot can use any of your machines and models.</Text>
    {placement.isError || options.isError ? <Alert tone="danger">{apiErrorText(placement.error || options.error)}</Alert> : null}
    {placement.isLoading || options.isLoading ? <div className="flex justify-center py-6"><Spinner /></div> : null}
    {rows.map((row, index) => {
      const models = [...new Set(bridges.flatMap((bridge) => bridge.providers.filter((provider) => provider.provider === row.provider).flatMap((provider) => provider.models)))];
      return <div key={index} data-debug-id={`settings-bots-placement-row-${index}`} className="grid min-w-0 grid-cols-1 gap-3 border-b border-subtle py-3 sm:grid-cols-2">
        <FormField label="Machine"><Select width="full" aria-label="Machine" data-debug-id={`settings-bots-placement-bridge-${index}`} value={row.bridge_id} disabled={saving.isLoading || !options.data} onChange={(value) => update(index, { bridge_id: value })}>
          <option value="*">Any machine</option>{bridges.map((b) => <option key={b.bridge_id} value={b.bridge_id}>{b.label}</option>)}
          {row.bridge_id !== '*' && !bridges.some((b) => b.bridge_id === row.bridge_id) ? <option value={row.bridge_id}>{row.bridge_id}</option> : null}
        </Select></FormField>
        <FormField label="Provider"><Select width="full" aria-label="Provider" data-debug-id={`settings-bots-placement-provider-${index}`} value={row.provider} disabled={saving.isLoading || !options.data} onChange={(value) => update(index, { provider: value, model: '*' })}>
          <option value="*">Any provider</option>{providers.map((p) => <option key={p.provider} value={p.provider}>{p.label}</option>)}
          {row.provider !== '*' && !providers.some((p) => p.provider === row.provider) ? <option value={row.provider}>{row.provider}</option> : null}
        </Select></FormField>
        <FormField label="Model"><Select width="full" aria-label="Model" data-debug-id={`settings-bots-placement-model-${index}`} value={row.model} disabled={row.provider === '*' || saving.isLoading || !options.data} onChange={(value) => update(index, { model: value })}>
          <option value="*">Any model</option>{models.map((model) => <option key={model} value={model}>{model}</option>)}
          {row.model !== '*' && !models.includes(row.model) ? <option value={row.model}>{row.model}</option> : null}
        </Select></FormField>
        <FormField label="Tier"><Select width="full" aria-label="Tier" data-debug-id={`settings-bots-placement-tier-${index}`} value={row.tier} disabled={saving.isLoading} onChange={(value) => update(index, { tier: value as BotPlacementCandidate['tier'] })}>
          <option value="preferred">Preferred</option><option value="allowed">Allowed</option>
        </Select></FormField>
        <Button variant="secondary" type="button" disabled={saving.isLoading} className="justify-self-start" aria-label="Remove rule" data-debug-id={`settings-bots-placement-remove-${index}`} onClick={() => change(rows.filter((_, i) => i !== index))}>Remove</Button>
      </div>;
    })}
    <div className="flex flex-wrap justify-end gap-3">
      <Button variant="secondary" type="button" data-debug-id="settings-bots-placement-add-btn" disabled={!placement.data || !options.data || saving.isLoading || rows.length >= 32} onClick={() => change([...rows, { bridge_id: '*', provider: '*', model: '*', tier: 'allowed' }])}>Add rule</Button>
      <Button variant="primary" type="button" loading={saving.isLoading} data-debug-id="settings-bots-placement-save-btn" disabled={!placement.data || !options.data || saving.isLoading} onClick={save}>Save</Button>
    </div>
    {error ? <div data-debug-id="settings-bots-placement-error"><Alert tone="danger">{error}</Alert></div> : null}
  </details></Panel>;
}
