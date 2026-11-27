import fs from 'node:fs';
import path from 'node:path';
import { nativeMcpHub, check, eventually } from '../../helpers/nativeMcpAcceptance.ts';

const scopes = [
  'mcp:chains', 'mcp:tasks:read', 'mcp:tasks:write', 'mcp:agents:read',
  'mcp:agents:write', 'mcp:instances:read', 'mcp:instances:control',
  'mcp:projects:read', 'mcp:projects:write',
].join(' ');

// Only provider behavior is stubbed. A native agent launch and task claim
// supply the real local socket, instance assertion, profile and placement.
export async function startSecureFormRuntime(control) {
  const bin = path.join(control, 'bin');
  fs.mkdirSync(bin);
  const ctl = process.env.HEIMDALL_E2E_CTL_BIN;
  if (!ctl || !path.isAbsolute(ctl)) throw new Error('Set HEIMDALL_E2E_CTL_BIN to the absolute native CLI path');
  const provider = path.join(bin, 'pi');
  fs.writeFileSync(provider, `#!/usr/bin/env bash
set -eu
for arg do
  if [[ "$arg" == --version ]]; then echo 0.99.0; exit; fi
  if [[ "$arg" == --mode ]]; then rpc=1; fi
done
if [[ ${'${rpc:-0}'} == 1 ]]; then
  while IFS= read -r line; do
    if [[ "$line" == *get_available_models* ]]; then
      echo '{"id":"models","command":"get_available_models","success":true,"data":{"models":[{"provider":"fixture","id":"local","name":"Fixture"}]}}'
      exit
    fi
  done
  exit
fi
control=${JSON.stringify(control)}
ctl=${JSON.stringify(ctl)}
"$ctl" agent start-success >"$control/agent-start.log" 2>&1
for ((i=0; i<240; i++)); do
  "$ctl" lease next >"$control/lease.log" 2>&1 || :
  if grep -Eq '"status":"(current|granted)"' "$control/lease.log"; then break; fi
  sleep .25
done
printf '%s\\n%s\\n%s\\n' "$HEIMDALL_BROWSER_PROFILE_DIR" "$HEIMDALL_BROWSER_CDP_PORT" "$HEIMDALL_AGENT_INSTANCE_ID" >"$control/placement.tmp"
mv "$control/placement.tmp" "$control/placement"
for ((i=1;; i++)); do
  while [[ ! -f "$control/command-$i" ]]; do sleep .05; done
  mapfile -t args <"$control/command-$i"
  status=0
  "$ctl" secure-form "${'${args[@]}'}" >"$control/output-$i" 2>&1 || status=$?
  printf '%s\\n' "$status" >"$control/status.tmp"
  mv "$control/status.tmp" "$control/status-$i"
done
`, { mode: 0o700 });
  process.env.PATH = bin + path.delimiter + process.env.PATH;
  const h = await nativeMcpHub();
  try {
    const { bridgeId } = await h.enroll();
    const bridge = `/api/v1/bridges/${bridgeId}`;
    check((await h.signed('POST', bridge + '/providers/discover', { providers: ['pi'], stage: 'providers' })).status === 200, 'fixture provider discovery');
    check((await h.signed('PUT', bridge + '/providers/pi', { enabled: true })).status === 200, 'fixture provider enabled');
    const auth = await h.grant(scopes);
    const tool = (name, args) => h.tool(auth, name, args);
    const eligible = await eventually(async () => {
      const result = await tool('providers.list', { bridge_id: bridgeId });
      return result.records.find(row => row.provider === 'pi' && row.eligible);
    }, 'eligible local fixture provider');
    const model = eligible.models.find(row => row.eligible)?.model_id;
    check(model, 'fixture model advertised');
    const work = path.join(control, 'project');
    fs.mkdirSync(work);
    const project = await tool('projects.create', { request_id: 'project', name: 'Secure form fixture', default_path: work });
    const { agent_id: agent } = await tool('agents.create', {
      request_id: 'agent', name: 'Fixture worker', instructions: 'Run the isolated secure form fixture.',
      supports: [{ bridge_id: bridgeId, enabled: true, max_instances: 1 }],
    });
    const placement = { bridge_id: bridgeId, provider: 'pi', provider_profile: eligible.provider_profile, model };
    const { chain_id: chain, coordinator_agent_instance_id: instance } = await tool('chains.create', {
      title: 'Secure form fixture', coordinator_agent_id: agent, project_id: project.resource_id, ...placement,
    });
    const detail = await tool('chains.get', { chain_id: chain });
    await tool('chains.configure', { chain_id: chain, request_id: 'fleet', expected_revision: detail.chain.configuration_revision, action: 'fleet', agent_id: agent, ...placement, capacity: 1 });
    const { task_id: task } = await tool('tasks.create', {
      chain_id: chain, request_id: 'task', title: 'Synthetic sign-in', goal: 'Sign in to the isolated fixture.',
      acceptance: ['One synthetic form.'], assignee_agent_id: agent, bridge_id: bridgeId, requires_user_approval: false,
    });
    const configured = await tool('chains.get', { chain_id: chain });
    await tool('chains.configure', { chain_id: chain, action: 'publish', request_id: 'publish', expected_revision: configured.chain.configuration_revision });
    const [profile, port, activeInstance] = await eventually(async () => {
      const name = path.join(control, 'placement');
      return fs.existsSync(name) ? fs.readFileSync(name, 'utf8').split('\n') : undefined;
    }, 'fixture agent claimed the task', 65000);
    check(instance === activeInstance, 'real task placement matches coordinator instance');
    check(profile && port, 'bridge browser profile and debug port supplied');
    return { h, bridgeId, task, instance, profile, port };
  } catch (error) {
    await h.close();
    fs.rmSync(h.root, { recursive: true, force: true });
    throw error;
  }
}
