/**
 * ActionViewPage — `/actions/:id` as a standalone page.
 * ------------------------------------------------------------------
 * Modeled after AgentViewPage.
 *
 * At >=1024 this route hands off to the list page, which renders list + pane, so a
 * pasted `/actions/:id` link and a click on a row land in the same place and one
 * action never has two URLs.
 */
import React from 'react';
import { Button, EmptyState, Icon, PageShell, Text, useViewport } from '@ui';
import ActionListPage from './ActionListPage';
import {
  ActionDetailActions,
  ActionDetailBody,
  ActionDetailMeta,
  ActionDetailMobileActions,
  useActionDetail,
  usePaneIsWide,
} from './ActionDetail';
import {
  actionErrorText,
  actionListHref,
  actionTitle,
  detailCrumbs,
  navigateTo,
  parseActionListUrl,
  viewCrumbs,
} from './actionModel';
import { getRouteSearch } from '../../utils/appLocation';

export default function ActionViewPage({ actionId }: { actionId: string }) {
  const viewport = useViewport();
  const listState = React.useMemo(() => parseActionListUrl(getRouteSearch()), []);
  const { query, record, busy, actionError, runNotice, runVerb } = useActionDetail(actionId, (verb) => {
    // A deleted action has no page left to stand on.
    if (verb === 'delete') navigateTo(actionListHref(listState));
  });
  const paneRef = React.useRef<HTMLDivElement | null>(null);
  const wide = usePaneIsWide(paneRef);

  // At >=1024 the detail belongs in the list's right-hand pane.
  if (viewport === 'desktop') {
    return <ActionListPage selectedId={actionId} />;
  }

  if (query.isLoading) {
    return <PageShell rhythm="banded" title="Actions" breadcrumbs={viewCrumbs('Loading…')} loading />;
  }

  if (query.error || !record) {
    return (
      <PageShell rhythm="banded" title="Actions" breadcrumbs={viewCrumbs('Not found')}>
        <EmptyState
          data-debug-id="action-view-missing"
          icon="search"
          title="That action doesn't exist"
          description={query.error ? actionErrorText(query.error) : undefined}
          action={<Button variant="secondary" onClick={() => navigateTo(actionListHref())}>Back to Actions</Button>}
        />
      </PageShell>
    );
  }

  const title = actionTitle(record);

  return (
    <PageShell
      rhythm="banded"
      width="content"
      title={title}
      breadcrumbs={detailCrumbs(title, record, listState)}
      description={<ActionDetailMeta record={record} />}
      actions={<ActionDetailActions record={record} busy={busy} onVerb={(verb) => void runVerb(verb)} />}
    >
      <div ref={paneRef} className="min-w-0">
        {viewport === 'mobile' ? (
          <a
            href={actionListHref(listState)}
            data-debug-id="action-view-back"
            className="mb-2 inline-flex items-center gap-1 rounded-[var(--radius-sm)] focus-visible:shadow-focus focus-visible:outline-none"
          >
            <Icon name="arrow-left" size="sm" aria-hidden="true" />
            <Text as="span" role="body-sm" tone="muted">Actions</Text>
          </a>
        ) : null}

        <ActionDetailBody record={record} actionError={actionError} runNotice={runNotice} wide={wide} />

        <div
          aria-hidden="true"
          className="md:hidden"
          style={{ height: 'calc(3.5rem + max(var(--ui-bottom-chrome, 0px), env(safe-area-inset-bottom, 0px)))' }}
        />
      </div>

      <ActionDetailMobileActions record={record} onVerb={(verb) => void runVerb(verb)} />
    </PageShell>
  );
}
