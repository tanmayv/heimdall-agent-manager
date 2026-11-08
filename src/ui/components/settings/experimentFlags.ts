import type { ExperimentFlag } from '../../api/endpoints/settings';

// Experiment keys mirror src/hub/domain/experiment.odin.
export const PROJECT_VCS_EXPERIMENT_KEY = 'project_vcs';
export const ACTIONS_EXPERIMENT_KEY = 'actions';
// A per-user setting kept in the same owner-scoped flag store (hub:
// domain.AUTO_APPROVE_AGENT_MEMORIES_KEY). On by default.
export const AUTO_APPROVE_AGENT_MEMORIES_KEY = 'auto_approve_agent_memories';

export type ExperimentFlagState = 'loading' | 'disabled' | 'enabled';

/**
 * Resolves one per-user experiment flag without conflating a pending request
 * with a loaded response where the key is absent (absent means disabled).
 *
 * The API guarantees unique, well-typed flags. If that contract is violated,
 * fail closed: malformed or duplicate entries cannot enable a feature.
 */
export function resolveExperimentFlag(
  flags: readonly ExperimentFlag[] | undefined,
  key: string,
): ExperimentFlagState {
  if (flags === undefined) return 'loading';

  const matches = flags.filter((flag) => flag != null && flag.key === key);
  if (matches.length !== 1 || typeof matches[0].enabled !== 'boolean') {
    return 'disabled';
  }
  return matches[0].enabled ? 'enabled' : 'disabled';
}

export function resolveActionsExperiment(
  flags: readonly ExperimentFlag[] | undefined,
): ExperimentFlagState {
  return resolveExperimentFlag(flags, ACTIONS_EXPERIMENT_KEY);
}

// REQ-EXP-2: toggles shown in Settings > Experimental, in display order.
export const EXPERIMENTAL_FLAGS: ReadonlyArray<{ key: string; label: string; description: string }> = [
  {
    key: 'lsp',
    label: 'Language Server Protocol (LSP) support',
    description: 'LSP integration. Enables in-editor diagnostics and completions. On by default; turning it on or off requires a restart of any active agent session.',
  },
  {
    key: 'streaming_terminal_pane',
    label: 'Streaming Terminal Pane',
    description: 'Real-time WebSocket streaming for interactive shell and agent terminal panes. Reduces interaction latency from 500ms to sub-10ms with native VT100 scrollback. On by default; turn off to fall back to polling.',
  },
  {
    key: PROJECT_VCS_EXPERIMENT_KEY,
    // Named like the Hub's refusal ("Project Explorer is experimental. Enable it in
    // Settings > Experimental…") so users can find the toggle it points to.
    label: 'Project Explorer (Files & VCS)',
    description: 'File and version-control explorer for projects and chain directories in conversations and chain overviews. On by default. Projects management is unaffected.',
  },
  {
    key: ACTIONS_EXPERIMENT_KEY,
    label: 'Actions',
    description: 'Scheduled and on-demand Actions. On by default. While off, Actions are hidden and scheduled runs are paused; saved Actions are kept.',
  },
  {
    key: AUTO_APPROVE_AGENT_MEMORIES_KEY,
    label: 'Auto-approve agent memories',
    description: 'Memories your agents propose are approved immediately instead of waiting in your queue. On by default; turn off to review each proposal.',
  },
];
