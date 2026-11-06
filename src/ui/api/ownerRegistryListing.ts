export interface OwnerRegistryCursor { after_chain: string; after_task: string }
export interface OwnerRegistryPage { items: any[]; next_cursor: OwnerRegistryCursor; terminal: boolean }

// Live keyset traversal. Registry keys/tombstones are permanent; edits do not
// invalidate cursors. Refresh from the beginning to see earlier concurrent inserts.
export async function listOwnerRegistryPages(
  fetchPage: (path: string) => Promise<OwnerRegistryPage>,
  current: () => boolean,
): Promise<any[]> {
  const rows: any[] = [];
  let cursor: OwnerRegistryCursor = { after_chain: '', after_task: '' };
  for (;;) {
    if (!current()) return [];
    const query = new URLSearchParams({ page: '1', ...cursor });
    const page = await fetchPage('/api/v1/owner-local/chains?' + query);
    if (!current()) return [];
    if (!Array.isArray(page.items) || typeof page.terminal !== 'boolean') throw new Error('Invalid owner registry page');
    rows.push(...page.items);
    if (page.terminal) return rows;
    const next = page.next_cursor;
    if (!next || typeof next.after_chain !== 'string' || typeof next.after_task !== 'string' ||
      !(next.after_chain > cursor.after_chain || (next.after_chain === cursor.after_chain && next.after_task > cursor.after_task))) {
      throw new Error('Owner registry cursor did not advance; refresh listing');
    }
    cursor = next;
  }
}
