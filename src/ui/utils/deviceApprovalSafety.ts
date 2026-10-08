// REQ-IMPL-5 / REQ-ENROLL-5, REQ-ENROLL-6, REQ-ENROLL-14:
// the untrusted-input handling behind the bridge-enrollment approval screen.
//
// Three jobs, all of them about one thing: the operator is making a trust
// decision from what this screen shows them, so everything the screen shows has
// to be either verifiable or visibly marked as unverifiable.
//
//  1. `sanitizeForDisplay` — host-asserted strings are untrusted input EVEN FOR
//     DISPLAY. React escapes markup, so there is no XSS here; what React cannot
//     stop is display SPOOFING. A hostname carrying U+202E reverses everything
//     after it (Trojan Source), and a Cyrillic U+0430 renders identically to a
//     Latin "a". Neither is caught by escaping, and both defeat exactly the
//     visual check this screen exists to enable.
//
//  2. `parseApprovalFragment` — the bridge public key is read from the URL
//     FRAGMENT, which the bridge itself wrote and which never leaves the
//     browser. It is the one copy of the key a substituting Hub could not have
//     touched. The fragment is a PARAMETER LIST, so `hash.slice(1)` is not the
//     key.
//
//  3. `publicKeysAgree` — the cross-check. A mismatch between the fragment key
//     and the Hub's stored copy is the relay attack in `iss_18dc4591d95eb89f`,
//     and it must fail closed.
//
// These live in their own module rather than inside the component because they
// are where the security properties are, and that is what the tests need to be
// able to reach directly (tests/ui_device_approval_safety_test.ts).

/** Result of sanitising one host-asserted string for display. */
export interface SanitizedDisplay {
  /** The string that is safe to render. */
  text: string;
  /** True when the value was absent or sanitised away to nothing. */
  empty: boolean;
  /** Bidi/invisible/control characters were present and have been removed. */
  removedControls: boolean;
  /** The value was longer than the cap and has been clipped. */
  truncated: boolean;
  /** Which scripts the surviving text draws letters from. */
  scripts: string[];
  /** More than one script is present — the homoglyph signal. */
  mixedScript: boolean;
  /** Any non-printable-ASCII character survives in `text`. */
  nonAscii: boolean;
  /** `text` with every non-ASCII char as an explicit \uXXXX escape. */
  escaped: string;
  /** Worth warning the operator about: something was removed, or scripts are mixed. */
  suspicious: boolean;
}

/** What the approval-link fragment yielded, and what was wrong with it. */
export interface ApprovalFragment {
  /** A fragment was present at all. */
  present: boolean;
  /** The bridge public key: 130 lowercase hex chars, or '' when unusable. */
  bpk: string;
  /** The bridge's loopback callback port, or 0 when absent/invalid. */
  cb: number;
  /** The bridge's correlation nonce, or '' when absent/invalid. */
  state: string;
  /** Machine-readable reasons a field was refused. Empty means nothing was wrong. */
  problems: string[];
}

/**
 * Bidi controls, invisible formatting characters, and C0/C1 controls.
 *
 * U+202A..U+202E and U+2066..U+2069 are the Trojan-Source family: they reorder
 * the characters AFTER them, so a visual check of the rendered string means
 * nothing while they are present. The zero-width and soft-hyphen range lets two
 * different strings render identically. Line/paragraph separators would let one
 * field occupy several lines of the layout.
 */
const DISPLAY_HOSTILE_RE = new RegExp(
  '[' +
    '\\u0000-\\u001F\\u007F-\\u009F' + // C0 and C1 controls (incl. tab/newline)
    '\\u00AD' + //                       soft hyphen (invisible)
    '\\u061C' + //                       Arabic letter mark
    '\\u180E' + //                       Mongolian vowel separator
    '\\u200B-\\u200F' + //               zero-width space .. RLM
    '\\u202A-\\u202E' + //               LRE RLE PDF LRO RLO  <- Trojan Source
    '\\u2028\\u2029' + //                line / paragraph separator
    '\\u2060-\\u2064' + //               word joiner, invisible operators
    '\\u2066-\\u206F' + //               LRI RLI FSI PDI, deprecated formats
    '\\uFEFF' + //                       zero-width no-break space / BOM
    '\\uFFF9-\\uFFFB' + //               interlinear annotation marks
    ']',
  'g',
);

/**
 * Scripts whose letters contain well-known homoglyphs for one another.
 *
 * This is MIXED-SCRIPT detection rather than a confusable lookup table. A table
 * would be large, would need maintaining, and would still miss pairs; whereas
 * "this one short identifier is written in two different alphabets at once" is
 * cheap to check and almost never true of a real hostname.
 */
const SCRIPT_PROBES: ReadonlyArray<readonly [string, RegExp]> = [
  ['Latin', /[A-Za-zÀ-ɏḀ-ỿ]/],
  ['Cyrillic', /[Ѐ-ԯⷠ-ⷿꙀ-ꚟ]/],
  ['Greek', /[Ͱ-Ͽἀ-῿]/],
  ['Armenian', /[԰-֏]/],
  ['Hebrew', /[֐-׿]/],
  ['Arabic', /[؀-ۿݐ-ݿ]/],
  ['Han', /[㐀-䶿一-鿿]/],
  ['Kana', /[぀-ヿ]/],
  ['Hangul', /[ᄀ-ᇿ가-힯]/],
  ['Thai', /[฀-๿]/],
];

/** Display cap for a host-asserted string, in code points. */
export const DISPLAY_MAX_CHARS = 96;

/**
 * The bridge emits 32 bytes of entropy as unpadded base64url, so a real `state`
 * is 43 characters from that alphabet (`bridge_enroll_random_token` /
 * `BRIDGE_ENROLL_SECRET_BYTES` in src/bridge/enroll_device_flow.odin).
 *
 * The floor is 22 characters — about 128 bits — rather than the exact 43, so a
 * future change to that constant cannot silently break the callback, while a
 * nonce too short to be a nonce is still refused.
 */
const STATE_RE = /^[A-Za-z0-9_-]{22,128}$/;

/** 65-byte uncompressed P-256 point as 130 lowercase hex chars. */
const BPK_RE = /^04[0-9a-f]{128}$/;

/** The lowest port a user-space bridge could have bound a loopback listener on. */
const MIN_CALLBACK_PORT = 1024;
const MAX_CALLBACK_PORT = 65535;

/**
 * Renders a string with every non-ASCII character as an explicit `\uXXXX`
 * escape, so a value flagged as suspicious can also be shown in a form that
 * cannot itself spoof anything. This is what the operator actually compares.
 */
export function escapeNonAscii(s: unknown): string {
  let out = '';
  for (const ch of String(s ?? '')) {
    const cp = ch.codePointAt(0)!;
    if (cp >= 0x20 && cp <= 0x7e) {
      out += ch;
      continue;
    }
    out += '\\u' + cp.toString(16).toUpperCase().padStart(4, '0');
  }
  return out;
}

function scriptsIn(s: string): string[] {
  const found: string[] = [];
  for (const [name, probe] of SCRIPT_PROBES) {
    if (probe.test(s)) found.push(name);
  }
  return found;
}

/**
 * The single sanitiser for every host-asserted string that reaches the screen.
 *
 * Order matters: hostile characters are removed BEFORE normalising, so nothing
 * can be reintroduced by composition, and truncation happens last so the
 * reported length is the length actually displayed.
 *
 * Removal is REPORTED rather than silent. Quietly turning
 * `evil<U+202E>moc.elpmaxe` into `evilmoc.elpmaxe` would trade one misleading
 * display for another; the caller is expected to render the flags.
 */
export function sanitizeForDisplay(raw: unknown, maxChars: number = DISPLAY_MAX_CHARS): SanitizedDisplay {
  const limit = Number.isFinite(maxChars) && maxChars > 0 ? Math.floor(maxChars) : DISPLAY_MAX_CHARS;
  const input = raw === null || raw === undefined ? '' : String(raw);

  const stripped = input.replace(DISPLAY_HOSTILE_RE, '');
  const removedControls = stripped.length !== input.length;

  let normalized = stripped;
  try {
    normalized = stripped.normalize('NFC');
  } catch {
    normalized = stripped;
  }
  // Normalisation cannot introduce a bidi control, but it is cheaper to be sure
  // than to argue about it.
  normalized = normalized.replace(DISPLAY_HOSTILE_RE, '');

  // Code points, not UTF-16 units: slicing by `.length` would cut an astral
  // character in half and render a replacement glyph.
  const chars = Array.from(normalized);
  const truncated = chars.length > limit;
  const text = truncated ? chars.slice(0, limit).join('') + '…' : normalized;

  const scripts = scriptsIn(text);
  return {
    text,
    empty: text.length === 0,
    removedControls,
    truncated,
    scripts,
    mixedScript: scripts.length > 1,
    nonAscii: /[^\x20-\x7E]/.test(text),
    escaped: escapeNonAscii(text),
    // Being non-ASCII is NOT itself suspicious. Flagging every accented
    // hostname would train the operator to click through the warning, which is
    // worse than not warning at all.
    suspicious: removedControls || scripts.length > 1,
  };
}

/**
 * Parses the approval-link fragment emitted by the bridge:
 *
 *     #bpk=<130 hex chars>&cb=<port>&state=<nonce>
 *
 * It is a parameter list, so `hash.slice(1)` is NOT the key — using it that way
 * fails the length check in a manner that looks like the bridge emitted
 * something malformed rather than like a parsing mistake here.
 *
 * Every field is validated before it is returned, and a field that fails
 * validation is reported as a problem rather than returned in a degraded form:
 * there is no sensible fallback for "the key might be this", and in particular
 * never the Hub's copy — taking that is the defect being fixed.
 */
export function parseApprovalFragment(hash: unknown): ApprovalFragment {
  const out: ApprovalFragment = { present: false, bpk: '', cb: 0, state: '', problems: [] };
  if (hash === null || hash === undefined) return out;

  let raw = String(hash);
  // Accepts either a raw fragment (`#bpk=...`) or the SPA router's hash-search
  // (`?bpk=...`). Both are the fragment: the app is hash-routed, so its
  // "search" string lives after the `#` and never reaches the Hub either. The
  // caller should not have to care which shape it is holding.
  if (raw.startsWith('#') || raw.startsWith('?')) raw = raw.slice(1);
  if (raw === '') return out;
  out.present = true;

  // A bare hex fragment is what someone produces by hand, or from an older
  // draft of the design. Naming it specifically makes the failure
  // self-explaining instead of arriving as an unhelpful "key missing".
  if (!raw.includes('=')) {
    out.problems.push(/^04[0-9a-fA-F]{128}$/.test(raw) ? 'fragment_bare_value' : 'fragment_unparsable');
    return out;
  }

  let params: URLSearchParams;
  try {
    params = new URLSearchParams(raw);
  } catch {
    out.problems.push('fragment_unparsable');
    return out;
  }

  const bpk = String(params.get('bpk') ?? '').trim().toLowerCase();
  if (bpk === '') out.problems.push('bpk_missing');
  else if (!BPK_RE.test(bpk)) out.problems.push('bpk_malformed');
  else out.bpk = bpk;

  // `cb` is attacker-controllable. It is only ever used as the PORT of a
  // hardcoded 127.0.0.1 URL, never as a host, and it must look like a port a
  // user-space bridge could actually have bound.
  const cbRaw = String(params.get('cb') ?? '').trim();
  if (cbRaw !== '') {
    if (!/^[0-9]{1,5}$/.test(cbRaw)) {
      out.problems.push('cb_malformed');
    } else {
      const port = Number.parseInt(cbRaw, 10);
      if (port < MIN_CALLBACK_PORT || port > MAX_CALLBACK_PORT) out.problems.push('cb_out_of_range');
      else out.cb = port;
    }
  }

  const state = String(params.get('state') ?? '').trim();
  if (state !== '') {
    if (!STATE_RE.test(state)) out.problems.push('state_malformed');
    else out.state = state;
  }

  // `cb` without `state` is a callback we could not correlate — which is
  // precisely the shape an attacker would supply. The headless path sends
  // NEITHER, and that is fine.
  if (out.cb !== 0 && out.state === '') out.problems.push('state_required_with_cb');

  return out;
}

/**
 * Compares the fragment key against the Hub's stored copy.
 *
 * Fails closed: an empty value on either side is never agreement. "Nothing to
 * compare" rendering as "the keys match" is the one way this check could be
 * worse than not having it at all.
 *
 * Length-first, then an accumulating XOR so the comparison does not stop at the
 * first differing character. Neither value is secret, so this is not a
 * timing-attack defence — a non-short-circuiting compare on attacker-influenced
 * input is simply cheap to write and tiresome to justify omitting.
 */
export function publicKeysAgree(a: unknown, b: unknown): boolean {
  const x = String(a ?? '').trim().toLowerCase();
  const y = String(b ?? '').trim().toLowerCase();
  if (x === '' || y === '') return false;
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x.charCodeAt(i) ^ y.charCodeAt(i);
  return diff === 0;
}

/**
 * Builds the bridge's loopback callback URL.
 *
 * The host is a literal. `cb` contributes the port and nothing else, so no
 * value of it can redirect anywhere but this machine.
 *
 * The query carries STATE AND STATUS ONLY — no token, no key, no user_code, no
 * fingerprint. The bridge redeems over TLS by polling, so there is nothing here
 * worth putting into a URL that lands in browser history, proxy logs and
 * referrer headers.
 *
 * Returns null when there is nothing safe to build, including when the bridge
 * supplied no callback at all (the headless path), which is not an error.
 */
export function loopbackCallbackUrl(
  cb: unknown,
  state: unknown,
  status: 'approved' | 'rejected' | string,
): string | null {
  if (!/^[0-9]{1,5}$/.test(String(cb))) return null;
  const port = Number.parseInt(String(cb), 10);
  if (port < MIN_CALLBACK_PORT || port > MAX_CALLBACK_PORT) return null;
  if (!STATE_RE.test(String(state))) return null;
  if (status !== 'approved' && status !== 'rejected') return null;
  return (
    'http://127.0.0.1:' +
    port +
    '/enroll/callback?state=' +
    encodeURIComponent(String(state)) +
    '&status=' +
    encodeURIComponent(status)
  );
}

// ── The approval gate (REQ-ENROLL-5) ──────────────────────────────────────
//
// Coordinator ruling, 2026-10-07T20:52:03Z: a BRIDGE grant reached without a
// readable fragment key is REFUSED, not warned about.
//
// The reasoning, because the refusal looks harsher than the warning it
// replaces: without `bpk` this screen can neither cross-check the Hub's copy
// nor encrypt the vault key to the bridge. Approving anyway enrolls the bridge
// and SILENTLY FAILS TO DELIVER the key — the operator believes they are
// finished and discovers otherwise at the next unseal. That is the
// silent-failure class this chain exists to remove. There is also nothing the
// operator can do from this page to make it safe, so there is deliberately no
// "approve anyway" escape.
//
// An absent `bpk` is NOT a legitimate headless flow: the `--headless` bridge
// path omits `cb` and `state` but always emits `bpk`, so absence means the link
// was truncated or its hash stripped.
//
// THE CONSTRAINT THAT DECIDES THE SHAPE OF THIS FUNCTION: the refusal applies
// only to bridge grants, and it is keyed on `isBridgeGrant` — the wire
// projection of the PERSISTED `Grant_Kind` (`is_bridge_grant`, derived once at
// authorize) — and NEVER on whether `bpk` happens to be present. The
// pre-existing Electron user-token flow carries no fragment at all, so a
// refusal keyed on absent-`bpk` would break every Electron approval.

/** What the fragment cross-check concluded, and whether approval may proceed. */
export interface KeyCheckResult {
  kind: 'not-a-bridge' | 'no-fragment' | 'agreed' | 'mismatch';
  /** Operator-facing explanation of a `no-fragment` outcome; '' otherwise. */
  why: string;
  /** True when the Approve action must be unavailable. */
  approvalBlocked: boolean;
  /**
   * Why approval is blocked, as a clause that reads correctly after
   * "Approval is blocked: …". Empty exactly when `approvalBlocked` is false,
   * so callers can derive the boolean from it and cannot drift apart.
   */
  blockedReason: string;
}

export interface KeyCheckInput {
  /** From the PERSISTED grant kind, not from the presence of a key. */
  isBridgeGrant: boolean;
  fragment: ApprovalFragment;
  /** The Hub's bound copy of the bridge key. */
  hubKey: unknown;
}

/**
 * Decides whether this approval may proceed, given what the fragment carried
 * and what the Hub claims.
 *
 * Pure and exported so both ruled directions are testable directly: a bridge
 * grant with no fragment is refused, and a user-token grant with no fragment
 * still approves. There is no DOM harness in this repo, so a policy left inside
 * the component would be untestable — and this is the policy the security
 * property lives in.
 */
export function evaluateKeyCheck(input: KeyCheckInput): KeyCheckResult {
  // User-token grants return here, BEFORE any fragment reasoning. This is the
  // branch that keeps Electron working.
  if (!input.isBridgeGrant) {
    return { kind: 'not-a-bridge', why: '', approvalBlocked: false, blockedReason: '' };
  }

  const f = input.fragment;
  if (!f.present || f.problems.length > 0 || f.bpk === '') {
    return {
      kind: 'no-fragment',
      why: !f.present
        ? 'You reached this page without the enrollment link, so this page has no independently-supplied key to compare against and no key to encrypt the vault key to.'
        : `The enrollment link was present but its key could not be read (${f.problems.join(', ')}).`,
      approvalBlocked: true,
      blockedReason:
        'this enrollment link is incomplete, so the bridge key cannot be checked and the vault key cannot be delivered',
    };
  }

  if (!publicKeysAgree(f.bpk, input.hubKey)) {
    return {
      kind: 'mismatch',
      why: '',
      approvalBlocked: true,
      blockedReason: 'the bridge key reported by the Hub does not match the key in your link',
    };
  }

  return { kind: 'agreed', why: '', approvalBlocked: false, blockedReason: '' };
}

// ── Hub-measured time (REQ-ENROLL-14) ─────────────────────────────────────
//
// Review finding, 2026-10-07T21:02:37Z: the approval screen rendered
// `Date.now()` — the OPERATOR BROWSER's clock — in the group headed "Verified
// by Heimdall", whose copy promises "The Hub measured these itself". That was a
// false provenance claim in the one group on the screen whose whole job is to be
// trustworthy.
//
// It was also a behavioural defect, which is the part that justifies a wire
// change over a relabel. The only reason to show a "now" beside "Request
// received" is to let the operator judge HOW STALE the request is — the check
// that catches an approval screen opened from an old phishing link. With a local
// "now" that comparison was Hub-clock versus operator-clock, so any skew on the
// operator's machine silently shifted the apparent age of the request in either
// direction, with nothing on screen to say so.
//
// `hub_observed.server_time` now carries the Hub's own reading, in unix seconds,
// from the same `now` that decided the grant had not expired.
//
// THE RULE THESE FUNCTIONS EXIST TO ENFORCE: when the Hub's time is missing or
// implausible, the row renders as UNAVAILABLE. It does NOT fall back to the
// local clock. A silent fallback would reintroduce exactly the defect above
// while still passing any test that only exercised the happy path.

/** Lower bound for a plausible unix-seconds timestamp: 2020-01-01. */
const MIN_PLAUSIBLE_UNIX = 1577836800;
/** Upper bound: 2100-01-01. Catches milliseconds passed as seconds. */
const MAX_PLAUSIBLE_UNIX = 4102444800;

/**
 * Reads a Hub-measured unix-seconds timestamp, or reports it unavailable.
 *
 * Rejects non-integers, zero, negatives, and values outside a plausible range —
 * the last of which is what catches a milliseconds value handed over as
 * seconds, since that would render as a date in the year 56000 rather than as
 * an obvious error.
 */
export function hubMeasuredTime(raw: unknown): { seconds: number; available: boolean } {
  const n = typeof raw === 'number' ? raw : Number.parseInt(String(raw ?? ''), 10);
  if (!Number.isFinite(n) || !Number.isInteger(n)) return { seconds: 0, available: false };
  if (n < MIN_PLAUSIBLE_UNIX || n > MAX_PLAUSIBLE_UNIX) return { seconds: 0, available: false };
  return { seconds: n, available: true };
}

/**
 * How old the request is, computed from TWO Hub-measured values so that
 * operator clock skew cannot shift it.
 *
 * Unavailable unless both sides are plausible Hub values. A negative age (the
 * Hub's "now" earlier than its own `requested_at`) is reported as unavailable
 * rather than clamped to zero: it means the two values did not come from the
 * clock this function assumes, and inventing "0 seconds old" would hide that.
 */
export function requestAgeSeconds(
  requestedAt: unknown,
  serverTime: unknown,
): { seconds: number; available: boolean } {
  const req = hubMeasuredTime(requestedAt);
  const now = hubMeasuredTime(serverTime);
  if (!req.available || !now.available) return { seconds: 0, available: false };
  const age = now.seconds - req.seconds;
  if (age < 0) return { seconds: 0, available: false };
  return { seconds: age, available: true };
}

/** Renders an age in whole units, for a row the operator reads at a glance. */
export function formatAge(age: { seconds: number; available: boolean }): string {
  if (!age.available) return '';
  const s = age.seconds;
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}
