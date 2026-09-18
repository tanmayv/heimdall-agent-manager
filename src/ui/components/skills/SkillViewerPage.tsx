import { PageShell } from '@ui';
import { useGetSkillQuery } from '../../api/endpoints/skills';
import Markdown from '../Markdown';

// SEARCH-5: read-only viewer for a compiled-in skill, reached from a skill hit
// in the command palette (route /skills/:slug). Renders the SKILL.md as markdown.

type SkillViewerPageProps = {
  slug: string;
};

export default function SkillViewerPage({ slug }: SkillViewerPageProps) {
  const { data, isFetching, isError } = useGetSkillQuery({ slug }, { skip: !slug });

  return (
    <PageShell eyebrow="Skill" title={slug}>
      {isFetching ? (
        <div data-debug-id="skill-viewer-loading" className="text-sm text-faint">Loading…</div>
      ) : isError ? (
        <div data-debug-id="skill-viewer-error" className="text-sm text-danger">Could not load this skill.</div>
      ) : data && data.content ? (
        <div className="rounded-2xl border border-subtle bg-surface p-4">
          <Markdown source={data.content} data-debug-id="skill-viewer-markdown" />
        </div>
      ) : (
        <div data-debug-id="skill-viewer-empty" className="text-sm text-faint">No content for this skill.</div>
      )}
    </PageShell>
  );
}
