/**
 * PaginatedMemoriesSection — full-width paginated memory list for view pages.
 * ------------------------------------------------------------------
 * Rendered BELOW the two-col layout in both AgentDetailBody and ProjectDetailBody,
 * spanning full width in all viewport sizes. The sentinel div lives in the PAGE's
 * main scroll flow — never in a nested scroller.
 *
 * Pass exactly one of `agentId` or `projectId`.
 */
import React from 'react';
import { Alert, Button, Link, Panel, Spinner, Text, useInfiniteList } from '@ui';
import { buildRouteHash } from '../../utils/appLocation';
import { fetchMemoryPage } from '../../api/endpoints/memory';

const PAGE_SIZE = 25;

export default function PaginatedMemoriesSection({
  agentId,
  projectId,
  debugPrefix = 'memories-section',
}: {
  agentId?: string;
  projectId?: string;
  debugPrefix?: string;
}) {
  const filterKey = agentId ? `agent:${agentId}` : `project:${projectId}`;
  const allMemoryHref = agentId
    ? buildRouteHash('/memory', `agent=${encodeURIComponent(agentId)}`)
    : buildRouteHash('/memory', `project=${encodeURIComponent(projectId || '')}`);

  const list = useInfiniteList<any>({
    fetchPage: ({ cursor, signal }) =>
      fetchMemoryPage({
        agentId: agentId || undefined,
        projectId: projectId || undefined,
        limit: PAGE_SIZE,
        cursor,
        signal,
      }),
    getItemId: (row) => String(row.memoryId || row.id || ''),
    // Memory's cursor column is `updated_at`; getCursorValue is used only for
    // change-detection (N-new pill probe), not for keyset navigation — the envelope's
    // `next_cursor` drives paging.
    getCursorValue: (row) => String(row.updatedAt || ''),
    resetKey: filterKey,
  });

  const header = (
    <div className="mb-2 flex items-start justify-between gap-3">
      <Text as="div" role="title">Memory</Text>
      <Link href={allMemoryHref} data-debug-id={`${debugPrefix}-all`}>All memory</Link>
    </div>
  );

  if (list.isLoadingInitial) {
    return (
      <Panel data-debug-id={`${debugPrefix}-card`} className="p-4">
        {header}
        <div className="flex items-center gap-2" data-debug-id={`${debugPrefix}-loading`}>
          <Spinner size="sm" />
          <Text as="span" role="body-sm" tone="muted">Loading…</Text>
        </div>
      </Panel>
    );
  }

  if (list.error && list.items.length === 0) {
    return (
      <Panel data-debug-id={`${debugPrefix}-card`} className="p-4">
        {header}
        <Text as="div" role="body-sm" tone="muted" data-debug-id={`${debugPrefix}-failed`}>
          Couldn&apos;t load memories right now.
        </Text>
      </Panel>
    );
  }

  return (
    <Panel data-debug-id={`${debugPrefix}-card`} className="p-4">
      {header}
      {list.items.length === 0 ? (
        <Text as="div" role="body-sm" tone="muted" data-debug-id={`${debugPrefix}-empty`}>
          No memories scoped to this {agentId ? 'agent' : 'project'}.
        </Text>
      ) : (
        <ul className="flex flex-col" data-debug-id={`${debugPrefix}-list`}>
          {list.items.map((item: any) => {
            const id = String(item.memoryId || item.id || '');
            const label = String(item.title || item.body || id).slice(0, 120);
            const sub = String(item.type || '');
            const href = buildRouteHash(`/memory/${encodeURIComponent(id)}`, '');
            return (
              <li key={id} className="border-t border-subtle py-1.5 first:border-0 first:pt-0">
                <a
                  href={href}
                  data-debug-id={`${debugPrefix}-item-${id}`}
                  className="flex min-w-0 flex-col rounded-[var(--radius-sm)] focus-visible:shadow-focus focus-visible:outline-none"
                >
                  <Text as="span" role="body-sm" className="truncate">{label}</Text>
                  {sub ? <Text as="span" role="caption" tone="muted" className="truncate">{sub}</Text> : null}
                </a>
              </li>
            );
          })}
        </ul>
      )}

      {/* Paging skeleton */}
      {list.isPaging ? (
        <div data-debug-id={`${debugPrefix}-paging`} aria-hidden="true" className="flex flex-col gap-2 py-3">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-5 w-full animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
          ))}
        </div>
      ) : null}

      {/* Paging error */}
      {list.pagingError ? (
        <div data-debug-id={`${debugPrefix}-paging-error`} className="py-3">
          <Alert tone="danger" title="Couldn't load more memories">
            <div className="flex items-center gap-3">
              <span>Something went wrong loading more memories.</span>
              <Button size="sm" variant="secondary" onClick={() => list.loadMore()}>Retry</Button>
            </div>
          </Alert>
        </div>
      ) : null}

      {/* Intersection-observer sentinel — must be in the PAGE's scroll flow, never in a nested scroll container. */}
      {list.hasMore && !list.pagingError ? (
        <div ref={list.sentinelRef} data-debug-id={`${debugPrefix}-sentinel`} className="h-px w-full" />
      ) : null}
    </Panel>
  );
}
