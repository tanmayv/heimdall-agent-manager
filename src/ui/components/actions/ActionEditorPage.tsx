import { useEffect, useMemo, useState } from 'react';
import Icon from '../Icon';
import SearchableSelect, { type SearchableOption } from '../SearchableSelect';
import { buildRouteHash } from '../../utils/appLocation';
import {
  parseBlackoutDates,
  useCreateActionMutation,
  useFetchActionQuery,
  useListAllAgentInstancesQuery,
  usePatchActionMutation,
} from '../../api/endpoints/actions';
import ScheduleEditor, { type ScheduleEditorValue } from './ScheduleEditor';
import { getLocalTimezone, validateCronExpression } from './scheduleUtils';

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
// is chosen through SearchableSelect (never typed by hand) and display names are the
// primary label while raw ids are demoted to a monospace secondary line.
export default function ActionEditorPage({ actionId }: ActionEditorPageProps) {
  const isEdit = Boolean(actionId);

  const { data: instancesData, isLoading: instancesLoading } = useListAllAgentInstancesQuery();
  const instances: any[] = instancesData?.instances || [];

  const { data: actionData, isLoading: actionLoading, error: actionError } = useFetchActionQuery(
    { id: actionId || '' },
    { skip: !isEdit },
  );
  const action = actionData?.action || null;

  const [createAction, { isLoading: isCreating }] = useCreateActionMutation();
  const [patchAction, { isLoading: isPatching }] = usePatchActionMutation();

  const [targetInstanceId, setTargetInstanceId] = useState('');
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
    setTargetInstanceId(action.target_instance_id);
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
  const instanceOptions = useMemo<SearchableOption[]>(() => {
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

  const saving = isCreating || isPatching;

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError('');

    if (!targetInstanceId) {
      setError('Please select a target agent instance.');
      return;
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
        await createAction({ target_instance_id: targetInstanceId, prompt_text: promptText.trim(), ...schedulePayload }).unwrap();
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
      <div data-debug-id="action-editor-loading" className="w-full max-w-4xl space-y-4 text-left">
        <div className="h-24 animate-pulse rounded-2xl bg-white/5" />
        <div className="h-64 animate-pulse rounded-2xl bg-white/5" />
      </div>
    );
  }

  if (isEdit && (actionError || !action)) {
    return (
      <div data-debug-id="action-editor-not-found" className="w-full max-w-4xl space-y-4 text-left">
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
    );
  }

  return (
    <div data-debug-id="action-editor-page" className="w-full max-w-4xl space-y-6 text-left">
      {/* Header card */}
      <div className="rounded-2xl border border-white/10 bg-white/[0.04] p-4 sm:p-5">
        <div className="flex flex-col items-stretch justify-between gap-3 sm:flex-row sm:items-start">
          <div>
            <h1 className="text-2xl font-semibold text-white">{isEdit ? 'Edit action' : 'Create action'}</h1>
            <p className="mt-1 text-sm text-zinc-500">
              {isEdit
                ? 'Update the prompt or schedule for this action. The target instance is fixed once the action exists.'
                : 'Target an agent instance, write the prompt, and choose whether it runs on a schedule or on demand.'}
            </p>
          </div>
          <a
            data-debug-id="action-editor-header-cancel-btn"
            href={shellHash('/actions')}
            className="inline-flex min-h-[44px] items-center justify-center rounded-xl bg-white/10 px-4 py-2 text-sm hover:bg-white/15"
          >
            Cancel
          </a>
        </div>
      </div>

      {/* Form card */}
      <form onSubmit={handleSubmit} className="space-y-6 rounded-2xl border border-white/10 bg-white/[0.035] p-4 sm:p-5">
        {/* Target section */}
        <section data-debug-id="action-editor-target-section" className="space-y-2">
          <div>
            <h2 className="text-sm font-semibold text-white">Target</h2>
            <p className="mt-0.5 text-xs text-zinc-500">The agent instance this action's prompt is dispatched to.</p>
          </div>

          {/* Hidden input mirrors the selection for debug/test parity. */}
          <input type="hidden" data-debug-id="action-editor-instance-select" value={targetInstanceId} readOnly />

          {isEdit ? (
            <div
              data-debug-id="action-editor-target-locked"
              className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-white/10 bg-black/30 p-3"
            >
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
                  <div className="font-mono text-[11px] text-zinc-500">{targetInstanceId}</div>
                </div>
              </div>
              <span className="text-[11px] text-zinc-500">Target instance cannot be changed after creation</span>
            </div>
          ) : (
            <SearchableSelect
              debugId="action-editor-agent-select"
              options={instanceOptions}
              value={targetInstanceId}
              onChange={setTargetInstanceId}
              buttonPlaceholder="Choose a target agent instance…"
              placeholder="Search by name, instance id, or agent id…"
              emptyLabel="No agent instances match your search."
              loading={instancesLoading}
            />
          )}
        </section>

        {/* Prompt section */}
        <section data-debug-id="action-editor-prompt-section" className="space-y-2 border-t border-white/10 pt-6">
          <div>
            <h2 className="text-sm font-semibold text-white">Prompt</h2>
            <p className="mt-0.5 text-xs text-zinc-500">The message dispatched to the agent when this action runs.</p>
          </div>
          <textarea
            data-debug-id="action-editor-prompt-input"
            rows={4}
            value={promptText}
            onChange={(e) => setPromptText(e.target.value)}
            placeholder="e.g. Check test failures, inspect ongoing branch status, and deliver a summary of pending items."
            className="w-full resize-y rounded-xl border border-white/10 bg-black/40 p-3 text-sm text-zinc-100 placeholder-zinc-600 outline-none focus:border-sky-400"
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
              <p className="text-[11px] text-zinc-500">
                {isScheduled
                  ? 'Will execute automatically according to the cron/preset schedule below.'
                  : 'On-demand only — runs when triggered via "Run now".'}
              </p>
            </div>
            <label className="relative inline-flex cursor-pointer items-center">
              <input
                type="checkbox"
                data-debug-id="action-editor-scheduled-toggle"
                checked={isScheduled}
                onChange={(e) => setIsScheduled(e.target.checked)}
                className="peer sr-only"
              />
              <div className="peer h-6 w-11 rounded-full bg-zinc-800 after:absolute after:left-[2px] after:top-[2px] after:h-5 after:w-5 after:rounded-full after:border after:border-gray-300 after:bg-white after:transition-all after:content-[''] peer-checked:bg-sky-500 peer-checked:after:translate-x-full peer-checked:after:border-white peer-focus:outline-none" />
            </label>
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
          <button
            data-debug-id="action-editor-submit-btn"
            type="submit"
            disabled={saving || !targetInstanceId || !promptText.trim()}
            className="inline-flex min-h-[44px] items-center justify-center rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300 disabled:opacity-50"
          >
            {saving ? 'Saving…' : isEdit ? 'Save changes' : 'Create action'}
          </button>
        </div>
      </form>
    </div>
  );
}
