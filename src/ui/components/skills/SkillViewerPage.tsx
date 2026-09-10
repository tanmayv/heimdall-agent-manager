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
    <div data-debug-id="skill-viewer-page" className="w-full max-w-3xl">
      <div className="mb-3 flex items-center gap-2">
        <span className="rounded-full border border-white/10 bg-white/[0.04] px-2 py-0.5 text-[11px] uppercase tracking-[0.16em] text-zinc-500">skill</span>
        <h1 className="truncate text-lg font-semibold text-zinc-100">{slug}</h1>
      </div>
      {isFetching ? (
        <div data-debug-id="skill-viewer-loading" className="text-sm text-zinc-500">Loading…</div>
      ) : isError ? (
        <div data-debug-id="skill-viewer-error" className="text-sm text-rose-300">Could not load this skill.</div>
      ) : data && data.content ? (
        <div className="rounded-2xl border border-white/10 bg-white/[0.02] p-4">
          <Markdown source={data.content} data-debug-id="skill-viewer-markdown" />
        </div>
      ) : (
        <div data-debug-id="skill-viewer-empty" className="text-sm text-zinc-500">No content for this skill.</div>
      )}
    </div>
  );
}
