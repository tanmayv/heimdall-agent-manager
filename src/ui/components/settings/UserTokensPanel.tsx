import { useState } from 'react';
import type { FormEvent } from 'react';
import {
  useFetchCurrentUserQuery,
  useIssueCurrentUserTokenMutation,
  useListCurrentUserTokensQuery,
  useRevokeCurrentUserTokenMutation,
} from '../../api/endpoints/userTokens';

function tokenRowId(token: any): string { return String(token?.token_id || token?.tokenId || ''); }
function tokenDate(value: any): string {
  const raw = String(value || '');
  if (!raw) return '—';
  const parsed = Date.parse(raw);
  return Number.isFinite(parsed) ? new Date(parsed).toLocaleString() : raw;
}
function tokenField(token: any, snake: string, camel: string): string { return String(token?.[snake] || token?.[camel] || ''); }

export default function UserTokensPanel() {
  const meQuery = useFetchCurrentUserQuery();
  const tokensQuery = useListCurrentUserTokensQuery();
  const [issueToken, issueState] = useIssueCurrentUserTokenMutation();
  const [revokeToken, revokeState] = useRevokeCurrentUserTokenMutation();
  const [label, setLabel] = useState('Heimdall Electron');
  const [expiresAt, setExpiresAt] = useState('');
  const [revealedToken, setRevealedToken] = useState('');
  const [error, setError] = useState('');
  const user = meQuery.data?.user || {};
  const tokens = tokensQuery.data?.tokens || [];

  async function createToken(event: FormEvent) {
    event.preventDefault();
    setError('');
    try {
      const result = await issueToken({ label, expiresAt }).unwrap();
      const plaintext = String(result?.plaintext || result?.token_plaintext || result?.access_token || '');
      if (!plaintext) throw new Error('Token was created but plaintext was not returned. Create another token.');
      setRevealedToken(plaintext);
      setLabel('Heimdall Electron');
      setExpiresAt('');
      void tokensQuery.refetch();
    } catch (err: any) {
      setError(String(err?.message || err?.error || err || 'Failed to create token'));
    }
  }

  async function revoke(tokenId: string) {
    if (!tokenId) return;
    if (!window.confirm('Revoke this user token? Apps using it will need a replacement token.')) return;
    setError('');
    try {
      await revokeToken({ tokenId }).unwrap();
      void tokensQuery.refetch();
    } catch (err: any) {
      setError(String(err?.message || err?.error || err || 'Failed to revoke token'));
    }
  }

  async function copyRevealedToken() {
    if (!revealedToken) return;
    await navigator.clipboard?.writeText(revealedToken).catch(() => undefined);
  }

  return (
    <div data-debug-id="settings-user-tokens-panel" className="w-full max-w-4xl space-y-5 text-left">
      <div>
        <h2 className="text-xl font-semibold text-white">User tokens</h2>
        <p className="mt-1 text-sm text-zinc-400">Create bearer tokens for devices such as the Electron app. Tokens assume your current Heimdall identity and can be revoked individually.</p>
      </div>

      <div className="rounded-2xl border border-white/10 bg-black/20 p-4">
        <div className="text-xs uppercase tracking-[0.18em] text-zinc-500">Current identity</div>
        <div data-debug-id="settings-user-tokens-current-user" className="mt-2 text-sm text-zinc-200">
          <span className="font-semibold text-white">{user.display_name || user.displayName || user.name || user.user_id || 'Unknown user'}</span>
          <span className="ml-2 font-mono text-xs text-zinc-500">{user.user_id || user.userId || ''}</span>
        </div>
      </div>

      <form data-debug-id="settings-user-token-create-form" onSubmit={createToken} className="rounded-2xl border border-white/10 bg-[#141414] p-5">
        <h3 className="text-lg font-semibold text-white">Create token</h3>
        <p className="mt-1 text-sm text-zinc-500">The token is shown once. Copy it into the Electron app when prompted.</p>
        <div className="mt-4 grid gap-3 md:grid-cols-[minmax(0,1fr)_220px_auto]">
          <label className="text-sm text-zinc-300">Label
            <input data-debug-id="settings-user-token-label-input" value={label} onChange={(event) => setLabel(event.target.value)} placeholder="Heimdall Electron" className="mt-1 min-h-[44px] w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-white outline-none focus:border-sky-400" />
          </label>
          <label className="text-sm text-zinc-300">Expires at (optional)
            <input data-debug-id="settings-user-token-expires-input" value={expiresAt} onChange={(event) => setExpiresAt(event.target.value)} placeholder="2026-12-31T23:59:59Z" className="mt-1 min-h-[44px] w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-white outline-none focus:border-sky-400" />
          </label>
          <button data-debug-id="settings-user-token-create-btn" type="submit" disabled={issueState.isLoading} className="self-end rounded-xl bg-sky-400 px-4 py-2 text-sm font-bold text-black hover:bg-sky-300 disabled:cursor-not-allowed disabled:opacity-50">{issueState.isLoading ? 'Creating…' : 'Create'}</button>
        </div>
        {error ? <div data-debug-id="settings-user-token-error" className="mt-3 rounded-xl border border-red-400/20 bg-red-400/10 px-3 py-2 text-xs text-red-100">{error}</div> : null}
      </form>

      {revealedToken ? (
        <div data-debug-id="settings-user-token-reveal" className="rounded-2xl border border-emerald-400/25 bg-emerald-400/10 p-5">
          <div className="flex items-center justify-between gap-3">
            <div><h3 className="font-semibold text-emerald-100">Copy this token now</h3><p className="mt-1 text-xs text-emerald-100/70">It will not be shown again after you leave this panel.</p></div>
            <button data-debug-id="settings-user-token-copy-btn" type="button" onClick={copyRevealedToken} className="rounded-xl bg-emerald-300 px-3 py-2 text-xs font-bold text-black hover:bg-emerald-200">Copy</button>
          </div>
          <div data-debug-id="settings-user-token-plaintext" className="mt-3 break-all rounded-xl border border-white/10 bg-black/40 p-3 font-mono text-xs text-emerald-50">{revealedToken}</div>
        </div>
      ) : null}

      <div className="rounded-2xl border border-white/10 bg-[#141414] p-5">
        <div className="flex items-center justify-between gap-3">
          <h3 className="text-lg font-semibold text-white">Existing tokens</h3>
          <button data-debug-id="settings-user-token-refresh-btn" type="button" onClick={() => tokensQuery.refetch()} className="rounded-xl border border-white/10 bg-white/5 px-3 py-1.5 text-xs text-zinc-200 hover:bg-white/10">Refresh</button>
        </div>
        {tokensQuery.isFetching ? <div data-debug-id="settings-user-token-loading" className="mt-4 text-sm text-zinc-500">Loading tokens…</div> : null}
        {!tokensQuery.isFetching && tokens.length === 0 ? <div data-debug-id="settings-user-token-empty" className="mt-4 rounded-xl border border-dashed border-white/10 p-6 text-center text-sm text-zinc-500">No tokens yet.</div> : null}
        <div className="mt-4 space-y-2">
          {tokens.map((token: any) => {
            const id = tokenRowId(token);
            const revoked = Boolean(tokenField(token, 'revoked_at', 'revokedAt')) || tokenField(token, 'status', 'status') === 'revoked';
            return (
              <div key={id} data-debug-id={`settings-user-token-row-${id}`} className="flex flex-col gap-3 rounded-xl border border-white/10 bg-black/20 p-3 md:flex-row md:items-center md:justify-between">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-medium text-white">{tokenField(token, 'label', 'label') || 'Untitled token'}</span>
                    <span className={`rounded-full px-2 py-0.5 text-[10px] font-semibold ${revoked ? 'bg-zinc-600/30 text-zinc-400' : 'bg-emerald-400/10 text-emerald-200'}`}>{revoked ? 'revoked' : 'active'}</span>
                    <span className="font-mono text-[11px] text-zinc-500">{id}</span>
                  </div>
                  <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-[11px] text-zinc-500">
                    <span>created {tokenDate(tokenField(token, 'created_at', 'createdAt'))}</span>
                    <span>last used {tokenDate(tokenField(token, 'last_used_at', 'lastUsedAt'))}</span>
                    <span>expires {tokenDate(tokenField(token, 'expires_at', 'expiresAt'))}</span>
                    <span>source {tokenField(token, 'created_from', 'createdFrom') || 'operator'}</span>
                  </div>
                </div>
                <button data-debug-id={`settings-user-token-revoke-btn-${id}`} type="button" disabled={revoked || revokeState.isLoading} onClick={() => void revoke(id)} className="rounded-xl border border-red-400/30 bg-red-400/10 px-3 py-1.5 text-xs font-semibold text-red-100 hover:bg-red-400/20 disabled:cursor-not-allowed disabled:opacity-40">Revoke</button>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
