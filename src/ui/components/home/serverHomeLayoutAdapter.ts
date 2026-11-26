import { ApiError, cookieJsonFetch } from '../../api/cookieFetch';
import { EXPECTED_USER_HEADER, getExpectedUserGeneration, getExpectedUserId } from '../../utils/expectedUser';
import { HOME_WIDGETS, HomeLayoutConflict, homeLayoutStorageKey, normalizeHomeLayout, type HomeLayout, type HomeLayoutAdapter } from './homeLayout';

const PATH = '/me/home-layout';
const byteLength = (value: unknown) => new TextEncoder().encode(JSON.stringify(value)).length;
function boundedOptions(value: unknown, depth = 0): boolean {
  if (depth > 16) return false;
  if (value && typeof value === 'object') return Object.values(value).every((item) => boundedOptions(item, depth + 1));
  return true;
}
function validLayout(value: any): value is HomeLayout {
  if (!value || !Number.isSafeInteger(value.version) || value.version < 0 || !Array.isArray(value.widgets)) return false;
  const seen = new Set<string>();
  for (const widget of value.widgets) {
    if (!widget || !HOME_WIDGETS.some(({ id }) => id === widget.id) || seen.has(widget.id)
      || (widget.width !== 1 && widget.width !== 2) || typeof widget.hidden !== 'boolean') return false;
    seen.add(widget.id);
    if (widget.options !== undefined) {
      const options = widget.options;
      if (!options || typeof options !== 'object' || Array.isArray(options) || byteLength(options) > 8192 || !boundedOptions(options)) return false;
      if (options.mobile_order !== undefined && (!Number.isSafeInteger(options.mobile_order) || options.mobile_order < 0)) return false;
    }
  }
  return true;
}

/** Read only the captured user's backup. Storage is optional and never rewritten. */
function readBackup(storage: Pick<Storage, 'getItem'> | undefined, userId: string): HomeLayout | undefined {
  try {
    const text = storage?.getItem(homeLayoutStorageKey(userId));
    if (!text) return;
    const raw = JSON.parse(text);
    if (!raw || !Number.isSafeInteger(raw.version) || raw.version < 0 || !Array.isArray(raw.widgets)
      || !raw.widgets.every((item: any) => item && typeof item === 'object' && typeof item.id === 'string')) return;
    // Retired/duplicate IDs and old defaultable fields follow the existing local
    // normalization policy. The browser revision has no authority on the server.
    const layout = normalizeHomeLayout({ ...raw, version: 0 });
    return validLayout(layout) && byteLength(layout) <= 32768 ? layout : undefined;
  } catch { return; }
}

export function createServerHomeLayoutAdapter({
  storage = () => { try { return window.localStorage; } catch { return undefined; } },
  isCurrentUser = (userId: string) => getExpectedUserId() === userId,
}: {
  storage?: () => Pick<Storage, 'getItem'> | undefined;
  isCurrentUser?: (userId: string) => boolean;
} = {}): HomeLayoutAdapter {
  function assertAccount(userId: string, signal?: AbortSignal, generation = getExpectedUserGeneration()) {
    if (signal?.aborted) throw new DOMException('Layout request cancelled.', 'AbortError');
    if (!userId || !isCurrentUser(userId) || generation !== getExpectedUserGeneration()) throw new ApiError('Your account session changed. Reload to continue.', 409, 'account_mismatch');
  }
  async function request(userId: string, signal?: AbortSignal, layout?: HomeLayout, version?: number, generation = getExpectedUserGeneration()): Promise<HomeLayout> {
    assertAccount(userId, signal, generation);
    try {
      const result = await cookieJsonFetch(PATH, {
        method: layout ? 'PUT' : 'GET', signal, cache: 'no-store',
        headers: {
          [EXPECTED_USER_HEADER]: userId,
          ...(layout ? { 'Content-Type': 'application/json', 'If-Match': `"${version}"` } : {}),
        },
        ...(layout ? { body: JSON.stringify({ ...layout, version }) } : {}),
      });
      assertAccount(userId, signal, generation);
      if (!validLayout(result)) throw new Error('The server returned an invalid Home layout.');
      return normalizeHomeLayout(result);
    } catch (error) {
      assertAccount(userId, signal, generation);
      if (error instanceof ApiError && error.status === 409 && error.code === 'conflict') throw new HomeLayoutConflict();
      throw error;
    }
  }
  return {
    async load(userId, signal) {
      const generation = getExpectedUserGeneration();
      const saved = await request(userId, signal, undefined, undefined, generation);
      if (saved.version !== 0) return saved;
      assertAccount(userId, signal, generation);
      const backup = readBackup(storage(), userId);
      if (!backup) return saved;
      try { return await request(userId, signal, backup, 0, generation); }
      catch (error) {
        if (!(error instanceof HomeLayoutConflict)) throw error;
        // Another device created first. One GET of its winner; never retry PUT.
        return request(userId, signal, undefined, undefined, generation);
      }
    },
    save: (userId, layout, version, signal) => request(userId, signal, layout, version),
  };
}
