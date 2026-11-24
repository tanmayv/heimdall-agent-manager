import type { FilterNode, FilterLimits } from '../../api/endpoints/actions';

export type Filter = FilterNode | Record<string, never>;
export type FilterCheck = Extract<FilterNode, { field: string }>;
export type FilterIssue = { path: string; reason: string };
export const operatorOptions = [
  { value: 'eq', label: 'is' }, { value: 'ne', label: 'is not' },
  { value: 'in', label: 'is one of' }, { value: 'not_in', label: 'is not one of' },
  { value: 'exists', label: 'exists' }, { value: 'prefix', label: 'starts with' },
];
export function children(node: Filter): { key: string; node: FilterNode }[] {
  if ('all' in node) return node.all.map((node, i) => ({ key: '/all/' + i, node }));
  if ('any' in node) return node.any.map((node, i) => ({ key: '/any/' + i, node }));
  if ('not' in node) return [{ key: '/not', node: node.not }];
  return [];
}
export function measureFilter(node: Filter, depth = 1): { nodes: number; checks: number; depth: number } {
  if (!Object.keys(node).length) return { nodes: 0, checks: 0, depth: 0 };
  return children(node).reduce((total, child) => {
    const size = measureFilter(child.node, depth + 1);
    return { nodes: total.nodes + size.nodes, checks: total.checks + size.checks, depth: Math.max(total.depth, size.depth) };
  }, { nodes: 1, checks: 'field' in node ? 1 : 0, depth });
}
/** JSON pointers refer to the wire tree, including the not/any nodes of None of. */
export function replaceFilter(root: Filter, path: string, replacement: FilterNode | null): Filter {
  if (!path) return replacement || {};
  const visit = (node: Filter, prefix: string): FilterNode | null => {
    if (prefix === path) return replacement;
    if ('all' in node || 'any' in node) {
      const mode = 'all' in node ? 'all' : 'any';
      const items = children(node).map(child => visit(child.node, prefix + child.key)).filter((n): n is FilterNode => n !== null);
      return items.length ? mode === 'all' ? { all: items } : { any: items } : null;
    }
    if ('not' in node) { const child = visit(node.not, prefix + '/not'); return child ? { not: child } : null; }
    return node as FilterNode;
  };
  return visit(root, '') || {};
}
export function withinLimits(tree: Filter, limits: FilterLimits): boolean {
  const size = measureFilter(tree);
  return size.depth <= limits.max_depth && size.nodes <= limits.max_nodes && size.checks <= limits.max_checks
    && new TextEncoder().encode(JSON.stringify(tree)).length <= limits.max_bytes
    && children(tree).length <= limits.max_children && children(tree).every(child => withinLimits(child.node, limits));
}
export function filterSentence(node: Filter): string {
  if ('field' in node) {
    if (node.op === 'exists') return node.field + (node.value ? ' exists' : ' does not exist');
    return node.field + ' ' + operatorOptions.find(o => o.value === node.op)?.label + ' ' + JSON.stringify(node.value);
  }
  if ('not' in node) return 'NOT (' + filterSentence(node.not) + ')';
  const items = children(node);
  return items.length ? '(' + items.map(child => filterSentence(child.node)).join('all' in node ? ' AND ' : ' OR ') + ')' : 'Always';
}
export function filterIssueFromError(error: any): FilterIssue | undefined {
  let details = error?.data?.details;
  if (typeof details === 'string') { try { details = JSON.parse(details); } catch { return; } }
  return details?.code === 'invalid_filter' && typeof details.path === 'string'
    ? { path: details.path, reason: String(details.reason || 'Check this condition.') } : undefined;
}
