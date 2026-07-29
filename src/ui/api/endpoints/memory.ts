import { cookieJsonFetch, cookieMutation } from "../cookieFetch";
import { heimdallApi } from "../heimdallApi";
import { normalizeMemory } from "../memoryCatalog";

export type ListMemoriesQueryArg = {
  status?: string;
  type?: string;
  agent_id?: string;
  project_id?: string;
  bridge_id?: string;
  targetAgentId?: string;
  targetProjectId?: string;
  targetBridgeId?: string;
  limit?: number;
  cursor?: string;
} | void;

export type CreateMemoryInput = {
  title?: string;
  body?: string;
  evidence?: string;
  type?: string;
  agent_id?: string;
  project_id?: string;
  bridge_id?: string;
  template_id?: string;
  targetAgentId?: string;
  targetProjectId?: string;
  targetBridgeId?: string;
  targetTemplateId?: string;
  expectedVersion?: number;
  metadataJson?: string;
  sourceTaskId?: string;
  reason?: string;
  status?: string;
  proposalAction?: string;
  memoryId?: string;
};

export type UpdateMemoryInput = {
  memoryId: string;
  title?: string;
  body?: string;
  evidence?: string;
  type?: string;
  agent_id?: string;
  project_id?: string;
  bridge_id?: string;
  template_id?: string;
  targetAgentId?: string;
  targetProjectId?: string;
  targetBridgeId?: string;
  targetTemplateId?: string;
  expectedVersion?: number;
};

export type ApproveMemoryInput = {
  memoryId?: string;
  proposalId?: string;
  decision?: "approve" | "reject" | string;
  reason?: string;
  title?: string;
  body?: string;
  evidence?: string;
  type?: string;
  agent_id?: string;
  project_id?: string;
  bridge_id?: string;
  template_id?: string;
  targetAgentId?: string;
  targetProjectId?: string;
  targetBridgeId?: string;
  targetTemplateId?: string;
};

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
            const agentId = arg.agent_id || arg.targetAgentId;
            if (agentId) params.set("agent_id", agentId);
            const projectId = arg.project_id || arg.targetProjectId;
            if (projectId) params.set("project_id", projectId);
            const bridgeId = arg.bridge_id || arg.targetBridgeId;
            if (bridgeId) params.set("bridge_id", bridgeId);
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
          const agent_id = payload.agent_id || payload.targetAgentId;
          const project_id = payload.project_id || payload.targetProjectId;
          const bridge_id = payload.bridge_id || payload.targetBridgeId;
          const template_id = payload.template_id || payload.targetTemplateId;
          const data = await cookieMutation("/memories", "POST", { ...payload, agent_id, project_id, bridge_id, template_id });
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
          const agent_id = payload.agent_id || payload.targetAgentId;
          const project_id = payload.project_id || payload.targetProjectId;
          const bridge_id = payload.bridge_id || payload.targetBridgeId;
          const template_id = payload.template_id || payload.targetTemplateId;
          const data = await cookieMutation(`/memories/${encodeURIComponent(memoryId)}`, "PATCH", { ...payload, agent_id, project_id, bridge_id, template_id });
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
          const { memoryId: _m, proposalId: _p, decision: _d, ...edits } = arg;
          const agent_id = edits.agent_id || edits.targetAgentId;
          const project_id = edits.project_id || edits.targetProjectId;
          const bridge_id = edits.bridge_id || edits.targetBridgeId;
          const template_id = edits.template_id || edits.targetTemplateId;
          const body = { ...edits, agent_id, project_id, bridge_id, template_id };
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
