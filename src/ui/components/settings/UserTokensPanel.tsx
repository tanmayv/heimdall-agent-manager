import { useState } from 'react';
import type { FormEvent } from 'react';
import {
  useFetchCurrentUserQuery,
  useIssueCurrentUserTokenMutation,
  useListCurrentUserTokensQuery,
  useRevokeCurrentUserTokenMutation,
} from '../../api/endpoints/userTokens';
import { Button, Input, PageShell, Text } from '@ui';

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
    <PageShell
      title="User tokens"
      description="Create bearer tokens for devices such as the Electron app. Tokens assume your current Heimdall identity and can be revoked individually."
    >
      <div data-debug-id="settings-user-tokens-panel" className="space-y-5 text-left">
      <div className="rounded-2xl border border-subtle bg-surface-raised/30 p-4">
        <Text as="div" role="overline" tone="muted">Current identity</Text>
        <div data-debug-id="settings-user-tokens-current-user" className="mt-2 text-sm text-primary">
          <span className="font-semibold text-primary">{user.display_name || user.displayName || user.name || user.user_id || 'Unknown user'}</span>
          <span className="ml-2 font-mono text-xs text-muted">{user.user_id || user.userId || ''}</span>
        </div>
      </div>

      <form data-debug-id="settings-user-token-create-form" onSubmit={createToken} className="rounded-2xl border border-subtle bg-surface-raised/40 p-5">
        <h3 className="text-lg font-semibold text-primary">Create token</h3>
        <p className="mt-1 text-sm text-muted">The token is shown once. Copy it into the Electron app when prompted.</p>
        <div className="mt-4 grid gap-3 md:grid-cols-[minmax(0,1fr)_220px_auto]">
          <label className="text-sm text-muted">Label
            <Input data-debug-id="settings-user-token-label-input" value={label} onChange={setLabel} placeholder="Heimdall Electron" width="full" className="mt-1 min-h-[44px]" />
          </label>
          <label className="text-sm text-muted">Expires at (optional)
            <Input data-debug-id="settings-user-token-expires-input" value={expiresAt} onChange={setExpiresAt} placeholder="2026-12-31T23:59:59Z" width="full" className="mt-1 min-h-[44px]" />
          </label>
          <Button variant="primary" data-debug-id="settings-user-token-create-btn" type="submit" disabled={issueState.isLoading} className="self-end">{issueState.isLoading ? 'Creating…' : 'Create'}</Button>
        </div>
        {error ? <div data-debug-id="settings-user-token-error" className="mt-3 rounded-xl border border-danger/30 bg-danger-soft px-3 py-2 text-xs text-danger">{error}</div> : null}
      </form>

      {revealedToken ? (
        <div data-debug-id="settings-user-token-reveal" className="rounded-2xl border border-success/30 bg-success-soft p-5">
          <div className="flex items-center justify-between gap-3">
            <div><h3 className="font-semibold text-success">Copy this token now</h3><p className="mt-1 text-xs text-success/80">It will not be shown again after you leave this panel.</p></div>
            <Button variant="primary" size="sm" data-debug-id="settings-user-token-copy-btn" onClick={copyRevealedToken}>Copy</Button>
          </div>
          <div data-debug-id="settings-user-token-plaintext" className="mt-3 break-all rounded-xl border border-subtle bg-surface-raised/40 p-3 font-mono text-xs text-success">{revealedToken}</div>
        </div>
      ) : null}

      <div className="rounded-2xl border border-subtle bg-surface-raised/40 p-5">
        <div className="flex items-center justify-between gap-3">
          <h3 className="text-lg font-semibold text-primary">Existing tokens</h3>
          <Button variant="secondary" size="sm" data-debug-id="settings-user-token-refresh-btn" onClick={() => tokensQuery.refetch()}>Refresh</Button>
        </div>
        {tokensQuery.isFetching ? <div data-debug-id="settings-user-token-loading" className="mt-4 text-sm text-muted">Loading tokens…</div> : null}
        {!tokensQuery.isFetching && tokens.length === 0 ? <div data-debug-id="settings-user-token-empty" className="mt-4 rounded-xl border border-dashed border-subtle p-6 text-center text-sm text-muted">No tokens yet.</div> : null}
        <div className="mt-4 space-y-2">
          {tokens.map((token: any) => {
            const id = tokenRowId(token);
            const revoked = Boolean(tokenField(token, 'revoked_at', 'revokedAt')) || tokenField(token, 'status', 'status') === 'revoked';
            return (
              <div key={id} data-debug-id={`settings-user-token-row-${id}`} className="flex flex-col gap-3 rounded-xl border border-subtle bg-surface-raised/30 p-3 md:flex-row md:items-center md:justify-between">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-medium text-primary">{tokenField(token, 'label', 'label') || 'Untitled token'}</span>
                    <span className={`rounded-full px-2 py-0.5 text-[10px] font-semibold ${revoked ? 'bg-neutral-soft text-muted' : 'bg-success-soft text-success'}`}>{revoked ? 'revoked' : 'active'}</span>
                    <span className="font-mono text-caption text-muted">{id}</span>
                  </div>
                  <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-caption text-muted">
                    <span>created {tokenDate(tokenField(token, 'created_at', 'createdAt'))}</span>
                    <span>last used {tokenDate(tokenField(token, 'last_used_at', 'lastUsedAt'))}</span>
                    <span>expires {tokenDate(tokenField(token, 'expires_at', 'expiresAt'))}</span>
                    <span>source {tokenField(token, 'created_from', 'createdFrom') || 'operator'}</span>
                  </div>
                </div>
                <Button variant="danger" size="sm" data-debug-id={`settings-user-token-revoke-btn-${id}`} disabled={revoked || revokeState.isLoading} onClick={() => void revoke(id)}>Revoke</Button>
              </div>
            );
          })}
        </div>
      </div>
      </div>
    </PageShell>
  );
}
