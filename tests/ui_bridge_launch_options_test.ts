import assert from 'node:assert/strict';

// Pure option-derivation for the launch/add-agent dropdowns. No DOM/RTK.
const {
  bridgeIdOf,
  bridgeIsOnline,
  bridgeLabel,
  launchProvidersFor,
  launchModelsFor,
  launchableBridgeRows,
  capSupports,
  MODEL_ORDER,
} = await import('../src/ui/utils/bridgeLaunchOptions');

// A bridge as returned by useListBridgesQuery: capabilities carry providers+models.
const onlineBridge = {
  bridge_id: 'brg_1',
  label: 'Mac Studio',
  status: 'online',
  capabilities: {
    providers: [
      { provider: 'anthropic', models: ['cheap', 'smart'], default_model: 'smart' },
      { provider: 'openai', models: ['normal'] },
    ],
  },
};
const offlineBridge = { bridge_id: 'brg_off', status: 'offline', capabilities: { providers: [{ provider: 'anthropic', models: ['normal'] }] } };
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

// --- models per bridge+provider ---
// anthropic advertises cheap+smart (+default smart) => canonical order first.
assert.deepEqual(launchModelsFor(onlineBridge, 'anthropic'), ['cheap', 'smart']);
// openai advertises only 'normal'.
assert.deepEqual(launchModelsFor(onlineBridge, 'openai'), ['normal']);
// No provider requested => falls back to the bridge default capability (anthropic, has default_model).
assert.deepEqual(launchModelsFor(onlineBridge, ''), ['cheap', 'smart']);

// --- capSupports ---
assert.equal(capSupports(onlineBridge, 'anthropic', 'smart'), true);
assert.equal(capSupports(onlineBridge, 'anthropic', 'normal'), false, 'anthropic does not advertise normal');
assert.equal(capSupports(onlineBridge, 'openai', 'normal'), true);
assert.equal(capSupports(onlineBridge, '', 'smart'), false, 'no provider => unsupported');
assert.equal(capSupports(onlineBridge, 'anthropic', ''), false, 'no model => unsupported');

// --- launchable rows: only online bridges advertising >=1 provider ---
const rows = launchableBridgeRows([onlineBridge, offlineBridge, onlineNoCaps]);
assert.equal(rows.length, 1, 'only the online-with-caps bridge is launchable');
assert.equal(rows[0].bridgeId, 'brg_1');

// --- empty/malformed inputs are safe ---
assert.deepEqual(launchableBridgeRows([]), []);
assert.deepEqual(launchableBridgeRows(undefined as any), []);
assert.deepEqual(launchProvidersFor({}), []);
assert.deepEqual(launchModelsFor({}, 'anthropic'), []);
assert.ok(Array.isArray(MODEL_ORDER) && MODEL_ORDER.includes('normal'));

console.log('ui_bridge_launch_options_test: ok');
