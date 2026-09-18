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
  500,
  'Composer panel expanded polling interval must be 500ms continuous'
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

// REQ-INT-3: Interactive Terminal Integration & ANSI Color Support
// REQ-WINSIZE-3: Terminal render window dimensions and viewport resize synchronization
import { agentsApi, useSendAgentPaneInputMutation, useSendAgentPaneResizeMutation } from '../src/ui/api/endpoints/agents';
import * as xtermModule from '@xterm/xterm';
import * as fitAddonModule from '@xterm/addon-fit';

console.log('Testing REQ-INT-3: sendAgentPaneInput API endpoint & hook...');
assert.equal(typeof useSendAgentPaneInputMutation, 'function', 'useSendAgentPaneInputMutation hook must be exported');
assert.ok(agentsApi.endpoints.sendAgentPaneInput, 'sendAgentPaneInput endpoint must exist on agentsApi');

console.log('Testing REQ-WINSIZE-3: sendAgentPaneResize API endpoint & hook...');
assert.equal(typeof useSendAgentPaneResizeMutation, 'function', 'useSendAgentPaneResizeMutation hook must be exported');
assert.ok(agentsApi.endpoints.sendAgentPaneResize, 'sendAgentPaneResize endpoint must exist on agentsApi');
assert.equal(typeof agentsApi.endpoints.sendAgentPaneResize.initiate, 'function', 'sendAgentPaneResize must have initiate function');

console.log('Testing REQ-INT-3 & REQ-WINSIZE-3: @xterm/xterm Terminal & ANSI color rendering...');
const TerminalClass = (xtermModule.Terminal || (xtermModule as any).default?.Terminal || (xtermModule as any).default);
const FitAddonClass = (fitAddonModule.FitAddon || (fitAddonModule as any).default?.FitAddon || (fitAddonModule as any).default);

assert.equal(typeof TerminalClass, 'function', 'Terminal must be available from @xterm/xterm');
assert.equal(typeof FitAddonClass, 'function', 'FitAddon must be available from @xterm/addon-fit');

const testTerminal = new TerminalClass({
  convertEol: true,
  cursorBlink: false,
  cursorInactiveStyle: 'none',
});
const testFit = new FitAddonClass();
testTerminal.loadAddon(testFit);

assert.equal(testTerminal.options.cursorBlink, false, 'Terminal cursorBlink must be disabled');
assert.equal(testTerminal.options.cursorInactiveStyle, 'none', 'Terminal cursorInactiveStyle must be none');

// Verify ANSI color test strings writing
const ansiColorString = '\x1b[31mRed\x1b[0m \x1b[32mGreen\x1b[0m \x1b[1;34mBold Blue\x1b[0m \x1b[38;2;255;100;50mRGB\x1b[0m\n';
testTerminal.write(ansiColorString);

// Verify keystroke dispatch hook
let capturedInput = '';
const disposable = testTerminal.onData((data: string) => {
  capturedInput = data;
});

testTerminal.input('ls -la\r');
assert.equal(capturedInput, 'ls -la\r', 'Terminal onData must capture input keystrokes');
disposable.dispose();

// Verify terminal onResize listener and dimension updates (REQ-WINSIZE-3)
let capturedResize: { cols: number; rows: number } | null = null;
const resizeDisposable = testTerminal.onResize((e: { cols: number; rows: number }) => {
  capturedResize = { cols: e.cols, rows: e.rows };
});

testTerminal.resize(110, 25);
assert.deepEqual(capturedResize, { cols: 110, rows: 25 }, 'Terminal onResize must fire with new cols and rows');
assert.equal(testTerminal.cols, 110, 'Terminal cols must update to 110');
assert.equal(testTerminal.rows, 25, 'Terminal rows must update to 25');
resizeDisposable.dispose();

// Verify auto-scroll to bottom
assert.equal(typeof testTerminal.scrollToBottom, 'function', 'Terminal must support scrollToBottom');
testTerminal.scrollToBottom();

console.log('ALL COMPOSER PANEL & INTERACTIVE TERMINAL TESTS PASSED (REQ-PANE-4, REQ-PANE-5, REQ-INT-3, REQ-WINSIZE-3)');
