import { Alert, Button, Link, Modal, Panel, Text } from '@ui';
import { useRef, useState } from 'react';
import { whatsAppCardState, whatsAppQrDataUrl } from './botsView';
import type { BotView, WhatsAppPairing } from '../../api/endpoints/bots';
import { useCreateWhatsAppPairingMutation, useDisconnectWhatsAppMutation } from '../../api/endpoints/bots';
import { apiErrorText } from '../../api/cookieFetch';

export default function BotWhatsAppCard({ whatsapp }: { whatsapp: BotView['whatsapp'] }) {
  const [pair, pairing] = useCreateWhatsAppPairingMutation();
  const [disconnect, disconnecting] = useDisconnectWhatsAppMutation();
  const [link, setLink] = useState<WhatsAppPairing | null>(null);
  const [confirm, setConfirm] = useState(false);
  const [error, setError] = useState('');
  const pending = useRef(false);
  const [copying, setCopying] = useState(false);
  const busy = pairing.isLoading || disconnecting.isLoading || copying;
  async function connect() {
    if (pending.current) return;
    pending.current = true;
    setError('');
    try { setLink(await pair().unwrap()); } catch (e) { setError(apiErrorText(e)); } finally { pending.current = false; }
  }
  async function remove() {
    if (pending.current) return;
    pending.current = true;
    setError('');
    try { await disconnect().unwrap(); setConfirm(false); setLink(null); } catch (e) { setError(apiErrorText(e)); } finally { pending.current = false; }
  }
  async function copyLink() {
    if (!link || pending.current) return;
    pending.current = true;
    setCopying(true);
    try { await navigator.clipboard.writeText(link.pairing_url); } catch (e) { setError(apiErrorText(e)); }
    finally { pending.current = false; setCopying(false); }
  }
  const state = whatsAppCardState(whatsapp);
  const reminder = whatsapp.reengage_sent ? 'Ninjy sent you a WhatsApp reminder.'
    : whatsapp.reengage_error === 'template_unavailable' ? 'Ninjy could not send you a WhatsApp reminder because its message template is not approved yet.'
    : whatsapp.reengage_error === 'send_failed' ? 'Ninjy could not send you a WhatsApp reminder.' : '';
  return <Panel title="WhatsApp" data-debug-id="settings-bots-whatsapp-card" className="min-w-0 space-y-3">
    {state === 'unconfigured' ? <Text data-debug-id="settings-bots-whatsapp-unconfigured">WhatsApp is not set up on this Ninjy hub. Ask your hub operator to connect a WhatsApp Business number.</Text>
      : whatsapp.binding ? <><Text data-debug-id="settings-bots-whatsapp-paired">Connected to {whatsapp.binding.display}</Text>
        <Button variant="danger" type="button" disabled={busy} data-debug-id="settings-bots-whatsapp-disconnect-btn" onClick={() => setConfirm(true)}>Disconnect</Button>
        <Modal open={confirm} onOpenChange={(open) => { if (!pending.current) setConfirm(open); }} title="Disconnect WhatsApp?" data-debug-id="settings-bots-whatsapp-disconnect-dialog"><Modal.Body><Text>Disconnect WhatsApp? Your bot will stop receiving messages from this WhatsApp account.</Text></Modal.Body><Modal.Footer>
          <Button variant="secondary" type="button" data-debug-id="settings-bots-whatsapp-disconnect-cancel-btn" disabled={busy} onClick={() => setConfirm(false)}>Cancel</Button>
          <Button variant="danger" type="button" data-debug-id="settings-bots-whatsapp-disconnect-confirm-btn" loading={disconnecting.isLoading} disabled={pairing.isLoading || copying} onClick={remove}>Disconnect</Button></Modal.Footer></Modal>
      </> : <><Text data-debug-id="settings-bots-whatsapp-unpaired">Connect your WhatsApp to talk to your bot.</Text>
        <Button variant="primary" type="button" data-debug-id="settings-bots-whatsapp-connect-btn" loading={pairing.isLoading} disabled={disconnecting.isLoading || copying} onClick={connect}>Connect WhatsApp</Button>
        {link ? <div data-debug-id="settings-bots-whatsapp-link" className="min-w-0 space-y-2"><Text>Open this link on your phone within 10 minutes, or scan the code with your phone's camera. Send the prefilled message without changing it:</Text>
          <Link className="block break-all" data-debug-id="settings-bots-whatsapp-open-link" href={link.pairing_url} target="_blank" rel="noreferrer">{link.pairing_url}</Link>
          <img src={whatsAppQrDataUrl(link.pairing_url)} alt="QR code to connect WhatsApp" className="h-48 w-48" data-debug-id="settings-bots-whatsapp-qr" />
          <Text data-debug-id="settings-bots-whatsapp-pairing-text">Message: {link.pairing_text}</Text>
          <Button variant="secondary" type="button" data-debug-id="settings-bots-whatsapp-copy-btn" loading={copying} disabled={pairing.isLoading || disconnecting.isLoading} onClick={copyLink}>Copy link</Button></div> : null}
      </>}
    {state === 'held' ? <><div data-debug-id="settings-bots-whatsapp-held"><Alert tone="warning">Your bot answered after WhatsApp's 24-hour reply window closed. Send any WhatsApp message to your bot to receive the reply.
      {whatsapp.held_replies.map((reply, index) => <Text key={reply.message_id} className="whitespace-pre-wrap" data-debug-id={'settings-bots-whatsapp-held-item-' + index}>{reply.body}</Text>)}
    </Alert></div>{reminder ? <Text data-debug-id="settings-bots-whatsapp-reminder">{reminder}</Text> : null}</> : null}
    <Text data-debug-id="settings-bots-whatsapp-notice" role="body-sm" tone="muted">WhatsApp's end-to-end encryption ends at Meta's business messaging service. Meta and your Ninjy hub can read these messages. Anyone who can send messages from your WhatsApp account can instruct your bot, which runs commands on your machines.</Text>
    {error ? <Alert tone="danger">{error}</Alert> : null}
  </Panel>;
}
