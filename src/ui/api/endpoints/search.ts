import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetchEnvelope } from '../cookieFetch';

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
  // Optional typed parent-id scopes (CSV of ids). Forwarded to the backend's
  // allowlisted scope filters so a caller can constrain results to e.g. one
  // task chain or one conversation. Multiple positive scopes are AND-ed by the
  // backend, so pass the single dimension that yields the desired union — a
  // chain id already covers that chain's messages, tasks and comments.
  chainIds?: string;
  conversationIds?: string;
  taskIds?: string;
  projectIds?: string;
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

// `body` is the FULL response envelope: { data: { groups }, page: { has_more,
// next_cursor }, meta }. The groups live under `data`, and the pagination cursor
// under the SIBLING `page` — reading it off `data` (the pre-unwrap bug) left
// hasMore/nextCursor always empty, so "Load more" never fired. Tolerates a
// pre-unwrapped `data` object too (page then absent → no more pages).
function normalizeSearch(body: any): SearchResponse {
  const data = body?.data ?? body;
  const page = body?.page ?? data?.page ?? {};
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
    hasMore: Boolean(page?.has_more ?? data?.has_more),
    nextCursor: page?.next_cursor ?? data?.next_cursor ?? null,
  };
}

export const searchApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    globalSearch: build.query<SearchResponse, GlobalSearchArg>({
      // Keep resolved pages cached for 45s — a bump above this API's base default of
      // 30s (heimdallApi.ts) so the type→backspace pattern re-uses a just-fetched query
      // from cache instead of refetching. RTK already keys/dedupes by args.
      keepUnusedDataFor: 45,
      queryFn: async ({ q, types, exclude, limit = 20, cursor, chainIds, conversationIds, taskIds, projectIds }) => {
        // Empty/whitespace q returns empty (per UI-BE-5); skip the network call so
        // an empty box never hits the endpoint. types/exclude and the typed
        // parent-id scopes are forwarded only when present.
        const query = String(q || '').trim();
        if (!query) {
          return { data: { groups: [], hits: [], hasMore: false, nextCursor: null } };
        }
        try {
          const params = new URLSearchParams({ q: query, limit: String(limit) });
          if (types) params.set('types', types);
          if (exclude) params.set('exclude', exclude);
          if (cursor) params.set('cursor', cursor);
          if (chainIds) params.set('chain_ids', chainIds);
          if (conversationIds) params.set('conversation_ids', conversationIds);
          if (taskIds) params.set('task_ids', taskIds);
          if (projectIds) params.set('project_ids', projectIds);
          // Fetch the FULL envelope ({data:{groups}, page:{has_more,next_cursor}}):
          // normalizeSearch needs the `page` sibling for cursor pagination, which the
          // data-unwrapping fetch would strip.
          const body = await cookieJsonFetchEnvelope(`/search?${params.toString()}`);
          return { data: normalizeSearch(body) };
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
