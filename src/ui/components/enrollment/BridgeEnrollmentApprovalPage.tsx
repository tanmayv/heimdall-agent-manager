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
  selectIsVaultUnlocked,
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
  parseApprovalFragment,
  evaluateKeyCheck,
  hubMeasuredTime,
  requestAgeSeconds,
  formatAge,
  sanitizeForDisplay,
  loopbackCallbackUrl,
  DISPLAY_MAX_CHARS,
  type ApprovalFragment,
  type KeyCheckResult,
  type SanitizedDisplay,
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

/** One row of the provenance tables. Values are rendered as text, never HTML. */
function Row({
  term,
  value,
  info,
  mono,
}: {
  term: string;
  value: string;
  info?: SanitizedDisplay;
  mono?: boolean;
}) {
  const notes: string[] = [];
  if (info?.removedControls) notes.push('hidden direction/invisible characters were removed');
  if (info?.truncated) notes.push('shortened for display');
  if (info?.mixedScript) notes.push(`mixes ${info.scripts.join(' + ')} letters`);

  return (
    <>
      <dt style={{ color: 'var(--text-muted, #6b7280)', fontSize: '0.8rem' }}>{term}</dt>
      <dd
        style={{
          margin: 0,
          fontWeight: 500,
          // Hard display bound: a 4000-character hostname must not be able to
          // push the Approve/Reject buttons off-screen. The string is truncated
          // too; this is the layer that holds regardless.
          overflowWrap: 'anywhere',
          wordBreak: 'break-word',
          maxHeight: '4.5rem',
          overflow: 'hidden',
          fontFamily: mono ? 'ui-monospace, SFMono-Regular, Menlo, monospace' : undefined,
          fontSize: mono ? '0.8rem' : undefined,
        }}
      >
        {value || '—'}
        {notes.length > 0 && (
          <span style={{ display: 'block', fontWeight: 400, fontSize: '0.75rem', color: '#92400e' }}>
            ⚠ {notes.join('; ')}
          </span>
        )}
        {notes.length > 0 && info?.nonAscii && (
          <span style={{ display: 'block', fontWeight: 400, fontSize: '0.75rem', color: '#92400e' }}>
            exactly: {info.escaped}
          </span>
        )}
      </dd>
    </>
  );
}

function ProvenanceGroup({
  heading,
  why,
  tone,
  children,
}: {
  heading: string;
  why: string;
  tone: 'observed' | 'asserted';
  children: React.ReactNode;
}) {
  const palette =
    tone === 'observed'
      ? { bg: 'rgba(16,185,129,0.08)', line: '#86efac', fg: '#065f46' }
      : { bg: 'rgba(245,158,11,0.10)', line: '#fcd34d', fg: '#92400e' };
  return (
    <div
      style={{
        background: palette.bg,
        border: `1px solid ${palette.line}`,
        borderRadius: 8,
        padding: '12px 14px',
        marginBottom: 12,
      }}
    >
      <h3
        style={{
          fontSize: '0.8rem',
          margin: '0 0 2px',
          textTransform: 'uppercase',
          letterSpacing: '0.04em',
          color: palette.fg,
        }}
      >
        {heading}
      </h3>
      <p style={{ margin: '0 0 10px', fontSize: '0.78rem', color: 'var(--text-muted, #6b7280)' }}>{why}</p>
      <dl
        style={{
          margin: 0,
          display: 'grid',
          gridTemplateColumns: 'minmax(7.5rem, auto) 1fr',
          gap: '6px 12px',
        }}
      >
        {children}
      </dl>
    </div>
  );
}

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

function formatTime(epochSeconds: unknown): string {
  const n = Number(epochSeconds);
  if (!Number.isFinite(n) || n <= 0) return '';
  try {
    return new Date(n * 1000).toLocaleString();
  } catch {
    return String(epochSeconds);
  }
}

// ---------------------------------------------------------------------------
// The screen
// ---------------------------------------------------------------------------

export default function BridgeEnrollmentApprovalPage() {
  const dispatch = useDispatch();
  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const vaultEnvelope = useGetUserVaultQuery().data?.vault;

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
  const [delivery, setDelivery] = useState<DeliveryState>({ phase: 'idle' });
  const [masterPassword, setMasterPassword] = useState('');
  const [rememberSession, setRememberSession] = useState(true);
  // "Attach to an existing bridge" instead of minting a new one. Empty means
  // the default (unchanged) behaviour: create a new bridge.
  const [bridgeTargets, setBridgeTargets] = useState<BridgeSummary[]>([]);
  const [targetBridgeId, setTargetBridgeId] = useState('');

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
          setBridgeTargets(list.filter((b) => b && b.status !== 'revoked'));
        }
      } catch {
        if (!cancelled) setBridgeTargets([]);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [grant?.is_bridge_enrollment]);

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

  // ── Hub-measured time ───────────────────────────────────────────────────
  // Read from the wire, never substituted locally. See `hubMeasuredTime` for
  // why a missing value renders as unavailable instead of falling back.
  const serverNow = hubMeasuredTime(grant?.hub_observed?.server_time);
  const requestAge = requestAgeSeconds(grant?.requested_at, grant?.hub_observed?.server_time);

  // ── Host-asserted values, sanitised for display ─────────────────────────
  //
  // Only HOST-ASSERTED values go through `sanitizeForDisplay`. The asymmetry is
  // deliberate: `hub_observed` fields are rendered as-is because the Hub
  // derived them, and a Hub that forges them already serves this page, so
  // sanitising them would buy nothing within the stated threat model. Do not
  // copy that omission to any field a remote machine can set.
  const asserted = grant?.host_asserted ?? {};
  const label = sanitizeForDisplay(asserted.device_label ?? grant?.device_label, DISPLAY_MAX_CHARS);
  const os = sanitizeForDisplay(asserted.os ?? grant?.os, DISPLAY_MAX_CHARS);
  const version = sanitizeForDisplay(asserted.app_version ?? grant?.app_version, 48);
  const osUser = sanitizeForDisplay(asserted.os_user ?? grant?.os_user, 64);
  const client = sanitizeForDisplay(grant?.client, 48);
  const flagged = [
    label.suspicious && 'hostname',
    os.suspicious && 'operating system',
    version.suspicious && 'version',
    osUser.suspicious && 'OS user',
    client.suspicious && 'client',
  ].filter(Boolean) as string[];

  // ── Vault delivery ──────────────────────────────────────────────────────

  /**
   * Waits for the just-approved bridge to come online, then encrypts the vault
   * key TO THE FRAGMENT KEY and dispatches it down the existing `bridge_unseal`
   * relay. The Hub carries ciphertext only.
   *
   * `vaultKeyMaterial` is hex or a `CryptoKey`; it is passed in explicitly and
   * read from nowhere else, and it is never placed in a URL, a query string or
   * any pasted payload.
   */
  const deliverVaultKey = useCallback(
    async (targetBridgeId: string, vaultKeyMaterial: string | CryptoKey) => {
      // Encrypting to the Hub's copy would reintroduce iss_18dc4591d95eb89f, so
      // this path requires an agreed fragment key and has no fallback.
      if (!fragment.bpk) {
        setDelivery({
          phase: 'failed',
          message:
            'No bridge key was supplied by the enrollment link, so the vault key cannot be delivered ' +
            'without trusting the Hub for the key. Unlock this bridge from Settings → Bridges instead.',
        });
        return;
      }

      const deadline = Date.now() + BRIDGE_ONLINE_TIMEOUT_SECONDS * 1000;
      for (;;) {
        const secondsLeft = Math.max(0, Math.ceil((deadline - Date.now()) / 1000));
        setDelivery({ phase: 'waiting-for-bridge', secondsLeft });

        let online = false;
        try {
          const data = await cookieJsonFetch('/bridges');
          const list: any[] = unwrap(data)?.bridges || (Array.isArray(unwrap(data)) ? unwrap(data) : []);
          online = list.some(
            (b) =>
              String(b?.bridge_id || b?.bridgeId || b?.id || '') === targetBridgeId &&
              String(b?.status || '').trim().toLowerCase() === 'online',
          );
        } catch {
          // A failed poll is not a failed enrollment; keep waiting until the
          // deadline, which is visible to the operator the whole time.
          online = false;
        }

        if (online) break;
        if (Date.now() >= deadline) {
          // VISIBLE timeout, never a silent skip: the operator must not believe
          // the vault was delivered when it was not.
          setDelivery({ phase: 'timed-out' });
          return;
        }
        await new Promise((r) => setTimeout(r, BRIDGE_POLL_INTERVAL_MS));
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
      const active = getActiveVaultKey();
      if (isUnlocked && active && canUnsealWithKey(active)) {
        await deliverVaultKey(targetBridgeId, active);
        return;
      }
      // A hardened or IndexedDB-restored handle cannot be wrapped, which is the
      // expected case rather than a malfunction. Ask the operator.
      setDelivery({ phase: 'need-password' });
    },
    [isUnlocked, deliverVaultKey],
  );

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
    [keyCheck, codeInput, verifiedCode, startDelivery, targetBridgeId],
  );

  const callbackUrl =
    decision !== 'none'
      ? loopbackCallbackUrl(fragment.cb, fragment.state, decision === 'approved' ? 'approved' : 'rejected')
      : null;

  // ── Render ──────────────────────────────────────────────────────────────

  const isBridge = grant?.is_bridge_enrollment === true;
  const observed = grant?.hub_observed ?? {};

  return (
    <div style={{ maxWidth: 680, margin: '32px auto', padding: '0 16px', lineHeight: 1.5 }}>
      <h1 style={{ fontSize: '1.25rem', margin: '0 0 4px' }}>
        {isBridge ? 'A machine is asking to enroll as a bridge' : 'Authorize a device'}
      </h1>
      <p style={{ margin: '0 0 20px', color: 'var(--text-muted, #6b7280)', fontSize: '0.9rem' }}>
        Review what is asking for access before you approve it.
      </p>

      {!userCode && (
        <div style={{ marginBottom: 16 }}>
          <label htmlFor="user_code" style={{ fontSize: '0.8rem', display: 'block', marginBottom: 4 }}>
            Device code
          </label>
          <Input
            id="user_code"
            value={codeInput}
            placeholder="ABCD-2345"
            autoComplete="off"
            disabled={!!grant}
            onChange={(value) => setCodeInput(value)}
          />
          <Button
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
          {keyCheck.kind === 'agreed' && (
            <Banner tone="ok" title="The bridge key matches.">
              The key in your link and the key the Hub holds are identical, so the Hub has not substituted a
              key of its own. This does not protect you if this page itself has been tampered with — the Hub
              serves this page.
            </Banner>
          )}

          {flagged.length > 0 && (
            <Banner tone="warn" title="These claimed values are not what they appear to be.">
              The {flagged.join(', ')} contained hidden or mixed-alphabet characters. Characters that reorder
              or hide text have been removed, and the exact contents are shown beneath each affected value. A
              real machine rarely needs any of these. If you did not expect this, reject the request.
            </Banner>
          )}

          <ProvenanceGroup
            tone="observed"
            heading="Verified by Heimdall"
            why="The Hub measured these itself. They do not depend on the requesting machine telling the truth."
          >
            <Row term="Request came from" value={observed.request_ip || grant.request_ip || ''} mono />
            {/*
              Both times below are the HUB's, so the age between them is a
              Hub-to-Hub comparison and operator clock skew cannot shift it.
              When the Hub sends no time, the row says so — it must NEVER fall
              back to `Date.now()`, which is the defect this replaced.
            */}
            <Row
              term="Server time now"
              value={serverNow.available ? formatTime(serverNow.seconds) : 'not reported by the Hub'}
            />
            <Row
              term="Request received"
              value={
                formatTime(grant.requested_at) +
                (requestAge.available ? ` (${formatAge(requestAge)})` : '')
              }
            />
            {isBridge && (
              <>
                <Row
                  term="Key fingerprint"
                  value={observed.bridge_key_fingerprint || grant.bridge_key_fingerprint || ''}
                  mono
                />
                <Row term="Fingerprint method" value={observed.fingerprint_algorithm || ''} />
                {bridgeId && <Row term="Bridge identity" value={bridgeId} mono />}
              </>
            )}
          </ProvenanceGroup>

          <ProvenanceGroup
            tone="asserted"
            heading="Claimed by the machine — not verified"
            why="The machine asking for access supplied these. Anything here can be set to any value by whoever controls it. Treat them as a claim, not as evidence."
          >
            <Row term="Hostname" value={label.text} info={label} />
            <Row term="Operating system" value={os.text} info={os} />
            <Row term={isBridge ? 'Bridge version' : 'App version'} value={version.text} info={version} />
            <Row term="Running as OS user" value={osUser.text} info={osUser} />
            <Row term="Client" value={client.text} info={client} />
            {isBridge && fragment.bpk !== '' && (
              <Row
                term="Public key (from link)"
                value={`${fragment.bpk.slice(0, 16)}…${fragment.bpk.slice(-16)}`}
                mono
              />
            )}
            {isBridge && fragment.cb !== 0 && (
              <Row term="Callback port" value={String(fragment.cb)} mono />
            )}
          </ProvenanceGroup>

          <p
            style={{
              fontSize: '0.85rem',
              color: 'var(--text-muted, #6b7280)',
              borderLeft: '3px solid #fcd34d',
              padding: '2px 0 2px 10px',
              margin: '14px 0',
            }}
          >
            Only approve this if you started it yourself, just now, on a machine you control. Heimdall will
            never ask you to enter a code someone sent you, and no support person will ever ask you to approve
            one. If this appeared without you starting it, choose Reject — the code stops working immediately.
          </p>

          {decision === 'none' && isBridge && bridgeTargets.length > 0 && (
            <div style={{ marginBottom: 12 }}>
              <label
                htmlFor="target_bridge_id"
                style={{ fontSize: '0.8rem', display: 'block', marginBottom: 4 }}
              >
                Bridge identity
              </label>
              <Select
                id="target_bridge_id"
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
              {targetBridgeId && (
                <p style={{ fontSize: '0.85rem', color: '#92400e', margin: '6px 0 0' }}>
                  This replaces that bridge's credential and disconnects it, ending any of its
                  running sessions.
                </p>
              )}
            </div>
          )}

          {decision === 'none' ? (
            <div style={{ display: 'flex', gap: 8 }}>
              <Button
                variant="primary"
                onClick={() => void decide(true)}
                disabled={deciding || approvalBlocked}
                title={approvalBlocked ? `Disabled: ${keyCheck.blockedReason}.` : undefined}
              >
                {deciding ? 'Working…' : 'Approve'}
              </Button>
              <Button onClick={() => void decide(false)} disabled={deciding}>
                Reject
              </Button>
            </div>
          ) : (
            <Banner
              tone={decision === 'approved' ? 'ok' : 'warn'}
              title={decision === 'approved' ? 'Approved.' : 'Rejected.'}
            >
              {decision === 'approved'
                ? 'The machine should connect within a few seconds.'
                : 'The code no longer works.'}
            </Banner>
          )}

          {decideError && <Banner tone="danger" title="That did not work">{decideError}</Banner>}

          {/* ── Vault delivery status ───────────────────────────────────── */}
          {delivery.phase === 'waiting-for-bridge' && (
            <Banner tone="warn" title="Waiting for the bridge to connect…">
              The vault key is delivered to the bridge itself, encrypted so the Hub cannot read it. That needs
              the bridge online, which usually takes a few seconds. Giving up in {delivery.secondsLeft}s.
            </Banner>
          )}
          {delivery.phase === 'delivering' && (
            <Banner tone="warn" title="Delivering the vault key…">
              Encrypting to the key from your link and sending it through the Hub as ciphertext.
            </Banner>
          )}
          {delivery.phase === 'delivered' && (
            <Banner tone="ok" title="Vault key delivered.">
              The bridge is enrolled and unsealed. There is no separate unlock step to do.
            </Banner>
          )}
          {delivery.phase === 'timed-out' && (
            <Banner tone="warn" title="The bridge did not connect in time.">
              The enrollment itself succeeded — the machine is approved and will finish connecting on its own.
              The vault key was <strong>not</strong> delivered, so the bridge is still sealed. Unlock it from
              Settings → Bridges once it shows as online.
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
                type="password"
                value={masterPassword}
                autoComplete="current-password"
                placeholder="Master password"
                onChange={(value) => setMasterPassword(value)}
              />
              <label style={{ display: 'block', fontSize: '0.8rem', margin: '8px 0' }}>
                <input
                  type="checkbox"
                  checked={rememberSession}
                  onChange={(e) => setRememberSession(e.target.checked)}
                />{' '}
                Keep the vault unlocked for this session
              </label>
              <Button variant="primary" type="submit" disabled={!masterPassword}>
                Deliver vault key
              </Button>
            </form>
          )}

          {/* Hand control back to the bridge's loopback listener: state and
              status only. No token, key, code or fingerprint may reach a URL. */}
          {callbackUrl && (
            <p style={{ marginTop: 16 }}>
              <a href={callbackUrl} rel="noreferrer noopener">
                <Icon name="arrow-right" size={14} /> Return to the machine being enrolled
              </a>
            </p>
          )}
        </>
      )}
    </div>
  );
}
