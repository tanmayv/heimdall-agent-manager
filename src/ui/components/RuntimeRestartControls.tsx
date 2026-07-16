import { useEffect, useMemo, useState } from 'react';

// Shared per-instance runtime selectors (provider / tier / project) with an
// explicit pending + Restart affordance. Changing a selector NEVER silently
// restarts and NEVER mutates durable identity defaults: it marks the runtime
// settings pending and reveals a Restart button. Clicking Restart calls the
// provided onRestart with the exact selected values so the caller can restart
// the exact agent_instance_id (preserving its inbox/history) with overrides.

export type RuntimeRestartValue = { provider: string; modelTier: string; projectId: string };

type RuntimeRestartControlsProps = {
  debugPrefix: string;
  providers?: any[];
  projects?: any[];
  provider: string;
  modelTier: string;
  projectId: string;
  disabled?: boolean;
  restarting?: boolean;
  showProject?: boolean;
  onRestart: (next: RuntimeRestartValue) => void | Promise<void>;
};

const TIERS = ['smart', 'normal', 'cheap'];

export default function RuntimeRestartControls({
  debugPrefix,
  providers = [],
  projects = [],
  provider,
  modelTier,
  projectId,
  disabled = false,
  restarting = false,
  showProject = true,
  onRestart,
}: RuntimeRestartControlsProps) {
  const [nextProvider, setNextProvider] = useState(provider || '');
  const [nextTier, setNextTier] = useState(modelTier || 'normal');
  const [nextProject, setNextProject] = useState(projectId || '');

  // Re-sync when the applied (agent) values change, e.g. after a restart completes.
  useEffect(() => { setNextProvider(provider || ''); }, [provider]);
  useEffect(() => { setNextTier(modelTier || 'normal'); }, [modelTier]);
  useEffect(() => { setNextProject(projectId || ''); }, [projectId]);

  const providerOptions = providers?.length ? providers : [{ name: provider || 'pi' }];
  const pending = useMemo(() => (
    (nextProvider || '') !== (provider || '')
    || (nextTier || '') !== (modelTier || '')
    || (showProject && (nextProject || '') !== (projectId || ''))
  ), [nextProvider, nextTier, nextProject, provider, modelTier, projectId, showProject]);

  const controlsDisabled = disabled || restarting;

  return (
    <div data-debug-id={`${debugPrefix}-runtime-controls`} className="flex flex-wrap items-center gap-2">
      <select
        data-debug-id={`${debugPrefix}-provider-select`}
        aria-label="Runtime provider"
        value={nextProvider}
        onChange={(event) => setNextProvider(event.target.value)}
        disabled={controlsDisabled}
        className="h-8 rounded-md border border-white/10 bg-[#141414] px-2 text-xs text-zinc-400 outline-none hover:border-white/20 focus:border-sky-400 disabled:cursor-not-allowed disabled:opacity-50"
      >
        {providerOptions.map((item: any) => {
          const name = item.name || item.id || 'pi';
          return <option key={name} value={name}>Provider: {name}</option>;
        })}
        {!providerOptions.some((item: any) => (item.name || item.id) === nextProvider) && nextProvider ? <option value={nextProvider}>Provider: {nextProvider}</option> : null}
      </select>
      <select
        data-debug-id={`${debugPrefix}-tier-select`}
        aria-label="Runtime model tier"
        value={nextTier}
        onChange={(event) => setNextTier(event.target.value)}
        disabled={controlsDisabled}
        className="h-8 rounded-md border border-white/10 bg-[#141414] px-2 text-xs text-zinc-400 outline-none hover:border-white/20 focus:border-sky-400 disabled:cursor-not-allowed disabled:opacity-50"
      >
        {TIERS.map((tier) => <option key={tier} value={tier}>Tier: {tier}</option>)}
      </select>
      {showProject ? (
        <select
          data-debug-id={`${debugPrefix}-project-select`}
          aria-label="Runtime project"
          value={nextProject}
          onChange={(event) => setNextProject(event.target.value)}
          disabled={controlsDisabled}
          className="h-8 rounded-md border border-white/10 bg-[#141414] px-2 text-xs text-zinc-400 outline-none hover:border-white/20 focus:border-sky-400 disabled:cursor-not-allowed disabled:opacity-50"
        >
          <option value="">Project: none</option>
          {(projects || []).map((project: any) => {
            const id = project.projectId || project.project_id || '';
            return <option key={id || 'none'} value={id}>Project: {project.name || id || 'none'}</option>;
          })}
        </select>
      ) : null}
      {pending ? (
        <button
          type="button"
          data-debug-id={`${debugPrefix}-restart-btn`}
          onClick={() => { void onRestart({ provider: nextProvider, modelTier: nextTier, projectId: showProject ? nextProject : projectId }); }}
          disabled={controlsDisabled}
          className="inline-flex h-8 items-center gap-1 rounded-md border border-sky-400/40 bg-sky-400/10 px-2.5 text-xs font-medium text-sky-100 transition hover:bg-sky-400/20 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {restarting ? 'Restarting…' : '↻ Restart to apply'}
        </button>
      ) : (
        <span data-debug-id={`${debugPrefix}-runtime-pending-hint`} className="text-[11px] text-zinc-600">Runtime settings applied</span>
      )}
    </div>
  );
}
