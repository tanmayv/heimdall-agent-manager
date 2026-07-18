import { createSelector } from '@reduxjs/toolkit';
import { heimdallApi } from './heimdallApi';

const selectApiQueries = (state: any) => state?.[heimdallApi.reducerPath]?.queries || {};

export const selectChainViewCacheProjection = createSelector([selectApiQueries], (queries) => {
  const chainsById: Record<string, any> = {};
  const workspaceByChainId: Record<string, any> = {};
  const teamByChainId: Record<string, any> = {};
  const mergePreviewByChainId: Record<string, any> = {};
  const workspaceDiffByChainId: Record<string, Record<string, any>> = {};
  const loadingByChainId: Record<string, boolean> = {};

  Object.values(queries as Record<string, any>).forEach((entry: any) => {
    if (!entry?.endpointName) return;
    switch (entry.endpointName) {
      case 'listChains': {
        for (const chain of entry?.data?.chains || []) {
          if (chain?.chainId) chainsById[chain.chainId] = chain;
        }
        break;
      }
      case 'fetchChain': {
        const chain = entry?.data?.chain;
        if (chain?.chainId) chainsById[chain.chainId] = { ...(chainsById[chain.chainId] || {}), ...chain };
        break;
      }
      case 'fetchWorkspace': {
        const chainId = String(entry?.originalArgs?.chainId || entry?.data?.chainId || '');
        if (chainId && entry?.data?.workspace) workspaceByChainId[chainId] = entry.data.workspace;
        if (chainId && entry?.status === 'pending') loadingByChainId[chainId] = true;
        break;
      }
      case 'fetchTeam': {
        const teamId = String(entry?.originalArgs?.teamId || entry?.data?.teamId || '');
        const team = entry?.data?.team;
        if (teamId && team) {
          const chainId = String(team.chain_id || team.chainId || '');
          if (chainId) teamByChainId[chainId] = team;
          teamByChainId[teamId] = team;
        }
        break;
      }
      case 'previewWorkspaceMerge': {
        const chainId = String(entry?.originalArgs?.chainId || entry?.data?.chainId || '');
        if (chainId && entry?.data?.preview) mergePreviewByChainId[chainId] = entry.data.preview;
        break;
      }
      case 'fetchWorkspaceDiff': {
        const chainId = String(entry?.originalArgs?.chainId || entry?.data?.chainId || '');
        const file = String(entry?.originalArgs?.file || entry?.data?.file || '');
        if (chainId && entry?.data?.diff) {
          if (!workspaceDiffByChainId[chainId]) workspaceDiffByChainId[chainId] = {};
          workspaceDiffByChainId[chainId][file] = entry.data.diff;
        }
        break;
      }
      default:
        break;
    }
  });

  return { chainsById, workspaceByChainId, teamByChainId, mergePreviewByChainId, workspaceDiffByChainId, loadingByChainId };
});

export function selectCachedChainById(state: any, chainId: string) {
  return chainId ? selectChainViewCacheProjection(state).chainsById?.[chainId] || null : null;
}
