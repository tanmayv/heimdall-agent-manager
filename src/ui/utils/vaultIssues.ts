// Zero-Knowledge Vault Transformers for Issues and Comments
// REQ-VAULT-ISSUES-UI-1

import { isVaultArmored, encryptVaultText, decryptVaultText } from './vaultContent.ts';

export interface IssuePayload {
  title?: string;
  description?: string;
  [key: string]: any;
}

export interface CommentPayload {
  body: string;
  [key: string]: any;
}

/**
 * Encrypt issue fields (title, description) if vault is unlocked using rawKeyHex.
 */
export async function encryptIssueFields<T extends IssuePayload>(
  payload: T,
  rawKeyHex?: string | null,
): Promise<T> {
  if (!rawKeyHex) return { ...payload };
  const res = { ...payload };
  if (res.title && !isVaultArmored(res.title)) {
    res.title = await encryptVaultText(res.title, rawKeyHex);
  }
  if (res.description && !isVaultArmored(res.description)) {
    res.description = await encryptVaultText(res.description, rawKeyHex);
  }
  return res;
}

/**
 * Encrypt comment body if vault is unlocked using rawKeyHex.
 */
export async function encryptCommentFields<T extends CommentPayload>(
  payload: T,
  rawKeyHex?: string | null,
): Promise<T> {
  if (!rawKeyHex || !payload.body) return { ...payload };
  const res = { ...payload };
  if (!isVaultArmored(res.body)) {
    res.body = await encryptVaultText(res.body, rawKeyHex);
  }
  return res;
}

/**
 * Decrypt issue fields (title, description, description_preview, comments) using rawKeyHex.
 */
export async function decryptIssueRecord<T extends IssuePayload>(
  issue: T,
  rawKeyHex?: string | null,
): Promise<T> {
  if (!rawKeyHex) return issue;
  let title = issue.title;
  let description = issue.description;
  let descriptionPreview = (issue as any).descriptionPreview || (issue as any).description_preview;

  if (title && isVaultArmored(title)) {
    try {
      title = await decryptVaultText(title, rawKeyHex);
    } catch {}
  }
  if (description && isVaultArmored(description)) {
    try {
      description = await decryptVaultText(description, rawKeyHex);
    } catch {}
  }
  if (descriptionPreview && isVaultArmored(descriptionPreview)) {
    try {
      descriptionPreview = await decryptVaultText(descriptionPreview, rawKeyHex);
    } catch {}
  }

  let comments = (issue as any).comments;
  if (Array.isArray(comments)) {
    comments = await Promise.all(
      comments.map(async (c: any) => {
        if (c.body && isVaultArmored(c.body)) {
          try {
            return { ...c, body: await decryptVaultText(c.body, rawKeyHex) };
          } catch {
            return c;
          }
        }
        return c;
      }),
    );
  }

  return {
    ...issue,
    title,
    description,
    descriptionPreview,
    description_preview: descriptionPreview,
    comments,
  };
}

/**
 * Decrypt comment record body using rawKeyHex.
 */
export async function decryptCommentRecord<T extends CommentPayload>(
  comment: T,
  rawKeyHex?: string | null,
): Promise<T> {
  if (!rawKeyHex || !isVaultArmored(comment.body)) return comment;
  return {
    ...comment,
    body: await decryptVaultText(comment.body, rawKeyHex),
  };
}
