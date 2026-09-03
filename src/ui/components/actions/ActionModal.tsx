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

  return (
    <div
      data-debug-id="action-modal-overlay"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/75 p-4 backdrop-blur-sm overflow-y-auto animate-fade-in"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div
        data-debug-id="action-modal"
        className="my-8 w-full max-w-3xl rounded-2xl border border-white/10 bg-[#121212] p-6 shadow-2xl space-y-5"
      >
        <div className="flex items-center justify-between border-b border-white/10 pb-4">
          <div>
            <h3 className="text-lg font-semibold text-white">
              {isEdit ? 'Edit Action' : 'Create New Action'}
            </h3>
            <p className="text-xs text-zinc-400">
              {isEdit
                ? 'Update prompt or schedule settings for this action'
                : 'Configure an on-demand or recurring prompt targeted to an agent instance'}
            </p>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="text-zinc-400 hover:text-white transition-colors"
          >
            ✕
          </button>
        </div>

        <form onSubmit={handleSubmit} className="space-y-4">
          {/* Target Instance Picker (Reusing shared AgentPicker) */}
          <div>
            <div className="flex items-center justify-between mb-1.5">
              <label className="block text-xs font-semibold text-zinc-300">
                Target Agent Instance *
              </label>
              {targetInstanceId && (
                <span className="text-[11px] text-sky-400 font-mono">
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
              rows={4}
              value={promptText}
              onChange={(e) => setPromptText(e.target.value)}
              placeholder="e.g. Check test failures, inspect ongoing branch status, and deliver a summary of pending items."
              className="w-full rounded-xl border border-white/10 bg-black/40 p-3 text-sm text-zinc-100 placeholder-zinc-600 outline-none focus:border-sky-400"
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

          {/* Actions */}
          <div className="flex items-center justify-end gap-3 pt-3 border-t border-white/10">
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
              className="px-5 py-2 rounded-xl bg-sky-500 hover:bg-sky-400 text-xs font-semibold text-black transition-colors disabled:opacity-50"
            >
              {saving ? 'Saving...' : isEdit ? 'Save Changes' : 'Create Action'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
