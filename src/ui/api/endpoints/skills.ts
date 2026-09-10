import { heimdallApi, withSessionQuery } from '../heimdallApi';

// SEARCH-5: read a single compiled-in skill (slug + SKILL.md contents) for the
// /skills/:slug viewer. Backed by the read-only GET /api/v1/skills/:slug hub
// endpoint. Skills are global (owner-independent) but a valid token is required.

export type Skill = {
  slug: string;
  content: string;
};

export const skillsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    getSkill: build.query<Skill, { slug: string }>({
      queryFn: withSessionQuery(async ({ slug }, { session }) => {
        const s = String(slug || '').trim();
        if (!s || !session?.daemonUrl || !session?.clientToken) {
          return { slug: s, content: '' };
        }
        const res = await fetch(`${session.daemonUrl.replace(/\/$/, '')}/api/v1/skills/${encodeURIComponent(s)}`, {
          headers: { Authorization: `Bearer ${session.clientToken}` },
        });
        if (!res.ok) {
          throw new Error(`Skill fetch failed (${res.status})`);
        }
        const json = await res.json();
        const data = json?.data ?? json;
        return { slug: String(data?.slug || s), content: String(data?.content || '') };
      }),
    }),
  }),
});

export const { useGetSkillQuery } = skillsApi;
