import React, { useState } from 'react';
import { useListAgentIdentitiesQuery, useCreateAgentMutation, useEnableBridgeSupportMutation } from '../../api/endpoints/agents';

export function AgentsPanel() {
  const { data, isLoading, refetch } = useListAgentIdentitiesQuery();
  const [createAgent, { isLoading: isCreating }] = useCreateAgentMutation();
  const [enableBridgeSupport, { isLoading: isEnabling }] = useEnableBridgeSupportMutation();
  const [showForm, setShowForm] = useState(false);

  const agents = data?.agents || [];

  const [formState, setFormState] = useState({
    name: '',
    slug: '',
    instructions: '',
    defaultProvider: 'claude',
    defaultTier: 'smart',
  });
  const [errorMsg, setErrorMsg] = useState('');

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setErrorMsg('');
    const res = await createAgent(formState);
    if (res.error) {
      setErrorMsg((res.error as any).error || 'Failed to create agent');
    } else {
      setShowForm(false);
      setFormState({ name: '', slug: '', instructions: '', defaultProvider: 'claude', defaultTier: 'smart' });
      refetch();
    }
  };

  return (
    <div className="w-full max-w-4xl space-y-6 text-left">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-xl font-semibold text-white">Agents</h2>
          <p className="mt-1 text-sm text-zinc-400">Manage your autonomous agents and templates.</p>
        </div>
        <button
          data-debug-id="agents-add-agent-btn"
          onClick={() => setShowForm(!showForm)}
          className="rounded-lg bg-white/10 px-4 py-2 text-sm font-semibold text-white hover:bg-white/20"
        >
          {showForm ? 'Cancel' : 'Add Agent'}
        </button>
      </div>

      {showForm && (
        <form onSubmit={handleSubmit} className="rounded-xl border border-white/10 bg-white/5 p-6">
          <h3 className="mb-4 text-lg font-medium text-white">Create New Agent</h3>
          <div className="space-y-4">
            <div>
              <label className="block text-xs font-medium text-zinc-400">Name</label>
              <input
                data-debug-id="agents-create-name-input"
                required
                type="text"
                className="mt-1 block w-full rounded-md border border-white/10 bg-black/50 px-3 py-2 text-white placeholder-zinc-500 focus:border-sky-500 focus:outline-none focus:ring-1 focus:ring-sky-500 sm:text-sm"
                placeholder="e.g. Code Reviewer"
                value={formState.name}
                onChange={(e) => setFormState({ ...formState, name: e.target.value })}
              />
            </div>
            <div>
              <label className="block text-xs font-medium text-zinc-400">Slug (optional)</label>
              <input
                data-debug-id="agents-create-slug-input"
                type="text"
                className="mt-1 block w-full rounded-md border border-white/10 bg-black/50 px-3 py-2 text-white placeholder-zinc-500 focus:border-sky-500 focus:outline-none focus:ring-1 focus:ring-sky-500 sm:text-sm"
                placeholder="e.g. code-reviewer"
                value={formState.slug}
                onChange={(e) => setFormState({ ...formState, slug: e.target.value })}
              />
            </div>
            <div>
              <label className="block text-xs font-medium text-zinc-400">Instructions (optional)</label>
              <textarea
                data-debug-id="agents-create-instructions-input"
                className="mt-1 block w-full rounded-md border border-white/10 bg-black/50 px-3 py-2 text-white placeholder-zinc-500 focus:border-sky-500 focus:outline-none focus:ring-1 focus:ring-sky-500 sm:text-sm"
                placeholder="You are a helpful assistant..."
                rows={3}
                value={formState.instructions}
                onChange={(e) => setFormState({ ...formState, instructions: e.target.value })}
              />
            </div>
            {errorMsg && (
              <div className="rounded border border-red-500/50 bg-red-500/10 p-3 text-sm text-red-400">
                {errorMsg}
              </div>
            )}
            <div className="flex justify-end pt-2">
              <button
                data-debug-id="agents-create-submit-btn"
                type="submit"
                disabled={isCreating}
                className="rounded-lg bg-sky-500 px-4 py-2 text-sm font-semibold text-white hover:bg-sky-400 disabled:opacity-50"
              >
                {isCreating ? 'Creating...' : 'Create Agent'}
              </button>
            </div>
          </div>
        </form>
      )}

      {isLoading ? (
        <div className="animate-pulse space-y-4">
          <div className="h-20 rounded-xl bg-white/5"></div>
          <div className="h-20 rounded-xl bg-white/5"></div>
        </div>
      ) : agents.length === 0 ? (
        <div className="rounded-xl border border-dashed border-white/20 p-8 text-center">
          <p className="text-zinc-400">No agents found.</p>
        </div>
      ) : (
        <div className="space-y-3">
          {agents.map((agent: any) => (
            <div key={agent.agent_id} className="flex items-start justify-between rounded-xl border border-white/10 bg-white/5 p-4 transition-colors hover:bg-white/10">
              <div>
                <h3 className="font-semibold text-white">{agent.name}</h3>
                <p className="mt-1 text-xs text-zinc-500">ID: {agent.agent_id} • Provider: {agent.default_provider || 'unknown'}</p>
                {agent.instructions && (
                  <p className="mt-2 text-sm text-zinc-300 line-clamp-2">{agent.instructions}</p>
                )}
                {agent.supported_bridge_count === 0 && (
                  <button
                    data-debug-id={`agents-enable-bridge-btn-${agent.agent_id}`}
                    type="button"
                    disabled={isEnabling}
                    onClick={() => enableBridgeSupport({ agentId: agent.agent_id })}
                    className="mt-3 rounded-lg bg-amber-500/20 px-3 py-1 text-xs font-semibold text-amber-300 hover:bg-amber-500/30 disabled:opacity-50"
                  >
                    {isEnabling ? 'Enabling...' : 'Enable all bridges'}
                  </button>
                )}
              </div>
              <div className="flex shrink-0 items-center gap-2">
                <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${agent.state === 'active' ? 'bg-emerald-400/10 text-emerald-400' : 'bg-zinc-400/10 text-zinc-400'}`}>
                  {agent.state || 'active'}
                </span>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
