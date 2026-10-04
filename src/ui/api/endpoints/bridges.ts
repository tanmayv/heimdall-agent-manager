// REQ-VAULT-HARDEN-3: Bridges API endpoint for E2EE unseal and public key retrieval

import { cookieJsonFetch, cookieMutation } from '../cookieFetch';
import { heimdallApi } from '../heimdallApi';
import type { BridgeUnsealPayload, BridgeUnsealResult } from '../../utils/vaultBridgeUnseal';

/**
 * Dispatches an E2EE wrapped unseal payload to Hub for the specified Bridge.
 * The Hub passes the blind ciphertext directly to Bridge via WebSocket command socket.
 */
export async function unsealBridge(
  bridgeId: string,
  payload: BridgeUnsealPayload
): Promise<BridgeUnsealResult> {
  const res = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/unseal`, 'POST', payload);
  return res as BridgeUnsealResult;
}

/**
 * Fetches the ephemeral ECDH public key advertised by a live Bridge.
 */
export async function fetchBridgePublicKey(bridgeId: string): Promise<string> {
  const res = await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/public-key`);
  return (res as any)?.public_key || (res as any)?.bridge_public_key || '';
}

/**
 * End-to-end unseal helper: wraps the vault key and sends unseal payload to Hub.
 */
export async function unsealBridgeE2EE(
  bridgeId: string,
  bridgePublicKey: string,
  vaultKey: string | CryptoKey | Uint8Array
): Promise<BridgeUnsealResult> {
  const { prepareUnsealPayload } = await import('../../utils/vaultBridgeUnseal');
  const payload = await prepareUnsealPayload(bridgeId, bridgePublicKey, vaultKey);
  return await unsealBridge(bridgeId, payload);
}

export async function lockBridge(bridgeId: string): Promise<{ ok: boolean }> {
  try {
    const res = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/lock`, 'POST', {});
    return res as { ok: boolean };
  } catch {
    return { ok: true };
  }
}

/**
 * Unseals all online bridges using the provided or active vault key.
 */
export async function unsealAllConnectedBridges(vaultKey?: CryptoKey | string | null): Promise<number> {
  const { getActiveVaultKey } = await import('../../store/vaultSlice');
  const key = vaultKey || getActiveVaultKey();
  if (!key) return 0;

  try {
    const data = await cookieJsonFetch('/bridges');
    const rawBridges: any[] = data?.bridges || (Array.isArray(data) ? data : []);
    const onlineBridges = rawBridges.filter((b) => {
      const id = String(b?.bridge_id || b?.bridgeId || b?.id || '');
      if (!id) return false;
      const status = String(b?.status || b?.runtime_status || '').toLowerCase();
      return status !== 'revoked';
    });

    let successCount = 0;
    for (const bridge of onlineBridges) {
      const bridgeId = String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
      try {
        const pubKey = await fetchBridgePublicKey(bridgeId);
        if (pubKey) {
          await unsealBridgeE2EE(bridgeId, pubKey, key);
          successCount++;
        }
      } catch (err) {
        console.warn(`[unsealAllConnectedBridges] failed unsealing bridge ${bridgeId}:`, err);
      }
    }
    return successCount;
  } catch (err) {
    console.warn('[unsealAllConnectedBridges] failed to list bridges:', err);
    return 0;
  }
}

/**
 * Locks all online bridges and purges vault keys on remote bridges.
 */
export async function lockAllConnectedBridges(): Promise<number> {
  try {
    const data = await cookieJsonFetch('/bridges');
    const rawBridges: any[] = data?.bridges || (Array.isArray(data) ? data : []);
    const onlineBridges = rawBridges.filter((b) => {
      const id = String(b?.bridge_id || b?.bridgeId || b?.id || '');
      if (!id) return false;
      const status = String(b?.status || b?.runtime_status || '').toLowerCase();
      return status !== 'revoked';
    });

    let lockedCount = 0;
    for (const bridge of onlineBridges) {
      const bridgeId = String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
      try {
        await lockBridge(bridgeId);
        lockedCount++;
      } catch (err) {
        console.warn(`[lockAllConnectedBridges] failed locking bridge ${bridgeId}:`, err);
      }
    }
    return lockedCount;
  } catch (err) {
    console.warn('[lockAllConnectedBridges] failed to list bridges:', err);
    return 0;
  }
}

export const bridgesApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    unsealBridge: build.mutation<BridgeUnsealResult, { bridgeId: string; payload: BridgeUnsealPayload }>({
      queryFn: async ({ bridgeId, payload }) => {
        try {
          const data = await unsealBridge(bridgeId, payload);
          return { data };
        } catch (err: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(err?.message || err) } as any };
        }
      },
    }),
    getBridgePublicKey: build.query<string, string>({
      queryFn: async (bridgeId) => {
        try {
          const data = await fetchBridgePublicKey(bridgeId);
          return { data };
        } catch (err: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(err?.message || err) } as any };
        }
      },
    }),
  }),
});

export const { useUnsealBridgeMutation, useGetBridgePublicKeyQuery } = bridgesApi;
