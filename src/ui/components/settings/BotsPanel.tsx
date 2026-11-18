import { Alert, Button, EmptyState, Modal, PageShell, Panel, Spinner, StatusPill, Text } from '@ui';
import { useRef, useState } from 'react';
import { useGetBotQuery, useCreateBotMutation, useDeleteBotMutation } from '../../api/endpoints/bots';
import { useFetchExperimentsQuery } from '../../api/endpoints/settings';
import { apiErrorText, queryErrorStatus } from '../../api/cookieFetch';
import { BOTS_EXPERIMENT_KEY, resolveExperimentFlag } from './experimentFlags';
import { BOT_STATUS_DETAILS, resolveBotStatusLabel } from './botsView';
import BotTelegramCard from './BotTelegramCard';
import BotPlacementEditor from './BotPlacementEditor';
import BotAdvancedSection from './BotAdvancedSection';
import BotAgentWritesSection from './BotAgentWritesSection';

export default function BotsPanel({ onOpenTerminal }: { onOpenTerminal?: () => void }) {
  const flags = useFetchExperimentsQuery();
  const enabled = resolveExperimentFlag(flags.data?.flags, BOTS_EXPERIMENT_KEY) === 'enabled';
  const query = useGetBotQuery(undefined, { skip: !enabled, pollingInterval: enabled ? 10000 : 0 });
  const [create, creating] = useCreateBotMutation();
  const [remove, deleting] = useDeleteBotMutation();
  const [confirm, setConfirm] = useState(false);
  const [error, setError] = useState('');
  const pending = useRef(false);
  if (!enabled) return null;
  const bot = query.currentData;
  const absent = queryErrorStatus(query.error) === 404;
  async function createBot() {
    if (pending.current) return;
    pending.current = true;
    setError('');
    try { await create().unwrap(); } catch (e) { setError(apiErrorText(e)); } finally { pending.current = false; }
  }
  async function deleteBot() {
    if (pending.current) return;
    pending.current = true;
    setError('');
    try { await remove().unwrap(); setConfirm(false); } catch (e) { setError(apiErrorText(e)); } finally { pending.current = false; }
  }
  return <div data-debug-id="settings-bots-panel" className="min-w-0">
    <PageShell title={bot?.display_name ?? 'Bots'} rhythm="banded">
      <div className="min-w-0 space-y-4">
        {query.isLoading ? <div className="flex items-center gap-2 py-6"><Spinner /><Text tone="muted">Loading…</Text></div> : null}
        {query.isError && !absent ? <Alert tone="danger">{apiErrorText(query.error)}</Alert> : null}
        {error ? <Alert tone="danger">{error}</Alert> : null}
        {absent ? <EmptyState
          description={<Text data-debug-id="settings-bots-empty" tone="muted">You don't have a bot yet. Your bot runs on your machines and answers you on Telegram.</Text>}
          action={<Button variant="primary" type="button" data-debug-id="settings-bots-create-btn" loading={creating.isLoading} disabled={deleting.isLoading} onClick={createBot}>Create my bot</Button>}
        /> : bot ? <>
          <Panel className="min-w-0 space-y-3">
            <StatusPill data-debug-id="settings-bots-status" tone={bot.status === 'ready' ? 'success' : bot.status === 'working' || bot.status === 'starting' ? 'pending' : bot.status === 'waiting_for_machine' ? 'warning' : 'neutral'} className="max-w-full whitespace-normal leading-normal">{resolveBotStatusLabel(bot.status)}</StatusPill>
            {bot.status_detail ? <Text tone="muted" data-debug-id="settings-bots-status-detail">{BOT_STATUS_DETAILS[bot.status_detail]}</Text> : null}
          </Panel>
          <BotTelegramCard key={bot.bot_id} telegram={bot.telegram} />
          <BotPlacementEditor key={bot.bot_id + '-placement'} />
          <BotAdvancedSection bot={bot} onOpenTerminal={onOpenTerminal} />
          <BotAgentWritesSection key={bot.bot_id + '-writes'} />
          <Button variant="danger" type="button" data-debug-id="settings-bots-delete-btn" disabled={deleting.isLoading} onClick={() => setConfirm(true)}>Delete bot</Button>
          <Modal open={confirm} onOpenChange={(open) => { if (!pending.current) setConfirm(open); }} title="Delete your bot?" data-debug-id="settings-bots-delete-dialog"><Modal.Body><Text>Delete your bot? Its Telegram connection and Telegram message history are removed.</Text></Modal.Body><Modal.Footer>
            <Button variant="secondary" type="button" data-debug-id="settings-bots-delete-cancel-btn" disabled={deleting.isLoading} onClick={() => setConfirm(false)}>Cancel</Button>
            <Button variant="danger" type="button" data-debug-id="settings-bots-delete-confirm-btn" loading={deleting.isLoading} onClick={deleteBot}>Delete bot</Button>
          </Modal.Footer></Modal>
        </> : null}
      </div>
    </PageShell>
  </div>;
}
