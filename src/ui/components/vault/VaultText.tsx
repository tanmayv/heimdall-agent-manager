// Zero-Knowledge VaultText Reusable Component & Decryption Hooks
// REQ-VAULT-ISSUES-UI-1
import React, { useState, useEffect } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import {
  selectIsVaultUnlocked,
  selectActiveVaultKey,
  openUnlockModal,
} from '../../store/vaultSlice';
import {
  isVaultArmored,
  containsVaultArmored,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
  decryptList,
  getActiveVaultKey,
} from '../../utils/vaultContent';
import Markdown from '../Markdown';

export interface VaultTextProps {
  value?: string | null;
  fallback?: string;
  as?: 'span' | 'p' | 'div';
  className?: string;
  onUnlockClick?: () => void;
  title?: string;
}

/**
 * Reusable VaultText component:
 * - If value is unencrypted / not armored, renders plaintext directly.
 * - If value is armored and vault is unlocked, decrypts and renders plaintext.
 * - If value is armored and vault is locked, renders an interactive placeholder
 *   with data-debug-id='vault-locked-placeholder' that triggers openUnlockModal on click.
 */
export function VaultText({
  value,
  fallback = '',
  as = 'span',
  className,
  onUnlockClick,
  title,
}: VaultTextProps) {
  const dispatch = useDispatch();
  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const activeVaultKey = useSelector(selectActiveVaultKey) || getActiveVaultKey();

  const rawString = value ?? '';
  const isArmored = isVaultArmored(rawString);
  const isEmbedded = !isArmored && containsVaultArmored(rawString);
  const hasVault = isArmored || isEmbedded;

  const [decryptedText, setDecryptedText] = useState<string | null>(null);
  const [isDecrypting, setIsDecrypting] = useState<boolean>(false);

  useEffect(() => {
    let mounted = true;
    if (!hasVault) {
      setDecryptedText(rawString);
      setIsDecrypting(false);
      return;
    }

    const activeKey = activeVaultKey || getActiveVaultKey();
    if (!isUnlocked || !activeKey) {
      setDecryptedText(
        isEmbedded ? rawString.replace(/vault:v1:[A-Za-z0-9+/=_-]+/g, '[🔒 Encrypted]') : null
      );
      setIsDecrypting(false);
      return;
    }

    setIsDecrypting(true);
    const p = isArmored
      ? decryptVaultText(rawString, activeKey)
      : decryptEmbeddedVaultTokens(rawString, activeKey);
    p.then((decrypted) => {
      if (mounted) {
        setDecryptedText(decrypted);
        setIsDecrypting(false);
      }
    }).catch((err) => {
      if (mounted) {
        console.error('Failed to decrypt vault armored text:', err);
        setDecryptedText(fallback || rawString.replace(/vault:v1:[A-Za-z0-9+/=_-]+/g, '[🔒 Encrypted]'));
        setIsDecrypting(false);
      }
    });

    return () => {
      mounted = false;
    };
  }, [rawString, hasVault, isArmored, isEmbedded, isUnlocked, activeVaultKey, fallback]);

  const Tag = as;

  // 1. Not armored or embedded: render plaintext directly
  if (!hasVault) {
    return (
      <Tag className={className} title={title}>
        {rawString || fallback}
      </Tag>
    );
  }

  // 2. Vault content and vault is locked
  const activeKey = activeVaultKey || getActiveVaultKey();
  if (!isUnlocked || !activeKey) {
    if (isArmored) {
      return (
        <button
          type="button"
          data-debug-id="vault-locked-placeholder"
          onClick={(e) => {
            e.stopPropagation();
            if (onUnlockClick) {
              onUnlockClick();
            } else {
              dispatch(openUnlockModal());
            }
          }}
          title={title || 'Encrypted content — click to unlock vault'}
          aria-label="Encrypted content — click to unlock vault"
          className={`inline-flex items-center gap-1.5 px-2 py-0.5 rounded text-xs font-mono font-medium bg-neutral-soft hover:bg-neutral-raised text-accent border border-subtle cursor-pointer transition-colors select-none ${className || ''}`}
        >
          <span aria-hidden="true">🔒</span>
          <span>[🔒 Encrypted content - click to unlock]</span>
        </button>
      );
    }
    return (
      <Tag className={className} title={title}>
        {decryptedText !== null ? decryptedText : rawString.replace(/vault:v1:[A-Za-z0-9+/=_-]+/g, '[🔒 Encrypted]')}
      </Tag>
    );
  }

  // 3. Vault content and currently decrypting
  if (isDecrypting && decryptedText === null) {
    return (
      <Tag className={`${className || ''} opacity-60 italic`} title={title}>
        {fallback || 'Decrypting...'}
      </Tag>
    );
  }

  // 4. Decrypted: render plaintext
  return (
    <Tag className={className} title={title}>
      {decryptedText !== null ? decryptedText : fallback}
    </Tag>
  );
}

/**
 * Hook to decrypt an individual string value reactively.
 */
export function useDecryptedText(value?: string | null): {
  text: string;
  isArmored: boolean;
  isLocked: boolean;
  isDecrypting: boolean;
} {
  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const activeVaultKey = useSelector(selectActiveVaultKey) || getActiveVaultKey();
  const raw = value ?? '';
  const isArmored = isVaultArmored(raw);
  const isEmbedded = !isArmored && containsVaultArmored(raw);
  const hasVault = isArmored || isEmbedded;

  const [text, setText] = useState<string>(raw);
  const [isDecrypting, setIsDecrypting] = useState<boolean>(false);

  useEffect(() => {
    let mounted = true;
    if (!hasVault) {
      setText(raw);
      setIsDecrypting(false);
      return;
    }
    const activeKey = activeVaultKey || getActiveVaultKey();
    if (!isUnlocked || !activeKey) {
      setText(raw.replace(/vault:v1:[A-Za-z0-9+/=_-]+/g, '[🔒 Encrypted]'));
      setIsDecrypting(false);
      return;
    }
    setIsDecrypting(true);
    const p = isArmored
      ? decryptVaultText(raw, activeKey)
      : decryptEmbeddedVaultTokens(raw, activeKey);
    p.then((decrypted) => {
      if (mounted) {
        setText(decrypted.replace(/vault:v1:[A-Za-z0-9+/=_-]+/g, '[🔒 Encrypted]'));
        setIsDecrypting(false);
      }
    }).catch(() => {
      if (mounted) {
        setText(raw.replace(/vault:v1:[A-Za-z0-9+/=_-]+/g, '[🔒 Encrypted]'));
        setIsDecrypting(false);
      }
    });
    return () => {
      mounted = false;
    };
  }, [raw, isArmored, isEmbedded, hasVault, isUnlocked, activeVaultKey]);

  return {
    text,
    isArmored: hasVault,
    isLocked: hasVault && !isUnlocked,
    isDecrypting,
  };
}

/**
 * Hook to decrypt an array of issue objects reactively when vault is unlocked.
 */
export function useDecryptedIssues<T extends { title?: string; description?: string; description_preview?: string; descriptionPreview?: string }>(
  items: T[],
): T[] {
  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const activeVaultKey = useSelector(selectActiveVaultKey) || getActiveVaultKey();
  const [decryptedList, setDecryptedList] = useState<T[]>(items);

  useEffect(() => {
    let mounted = true;
    const activeKey = activeVaultKey || getActiveVaultKey();
    if (!isUnlocked || !activeKey || items.length === 0) {
      setDecryptedList(items);
      return;
    }

    const hasArmored = items.some(
      (item) =>
        isVaultArmored(item.title) ||
        isVaultArmored(item.description) ||
        isVaultArmored(item.description_preview) ||
        isVaultArmored(item.descriptionPreview),
    );

    if (!hasArmored) {
      setDecryptedList(items);
      return;
    }

    decryptList(
      items,
      ['title', 'description', 'description_preview', 'descriptionPreview'] as (keyof T)[],
      activeKey,
    )
      .then((res) => {
        if (mounted) setDecryptedList(res);
      })
      .catch((err) => {
        console.error('Failed to decrypt issues list:', err);
        if (mounted) setDecryptedList(items);
      });

    return () => {
      mounted = false;
    };
  }, [items, isUnlocked, activeVaultKey]);

  return decryptedList;
}

export interface DecryptedMarkdownProps {
  source?: string | null;
  className?: string;
  compact?: boolean;
  copyAll?: boolean;
  'data-debug-id'?: string;
  fallback?: string;
}

/**
 * Reactive Markdown component that decrypts armored or embedded vault tokens in `source`
 * using `useDecryptedText` before rendering with `Markdown`.
 */
export function DecryptedMarkdown({
  source,
  fallback = '',
  ...props
}: DecryptedMarkdownProps) {
  const { text } = useDecryptedText(source ?? '');
  return <Markdown source={text || fallback} {...props} />;
}

export default VaultText;
