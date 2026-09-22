/**
 * AgentDetail — the agent view's guts, rendered as a full page AND as the
 * two-pane right-hand pane. Modeled after ProjectDetail.
 * ------------------------------------------------------------------
 * One implementation, two mounts, so the page and the pane cannot drift apart.
 *
 * Cards: Instructions · Details · Instances · Memory.
 *
 * What is deliberately absent:
 *  - **Created.** `created_at` is not serialised by `write_agent_json`
 *    (`agent_handlers.odin:338-351`). Amendment 6: do not render what the
 *    API does not send.
 *  - **Owner.** Same reason — `owner_user_id` is never emitted.
 *  - **Restore / Unarchive.** No endpoint reverses an archive.
 *  - **Delete.** There is no DELETE route for an agent identity at all.
 *
 * Agent→Memories: kept (Amendment 9). The asymmetric ruling removed the
 * Project→Agent link; the Agent→Memory link is intentionally preserved.
 */
import React from 'react';
import {
  ActionButton,
  Alert,
  Badge,
  Button,
  Icon,
  IconButton,
  Menu,
  MenuItem,
  Panel,
  Spinner,
  StatusPill,
  Text,
  useViewport,
} from '@ui';
import MarkdownBody from '../MarkdownBody';
import {
  agentErrorText,
  normalizeAgent,
  useArchiveAgentIdentityMutation,
  useFetchAgentIdentityQuery,
  useListAgentInstancesQuery,
  type AgentRecord,
} from '../../api/endpoints/agents';
import PaginatedMemoriesSection from '../shared/PaginatedMemoriesSection';
import { buildRouteHash } from '../../utils/appLocation';
import {
  VERB_LABEL,
  absoluteTime,
  agentEditHref,
  agentState,
  agentTitle,
  navigateTo,
  relativeTime,
  stateLabel,
  stateTone,
  verbsForState,
  type AgentVerb,
} from './agentModel';

/* ------------------------------------------------------------------ *
 * ResizeObserver-based wide detection (copied from ProjectDetail)
 * ------------------------------------------------------------------ */

export function usePaneIsWide(ref: React.RefObject<HTMLElement | null>): boolean {
  const [wide, setWide] = React.useState(false);
  React.useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const observer = new ResizeObserver((entries) => {
      setWide((entries[0]?.contentRect.width ?? 0) >= 900);
    });
    observer.observe(el);
    return () => observer.disconnect();
  }, [ref]);
  return wide;
}

/* ------------------------------------------------------------------ *
 * Data + verbs
 * ------------------------------------------------------------------ */

export function useAgentDetail(agentId: string, onAfterVerb?: (verb: AgentVerb) => void) {
  const query = useFetchAgentIdentityQuery({ agentId }, { skip: !agentId });
  const [archiveAgent] = useArchiveAgentIdentityMutation();
  const [busy, setBusy] = React.useState<AgentVerb | ''>('');
  const [actionError, setActionError] = React.useState('');

  const record: AgentRecord | null = React.useMemo(() => {
    const raw = query.data?.agent;
    return raw ? normalizeAgent(raw) : null;
  }, [query.data]);

  const runVerb = React.useCallback(
    async (verb: AgentVerb) => {
      if (verb === 'edit') {
        navigateTo(agentEditHref(agentId));
        return;
      }
      setBusy(verb);
      setActionError('');
      try {
        await archiveAgent({ agentId }).unwrap();
        onAfterVerb?.(verb);
      } catch (err) {
        setActionError(agentErrorText(err, `Couldn't ${VERB_LABEL[verb].toLowerCase()} this agent.`));
      } finally {
        setBusy('');
      }
    },
    [archiveAgent, onAfterVerb, agentId],
  );

  return { query, record, busy, actionError, runVerb };
}

/* ------------------------------------------------------------------ *
 * Copy-to-clipboard helper
 * ------------------------------------------------------------------ */

export function CopyButton({ value, label, debugId }: { value: string; label: string; debugId: string }) {
  const [copied, setCopied] = React.useState(false);
  return (
    <IconButton
      icon={copied ? 'check' : 'copy'}
      size="sm"
      label={copied ? 'Copied' : label}
      data-debug-id={debugId}
      onClick={() => {
        void navigator.clipboard?.writeText(value).then(() => {
          setCopied(true);
          window.setTimeout(() => setCopied(false), 1500);
        });
      }}
    />
  );
}

/* ------------------------------------------------------------------ *
 * Header
 * ------------------------------------------------------------------ */

export function AgentDetailActions({
  record,
  busy,
  onVerb,
}: {
  record: AgentRecord;
  busy: AgentVerb | '';
  onVerb: (verb: AgentVerb) => void;
}) {
  const verbs = verbsForState(agentState(record));
  const menuVerbs = verbs.filter((verb) => verb !== 'edit');

  return (
    <>
      {verbs.includes('edit') ? (
        <span className="hidden md:contents">
          <ActionButton
            label="Edit"
            variant="primary"
            data-debug-id="agent-view-edit"
            onClick={() => onVerb('edit')}
          />
        </span>
      ) : null}
      {menuVerbs.length ? (
        <Menu
          label="Agent actions"
          align="end"
          trigger={
            <ActionButton
              icon="more-horizontal"
              label="More"
              iconOnly
              aria-label="Agent actions"
              data-debug-id="agent-view-menu"
            />
          }
        >
          {menuVerbs.map((verb) => (
            <MenuItem
              key={verb}
              danger={verb === 'archive'}
              data-debug-id={`agent-view-${verb}`}
              onClick={() => onVerb(verb)}
            >
              {VERB_LABEL[verb]}
            </MenuItem>
          ))}
        </Menu>
      ) : null}
    </>
  );
}

/** The meta line under the title: provider · tier · state · Updated <relative>. */
export function AgentDetailMeta({ record }: { record: AgentRecord }) {
  const state = agentState(record);
  return (
    <div className="flex flex-wrap items-center gap-2" data-debug-id="agent-view-meta">
      {record.defaultProvider ? <Badge data-debug-id="agent-view-provider">{record.defaultProvider}</Badge> : null}
      {record.defaultTier ? <Badge data-debug-id="agent-view-tier">{record.defaultTier}</Badge> : null}
      {state === 'archived' ? (
        <StatusPill tone={stateTone(state)} data-debug-id="agent-view-state">{stateLabel(state)}</StatusPill>
      ) : null}
      <Text as="span" role="body-sm" tone="muted" title={absoluteTime(record.updatedAt)}>
        Updated {relativeTime(record.updatedAt)}
      </Text>
    </div>
  );
}

/* ------------------------------------------------------------------ *
 * Cards
 * ------------------------------------------------------------------ */

function Card({
  title,
  helper,
  action,
  children,
  debugId,
}: {
  title: string;
  helper?: string;
  action?: React.ReactNode;
  children: React.ReactNode;
  debugId: string;
}) {
  return (
    <Panel data-debug-id={debugId} className="p-4">
      <div className="mb-2 flex items-start justify-between gap-3">
        <div className="min-w-0">
          <Text as="div" role="title">{title}</Text>
          {helper ? <Text as="div" role="body-sm" tone="muted" className="ui-measure">{helper}</Text> : null}
        </div>
        {action ? <div className="shrink-0">{action}</div> : null}
      </div>
      {children}
    </Panel>
  );
}

function DetailRow({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <Text as="div" role="label" tone="muted">{label}</Text>
      {children}
    </div>
  );
}

/** One linked-resource list — degrades rather than errors (same as ProjectDetail). */
function LinkedList({
  items,
  loading,
  failed,
  emptyLabel,
  debugId,
}: {
  items: { id: string; label: string; sub?: string; href: string }[];
  loading: boolean;
  failed: boolean;
  emptyLabel: string;
  debugId: string;
}) {
  if (loading) {
    return (
      <div className="flex items-center gap-2" data-debug-id={`${debugId}-loading`}>
        <Spinner size="sm" />
        <Text as="span" role="body-sm" tone="muted">Loading…</Text>
      </div>
    );
  }
  if (failed) {
    return (
      <Text as="div" role="body-sm" tone="muted" data-debug-id={`${debugId}-failed`}>
        Couldn&apos;t load these right now.
      </Text>
    );
  }
  if (items.length === 0) {
    return (
      <Text as="div" role="body-sm" tone="muted" data-debug-id={`${debugId}-empty`}>
        {emptyLabel}
      </Text>
    );
  }
  return (
    <ul className="flex flex-col" data-debug-id={debugId}>
      {items.map((item) => (
        <li key={item.id} className="border-t border-subtle py-1.5 first:border-0 first:pt-0">
          <a
            href={item.href}
            data-debug-id={`${debugId}-${item.id}`}
            className="flex min-w-0 flex-col rounded-[var(--radius-sm)] focus-visible:shadow-focus focus-visible:outline-none"
          >
            <Text as="span" role="body-sm" className="truncate">{item.label}</Text>
            {item.sub ? <Text as="span" role="caption" tone="muted" className="truncate">{item.sub}</Text> : null}
          </a>
        </li>
      ))}
    </ul>
  );
}

const LINKED_PREVIEW = 5;

function InstancesCard({ agentId }: { agentId: string }) {
  const instancesQuery = useListAgentInstancesQuery({ agentId, limit: LINKED_PREVIEW }, { skip: !agentId });
  const rawInstances = (instancesQuery.data?.instances || []).slice(0, LINKED_PREVIEW);

  const instances = rawInstances.map((inst: any) => ({
    id: String(inst.agent_instance_id || inst.agentInstanceId || inst.id || ''),
    label: String(inst.agent_instance_id || inst.agentInstanceId || inst.id || '').slice(0, 24),
    sub: String(inst.runtime_status || inst.runtimeStatus || ''),
    href: buildRouteHash(`/chains/${encodeURIComponent(String(inst.chain_id || inst.chainId || ''))}`, ''),
  }));

  return (
    <Card
      title="Instances"
      helper="Currently running and recently stopped instances."
      debugId="agent-view-instances-card"
    >
      <LinkedList
        items={instances}
        loading={instancesQuery.isLoading}
        failed={Boolean(instancesQuery.error)}
        emptyLabel="No instances right now."
        debugId="agent-view-instances"
      />
    </Card>
  );
}

/* ------------------------------------------------------------------ *
 * The body
 * ------------------------------------------------------------------ */

export function AgentDetailBody({
  record,
  actionError,
  wide,
}: {
  record: AgentRecord;
  actionError?: string;
  wide: boolean;
}) {
  const instructions = record.instructions;

  const main = (
    <>
      <Card title="Instructions" debugId="agent-view-instructions-card">
        {instructions ? (
          <MarkdownBody source={instructions} copyAll={false} data-debug-id="agent-view-instructions" />
        ) : (
          <Text as="div" role="body-sm" tone="muted" data-debug-id="agent-view-instructions-empty">
            No instructions set.
          </Text>
        )}
      </Card>

      <InstancesCard agentId={record.agentId} />
    </>
  );

  const rail = (
    <Card title="Details" debugId="agent-view-details-card">
      <div className="flex flex-col gap-2">
        {record.defaultProvider ? (
          <DetailRow label="Provider">
            <Text as="div" role="body-sm">{record.defaultProvider}</Text>
          </DetailRow>
        ) : null}
        {record.defaultTier ? (
          <DetailRow label="Tier">
            <Text as="div" role="body-sm">{record.defaultTier}</Text>
          </DetailRow>
        ) : null}
        {record.templateId ? (
          <DetailRow label="Template">
            <Text as="div" role="body-sm" className="font-mono">{record.templateId}</Text>
          </DetailRow>
        ) : null}
        <DetailRow label="Slug">
          <Text as="div" role="body-sm" className="font-mono">{record.slug || '—'}</Text>
        </DetailRow>
        <DetailRow label="Updated">
          <Text as="div" role="body-sm">{`${absoluteTime(record.updatedAt)} (${relativeTime(record.updatedAt)})`}</Text>
        </DetailRow>
        <DetailRow label="Agent ID">
          <div className="flex items-center gap-2">
            <Text as="span" role="body-sm" className="font-mono">{record.agentId}</Text>
            <CopyButton value={record.agentId} label="Copy agent ID" debugId="agent-view-copy-id" />
          </div>
        </DetailRow>
      </div>
    </Card>
  );

  return (
    <div data-debug-id="agent-view-page" className="flex w-full min-w-0 flex-col gap-3">
      {actionError ? <Alert tone="danger" title="That didn't work">{actionError}</Alert> : null}
      {agentState(record) === 'archived' ? (
        <Alert tone="warning" title="This agent is archived">
          It still works — running instances and memories are untouched. Heimdall can&apos;t un-archive from here.
        </Alert>
      ) : null}
      {wide ? (
        <div className="flex min-w-0 items-start gap-3">
          <div className="flex min-w-0 flex-1 flex-col gap-3">{main}</div>
          <div className="flex w-[320px] shrink-0 flex-col gap-3">{rail}</div>
        </div>
      ) : (
        <>
          {main}
          {rail}
        </>
      )}
      {/* Amendment 9: Agent→Memories link kept. Full-width below the layout so the
          intersection-observer sentinel lives in the page's main scroll flow. */}
      <PaginatedMemoriesSection agentId={record.agentId} debugPrefix="agent-view-memories" />
    </div>
  );
}

/**
 * The mobile action bar: Edit, full width, docked above the app's bottom tab nav.
 * Archive is NOT here — destructive verbs stay in the `…` menu.
 */
export function AgentDetailMobileActions({
  record,
  onVerb,
}: {
  record: AgentRecord;
  onVerb: (verb: AgentVerb) => void;
}) {
  if (!verbsForState(agentState(record)).includes('edit')) return null;
  return (
    <div
      className="fixed bottom-0 left-0 right-0 z-sticky border-t border-subtle bg-surface px-4 pb-[max(var(--ui-bottom-chrome,0px),env(safe-area-inset-bottom,0px))] pt-2 md:hidden"
      data-debug-id="agent-view-mobile-bar"
    >
      <Button
        variant="primary"
        width="full"
        data-debug-id="agent-view-mobile-edit"
        onClick={() => onVerb('edit')}
      >
        Edit
      </Button>
    </div>
  );
}

/**
 * Skeleton for the two-pane pane while the detail query is loading.
 * Mirrors the real layout's card structure so there is no shift on load.
 */
export function AgentDetailPaneSkeleton() {
  return (
    <div className="flex flex-col gap-3" role="status" aria-busy="true" data-debug-id="agent-pane-skeleton">
      <span className="sr-only">Loading agent…</span>
      <div className="h-6 w-2/3 animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
      <div className="h-4 w-1/2 animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
      <div className="mt-2 flex flex-col gap-2">
        {[0, 1, 2].map((i) => (
          <div key={i} className="h-4 w-full animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
        ))}
      </div>
    </div>
  );
}
