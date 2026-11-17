import { Button } from '@ui';
import { useDispatch } from 'react-redux';
import type { BotView } from '../../api/endpoints/bots';
import { useGetBotDeliveriesQuery } from '../../api/endpoints/bots';
import { openAuxTab } from '../../store/auxPanesSlice';
import { buildRouteHash } from '../../utils/appLocation';
import { apiErrorText } from '../../api/cookieFetch';

export default function BotAdvancedSection({ bot, onOpenTerminal }: { bot: BotView; onOpenTerminal?: () => void }) {
  const dispatch = useDispatch();
  const deliveries = useGetBotDeliveriesQuery(20);
  const advanced = bot.advanced;
  function openTerminal() {
    const agentInstanceId = advanced.agent_instance_id;
    if (!agentInstanceId) return;
    dispatch(openAuxTab({ treeId: { kind: 'agent', agentInstanceId }, content: { type: 'agentPty', agentInstanceId }, title: 'Ninjy bot terminal' }));
    window.location.hash = buildRouteHash('/conversations/' + encodeURIComponent(agentInstanceId), '');
    onOpenTerminal?.();
  }
  return <details className="rounded-xl border border-subtle p-4">
    <summary data-debug-id="settings-bots-advanced-toggle" className="cursor-pointer font-semibold">Advanced</summary>
    <div data-debug-id="settings-bots-advanced-details" className="my-3 text-sm">
      <p>Machine: {advanced.bridge_label}</p><p>Provider: {advanced.provider}</p><p>Model: {advanced.model}</p><p>Runtime: {advanced.runtime_status}</p>
    </div>
    <Button variant="secondary" type="button" data-debug-id="settings-bots-advanced-terminal-btn" disabled={!advanced.agent_instance_id} title={!advanced.agent_instance_id ? 'Your bot has not started yet.' : undefined} onClick={openTerminal}>Open terminal</Button>
    {deliveries.isError ? <p role="alert">{apiErrorText(deliveries.error)}</p> : null}
    <table data-debug-id="settings-bots-advanced-deliveries" className="mt-3 w-full text-left text-sm">
      <caption className="text-left">Recent deliveries</caption>
      <thead><tr><th>State</th><th>Round</th><th>Finish reason</th><th>Time</th></tr></thead>
      <tbody>{deliveries.data?.deliveries.map((delivery) => <tr key={delivery.delivery_id}><td>{delivery.state}</td><td>{delivery.round}</td><td>{delivery.finish_reason}</td><td>{delivery.created_at}</td></tr>)}</tbody>
    </table>
  </details>;
}
