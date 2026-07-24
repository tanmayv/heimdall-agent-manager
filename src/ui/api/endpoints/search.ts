import { heimdallApi, withSessionQuery } from '../heimdallApi';

// UI-12 / UI-18: global entity search via GET /api/v1/search (Hub rewrite route).
// Response groups hits by resource type; each hit carries id/label/sublabel/
// score/route. The `route` field is the navigation target (e.g.
// `/library/artifacts/:artifact_id`, `/chains/:chain_id`).

export type SearchHit = {
  id: string;
  label: string;
  sublabel?: string;
  score?: number;
  route?: string;
  type?: string;
};

export type SearchGroup = {
  type: string;
  hits: SearchHit[];
};

export type SearchResponse = {
  groups: SearchGroup[];
  hits: SearchHit[];
  hasMore: boolean;
  nextCursor?: string | null;
};

function normalizeHit(raw: any, type: string): SearchHit {
  return {
    id: String(raw?.id || raw?.resource_id || ''),
    label: String(raw?.label || raw?.title || raw?.name || ''),
    sublabel: raw?.sublabel || raw?.subtitle || undefined,
    score: raw?.score !== undefined ? Number(raw.score) : undefined,
    route: raw?.route || undefined,
    type,
  };
}

function normalizeSearch(data: any): SearchResponse {
  const groupsRaw = data?.groups || [];
  const groups: SearchGroup[] = Array.isArray(groupsRaw)
    ? groupsRaw.map((g: any) => ({
        type: String(g?.type || ''),
        hits: (Array.isArray(g?.hits) ? g.hits : []).map((h: any) => normalizeHit(h, String(g?.type || ''))),
      }))
    : [];
  // Flatten for convenience (entity search across all groups).
  const hits: SearchHit[] = groups.flatMap((g) => g.hits);
  return {
    groups,
    hits,
    hasMore: Boolean(data?.has_more ?? data?.page?.has_more),
    nextCursor: data?.next_cursor ?? data?.page?.next_cursor ?? null,
  };
}

export const searchApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    globalSearch: build.query<SearchResponse, { q: string; types?: string; limit?: number }>({
      queryFn: withSessionQuery(async ({ q, types, limit = 20 }, { session }) => {
        // Empty/whitespace q returns empty (per UI-BE-5); skip the network call.
        const query = String(q || '').trim();
        if (!query || !session?.daemonUrl || !session?.clientToken) {
          return { groups: [], hits: [], hasMore: false, nextCursor: null };
        }
        const params = new URLSearchParams({ q: query, limit: String(limit) });
        if (types) params.set('types', types);
        const res = await fetch(`${session.daemonUrl.replace(/\/$/, '')}/api/v1/search?${params.toString()}`, {
          headers: { Authorization: `Bearer ${session.clientToken}` },
        });
        if (!res.ok) {
          throw new Error(`Search failed (${res.status})`);
        }
        const json = await res.json();
        // The Hub wraps data under `data`; normalize either shape.
        return normalizeSearch(json?.data || json);
      }),
    }),
  }),
});

export const { useGlobalSearchQuery } = searchApi;
