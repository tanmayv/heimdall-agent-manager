import { heimdallApi, withSessionQuery } from '../heimdallApi';

// UI-12 / UI-18 / SEARCH-5: global entity search via GET /api/v1/search.
// Response groups hits by resource type; each hit carries the SEARCH-2 clean
// shape: id/label/sublabel/score/route plus nested parent {id,type} (null for
// top-level entities), a preview snippet, and matched_field. The `route` field
// is the navigation target (e.g. `/chains/:chain_id/tasks/:task_id` for a
// comment, `/skills/:slug` for a skill).

export type SearchParent = { id: string; type: string };

export type SearchHit = {
  id: string;
  label: string;
  sublabel?: string;
  score?: number;
  route?: string;
  type?: string;
  // SEARCH-2 clean shape (no back-compat): nested parent, preview, matched field.
  parent?: SearchParent | null;
  preview?: string;
  matchedField?: string;
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

export type GlobalSearchArg = {
  q: string;
  types?: string;
  scopeIds?: string;
  exclude?: string;
  limit?: number;
  cursor?: string;
};

function normalizeParent(raw: any): SearchParent | null {
  const parent = raw?.parent;
  if (!parent || typeof parent !== 'object') return null;
  const id = String(parent.id || '');
  const type = String(parent.type || '');
  if (!id && !type) return null;
  return { id, type };
}

function normalizeHit(raw: any, type: string): SearchHit {
  return {
    id: String(raw?.id || raw?.resource_id || ''),
    label: String(raw?.label || raw?.title || raw?.name || ''),
    sublabel: raw?.sublabel || raw?.subtitle || undefined,
    score: raw?.score !== undefined ? Number(raw.score) : undefined,
    route: raw?.route || undefined,
    type,
    parent: normalizeParent(raw),
    preview: raw?.preview ? String(raw.preview) : undefined,
    matchedField: raw?.matched_field ? String(raw.matched_field) : undefined,
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
    globalSearch: build.query<SearchResponse, GlobalSearchArg>({
      queryFn: withSessionQuery(async ({ q, types, scopeIds, exclude, limit = 20, cursor }, { session }) => {
        // Empty/whitespace q returns empty (per UI-BE-5); skip the network call.
        const query = String(q || '').trim();
        if (!query || !session?.daemonUrl || !session?.clientToken) {
          return { groups: [], hits: [], hasMore: false, nextCursor: null };
        }
        const params = new URLSearchParams({ q: query, limit: String(limit) });
        if (types) params.set('types', types);
        if (scopeIds) params.set('scope_ids', scopeIds);
        if (exclude) params.set('exclude', exclude);
        if (cursor) params.set('cursor', cursor);
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

// useGlobalSearchQuery: debounced first-page search-as-you-type (RTK Query keeps
// only the latest arg and cancels superseded requests).
// useLazyGlobalSearchQuery: on-demand "load more" — the palette calls it with the
// previous page's nextCursor and appends the returned hits.
export const { useGlobalSearchQuery, useLazyGlobalSearchQuery } = searchApi;
