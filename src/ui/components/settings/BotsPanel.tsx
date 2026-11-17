import { Modal } from '../ui/composites/Modal';
import { Button } from '@ui';
import { useState } from 'react';
import { useGetBotQuery, useCreateBotMutation, useDeleteBotMutation } from '../../api/endpoints/bots';
import { useFetchExperimentsQuery } from '../../api/endpoints/settings';
import { apiErrorText, queryErrorStatus } from '../../api/cookieFetch';
import { BOTS_EXPERIMENT_KEY, resolveExperimentFlag } from './experimentFlags';
import { BOT_STATUS_DETAILS, resolveBotStatusLabel } from './botsView';
import BotTelegramCard from './BotTelegramCard';
import BotPlacementEditor from './BotPlacementEditor';
import BotAdvancedSection from './BotAdvancedSection';

export default function BotsPanel({ onOpenTerminal }: { onOpenTerminal?: () => void }) {
  const flags = useFetchExperimentsQuery();
  const enabled = resolveExperimentFlag(flags.data?.flags, BOTS_EXPERIMENT_KEY) === 'enabled';
  const query = useGetBotQuery(undefined, { skip: !enabled, pollingInterval: enabled ? 10000 : 0 });
  const [create, creating] = useCreateBotMutation();
  const [remove, deleting] = useDeleteBotMutation();
  const [confirm, setConfirm] = useState(false);
  const [error, setError] = useState('');
  if (!enabled) return null;
  const bot = query.currentData;
  const absent = queryErrorStatus(query.error) === 404;
  async function createBot() {
    setError('');
    try { await create().unwrap(); } catch (e) { setError(apiErrorText(e)); }
  }
  async function deleteBot() {
    setError('');
    try { await remove().unwrap(); setConfirm(false); } catch (e) { setError(apiErrorText(e)); }
  }
  return <div data-debug-id="settings-bots-panel" className="space-y-4 text-primary">
    {query.isLoading ? <p>Loading…</p> : null}
    {query.isError && !absent ? <p role="alert">{apiErrorText(query.error)}</p> : null}
    {error ? <p role="alert" className="text-danger">{error}</p> : null}
    {absent ? <><p data-debug-id="settings-bots-empty">You don't have a bot yet. Your bot runs on your machines and answers you on Telegram.</p>
      <Button variant="secondary" type="button" data-debug-id="settings-bots-create-btn" disabled={creating.isLoading} onClick={createBot}>Create my bot</Button></> : bot ? <>
      <h3 className="text-lg font-semibold">{bot.display_name}</h3>
      <p data-debug-id="settings-bots-status">{resolveBotStatusLabel(bot.status)}</p>
      {bot.status_detail ? <p data-debug-id="settings-bots-status-detail">{BOT_STATUS_DETAILS[bot.status_detail]}</p> : null}
      <BotTelegramCard key={bot.bot_id} telegram={bot.telegram} />
      <BotPlacementEditor key={bot.bot_id + '-placement'} />
      <BotAdvancedSection bot={bot} onOpenTerminal={onOpenTerminal} />
      <Button variant="secondary" type="button" data-debug-id="settings-bots-delete-btn" className="text-danger" onClick={() => setConfirm(true)}>Delete bot</Button>
      <Modal open={confirm} onOpenChange={setConfirm} title="Delete your bot?" data-debug-id="settings-bots-delete-dialog"><Modal.Body><p>Delete your bot? Its Telegram connection and Telegram message history are removed.</p></Modal.Body><Modal.Footer>
        <Button variant="secondary" type="button" data-debug-id="settings-bots-delete-confirm-btn" disabled={deleting.isLoading} onClick={deleteBot}>Delete bot</Button>
        <Button variant="secondary" type="button" data-debug-id="settings-bots-delete-cancel-btn" onClick={() => setConfirm(false)}>Cancel</Button></Modal.Footer></Modal>
    </> : null}
  </div>;
}
