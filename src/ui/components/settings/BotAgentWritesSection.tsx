import { Alert, Button, EmptyState, Panel, Spinner, Text } from '@ui';
import { useState } from 'react';
import { useGetAgentWritesQuery } from '../../api/endpoints/bots';
import type { AgentWrite } from '../../api/endpoints/bots';
import { apiErrorText } from '../../api/cookieFetch';

const pastTense: Record<AgentWrite['action'], string> = {
  create: 'created', update: 'updated', archive: 'archived', unarchive: 'restored',
};

export default function BotAgentWritesSection() {
  const [cursor, setCursor] = useState<string>();
  const [previous, setPrevious] = useState<AgentWrite[]>([]);
  const query = useGetAgentWritesQuery(cursor);
  const page = query.currentData;
  const rows = [...new Map([...previous, ...(page?.items ?? [])].map((row) => [row.write_id, row])).values()]
    .sort((a, b) => b.seq - a.seq);

  return <Panel className="min-w-0 space-y-3">
    <Text as="h3" role="title" data-debug-id="settings-bots-agent-writes">Changes made by agents</Text>
    <Text tone="muted" data-debug-id="settings-bots-agent-writes-help">Projects, memories and agents that your agents created or changed. Newest first.</Text>
    {query.isFetching ? <div className="flex items-center gap-2"><Spinner /><Text tone="muted">Loading…</Text></div> : null}
    {query.isError ? <Alert tone="danger">{apiErrorText(query.error)} <Button type="button" variant="secondary" data-debug-id="settings-bots-agent-writes-retry-btn" onClick={() => query.refetch()}>Try again</Button></Alert> : null}
    {!query.isFetching && !query.isError && rows.length === 0 ? <EmptyState description={<Text tone="muted" data-debug-id="settings-bots-agent-writes-empty">No changes by agents yet.</Text>} /> : null}
    <div className="space-y-2">
      {rows.map((row) => <Text key={row.write_id} data-debug-id="settings-bots-agent-writes-row" className="break-words">
        {row.actor_display_name || row.actor_agent_instance_id} · {pastTense[row.action]} {row.resource_kind} {row.resource_id} · {row.fields.join(', ')} · {new Date(row.created_at).toLocaleString()}
      </Text>)}
    </div>
    {page?.next_cursor ? <Button variant="secondary" type="button" data-debug-id="settings-bots-agent-writes-more-btn" disabled={query.isFetching} onClick={() => { setPrevious(rows); setCursor(page.next_cursor); }}>Show older</Button> : null}
  </Panel>;
}
