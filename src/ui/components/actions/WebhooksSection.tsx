import React from 'react';
import { Alert, Button, FormField, Input, Panel, StatusPill, Text } from '@ui';
import { apiAbsoluteUrl } from '../../api/apiBase';
import { createWebhook, listWebhooks, rotateWebhook, setWebhookEnabled, setWebhookDedupeHeader, type EventWebhook, type WebhookSecret } from '../../api/endpoints/webhooks';
import { actionErrorText } from './actionModel';
import './webhooks.css';

function SecretValue({ label, value, id }: { label: string; value: string; id: string }) {
  const [notice, setNotice] = React.useState('');
  async function copy() {
    try { await navigator.clipboard.writeText(value); setNotice('Copied'); }
    catch { setNotice('Could not copy. Select the value and copy it manually.'); }
  }
  return <div className="webhook-secret-value"><FormField label={label}><Input aria-label={label} data-debug-id={'webhook-' + id} value={value} className="text-code" onChange={() => {}} readOnly /></FormField><Button variant="secondary" data-debug-id={'webhook-copy-' + id} onClick={() => void copy()}>Copy {label === 'Token' ? 'token' : label === 'Header URL' ? 'header URL' : 'secret URL'}</Button><span role="status" className="webhook-copy-notice">{notice}</span></div>;
}
export function WebhookSecretNotice({ secret, onDismiss }: { secret: WebhookSecret; onDismiss: () => void }) {
  const url = apiAbsoluteUrl('/api/v1/hooks/' + encodeURIComponent(secret.webhook.webhook_id));
  return <Panel className="webhook-secret">
    <Text as="h3" role="heading" id="webhook-secret-title" tabIndex={-1}>Save your webhook credentials now</Text>
    <Text role="body-sm">These credentials are shown once. After you dismiss this panel or leave this page, rotate the token to get new credentials.</Text>
    <SecretValue label="Token" value={secret.token} id="token" />
    <SecretValue label="Header URL" value={url} id="header-url" />
    <Text role="code-sm">Authorization: Bearer YOUR_TOKEN</Text>
    <Alert tone="warning" title="Keep the secret URL private">Anyone holding the secret URL can post events. Prefer the header URL when your sender supports it.</Alert>
    <SecretValue label="Secret URL" value={url + '/' + encodeURIComponent(secret.token)} id="secret-url" />
    <Button variant="secondary" data-debug-id="webhook-secret-dismiss" onClick={onDismiss}>I saved these credentials</Button>
  </Panel>;
}
function isCredentialHeader(value: string) {
  return ['authorization', 'proxy-authorization', 'cookie', 'set-cookie', 'x-api-key'].includes(value.toLowerCase());
}
function validDedupeHeader(value: string) {
  return value.length >= 1 && value.length <= 64 && !/[^!#$%&'*+.^_`|~0-9A-Za-z-]/.test(value) && !isCredentialHeader(value);
}
function dedupeHeaderError(value: string) {
  return isCredentialHeader(value) ? 'Choose an event ID header. Credential headers cannot be used for deduplication.' : 'Enter a header name of 1 to 64 letters, digits or HTTP token symbols.';
}
function DedupeHeaderEditor({ row, disabled, onSave }: { row: EventWebhook; disabled: boolean; onSave: (value: string) => void }) {
  const [value, setValue] = React.useState(row.dedupe_header);
  React.useEffect(() => setValue(row.dedupe_header), [row.dedupe_header]);
  const valid = validDedupeHeader(value);
  return <form className="webhook-create" onSubmit={event => { event.preventDefault(); if (valid && !disabled) onSave(value); }}>
    <FormField label="Dedupe header" hint="Use your sender’s event ID header. Retries with the same value are accepted once. Missing values create separate events.">
      <Input data-debug-id={'webhook-dedupe-header-' + row.webhook_id} aria-label={'Dedupe header for ' + row.name} value={value} onChange={setValue} disabled={disabled} />
    </FormField>
    {!valid ? <Text role="body-sm">{dedupeHeaderError(value)}</Text> : null}
    <Button type="submit" variant="secondary" data-debug-id={'webhook-dedupe-save-' + row.webhook_id} disabled={disabled || !valid || value === row.dedupe_header}>Save header</Button>
  </form>;
}
export default function WebhooksSection() {
  const [rows, setRows] = React.useState<EventWebhook[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [busy, setBusy] = React.useState(false);
  const [error, setError] = React.useState('');
  const [name, setName] = React.useState('');
  const [dedupeHeader, setDedupeHeader] = React.useState('Idempotency-Key');
  const validHeader = validDedupeHeader(dedupeHeader);
  const [secret, setSecret] = React.useState<WebhookSecret | null>(null);
  const [confirmRotate, setConfirmRotate] = React.useState<EventWebhook | null>(null);
  const mounted = React.useRef(false);
  const secretRef = React.useRef<HTMLDivElement>(null);
  async function load() {
    setLoading(true); setError('');
    try { const data = await listWebhooks(); if (mounted.current) setRows(data); }
    catch (e) { if (mounted.current) setError(actionErrorText(e)); }
    finally { if (mounted.current) setLoading(false); }
  }
  React.useEffect(() => { mounted.current = true; void load(); return () => { mounted.current = false; }; }, []);
  React.useEffect(() => { if (secret) secretRef.current?.querySelector<HTMLElement>('#webhook-secret-title')?.focus(); }, [secret]);
  async function mutate(operation: () => Promise<WebhookSecret | EventWebhook>) {
    setBusy(true); setError('');
    try {
      const result = await operation();
      if (!mounted.current) return;
      const row = 'webhook' in result ? result.webhook : result;
      setRows(prev => [row, ...prev.filter(item => item.webhook_id !== row.webhook_id)]);
      if ('token' in result) { setSecret(result); setName(''); }
      setConfirmRotate(null);
    } catch (e) { if (mounted.current) setError(actionErrorText(e)); }
    finally { if (mounted.current) setBusy(false); }
  }
  return <section className="webhooks-section" aria-labelledby="webhooks-title">
    <Text as="h2" role="heading" id="webhooks-title">Webhooks</Text>
    <Text role="body-sm" tone="muted">A webhook accepts JSON from your sender. To send an agent a prompt, add a Webhook received trigger to an action and choose this webhook.</Text>
    <Text role="body-sm" aria-live="polite" className="webhook-copy-notice">{busy ? 'Saving webhook…' : ''}</Text>
    {error ? <Alert tone="danger" title="Could not update webhooks">{error}</Alert> : null}
    {loading ? <Text role="body-sm" aria-live="polite">Loading webhooks…</Text> : null}
    {!loading && error && !rows.length ? <Button variant="secondary" data-debug-id="webhook-retry" onClick={() => void load()}>Try again</Button> : null}
    {!loading && !error && !rows.length ? <Text role="body-sm">No webhooks yet. Create one to connect your sender.</Text> : null}
    <div ref={secretRef} tabIndex={-1} className="webhook-secret-focus">{secret ? <WebhookSecretNotice secret={secret} onDismiss={() => { if (!window.confirm('Have you saved these credentials? They cannot be shown again.')) return; setSecret(null); requestAnimationFrame(() => document.querySelector<HTMLInputElement>('[data-debug-id="webhook-name"]')?.focus()); }} /> : null}</div>
    <form className="webhook-create" onSubmit={event => { event.preventDefault(); if (name.trim() && validHeader && !busy && !secret) void mutate(() => createWebhook(name.trim(), dedupeHeader)); }}>
      <FormField label="Webhook name" hint="For example, Release notifications. Creating a webhook does not send a prompt."><Input data-debug-id="webhook-name" aria-label="Webhook name" value={name} onChange={setName} disabled={busy || Boolean(secret)} /></FormField>
      <FormField label="Dedupe header" hint="Defaults to Idempotency-Key. Examples: X-GitHub-Delivery, Svix-Id, X-Request-Id."><Input data-debug-id="webhook-dedupe-header" aria-label="Dedupe header" value={dedupeHeader} onChange={setDedupeHeader} disabled={busy || Boolean(secret)} /></FormField>
      {!validHeader ? <Text role="body-sm">{dedupeHeaderError(dedupeHeader)}</Text> : null}
      <Button type="submit" variant="primary" data-debug-id="webhook-create" disabled={!name.trim() || !validHeader || busy || Boolean(secret)}>Create webhook</Button>
    </form>
    {rows.map(row => <Panel key={row.webhook_id} className="webhook-row">
      <Text as="h3" role="title">{row.name || 'Unnamed webhook'}</Text><StatusPill className="self-start" tone={row.enabled ? 'success' : 'neutral'}>{row.enabled ? 'Enabled' : 'Disabled'}</StatusPill>
      <Text role="code-sm" className="webhook-value">{row.webhook_id}</Text>
      <Text role="body-sm" tone="muted">{row.last_received_at ? 'Last received ' + row.last_received_at : 'No events received yet'}</Text>
      <DedupeHeaderEditor row={row} disabled={busy || Boolean(secret)} onSave={value => void mutate(() => setWebhookDedupeHeader(row.webhook_id, value))} />
      <div className="webhook-actions"><Button variant="secondary" data-debug-id={'webhook-enabled-' + row.webhook_id} disabled={busy || Boolean(secret)} onClick={() => void mutate(() => setWebhookEnabled(row.webhook_id, !row.enabled))}>{row.enabled ? 'Disable' : 'Enable'}</Button><Button variant="secondary" data-debug-id={'webhook-rotate-' + row.webhook_id} disabled={busy || Boolean(secret)} onClick={() => setConfirmRotate(row)}>Rotate token</Button></div>
      {confirmRotate?.webhook_id === row.webhook_id ? <div role="group" aria-label="Confirm token rotation"><Alert tone="warning" title="Replace this webhook’s token?">Both current URLs will stop accepting the old token immediately. Update your sender with the new credentials.</Alert><div className="webhook-actions"><Button variant="secondary" data-debug-id="webhook-rotate-cancel" onClick={() => { setConfirmRotate(null); requestAnimationFrame(() => document.querySelector<HTMLElement>('[data-debug-id="webhook-rotate-' + row.webhook_id + '"]')?.focus()); }} disabled={busy}>Cancel</Button><Button variant="danger" data-debug-id="webhook-rotate-confirm" onClick={() => void mutate(() => rotateWebhook(row.webhook_id))} disabled={busy}>Replace token</Button></div></div> : null}
    </Panel>)}
  </section>;
}
