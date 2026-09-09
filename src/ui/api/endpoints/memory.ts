import { cookieJsonFetch, cookieMutation } from "../cookieFetch";
import { heimdallApi } from "../heimdallApi";
import { normalizeMemory } from "../memoryCatalog";

// Memory targeting is a LIST per dimension (T1 contract): agent_ids/project_ids/
// bridge_ids/template_ids as JSON string arrays where empty = applies to all.
// The TS API exposes these as camelCase string[] (agentIds/projectIds/
// bridgeIds/templateIds) and sends the snake_case arrays on the wire. The old
// scalar/target_* single-value fields are gone (no back-compat).
export type MemoryTargeting = {
  agentIds?: string[];
  projectIds?: string[];
  bridgeIds?: string[];
  templateIds?: string[];
};

export type ListMemoriesQueryArg = ({
  status?: string;
  type?: string;
  limit?: number;
  cursor?: string;
} & MemoryTargeting) | void;

export type CreateMemoryInput = {
  title?: string;
  body?: string;
  evidence?: string;
  type?: string;
  expectedVersion?: number;
  metadataJson?: string;
  sourceTaskId?: string;
  reason?: string;
  status?: string;
  proposalAction?: string;
  memoryId?: string;
} & MemoryTargeting;

export type UpdateMemoryInput = {
  memoryId: string;
  title?: string;
  body?: string;
  evidence?: string;
  type?: string;
  expectedVersion?: number;
} & MemoryTargeting;

export type ApproveMemoryInput = {
  memoryId?: string;
  proposalId?: string;
  decision?: "approve" | "reject" | string;
  reason?: string;
  title?: string;
  body?: string;
  evidence?: string;
  type?: string;
} & MemoryTargeting;

// buildTargetingBody maps the camelCase targeting lists to the wire field names,
// emitting an array (possibly empty) only for dimensions the caller provided.
// Empty/blank ids are dropped. Omitting a dimension lets the hub default apply.
function buildTargetingBody(input: MemoryTargeting): Record<string, string[]> {
  const clean = (ids?: string[]) => (ids || []).map((id) => String(id || "").trim()).filter(Boolean);
  const out: Record<string, string[]> = {};
  if (input.agentIds !== undefined) out.agent_ids = clean(input.agentIds);
  if (input.projectIds !== undefined) out.project_ids = clean(input.projectIds);
  if (input.bridgeIds !== undefined) out.bridge_ids = clean(input.bridgeIds);
  if (input.templateIds !== undefined) out.template_ids = clean(input.templateIds);
  return out;
}

// memoryErrorText turns whatever a memory mutation's .unwrap() rejects with into
// a human-readable string. These endpoints use a custom queryFn that, on failure,
// rejects with an RTK "CUSTOM_ERROR" object { status: "CUSTOM_ERROR", error:
// "<message>" } — so the real message lives on err.error, NOT err.data or
// err.message. Callers that only read err?.data?.error || err?.message fell
// through to String(err) and rendered the useless "[object Object]". This helper
// also handles the FetchBaseQueryError shape ({ data: { error | message } }),
// plain Error ({ message }), and bare strings, with a caller-supplied fallback.
export function memoryErrorText(err: unknown, fallback = "Something went wrong"): string {
  const nonBlank = (v: unknown): string | undefined =>
    typeof v === "string" && v.trim() ? v : undefined;
  if (err == null) return fallback;
  if (typeof err === "string") return nonBlank(err) ?? fallback;
  const e = err as any;
  // FetchBaseQueryError server-envelope payload.
  const data = e.data;
  if (data) {
    if (typeof data === "string") { const s = nonBlank(data); if (s) return s; }
    else {
      const s = nonBlank(data?.error?.message) ?? nonBlank(data?.error) ?? nonBlank(data?.message);
      if (s) return s;
    }
  }
  // Custom queryFn CUSTOM_ERROR shape: { status: "CUSTOM_ERROR", error: "<msg>" }.
  const fromError = nonBlank(e.error) ?? nonBlank(e.error?.message);
  if (fromError) return fromError;
  // Plain Error / anything carrying a string message.
  return nonBlank(e.message) ?? fallback;
}

export type RejectMemoryInput = {
  memoryId: string;
  reason?: string;
};

export type ArchiveMemoryInput = {
  memoryId: string;
  reason?: string;
};

export const memoryApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listMemories: build.query<any, ListMemoriesQueryArg>({
      queryFn: async (arg) => {
        try {
          const params = new URLSearchParams();
          if (arg) {
            if (arg.status) params.set("status", arg.status);
            if (arg.type) params.set("type", arg.type);
            // Targeting filters send the plural list params as CSV; the hub
            // matches when a memory's list is empty (global) OR contains a value.
            const csv = (ids?: string[]) => (ids || []).map((id) => String(id || "").trim()).filter(Boolean).join(",");
            const agentIds = csv(arg.agentIds);
            if (agentIds) params.set("agent_ids", agentIds);
            const projectIds = csv(arg.projectIds);
            if (projectIds) params.set("project_ids", projectIds);
            const bridgeIds = csv(arg.bridgeIds);
            if (bridgeIds) params.set("bridge_ids", bridgeIds);
            const templateIds = csv(arg.templateIds);
            if (templateIds) params.set("template_ids", templateIds);
            if (arg.limit) params.set("limit", String(arg.limit));
            if (arg.cursor) params.set("cursor", arg.cursor);
          }
          const queryString = params.toString();
          const path = `/memories${queryString ? `?${queryString}` : ""}`;
          const res = await cookieJsonFetch(path);
          const rawItems = res?.items || res?.memories || (Array.isArray(res) ? res : []);
          const items = rawItems.map(normalizeMemory);
          return { data: { items, next_cursor: res?.next_cursor || res?.nextCursor || "" } };
        } catch (error: any) {
          return { error: { status: "CUSTOM_ERROR", error: String(error?.message || error) } as any };
        }
      },
      providesTags: (result) => [
        { type: "Memory" as const, id: "ALL" },
        ...((result?.items || []).map((m: any) => ({ type: "Memory" as const, id: String(m.id || m.memoryId) })).filter((t: any) => Boolean(t.id))),
      ],
    }),
    getMemory: build.query<any, { memoryId: string } | string>({
      queryFn: async (arg) => {
        const memoryId = typeof arg === "string" ? arg : arg?.memoryId;
        if (!memoryId) return { data: null };
        try {
          const res = await cookieJsonFetch(`/memories/${encodeURIComponent(memoryId)}`);
          const record = res?.memory || res?.record || res;
          return { data: record ? normalizeMemory(record) : null };
        } catch (error: any) {
          return { error: { status: "CUSTOM_ERROR", error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, arg) => [
        { type: "Memory" as const, id: typeof arg === "string" ? arg : arg?.memoryId },
      ],
    }),
    fetchMemoryHistory: build.query<any, { memoryId: string }>({
      queryFn: async () => {
        return { data: { events: [] } };
      },
      providesTags: (_result, _error, arg) => [{ type: "MemoryHistory" as const, id: arg?.memoryId }],
    }),
    createMemory: build.mutation<any, CreateMemoryInput>({
      queryFn: async (payload) => {
        try {
          const { agentIds, projectIds, bridgeIds, templateIds, ...rest } = payload;
          const data = await cookieMutation("/memories", "POST", { ...rest, ...buildTargetingBody({ agentIds, projectIds, bridgeIds, templateIds }) });
          return { data };
        } catch (error: any) {
          return { error: { status: "CUSTOM_ERROR", error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [{ type: "Memory" as const, id: "ALL" }],
    }),
    updateMemory: build.mutation<any, UpdateMemoryInput>({
      queryFn: async ({ memoryId, ...payload }) => {
        try {
          const { agentIds, projectIds, bridgeIds, templateIds, ...rest } = payload;
          const data = await cookieMutation(`/memories/${encodeURIComponent(memoryId)}`, "PATCH", { ...rest, ...buildTargetingBody({ agentIds, projectIds, bridgeIds, templateIds }) });
          return { data };
        } catch (error: any) {
          return { error: { status: "CUSTOM_ERROR", error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { memoryId }) => [
        { type: "Memory" as const, id: "ALL" },
        { type: "Memory" as const, id: memoryId },
      ],
    }),
    approveMemory: build.mutation<any, ApproveMemoryInput>({
      queryFn: async (arg) => {
        try {
          const memoryId = arg.memoryId || arg.proposalId || "";
          if (arg.decision === "reject") {
            const data = await cookieMutation(`/memories/${encodeURIComponent(memoryId)}/reject`, "POST", { reason: arg.reason });
            return { data };
          }
          const { memoryId: _m, proposalId: _p, decision: _d, agentIds, projectIds, bridgeIds, templateIds, ...edits } = arg;
          const body = { ...edits, ...buildTargetingBody({ agentIds, projectIds, bridgeIds, templateIds }) };
          const data = await cookieMutation(`/memories/${encodeURIComponent(memoryId)}/approve`, "POST", body);
          return { data };
        } catch (error: any) {
          return { error: { status: "CUSTOM_ERROR", error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, arg) => [
        { type: "Memory" as const, id: "ALL" },
        { type: "Memory" as const, id: arg.memoryId || arg.proposalId || "" },
      ],
    }),
    rejectMemory: build.mutation<any, RejectMemoryInput>({
      queryFn: async ({ memoryId, reason }) => {
        try {
          const data = await cookieMutation(`/memories/${encodeURIComponent(memoryId)}/reject`, "POST", { reason });
          return { data };
        } catch (error: any) {
          return { error: { status: "CUSTOM_ERROR", error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { memoryId }) => [
        { type: "Memory" as const, id: "ALL" },
        { type: "Memory" as const, id: memoryId },
      ],
    }),
    archiveMemory: build.mutation<any, ArchiveMemoryInput>({
      queryFn: async ({ memoryId, reason }) => {
        try {
          const data = await cookieMutation(`/memories/${encodeURIComponent(memoryId)}/archive`, "POST", { reason });
          return { data };
        } catch (error: any) {
          return { error: { status: "CUSTOM_ERROR", error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { memoryId }) => [
        { type: "Memory" as const, id: "ALL" },
        { type: "Memory" as const, id: memoryId },
      ],
    }),
  }),
});

export function patchMemoryCachesFromWs(dispatch: any, payload: any) {
  const memoryId = String(payload?.memory_id || payload?.memoryId || payload?.record?.memory_id || payload?.record?.id || "");
  const tags: any[] = [{ type: "Memory", id: "ALL" }];
  if (memoryId) {
    tags.push({ type: "Memory", id: memoryId });
  }
  dispatch(heimdallApi.util.invalidateTags(tags));
}

export const {
  useListMemoriesQuery,
  useGetMemoryQuery,
  useCreateMemoryMutation,
  useUpdateMemoryMutation,
  useApproveMemoryMutation,
  useRejectMemoryMutation,
  useArchiveMemoryMutation,
} = memoryApi;

export const useListMemoryQuery = useListMemoriesQuery;
export const useListApplicableMemoryQuery = useListMemoriesQuery;
export const useFetchMemoryQuery = useGetMemoryQuery;
export const useLazyFetchMemoryQuery = memoryApi.endpoints.getMemory.useLazyQuery;
export const useProposeMemoryChangeMutation = useCreateMemoryMutation;
export const useDecideMemoryProposalMutation = useApproveMemoryMutation;
export const useFetchMemoryHistoryQuery = memoryApi.endpoints.fetchMemoryHistory.useQuery;
