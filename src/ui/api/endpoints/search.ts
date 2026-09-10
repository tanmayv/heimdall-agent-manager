import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch } from '../cookieFetch';

// UI-12 / UI-18 / SEARCH-5 / SEARCH-13: global entity search via GET /api/v1/search.
// The rewrite/web shell is served behind the trusted proxy and authenticates with
// the SAME cookie session as `/api/v1/me` (`credentials: 'include'`) — like
// sidebar/chats/artifacts — NOT the legacy per-client token session. So this uses
// the shared cookieFetch transport; the old withSessionQuery/daemonUrl+clientToken
// path fired no request in the cookie shell (its session has neither), which is
// why the command palette returned nothing (SEARCH-13).
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
  // For `message` hits (MSG-1/MSG-2): id=message_id, sublabel=conversation title,
  // preview=bracketed body snippet, route=/conversations/<agent_instance_id>, and
  // parent={id:<conversation/instance>, type:'conversation'}.
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
    // `snippet` is accepted as a defensive fallback for the message provider in
    // case it emits the body excerpt under that key instead of `preview`.
    preview: raw?.preview ? String(raw.preview) : raw?.snippet ? String(raw.snippet) : undefined,
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
      queryFn: async ({ q, types, exclude, limit = 20, cursor }) => {
        // Empty/whitespace q returns empty (per UI-BE-5); skip the network call so
        // an empty box never hits the endpoint. The palette only sends q/limit/cursor
        // today; types/exclude are forwarded when present (scope_ids dropped, SEARCH-8).
        const query = String(q || '').trim();
        if (!query) {
          return { data: { groups: [], hits: [], hasMore: false, nextCursor: null } };
        }
        try {
          const params = new URLSearchParams({ q: query, limit: String(limit) });
          if (types) params.set('types', types);
          if (exclude) params.set('exclude', exclude);
          if (cursor) params.set('cursor', cursor);
          // cookieJsonFetch => GET apiUrl('/search?…') with credentials:'include',
          // throwing on non-2xx and unwrapping `body.data` (the {groups,page} object).
          const data = await cookieJsonFetch(`/search?${params.toString()}`);
          return { data: normalizeSearch(data) };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error || 'Search failed') } as any };
        }
      },
    }),
  }),
});

// useGlobalSearchQuery: debounced first-page search-as-you-type (RTK Query keeps
// only the latest arg and cancels superseded requests).
// useLazyGlobalSearchQuery: on-demand "load more" — the palette calls it with the
// previous page's nextCursor and appends the returned hits.
export const { useGlobalSearchQuery, useLazyGlobalSearchQuery } = searchApi;
