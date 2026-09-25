import { apiUrl, cookieMutation } from '../cookieFetch';
import { heimdallApi } from '../heimdallApi';

export interface UserVaultRecord {
  user_id?: string;
  userId?: string;
  encrypted_vault_key: string;
  encryptedVaultKey?: string;
  vault_key_nonce: string;
  vaultKeyNonce?: string;
  vault_key_tag: string;
  vaultKeyTag?: string;
  kdf_algorithm: string;
  kdfAlgorithm?: string;
  kdf_salt: string;
  kdfSalt?: string;
  kdf_iterations: number;
  kdfIterations?: number;
  recovery_encrypted_vault_key: string;
  recoveryEncryptedVaultKey?: string;
  recovery_nonce: string;
  recoveryNonce?: string;
  recovery_tag: string;
  recoveryTag?: string;
  recovery_salt: string;
  recoverySalt?: string;
  created_at?: string;
  createdAt?: string;
  updated_at?: string;
  updatedAt?: string;
}

export interface UserVaultResponse {
  isConfigured: boolean;
  vault: UserVaultRecord | null;
}

export interface SetUserVaultPayload {
  encrypted_vault_key: string;
  vault_key_nonce: string;
  vault_key_tag: string;
  kdf_algorithm?: string;
  kdf_salt: string;
  kdf_iterations?: number;
  recovery_encrypted_vault_key: string;
  recovery_nonce: string;
  recovery_tag: string;
  recovery_salt: string;
}

export const userVaultApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    getUserVault: build.query<UserVaultResponse, void>({
      queryFn: async () => {
        try {
          const url = apiUrl('/user/vault');
          const res = await fetch(url, { credentials: 'include' });
          if (res.status === 404) {
            return { data: { isConfigured: false, vault: null } };
          }
          if (!res.ok) {
            let msg = `Request failed (${res.status})`;
            try {
              const text = await res.text();
              const errBody = JSON.parse(text);
              if (errBody?.error?.message) msg = errBody.error.message;
              else if (errBody?.message) msg = errBody.message;
            } catch {}
            throw new Error(msg);
          }
          const rawText = await res.text();
          if (!rawText.trim()) {
            return { data: { isConfigured: false, vault: null } };
          }
          const body = JSON.parse(rawText);
          const envelope = body?.data !== undefined ? body.data : body;
          if (!envelope || envelope.configured === false || envelope.isConfigured === false) {
            return { data: { isConfigured: false, vault: null } };
          }
          const vaultData = envelope.vault !== undefined ? envelope.vault : envelope;
          return {
            data: {
              isConfigured: true,
              vault: vaultData,
            },
          };
        } catch (error: any) {
          return {
            error: {
              status: 'CUSTOM_ERROR',
              error: String(error?.message || error || 'Request failed'),
            } as any,
          };
        }
      },
      providesTags: [{ type: 'UserVault' as const, id: 'CURRENT' }],
    }),
    setUserVault: build.mutation<{ ok: boolean; vault?: UserVaultRecord }, SetUserVaultPayload>({
      queryFn: async (payload) => {
        try {
          const data = await cookieMutation('/user/vault', 'POST', payload);
          return { data: { ok: true, vault: data?.vault || data } };
        } catch (error: any) {
          return {
            error: {
              status: 'CUSTOM_ERROR',
              error: String(error?.message || error || 'Request failed'),
            } as any,
          };
        }
      },
      invalidatesTags: [{ type: 'UserVault' as const, id: 'CURRENT' }],
    }),
  }),
});

export const {
  useGetUserVaultQuery,
  useLazyGetUserVaultQuery,
  useSetUserVaultMutation,
} = userVaultApi;
