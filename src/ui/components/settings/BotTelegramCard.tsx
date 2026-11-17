import { Modal } from '../ui/composites/Modal';
import { Button } from '@ui';
import { useState } from 'react';
import type { BotView, TelegramPairing } from '../../api/endpoints/bots';
import { useCreateTelegramPairingMutation, useDisconnectTelegramMutation } from '../../api/endpoints/bots';
import { apiErrorText } from '../../api/cookieFetch';

export default function BotTelegramCard({ telegram }: { telegram: BotView['telegram'] }) {
  const [pair, pairing] = useCreateTelegramPairingMutation();
  const [disconnect, disconnecting] = useDisconnectTelegramMutation();
  const [link, setLink] = useState<TelegramPairing | null>(null);
  const [confirm, setConfirm] = useState(false);
  const [error, setError] = useState('');
  async function connect() {
    setError('');
    try { setLink(await pair().unwrap()); } catch (e) { setError(apiErrorText(e)); }
  }
  async function remove() {
    setError('');
    try { await disconnect().unwrap(); setConfirm(false); setLink(null); } catch (e) { setError(apiErrorText(e)); }
  }
  return <section data-debug-id="settings-bots-telegram-card" className="space-y-3 rounded-xl border border-subtle p-4">
    <h3 className="font-semibold">Telegram</h3>
    {!telegram.configured ? <p data-debug-id="settings-bots-telegram-unconfigured">Telegram is not set up on this Ninjy hub. Ask your hub operator to add a Telegram bot token.</p>
      : telegram.binding ? <><p data-debug-id="settings-bots-telegram-paired">Connected to {telegram.binding.display}</p>
        <Button variant="secondary" type="button" data-debug-id="settings-bots-telegram-disconnect-btn" onClick={() => setConfirm(true)}>Disconnect</Button>
        <Modal open={confirm} onOpenChange={setConfirm} title="Disconnect Telegram?" data-debug-id="settings-bots-telegram-disconnect-dialog"><Modal.Body><p>Disconnect Telegram? Your bot will stop receiving messages from this chat.</p></Modal.Body><Modal.Footer>
          <Button variant="secondary" type="button" data-debug-id="settings-bots-telegram-disconnect-confirm-btn" disabled={disconnecting.isLoading} onClick={remove}>Disconnect</Button>
          <Button variant="secondary" type="button" data-debug-id="settings-bots-telegram-disconnect-cancel-btn" onClick={() => setConfirm(false)}>Cancel</Button></Modal.Footer></Modal>
      </> : <><p>Connect a Telegram chat to talk to your bot.</p>
        <Button variant="secondary" type="button" data-debug-id="settings-bots-telegram-connect-btn" disabled={pairing.isLoading} onClick={connect}>Connect Telegram</Button>
        {link ? <div data-debug-id="settings-bots-telegram-link"><p>Open this link on your phone within 10 minutes:</p>
          <a data-debug-id="settings-bots-telegram-open-link" href={link.pairing_url} target="_blank" rel="noreferrer">{link.pairing_url}</a>
          <Button variant="secondary" type="button" data-debug-id="settings-bots-telegram-copy-btn" onClick={async () => { try { await navigator.clipboard.writeText(link.pairing_url); } catch (e) { setError(apiErrorText(e)); } }}>Copy link</Button></div> : null}
      </>}
    <p data-debug-id="settings-bots-telegram-notice" className="text-sm text-muted">Telegram chats are not end-to-end encrypted. Telegram and your Ninjy hub can read these messages. Anyone who can send messages from your Telegram account can instruct your bot, which runs commands on your machines.</p>
    {error ? <p role="alert" className="text-danger">{error}</p> : null}
  </section>;
}
