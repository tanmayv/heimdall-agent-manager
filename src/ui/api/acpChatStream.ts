// Pending assistant state owns the status line, independently of runtime activity
// and the animated text reveal. Terminal snapshots remove it on the next render.
export function hasPendingAcpResponse(rows: readonly {
  isUser: boolean; messageStatus?: string; metadata?: Record<string, any>;
}[]): boolean {
  return rows.some((row) => !row.isUser && Boolean(row.metadata?.acp) && row.messageStatus === 'pending');
}

// Stream ordering applies equally to raw REST rows and mapped legacy messages.
export function assistantRevision(row: any): number {
  let metadata = row?.metadata ?? row?.metadata_json ?? {};
  if (typeof metadata === 'string') {
    try { metadata = JSON.parse(metadata); } catch { metadata = {}; }
  }
  return Number(metadata?.acp?.revision || 0);
}

export function acceptAssistantSnapshot(current: any, incoming: any): boolean {
  const revision = assistantRevision(current);
  if (!revision) return true;
  if (assistantRevision(incoming) < revision) return false;
  const status = current?.message_status ?? current?.messageStatus;
  const nextStatus = incoming?.message_status ?? incoming?.messageStatus;
  return !((status === 'complete' || status === 'failed') && nextStatus === 'pending');
}

export function upsertAssistantSnapshot(rows: any[], incoming: any, insert = true): void {
  const id = String(incoming?.message_id ?? incoming?.id ?? '');
  const index = rows.findIndex((row) => String(row?.message_id ?? row?.id ?? '') === id);
  if (index >= 0) {
    if (acceptAssistantSnapshot(rows[index], incoming)) rows[index] = { ...rows[index], ...incoming };
  } else if (insert) {
    const created = String(incoming?.created_at ?? incoming?.createdAt ?? '');
    const position = created ? rows.findIndex((row) => String(row?.created_at ?? row?.createdAt ?? '') < created) : 0;
    rows.splice(position < 0 ? rows.length : position, 0, incoming);
  }
}

// A fetch in flight cannot satisfy an event received after it started. Keep a
// trailing request for that event (including the terminal event) and serialize
// requests so RTK Query cannot coalesce it into the older in-flight request.
export function createAssistantFetchQueue(fetchMessage: (conversationId: string, messageId: string) => Promise<unknown>, interval = 100) {
  type Entry = { conversationId: string; revision: number; dirty: boolean; running: boolean; last: number; timer?: ReturnType<typeof setTimeout>; failures: number };
  const entries = new Map<string, Entry>();
  const run = async (id: string, entry: Entry) => {
    entry.timer = undefined;
    entry.running = true;
    entry.dirty = false;
    entry.last = Date.now();
    try {
      await fetchMessage(entry.conversationId, id);
      entry.failures = 0;
    } catch {
      entry.failures += 1;
      entry.dirty = entry.failures <= 3;
    } finally {
      entry.running = false;
      if (entry.dirty && entries.get(id) === entry) schedule(id, entry);
    }
  };
  const schedule = (id: string, entry: Entry) => {
    if (entry.running || entry.timer) return;
    const delay = Math.max(0, (entry.failures ? 1000 : interval) - (Date.now() - entry.last));
    entry.timer = setTimeout(() => { void run(id, entry); }, delay);
  };
  return {
    enqueue(conversationId: string, messageId: string, revision: number) {
      let entry = entries.get(messageId);
      if (!entry) {
        entry = { conversationId, revision: 0, dirty: false, running: false, last: 0, failures: 0 };
        entries.set(messageId, entry);
      }
      if (revision <= entry.revision) return;
      entry.revision = revision;
      entry.dirty = true;
      schedule(messageId, entry);
      if (entries.size > 256) {
        for (const [id, old] of entries) {
          if (!old.running && !old.timer && !old.dirty) { entries.delete(id); break; }
        }
      }
    },
    clear() {
      for (const entry of entries.values()) if (entry.timer) clearTimeout(entry.timer);
      entries.clear();
    },
  };
}
