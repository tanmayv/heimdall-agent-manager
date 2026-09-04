import { useState, useEffect, useMemo } from 'react';
import { useSelector } from 'react-redux';
import {
  Action,
  parseBlackoutDates,
  useCreateActionMutation,
  usePatchActionMutation,
} from '../../api/endpoints/actions';
import {
  useListAgentIdentitiesQuery,
  useListAgentTemplatesQuery,
} from '../../api/endpoints/agents';
import AgentPicker from '../AgentPicker';
import ScheduleEditor, { ScheduleEditorValue } from './ScheduleEditor';
import { getLocalTimezone, validateCronExpression } from './scheduleUtils';

export type ActionModalProps = {
  isOpen: boolean;
  action?: Action | null;
  onClose: () => void;
  defaultInstanceId?: string;
  projects: any[];
  instances: any[];
  onRefreshAgents?: () => void | Promise<void>;
};

export default function ActionModal({
  isOpen,
  action,
  onClose,
  defaultInstanceId,
  projects,
  instances,
  onRefreshAgents,
}: ActionModalProps) {
  const [createAction] = useCreateActionMutation();
  const [patchAction] = usePatchActionMutation();

  const { data: identitiesData } = useListAgentIdentitiesQuery();
  const identities = identitiesData?.agents || [];

  const { data: templatesData } = useListAgentTemplatesQuery();
  const templates = templatesData?.templates || [];

  const session = useSelector((state: any) => state?.chat?.session || {});

  const isEdit = Boolean(action);

  const [targetInstanceId, setTargetInstanceId] = useState('');
  const [promptText, setPromptText] = useState('');
  const [isScheduled, setIsScheduled] = useState(true);
  const [schedule, setSchedule] = useState<ScheduleEditorValue>({
    cron_expr: '0 9 * * 1-5',
    timezone: getLocalTimezone(),
    blackout_dates: [],
    active_from: undefined,
    active_until: undefined,
  });

  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  // Selected instance lookup
  const selectedInstance = useMemo(() => {
    return instances.find(
      (inst: any) =>
        (inst?.agent_instance_id || inst?.id || inst?.agentInstanceId) === targetInstanceId
    );
  }, [instances, targetInstanceId]);

  // Populate or reset form when modal opens or action changes
  useEffect(() => {
    if (!isOpen) return;

    setError('');
    setSaving(false);

    if (action) {
      setTargetInstanceId(action.target_instance_id);
      setPromptText(action.prompt_text);
      const hasCron = Boolean(action.cron_expr && action.cron_expr.trim() !== '');
      setIsScheduled(hasCron);
      setSchedule({
        cron_expr: action.cron_expr || '0 9 * * 1-5',
        timezone: action.timezone || getLocalTimezone(),
        blackout_dates: parseBlackoutDates(action.blackout_dates),
        active_from: action.active_from || undefined,
        active_until: action.active_until || undefined,
      });
    } else {
      const fallbackId =
        defaultInstanceId || (instances.length > 0 ? instances[0].agent_instance_id : '');
      setTargetInstanceId(fallbackId);
      setPromptText('');
      setIsScheduled(true);
      setSchedule({
        cron_expr: '0 9 * * 1-5',
        timezone: getLocalTimezone(),
        blackout_dates: [],
        active_from: undefined,
        active_until: undefined,
      });
    }
  }, [isOpen, action, defaultInstanceId, instances]);

  if (!isOpen) return null;

  const handleSubmit = async (e: React.FormEvent) => {
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
      const val = validateCronExpression(schedule.cron_expr);
      if (!val.valid) {
        setError(`Invalid schedule: ${val.error}`);
        return;
      }
    }

    setSaving(true);
    try {
      if (isEdit && action) {
        await patchAction({
          id: action.id,
          prompt_text: promptText.trim(),
          cron_expr: isScheduled ? schedule.cron_expr : '',
          timezone: isScheduled ? schedule.timezone : 'UTC',
          blackout_dates: isScheduled ? schedule.blackout_dates : [],
          active_from: isScheduled ? schedule.active_from : undefined,
          active_until: isScheduled ? schedule.active_until : undefined,
        }).unwrap();
      } else {
        await createAction({
          target_instance_id: targetInstanceId,
          prompt_text: promptText.trim(),
          cron_expr: isScheduled ? schedule.cron_expr : '',
          timezone: isScheduled ? schedule.timezone : 'UTC',
          blackout_dates: isScheduled ? schedule.blackout_dates : [],
          active_from: isScheduled ? schedule.active_from : undefined,
          active_until: isScheduled ? schedule.active_until : undefined,
        }).unwrap();
      }
      onClose();
    } catch (err: any) {
      const msg =
        err?.data?.error?.message ||
        err?.error ||
        err?.message ||
        String(err || 'Failed to save action');
      setError(msg);
    } finally {
      setSaving(false);
    }
  };

  if (!isOpen) return null;

  return (
    <div
      data-debug-id="action-modal-overlay"
      className="fixed inset-0 z-50 flex items-start sm:items-center justify-center bg-black/80 p-3 sm:p-5 backdrop-blur-sm overflow-y-auto animate-fade-in"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div
        data-debug-id="action-modal"
        className="my-auto relative flex flex-col w-full max-w-3xl max-h-[92vh] sm:max-h-[88vh] rounded-2xl border border-white/10 bg-[#121212] shadow-2xl overflow-hidden"
      >
        {/* Header - Fixed at top */}
        <div className="shrink-0 flex items-center justify-between border-b border-white/10 px-6 py-4 bg-[#141414]/95 backdrop-blur-md z-10">
          <div>
            <h3 className="text-lg font-semibold text-white">
              {isEdit ? 'Edit Action' : 'Create New Action'}
            </h3>
            <p className="text-xs text-zinc-400 mt-0.5">
              {isEdit
                ? 'Update prompt or schedule settings for this action'
                : 'Configure an on-demand or recurring prompt targeted to an agent instance'}
            </p>
          </div>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close"
            className="flex h-8 w-8 items-center justify-center rounded-xl text-zinc-400 hover:text-white hover:bg-white/10 transition-colors"
          >
            ✕
          </button>
        </div>

        {/* Scrollable Form Body */}
        <form onSubmit={handleSubmit} className="flex flex-col flex-1 min-h-0 overflow-hidden">
          <div className="flex-1 min-h-0 overflow-y-auto px-6 py-5 space-y-5">
            {/* Target Instance Picker (Reusing shared AgentPicker) */}
            <div>
              <div className="flex items-center justify-between mb-1.5">
                <label className="block text-xs font-semibold text-zinc-300">
                  Target Agent Instance *
                </label>
                {targetInstanceId && (
                  <span className="text-[11px] text-sky-400 font-mono truncate max-w-[300px]">
                    Selected: {selectedInstance?.display_name || selectedInstance?.agent_name || targetInstanceId}
                  </span>
                )}
              </div>

              {/* Hidden input for debug/test parity */}
              <input
                type="hidden"
                data-debug-id="action-modal-instance-select"
                value={targetInstanceId}
              />

              {isEdit ? (
                <div className="flex items-center justify-between rounded-xl border border-white/10 bg-black/40 p-3">
                  <div className="flex items-center gap-2.5">
                    <span
                      className={`h-2 w-2 rounded-full ${
                        selectedInstance?.runtime_status === 'running'
                          ? 'bg-emerald-400'
                          : 'bg-zinc-500'
                      }`}
                    />
                    <div>
                      <div className="text-xs font-semibold text-white">
                        {selectedInstance?.display_name || selectedInstance?.agent_name || selectedInstance?.agent_id || targetInstanceId}
                      </div>
                      <div className="text-[11px] font-mono text-zinc-400">
                        {targetInstanceId}
                      </div>
                    </div>
                  </div>
                  <span className="text-[11px] text-zinc-500">
                    Target instance cannot be changed after creation
                  </span>
                </div>
              ) : (
                <div className="space-y-2">
                  <AgentPicker
                    debugId="action-modal-agent-picker"
                    daemonUrl={session?.daemonUrl || ''}
                    clientToken={session?.clientToken || ''}
                    agents={instances}
                    identities={identities}
                    projects={projects}
                    templates={templates}
                    value={targetInstanceId}
                    onSelected={(selectedAgentId) => {
                      setTargetInstanceId(selectedAgentId);
                    }}
                    onRefreshAgents={onRefreshAgents}
                  />
                </div>
              )}
            </div>

            {/* Prompt Text */}
            <div>
              <label className="block text-xs font-semibold text-zinc-300 mb-1">
                Prompt Text *
              </label>
              <textarea
                data-debug-id="action-modal-prompt-input"
                rows={3}
                value={promptText}
                onChange={(e) => setPromptText(e.target.value)}
                placeholder="e.g. Check test failures, inspect ongoing branch status, and deliver a summary of pending items."
                className="w-full rounded-xl border border-white/10 bg-black/40 p-3 text-sm text-zinc-100 placeholder-zinc-600 outline-none focus:border-sky-400 resize-y"
              />
            </div>

            {/* Execution Mode Toggle */}
            <div className="flex items-center justify-between rounded-xl border border-white/10 bg-white/[0.02] p-3">
              <div>
                <span className="text-xs font-semibold text-zinc-200">Scheduled Recurring Execution</span>
                <p className="text-[11px] text-zinc-500">
                  {isScheduled
                    ? 'Will execute automatically according to cron/preset schedule'
                    : 'On-demand action only (runs when triggered via "Run Now")'}
                </p>
              </div>
              <label className="relative inline-flex items-center cursor-pointer">
                <input
                  type="checkbox"
                  data-debug-id="action-modal-scheduled-toggle"
                  checked={isScheduled}
                  onChange={(e) => setIsScheduled(e.target.checked)}
                  className="sr-only peer"
                />
                <div className="w-11 h-6 bg-zinc-800 peer-focus:outline-none rounded-full peer peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:border-gray-300 after:border after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:bg-sky-500"></div>
              </label>
            </div>

            {/* Schedule Editor (shown only when scheduled) */}
            {isScheduled && (
              <ScheduleEditor value={schedule} onChange={setSchedule} />
            )}

            {error && (
              <div data-debug-id="action-modal-error" className="rounded-lg border border-red-500/40 bg-red-950/20 p-3 text-xs text-red-300">
                {error}
              </div>
            )}
          </div>

          {/* Footer - Fixed at bottom */}
          <div className="shrink-0 flex items-center justify-end gap-3 px-6 py-4 border-t border-white/10 bg-[#141414]/95 backdrop-blur-md z-10">
            <button
              type="button"
              data-debug-id="action-modal-cancel-btn"
              disabled={saving}
              onClick={onClose}
              className="px-4 py-2 rounded-xl border border-white/10 bg-white/5 hover:bg-white/10 text-xs font-semibold text-zinc-300 transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              data-debug-id="action-modal-submit-btn"
              disabled={saving}
              className="px-5 py-2 rounded-xl bg-sky-500 hover:bg-sky-400 text-xs font-semibold text-black transition-colors disabled:opacity-50 shadow-sm"
            >
              {saving ? 'Saving...' : isEdit ? 'Save Changes' : 'Create Action'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
