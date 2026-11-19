import { Alert, Button, Link, Modal, Panel, Text } from '@ui';
import { useRef, useState } from 'react';
import type { BotView, TelegramPairing } from '../../api/endpoints/bots';
import { useCreateTelegramPairingMutation, useDisconnectTelegramMutation } from '../../api/endpoints/bots';
import { apiErrorText } from '../../api/cookieFetch';

export default function BotTelegramCard({ telegram }: { telegram: BotView['telegram'] }) {
  const [pair, pairing] = useCreateTelegramPairingMutation();
  const [disconnect, disconnecting] = useDisconnectTelegramMutation();
  const [link, setLink] = useState<TelegramPairing | null>(null);
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
  return <Panel title="Telegram" data-debug-id="settings-bots-telegram-card" className="min-w-0 space-y-3">
    {!telegram.configured ? <Text data-debug-id="settings-bots-telegram-unconfigured">Telegram is not set up on this Ninjy hub. Ask your hub operator to add a Telegram bot token.</Text>
      : telegram.binding ? <><Text data-debug-id="settings-bots-telegram-paired">Connected to {telegram.binding.display}</Text>
        <Button variant="danger" type="button" disabled={busy} data-debug-id="settings-bots-telegram-disconnect-btn" onClick={() => setConfirm(true)}>Disconnect</Button>
        <Modal open={confirm} onOpenChange={(open) => { if (!pending.current) setConfirm(open); }} title="Disconnect Telegram?" data-debug-id="settings-bots-telegram-disconnect-dialog"><Modal.Body><Text>Disconnect Telegram? Your bot will stop receiving messages from this chat.</Text></Modal.Body><Modal.Footer>
          <Button variant="secondary" type="button" data-debug-id="settings-bots-telegram-disconnect-cancel-btn" disabled={busy} onClick={() => setConfirm(false)}>Cancel</Button>
          <Button variant="danger" type="button" data-debug-id="settings-bots-telegram-disconnect-confirm-btn" loading={disconnecting.isLoading} disabled={pairing.isLoading || copying} onClick={remove}>Disconnect</Button></Modal.Footer></Modal>
      </> : <><Text>Connect a Telegram chat to talk to your bot.</Text>
        <Button variant="primary" type="button" data-debug-id="settings-bots-telegram-connect-btn" loading={pairing.isLoading} disabled={disconnecting.isLoading || copying} onClick={connect}>Connect Telegram</Button>
        {link ? <div data-debug-id="settings-bots-telegram-link" className="min-w-0 space-y-2"><Text>Open this link on your phone within 10 minutes:</Text>
          <Link className="block break-all" data-debug-id="settings-bots-telegram-open-link" href={link.pairing_url} target="_blank" rel="noreferrer">{link.pairing_url}</Link>
          <Button variant="secondary" type="button" data-debug-id="settings-bots-telegram-copy-btn" loading={copying} disabled={pairing.isLoading || disconnecting.isLoading} onClick={copyLink}>Copy link</Button></div> : null}
      </>}
    <Text data-debug-id="settings-bots-telegram-notice" role="body-sm" tone="muted">Telegram chats are not end-to-end encrypted. Telegram and your Ninjy hub can read these messages. Anyone who can send messages from your Telegram account can instruct your bot, which runs commands on your machines.</Text>
    {error ? <Alert tone="danger">{error}</Alert> : null}
  </Panel>;
}
