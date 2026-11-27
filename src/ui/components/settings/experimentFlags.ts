import type { ExperimentFlag } from '../../api/endpoints/settings';

// Experiment keys mirror src/hub/domain/experiment.odin.
export const PROJECT_VCS_EXPERIMENT_KEY = 'project_vcs';
export const ACTIONS_EXPERIMENT_KEY = 'actions';
export const BOTS_EXPERIMENT_KEY = 'bots';
/** Docked Agent settings panel (default on in the hub); off falls back to the modal. */
export const AGENT_SETTINGS_PANEL_EXPERIMENT_KEY = 'agent_settings_panel';

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
    description: 'Experimental LSP integration. Enables in-editor diagnostics and completions. Requires a restart of any active agent session.',
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
    description: 'Experimental file and version-control explorer for projects and chain directories in conversations and chain overviews. Projects management is unaffected.',
  },
  {
    key: ACTIONS_EXPERIMENT_KEY,
    label: 'Actions',
    description: 'Scheduled and on-demand Actions. While off, Actions are hidden and scheduled runs are paused; saved Actions are kept.',
  },
  { key: BOTS_EXPERIMENT_KEY, label: 'Bots', description: 'A personal bot you can talk to from Telegram or WhatsApp. It runs on your machines; Ninjy picks the machine and model.' },
  {
    key: AGENT_SETTINGS_PANEL_EXPERIMENT_KEY,
    label: 'Agent settings panel',
    description: 'Opens agent settings in a panel beside the conversation instead of a dialog. On by default; turn off to use the previous dialog.',
  },
];
