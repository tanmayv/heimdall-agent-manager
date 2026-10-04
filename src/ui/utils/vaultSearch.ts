import { isVaultArmored, decryptVaultText, getActiveVaultKey } from './vaultContent.ts';
import type { SearchItem } from '../store/searchTitleSlice.ts';

export const SEARCH_DECRYPT_BATCH_SIZE = 50;

export interface RawSearchItemInput {
  id: string;
  type: 'chain' | 'conversation';
  rawTitle?: string;
  title?: string;
  decryptedTitle?: string;
  projectId?: string;
  status?: string;
  updatedAt?: string;
  [key: string]: any;
}

const yieldEventLoop = (): Promise<void> =>
  new Promise<void>((resolve) => {
    if (typeof setImmediate === 'function') {
      setImmediate(resolve);
    } else {
      setTimeout(resolve, 0);
    }
  });

export async function decryptSearchTitle(
  rawTitle: string,
  rawKeyHex?: string | CryptoKey | null,
): Promise<string> {
  if (!rawTitle) return '';
  const activeKey = rawKeyHex || getActiveVaultKey();
  if (!activeKey || !isVaultArmored(rawTitle)) return rawTitle;
  try {
    return await decryptVaultText(rawTitle, activeKey);
  } catch {
    return rawTitle;
  }
}

export async function batchDecryptTitles(
  items: RawSearchItemInput[],
  rawKeyHex?: string | CryptoKey | null,
  batchSize: number = SEARCH_DECRYPT_BATCH_SIZE,
): Promise<SearchItem[]> {
  if (!items || items.length === 0) {
    return [];
  }

  const activeKey = rawKeyHex || getActiveVaultKey();
  const results: SearchItem[] = [];

  for (let i = 0; i < items.length; i += batchSize) {
    if (i > 0) {
      await yieldEventLoop();
    }
    const chunk = items.slice(i, i + batchSize);
    const decryptedChunk = await Promise.all(
      chunk.map(async (item): Promise<SearchItem> => {
        const rawTitle = String(item.rawTitle ?? item.title ?? '');
        let decryptedTitle = rawTitle;
        if (activeKey && isVaultArmored(rawTitle)) {
          try {
            decryptedTitle = await decryptVaultText(rawTitle, activeKey);
          } catch {
            decryptedTitle = rawTitle;
          }
        } else if (item.decryptedTitle && !isVaultArmored(item.decryptedTitle)) {
          decryptedTitle = item.decryptedTitle;
        }

        return {
          id: String(item.id),
          type: item.type,
          rawTitle,
          decryptedTitle,
          projectId: item.projectId,
          status: item.status,
          updatedAt: item.updatedAt,
        };
      }),
    );
    results.push(...decryptedChunk);
  }

  return results;
}
