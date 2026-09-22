/**
 * ShellViewPage — `/shells/:id` as a standalone page.
 * ------------------------------------------------------------------
 * Modeled after ActionViewPage.
 *
 * At >=1024 this route hands off to the list page, which renders list + pane, so a
 * pasted `/shells/:id` link and a click on a row land in the same place and one
 * session never has two URLs.
 *
 * There is no edit route to offer (REQ-UI-15): shells are runtime.
 */
import React from 'react';
import { Button, EmptyState, Icon, PageShell, Text, useViewport } from '@ui';
import ShellListPage from './ShellListPage';
import {
  ShellDetailActions,
  ShellDetailBody,
  ShellDetailMeta,
  ShellDetailMobileActions,
  ShellDetailOverlays,
  useShellDetail,
  usePaneIsWide,
} from './ShellDetail';
import {
  detailCrumbs,
  navigateTo,
  parseShellListUrl,
  shellErrorText,
  shellListHref,
  shellTitle,
  viewCrumbs,
} from './shellModel';
import { getRouteSearch } from '../../utils/appLocation';

export default function ShellViewPage({ sessionId }: { sessionId: string }) {
  const viewport = useViewport();
  const listState = React.useMemo(() => parseShellListUrl(getRouteSearch()), []);
  const detail = useShellDetail(sessionId);
  const paneRef = React.useRef<HTMLDivElement | null>(null);
  const wide = usePaneIsWide(paneRef);

  // At >=1024 the detail belongs in the list's right-hand pane.
  if (viewport === 'desktop') {
    return <ShellListPage selectedId={sessionId} />;
  }

  const { query, record, busy, actionError, notice, runVerb } = detail;

  if (query.isLoading) {
    return <PageShell rhythm="banded" title="Shells" breadcrumbs={viewCrumbs('Loading…')} loading />;
  }

  if (query.error || !record) {
    return (
      <PageShell rhythm="banded" title="Shells" breadcrumbs={viewCrumbs('Not found')}>
        <EmptyState
          data-debug-id="shell-view-missing"
          icon="search"
          title="That shell session doesn't exist"
          description={
            query.error
              ? shellErrorText(query.error)
              : 'It may have been reaped — a session record does not outlive its bridge forever.'
          }
          action={<Button variant="secondary" onClick={() => navigateTo(shellListHref())}>Back to Shells</Button>}
        />
      </PageShell>
    );
  }

  const title = shellTitle(record);

  return (
    <PageShell
      rhythm="banded"
      width="content"
      title={title}
      breadcrumbs={detailCrumbs(title, record, listState)}
      description={<ShellDetailMeta record={record} />}
      actions={<ShellDetailActions record={record} busy={busy} onVerb={runVerb} />}
    >
      <div ref={paneRef} className="min-w-0">
        {viewport === 'mobile' ? (
          <a
            href={shellListHref(listState)}
            data-debug-id="shell-view-back"
            className="mb-2 inline-flex items-center gap-1 rounded-[var(--radius-sm)] focus-visible:shadow-focus focus-visible:outline-none"
          >
            <Icon name="arrow-left" size="sm" aria-hidden="true" />
            <Text as="span" role="body-sm" tone="muted">Shells</Text>
          </a>
        ) : null}

        <ShellDetailBody
          record={record}
          actionError={actionError}
          notice={notice}
          wide={wide}
          onVerb={runVerb}
        />

        {/* Clearance for the sticky bar, measured rather than guessed. */}
        <div
          aria-hidden="true"
          className="md:hidden"
          style={{ height: 'calc(3.5rem + max(var(--ui-bottom-chrome, 0px), env(safe-area-inset-bottom, 0px)))' }}
        />
      </div>

      <ShellDetailMobileActions record={record} onVerb={runVerb} />
      <ShellDetailOverlays
        confirm={detail.confirm}
        onResolve={detail.resolveConfirm}
        portSession={record}
        portDialogOpen={detail.portDialogOpen}
        onClosePortDialog={detail.closePortDialog}
        busy={busy}
      />
    </PageShell>
  );
}
