// Pure view-model for the chat pane's action tray (REQ-AT-1/6/7): which task
// items belong to a conversation, and whether the tray or the composer shows.
// No React; unit-tested in tests/ui_action_tray_test.ts.
import type { AttentionBlockerItem, AttentionItem, AttentionTaskItem } from '../../api/endpoints/attention';
import { blockerReason, hideKey } from './attentionModel';

/** What the tray pages through: tasks waiting on the user, and live agent blockers. */
export type TrayItem = AttentionTaskItem | AttentionBlockerItem;

/** Whose items a pane shows: its task chain, or (no chain) the agent instance holding the task. */
export type TrayScope = { chainId: string; agentInstanceId: string };

/**
 * The items that need the user in this conversation, not hidden by a
 * pending/settled attention action, server order kept:
 * - agent blockers (permission / terminal prompts) of the chain, or of this
 *   agent instance when the pane has no chain — listed first, an agent is stalled;
 * - live (not snoozed) task cards blocked on the user or waiting on their review.
 */
export function trayItems(items: readonly AttentionItem[], scope: TrayScope, hidden: ReadonlySet<string> = new Set()): TrayItem[] {
  const chainId = scope.chainId.trim();
  const instanceId = scope.agentInstanceId.trim();
  if (!chainId && !instanceId) return [];
  const blockers = items.filter((item): item is AttentionBlockerItem => {
    if (item.kind !== 'agent_blocker' || hidden.has(hideKey(item))) return false;
    if (chainId) return item.action_refs?.chain_id === chainId;
    return item.action_refs?.agent_instance_id === instanceId;
  });
  const tasks = items.filter((item): item is AttentionTaskItem => {
    if (item.kind !== 'task' || item.snoozed) return false;
    const attention = item.details?.attention;
    if (attention !== 'blocked' && attention !== 'review') return false;
    if (hidden.has(hideKey(item))) return false;
    if (chainId) return item.action_refs?.chain_id === chainId;
    return !!instanceId && item.details?.holder_instance_id === instanceId;
  });
  return [...blockers, ...tasks];
}

export function isBlockedItem(item: AttentionTaskItem): boolean {
  return item.details.attention === 'blocked';
}

/** "Needs your answer" (blocked) / "Needs your approval" (review) / "Needs your permission" (blocker). */
export function needLabel(item: TrayItem): string {
  if (item.kind === 'agent_blocker') return blockerReason(item);
  if (item.details.badge === 'agent_not_running') return 'Needs you to start the agent';
  return isBlockedItem(item) ? 'Needs your answer' : 'Needs your approval';
}

/** The pill and panel title: "1 need you", "3 need you". */
export function needYouLabel(count: number): string {
  return `${count} need you`;
}

/** Answer (blocked) and Request changes (review) borrow the composer for their text. */
export type TrayModeKind = 'answer' | 'changes';
export type TrayMode = { kind: TrayModeKind; cardId: string };

export type TrayState = {
  /** What the user picked: the items, or the composer. */
  view: 'items' | 'composer';
  /** The composer is borrowed to answer / request changes on one card. */
  mode: TrayMode | null;
  /** Card ids already seen, so only a NEW item flips the dock back to the tray. */
  seen: readonly string[];
};

export const INITIAL_TRAY_STATE: TrayState = { view: 'items', mode: null, seen: [] };

export type TrayEvent =
  | { type: 'show_composer' }
  | { type: 'show_items' }
  | { type: 'start_mode'; kind: TrayModeKind; cardId: string }
  | { type: 'cancel_mode' }
  | { type: 'mode_sent' }
  /** The visible items changed. draftEmpty: the user is not halfway through a message. */
  | { type: 'items'; ids: readonly string[]; draftEmpty: boolean };

export function trayReducer(state: TrayState, event: TrayEvent): TrayState {
  switch (event.type) {
    case 'show_composer':
      return state.view === 'composer' && !state.mode ? state : { ...state, view: 'composer', mode: null };
    case 'show_items':
      return state.view === 'items' && !state.mode ? state : { ...state, view: 'items', mode: null };
    case 'start_mode':
      return { ...state, view: 'composer', mode: { kind: event.kind, cardId: event.cardId } };
    // Leaving a mode (sent or cancelled) goes back to the items; with none left
    // the composer shows anyway.
    case 'cancel_mode':
    case 'mode_sent':
      return { ...state, view: 'items', mode: null };
    case 'items': {
      const ids = event.ids;
      const known = new Set(state.seen);
      const arrived = ids.some((id) => !known.has(id));
      let { view, mode } = state;
      // The card being answered went away (answered elsewhere, or settled): drop the mode.
      if (mode && !ids.includes(mode.cardId)) {
        mode = null;
        view = 'items';
      }
      // A new item takes the dock back, unless the user is typing.
      if (arrived && !mode && event.draftEmpty) view = 'items';
      const sameSeen = ids.length === state.seen.length && ids.every((id, i) => id === state.seen[i]);
      if (sameSeen && view === state.view && mode === state.mode) return state;
      return { view, mode, seen: sameSeen ? state.seen : [...ids] };
    }
    default:
      return state;
  }
}

/** The dock shows the tray only when there are items, the user picked them, and no mode borrows the composer. */
export function trayVisible(state: TrayState, itemCount: number): boolean {
  return itemCount > 0 && state.view === 'items' && !state.mode;
}

/** The "<n> need you" pill rides on the composer when items wait and no mode is active. */
export function needYouPillVisible(state: TrayState, itemCount: number): boolean {
  return itemCount > 0 && !state.mode && !trayVisible(state, itemCount);
}

/** Composer copy while a mode borrows it. */
export const TRAY_MODE_COPY: Record<TrayModeKind, { banner: string; placeholder: string; sent: string }> = {
  answer: { banner: 'Answering', placeholder: 'Your answer…', sent: 'Answer sent' },
  changes: { banner: 'Requesting changes on', placeholder: 'What should change?', sent: 'Changes requested' },
};
