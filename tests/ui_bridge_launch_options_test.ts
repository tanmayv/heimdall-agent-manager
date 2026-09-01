import assert from 'node:assert/strict';

// Pure option-derivation for the launch/add-agent dropdowns. No DOM/RTK.
const {
  bridgeIdOf,
  bridgeIsOnline,
  bridgeLabel,
  launchProvidersFor,
  launchTiersFor,
  launchableBridgeRows,
  capSupports,
  TIER_ORDER,
} = await import('../src/ui/utils/bridgeLaunchOptions');

// A bridge as returned by useListBridgesQuery: capabilities carry providers+tiers.
const onlineBridge = {
  bridge_id: 'brg_1',
  label: 'Mac Studio',
  status: 'online',
  capabilities: {
    providers: [
      { provider: 'anthropic', tiers: ['cheap', 'smart'], default_tier: 'smart' },
      { provider: 'openai', tiers: ['normal'] },
    ],
  },
};
const offlineBridge = { bridge_id: 'brg_off', status: 'offline', capabilities: { providers: [{ provider: 'anthropic', tiers: ['normal'] }] } };
const onlineNoCaps = { bridge_id: 'brg_empty', status: 'online', capabilities: { providers: [] } };

// --- identity/label/status helpers ---
assert.equal(bridgeIdOf(onlineBridge), 'brg_1');
assert.equal(bridgeIdOf({ bridgeId: 'x' }), 'x');
assert.equal(bridgeIdOf({ id: 'y' }), 'y');
assert.equal(bridgeIsOnline(onlineBridge), true);
assert.equal(bridgeIsOnline(offlineBridge), false);
assert.equal(bridgeLabel(onlineBridge), 'Mac Studio');
assert.equal(bridgeLabel({ bridge_id: 'brg_z', machine_hostname: 'host-z' }), 'host-z');
assert.equal(bridgeLabel({ bridge_id: 'brg_z' }), 'brg_z');

// --- providers per bridge (sorted, de-duped) ---
assert.deepEqual(launchProvidersFor(onlineBridge), ['anthropic', 'openai']);
assert.deepEqual(launchProvidersFor(onlineNoCaps), []);

// --- tiers per bridge+provider ---
// anthropic advertises cheap+smart (+default smart) => canonical order first.
assert.deepEqual(launchTiersFor(onlineBridge, 'anthropic'), ['cheap', 'smart']);
// openai advertises only 'normal'.
assert.deepEqual(launchTiersFor(onlineBridge, 'openai'), ['normal']);
// No provider requested => falls back to the bridge default capability (anthropic, has default_tier).
assert.deepEqual(launchTiersFor(onlineBridge, ''), ['cheap', 'smart']);

// --- capSupports ---
assert.equal(capSupports(onlineBridge, 'anthropic', 'smart'), true);
assert.equal(capSupports(onlineBridge, 'anthropic', 'normal'), false, 'anthropic does not advertise normal');
assert.equal(capSupports(onlineBridge, 'openai', 'normal'), true);
assert.equal(capSupports(onlineBridge, '', 'smart'), false, 'no provider => unsupported');
assert.equal(capSupports(onlineBridge, 'anthropic', ''), false, 'no tier => unsupported');

// --- launchable rows: only online bridges advertising >=1 provider ---
const rows = launchableBridgeRows([onlineBridge, offlineBridge, onlineNoCaps]);
assert.equal(rows.length, 1, 'only the online-with-caps bridge is launchable');
assert.equal(rows[0].bridgeId, 'brg_1');

// --- empty/malformed inputs are safe ---
assert.deepEqual(launchableBridgeRows([]), []);
assert.deepEqual(launchableBridgeRows(undefined as any), []);
assert.deepEqual(launchProvidersFor({}), []);
assert.deepEqual(launchTiersFor({}, 'anthropic'), []);
assert.ok(Array.isArray(TIER_ORDER) && TIER_ORDER.includes('normal'));

console.log('ui_bridge_launch_options_test: ok');
