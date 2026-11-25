import { useCallback, useRef, useState } from 'react';
import {
  useCreateAgentInstanceMutation, useStartInstanceMutation,
  useStopAgentInstanceMutation, useRestartAgentInstanceMutation,
  useApplyInstanceConfigurationMutation, useRetryInstanceConfigurationMutation,
  isAlreadyRunningError, lifecycleErrorMessage,
} from '../api/endpoints/agents';

export type LifecycleAction = 'create' | 'start' | 'stop' | 'restart' | 'reconfigure' | 'retry';
export type LifecycleResult<T = unknown> =
  | { status: 'accepted'; data: T; message: string }
  | { status: 'already-running'; message: string }
  | { status: 'failed'; error: unknown; message: string; code?: string; httpStatus?: number };

const labels: Record<LifecycleAction, string> = {
  create: 'Launch', start: 'Start', stop: 'Stop', restart: 'Restart',
  reconfigure: 'Configuration change', retry: 'Recovery retry',
};

/** The same policy applies to every view; HTTP acceptance is not runtime completion. */
export async function lifecycleResult<T>(action: LifecycleAction, invoke: () => Promise<T>): Promise<LifecycleResult<T>> {
  try {
    return { status: 'accepted', data: await invoke(), message: `${labels[action]} requested.` };
  } catch (error) {
    if (action === 'start' && isAlreadyRunningError(error)) {
      return { status: 'already-running', message: 'Already running.' };
    }
    const detail = error as { details?: { code?: string }; originalStatus?: number; data?: { error?: { details?: { code?: string } } } };
    return { status: 'failed', error, message: lifecycleErrorMessage(error, `${labels[action]} failed`),
      code: detail?.details?.code || detail?.data?.error?.details?.code, httpStatus: detail?.originalStatus };
  }
}

/** Own invocation, pending state and feedback; keep the existing RTK endpoints underneath. */
type LifecyclePresentation = {
  inline?: (result: LifecycleResult | null) => void;
  toast?: (entry: { tone: 'danger' | 'success'; title: string }) => void;
};

export function useAgentLifecycle(presentation: LifecyclePresentation = {}) {
  const presenter = useRef(presentation);
  presenter.current = presentation;
  const [createMutation] = useCreateAgentInstanceMutation();
  const [startMutation] = useStartInstanceMutation();
  const [stopMutation] = useStopAgentInstanceMutation();
  const [restartMutation] = useRestartAgentInstanceMutation();
  const [reconfigureMutation] = useApplyInstanceConfigurationMutation();
  const [retryMutation] = useRetryInstanceConfigurationMutation();
  const [pending, setPending] = useState<Record<string, LifecycleAction>>({});
  const [result, setResult] = useState<LifecycleResult | null>(null);
  const inFlight = useRef(new Map<string, Promise<LifecycleResult<any>>>());
  const run = useCallback(<T,>(action: LifecycleAction, id: string, invoke: () => Promise<T>): Promise<LifecycleResult<T>> => {
    // Coalesce repeated clicks for this resource without manufacturing a second durable request.
    const key = `${action}:${id}`;
    const existing = inFlight.current.get(key);
    if (existing) return existing;
    setResult(null);
    presenter.current.inline?.(null);
    setPending(current => ({ ...current, [key]: action }));
    const request = lifecycleResult(action, invoke).then(next => {
      setResult(next);
      // One sink per surface. Inline feedback takes precedence over the existing toast facility.
      if (presenter.current.inline) presenter.current.inline(next);
      else presenter.current.toast?.({ tone: next.status === 'failed' ? 'danger' : 'success', title: next.message });
      return next;
    }).finally(() => {
      inFlight.current.delete(key);
      setPending(current => { const next = { ...current }; delete next[key]; return next; });
    });
    inFlight.current.set(key, request);
    return request;
  }, []);
  const create = useCallback((args: Parameters<typeof createMutation>[0]) => run('create', args.agentId, () => createMutation(args).unwrap()), [run, createMutation]);
  const start = useCallback((args: Parameters<typeof startMutation>[0]) => run('start', typeof args === 'string' ? args : args.instanceId, () => startMutation(args).unwrap()), [run, startMutation]);
  const stop = useCallback((args: Parameters<typeof stopMutation>[0]) => run('stop', args.instanceId, () => stopMutation(args).unwrap()), [run, stopMutation]);
  const restart = useCallback((args: Parameters<typeof restartMutation>[0]) => run('restart', args.instanceId, () => restartMutation(args).unwrap()), [run, restartMutation]);
  // Revision and idempotency identity belong to the caller's durable intent; forward unchanged.
  const reconfigure = useCallback((args: Parameters<typeof reconfigureMutation>[0]) => run('reconfigure', args.instanceId, () => reconfigureMutation(args).unwrap()), [run, reconfigureMutation]);
  const retry = useCallback((args: Parameters<typeof retryMutation>[0]) => run('retry', args.instanceId, () => retryMutation(args).unwrap()), [run, retryMutation]);
  const isPending = (action?: LifecycleAction, instanceId?: string) => Object.entries(pending).some(([key, value]) => (!action || value === action) && (!instanceId || key === `${value}:${instanceId}`));
  return { create, start, stop, restart, reconfigure, retry, isPending, pending, result, clearResult: () => setResult(null) };
}
