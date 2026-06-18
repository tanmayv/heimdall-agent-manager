const DEFAULT_TIMEOUT_MS = 5000;

type RequestOptions = {
  method?: string;
  body?: unknown;
  timeoutMs?: number;
};

type SessionRequest = {
  daemonUrl: string;
  userId: string;
  clientInstanceId: string;
  clientToken: string;
};

type AgentRequest = {
  daemonUrl: string;
  clientInstanceId: string;
  clientToken: string;
  agentInstanceId: string;
};

async function requestJson(url: string, { method = 'GET', body, timeoutMs = DEFAULT_TIMEOUT_MS }: RequestOptions = {}): Promise<any> {
  if (window.odinApi?.request) {
    return window.odinApi.request({ url, method, body });
  }

  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {
      method,
      headers: { 'Content-Type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
      signal: controller.signal,
    });
    const data = await response.json().catch(() => null);
    if (!response.ok) {
      throw new Error(data?.message || `Daemon request failed with ${response.status}`);
    }
    return data;
  } finally {
    window.clearTimeout(timeout);
  }
}

function joinUrl(baseUrl: string, path: string) {
  return `${baseUrl.replace(/\/$/, '')}${path}`;
}

export async function registerUserClient({ daemonUrl, userId, clientInstanceId, clientToken }: SessionRequest) {
  return requestJson(joinUrl(daemonUrl, '/user-client/register'), {
    method: 'POST',
    body: {
      user_id: userId,
      client_instance_id: clientInstanceId,
      client_token: clientToken || '',
    },
  });
}

export async function listConnectedAgents({ daemonUrl }: { daemonUrl: string }) {
  const data = await requestJson(joinUrl(daemonUrl, '/clients'));
  return (data.agents ?? data.clients ?? []).filter((agent) => agent.connected);
}

export async function fetchChat({ daemonUrl, clientInstanceId, clientToken, agentInstanceId }: AgentRequest) {
  return requestJson(joinUrl(daemonUrl, '/user-rpc'), {
    method: 'POST',
    body: {
      action: 'fetch_chat',
      client_instance_id: clientInstanceId,
      client_token: clientToken,
      agent_instance_id: agentInstanceId,
    },
  });
}

export async function sendToAgent({ daemonUrl, clientInstanceId, clientToken, agentInstanceId, body }: AgentRequest & { body: string }) {
  return requestJson(joinUrl(daemonUrl, '/user-rpc'), {
    method: 'POST',
    body: {
      action: 'send_to_agent',
      client_instance_id: clientInstanceId,
      client_token: clientToken,
      agent_instance_id: agentInstanceId,
      body,
    },
  });
}
