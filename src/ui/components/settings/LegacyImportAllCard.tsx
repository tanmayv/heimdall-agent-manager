import { useEffect, useState } from 'react';
import { Button, Spinner, StatusPill, Text } from '@ui';
import { cookieJsonFetch, cookieMutation } from '../../api/cookieFetch';
import type { OwnerSession } from '../../api/ownerLocalClient';
import { describeMigrationBlockers, prepareMigrationRequest } from '../../api/ownerMigrationClient';
import { importAllLegacyChains, type ImportAllProgress, type ImportAllResult } from '../../api/ownerImportAll';
import { getKeyringSession, subscribeKeyringSession } from '../../utils/vaultKeyringSession';
import { decryptVaultText, isVaultArmored } from '../../utils/vaultContent';
import { pinsFromChain, verifyDirectory } from '../../utils/vaultDirectoryVerify';

/** The current vault session re-verified against the live device directory. */
async function currentSession(): Promise<OwnerSession> {
  const s = getKeyringSession();
  if (!s) throw new Error('Unlock the vault first');
  const chain = await verifyDirectory(await cookieJsonFetch('/api/v1/vault/directory'), s.identity.userId, pinsFromChain(s.chain));
  if (getKeyringSession() !== s || chain.currentEpoch !== s.keyring.currentEpoch) throw new Error('Vault session changed; refresh it first');
  return { ...s, chain };
}

function isTrustedOwnerBridge(bridgeId: string): boolean {
  const s = getKeyringSession();
  if (!s || !bridgeId) return false;
  return [...s.chain.trusted.values()].some((d) => d.kind === 'bridge' && d.row.bridge_id === bridgeId);
}

function ResultRow({ result }: { result: ImportAllResult }) {
  const tone = result.outcome === 'imported' ? 'success' : result.outcome === 'failed' ? 'danger' : result.outcome === 'pending' ? 'warning' : 'neutral';
  const label = result.outcome === 'imported' ? '✓ Imported' : result.outcome === 'skipped' ? 'Skipped' : result.outcome === 'pending' ? 'Pending' : 'Failed';
  const neutralized = describeMigrationBlockers(result.neutralized);
  return (
    <li data-debug-id={`settings-bridge-import-all-result-${result.chainId}`} className="flex flex-col gap-0.5 py-1.5 text-xs">
      <span className="flex flex-wrap items-center gap-2">
        <StatusPill tone={tone}>{label}</StatusPill>
        <span className="text-primary">{result.title}</span>
        {result.message ? <span className="text-muted">{result.outcome === 'failed' ? `failed: ${result.message}` : result.message.toLowerCase() === 'already imported' ? 'already imported' : result.message}</span> : null}
      </span>
      {result.forcedHeld.length > 0 ? (
        <span className="text-warning" title={result.forcedHeld.join(', ')}>
          {result.forcedHeld.length} {result.forcedHeld.length === 1 ? 'task' : 'tasks'} force-held
        </span>
      ) : null}
      {neutralized.length > 0 ? <span className="text-muted">{neutralized.join('; ')}</span> : null}
    </li>
  );
}

/**
 * Settings → Bridges: one click imports every legacy Hub chain that is not
 * imported yet into this Bridge. Needs an unlocked vault and a Bridge enrolled
 * in it (a trusted owner Bridge).
 */
export default function LegacyImportAllCard({ bridgeId }: { bridgeId: string }) {
  const [sessionTick, setSessionTick] = useState(0);
  const [running, setRunning] = useState(false);
  const [progress, setProgress] = useState<ImportAllProgress | null>(null);
  const [error, setError] = useState('');
  useEffect(() => subscribeKeyringSession(() => setSessionTick((n) => n + 1)), []);
  void sessionTick;
  const unlocked = Boolean(getKeyringSession());
  const trusted = isTrustedOwnerBridge(bridgeId);

  async function run() {
    setRunning(true); setError(''); setProgress(null);
    try {
      const session = await currentSession();
      const before = getKeyringSession();
      await importAllLegacyChains(bridgeId, {
        fetchJson: (path) => cookieJsonFetch(path),
        post: (path, body) => cookieMutation(path, 'POST', body),
        prepare: (chainId, owner, revision) => prepareMigrationRequest(session, chainId, owner, revision),
        decryptTitle: async (title) => (title && isVaultArmored(title) ? decryptVaultText(title, session.keyring) : title),
        onProgress: setProgress,
        isCurrent: () => getKeyringSession() === before,
      });
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setRunning(false);
    }
  }

  const results = progress?.results ?? [];
  const counts = {
    imported: results.filter((r) => r.outcome === 'imported').length,
    skipped: results.filter((r) => r.outcome === 'skipped').length,
    failed: results.filter((r) => r.outcome === 'failed').length,
  };
  return (
    <section data-debug-id={`settings-bridge-import-all-${bridgeId}`} className="space-y-3 border-t border-subtle pt-4" aria-label="Import legacy chains">
      <Text as="h2" role="heading">Legacy chains</Text>
      <Text role="body-sm" tone="muted">
        Moves every legacy Hub chain not imported yet into this Bridge. Busy chains are imported as they are: in-progress tasks are held, live leases are ended, and running workflows and pending merges are cancelled.
      </Text>
      <div className="flex flex-wrap items-center gap-3">
        <Button
          size="sm"
          data-debug-id={`settings-bridge-import-all-btn-${bridgeId}`}
          disabled={running || !unlocked || !trusted}
          onClick={() => void run()}
        >
          Import all legacy chains
        </Button>
        {running ? (
          <span className="inline-flex items-center gap-2 text-xs text-muted" data-debug-id={`settings-bridge-import-all-progress-${bridgeId}`}>
            <Spinner size="sm" />
            {progress && progress.total > 0 ? `Importing ${progress.index} of ${progress.total}…` : 'Listing legacy chains…'}
          </span>
        ) : null}
        {!running && progress?.done ? (
          <span className="text-xs text-muted" data-debug-id={`settings-bridge-import-all-summary-${bridgeId}`}>
            {progress.total === 0 ? 'No legacy chains found.' : `${counts.imported} imported, ${counts.skipped} skipped, ${counts.failed} failed.`}
          </span>
        ) : null}
      </div>
      {!unlocked ? <Text role="body-sm" tone="muted">Unlock the vault to import chains.</Text> : null}
      {unlocked && !trusted ? <Text role="body-sm" tone="muted">This Bridge is not enrolled in your vault, so it cannot own chains.</Text> : null}
      {error ? <p role="alert" className="text-xs text-danger">{error}</p> : null}
      {results.length > 0 ? (
        <ul data-debug-id={`settings-bridge-import-all-results-${bridgeId}`} className="flex flex-col divide-y divide-subtle">
          {results.map((r) => <ResultRow key={r.chainId} result={r} />)}
        </ul>
      ) : null}
    </section>
  );
}
