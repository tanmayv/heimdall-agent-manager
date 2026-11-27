import { useEffect, useId, useRef, useState, useSyncExternalStore, type FormEvent } from 'react';
import { useSelector } from 'react-redux';
import { Alert, Button, Checkbox, FormField, Icon, Input, Panel, Select, Spinner, StatusPill, Text, type Tone } from '@ui';
import { withApiBase } from '../../api/apiBase';
import { USER_WS_RESYNC_EVENT } from '../../api/userWsRecovery';
import { currentDeviceIdentity, fetchVerifiedChain } from '../../services/deviceVault';
import type { store } from '../../store/store';
import { selectActiveTheme } from '../../store/themeSlice';
import { EXPECTED_USER_HEADER, getExpectedUserGeneration } from '../../utils/expectedUser';
import { getKeyringSession, keyringGeneration, subscribeKeyringSession } from '../../utils/vaultKeyringSession';
import { kindPolicy, signatureObjectText, SIGN_ALG_ECDSA_P256_SHA256 } from '../../utils/vaultStatements';
import { missingSecureFormChoices, sealSecureForm, secureFormChanged, secureFormId, verifySecureForm, type FormSigner, type FormStatus, type FormView, type VerifiedForm } from '../../utils/secureFormCrypto';
import darkLogo from '../../../../assets/brand/logos/ninjy-icon-dark-gold.png';
import lightLogo from '../../../../assets/brand/logos/ninjy-icon-light-gold.png';

const path = '/api/v1/secure-forms';
const blocked = 'The request could not be verified. No fields are available.';

class SecureFormHttpError extends Error {
  readonly status: number;
  constructor(status: number) {
    super('Secure form request failed');
    this.status = status;
  }
}

async function request<T>(suffix: string, owner: string, signal: AbortSignal, body?: unknown): Promise<T> {
  const res = await fetch(withApiBase(path + suffix), {
    signal, cache: 'no-store', credentials: 'same-origin', mode: 'same-origin', redirect: 'error',
    method: body === undefined ? 'GET' : 'POST',
    headers: body === undefined ? { [EXPECTED_USER_HEADER]: owner }
      : { [EXPECTED_USER_HEADER]: owner, 'Content-Type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  if (!res.ok) throw new SecureFormHttpError(res.status);
  const result = await res.json();
  return result.data;
}

type Card = { form: VerifiedForm; status: FormStatus; signer: FormSigner };
type Entries = Record<string, Card>;
const stateOrder: Record<FormStatus['state'], number> = { pending: 0, forwarding: 1, accepted: 2, final: 3 };

function statusMatches(status: FormStatus, form: VerifiedForm) {
  return status?.version === 1 && status.request_id === form.request.request_id
    && status.generation === form.request.generation && ['pending', 'forwarding', 'accepted', 'final'].includes(status.state);
}

async function verifyViews(views: FormView[], owner: string, conversation: string, expectedId?: string) {
  const entries: Entries = Object.create(null);
  const rejected = new Set<string>();
  if (!views.length) return { entries, rejected };
  const identity = currentDeviceIdentity();
  if (!identity || identity.userId !== owner || getKeyringSession()?.identity !== identity) throw new Error(blocked);
  const { chain, dir } = await fetchVerifiedChain();
  const signer = chain.trusted.get(identity.deviceId);
  if (chain.userId !== owner || !signer || !kindPolicy(signer.kind).canApprove
    || signer.sign_public_key !== identity.signPub || signer.sign_alg !== identity.signAlg
    || getKeyringSession()?.keyring.currentEpoch !== chain.currentEpoch) throw new Error(blocked);
  const proof = JSON.stringify({
    owner, root_device_id: chain.rootDeviceId, head_hash: chain.headHash, version: chain.version,
    current_epoch: chain.currentEpoch, pin_seq: chain.version, pin_hash: chain.headHash, vault_id: chain.vaultId,
    log: dir.log.map(({ seq, statement, signature }) => ({ seq, statement, signature: signatureObjectText(signature) })),
    devices: dir.devices.map((d) => ({
      id: d.device_id, kind: d.kind, sign_alg: d.sign_alg, wrap_alg: d.wrap_alg,
      sign_public_key: d.sign_public_key, ecdh_public_key: d.ecdh_public_key,
      approved: d.status === 'approved', pending: d.status === 'pending',
    })),
  });
  if (new TextEncoder().encode(proof).length > 262144) throw new Error(blocked);
  const signing: FormSigner = {
    deviceId: identity.deviceId, signPrivateKey: identity.signPrivateKey, sequence: chain.version, head: chain.headHash, proof,
  };
  const seen = new Set<string>();
  for (const [index, view] of views.entries()) {
    const id = view?.registration?.request?.request_id;
    if (typeof id !== 'string' || !secureFormId.test(id) || (expectedId && id !== expectedId)) {
      rejected.add(expectedId ?? 'invalid-' + index);
      continue;
    }
    if (seen.has(id)) {
      delete entries[id];
      rejected.add(id);
      continue;
    }
    seen.add(id);
    try {
      const { registration, status } = view;
      const bridgeId = registration.request.bridge;
      const candidates = [...chain.trusted.values()].filter((d) => d.kind === 'bridge' && d.row.bridge_id === bridgeId
        && d.sign_alg === SIGN_ALG_ECDSA_P256_SHA256 && !chain.retiredHints.includes(d.device_id));
      const verified = await Promise.any(candidates.map((device) => verifySecureForm(registration,
        { owner, conversation, bridge: bridgeId }, device.sign_public_key)));
      if (!statusMatches(status, verified)) throw new Error(blocked);
      entries[id] = { form: verified, status, signer: signing };
    } catch {
      rejected.add(id);
    }
  }
  return { entries, rejected };
}

function label(status: FormStatus, expired: boolean, sent: boolean): [string, Tone] {
  if (status.state === 'final') {
    if (status.code === 0) return ['Completed', 'success'];
    if (status.code === 21) return ['Declined', 'neutral'];
    if (status.code === 22) return ['Expired', 'warning'];
    if (status.code === 23) return ['Cancelled', 'neutral'];
    if (status.code === 28) return ['Outcome unknown', 'warning'];
    return ['Did not complete', 'danger'];
  }
  if (status.state === 'accepted') return ['Accepted', 'success'];
  if (status.state === 'forwarding') return ['Forwarding', 'pending'];
  if (sent) return ['Decision sent', 'pending'];
  return expired ? ['Expired', 'warning'] : ['Awaiting your input', 'pending'];
}

function SecureFormCard({ card, decide, decided }: {
  card: Card;
  decide: (id: string, body: unknown, action: 'submit' | 'decline') => Promise<void>;
  decided: React.MutableRefObject<Set<string>>;
}) {
  const { form, status, signer } = card;
  const { request: r, schema } = form;
  const titleId = useId();
  const fieldsId = useId();
  const [values, setValues] = useState<Record<string, string | string[]>>({});
  const [expired, setExpired] = useState(() => Date.now() >= Number(r.deadline));
  const [error, setError] = useState('');
  const [fieldErrors, setFieldErrors] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState(() => decided.current.has(r.request_id));
  const active = useRef(false);
  const viewGeneration = useRef(0);
  const logo = useSelector(selectActiveTheme).appearance === 'light' ? lightLogo : darkLogo;
  useEffect(() => {
    active.current = true;
    const expire = () => { setExpired(true); setValues({}); };
    const clear = () => { viewGeneration.current++; setValues({}); setFieldErrors({}); };
    const timer = window.setTimeout(expire, Math.max(0, Number(r.deadline) - Date.now()));
    window.addEventListener('pagehide', clear);
    window.addEventListener('hashchange', clear);
    window.addEventListener('popstate', clear);
    return () => {
      active.current = false;
      clearTimeout(timer);
      window.removeEventListener('pagehide', clear);
      window.removeEventListener('hashchange', clear);
      window.removeEventListener('popstate', clear);
    };
  }, [r.deadline]);
  useEffect(() => { if (status.state !== 'pending') setValues({}); }, [status.state]);
  const set = (id: string, value: string | string[]) => {
    setValues((prev) => ({ ...prev, [id]: value }));
    setFieldErrors((prev) => Object.hasOwn(prev, id) ? { ...prev, [id]: '' } : prev);
  };
  const [state, tone] = label(status, expired, sent);

  async function send(action: 'submit' | 'decline', event?: FormEvent) {
    event?.preventDefault();
    if (decided.current.has(r.request_id) || Date.now() >= Number(r.deadline) || status.state !== 'pending') return;
    if (action === 'submit') {
      const missing = missingSecureFormChoices(schema.fields, values);
      setFieldErrors(missing);
      if (Object.keys(missing).length) return;
    }
    decided.current.add(r.request_id);
    setBusy(true);
    setError('');
    setValues({});
    setFieldErrors({});
    const generation = getExpectedUserGeneration();
    const vault = keyringGeneration();
    const view = viewGeneration.current;
    let started = false;
    try {
      if (!getKeyringSession()) throw new Error('Locked');
      const body = action === 'submit' ? await sealSecureForm(form, values, signer)
        : { version: 1, request_id: r.request_id, generation: r.generation };
      if (!active.current || viewGeneration.current !== view || getExpectedUserGeneration() !== generation || keyringGeneration() !== vault
        || Date.now() >= Number(r.deadline)) throw new Error('Decision no longer valid');
      started = true;
      setSent(true);
      await decide(r.request_id, body, action);
    } catch {
      if (!started) decided.current.delete(r.request_id);
      if (active.current) setError(started
        ? 'The decision could not be confirmed. Ask the agent for a new request if needed.'
        : 'Nothing was sent. Enter the values again and check the form limits.');
    } finally {
      if (active.current) setBusy(false);
    }
  }

  return (
    <Panel aria-labelledby={titleId} className="min-w-0">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          {schema.logo ? <img src={logo} alt="" className="h-6 w-6" /> : <Icon name="lock" />}
          <Text id={titleId} as="h2" role="heading">Secure request</Text>
        </div>
        <StatusPill aria-live="polite" tone={tone}>{busy && !sent ? 'Preparing decision' : state}</StatusPill>
      </div>
      <div className="mt-3 grid gap-2">
        <Text role="title" className="break-words">{schema.purpose}</Text>
        <Text role="body-sm" tone="muted">Requested by agent <Text role="code-sm" className="break-all">{r.instance}</Text></Text>
        <Text role="body-sm" tone="muted">Bridge <Text role="code-sm" className="break-all">{r.bridge}</Text></Text>
        <Text role="body-sm" tone="muted">Script <Text role="code-sm" className="break-all">{r.script}</Text></Text>
        <Text role="body-sm" tone="muted">Deadline <time dateTime={new Date(Number(r.deadline)).toISOString()}>{new Date(Number(r.deadline)).toLocaleString()}</time></Text>
      </div>
      {error && <Alert tone="danger" className="mt-3">{error}</Alert>}
      {status.state === 'pending' && !expired && !sent && (
        <form aria-labelledby={titleId} autoComplete="off" className="mt-4 grid gap-4" onSubmit={(event) => void send('submit', event)}>
          {schema.fields.map((field, index) => {
            const value = Object.hasOwn(values, field.id) ? values[field.id] : '';
            const fieldError = Object.hasOwn(fieldErrors, field.id) ? fieldErrors[field.id] : undefined;
            if (field.type === 'multiple') {
              const selected = Array.isArray(value) ? value : [];
              const fieldId = fieldsId + '-' + index;
              return <fieldset key={field.id} aria-labelledby={fieldId} aria-describedby={fieldError ? fieldId + '-error' : undefined} className="grid min-w-0 gap-2" disabled={busy}>
                <Text id={fieldId} role="label" className="break-words">{field.label} (choose at least one)</Text>
                {field.choices?.map((choice) => <Checkbox key={choice.id} label={choice.label}
                  checked={selected.includes(choice.id)} aria-describedby={fieldError ? fieldId + '-error' : undefined}
                  onChange={(checked) => set(field.id, checked ? [...selected, choice.id] : selected.filter((id) => id !== choice.id))} />)}
                {fieldError && <Text id={fieldId + '-error'} role="body-sm" tone="danger" aria-live="polite">{fieldError}</Text>}
              </fieldset>;
            }
            return <FormField key={field.id} label={field.label} error={fieldError} required>
              {field.type === 'single'
                ? <Select value={String(value)} disabled={busy} onChange={(next) => set(field.id, next)} placeholder="Choose an option"
                    options={(field.choices ?? []).map((c) => ({ value: c.id, label: c.label }))} />
                : <Input type={field.type === 'password' ? 'password' : 'text'} value={String(value)} disabled={busy}
                    autoComplete="off" spellCheck={false} autoCorrect="off"
                    autoCapitalize="off" maxLength={8192} required onChange={(next) => set(field.id, next)} />}
            </FormField>;
          })}
          <Text role="body-sm" tone="muted">Your browser encrypts these values for the named script. Heimdall does not save them to persistent storage. The Bridge keeps an encrypted copy in memory for up to 5 minutes. During that time the agent can edit and rerun this script for the shown purpose without asking you again.</Text>
          <div className="flex flex-wrap justify-end gap-2">
            <Button variant="secondary" type="button" disabled={busy} onClick={() => void send('decline')}>Decline</Button>
            <Button variant="primary" type="submit" disabled={busy}>Encrypt and send</Button>
          </div>
        </form>
      )}
    </Panel>
  );
}

export default function SecureForms({ conversation }: { conversation: string }) {
  const owner = useSelector((state: ReturnType<typeof store.getState>) => state.deviceVault.userId);
  const vaultGeneration = useSyncExternalStore(subscribeKeyringSession, keyringGeneration);
  const stale = useSelector((state: ReturnType<typeof store.getState>) => state.deviceVault.staleHead);
  const context = owner + ':' + conversation;
  const submitted = useRef({ context, ids: new Set<string>() });
  if (submitted.current.context !== context) submitted.current = { context, ids: new Set<string>() };
  if (!owner) return null;
  if (stale) return <Alert tone="warning" title="Secure requests unavailable">Reload after your device verifies the current vault directory.</Alert>;
  return <SecureFormsForOwner key={context + ':' + vaultGeneration} conversation={conversation} owner={owner} decisions={submitted.current.ids} />;
}

function SecureFormsForOwner({ conversation, owner, decisions }: { conversation: string; owner: string; decisions: Set<string> }) {
  const [entries, setEntries] = useState<Entries>({});
  const [loading, setLoading] = useState(true);
  const [rejected, setRejected] = useState<Set<string>>(() => new Set());
  const [refreshErrors, setRefreshErrors] = useState<Set<string | undefined>>(() => new Set());
  const decisionRef = useRef(decisions);
  const controller = useRef<AbortController | null>(null);
  const known = useRef<Entries>({});
  const rejectedNow = useRef(new Set<string>());
  const retry = useRef<(id?: string) => void>(() => {});

  useEffect(() => {
    const abort = new AbortController();
    controller.current = abort;
    let pending = Promise.resolve();
    const merge = ({ entries: incoming, rejected: failures }: Awaited<ReturnType<typeof verifyViews>>, id?: string) => {
      const next = { ...known.current };
      const hidden = new Set(rejectedNow.current);
      if (!id) for (const key of hidden) if (!secureFormId.test(key)) hidden.delete(key);
      for (const [key, card] of Object.entries(incoming)) {
        const old = next[key];
        const incomingDigest = new Uint8Array(card.form.digest);
        if (old && new Uint8Array(old.form.digest).some((byte, i) => byte !== incomingDigest[i])) {
          failures.add(key);
          continue;
        }
        if (!old || stateOrder[old.status.state] <= stateOrder[card.status.state]) next[key] = card;
        hidden.delete(key);
      }
      for (const failed of failures) hidden.add(failed);
      known.current = next;
      rejectedNow.current = hidden;
      setEntries(next);
      setRejected(hidden);
    };
    const refresh = async (id?: string) => {
      if (abort.signal.aborted) return;
      try {
        const views = id
          ? [await request<FormView>('/' + id, owner, abort.signal)]
          : await request<FormView[]>('?conversation_id=' + encodeURIComponent(conversation), owner, abort.signal);
        const updated = await verifyViews(views, owner, conversation, id);
        if (abort.signal.aborted) return;
        merge(updated, id);
        setRefreshErrors((previous) => {
          const next = new Set(previous);
          next.delete(id);
          return next;
        });
      } catch {
        if (!abort.signal.aborted) setRefreshErrors((previous) => new Set(previous).add(id));
      } finally {
        if (!abort.signal.aborted) setLoading(false);
      }
    };
    const queue = (id?: string) => { pending = pending.then(() => refresh(id)); };
    retry.current = queue;
    const changed = (event: Event) => {
      const data = (event as CustomEvent<{ conversation_id: string; request_id: string }>).detail;
      if (data?.conversation_id === conversation && secureFormId.test(data.request_id)) queue(data.request_id);
    };
    const resync = () => {
      queue();
      for (const [id, card] of Object.entries(known.current)) {
        if (card.status.state !== 'final' && Date.now() < Number(card.form.request.deadline) + 60000) queue(id);
      }
    };
    window.addEventListener(secureFormChanged, changed);
    window.addEventListener(USER_WS_RESYNC_EVENT, resync);
    queue();
    return () => {
      abort.abort();
      window.removeEventListener(secureFormChanged, changed);
      window.removeEventListener(USER_WS_RESYNC_EVENT, resync);
    };
  }, [owner, conversation]);

  async function decide(id: string, body: unknown, action: 'submit' | 'decline') {
    const signal = controller.current?.signal;
    const card = known.current[id];
    if (!signal || signal.aborted || !card || rejectedNow.current.has(id) || !getKeyringSession()) throw new Error('Form no longer active');
    // Only the sealed envelope (submit) or public reference (decline) reaches fetch.
    const status = await request<FormStatus>('/' + id + '/' + action, owner, signal, body);
    if (!statusMatches(status, card.form)) throw new Error('Unexpected form status');
    if (signal.aborted) return;
    const current = known.current[id];
    if (!current || stateOrder[current.status.state] > stateOrder[status.state]) return;
    const next = { ...known.current, [id]: { ...card, status } };
    known.current = next;
    setEntries(next);
  }

  if (loading) return <div role="status" className="flex items-center gap-2"><Spinner /><Text role="body-sm">Checking for secure requests</Text></div>;
  if (!Object.keys(entries).length && !refreshErrors.size && !rejected.size) return null;
  if (!getKeyringSession()) return <Alert tone="warning" title="Vault locked">Unlock your vault to check secure requests.</Alert>;
  return <div className="grid min-w-0 gap-3">
    {Object.entries(entries).filter(([id]) => !rejected.has(id)).map(([id, card]) => <SecureFormCard key={id} card={card} decide={decide} decided={decisionRef} />)}
    {[...rejected].map((id) => <Alert key={id} tone="warning" title="Unverified secure request">{blocked}</Alert>)}
    {refreshErrors.size > 0 && <Alert tone="warning" title="Could not refresh secure requests">
      <Text as="p" role="body-sm">Some requests may be out of date.</Text>
      <Button type="button" size="sm" variant="secondary" className="mt-2" onClick={() => {
        for (const id of refreshErrors) retry.current(id);
      }}>Check requests again</Button>
    </Alert>}
  </div>;
}


export function SecureFormLinkPage({ requestId }: { requestId: string }) {
  const owner = useSelector((state: ReturnType<typeof store.getState>) => state.deviceVault.userId);
  const stale = useSelector((state: ReturnType<typeof store.getState>) => state.deviceVault.staleHead);
  const vault = useSyncExternalStore(subscribeKeyringSession, keyringGeneration);
  return <div className="mx-auto grid w-full max-w-xl gap-4 p-4 sm:p-6">
    <Text as="h1" role="title">Secure request</Text>
    {!secureFormId.test(requestId) ? <Alert title="Secure request not found">Check the link or ask the agent for a new request.</Alert>
      : !owner ? <Alert tone="warning" title="Sign-in required">Sign in to the owner’s Hub account.</Alert>
      : stale || !getKeyringSession() ? <Alert tone="warning" title="Vault unavailable">Unlock your vault and verify your device to open this request.</Alert>
      : <LinkedSecureForm key={owner + ':' + requestId + ':' + vault} owner={owner} id={requestId} />}
  </div>;
}

function LinkedSecureForm({ owner, id }: { owner: string; id: string }) {
  const [card, setCard] = useState<Card | null>(null);
  const [notice, setNotice] = useState('');
  const [revision, setRevision] = useState(0);
  const controller = useRef<AbortController | null>(null);
  const active = useRef<Card | null>(null);
  const decided = useRef(new Set<string>());

  function update(next: Card) {
    if (active.current && stateOrder[active.current.status.state] > stateOrder[next.status.state]) return;
    active.current = next;
    setCard(next);
  }

  function unavailable(error: unknown) {
    active.current = null;
    setCard(null);
    const status = error instanceof SecureFormHttpError ? error.status : 0;
    setNotice(status === 404 ? 'Secure request not found'
      : status === 401 || status === 403 ? 'Secure request unavailable to this account'
      : 'Could not load secure request');
  }

  useEffect(() => {
    const abort = new AbortController();
    controller.current = abort;
    let timer: number | undefined;
    async function refresh() {
      try {
        const view = await request<FormView>('/' + id, owner, abort.signal);
        const conversation = view?.registration?.request?.conversation;
        const verified = typeof conversation === 'string' && conversation
          ? (await verifyViews([view], owner, conversation, id)).entries[id]
          : undefined;
        if (abort.signal.aborted) return;
        if (!verified || (active.current && active.current.form.request.generation !== verified.form.request.generation)) {
          active.current = null;
          setCard(null);
          setNotice('Unverified secure request');
          return;
        }
        setNotice('');
        update(verified);
        if (active.current?.status.state !== 'final') timer = window.setTimeout(refresh, 2000);
      } catch (error) {
        if (!abort.signal.aborted) unavailable(error);
      }
    }
    void refresh();
    return () => {
      abort.abort();
      window.clearTimeout(timer);
    };
  }, [owner, id, revision]);

  async function decide(requestId: string, body: unknown, action: 'submit' | 'decline') {
    const signal = controller.current?.signal;
    const current = active.current;
    if (!signal || signal.aborted || !current || current.status.state !== 'pending'
      || requestId !== id || !getKeyringSession()) throw new Error('Form no longer active');
    try {
      const status = await request<FormStatus>('/' + id + '/' + action, owner, signal, body);
      if (!statusMatches(status, current.form)) throw new Error('Unexpected form status');
      if (!signal.aborted && active.current) update({ ...current, status });
    } catch (error) {
      if (!signal.aborted && error instanceof SecureFormHttpError && [401, 403, 404].includes(error.status)) {
        controller.current?.abort();
        unavailable(error);
      }
      throw error;
    }
  }

  if (notice) return <Alert tone="warning" title={notice}>
    {notice === 'Unverified secure request' ? blocked
      : notice === 'Secure request not found' ? 'This link may be old or belong to another account.'
      : notice === 'Secure request unavailable to this account' ? 'Sign in to the owner’s Hub account.'
      : <Button type="button" variant="secondary" size="sm" onClick={() => {
        setNotice('');
        setRevision((value) => value + 1);
      }}>Try again</Button>}
  </Alert>;
  if (!card) return <div role="status" className="flex items-center gap-2"><Spinner /><Text role="body-sm">Checking secure request</Text></div>;
  return <SecureFormCard card={card} decide={decide} decided={decided} />;
}
