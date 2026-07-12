export type TeamKindPace = 'fast' | 'normal' | 'slow';
export type TeamKindVcsMode = 'on' | 'off' | 'project';

export type TeamKindScaffoldMeta = {
  key: string;
  label: string;
  description: string;
  pace: TeamKindPace;
  expectedTaskCount: number;
  collaboratingAgentCount: number;
};

export type TeamKindMeta = {
  key: string;
  label: string;
  description: string;
  pace: TeamKindPace;
  expectedTaskCount: number;
  collaboratingAgentCount: number;
  wantsVcsMode: TeamKindVcsMode;
  scaffolds: TeamKindScaffoldMeta[];
};

export const NONE_SCAFFOLD_META: TeamKindScaffoldMeta = {
  key: 'none',
  label: 'none',
  description: 'Coordinator discovery only; creates one initial task to clarify the goal and plan follow-on work.',
  pace: 'normal',
  expectedTaskCount: 1,
  collaboratingAgentCount: 1,
};

export const TEAM_KIND_METADATA: TeamKindMeta[] = [
  {
    key: 'coding',
    label: 'Coding',
    description: 'Code changes, bug fixes, refactors, and repo chores with separate implementation, testing, and review roles.',
    pace: 'normal',
    expectedTaskCount: 1,
    collaboratingAgentCount: 4,
    wantsVcsMode: 'on',
    scaffolds: [
      {
        key: 'feature',
        label: 'feature',
        description: 'Contracts-first delivery: plan, define interfaces, implement, test, then summarize.',
        pace: 'slow',
        expectedTaskCount: 5,
        collaboratingAgentCount: 4,
      },
      {
        key: 'bugfix',
        label: 'bugfix',
        description: 'Tester reproduces first, coder fixes, tester verifies, coordinator closes out.',
        pace: 'fast',
        expectedTaskCount: 4,
        collaboratingAgentCount: 4,
      },
      {
        key: 'refactor',
        label: 'refactor',
        description: 'Coordinator plans, coder refactors, tester validates regressions, coordinator summarizes.',
        pace: 'normal',
        expectedTaskCount: 4,
        collaboratingAgentCount: 4,
      },
      {
        key: 'chore',
        label: 'chore',
        description: 'Small repo/config maintenance with implementation followed by coordinator summary.',
        pace: 'fast',
        expectedTaskCount: 2,
        collaboratingAgentCount: 4,
      },
      {
        key: 'incident',
        label: 'incident',
        description: 'Coordinator triage, coder mitigation/fix, tester-led RCA validation, then post-mortem.',
        pace: 'slow',
        expectedTaskCount: 5,
        collaboratingAgentCount: 4,
      },
    ],
  },
  {
    key: 'research',
    label: 'Research',
    description: 'Non-code investigation, RCA, analysis, and synthesis led by a dedicated researcher persona.',
    pace: 'normal',
    expectedTaskCount: 1,
    collaboratingAgentCount: 3,
    wantsVcsMode: 'off',
    scaffolds: [
      {
        key: 'report',
        label: 'report',
        description: 'Scope the question, gather evidence, synthesize findings, then summarize.',
        pace: 'slow',
        expectedTaskCount: 4,
        collaboratingAgentCount: 3,
      },
      {
        key: 'spike',
        label: 'spike',
        description: 'Explore an open question and conclude with evidence-backed recommendations.',
        pace: 'normal',
        expectedTaskCount: 4,
        collaboratingAgentCount: 3,
      },
      {
        key: 'analysis',
        label: 'analysis',
        description: 'Define the frame, investigate data/sources, synthesize insights, then summarize.',
        pace: 'normal',
        expectedTaskCount: 4,
        collaboratingAgentCount: 3,
      },
    ],
  },
  {
    key: 'solo',
    label: 'Solo',
    description: 'A coordinator plus one worker with user_proxy approval, following the project VCS default when available.',
    pace: 'fast',
    expectedTaskCount: 1,
    collaboratingAgentCount: 3,
    wantsVcsMode: 'project',
    scaffolds: [
      {
        key: 'solo',
        label: 'solo',
        description: 'Single-worker flow: plan, work, explicit user review, then summary.',
        pace: 'fast',
        expectedTaskCount: 4,
        collaboratingAgentCount: 3,
      },
    ],
  },
];

export function paceLabel(pace: TeamKindPace) {
  return pace.charAt(0).toUpperCase() + pace.slice(1);
}

export function taskCountLabel(count: number) {
  return `${count} task${count === 1 ? '' : 's'}`;
}

export function collaboratingAgentLabel(count: number) {
  return `${count} collaborating agent${count === 1 ? '' : 's'}`;
}

export function wantsVcsLabel(mode: TeamKindVcsMode) {
  if (mode === 'project') return 'project default';
  return mode === 'on' ? 'default on' : 'default off';
}

export function kindOptionLabel(kind: TeamKindMeta) {
  return `${kind.label} — ${paceLabel(kind.pace)} pace · ${collaboratingAgentLabel(kind.collaboratingAgentCount)}`;
}

export function scaffoldOptionLabel(scaffold: TeamKindScaffoldMeta) {
  if (scaffold.key === 'none') return 'none — 1 task (Coordinator discovery only)';
  return `${scaffold.label} — ${paceLabel(scaffold.pace)} pace · ${taskCountLabel(scaffold.expectedTaskCount)} · ${scaffold.collaboratingAgentCount} agents`;
}

export function defaultWantsVcs(kind: TeamKindMeta, projectSupportsVcs: boolean) {
  if (!projectSupportsVcs) return false;
  if (kind.wantsVcsMode === 'off') return false;
  return true;
}

export function findTeamKind(key: string) {
  return TEAM_KIND_METADATA.find((item) => item.key === key) || TEAM_KIND_METADATA[0];
}

export function findScaffold(kind: TeamKindMeta, key: string) {
  if (key === 'none') return NONE_SCAFFOLD_META;
  return kind.scaffolds.find((item) => item.key === key) || NONE_SCAFFOLD_META;
}
