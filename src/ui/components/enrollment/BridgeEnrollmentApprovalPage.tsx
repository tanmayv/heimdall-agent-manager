// REQ-IMPL-5 — the bridge-enrollment approval screen (REQ-ENROLL-5/6/14).
//
// Reached at `#/enroll/approve?user_code=...&bpk=...&cb=...&state=...`, from the
// link the BRIDGE prints on the machine being enrolled.
//
// ── Why this screen lives in the SPA and not in the standalone device page ──
//
// The Hub also serves a self-contained approval page at `GET /api/v1/device`
// (src/hub/service/device_auth/page.odin), which the Electron device flow uses
// and which is left exactly as it was. It cannot host THIS screen, because the
// vault key is in-memory module state inside the SPA (`getActiveVaultKey`), and
// a separate document on the same origin shares cookies and storage but no JS
// module memory. The alternative — reimplementing vault key derivation inside an
// inline-JS page with no build step and no test coverage — would put the most
// security-sensitive code in the system into a second, untested copy. So the
// enrollment ceremony happens here, where the vault key, the vault crypto and an
// authenticated session already are.
//
// ── The three things this screen must get right ─────────────────────────────
//
// 1. PROVENANCE (REQ-ENROLL-14). The verify payload nests fields under
//    `hub_observed` (measured by the Hub) and `host_asserted` (claimed by the
//    machine asking to be let in). Those two halves are rendered as visibly
//    different things, and the distinction is carried by HEADING TEXT and
//    per-row marks, not by colour alone — a colour-blind or high-contrast
//    operator must not lose it at the moment it matters.
//
// 2. THE FRAGMENT KEY (REQ-ENROLL-5). The bridge public key is read from the URL
//    fragment, which the bridge itself wrote and which never leaves the browser.
//    It is cross-checked against the Hub's stored copy, and the vault key is
//    encrypted to the FRAGMENT key — never to the Hub's. `iss_18dc4591d95eb89f`
//    is exactly the defect of taking the Hub's copy on trust.
//
// 3. NO AUTO-APPROVE (Part A item 4). Following the link verifies and displays;
//    it never decides. The fragment can only ever REMOVE the approve option (on
//    a key mismatch), never supply it.
//
// ── Residual risk — stated, not papered over ────────────────────────────────
//
// This defeats a SUBSTITUTING Hub. It does NOT defeat a COMPROMISED UI ORIGIN:
// the Hub serves the JavaScript doing the encryption, so a Hub serving malicious
// code can simply lie about the comparison it claims to have made. No in-browser
// design escapes that. The guarantee is narrow and real: a Hub that merely
// relays ciphertext cannot swap the key without the operator's own browser
// noticing.
//
// Separately, the bridge's ECDH keypair is ephemeral per process
// (`bridge_unseal_init`), so it legitimately changes on every bridge restart.
// The fragment therefore exists only during enrollment, and the steady-state
// unlock path has no fragment to read and no key that could be pinned.

import React, { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { Button, Input, Icon, Select } from '@ui';

import { cookieJsonFetch, cookieMutation } from '../../api/cookieFetch';
import { unsealBridgeE2EE } from '../../api/endpoints/bridges';
import { useGetUserVaultQuery } from '../../api/endpoints/userVault';
import {
  getActiveVaultKey,
  getActiveBridgeVaultKeyMaterial,
  selectIsVaultUnlocked,
  setActiveBridgeVaultKeyMaterial,
  setVaultUnlocked,
} from '../../store/vaultSlice';
import {
  deriveKeyFromPassword,
  decryptVaultKeyEnvelope,
  decryptVaultKeyEnvelopeHex,
  DEFAULT_KDF_ITERATIONS,
} from '../../utils/vaultCrypto';
import { canUnsealWithKey } from '../../utils/vaultBridgeUnseal';
import { getRouteSearch } from '../../utils/appLocation';
import {
  approvedBridgeIsOnline,
  BRIDGE_HOME_REDIRECT_DELAY_MS,
  navigateEnrollmentHome,
  nextAvailableBridgeLabel,
} from './bridgeEnrollmentCompletion';
import {
  parseApprovalFragment,
  evaluateKeyCheck,
  sanitizeForDisplay,
  DISPLAY_MAX_CHARS,
  type ApprovalFragment,
  type KeyCheckResult,
} from '../../utils/deviceApprovalSafety';

// ---------------------------------------------------------------------------
// Wire shapes
// ---------------------------------------------------------------------------

/** One row of GET /api/v1/bridges, trimmed to what the picker below needs. */
interface BridgeSummary {
  bridge_id?: string;
  label?: string;
  machine_hostname?: string;
  status?: string;
}

interface VerifyPayload {
  client?: string;
  device_label?: string;
  os?: string;
  app_version?: string;
  request_ip?: string;
  requested_at?: number;
  is_bridge_enrollment?: boolean;
  bridge_public_key?: string;
  bridge_key_fingerprint?: string;
  os_user?: string;
  hub_observed?: {
    bridge_key_fingerprint?: string;
    bridge_public_key_on_record?: string;
    fingerprint_algorithm?: string;
    request_ip?: string;
    /** The Hub's own clock reading, unix seconds. NEVER the browser's. */
    server_time?: number;
  };
  host_asserted?: {
    bridge_public_key?: string;
    os_user?: string;
    device_label?: string;
    os?: string;
    app_version?: string;
  };
}


/** Where the post-approval vault delivery has got to. */
type DeliveryState =
  | { phase: 'idle' }
  | { phase: 'not-needed' }
  | { phase: 'need-password' }
  | { phase: 'waiting-for-bridge'; secondsLeft: number }
  | { phase: 'delivering' }
  | { phase: 'delivered' }
  | { phase: 'failed'; message: string }
  | { phase: 'timed-out' };

/**
 * How long to wait for the just-approved bridge to connect before giving up
 * VISIBLY.
 *
 * The bridge only learns it was approved on its next poll, then has to open its
 * WebSocket, so it is not addressable at the instant of approval. A silent skip
 * here would be the worst outcome: the operator would believe the vault key was
 * delivered and find out otherwise the next time the bridge needed it.
 */
const BRIDGE_ONLINE_TIMEOUT_SECONDS = 45;
const BRIDGE_POLL_INTERVAL_MS = 2000;

function unwrap(body: any): any {
  return (body && body.data) || body || {};
}

// ---------------------------------------------------------------------------
// Presentation helpers
// ---------------------------------------------------------------------------

function Banner({
  tone,
  title,
  children,
}: {
  tone: 'danger' | 'warn' | 'ok';
  title: string;
  children: React.ReactNode;
}) {
  const palette = {
    danger: { bg: 'rgba(185,28,28,0.08)', line: '#fca5a5', fg: '#b91c1c' },
    warn: { bg: 'rgba(245,158,11,0.10)', line: '#fcd34d', fg: '#92400e' },
    ok: { bg: 'rgba(16,185,129,0.08)', line: '#86efac', fg: '#065f46' },
  }[tone];
  return (
    <div
      role={tone === 'danger' ? 'alert' : 'status'}
      style={{
        background: palette.bg,
        border: `1px solid ${palette.line}`,
        borderRadius: 8,
        padding: '12px 14px',
        marginBottom: 12,
        color: palette.fg,
        fontSize: '0.88rem',
      }}
    >
      <strong style={{ display: 'block', marginBottom: 4 }}>{title}</strong>
      {children}
    </div>
  );
}

// ---------------------------------------------------------------------------
// The screen
// ---------------------------------------------------------------------------

export default function BridgeEnrollmentApprovalPage() {
  const dispatch = useDispatch();
  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const vaultQuery = useGetUserVaultQuery();
  const vaultEnvelope = vaultQuery.data?.vault;

  // The fragment is captured ONCE, on first render, before anything can
  // navigate. It never reached the Hub — that is the entire reason the bridge
  // puts the key there rather than letting us ask for it.
  const fragmentRef = useRef<ApprovalFragment | null>(null);
  if (fragmentRef.current === null) fragmentRef.current = parseApprovalFragment(getRouteSearch());
  const fragment = fragmentRef.current;

  const userCode = useMemo(() => {
    const params = new URLSearchParams(getRouteSearch().replace(/^\?/, ''));
    return String(params.get('user_code') ?? '').trim();
  }, []);

  const [codeInput, setCodeInput] = useState(userCode);
  const [grant, setGrant] = useState<VerifyPayload | null>(null);
  // The code that actually produced `grant`. The decision is sent for THIS
  // value, never for whatever the editable input happens to hold at click time.
  const [verifiedCode, setVerifiedCode] = useState('');
  const [verifyError, setVerifyError] = useState('');
  const [verifying, setVerifying] = useState(false);
  const [decision, setDecision] = useState<'none' | 'approved' | 'rejected'>('none');
  const [decideError, setDecideError] = useState('');
  const [deciding, setDeciding] = useState(false);
  const [bridgeId, setBridgeId] = useState('');
  const [bridgeConnected, setBridgeConnected] = useState(false);
  const [delivery, setDelivery] = useState<DeliveryState>({ phase: 'idle' });
  const [masterPassword, setMasterPassword] = useState('');
  const [rememberSession, setRememberSession] = useState(true);
  // "Attach to an existing bridge" instead of minting a new one. Empty means
  // the default (unchanged) behaviour: create a new bridge.
  const [bridgeTargets, setBridgeTargets] = useState<BridgeSummary[]>([]);
  const [targetBridgeId, setTargetBridgeId] = useState('');
  const [newBridgeLabel, setNewBridgeLabel] = useState('');

  const doVerify = useCallback(async (code: string) => {
    const trimmed = code.trim();
    if (!trimmed) {
      setVerifyError('Enter the code shown on the machine you are enrolling.');
      return;
    }
    setVerifying(true);
    setVerifyError('');
    try {
      const res = await cookieMutation('/device/verify', 'POST', { user_code: trimmed });
      setGrant(unwrap(res) as VerifyPayload);
      setVerifiedCode(trimmed);
    } catch (err: any) {
      // The Hub answers a generic error for unknown/expired codes on purpose
      // (anti-enumeration), so there is nothing more specific to say here.
      setVerifyError(
        err?.status === 410
          ? 'This code was already used.'
          : 'That code is not valid, or it has expired.',
      );
      setGrant(null);
      setVerifiedCode('');
    } finally {
      setVerifying(false);
    }
  }, []);

  // Following the link SHOWS the request. It never decides.
  useEffect(() => {
    if (userCode) void doVerify(userCode);
  }, [userCode, doVerify]);

  // Offer "attach to an existing bridge" only for a bridge-enrollment grant —
  // a plain user/Electron device grant has no bridge_id to attach to. Fetch
  // runs once the grant verifies; a failure here is non-fatal, the picker
  // just stays empty (new bridge only), same as the plain /api/v1/device
  // page's fallback behaviour.
  useEffect(() => {
    if (grant?.is_bridge_enrollment !== true) {
      setBridgeTargets([]);
      setNewBridgeLabel('');
      return;
    }
    let cancelled = false;
    (async () => {
      try {
        const data = await cookieJsonFetch('/bridges');
        const unwrapped = unwrap(data);
        const list: BridgeSummary[] = Array.isArray(unwrapped)
          ? unwrapped
          : Array.isArray(unwrapped?.bridges)
            ? unwrapped.bridges
            : [];
        if (!cancelled) {
          // A revoked bridge has nothing to attach to; the Hub also refuses
          // this server-side, this is just not offering a dead end in the UI.
          const available = list.filter((b) => b && b.status !== 'revoked');
          setBridgeTargets(available);
          const hostname = sanitizeForDisplay(
            grant.host_asserted?.device_label ?? grant.device_label,
            DISPLAY_MAX_CHARS,
          ).text;
          // Revoked bridges are not valid attachment targets, but their labels
          // still count as existing names for the suggested new identity.
          setNewBridgeLabel(nextAvailableBridgeLabel(hostname, list));
        }
      } catch {
        if (!cancelled) {
          setBridgeTargets([]);
          const hostname = sanitizeForDisplay(
            grant.host_asserted?.device_label ?? grant.device_label,
            DISPLAY_MAX_CHARS,
          ).text;
          setNewBridgeLabel(nextAvailableBridgeLabel(hostname, []));
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [
    grant?.is_bridge_enrollment,
    grant?.host_asserted?.device_label,
    grant?.device_label,
  ]);

  // ── The REQ-ENROLL-5 cross-check ────────────────────────────────────────
  const hubKey = String(
    grant?.hub_observed?.bridge_public_key_on_record || grant?.bridge_public_key || '',
  )
    .trim()
    .toLowerCase();

  // The policy itself lives in `deviceApprovalSafety` so it can be tested
  // without a DOM. `isBridgeGrant` comes from the PERSISTED grant kind the Hub
  // projects onto the wire, never from whether a key happens to be present —
  // see `evaluateKeyCheck`, which explains why that distinction is what keeps
  // the Electron user-token flow working.
  const keyCheck: KeyCheckResult = useMemo(
    () =>
      evaluateKeyCheck({
        isBridgeGrant: !!grant && grant.is_bridge_enrollment === true,
        fragment,
        hubKey,
      }),
    [grant, fragment, hubKey],
  );

  const approvalBlocked = keyCheck.approvalBlocked;

  // Host-provided values remain sanitised even though the page intentionally
  // presents only the two details an operator needs for this decision.
  const asserted = grant?.host_asserted ?? {};
  const label = sanitizeForDisplay(asserted.device_label ?? grant?.device_label, DISPLAY_MAX_CHARS);
  const os = sanitizeForDisplay(asserted.os ?? grant?.os, DISPLAY_MAX_CHARS);
  const flagged = [
    label.suspicious && 'hostname',
    os.suspicious && 'operating system',
  ].filter(Boolean) as string[];

  // ── Vault delivery ──────────────────────────────────────────────────────

  const waitForAuthenticatedBridge = useCallback(async (targetBridgeId: string): Promise<boolean> => {
    const deadline = Date.now() + BRIDGE_ONLINE_TIMEOUT_SECONDS * 1000;
    for (;;) {
      const secondsLeft = Math.max(0, Math.ceil((deadline - Date.now()) / 1000));
      setDelivery({ phase: 'waiting-for-bridge', secondsLeft });

      try {
        const data = await cookieJsonFetch('/bridges');
        const unwrapped = unwrap(data);
        const list = Array.isArray(unwrapped) ? unwrapped : unwrapped?.bridges;
        if (approvedBridgeIsOnline(list, targetBridgeId)) {
          setBridgeConnected(true);
          return true;
        }
      } catch {
        // A transient authenticated-poll failure is not an enrollment failure.
      }

      if (Date.now() >= deadline) {
        setDelivery({ phase: 'timed-out' });
        return false;
      }
      await new Promise((resolve) => setTimeout(resolve, BRIDGE_POLL_INTERVAL_MS));
    }
  }, []);

  /** Encrypts the vault key to the fragment key and relays only ciphertext. */
  const deliverVaultKey = useCallback(
    async (targetBridgeId: string, vaultKeyMaterial: string | CryptoKey) => {
      if (!fragment.bpk) {
        setDelivery({
          phase: 'failed',
          message:
            'No bridge key was supplied by the enrollment link, so the vault key cannot be delivered ' +
            'without trusting the Hub for the key. Unlock this bridge from Settings → Bridges instead.',
        });
        return;
      }

      setDelivery({ phase: 'delivering' });
      try {
        const result = await unsealBridgeE2EE(targetBridgeId, fragment.bpk, vaultKeyMaterial);
        if (result && (result as any).ok === false) {
          throw new Error(String((result as any).error || 'the bridge refused the unseal'));
        }
        setDelivery({ phase: 'delivered' });
      } catch (err: any) {
        setDelivery({ phase: 'failed', message: String(err?.message || err) });
      }
    },
    [fragment.bpk],
  );

  /** Obtains the vault key without ever degrading to a weaker payload. */
  const startDelivery = useCallback(
    async (targetBridgeId: string) => {
      if (!(await waitForAuthenticatedBridge(targetBridgeId))) return;

      if (!vaultQuery.isLoading && !vaultEnvelope) {
        setDelivery({ phase: 'not-needed' });
        return;
      }
      const active = getActiveBridgeVaultKeyMaterial() || getActiveVaultKey();
      if (isUnlocked && active && canUnsealWithKey(active)) {
        await deliverVaultKey(targetBridgeId, active);
        return;
      }
      // A hardened or IndexedDB-restored handle cannot be wrapped, which is the
      // expected case rather than a malfunction. Ask the operator.
      setDelivery({ phase: 'need-password' });
    },
    [isUnlocked, deliverVaultKey, vaultEnvelope, vaultQuery.isLoading, waitForAuthenticatedBridge],
  );

  useEffect(() => {
    const enrollmentFinished =
      decision === 'approved' &&
      bridgeConnected &&
      (delivery.phase === 'delivered' || delivery.phase === 'not-needed');
    if (!enrollmentFinished) return;

    const redirectTimer = window.setTimeout(
      navigateEnrollmentHome,
      BRIDGE_HOME_REDIRECT_DELAY_MS,
    );
    return () => window.clearTimeout(redirectTimer);
  }, [bridgeConnected, decision, delivery.phase]);

  const handlePasswordSubmit = useCallback(
    async (e: FormEvent) => {
      e.preventDefault();
      if (!masterPassword || !vaultEnvelope || !bridgeId) return;
      setDelivery({ phase: 'delivering' });
      try {
        const derived = await deriveKeyFromPassword(
          masterPassword,
          vaultEnvelope.kdf_salt,
          vaultEnvelope.kdf_iterations || DEFAULT_KDF_ITERATIONS,
        );
        // Two shapes from one envelope, as elsewhere: the hex is what the unseal
        // protocol has to transmit and dies with this closure; the handle
        // installed as the active key is imported NON-extractable.
        const unsealHex = await decryptVaultKeyEnvelopeHex(
          derived,
          vaultEnvelope.encrypted_vault_key,
          vaultEnvelope.vault_key_nonce,
          vaultEnvelope.vault_key_tag,
        );
        const handle = await decryptVaultKeyEnvelope(
          derived,
          vaultEnvelope.encrypted_vault_key,
          vaultEnvelope.vault_key_nonce,
          vaultEnvelope.vault_key_tag,
        );
        dispatch(setVaultUnlocked({ key: handle, rememberSession }));
        setActiveBridgeVaultKeyMaterial(unsealHex);
        setMasterPassword('');
        await deliverVaultKey(bridgeId, unsealHex);
      } catch (err: any) {
        setDelivery({
          phase: 'failed',
          message: String(err?.message || 'That password did not unlock the vault.'),
        });
      }
    },
    [masterPassword, vaultEnvelope, bridgeId, rememberSession, dispatch, deliverVaultKey],
  );

  // ── The decision ────────────────────────────────────────────────────────

  const decide = useCallback(
    async (approve: boolean) => {
      // Belt and braces: the button is already disabled, but a code path that
      // could approve past a failed key check must not exist.
      if (approve && keyCheck.approvalBlocked) {
        setDecideError(`Approval is blocked: ${keyCheck.blockedReason}.`);
        return;
      }
      setDeciding(true);
      setDecideError('');
      try {
        // Approve the code that was VERIFIED and displayed, not whatever the
        // input holds now. The field is also locked once a grant is on screen,
        // but a decision must not depend on an editable control agreeing with
        // what the operator was shown.
        const res = await cookieMutation('/device/approve', 'POST', {
          user_code: (verifiedCode || codeInput).trim(),
          approve,
          // Ignored server-side for anything but an approved bridge-enrollment
          // grant, so sending it unconditionally on a deny or a non-bridge
          // grant is harmless.
          target_bridge_id: targetBridgeId || undefined,
          new_bridge_label:
            grant?.is_bridge_enrollment === true && !targetBridgeId
              ? newBridgeLabel.trim()
              : undefined,
        });
        setDecision(approve ? 'approved' : 'rejected');

        const minted = String(unwrap(res)?.hub_observed?.bridge_id || '');
        if (approve && minted) {
          setBridgeId(minted);
          void startDelivery(minted);
        }
      } catch (err: any) {
        setDecideError(
          err?.status === 409
            ? 'This code was already used.'
            : String(err?.message || 'That code is not valid, or it has expired.'),
        );
      } finally {
        setDeciding(false);
      }
    },
    [keyCheck, codeInput, verifiedCode, startDelivery, targetBridgeId, grant?.is_bridge_enrollment, newBridgeLabel],
  );

  // ── Render ──────────────────────────────────────────────────────────────

  const isBridge = grant?.is_bridge_enrollment === true;

  return (
    <div
      data-debug-id="enrollment-approval-page"
      className="mx-auto flex min-h-full w-full max-w-lg items-start px-4 py-4 sm:py-6"
    >
      <section className="w-full rounded-2xl border border-subtle bg-surface p-5 shadow-2xl sm:p-7">
        <div className="mb-6 text-center">
          <div className="mx-auto mb-3 grid h-12 w-12 place-items-center rounded-2xl bg-accent-soft text-accent">
            <Icon name="device" size={22} />
          </div>
          <h1 className="text-xl font-semibold tracking-tight text-primary">
            {isBridge ? 'Approve this bridge?' : 'Approve this device?'}
          </h1>
          <p className="mt-2 text-sm leading-6 text-muted">
            Only continue if you started this request on a device you trust.
          </p>
        </div>

      {!userCode && (
        <div style={{ marginBottom: 16 }}>
          <label htmlFor="user_code" style={{ fontSize: '0.8rem', display: 'block', marginBottom: 4 }}>
            Device code
          </label>
          <Input
            id="user_code"
            data-debug-id="enrollment-device-code-input"
            value={codeInput}
            placeholder="ABCD-2345"
            autoComplete="off"
            disabled={!!grant}
            onChange={(value) => setCodeInput(value)}
          />
          <Button
            data-debug-id="enrollment-device-code-submit-btn"
            variant="primary"
            onClick={() => void doVerify(codeInput)}
            disabled={verifying || !!grant}
          >
            {verifying ? 'Checking…' : 'Continue'}
          </Button>
        </div>
      )}

      {verifyError && <Banner tone="danger" title="That code did not work">{verifyError}</Banner>}

      {grant && (
        <>
          {/* The key cross-check, above the detail: it can invalidate everything below it. */}
          {keyCheck.kind === 'mismatch' && (
            <Banner tone="danger" title="Stop. The key the Hub reports is not the key the machine sent.">
              Your link carries one bridge key and the Hub is reporting a different one. That is what a
              machine-in-the-middle looks like: something between you and the bridge is trying to substitute a
              key it controls so it can read your vault key. Approval is disabled. Reject this request and
              check the Hub before enrolling anything.
            </Banner>
          )}
          {keyCheck.kind === 'no-fragment' && (
            <Banner tone="danger" title="This enrollment link is incomplete. Approval is disabled.">
              {keyCheck.why} Approving from here would enrol the machine but could NOT deliver the vault key,
              so the bridge would stay sealed and you would not find out until it next needed to unseal.
              Re-open the full link the bridge printed on the machine being enrolled, including everything
              after the <code>#</code> — that part never reaches the Hub, which is why it is the copy of the
              key worth checking, and why a link that lost it cannot be approved.
            </Banner>
          )}
          {flagged.length > 0 && (
            <Banner tone="warn" title="This device name may be misleading.">
              The {flagged.join(' and ')} contained unusual or hidden characters. If you did not expect this,
              reject the request.
            </Banner>
          )}

          <dl className="mb-5 overflow-hidden rounded-xl border border-subtle bg-surface-raised/40">
            <div className="grid grid-cols-[7rem_1fr] gap-3 border-b border-subtle px-4 py-3">
              <dt className="text-sm text-muted">Hostname</dt>
              <dd
                data-debug-id="enrollment-device-hostname"
                className="min-w-0 break-words text-right text-sm font-medium text-primary"
              >
                {label.text || 'Unknown'}
              </dd>
            </div>
            <div className="grid grid-cols-[7rem_1fr] gap-3 px-4 py-3">
              <dt className="text-sm text-muted">Operating system</dt>
              <dd
                data-debug-id="enrollment-device-os"
                className="min-w-0 break-words text-right text-sm font-medium text-primary"
              >
                {os.text || 'Unknown'}
              </dd>
            </div>
          </dl>

          {decision === 'none' && isBridge && (
            <div className="mb-4 space-y-3">
              {bridgeTargets.length > 0 && (
                <div>
                  <label htmlFor="target_bridge_id" className="mb-1 block text-xs font-medium text-muted">
                    Bridge identity
                  </label>
                  <Select
                    id="target_bridge_id"
                    data-debug-id="enrollment-bridge-identity-select"
                    value={targetBridgeId}
                    onChange={setTargetBridgeId}
                    disabled={deciding}
                  >
                    <option value="">Create a new bridge</option>
                    {bridgeTargets.map((b) => (
                      <option key={b.bridge_id} value={b.bridge_id}>
                        {(b.label || b.bridge_id || 'bridge') +
                          ' (' +
                          (b.machine_hostname || 'unknown host') +
                          ')'}
                      </option>
                    ))}
                  </Select>
                </div>
              )}
              {!targetBridgeId && (
                <div>
                  <label htmlFor="new_bridge_label" className="mb-1 block text-xs font-medium text-muted">
                    Bridge name
                  </label>
                  <Input
                    id="new_bridge_label"
                    data-debug-id="enrollment-new-bridge-name-input"
                    value={newBridgeLabel}
                    onChange={setNewBridgeLabel}
                    disabled={deciding}
                    maxLength={128}
                  />
                </div>
              )}
              {targetBridgeId && (
                <p className="text-xs leading-5 text-warning">
                  This replaces that bridge's credential and disconnects it, ending any of its
                  running sessions.
                </p>
              )}
            </div>
          )}

          {decision === 'none' ? (
            <div style={{ display: 'flex', gap: 8 }}>
              <Button
                data-debug-id="enrollment-approve-btn"
                variant="primary"
                onClick={() => void decide(true)}
                disabled={
                  deciding ||
                  approvalBlocked ||
                  (isBridge && !targetBridgeId && !newBridgeLabel.trim())
                }
                title={approvalBlocked ? `Disabled: ${keyCheck.blockedReason}.` : undefined}
              >
                {deciding ? 'Working…' : 'Approve'}
              </Button>
              <Button
                data-debug-id="enrollment-reject-btn"
                onClick={() => void decide(false)}
                disabled={deciding}
              >
                Reject
              </Button>
            </div>
          ) : (
            <Banner
              tone={decision === 'approved' ? 'ok' : 'warn'}
              title={decision === 'approved' ? 'Approval accepted.' : 'Rejected.'}
            >
              {decision === 'approved'
                ? 'Waiting for this bridge to authenticate and connect to the Hub.'
                : 'The code no longer works.'}
            </Banner>
          )}

          {decideError && <Banner tone="danger" title="That did not work">{decideError}</Banner>}

          {/* ── Vault delivery status ───────────────────────────────────── */}
          {delivery.phase === 'waiting-for-bridge' && (
            <Banner tone="warn" title="Waiting for the bridge to connect…">
              <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8 }}>
                <Icon name="refresh" size={16} className="animate-spin" />
                Waiting for the approved bridge to authenticate with the Hub. Giving up in{' '}
                {delivery.secondsLeft}s.
              </span>
            </Banner>
          )}
          {delivery.phase === 'delivering' && (
            <Banner tone="warn" title="Delivering the vault key…">
              Encrypting to the key from your link and sending it through the Hub as ciphertext.
            </Banner>
          )}
          {delivery.phase === 'delivered' && (
            <Banner tone="ok" title="Vault key delivered.">
              The bridge is enrolled and unsealed. Taking you home in 3 seconds.
            </Banner>
          )}
          {delivery.phase === 'not-needed' && (
            <Banner tone="ok" title="Enrollment approved.">
              The bridge authenticated successfully. Taking you home in 3 seconds.
            </Banner>
          )}
          {delivery.phase === 'timed-out' && (
            <Banner tone="warn" title="The bridge did not connect in time.">
              The machine was approved, but Heimdall could not confirm that this bridge authenticated and
              connected. Leave this page open and retry enrollment if it does not appear in Settings → Bridges.
            </Banner>
          )}
          {delivery.phase === 'failed' && (
            <Banner tone="danger" title="The vault key was not delivered.">
              {delivery.message} The enrollment itself succeeded; the bridge is approved but still sealed. You
              can unlock it from Settings → Bridges.
            </Banner>
          )}
          {delivery.phase === 'need-password' && (
            <form onSubmit={handlePasswordSubmit} style={{ marginTop: 12 }}>
              <Banner tone="warn" title="Enter your master password to finish.">
                This browser holds the vault key in a form that cannot be wrapped for a bridge, so the key has
                to be derived again here. It is used for this delivery and not stored.
              </Banner>
              <Input
                data-debug-id="enrollment-master-password-input"
                type="password"
                value={masterPassword}
                autoComplete="current-password"
                placeholder="Master password"
                onChange={(value) => setMasterPassword(value)}
              />
              <label
                data-debug-id="enrollment-remember-session-label"
                style={{ display: 'block', fontSize: '0.8rem', margin: '8px 0' }}
              >
                <input
                  data-debug-id="enrollment-remember-session-checkbox"
                  type="checkbox"
                  checked={rememberSession}
                  onChange={(e) => setRememberSession(e.target.checked)}
                />{' '}
                Keep the vault unlocked for this session
              </label>
              <Button
                data-debug-id="enrollment-deliver-vault-key-btn"
                variant="primary"
                type="submit"
                disabled={!masterPassword}
              >
                Deliver vault key
              </Button>
            </form>
          )}

        </>
      )}
      </section>
    </div>
  );
}
