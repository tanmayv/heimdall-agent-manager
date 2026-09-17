import assert from 'node:assert/strict';
import { configureStore } from '@reduxjs/toolkit';
import { computeAgentPanePollingInterval } from '../src/ui/hooks/useAgentPaneSubscription';
import { heimdallApi } from '../src/ui/api/heimdallApi';
import { agentsApi, useGetAgentPaneQuery, useLazyGetAgentPaneQuery } from '../src/ui/api/endpoints/agents';

console.log('Testing computeAgentPanePollingInterval...');

// 1. Inactive / paused conditions return 0
assert.equal(
  computeAgentPanePollingInterval({
    agentInstanceId: null,
    isExpanded: true,
    isActiveTab: true,
  }),
  0,
  'null agentInstanceId must return 0'
);

assert.equal(
  computeAgentPanePollingInterval({
    agentInstanceId: '',
    isExpanded: true,
    isActiveTab: true,
  }),
  0,
  'empty agentInstanceId must return 0'
);

assert.equal(
  computeAgentPanePollingInterval({
    agentInstanceId: 'inst_1',
    isExpanded: true,
    isActiveTab: false,
  }),
  0,
  'isActiveTab=false must return 0'
);

assert.equal(
  computeAgentPanePollingInterval({
    agentInstanceId: 'inst_1',
    isExpanded: true,
    isActiveTab: true,
    isDocumentHidden: true,
  }),
  0,
  'isDocumentHidden=true must return 0'
);

assert.equal(
  computeAgentPanePollingInterval({
    agentInstanceId: 'inst_1',
    isExpanded: true,
    isActiveTab: true,
    runtimeStatus: 'stopped',
  }),
  0,
  'runtimeStatus=stopped must return 0'
);

assert.equal(
  computeAgentPanePollingInterval({
    agentInstanceId: 'inst_1',
    isExpanded: true,
    isActiveTab: true,
    runtimeStatus: 'failed',
  }),
  0,
  'runtimeStatus=failed must return 0'
);

// 2. Active expanded returns 15000 (15 seconds)
assert.equal(
  computeAgentPanePollingInterval({
    agentInstanceId: 'inst_1',
    isExpanded: true,
    isActiveTab: true,
    runtimeStatus: 'running',
    isDocumentHidden: false,
  }),
  15000,
  'expanded active subscription must return 15000 (15s)'
);

// 3. Active collapsed returns 300000 (5 minutes)
assert.equal(
  computeAgentPanePollingInterval({
    agentInstanceId: 'inst_1',
    isExpanded: false,
    isActiveTab: true,
    runtimeStatus: 'running',
    isDocumentHidden: false,
  }),
  300000,
  'collapsed active subscription must return 300000 (5m)'
);

console.log('Testing agentsApi getAgentPane endpoint exports & caching...');

// 4. Verify endpoint exists on agentsApi
const endpoint = agentsApi.endpoints.getAgentPane;
assert.ok(endpoint, 'agentsApi must define getAgentPane endpoint');
assert.equal(typeof endpoint.initiate, 'function', 'endpoint must have initiate function');

// 5. Verify hook exports
assert.equal(typeof useGetAgentPaneQuery, 'function', 'useGetAgentPaneQuery must be exported');
assert.equal(typeof useLazyGetAgentPaneQuery, 'function', 'useLazyGetAgentPaneQuery must be exported');

// 6. Test Redux store integration and cache retention with mock fetch
let fetchUrlCalled = '';
let fetchCallCount = 0;
let mockResponsePayload: any = {
  data: {
    ok: true,
    unchanged: false,
    hash: 'hash_v1',
    output: 'line 1\nline 2',
    line_count: 2,
  },
};

globalThis.fetch = (async (url: string) => {
  fetchUrlCalled = url;
  fetchCallCount++;
  return {
    ok: true,
    status: 200,
    json: async () => mockResponsePayload,
    text: async () => JSON.stringify(mockResponsePayload),
  } as any;
}) as any;

const store = configureStore({
  reducer: {
    [heimdallApi.reducerPath]: heimdallApi.reducer,
  },
  middleware: (getDefaultMiddleware) =>
    getDefaultMiddleware().concat(heimdallApi.middleware),
});

// Initial query fetch (no sinceHash)
const res1 = await store.dispatch(
  endpoint.initiate(
    { agentInstanceId: 'inst_test_1', width: 80, lineLimit: 120 },
    { forceRefetch: true }
  )
);
assert.equal(fetchCallCount, 1);
assert.ok(fetchUrlCalled.includes('/api/v1/agent-instances/inst_test_1/pane'));
assert.ok(fetchUrlCalled.includes('since_hash='));
assert.ok(fetchUrlCalled.includes('width=80'));
assert.ok(fetchUrlCalled.includes('line_limit=120'));
assert.equal(res1.data?.output, 'line 1\nline 2');
assert.equal(res1.data?.hash, 'hash_v1');

// Second query fetch with sinceHash matching and unchanged: true
mockResponsePayload = {
  data: {
    ok: true,
    unchanged: true,
    hash: 'hash_v1',
    output: '',
  },
};

const res2 = await store.dispatch(
  endpoint.initiate(
    { agentInstanceId: 'inst_test_1', sinceHash: 'hash_v1', width: 80, lineLimit: 120 },
    { forceRefetch: true }
  )
);
assert.equal(fetchCallCount, 2);
assert.ok(fetchUrlCalled.includes('since_hash=hash_v1'));

// Check state in store: previous output buffer MUST be retained!
const querySubstate = endpoint.select({
  agentInstanceId: 'inst_test_1',
  width: 80,
  lineLimit: 120,
})(store.getState());

assert.equal(querySubstate.data?.output, 'line 1\nline 2', 'cached output buffer must be retained when response is unchanged');
assert.equal(querySubstate.data?.hash, 'hash_v1');
assert.equal(querySubstate.data?.unchanged, true);

console.log('ALL TESTS PASSED (REQ-PANE-3)');
