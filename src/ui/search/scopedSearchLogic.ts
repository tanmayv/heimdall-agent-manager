// Scoped Search logic and utilities (REQ-SEARCH-UI-PANEL-1, REQ-SEARCH-SHORTCUTS-1).
//
// DELIBERATELY DEPENDENCY-FREE leaf module (following repository conventions).
// Contains search query transformations, multi-scope path deduplication,
// include/exclude glob pattern matching, and result grouping for automated testing
// and runtime consumption.

export type FsSearchScopeArgs = {
  projectId?: string;
  chainId?: string;
  directoryId?: string;
  agentInstanceId?: string;
  bridgeId?: string;
};

export type FsSearchMatch = {
  path: string;
  line_number: number;
  column: number;
  match_start: number;
  match_end: number;
  line: string;
};

export type FsSearchResult = {
  ok: boolean;
  root: string;
  matches: FsSearchMatch[];
  truncated: boolean;
  error?: { code: string; message: string };
};

export type FsSearchScope = {
  id: string; // 'primary' | chainDir.directoryId | `agent-rundir:${instanceId}`
  label: string;
  kind: 'primary' | 'chain_directory' | 'agent_run_dir';
  path?: string; // Root filesystem path if known (for deduplication)
  bridgeId?: string;
  scopeArgs: FsSearchScopeArgs;
};

export type ScopedSearchMatch = FsSearchMatch & {
  scopeId: string;
  scopeLabel: string;
  scopeKind: 'primary' | 'chain_directory' | 'agent_run_dir';
  scopeArgs: FsSearchScopeArgs;
};

export type MultiScopeSearchOptions = {
  query: string;
  scopes: FsSearchScope[];
  caseSensitive?: boolean;
  wholeWord?: boolean;
  regex?: boolean;
  includePattern?: string; // e.g. "*.tsx, !*.test.ts"
  limitPerScope?: number;
};

export type MultiScopeSearchResult = {
  scopesSearched: FsSearchScope[];
  scopesDeduplicatedOut: FsSearchScope[];
  matches: ScopedSearchMatch[];
  totalMatches: number;
  totalFiles: number;
  isTruncated: boolean;
  errors: Array<{ scopeId: string; scopeLabel: string; error: string }>;
};

/**
 * Normalizes a directory path: trims whitespace, standardizes slashes to forward slashes,
 * collapses consecutive slashes, and removes trailing slashes (except root).
 */
export function normalizeFsPath(p?: string): string {
  if (!p) return '';
  let clean = p.trim().replace(/\\/g, '/');
  clean = clean.replace(/\/+/g, '/');
  if (clean.length > 1 && clean.endsWith('/')) {
    clean = clean.slice(0, -1);
  }
  return clean;
}

/**
 * Deduplicates search scopes to prevent redundant recursive searches across
 * overlapping nested directory subtrees on the same bridge.
 * E.g., if a Project Root is `/repo` and a Task Chain Dir is `/repo/sub`,
 * the nested child is omitted when the parent is also selected.
 */
export function deduplicateSearchScopes(scopes: FsSearchScope[]): {
  activeScopes: FsSearchScope[];
  deduplicatedOut: FsSearchScope[];
} {
  const activeScopes: FsSearchScope[] = [];
  const deduplicatedOut: FsSearchScope[] = [];

  for (const scope of scopes) {
    const normPath = normalizeFsPath(scope.path);
    const normBridge = (scope.bridgeId || 'local').trim();

    // If path is missing, keep the scope (containment cannot be determined)
    if (!normPath) {
      activeScopes.push(scope);
      continue;
    }

    let isNested = false;
    for (const existing of activeScopes) {
      const existingBridge = (existing.bridgeId || 'local').trim();
      if (existingBridge !== normBridge) continue;

      const existingPath = normalizeFsPath(existing.path);
      if (!existingPath) continue;

      if (normPath === existingPath) {
        isNested = true;
        break;
      }

      if (normPath.startsWith(existingPath + '/')) {
        isNested = true;
        break;
      }
    }

    if (isNested) {
      deduplicatedOut.push(scope);
    } else {
      // Check if candidate scope subsumes any existing scopes in activeScopes
      const retained: FsSearchScope[] = [];
      for (const existing of activeScopes) {
        const existingBridge = (existing.bridgeId || 'local').trim();
        const existingPath = normalizeFsPath(existing.path);
        if (existingBridge === normBridge && existingPath && existingPath.startsWith(normPath + '/')) {
          deduplicatedOut.push(existing);
        } else {
          retained.push(existing);
        }
      }
      retained.push(scope);
      activeScopes.length = 0;
      activeScopes.push(...retained);
    }
  }

  return { activeScopes, deduplicatedOut };
}

/**
 * Converts a simple glob pattern (e.g. *.tsx, src/** /*.ts) to a RegExp.
 */
export function globToRegExp(glob: string): RegExp {
  let reStr = '';
  let i = 0;
  while (i < glob.length) {
    const c = glob[i];
    if (c === '*') {
      if (glob[i + 1] === '*') {
        reStr += '.*';
        i += 2;
        if (glob[i] === '/') {
          reStr += '(?:/)?';
          i++;
        }
      } else {
        reStr += '[^/]*';
        i++;
      }
    } else if (c === '?') {
      reStr += '[^/]';
      i++;
    } else if (['.', '+', '^', '$', '{', '}', '(', ')', '|', '[', ']', '\\'].includes(c)) {
      reStr += '\\' + c;
      i++;
    } else {
      reStr += c;
      i++;
    }
  }
  return new RegExp(`^${reStr}$`, 'i');
}

/**
 * Tests whether a relative file path matches a comma-separated include/exclude pattern
 * (e.g. "*.tsx, !*.test.ts").
 */
export function matchesFilePattern(filePath: string, patternString?: string): boolean {
  if (!patternString || !patternString.trim()) return true;

  const rawPatterns = patternString
    .split(',')
    .map((p) => p.trim())
    .filter(Boolean);
  if (rawPatterns.length === 0) return true;

  const includePatterns: RegExp[] = [];
  const excludePatterns: RegExp[] = [];

  for (const raw of rawPatterns) {
    const isExclude = raw.startsWith('!');
    const pat = isExclude ? raw.slice(1).trim() : raw;
    if (!pat) continue;

    const regex = globToRegExp(pat);
    if (isExclude) {
      excludePatterns.push(regex);
    } else {
      includePatterns.push(regex);
    }
  }

  const cleanPath = filePath.replace(/\\/g, '/');
  const fileName = cleanPath.split('/').pop() || cleanPath;

  for (const ex of excludePatterns) {
    if (ex.test(cleanPath) || ex.test(fileName)) {
      return false;
    }
  }

  if (includePatterns.length > 0) {
    return includePatterns.some((inc) => inc.test(cleanPath) || inc.test(fileName));
  }

  return true;
}

/**
 * Transforms a raw query based on regex and wholeWord options for backend ripgrep execution.
 */
export function transformSearchQuery(
  rawQuery: string,
  options: { regex?: boolean; wholeWord?: boolean }
): string {
  if (!rawQuery) return '';
  let transformed = rawQuery;

  if (!options.regex) {
    transformed = transformed.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    if (options.wholeWord) {
      const startsWord = /^\w/.test(rawQuery);
      const endsWord = /\w$/.test(rawQuery);
      const prefix = startsWord ? '\\b' : '';
      const suffix = endsWord ? '\\b' : '';
      transformed = `${prefix}${transformed}${suffix}`;
    }
  } else {
    if (options.wholeWord) {
      transformed = `\\b${transformed}\\b`;
    }
  }

  return transformed;
}

/**
 * Deduplicates search results after execution using the canonical root paths returned by the backend.
 * Catches cases where a scope's root was not known prior to search (e.g. agent run dir nested within project root).
 */
export function deduplicateScopeResultsByRoot(
  results: Array<{ scope: FsSearchScope; root: string; matches: FsSearchMatch[] }>
): {
  activeResults: Array<{ scope: FsSearchScope; root: string; matches: FsSearchMatch[] }>;
  subsumedScopes: FsSearchScope[];
} {
  const subsumedScopeIds = new Set<string>();

  for (let i = 0; i < results.length; i++) {
    const a = results[i];
    const bridgeA = (a.scope.bridgeId || 'local').trim();
    const rootA = normalizeFsPath(a.root || a.scope.path);
    if (!rootA) continue;

    for (let j = 0; j < results.length; j++) {
      if (i === j) continue;
      const b = results[j];
      const bridgeB = (b.scope.bridgeId || 'local').trim();
      if (bridgeA !== bridgeB) continue;
      const rootB = normalizeFsPath(b.root || b.scope.path);
      if (!rootB) continue;

      if (rootB === rootA) {
        if (a.scope.kind === 'primary' && b.scope.kind !== 'primary') {
          subsumedScopeIds.add(b.scope.id);
        } else if (i < j && !(b.scope.kind === 'primary' && a.scope.kind !== 'primary')) {
          subsumedScopeIds.add(b.scope.id);
        }
      } else if (rootB.startsWith(rootA + '/')) {
        subsumedScopeIds.add(b.scope.id);
      }
    }
  }

  const activeResults: Array<{ scope: FsSearchScope; root: string; matches: FsSearchMatch[] }> = [];
  const subsumedScopes: FsSearchScope[] = [];

  for (const r of results) {
    if (subsumedScopeIds.has(r.scope.id)) {
      subsumedScopes.push(r.scope);
    } else {
      activeResults.push(r);
    }
  }

  return { activeResults, subsumedScopes };
}

