/** Shared runtime selection for instance and conversation creation.
 * Keep an omitted project distinct from an explicitly empty project on the wire.
 */
export interface RuntimeSelection {
  bridgeId?: string;
  provider?: string;
  providerProfile?: string;
  model?: string;
  projectId?: string;
  chainId?: string;
}

export interface RuntimePayload {
  bridge_id?: string;
  provider?: string;
  provider_profile?: string;
  model?: string;
  project_id?: string;
  chain_id?: string;
}

export interface CreateAgentInstanceArgs extends RuntimeSelection {
  agentId: string;
  displayName?: string;
}

export function buildRuntimePayload(selection: RuntimeSelection): RuntimePayload {
  return {
    ...(selection.bridgeId !== undefined ? { bridge_id: selection.bridgeId } : {}),
    ...(selection.provider !== undefined ? { provider: selection.provider } : {}),
    ...(selection.providerProfile !== undefined ? { provider_profile: selection.providerProfile } : {}),
    ...(selection.model !== undefined ? { model: selection.model } : {}),
    ...(selection.projectId !== undefined ? { project_id: selection.projectId } : {}),
    ...(selection.chainId !== undefined ? { chain_id: selection.chainId } : {}),
  };
}
