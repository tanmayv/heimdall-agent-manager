// REQ-AGENTS-CHAIN-NAME-31: Unit & Regression Tests for Task Chain Name on Agents Page
//
// RUN: node --test tests/ui_agents_chain_name_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

test('AgentListPage.tsx imports useListFlatTaskChainsQuery and VaultText', () => {
  const filePath = path.join(REPO_ROOT, 'src/ui/components/agents/AgentListPage.tsx');
  assert.ok(fs.existsSync(filePath), 'AgentListPage.tsx must exist');

  const content = fs.readFileSync(filePath, 'utf8');

  assert.match(
    content,
    /import\s*\{[^}]*useListFlatTaskChainsQuery[^}]*\}\s*from\s*['"]\.\.\/\.\.\/api\/endpoints\/taskChains['"]/,
    'AgentListPage must import useListFlatTaskChainsQuery from taskChains endpoint',
  );
  assert.match(
    content,
    /import\s*\{[^}]*VaultText[^}]*\}\s*from\s*['"]\.\.\/vault\/VaultText['"]/,
    'AgentListPage must import VaultText',
  );
});

test('AgentListPage.tsx queries flat task chains and builds chainMap', () => {
  const filePath = path.join(REPO_ROOT, 'src/ui/components/agents/AgentListPage.tsx');
  const content = fs.readFileSync(filePath, 'utf8');

  // Verify invocation of useListFlatTaskChainsQuery
  assert.match(
    content,
    /const\s+chainsQuery\s*=\s*useListFlatTaskChainsQuery\(\)/,
    'AgentListPage must call useListFlatTaskChainsQuery()',
  );

  // Verify chainMap construction
  assert.match(
    content,
    /const\s+chainMap\s*=\s*React\.useMemo\(\(\)\s*=>\s*\{[\s\S]*new\s+Map<string,\s*string>\(\)[\s\S]*map\.set\(id,\s*String\(c\.title\s*\|\|\s*c\.name\s*\|\|\s*id\)\)[\s\S]*return\s+map;[\s\S]*\},\s*\[rawChains\]\)/,
    'AgentListPage must build memoized chainMap mapping chainId to title',
  );
});

test('AgentListPage.tsx renders live instance chain badge with VaultText and title={chId}', () => {
  const filePath = path.join(REPO_ROOT, 'src/ui/components/agents/AgentListPage.tsx');
  const content = fs.readFileSync(filePath, 'utf8');

  // Resolves human-readable chName
  assert.match(
    content,
    /const\s+chName\s*=\s*chainMap\.get\(chId\)\s*\|\|\s*chId;/,
    'AgentListPage must resolve chName from chainMap',
  );

  // Live instance chain badge renders title={chId} and VaultText with chName and fallback={chId}
  assert.match(
    content,
    /<Badge\s+data-debug-id=\{`live-instance-chain-\$\{instId\}`\}\s+title=\{chId\}>\s*<VaultText\s+value=\{chName\}\s+fallback=\{chId\}\s*\/>\s*<\/Badge>/,
    'Live instance chain badge must render VaultText with chName and title={chId}',
  );

  // Project badge renders VaultText with projName and fallback={projId}
  assert.match(
    content,
    /<Badge\s+data-debug-id=\{`live-instance-project-\$\{instId\}`\}>\s*<VaultText\s+value=\{projName\}\s+fallback=\{projId\}\s*\/>\s*<\/Badge>/,
    'Live instance project badge must render VaultText with projName',
  );
});

test('AgentListPage.tsx search filtering matches against both chName and chId', () => {
  const filePath = path.join(REPO_ROOT, 'src/ui/components/agents/AgentListPage.tsx');
  const content = fs.readFileSync(filePath, 'utf8');

  // Search filtering logic must check chName and chId
  assert.match(
    content,
    /chName\.includes\(searchNormalized\)/,
    'Search filter must match against chName',
  );
  assert.match(
    content,
    /chId\.includes\(searchNormalized\)/,
    'Search filter must match against chId',
  );
  assert.match(
    content,
    /\[liveInstances,\s*searchNormalized,\s*projectMap,\s*chainMap\]/,
    'filteredLiveInstances memo must depend on chainMap',
  );
});

test('Pure search filtering logic matches by chain title, chain ID, and other fields', () => {
  const chainMap = new Map<string, string>([
    ['chain_18daf5b0dc39a86f', 'Simplify conversation layout & task-chain sidebar persistence'],
    ['chain_2222222222222222', 'vault:v1:ArmoredChainTitle'],
  ]);

  const liveInstances = [
    {
      agent_instance_id: 'inst_18daf649a20f7b22',
      display_name: 'worker #76',
      chain_id: 'chain_18daf5b0dc39a86f',
      provider: 'jetski',
      project_id: 'proj_1',
    },
    {
      agent_instance_id: 'inst_abc123',
      display_name: 'coordinator #1',
      chain_id: 'chain_2222222222222222',
      provider: 'claude',
      project_id: 'proj_2',
    },
  ];

  function filterInstances(instances: typeof liveInstances, query: string) {
    const searchNormalized = query.trim().toLowerCase();
    if (!searchNormalized) return instances;
    return instances.filter((inst) => {
      const name = String(inst.display_name || '').toLowerCase();
      const instId = String(inst.agent_instance_id || '').toLowerCase();
      const rawChId = String(inst.chain_id || '');
      const chId = rawChId.toLowerCase();
      const chName = String(chainMap.get(rawChId) || rawChId).toLowerCase();
      const prov = String(inst.provider || '').toLowerCase();
      return (
        name.includes(searchNormalized) ||
        instId.includes(searchNormalized) ||
        chName.includes(searchNormalized) ||
        chId.includes(searchNormalized) ||
        prov.includes(searchNormalized)
      );
    });
  }

  // 1. Search by human-readable chain name
  const matchByName = filterInstances(liveInstances, 'conversation layout');
  assert.equal(matchByName.length, 1);
  assert.equal(matchByName[0].agent_instance_id, 'inst_18daf649a20f7b22');

  // 2. Search by raw chain id
  const matchById = filterInstances(liveInstances, '18daf5b0dc');
  assert.equal(matchById.length, 1);
  assert.equal(matchById[0].agent_instance_id, 'inst_18daf649a20f7b22');

  // 3. Search by provider
  const matchByProvider = filterInstances(liveInstances, 'claude');
  assert.equal(matchByProvider.length, 1);
  assert.equal(matchByProvider[0].agent_instance_id, 'inst_abc123');

  // 4. Non-matching search
  const matchNone = filterInstances(liveInstances, 'non-existent term');
  assert.equal(matchNone.length, 0);
});

test('AgentDetail.tsx wraps chainTitle in VaultText with fallback={chainId}', () => {
  const filePath = path.join(REPO_ROOT, 'src/ui/components/agents/AgentDetail.tsx');
  assert.ok(fs.existsSync(filePath), 'AgentDetail.tsx must exist');

  const content = fs.readFileSync(filePath, 'utf8');

  assert.match(
    content,
    /import\s*\{[^}]*VaultText[^}]*\}\s*from\s*['"]\.\.\/vault\/VaultText['"]/,
    'AgentDetail must import VaultText',
  );

  assert.match(
    content,
    /<VaultText\s+value=\{chainTitle\}\s+fallback=\{chainId\}\s*\/>/,
    'AgentDetail must wrap chainTitle with VaultText and fallback={chainId}',
  );
});

test('AgentDetailPanel.tsx resolves chain name and renders with VaultText', () => {
  const filePath = path.join(REPO_ROOT, 'src/ui/components/agents/AgentDetailPanel.tsx');
  assert.ok(fs.existsSync(filePath), 'AgentDetailPanel.tsx must exist');

  const content = fs.readFileSync(filePath, 'utf8');

  assert.match(
    content,
    /import\s*\{[^}]*useListFlatTaskChainsQuery[^}]*\}\s*from\s*['"]\.\.\/\.\.\/api\/endpoints\/taskChains['"]/,
    'AgentDetailPanel must import useListFlatTaskChainsQuery',
  );
  assert.match(
    content,
    /import\s*\{[^}]*VaultText[^}]*\}\s*from\s*['"]\.\.\/vault\/VaultText['"]/,
    'AgentDetailPanel must import VaultText',
  );
  assert.match(
    content,
    /const\s+chainMap\s*=\s*useMemo\(\(\)\s*=>\s*\{[\s\S]*new\s+Map<string,\s*string>\(\)[\s\S]*map\.set\(id,\s*String\(c\.title\s*\|\|\s*c\.name\s*\|\|\s*id\)\)[\s\S]*return\s+map;[\s\S]*\},\s*\[rawChains\]\)/,
    'AgentDetailPanel must construct chainMap',
  );
  assert.match(
    content,
    /<VaultText\s+value=\{chainName\}\s+fallback=\{chainId\}\s*\/>/,
    'AgentDetailPanel must display resolved chainName using VaultText',
  );
});
