export type DiscoveryState = 'idle' | 'running' | 'complete' | 'failed';
export type DetectionState = 'absent' | 'present';
export type AuthState = 'ready' | 'needs_auth' | 'unknown';
export type ProviderTestRunState = 'detecting' | 'awaiting_validation' | 'stopping' | 'stopped' | 'failed';

export interface ProviderModelStatus {
  model_id: string;
  label: string;
  description: string;
  catalog_state: 'active' | 'deprecated';
}

export interface BridgeProviderStatus {
  provider: 'claude' | 'codex' | 'copilot' | 'antigravity';
  display_name: string;
  icon_url: string;
  catalog_state: 'active' | 'deprecated';
  enabled: boolean;
  detection: {
    state: DetectionState;
    binary_path: string;
    version_text: string;
    checked_at: string | null;
  };
  authentication: {
    state: AuthState;
    message: string;
  };
  models: ProviderModelStatus[];
}

export interface ProviderSetupResponse {
  data: {
    bridge: {
      bridge_id: string;
      label: string;
      machine_hostname: string;
      status: 'online' | 'offline';
    };
    discovery: {
      run_id: string | null;
      state: DiscoveryState;
      requested_at: string | null;
      completed_at: string | null;
    };
    providers: BridgeProviderStatus[];
  };
  meta: {
    request_id: string;
    server_time: string;
  };
}

export interface ProviderSelectionResponse {
  data: {
    bridge_id: string;
    provider: string;
    enabled: boolean;
  };
  meta: ProviderSetupResponse['meta'];
}

export interface ProviderTestRunResponse {
  data: {
    run_id: string;
    agent_instance_id: string;
    shell_session_id: string;
    bridge_id: string;
    provider: string;
    model_id: string;
    state: ProviderTestRunState;
    ephemeral: true;
    start_success_at: string | null;
    stopped_at: string | null;
    diagnostic_code: string | null;
    diagnostic_message: string | null;
    started_at: string;
  };
  meta: ProviderSetupResponse['meta'];
}

function logoData(label: string, background: string, foreground = '#ffffff'): string {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><rect width="64" height="64" rx="15" fill="${background}"/><text x="32" y="39" text-anchor="middle" font-family="system-ui,sans-serif" font-size="25" font-weight="700" fill="${foreground}">${label}</text></svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

const NOW = '2026-10-09T09:00:00Z';

export const MOCK_PROVIDER_SETUP_RESPONSE: ProviderSetupResponse = {
  data: {
    bridge: {
      bridge_id: 'brg_mock_dawnstar',
      label: 'dawnstar',
      machine_hostname: 'dawnstar',
      status: 'online',
    },
    discovery: {
      run_id: 'pdr_mock_01',
      state: 'complete',
      requested_at: '2026-10-09T08:59:57Z',
      completed_at: NOW,
    },
    providers: [
      {
        provider: 'claude',
        display_name: 'Claude Code',
        icon_url: logoData('C', '#d97757'),
        catalog_state: 'active',
        enabled: true,
        detection: { state: 'present', binary_path: '/home/tanmay/.local/bin/claude', version_text: '2.1.4', checked_at: NOW },
        authentication: { state: 'ready', message: 'Signed in and ready' },
        models: [
          { model_id: 'claude-opus-5', label: 'Opus 5', description: 'Deep reasoning and complex implementation', catalog_state: 'active' },
          { model_id: 'claude-sonnet-5', label: 'Sonnet 5', description: 'Fast, capable everyday model', catalog_state: 'active' },
        ],
      },
      {
        provider: 'codex',
        display_name: 'Codex',
        icon_url: logoData('◎', '#111827'),
        catalog_state: 'active',
        enabled: false,
        detection: { state: 'present', binary_path: '/home/tanmay/.local/bin/codex', version_text: '0.9.1', checked_at: NOW },
        authentication: { state: 'needs_auth', message: 'Sign in before testing models' },
        models: [
          { model_id: 'gpt-5.4', label: 'GPT-5.4', description: 'General coding and agent work', catalog_state: 'active' },
          { model_id: 'gpt-5.4-mini', label: 'GPT-5.4 mini', description: 'Lower latency for routine work', catalog_state: 'active' },
        ],
      },
      {
        provider: 'copilot',
        display_name: 'GitHub Copilot',
        icon_url: logoData('GH', '#6e40c9'),
        catalog_state: 'active',
        enabled: false,
        detection: { state: 'absent', binary_path: '', version_text: '', checked_at: NOW },
        authentication: { state: 'unknown', message: 'CLI not detected' },
        models: [
          { model_id: 'copilot-auto', label: 'Auto', description: 'Let Copilot select the model', catalog_state: 'active' },
        ],
      },
      {
        provider: 'antigravity',
        display_name: 'Antigravity',
        icon_url: logoData('A', '#2563eb'),
        catalog_state: 'active',
        enabled: false,
        detection: { state: 'present', binary_path: '/usr/local/bin/agy', version_text: '1.2.0', checked_at: NOW },
        authentication: { state: 'ready', message: 'Ready to test' },
        models: [
          { model_id: 'gemini-3.5-pro', label: 'Gemini 3.5 Pro', description: 'High-capability agent model', catalog_state: 'active' },
          { model_id: 'gemini-3.5-flash', label: 'Gemini 3.5 Flash', description: 'Fast interactive work', catalog_state: 'active' },
        ],
      },
    ],
  },
  meta: { request_id: 'req_mock_provider_setup', server_time: NOW },
};

const wait = (milliseconds: number) => new Promise((resolve) => globalThis.setTimeout(resolve, milliseconds));

export function cloneProviderSetupResponse(response = MOCK_PROVIDER_SETUP_RESPONSE): ProviderSetupResponse {
  return structuredClone(response);
}

export const providerSetupMockApi = {
  async get(bridgeId?: string): Promise<ProviderSetupResponse> {
    await wait(220);
    const response = cloneProviderSetupResponse();
    if (bridgeId) response.data.bridge.bridge_id = bridgeId;
    return response;
  },

  async discover(current: ProviderSetupResponse): Promise<ProviderSetupResponse> {
    await wait(850);
    const response = cloneProviderSetupResponse(current);
    response.data.discovery = {
      run_id: `pdr_mock_${Date.now()}`,
      state: 'complete',
      requested_at: new Date(Date.now() - 850).toISOString(),
      completed_at: new Date().toISOString(),
    };
    response.meta = { request_id: `req_mock_${Date.now()}`, server_time: new Date().toISOString() };
    return response;
  },

  async saveSelection(current: ProviderSetupResponse, providerName: string, enabled: boolean): Promise<{ response: ProviderSetupResponse; mutation: ProviderSelectionResponse }> {
    await wait(180);
    const response = cloneProviderSetupResponse(current);
    const provider = response.data.providers.find((item) => item.provider === providerName);
    if (!provider || provider.detection.state !== 'present') throw new Error('Provider is not available on this bridge.');
    provider.enabled = enabled;
    const meta = { request_id: `req_mock_${Date.now()}`, server_time: new Date().toISOString() };
    response.meta = meta;
    return { response, mutation: { data: { bridge_id: response.data.bridge.bridge_id, provider: providerName, enabled }, meta } };
  },

  async authenticate(current: ProviderSetupResponse, providerName: string): Promise<ProviderSetupResponse> {
    await wait(750);
    const response = cloneProviderSetupResponse(current);
    const provider = response.data.providers.find((item) => item.provider === providerName);
    if (provider) provider.authentication = { state: 'ready', message: 'Signed in and ready' };
    return response;
  },

  async startTestRun(current: ProviderSetupResponse, providerName: string, modelId: string): Promise<ProviderTestRunResponse> {
    await wait(280);
    const provider = current.data.providers.find((item) => item.provider === providerName);
    const model = provider?.models.find((item) => item.model_id === modelId);
    if (!provider || !model) throw new Error('Unknown provider or model.');
    if (provider.authentication.state !== 'ready') throw new Error('Provider authentication is required.');
    const meta = { request_id: `req_mock_${Date.now()}`, server_time: new Date().toISOString() };
    const suffix = Date.now();
    return {
      data: {
        run_id: `ptr_mock_${suffix}`,
        agent_instance_id: `probe_${providerName}_${suffix}`,
        shell_session_id: `shl_mock_${suffix}`,
        bridge_id: current.data.bridge.bridge_id,
        provider: providerName,
        model_id: modelId,
        state: 'detecting',
        ephemeral: true,
        start_success_at: null,
        stopped_at: null,
        diagnostic_code: null,
        diagnostic_message: null,
        started_at: new Date().toISOString(),
      },
      meta,
    };
  },

  async reportStartSuccess(current: ProviderTestRunResponse): Promise<ProviderTestRunResponse> {
    await wait(120);
    const response = structuredClone(current);
    response.data.state = 'awaiting_validation';
    response.data.start_success_at = new Date().toISOString();
    response.meta = { request_id: `req_mock_${Date.now()}`, server_time: new Date().toISOString() };
    return response;
  },

  async validateAndStopTestRun(current: ProviderTestRunResponse): Promise<ProviderTestRunResponse> {
    await wait(500);
    const response = structuredClone(current);
    response.data.state = 'stopped';
    response.data.stopped_at = new Date().toISOString();
    response.meta = { request_id: `req_mock_${Date.now()}`, server_time: new Date().toISOString() };
    return response;
  },
};
