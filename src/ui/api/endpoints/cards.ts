import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';

export type CardStatus = 'pending' | 'accepted' | 'rejected' | 'snoozed' | 'discarded';

export type CardOperation = {
  op: string;
  label?: string;
  args?: Record<string, any>;
  [key: string]: any;
};

export type CardGuard = {
  target_type?: string;
  target_id?: string;
  field_conditions?: Record<string, any>;
  expected_version?: number;
  expires_at?: string;
  [key: string]: any;
};

export type Card = {
  card_id: string;
  owner_user_id: string;
  project_id: string;
  title: string;
  rationale: string;
  scope: string;
  provider: string;
  confidence: number;
  source_refs: string[];
  status: CardStatus | string;
  operations: CardOperation[];
  guard?: CardGuard;
  snooze_until?: string;
  ttl_at?: string;
  created_at: string;
  updated_at: string;
};

export type ListCardsQueryArg = {
  projectId?: string;
  status?: string;
  scope?: string;
  provider?: string;
  limit?: number;
} | void;

export type CreateCardInput = {
  project_id?: string;
  title: string;
  rationale?: string;
  scope?: string;
  provider?: string;
  confidence?: number;
  source_refs?: string[];
  operations?: CardOperation[];
  guard?: CardGuard;
  snooze_until?: string;
  ttl_at?: string;
};

export function cardErrorText(err: unknown, fallback = 'Something went wrong'): string {
  if (err == null) return fallback;
  if (typeof err === 'string') return err.trim() || fallback;
  const e = err as any;
  const data = e.data;
  if (data) {
    if (typeof data === 'string' && data.trim()) return data;
    const msg = data?.error?.message || data?.error || data?.message;
    if (typeof msg === 'string' && msg.trim()) return msg;
  }
  const fromError = e.error?.message || e.error;
  if (typeof fromError === 'string' && fromError.trim()) return fromError;
  const fromMessage = e.message;
  if (typeof fromMessage === 'string' && fromMessage.trim()) return fromMessage;
  return fallback;
}

/**
 * REQ-UX-1: Format human-friendly operation summary.
 * Uses the op's plain-language `label` property if available,
 * or defensively derives a clear human-readable description instead of exposing raw JSON.
 */
export function formatOpLabel(op: CardOperation): string {
  if (op.label && typeof op.label === 'string' && op.label.trim()) {
    return op.label.trim();
  }
  const opName = op.op || 'operation';
  const getArg = (k: string) => op.args?.[k] ?? op[k] ?? '';
  switch (opName) {
    case 'memory.delete':
    case 'memory.archive': {
      const mid = getArg('memory_id') || getArg('id');
      return mid ? `Delete memory ${mid}` : 'Delete memory';
    }
    case 'memory.create': {
      const title = getArg('title');
      const type = getArg('type') || 'fact';
      return title ? `Create ${type} memory: "${title}"` : `Create new ${type} memory`;
    }
    case 'memory.update': {
      const mid = getArg('memory_id') || getArg('id');
      const title = getArg('title');
      return title ? `Update memory ${mid}: "${title}"` : `Update memory ${mid}`;
    }
    case 'memory.approve': {
      const mid = getArg('memory_id') || getArg('id');
      return mid ? `Approve memory proposal ${mid}` : 'Approve memory proposal';
    }
    case 'memory.reject': {
      const mid = getArg('memory_id') || getArg('id');
      return mid ? `Reject memory proposal ${mid}` : 'Reject memory proposal';
    }
    case 'task.vote': {
      const tid = getArg('task_id');
      const result = (getArg('result') || 'lgtm').toUpperCase();
      return tid ? `Vote ${result} on task ${tid}` : `Cast task vote (${result})`;
    }
    case 'task_chain.set_status': {
      const cid = getArg('chain_id') || getArg('id');
      const status = getArg('status') || 'completed';
      return cid ? `Set chain ${cid} status to ${status}` : `Update chain status to ${status}`;
    }
    case 'project.update': {
      const name = getArg('name');
      return name ? `Update project settings: "${name}"` : 'Update project settings';
    }
    case 'agent.prompt': {
      const iid = getArg('instance_id') || getArg('agent_instance_id');
      return iid ? `Dispatch prompt to agent instance ${iid}` : 'Dispatch agent prompt';
    }
    default:
      return `${opName} operation`;
  }
}

export const cardsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listCards: build.query<{ cards: Card[] }, ListCardsQueryArg>({
      queryFn: async (arg) => {
        try {
          const params = new URLSearchParams();
          if (arg) {
            if (arg.projectId) params.set('project_id', arg.projectId);
            if (arg.status) params.set('status', arg.status);
            if (arg.scope) params.set('scope', arg.scope);
            if (arg.provider) params.set('provider', arg.provider);
            if (arg.limit) params.set('limit', String(arg.limit));
          }
          const queryStr = params.toString() ? `?${params.toString()}` : '';
          const data = await cookieJsonFetch(`/cards${queryStr}`);
          const cards: Card[] = Array.isArray(data)
            ? data
            : (Array.isArray(data?.data) ? data.data : (data?.cards || []));
          return { data: { cards } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: cardErrorText(error, 'Failed to list cards') } as any };
        }
      },
      providesTags: (result) => [
        { type: 'Cards' as const, id: 'LIST' },
        ...((result?.cards || []).map((card) => ({ type: 'Card' as const, id: card.card_id }))),
      ],
    }),

    getCard: build.query<{ card: Card | null }, { id: string }>({
      queryFn: async ({ id }) => {
        if (!id) return { data: { card: null } };
        try {
          const data = await cookieJsonFetch(`/cards/${encodeURIComponent(id)}`);
          const card = data?.data || data?.card || data || null;
          return { data: { card } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: cardErrorText(error, 'Failed to get card') } as any };
        }
      },
      providesTags: (_result, _error, { id }) => [{ type: 'Card' as const, id }],
    }),

    createCard: build.mutation<Card, CreateCardInput>({
      queryFn: async (input) => {
        try {
          const card = await cookieMutation('/cards', 'POST', input);
          return { data: card };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: cardErrorText(error, 'Failed to create card') } as any };
        }
      },
      invalidatesTags: [{ type: 'Cards' as const, id: 'LIST' }],
    }),

    acceptCard: build.mutation<Card, { id: string }>({
      queryFn: async ({ id }) => {
        try {
          const card = await cookieMutation(`/cards/${encodeURIComponent(id)}/accept`, 'POST', {});
          return { data: card };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: cardErrorText(error, 'Failed to accept card') } as any };
        }
      },
      invalidatesTags: (_result, _error, { id }) => [
        { type: 'Cards' as const, id: 'LIST' },
        { type: 'Card' as const, id },
        { type: 'Memory' as const, id: 'LIST' },
        { type: 'Chain' as const, id: 'LIST' },
        { type: 'Task' as const, id: 'LIST' },
      ],
    }),

    rejectCard: build.mutation<Card, { id: string }>({
      queryFn: async ({ id }) => {
        try {
          const card = await cookieMutation(`/cards/${encodeURIComponent(id)}/reject`, 'POST', {});
          return { data: card };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: cardErrorText(error, 'Failed to reject card') } as any };
        }
      },
      invalidatesTags: (_result, _error, { id }) => [
        { type: 'Cards' as const, id: 'LIST' },
        { type: 'Card' as const, id },
      ],
    }),

    discardCard: build.mutation<Card, { id: string }>({
      queryFn: async ({ id }) => {
        try {
          const card = await cookieMutation(`/cards/${encodeURIComponent(id)}/discard`, 'POST', {});
          return { data: card };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: cardErrorText(error, 'Failed to discard card') } as any };
        }
      },
      invalidatesTags: (_result, _error, { id }) => [
        { type: 'Cards' as const, id: 'LIST' },
        { type: 'Card' as const, id },
      ],
    }),

    snoozeCard: build.mutation<Card, { id: string; snoozeUntil: string }>({
      queryFn: async ({ id, snoozeUntil }) => {
        try {
          const card = await cookieMutation(`/cards/${encodeURIComponent(id)}/snooze`, 'POST', { snooze_until: snoozeUntil });
          return { data: card };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: cardErrorText(error, 'Failed to snooze card') } as any };
        }
      },
      invalidatesTags: (_result, _error, { id }) => [
        { type: 'Cards' as const, id: 'LIST' },
        { type: 'Card' as const, id },
      ],
    }),
  }),
});

export const {
  useListCardsQuery,
  useGetCardQuery,
  useCreateCardMutation,
  useAcceptCardMutation,
  useRejectCardMutation,
  useDiscardCardMutation,
  useSnoozeCardMutation,
} = cardsApi;
