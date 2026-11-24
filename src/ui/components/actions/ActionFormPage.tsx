import React from 'react';
import { Alert, Button, Combobox, FormField, Input, PageShell, Panel, Select, Toggle } from '@ui';
import { useActionTriggerTypesQuery, useCreateActionMutation, useFetchActionQuery, usePatchActionMutation, type ActionTarget } from '../../api/endpoints/actions';
import { useActionCatalog, catalogNote, type CatalogSlice } from './actionCatalog';
import { emptyActionForm, defaultBotTarget, formFromAction, actionFormBody, actionTitle, actionListHref, actionViewHref, navigateTo, mapServerError, type ActionFormField } from './actionModel';
import TriggerListEditor from './TriggerListEditor';
import PlacementRulesEditor from './PlacementRulesEditor';

export const offeredTargetKinds = (kinds: ActionTarget['kind'][]) => kinds.map(value => ({ value, label: value === 'agent' ? 'Agent' : value === 'instance' ? 'Instance' : 'Bot' }));
export default function ActionFormPage({ actionId }: { actionId?: string } = {}) {
  const typesQuery = useActionTriggerTypesQuery();
  const types = typesQuery.data;
  const catalog = useActionCatalog(Boolean(types?.target_kinds.includes('bot')));
  const record = useFetchActionQuery({ id: actionId! }, { skip: !actionId });
  const [create, createState] = useCreateActionMutation();
  const [patch, patchState] = usePatchActionMutation();
  const [form, setForm] = React.useState(() => emptyActionForm());
  const [baseline, setBaseline] = React.useState('');
  const [errors, setErrors] = React.useState<Partial<Record<ActionFormField, string>>>({});
  const initialized = React.useRef('');
  React.useEffect(() => {
    if (actionId && record.data?.action && initialized.current !== actionId) {
      const next = formFromAction(record.data.action); setForm(next); setBaseline(JSON.stringify(next)); initialized.current = actionId;
    } else if (!actionId && types && !initialized.current) {
      const next = emptyActionForm(types.limits.min_interval_s.default);
      const kind = types.target_kinds[0];
      if (kind === 'instance') next.target = { kind, instance_id: '' };
      if (kind === 'bot') next.target = { kind, bot_id: '' };
      setForm(next); setBaseline(JSON.stringify(next)); initialized.current = 'new';
    }
  }, [actionId, record.data, types]);
  // The catalog contains the owner's bot. Fill only an empty selection, so an
  // existing explicit target survives loading and editing.
  React.useEffect(() => {
    const ownerBotId = catalog.bots.all[0]?.id;
    if (!ownerBotId) return;
    setForm(prev => {
      const target = defaultBotTarget(prev.target, ownerBotId);
      return target === prev.target ? prev : { ...prev, target };
    });
  }, [catalog.bots.all, form.target.kind]);
  const dirty = Boolean(baseline && JSON.stringify(form) !== baseline);
  React.useEffect(() => { if (!dirty) return; const warn = (event: BeforeUnloadEvent) => { event.preventDefault(); }; window.addEventListener('beforeunload', warn); return () => window.removeEventListener('beforeunload', warn); }, [dirty]);
  const field = <K extends keyof typeof form>(key: K, value: typeof form[K]) => { setForm(prev => ({ ...prev, [key]: value })); setErrors({}); };
  const target = form.target;
  const targetField = (patch: Record<string, unknown>) => field('target', { ...target, ...patch } as ActionTarget);
  function picker(label: string, slice: CatalogSlice, value: string, change: (v: string) => void, optional = false) {
    return <FormField label={label} hint={catalogNote(slice.state, label.toLowerCase()) || undefined}>
      <Combobox debugId={'action-form-' + label.toLowerCase()} value={value} onChange={change} options={[...(optional ? [{ value: '', title: 'None' }] : []), ...slice.all.map(e => ({ value: e.id, title: e.label }))]} placeholder={'Choose ' + label.toLowerCase()} loading={slice.state === 'loading'} />
    </FormField>;
  }
  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (!form.prompt_text.trim()) { setErrors({ prompt_text: 'Enter a prompt.' }); return; }
    try {
      const body = actionFormBody(form);
      const result = actionId ? await patch({ id: actionId, ...body }).unwrap() : await create(body).unwrap();
      setBaseline(JSON.stringify(form)); navigateTo(actionViewHref(result.action.id));
    } catch (error) { const mapped = mapServerError(error); setErrors({ [mapped.field]: mapped.message }); }
  }
  if (typesQuery.isLoading || (actionId && record.isLoading)) return <PageShell title="Action" loading />;
  if (!types || typesQuery.error || (actionId && (record.error || !record.data?.action))) return <PageShell title="Action"><Alert tone="danger" title="Couldn't load action form" /></PageShell>;
  return <PageShell title={actionId ? 'Edit ' + actionTitle(record.data?.action) : 'New action'} width="content">
    <form className="flex flex-col gap-4" onSubmit={submit}>
      <Panel className="p-4 flex flex-col gap-3"><h3>Prompt</h3>
        <FormField label="Name"><Input data-debug-id="action-form-name" value={form.name} onChange={v => field('name', v)} /></FormField>
        <FormField label="Prompt" required error={errors.prompt_text}><textarea className="w-full rounded border border-subtle bg-surface p-3" data-debug-id="action-form-prompt" aria-label="Prompt" rows={8} value={form.prompt_text} onChange={e => field('prompt_text', e.target.value)} /></FormField>
        <p className="text-caption text-muted">Placeholders: {'{{event.type}}, {{event.id}}, {{event.chain_id}}, {{event.task_id}}, {{event.actor}}, {{event.occurred_at}}, {{event.data.<key>}}, {{schedule.fired_at}}, {{action.id}}, {{action.name}}, {{run.id}}, {{run.joined_count}}'}</p>
        <Toggle data-debug-id="action-form-enabled" aria-label="Action enabled" checked={form.enabled} onChange={v => field('enabled', v)} />
      </Panel>
      <Panel className="p-4 flex flex-col gap-3"><h3>Target</h3>
        <Select data-debug-id="action-form-target-kind" aria-label="Target kind" value={target.kind} options={offeredTargetKinds(types.target_kinds)} onChange={kind => field('target', kind === 'agent' ? { kind, agent_id: '', project_id: '', instance_strategy: 'reuse', selector: 'first', rules: [] } : kind === 'instance' ? { kind, instance_id: '' } : { kind: 'bot', bot_id: '' })} />
        {target.kind === 'agent' ? <>
          {picker('Agent', catalog.agents, target.agent_id, agent_id => targetField({ agent_id }))}
          {picker('Project', catalog.projects, target.project_id || '', project_id => targetField({ project_id }), true)}
          <FormField label="Instance strategy"><Select data-debug-id="action-form-strategy" aria-label="Instance strategy" value={target.instance_strategy} onChange={instance_strategy => targetField({ instance_strategy })} options={[{ value: 'reuse', label: 'Reuse an instance' }, { value: 'fresh_per_run', label: 'Fresh instance per run' }]} /></FormField>
          <PlacementRulesEditor agentId={target.agent_id} value={target.rules} onChange={rules => targetField({ rules })} maxRules={types.limits.max_rules} />
        </> : target.kind === 'instance' ? picker('Instance', catalog.instances, target.instance_id, instance_id => targetField({ instance_id })) : picker('Bot', catalog.bots, target.bot_id, bot_id => targetField({ bot_id }))}
        {errors.target ? <Alert tone="danger" title="Check target">{errors.target}</Alert> : null}
        <p>An action also starts an agent that you stopped. Disable the action to stop that.</p>
      </Panel>
      <Panel className="p-4 flex flex-col gap-3"><h3>Triggers</h3>
        <TriggerListEditor value={form.triggers} onChange={v => field('triggers', v)} types={types} />
        {errors.triggers ? <Alert tone="danger" title="Check triggers">{errors.triggers}</Alert> : null}
      </Panel>
      <FormField label="Minimum interval (seconds)" error={errors.min_interval_s}><Input type="number" min={types.limits.min_interval_s.min} max={types.limits.min_interval_s.max} data-debug-id="action-form-min-interval" value={String(form.min_interval_s)} onChange={v => field('min_interval_s', Number(v))} /></FormField>
      {errors.form ? <Alert tone="danger" title="Couldn't save action">{errors.form}</Alert> : null}
      <div className="flex justify-between gap-2"><Button type="button" variant="secondary" data-debug-id="action-form-cancel" onClick={() => { if (!dirty || window.confirm('Discard unsaved changes?')) navigateTo(actionId ? actionViewHref(actionId) : actionListHref()); }}>Cancel</Button><Button type="submit" variant="primary" data-debug-id="action-form-save" loading={createState.isLoading || patchState.isLoading}>{actionId ? 'Save changes' : 'Create action'}</Button></div>
    </form>
  </PageShell>;
}
