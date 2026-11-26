/**
 * useApplyAgentSettings — the Apply flow behind the staged-changes footer
 * (ApplyFooter.tsx, `agent-panel-apply`). See DESIGN.md "Staged changes and Apply".
 *
 * The hook owns the request and what the footer says about it; the pane owns the
 * draft and the lifecycle endpoints, which it injects (so the flow is unit-testable
 * without RTK):
 *
 *   - Apply sends the FULL destination every time (bridge_id, project_id, provider,
 *     provider_profile, model, runtime_transport, permission_mode) with
 *     expected_revision = the instance's configuration_revision, a stable idempotency
 *     key per intent (replayed only after an ambiguous 5xx/network failure) and
 *     apply 'after_turn' while the agent is mid-turn, else 'now'.
 *   - "Restart now" is apply 'now' with a new key: the hub supersedes a queued change.
 *   - 409: refetch the instance, keep the draft, list what changed since the draft
 *     was started ("Changed since you opened: …").
 *   - Any other failure: the hub's error, draft kept.
 *   - Accepted: Restarting until the instance reports running on a NEW launch_epoch
 *     (the WS agent_instance summary patches launch_epoch), or the operation fails.
 *   - waiting_for_idle (queued after this turn): "Waiting for the turn to finish…"
 *     + Cancel; 30 min after waiting_since also "Still waiting · Restart now".
 *   - recovery_required: the existing retry endpoint.
 *
 * Pure helpers (`buildApplyRequest`, `applyFooterView`, `conflictMessage`) carry the
 * rules and are exported for tests (tests/ui_agent_settings_apply_test.ts).
 */
import { useCallback, useEffect, useRef, useState } from 'react';
import type {
  ApplyInstanceConfigurationInput,
  InstanceReconfiguration,
  ReconfigurationApply,
} from '../../api/endpoints/agents';
import type { LifecycleResult } from '../../hooks/useAgentLifecycle';
import { draftDiff, type AgentConfig, type DraftChange, type DraftLabels } from './agentSettingsDraft';

/** The hub keeps waiting indefinitely; after this long the footer offers Restart now. */
export const STILL_WAITING_AFTER_MS = 30 * 60 * 1000;

export const FOOTER_COPY = {
  restart: 'Restarts the agent with a fresh session. The conversation stays.',
  midTurn: "It's mid-turn, so the restart waits for the turn to finish.",
  stopped: 'Starts the agent with these settings.',
  waiting: 'Waiting for the turn to finish…',
  stillWaiting: 'Still waiting',
  restarting: 'Restarting the agent…',
  recovery: 'The last change did not finish. Retry it, or discard your changes.',
  conflictFallback: 'The agent’s settings changed since you opened them. Check your changes and apply again.',
} as const;

/** "Restarts the agent on dawnstar, in ~/src/app, with a fresh session. The conversation stays." */
export function bridgeMoveNote(bridge: string, folder: string): string {
  return folder
    ? `Restarts the agent on ${bridge}, in ${folder}, with a fresh session. The conversation stays.`
    : `Restarts the agent on ${bridge} with a fresh session. The conversation stays.`;
}

// ---------------------------------------------------------------- request

export interface BuildApplyRequestInput {
  instanceId: string;
  /** The agent's project; always resent ('' when it has none). */
  projectId: string;
  draft: AgentConfig;
  /** instance.configuration_revision */
  revision: number;
  apply: ReconfigurationApply;
}

/** The reconfiguration body minus its idempotency key: the full destination, always. */
export function buildApplyRequest(input: BuildApplyRequestInput): Omit<ApplyInstanceConfigurationInput, 'idempotency_key'> {
  const { draft } = input;
  return {
    instanceId: input.instanceId,
    bridge_id: draft.bridgeId,
    project_id: input.projectId,
    provider: draft.provider,
    provider_profile: draft.providerProfile || draft.provider,
    model: draft.model,
    runtime_transport: draft.transport,
    permission_mode: draft.bypass ? 'yolo' : 'ask',
    expected_revision: Number(input.revision || 0),
    apply: input.apply,
  };
}

function newKey(): string {
  return globalThis.crypto?.randomUUID?.() || `apply-${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

/** True when the hub may not have seen the request (network error or 5xx): replay the same key. */
function ambiguous(result: LifecycleResult): boolean {
  return result.status === 'failed' && (result.httpStatus === undefined || result.httpStatus >= 500);
}

// ---------------------------------------------------------------- state

export type ApplyPhase =
  /** Nothing in flight. */
  | 'idle'
  /** The reconfigure request is on the wire. */
  | 'submitting'
  /** Accepted; waiting for the instance to run on a new launch. */
  | 'restarting'
  /** Queued after the current turn (waiting_for_idle). */
  | 'waiting'
  /** The request or the operation failed; the draft is kept. */
  | 'failed'
  /** 409: the configuration changed since the draft was started. */
  | 'conflict'
  /** The latest operation is recovery_required: retry it. */
  | 'recovery';

export interface ApplyFlowState {
  phase: ApplyPhase;
  /** Hub error text (failed). */
  error: string;
  /** What changed since the draft was started (conflict). */
  conflict: DraftChange[];
  /** The queued operation's waiting_since (waiting). */
  waitingSince: string;
}

export function conflictMessage(changes: DraftChange[]): string {
  if (!changes.length) return FOOTER_COPY.conflictFallback;
  return `Changed since you opened: ${changes.map((c) => `${c.label} ${c.from} → ${c.to}`).join(', ')}.`;
}

// ---------------------------------------------------------------- footer view

export type PrimaryKind = 'apply' | 'after_turn' | 'start' | 'retry';

export interface ApplyFooterViewInput {
  changes: DraftChange[];
  flow: ApplyFlowState;
  /** activity busy: the agent is in a turn. */
  midTurn: boolean;
  /** The agent is stopped: Apply starts it. */
  stopped: boolean;
  /** The draft bridge's label and the project's folder there (bridge moves). */
  destinationBridge: string;
  destinationFolder: string;
  /** applyBlockedReason(...)?.message, or ''. */
  blockedMessage: string;
  /** Destination validation issues (no folder, offline bridge, …). */
  issues: string[];
  /** Another lifecycle action is in flight, or the inputs are locked. */
  busy: boolean;
  now: number;
}

export interface ApplyFooterView {
  visible: boolean;
  chips: DraftChange[];
  /** The note under the chips ('' for none). */
  note: string;
  /** Why Apply is disabled, shown instead of nothing ('' when enabled). */
  blocked: string;
  issues: string[];
  /** Danger alert: the hub's error. */
  error: string;
  /** Warning alert: "Changed since you opened: …". */
  conflict: string;
  /** Status line: waiting / still waiting / restarting. */
  status: string;
  primary: { kind: PrimaryKind; label: string; disabled: boolean; loading: boolean } | null;
  /** Ghost "Restart now" (mid-turn, and after 30 min of waiting). */
  restartNow: { disabled: boolean } | null;
  /** Ghost "Cancel" for a queued change. */
  cancel: { disabled: boolean } | null;
  discard: { disabled: boolean } | null;
}

const PRIMARY_LABEL: Record<PrimaryKind, string> = {
  apply: 'Apply and restart',
  after_turn: 'Restart after this turn',
  start: 'Apply and start',
  retry: 'Retry change',
};

export function applyFooterView(input: ApplyFooterViewInput): ApplyFooterView {
  const { flow, changes } = input;
  const hidden: ApplyFooterView = {
    visible: false, chips: [], note: '', blocked: '', issues: [], error: '', conflict: '', status: '',
    primary: null, restartNow: null, cancel: null, discard: null,
  };
  const submitting = flow.phase === 'submitting';

  if (flow.phase === 'restarting') {
    return { ...hidden, visible: true, chips: changes, status: FOOTER_COPY.restarting };
  }
  if (flow.phase === 'waiting') {
    const since = Date.parse(flow.waitingSince || '');
    const still = Number.isFinite(since) && input.now - since >= STILL_WAITING_AFTER_MS;
    return {
      ...hidden,
      visible: true,
      chips: changes,
      status: still ? FOOTER_COPY.stillWaiting : FOOTER_COPY.waiting,
      cancel: { disabled: input.busy },
      restartNow: still ? { disabled: input.busy || input.stopped } : null,
    };
  }
  if (flow.phase === 'recovery') {
    return {
      ...hidden,
      visible: true,
      chips: changes,
      note: FOOTER_COPY.recovery,
      error: flow.error,
      primary: { kind: 'retry', label: PRIMARY_LABEL.retry, disabled: input.busy || submitting, loading: submitting },
      discard: changes.length ? { disabled: input.busy || submitting } : null,
    };
  }
  if (!changes.length && flow.phase !== 'failed' && flow.phase !== 'conflict') return hidden;
  if (!changes.length) {
    // The failure outlived the draft (e.g. it was discarded): still say what happened.
    return { ...hidden, visible: true, error: flow.error, conflict: flow.phase === 'conflict' ? conflictMessage(flow.conflict) : '' };
  }

  const bridgeChange = changes.find((c) => c.field === 'bridge');
  let note: string;
  if (input.stopped) note = FOOTER_COPY.stopped;
  else {
    note = bridgeChange ? bridgeMoveNote(input.destinationBridge || bridgeChange.to, input.destinationFolder) : FOOTER_COPY.restart;
    if (input.midTurn) note = `${note} ${FOOTER_COPY.midTurn}`;
  }
  const kind: PrimaryKind = input.stopped ? 'start' : input.midTurn ? 'after_turn' : 'apply';
  const blocked = input.blockedMessage;
  const disabled = input.busy || submitting || Boolean(blocked) || input.issues.length > 0;
  return {
    ...hidden,
    visible: true,
    chips: changes,
    note,
    blocked,
    issues: input.issues,
    error: flow.phase === 'failed' ? flow.error : '',
    conflict: flow.phase === 'conflict' ? conflictMessage(flow.conflict) : '',
    primary: { kind, label: PRIMARY_LABEL[kind], disabled, loading: submitting },
    restartNow: kind === 'after_turn' ? { disabled } : null,
    discard: { disabled: input.busy || submitting },
  };
}

// ---------------------------------------------------------------- hook

type ReconfigureFn = (args: ApplyInstanceConfigurationInput) => Promise<LifecycleResult<InstanceReconfiguration>>;
type OperationRefFn = (args: { instanceId: string; idempotency_key: string; expected_operation_revision: number }) => Promise<LifecycleResult<InstanceReconfiguration>>;

export interface UseApplyAgentSettingsInput {
  instanceId: string;
  projectId: string;
  current: AgentConfig;
  draft: AgentConfig;
  revision: number;
  /** instance.launch_epoch: a new value means a new launch. */
  launchEpoch: string;
  /** The runtime is live (running). */
  running: boolean;
  midTurn: boolean;
  /** The latest reconfiguration (the pane's merged accepted/server operation). */
  operation: InstanceReconfiguration | null | undefined;
  labels?: DraftLabels;
  reconfigure: ReconfigureFn;
  retry: OperationRefFn;
  cancel: OperationRefFn;
  /** Refetch the instance after a 409 (its new revision and configuration). */
  refetchInstance: () => unknown;
  /** The hub accepted an operation (the pane shows it until the server list catches up). */
  onAccepted?: (operation: InstanceReconfiguration) => void;
}

export interface UseApplyAgentSettings {
  state: ApplyFlowState;
  changes: DraftChange[];
  /** Apply the draft: 'after_turn' while mid-turn, else 'now'. */
  apply: () => Promise<void>;
  /** Apply the draft at once, superseding a queued change. */
  restartNow: () => Promise<void>;
  /** Cancel the queued change (waiting_for_idle). */
  cancelWaiting: () => Promise<void>;
  /** Retry a recovery_required operation. */
  retry: () => Promise<void>;
  /** Forget a failure/conflict message (Discard). */
  clear: () => void;
}

interface Tracked {
  operationId: string;
  /** launch_epoch when the operation was accepted. */
  epoch: string;
}

export function useApplyAgentSettings(input: UseApplyAgentSettingsInput): UseApplyAgentSettings {
  const latest = useRef(input);
  latest.current = input;
  const changes = draftDiff(input.current, input.draft, input.labels);

  // The configuration the draft was started from: frozen while the draft is dirty.
  const baseline = useRef<AgentConfig>(input.current);
  if (!changes.length) baseline.current = input.current;

  const intent = useRef<{ signature: string; key: string } | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [failure, setFailure] = useState<{ kind: 'failed' | 'conflict'; error: string; base: AgentConfig | null } | null>(null);
  const [tracked, setTracked] = useState<Tracked | null>(null);

  const op = input.operation || null;
  const ownOp = tracked && op && op.operation_id === tracked.operationId ? op : null;
  const opFailed = Boolean(ownOp && ownOp.phase === 'failed' && ownOp.failure_code !== 'cancelled' && ownOp.failure_code !== 'superseded');
  const launched = Boolean(
    ownOp && input.running && !opFailed && ownOp.phase !== 'waiting_for_idle' &&
      (tracked!.epoch ? input.launchEpoch !== '' && input.launchEpoch !== tracked!.epoch : ownOp.phase === 'ready'),
  );
  const cancelled = Boolean(ownOp && ownOp.phase === 'failed' && ownOp.failure_code === 'cancelled');

  // Settle the tracked operation: launched on a new epoch, cancelled, or failed.
  useEffect(() => {
    if (!tracked) return;
    if (launched || cancelled) setTracked(null);
    else if (opFailed && ownOp) {
      setTracked(null);
      setFailure({ kind: 'failed', error: ownOp.failure_message || ownOp.failure_code || 'The change failed.', base: null });
    }
  }, [tracked, launched, cancelled, opFailed, ownOp?.failure_message, ownOp?.failure_code]);

  let state: ApplyFlowState;
  const none = { error: '', conflict: [], waitingSince: '' };
  if (submitting) state = { ...none, phase: 'submitting' };
  else if (op?.phase === 'waiting_for_idle') state = { ...none, phase: 'waiting', waitingSince: op.waiting_since || '' };
  else if (op?.phase === 'recovery_required') state = { ...none, phase: 'recovery', error: failure?.error || '' };
  else if (tracked && !launched && !cancelled && !opFailed) state = { ...none, phase: 'restarting' };
  else if (failure?.kind === 'conflict') {
    state = { ...none, phase: 'conflict', conflict: failure.base ? draftDiff(failure.base, input.current, input.labels) : [] };
  } else if (failure) state = { ...none, phase: 'failed', error: failure.error };
  else state = { ...none, phase: 'idle' };

  const send = useCallback(async (apply: ReconfigurationApply) => {
    const cur = latest.current;
    if (!cur.instanceId) return;
    const base = baseline.current;
    const request = buildApplyRequest({
      instanceId: cur.instanceId, projectId: cur.projectId, draft: cur.draft, revision: cur.revision, apply,
    });
    const signature = JSON.stringify(request);
    if (intent.current?.signature !== signature) intent.current = { signature, key: newKey() };
    const epoch = cur.launchEpoch;
    setSubmitting(true);
    setFailure(null);
    try {
      const result = await cur.reconfigure({ ...request, idempotency_key: intent.current.key });
      if (!ambiguous(result)) intent.current = null;
      if (result.status === 'accepted') {
        setTracked({ operationId: result.data.operation_id, epoch });
        latest.current.onAccepted?.(result.data);
        return;
      }
      if (result.status !== 'failed') return;
      if (result.httpStatus === 409) {
        setFailure({ kind: 'conflict', error: result.message, base });
        await latest.current.refetchInstance();
        return;
      }
      setFailure({ kind: 'failed', error: result.message, base: null });
    } finally {
      setSubmitting(false);
    }
  }, []);

  const apply = useCallback(() => send(latest.current.midTurn ? 'after_turn' : 'now'), [send]);
  const restartNow = useCallback(() => send('now'), [send]);

  const operationCall = useCallback(async (call: 'cancel' | 'retry') => {
    const cur = latest.current;
    const operation = cur.operation;
    if (!cur.instanceId || !operation) return;
    setSubmitting(true);
    setFailure(null);
    try {
      const result = await cur[call]({
        instanceId: cur.instanceId,
        idempotency_key: operation.idempotency_key,
        expected_operation_revision: operation.revision,
      });
      if (result.status === 'accepted') {
        if (call === 'retry') setTracked({ operationId: result.data.operation_id, epoch: cur.launchEpoch });
        cur.onAccepted?.(result.data);
      } else if (result.status === 'failed') {
        setFailure({ kind: 'failed', error: result.message, base: null });
      }
    } finally {
      setSubmitting(false);
    }
  }, []);

  return {
    state,
    changes,
    apply,
    restartNow,
    cancelWaiting: useCallback(() => operationCall('cancel'), [operationCall]),
    retry: useCallback(() => operationCall('retry'), [operationCall]),
    clear: useCallback(() => setFailure(null), []),
  };
}
