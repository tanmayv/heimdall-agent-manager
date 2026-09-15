import { useEffect, useMemo, useState } from 'react';

import { buildRouteHash } from '../../utils/appLocation';
import {
  parseBlackoutDates,
  useCreateActionMutation,
  useFetchActionQuery,
  useListAllAgentInstancesQuery,
  usePatchActionMutation,
} from '../../api/endpoints/actions';
import { useListAgentIdentitiesQuery } from '../../api/endpoints/agents';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { useListProjectsQuery } from '../../api/endpoints/projects';
import ScheduleEditor, { type ScheduleEditorValue } from './ScheduleEditor';
import { getLocalTimezone, validateCronExpression } from './scheduleUtils';
import { Button, Combobox, Icon, Input, PageShell, Textarea, Toggle, type ComboboxOption } from '@ui';
export type ActionEditorPageProps = {
  // When present the page edits an existing action; otherwise it creates a new one.
  actionId?: string;
};

const DEFAULT_CRON = '0 9 * * 1-5';

function shellHash(path: string): string {
  return buildRouteHash(path, '');
}

function instanceInstanceId(inst: any): string {
  return String(inst?.agent_instance_id || inst?.id || inst?.agentInstanceId || '');
}

function instanceDisplayName(inst: any): string {
  return String(inst?.display_name || inst?.displayName || inst?.agent_name || inst?.agentName || instanceInstanceId(inst));
}

function instanceAgentId(inst: any): string {
  return String(inst?.agent_id || inst?.agentId || '');
}

function instanceRuntimeStatus(inst: any): string {
  return String(inst?.runtime_status || inst?.runtimeStatus || 'idle');
}

// ACT-1..ACT-7: dedicated full-page create/edit surface for Actions, replacing the
// former ActionModal popup. Layout mirrors NewAgentPage (header card + form card +
// sticky footer) so Actions matches Agents/Templates/Bridges. The target instance
// or durable agent + bridge is chosen through Combobox pickers and display names are the
// primary label while raw ids are demoted to a monospace secondary line.
export default function ActionEditorPage({ actionId }: ActionEditorPageProps) {
  const isEdit = Boolean(actionId);

  const { data: instancesData, isLoading: instancesLoading } = useListAllAgentInstancesQuery();
  const instances: any[] = instancesData?.instances || [];

  const { data: agentsData, isLoading: agentsLoading } = useListAgentIdentitiesQuery();
  const agentIdentities: any[] = agentsData?.agents || [];

  const { data: bridgesData, isLoading: bridgesLoading } = useListBridgesQuery();
  const bridges: any[] = bridgesData?.bridges || [];

  const { data: projectsData, isLoading: projectsLoading } = useListProjectsQuery();
  const projects = projectsData?.projects || [];

  const { data: actionData, isLoading: actionLoading, error: actionError } = useFetchActionQuery(
    { id: actionId || '' },
    { skip: !isEdit },
  );
  const action = actionData?.action || null;

  const [createAction, { isLoading: isCreating }] = useCreateActionMutation();
  const [patchAction, { isLoading: isPatching }] = usePatchActionMutation();

  const [targetMode, setTargetMode] = useState<'instance' | 'agent'>('instance');
  const [targetInstanceId, setTargetInstanceId] = useState('');
  const [targetAgentId, setTargetAgentId] = useState('');
  const [targetBridgeId, setTargetBridgeId] = useState('');
  const [targetProvider, setTargetProvider] = useState('');
  const [targetTier, setTargetTier] = useState('');
  const [targetProjectId, setTargetProjectId] = useState('');

  const [promptText, setPromptText] = useState('');
  const [isScheduled, setIsScheduled] = useState(true);
  const [schedule, setSchedule] = useState<ScheduleEditorValue>({
    cron_expr: DEFAULT_CRON,
    timezone: getLocalTimezone(),
    blackout_dates: [],
    active_from: undefined,
    active_until: undefined,
  });
  const [error, setError] = useState('');

  // Populate the form once the edited action loads.
  useEffect(() => {
    if (!isEdit || !action) return;
    if (action.target_instance_id) {
      setTargetMode('instance');
      setTargetInstanceId(action.target_instance_id);
    } else {
      setTargetMode('agent');
      setTargetAgentId(action.target_agent_id || '');
      setTargetBridgeId(action.target_bridge_id || '');
      setTargetProvider(action.target_provider || '');
      setTargetTier(action.target_tier || '');
      setTargetProjectId(action.target_project_id || '');
    }
    setPromptText(action.prompt_text);
    const hasCron = Boolean(action.cron_expr && action.cron_expr.trim() !== '');
    setIsScheduled(hasCron);
    setSchedule({
      cron_expr: action.cron_expr || DEFAULT_CRON,
      timezone: action.timezone || getLocalTimezone(),
      blackout_dates: parseBlackoutDates(action.blackout_dates),
      active_from: action.active_from || undefined,
      active_until: action.active_until || undefined,
    });
  }, [isEdit, action]);

  const selectedInstance = useMemo(
    () => instances.find((inst) => instanceInstanceId(inst) === targetInstanceId),
    [instances, targetInstanceId],
  );

  // ACT-3: fold display name, instance id, and agent id into the picker search
  // index so any of the three finds the instance. ACT-4: display name is the
  // primary title, the instance id is the demoted monospace secondary line.
  const instanceOptions = useMemo<ComboboxOption[]>(() => {
    return instances
      .filter((inst) => instanceInstanceId(inst))
      .map((inst) => {
        const instanceId = instanceInstanceId(inst);
        const agentId = instanceAgentId(inst);
        const status = instanceRuntimeStatus(inst);
        return {
          value: instanceId,
          title: instanceDisplayName(inst),
          tag: status === 'running' ? 'running' : undefined,
          id: instanceId,
          keywords: [instanceId, agentId, instanceDisplayName(inst)].filter(Boolean).join(' '),
        };
      })
      .sort((left, right) => left.title.localeCompare(right.title));
  }, [instances]);

  const agentOptions = useMemo<ComboboxOption[]>(() => {
    return (Array.isArray(agentIdentities) ? agentIdentities : [])
      // The /agents serializer emits `agent_id` (no `id`); fall back for safety.
      .map((a: any) => ({ raw: a, id: String(a?.agent_id || a?.id || '') }))
      .filter(({ id }) => Boolean(id))
      .map(({ raw: a, id }) => ({
        value: id,
        title: String(a.name || a.slug || id),
        id,
        tag: a.default_provider ? `${a.default_provider}${a.default_tier ? ` / ${a.default_tier}` : ''}` : undefined,
        keywords: [id, String(a.name || ''), String(a.slug || '')].filter(Boolean).join(' '),
      }))
      .sort((l, r) => l.title.localeCompare(r.title));
  }, [agentIdentities]);

  const bridgeOptions = useMemo<ComboboxOption[]>(() => {
    return (Array.isArray(bridges) ? bridges : [])
      // The /bridges serializer emits `bridge_id`/`label`/`machine_hostname` and a
      // `status` of online|offline|revoked. Show the label, and drop revoked bridges.
      .filter((b: any) => b?.status !== 'revoked')
      .map((b: any) => {
        const id = String(b.bridge_id || b.id || '');
        const title = String(b.label || b.machine_hostname || id);
        return {
          value: id,
          title,
          id,
          tag: b.status,
          keywords: [id, title, String(b.machine_hostname || '')].filter(Boolean).join(' '),
        };
      })
      .filter((opt) => Boolean(opt.value))
      .sort((l, r) => l.title.localeCompare(r.title));
  }, [bridges]);

  const projectOptions = useMemo<ComboboxOption[]>(() => {
    return [
      { value: '', title: 'None (Global / No Project)', id: 'none', keywords: 'none global' },
      ...projects.map((p) => ({
        value: p.project_id,
        title: p.name || p.project_id,
        id: p.project_id,
        keywords: [p.project_id, p.name || ''].filter(Boolean).join(' '),
      })),
    ];
  }, [projects]);

  const saving = isCreating || isPatching;

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError('');

    if (targetMode === 'instance') {
      if (!targetInstanceId) {
        setError('Please select a target agent instance.');
        return;
      }
    } else {
      if (!targetAgentId) {
        setError('Please select a target agent identity.');
        return;
      }
      if (!targetBridgeId) {
        setError('Please select a target bridge.');
        return;
      }
    }
    if (!promptText.trim()) {
      setError('Prompt text is required.');
      return;
    }
    if (isScheduled) {
      const validation = validateCronExpression(schedule.cron_expr);
      if (!validation.valid) {
        setError(`Invalid schedule: ${validation.error}`);
        return;
      }
    }

    const schedulePayload = {
      cron_expr: isScheduled ? schedule.cron_expr : '',
      timezone: isScheduled ? schedule.timezone : 'UTC',
      blackout_dates: isScheduled ? schedule.blackout_dates : [],
      active_from: isScheduled ? schedule.active_from : undefined,
      active_until: isScheduled ? schedule.active_until : undefined,
    };

    try {
      if (isEdit && action) {
        await patchAction({ id: action.id, prompt_text: promptText.trim(), ...schedulePayload }).unwrap();
      } else {
        if (targetMode === 'instance') {
          await createAction({ target_instance_id: targetInstanceId, prompt_text: promptText.trim(), ...schedulePayload }).unwrap();
        } else {
          await createAction({
            target_agent_id: targetAgentId,
            target_bridge_id: targetBridgeId,
            target_provider: targetProvider.trim() || undefined,
            target_tier: targetTier.trim() || undefined,
            target_project_id: targetProjectId.trim() || undefined,
            prompt_text: promptText.trim(),
            ...schedulePayload,
          }).unwrap();
        }
      }
      window.location.hash = shellHash('/actions');
    } catch (err: any) {
      const msg = err?.data?.error?.message || err?.error || err?.message || String(err || 'Failed to save action');
      setError(msg);
    }
  }

  // Edit mode: don't render the form until the action is loaded so fields never
  // flash empty then repopulate.
  if (isEdit && actionLoading) {
    return (
      <PageShell width="full" title="Edit action">
        <div data-debug-id="action-editor-loading" className="space-y-4 text-left">
          <div className="h-24 animate-pulse rounded-2xl bg-white/5" />
          <div className="h-64 animate-pulse rounded-2xl bg-white/5" />
        </div>
      </PageShell>
    );
  }

  if (isEdit && (actionError || !action)) {
    return (
      <PageShell width="full" title="Edit action">
        <div data-debug-id="action-editor-not-found" className="space-y-4 text-left">
          <div className="rounded-2xl border border-red-500/40 bg-red-950/20 p-5 text-sm text-red-300">
            {actionError
              ? `Failed to load action: ${String((actionError as any)?.error || (actionError as any)?.message || actionError)}`
              : 'This action could not be found. It may have been deleted.'}
          </div>
          <a
            data-debug-id="action-editor-back-link"
            href={shellHash('/actions')}
            className="inline-flex min-h-[44px] items-center justify-center rounded-xl bg-white/10 px-4 py-2 text-sm hover:bg-white/15"
          >
            Back to Actions
          </a>
        </div>
      </PageShell>
    );
  }

  return (
    <PageShell
      width="full"
      title={isEdit ? 'Edit action' : 'Create action'}
      description={
        isEdit
          ? 'Update the prompt or schedule for this action. The target is fixed once the action exists.'
          : 'Target an existing agent instance or durable agent on a bridge, write the prompt, and choose whether it runs on a schedule or on demand.'
      }
      actions={
        <a
          data-debug-id="action-editor-header-cancel-btn"
          href={shellHash('/actions')}
          className="inline-flex min-h-[44px] items-center justify-center rounded-xl bg-white/10 px-4 py-2 text-sm hover:bg-white/15"
        >
          Cancel
        </a>
      }
    >
      <div data-debug-id="action-editor-page" className="space-y-6 text-left">
      {/* Form card */}
      <form onSubmit={handleSubmit} className="space-y-6 rounded-2xl border border-white/10 bg-white/[0.035] p-4 sm:p-5">
        {/* Target section */}
        <section data-debug-id="action-editor-target-section" className="space-y-4">
          <div>
            <h2 className="text-sm font-semibold text-white">Target</h2>
            <p className="mt-0.5 text-xs text-zinc-500">
              {targetMode === 'instance'
                ? 'The existing agent instance this action is dispatched to.'
                : 'The agent identity and bridge that will launch or resolve an instance when the action runs.'}
            </p>
          </div>

          {/* Hidden inputs mirror selections for debug/test parity. */}
          <input type="hidden" data-debug-id="action-editor-instance-select" value={targetInstanceId} readOnly />
          <input type="hidden" data-debug-id="action-editor-agent-id" value={targetAgentId} readOnly />
          <input type="hidden" data-debug-id="action-editor-bridge-id" value={targetBridgeId} readOnly />

          {isEdit ? (
            <div
              data-debug-id="action-editor-target-locked"
              className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-white/10 bg-black/30 p-3"
            >
              {targetMode === 'instance' ? (
                <div className="flex items-center gap-2.5">
                  <span
                    className={`h-2 w-2 rounded-full ${
                      instanceRuntimeStatus(selectedInstance) === 'running' ? 'bg-emerald-400' : 'bg-zinc-500'
                    }`}
                  />
                  <div>
                    <div className="text-sm font-semibold text-white">
                      {selectedInstance ? instanceDisplayName(selectedInstance) : targetInstanceId}
                    </div>
                    <div className="font-mono text-caption text-zinc-500">{targetInstanceId}</div>
                  </div>
                </div>
              ) : (
                <div className="flex items-center gap-2.5">
                  <Icon name="bot" size={16} className="text-sky-400" />
                  <div>
                    <div className="text-sm font-semibold text-white">
                      Agent: {targetAgentId} (Bridge: {targetBridgeId})
                    </div>
                    {(targetProvider || targetTier || targetProjectId) && (
                      <div className="font-mono text-caption text-zinc-400">
                        {[targetProvider && `provider: ${targetProvider}`, targetTier && `tier: ${targetTier}`, targetProjectId && `project: ${targetProjectId}`].filter(Boolean).join(' • ')}
                      </div>
                    )}
                  </div>
                </div>
              )}
              <span className="text-caption text-zinc-500">Target cannot be changed after creation</span>
            </div>
          ) : (
            <div className="space-y-4">
              {/* Target Mode Toggle */}
              <div className="flex gap-2 p-1 bg-black/40 rounded-xl border border-white/10 w-fit">
                <button
                  type="button"
                  data-debug-id="action-editor-mode-instance"
                  onClick={() => setTargetMode('instance')}
                  className={`px-3 py-1.5 rounded-lg text-xs font-semibold transition-colors ${
                    targetMode === 'instance'
                      ? 'bg-white/20 text-white'
                      : 'text-zinc-400 hover:text-white'
                  }`}
                >
                  Existing Instance
                </button>
                <button
                  type="button"
                  data-debug-id="action-editor-mode-agent"
                  onClick={() => setTargetMode('agent')}
                  className={`px-3 py-1.5 rounded-lg text-xs font-semibold transition-colors ${
                    targetMode === 'agent'
                      ? 'bg-white/20 text-white'
                      : 'text-zinc-400 hover:text-white'
                  }`}
                >
                  Agent &amp; Bridge (Launch on demand)
                </button>
              </div>

              {targetMode === 'instance' ? (
                <Combobox
                  debugId="action-editor-agent-select"
                  options={instanceOptions}
                  value={targetInstanceId}
                  onChange={setTargetInstanceId}
                  placeholder="Choose a target agent instance…"
                  searchPlaceholder="Search by name, instance id, or agent id…"
                  emptyLabel="No agent instances match your search."
                  loading={instancesLoading}
                  width="full"
                />
              ) : (
                <div className="space-y-4 pt-1">
                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <div className="space-y-1.5">
                      <label className="text-xs font-semibold text-zinc-300">Target Agent *</label>
                      <Combobox
                        debugId="action-editor-agent-id-select"
                        options={agentOptions}
                        value={targetAgentId}
                        onChange={setTargetAgentId}
                        placeholder="Choose an agent identity…"
                        searchPlaceholder="Search agents by name or slug…"
                        emptyLabel="No agent identities match your search."
                        loading={agentsLoading}
                        width="full"
                      />
                    </div>

                    <div className="space-y-1.5">
                      <label className="text-xs font-semibold text-zinc-300">Target Bridge *</label>
                      <Combobox
                        debugId="action-editor-bridge-id-select"
                        options={bridgeOptions}
                        value={targetBridgeId}
                        onChange={setTargetBridgeId}
                        placeholder="Choose a bridge…"
                        searchPlaceholder="Search bridges by name or id…"
                        emptyLabel="No bridges match your search."
                        loading={bridgesLoading}
                        width="full"
                      />
                    </div>
                  </div>

                  <div className="grid grid-cols-1 sm:grid-cols-3 gap-4 pt-1">
                    <div className="space-y-1.5">
                      <label className="text-xs font-medium text-zinc-400">Provider (optional)</label>
                      <Input
                        data-debug-id="action-editor-provider-input"
                        value={targetProvider}
                        onChange={setTargetProvider}
                        placeholder="e.g. vertex, anthropic"
                        width="full"
                      />
                    </div>

                    <div className="space-y-1.5">
                      <label className="text-xs font-medium text-zinc-400">Tier (optional)</label>
                      <Input
                        data-debug-id="action-editor-tier-input"
                        value={targetTier}
                        onChange={setTargetTier}
                        placeholder="e.g. fast, smart"
                        width="full"
                      />
                    </div>

                    <div className="space-y-1.5">
                      <label className="text-xs font-medium text-zinc-400">Project (optional)</label>
                      <Combobox
                        debugId="action-editor-project-select"
                        options={projectOptions}
                        value={targetProjectId}
                        onChange={setTargetProjectId}
                        placeholder="Global (no project)"
                        searchPlaceholder="Search projects…"
                        loading={projectsLoading}
                        width="full"
                      />
                    </div>
                  </div>
                </div>
              )}
            </div>
          )}
        </section>

        {/* Prompt section */}
        <section data-debug-id="action-editor-prompt-section" className="space-y-2 border-t border-white/10 pt-6">
          <div>
            <h2 className="text-sm font-semibold text-white">Prompt</h2>
            <p className="mt-0.5 text-xs text-zinc-500">The message dispatched to the agent when this action runs.</p>
          </div>
          <Textarea
            data-debug-id="action-editor-prompt-input"
            rows={4}
            value={promptText}
            onChange={setPromptText}
            placeholder="e.g. Check test failures, inspect ongoing branch status, and deliver a summary of pending items."
            width="full"
          />
        </section>

        {/* Schedule section */}
        <section data-debug-id="action-editor-schedule-section" className="space-y-3 border-t border-white/10 pt-6">
          <div>
            <h2 className="text-sm font-semibold text-white">Schedule</h2>
            <p className="mt-0.5 text-xs text-zinc-500">Run automatically on a recurring schedule, or leave off for on-demand only.</p>
          </div>

          <div className="flex items-center justify-between rounded-xl border border-white/10 bg-white/[0.02] p-3">
            <div>
              <span className="text-xs font-semibold text-zinc-200">Scheduled recurring execution</span>
              <p className="text-caption text-zinc-500">
                {isScheduled
                  ? 'Will execute automatically according to the cron/preset schedule below.'
                  : 'On-demand only — runs when triggered via "Run now".'}
              </p>
            </div>
            <Toggle
              data-debug-id="action-editor-scheduled-toggle"
              checked={isScheduled}
              onChange={setIsScheduled}
              aria-label="Scheduled recurring execution"
            />
          </div>

          {isScheduled && <ScheduleEditor value={schedule} onChange={setSchedule} />}
        </section>

        {error && (
          <div data-debug-id="action-editor-error" className="rounded-lg border border-red-500/40 bg-red-950/20 p-3 text-xs text-red-300">
            {error}
          </div>
        )}

        {/* Sticky footer */}
        <div className="z-10 -mx-4 -mb-4 flex flex-col-reverse gap-2 border-t border-white/10 bg-[#0d0f14]/95 px-4 py-3 pb-[max(0.75rem,env(safe-area-inset-bottom))] backdrop-blur sm:-mx-5 sm:-mb-5 sm:flex-row sm:justify-end sm:px-5 md:sticky md:bottom-0">
          <a
            data-debug-id="action-editor-footer-cancel-btn"
            href={shellHash('/actions')}
            className="inline-flex min-h-[44px] items-center justify-center rounded-xl bg-white/10 px-4 py-2 text-sm hover:bg-white/15"
          >
            Cancel
          </a>
          <Button
            variant="primary"
            data-debug-id="action-editor-submit-btn"
            type="submit"
            disabled={saving || (targetMode === 'instance' ? !targetInstanceId : (!targetAgentId || !targetBridgeId)) || !promptText.trim()}
            className="min-h-[44px]"
          >
            {saving ? 'Saving…' : isEdit ? 'Save changes' : 'Create action'}
          </Button>
        </div>
      </form>
      </div>
    </PageShell>
  );
}
