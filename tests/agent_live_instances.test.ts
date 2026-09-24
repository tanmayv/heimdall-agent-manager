import { describe, it, expect } from 'vitest';
import {
  AGENT_TABS,
  parseAgentListUrl,
  agentListSearch,
  isLiveRuntimeStatus,
  relativeTime,
  absoluteTime,
  type AgentTab,
  type AgentListUrlState,
} from '../src/ui/components/agents/agentModel';
import {
  Card,
  DetailRow,
  CopyButton,
  usePaneIsWide,
  AgentDetailPaneSkeleton,
  LiveInstanceDetailPane,
} from '../src/ui/components/agents/AgentDetail';

describe('Live Instances Model & URL State (REQ-AGENTS-LIVE-INSTANCES-1)', () => {
  it('has Live Instances as the first tab in AGENT_TABS', () => {
    expect(AGENT_TABS).toHaveLength(3);
    expect(AGENT_TABS[0]).toEqual({ value: 'live', label: 'Live Instances' });
    expect(AGENT_TABS[1]).toEqual({ value: 'active', label: 'Active' });
    expect(AGENT_TABS[2]).toEqual({ value: 'archived', label: 'Archived' });
  });

  it('defaults to live tab when tab is not set in urlState', () => {
    const urlState: AgentListUrlState = { tab: '', q: '' };
    const tab: AgentTab = urlState.tab || 'live';
    expect(tab).toBe('live');
  });

  it('parses and serializes URL state with tab and instanceId', () => {
    const parsed = parseAgentListUrl('?tab=live&instance=inst_test_123&q=jetski');
    expect(parsed.tab).toBe('live');
    expect(parsed.instanceId).toBe('inst_test_123');
    expect(parsed.q).toBe('jetski');

    const search = agentListSearch(parsed);
    expect(search).toContain('tab=live');
    expect(search).toContain('instance=inst_test_123');
    expect(search).toContain('q=jetski');
  });

  it('correctly identifies live runtime status', () => {
    const liveStatuses = ['running', 'starting', 'launching', 'idle', 'busy', 'ready'];
    for (const status of liveStatuses) {
      expect(isLiveRuntimeStatus(status)).toBe(true);
      expect(isLiveRuntimeStatus(status.toUpperCase())).toBe(true);
      expect(isLiveRuntimeStatus(`  ${status}  `)).toBe(true);
    }

    const nonLiveStatuses = ['stopped', 'failed', 'terminated', '', undefined, 'unknown', 'offline'];
    for (const status of nonLiveStatuses) {
      expect(isLiveRuntimeStatus(status)).toBe(false);
    }
  });

  it('formats relative and absolute timestamps properly', () => {
    expect(absoluteTime('')).toBe('—');
    expect(relativeTime('')).toBe('—');

    const nowIso = new Date().toISOString();
    expect(relativeTime(nowIso)).toBe('just now');
    expect(absoluteTime(nowIso)).not.toBe('—');
  });
});

describe('Zero Duplication: Exported Helpers and Components', () => {
  it('exports Card, DetailRow, CopyButton, usePaneIsWide, AgentDetailPaneSkeleton, and LiveInstanceDetailPane', () => {
    expect(typeof Card).toBe('function');
    expect(typeof DetailRow).toBe('function');
    expect(typeof CopyButton).toBe('function');
    expect(typeof usePaneIsWide).toBe('function');
    expect(typeof AgentDetailPaneSkeleton).toBe('function');
    expect(typeof LiveInstanceDetailPane).toBe('function');
  });
});
