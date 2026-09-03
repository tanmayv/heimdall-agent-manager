import { useState, useEffect, useMemo } from 'react';
import {
  Action,
  parseBlackoutDates,
  useCreateActionMutation,
  usePatchActionMutation,
} from '../../api/endpoints/actions';
import ScheduleEditor, { ScheduleEditorValue } from './ScheduleEditor';
import { getLocalTimezone, validateCronExpression } from './scheduleUtils';

export type ActionModalProps = {
  isOpen: boolean;
  action?: Action | null;
  onClose: () => void;
  defaultInstanceId?: string;
  projects: any[];
  instances: any[];
};

export default function ActionModal({
  isOpen,
  action,
  onClose,
  defaultInstanceId,
  projects,
  instances,
}: ActionModalProps) {
  const [createAction] = useCreateActionMutation();
  const [patchAction] = usePatchActionMutation();

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

  // Project map for quick lookup
  const projectMap = useMemo(() => {
    const map = new Map<string, string>();
    for (const p of projects) {
      map.set(p.project_id, p.name);
    }
    return map;
  }, [projects]);

  // Group instances by project
  const instancesByProject = useMemo(() => {
    const groups: Record<string, any[]> = {};
    for (const inst of instances) {
      const pid = inst.project_id || 'unassigned';
      if (!groups[pid]) groups[pid] = [];
      groups[pid].push(inst);
    }
    return groups;
  }, [instances]);

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
      const fallbackId = defaultInstanceId || (instances.length > 0 ? instances[0].agent_instance_id : '');
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
      const msg = err?.data?.error?.message || err?.error || err?.message || String(err || 'Failed to save action');
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
        className="my-8 w-full max-w-2xl rounded-2xl border border-white/10 bg-[#121212] p-6 shadow-2xl space-y-5"
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
          {/* Target Instance Picker */}
          <div>
            <label className="block text-xs font-semibold text-zinc-300 mb-1">
              Target Agent Instance *
            </label>
            <select
              data-debug-id="action-modal-instance-select"
              value={targetInstanceId}
              disabled={isEdit} // Instance is fixed once created
              onChange={(e) => setTargetInstanceId(e.target.value)}
              className="w-full rounded-xl border border-white/10 bg-zinc-900 px-3 py-2.5 text-sm text-zinc-100 outline-none focus:border-sky-400 disabled:opacity-60"
            >
              {instances.length === 0 ? (
                <option value="">No agent instances found</option>
              ) : (
                Object.entries(instancesByProject).map(([pid, instList]) => {
                  const projectName = pid === 'unassigned' ? 'Unassigned Project' : (projectMap.get(pid) || pid);
                  return (
                    <optgroup key={pid} label={`Project: ${projectName}`}>
                      {instList.map((inst) => {
                        const name = inst.display_name || inst.agent_name || inst.agent_id || inst.agent_instance_id;
                        return (
                          <option key={inst.agent_instance_id} value={inst.agent_instance_id}>
                            {name} ({inst.agent_instance_id}) [{inst.runtime_status || 'idle'}]
                          </option>
                        );
                      })}
                    </optgroup>
                  );
                })
              )}
            </select>
            {isEdit && (
              <p className="mt-1 text-[11px] text-zinc-500">
                Target agent instance cannot be changed after creation.
              </p>
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
