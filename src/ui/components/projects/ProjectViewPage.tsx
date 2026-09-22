/**
 * ProjectViewPage — `/projects/:id` as a standalone page.
 * ------------------------------------------------------------------
 * Read-only (REQ-UI-11): every mutation is a verb in the header, the mobile action
 * bar, or a trip to `/projects/:id/edit`. The guts live in `ProjectDetail.tsx`,
 * because the same detail also renders as the right-hand pane of the two-pane list
 * at >=1024 — one implementation, so the page and the pane cannot drift apart.
 *
 * At >=1024 this route hands off to the list page, which renders list + pane, so a
 * pasted `/projects/:id` link and a click on a row land in the same place and one
 * project never has two URLs. Below that, this page is the detail.
 *
 * `description` renders as markdown because that is how it is authored; `name`
 * stays plain text — it is a row label, a breadcrumb and a search label.
 */
import React from 'react';
import { Button, EmptyState, Icon, PageShell, Text, useViewport } from '@ui';
import { projectErrorText } from '../../api/endpoints/projects';
import ProjectListPage from './ProjectListPage';
import {
  ProjectDetailActions,
  ProjectDetailBody,
  ProjectDetailMeta,
  ProjectDetailMobileActions,
  useProjectDetail,
  usePaneIsWide,
} from './ProjectDetail';
import {
  detailCrumbs,
  navigateTo,
  parseProjectListUrl,
  projectListHref,
  projectState,
  projectTitle,
  viewCrumbs,
} from './projectModel';
import { getRouteSearch } from '../../utils/appLocation';

export default function ProjectViewPage({ projectId }: { projectId: string }) {
  const viewport = useViewport();
  const { query, record, busy, actionError, runVerb } = useProjectDetail(projectId);
  const paneRef = React.useRef<HTMLDivElement | null>(null);
  const wide = usePaneIsWide(paneRef);
  // The trail's terminal tab comes from the URL the user arrived with; a pasted
  // link carries none, and `detailCrumbs` falls back to the tab the record's own
  // state belongs to rather than rendering an empty crumb.
  const listState = React.useMemo(() => parseProjectListUrl(getRouteSearch()), []);

  // At >=1024 the detail belongs in the list's right-hand pane. The ROUTE is
  // unchanged. Every hook above runs first, so this early return cannot reorder
  // them.
  if (viewport === 'desktop') {
    return <ProjectListPage selectedId={projectId} />;
  }

  if (query.isLoading) {
    return <PageShell rhythm="banded" title="Projects" breadcrumbs={viewCrumbs('Loading…')} loading />;
  }

  if (query.error || !record) {
    return (
      <PageShell rhythm="banded" title="Projects" breadcrumbs={viewCrumbs('Not found')}>
        <EmptyState
          data-debug-id="project-view-missing"
          icon="search"
          title="That project doesn't exist"
          description={query.error ? projectErrorText(query.error) : undefined}
          action={<Button variant="secondary" onClick={() => navigateTo(projectListHref())}>Back to Projects</Button>}
        />
      </PageShell>
    );
  }

  const title = projectTitle(record);

  return (
    <PageShell
      rhythm="banded"
      width="content"
      title={title}
      // "Projects / Active" — ancestors only. `PageShell` promotes the terminal
      // crumb into the <h1>, so the title is never printed twice.
      breadcrumbs={detailCrumbs(title, projectState(record), listState)}
      description={<ProjectDetailMeta record={record} />}
      actions={<ProjectDetailActions record={record} busy={busy} onVerb={(verb) => void runVerb(verb)} />}
    >
      <div ref={paneRef} className="min-w-0">
        {/* Mobile: a back link, because the trail collapses to one step that matters. */}
        {viewport === 'mobile' ? (
          <a
            href={projectListHref(listState)}
            data-debug-id="project-view-back"
            className="mb-2 inline-flex items-center gap-1 rounded-[var(--radius-sm)] focus-visible:shadow-focus focus-visible:outline-none"
          >
            <Icon name="arrow-left" size="sm" aria-hidden="true" />
            <Text as="span" role="body-sm" tone="muted">Projects</Text>
          </a>
        ) : null}

        <ProjectDetailBody record={record} actionError={actionError} wide={wide} />

        {/* The bar is fixed, so the page needs room under it — plus the tab nav and
            the device's safe area — or the last card sits under the button. */}
        <div
          aria-hidden="true"
          className="md:hidden"
          style={{ height: 'calc(3.5rem + max(var(--ui-bottom-chrome, 0px), env(safe-area-inset-bottom, 0px)))' }}
        />
      </div>

      <ProjectDetailMobileActions record={record} onVerb={(verb) => void runVerb(verb)} />
    </PageShell>
  );
}
