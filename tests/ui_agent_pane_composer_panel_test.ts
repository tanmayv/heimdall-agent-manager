import assert from 'node:assert/strict';
import React from 'react';
import { AgentPaneComposerPanel } from '../src/ui/components/chat/AgentPaneComposerPanel';
import { computeAgentPanePollingInterval } from '../src/ui/hooks/useAgentPaneSubscription';

console.log('Testing AgentPaneComposerPanel module and export contracts...');

assert.equal(typeof AgentPaneComposerPanel, 'function', 'AgentPaneComposerPanel must be a React function component');

// Test that props shape is well-formed
const element = React.createElement(AgentPaneComposerPanel, {
  agentInstanceId: 'inst_test_123',
  isExpanded: true,
  isActiveTab: true,
  runtimeStatus: 'running',
  onClose: () => {},
  onToggleExpand: () => {},
  className: 'custom-class',
});

assert.ok(element, 'React.createElement with AgentPaneComposerPanel must succeed');
assert.equal(element.props.agentInstanceId, 'inst_test_123');
assert.equal(element.props.isExpanded, true);
assert.equal(element.props.isActiveTab, true);
assert.equal(element.props.runtimeStatus, 'running');

// Verify polling interval rules for expanded vs collapsed state in composer
assert.equal(
  computeAgentPanePollingInterval({
    agentInstanceId: 'inst_test_123',
    isExpanded: true,
    isActiveTab: true,
    runtimeStatus: 'running',
    isDocumentHidden: false,
  }),
  15000,
  'Composer panel expanded polling interval must be 15s (15000ms)'
);

assert.equal(
  computeAgentPanePollingInterval({
    agentInstanceId: 'inst_test_123',
    isExpanded: false,
    isActiveTab: true,
    runtimeStatus: 'running',
    isDocumentHidden: false,
  }),
  300000,
  'Composer panel collapsed polling interval must be 5m (300000ms)'
);

assert.equal(
  computeAgentPanePollingInterval({
    agentInstanceId: 'inst_test_123',
    isExpanded: true,
    isActiveTab: false,
    runtimeStatus: 'running',
  }),
  0,
  'Inactive tab must pause polling (0ms)'
);

assert.equal(
  computeAgentPanePollingInterval({
    agentInstanceId: 'inst_test_123',
    isExpanded: true,
    isActiveTab: true,
    runtimeStatus: 'stopped',
  }),
  0,
  'Stopped agent runtime must pause polling (0ms)'
);

console.log('ALL COMPOSER PANEL TESTS PASSED (REQ-PANE-4, REQ-PANE-5)');
