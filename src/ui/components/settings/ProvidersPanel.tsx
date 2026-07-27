import React from 'react';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';

export function ProvidersPanel() {
  const { data, isLoading } = useListBridgesQuery();
  const bridges = data?.bridges || [];

  return (
    <div className="w-full max-w-4xl space-y-6 text-left">
      <div>
        <h2 className="text-xl font-semibold text-white">Providers</h2>
        <p className="mt-1 text-sm text-zinc-400">
          Provider configurations (like API keys) are intentionally kept securely on your local Bridge machines (e.g., inside <code>~/.config/heimdall/config.toml</code>) and are never sent to the Hub. This page displays the read-only capabilities that your Bridges have reported.
        </p>
      </div>

      {isLoading ? (
        <div className="animate-pulse space-y-4">
          <div className="h-24 rounded-xl bg-white/5"></div>
          <div className="h-24 rounded-xl bg-white/5"></div>
        </div>
      ) : bridges.length === 0 ? (
        <div className="rounded-xl border border-dashed border-white/20 p-8 text-center">
          <p className="text-zinc-400">No bridges connected to report capabilities.</p>
        </div>
      ) : (
        <div className="space-y-4">
          {bridges.map((bridge: any) => (
            <div key={bridge.bridge_id} data-debug-id={`providers-bridge-${bridge.bridge_id}`} className="rounded-xl border border-white/10 bg-white/5 p-5">
              <div className="mb-3 flex items-center justify-between border-b border-white/10 pb-3">
                <div className="flex items-center gap-3">
                  <span className={`h-2.5 w-2.5 rounded-full ${bridge.status === 'online' ? 'bg-emerald-400' : 'bg-red-400'}`}></span>
                  <h3 className="font-semibold text-white">{bridge.label || bridge.hostname || 'Unknown Bridge'}</h3>
                </div>
                <span className="text-xs text-zinc-500">ID: {bridge.bridge_id}</span>
              </div>
              <div className="space-y-3">
                <h4 className="text-xs font-semibold uppercase tracking-wider text-zinc-500">Reported Capabilities</h4>
                {bridge.capabilities && Object.keys(bridge.capabilities).length > 0 ? (
                  <div className="grid grid-cols-2 gap-4 sm:grid-cols-3">
                    {Object.entries(bridge.capabilities).map(([key, val]) => (
                      <div key={key} className="rounded-lg bg-black/30 p-3">
                        <div className="text-[10px] uppercase text-zinc-500">{key}</div>
                        <div className="mt-1 text-sm font-medium text-white">{String(val)}</div>
                      </div>
                    ))}
                  </div>
                ) : (
                  <p className="text-sm text-zinc-400">No specific capabilities reported.</p>
                )}
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
