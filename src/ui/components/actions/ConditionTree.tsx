import React from 'react';
import { Icon, Text } from '@ui';
import { children, filterSentence, groupName, groupSummary, type Filter } from './filterTree';
import './conditionTree.css';
import { seenValue } from './runTrace';
type Item = { path: string; node: Filter; state?: string; children: Item[] };
/** A reusable author-ordered tree. None-of hides its wire-only Any wrapper while
 * retaining original pointers and preorder trace positions for U1b. */
function treeItems(value: Filter, trace?: string): Item {
  let cursor = 0;
  function visit(node: Filter, path: string): Item {
    const state = Object.keys(node).length ? trace?.[cursor++] : trace === undefined ? undefined : 'T';
    if ('not' in node && 'any' in node.not) {
      cursor++;
      return { path, node, state, children: node.not.any.map((child, i) => visit(child, path + '/not/any/' + i)) };
    }
    return { path, node, state, children: children(node).map(child => visit(child.node, path + child.key)) };
  }
  return visit(value, '');
}

export default function ConditionTree({ value, trace, seen, onActivate, debugId }: {
  value: Filter; trace?: string; seen?: Record<string, unknown>; onActivate?: (path: string) => void; debugId: string;
}) {
  const [closed, setClosed] = React.useState<Set<string>>(() => new Set());
  const [active, setActive] = React.useState('');
  const root = React.useRef<HTMLUListElement>(null);
  const model = treeItems(value, trace);
  const visible: Item[] = [];
  function flatten(item: Item) { visible.push(item); if (!closed.has(item.path)) item.children.forEach(flatten); }
  flatten(model);
  const selected = visible.some(item => item.path === active) ? active : '';
  function focus(path: string) {
    setActive(path);
    Array.from(root.current?.querySelectorAll<HTMLElement>('[role="treeitem"]') || []).find(el => el.dataset.treePath === path)?.focus();
  }
  function toggle(path: string) { setClosed(prev => { const next = new Set(prev); if (next.has(path)) next.delete(path); else next.add(path); return next; }); }
  function key(event: React.KeyboardEvent, item: Item, parent: string | undefined) {
    const index = visible.indexOf(item);
    switch (event.key) {
      case 'ArrowDown': event.preventDefault(); focus(visible[Math.min(index + 1, visible.length - 1)].path); break;
      case 'ArrowUp': event.preventDefault(); focus(visible[Math.max(index - 1, 0)].path); break;
      case 'Home': event.preventDefault(); focus(''); break;
      case 'End': event.preventDefault(); focus(visible[visible.length - 1].path); break;
      case 'ArrowRight':
        event.preventDefault();
        if (item.children.length && closed.has(item.path)) toggle(item.path);
        else if (item.children.length) focus(item.children[0].path);
        break;
      case 'ArrowLeft':
        event.preventDefault();
        if (item.children.length && !closed.has(item.path)) toggle(item.path);
        else if (parent !== undefined) focus(parent);
        break;
      case ' ': event.preventDefault(); if (item.children.length) toggle(item.path); break;
      case 'Enter': event.preventDefault(); onActivate?.(item.path); break;
      default: return;
    }
    event.stopPropagation();
  }
  function render(item: Item, level: number, position: number, count: number, parent?: string): React.ReactNode {
    const isGroup = !('field' in item.node) && item.children.length > 0;
    const expanded = !closed.has(item.path);
    const title = 'field' in item.node ? filterSentence(item.node) : groupSummary(item.node);
    const status = item.state === 'T' ? 'Matched' : item.state === 'F' ? 'Did not match' : trace !== undefined ? 'Not evaluated' : '';
    return <li key={item.path} role="treeitem" className="condition-tree-branch" aria-label={title + ', level ' + level + ', ' + position + ' of ' + count + (status ? ', ' + status : '') + (seen && 'field' in item.node ? ', saw: ' + seenValue(seen, item.node.field) : '')} aria-level={level} aria-posinset={position} aria-setsize={count} aria-expanded={isGroup ? expanded : undefined} aria-selected={item.path === selected} tabIndex={item.path === selected ? 0 : -1} data-tree-path={item.path} data-debug-id={debugId + '-node-' + (item.path.replaceAll('/', '-') || 'root')} onFocus={event => { event.stopPropagation(); setActive(item.path); }} onKeyDown={event => key(event, item, parent)} onClick={event => { event.stopPropagation(); setActive(item.path); onActivate?.(item.path); }}>
      <div className="condition-tree-node">
        {isGroup ? <button type="button" tabIndex={-1} aria-label={(expanded ? 'Collapse ' : 'Expand ') + groupName(item.node)} data-debug-id={debugId + '-collapse-' + (item.path.replaceAll('/', '-') || 'root')} className="condition-tree-chevron" onClick={event => { event.stopPropagation(); toggle(item.path); focus(item.path); }}><Icon name={expanded ? 'chevron-down' : 'chevron-right'} size="md" /></button> : null}
        <div className="min-w-0"><Text role={isGroup ? 'title' : 'body-sm'}>{title}</Text>{status ? <Text as="span" role="label" tone={item.state === 'T' ? 'success' : item.state === 'F' ? 'danger' : 'muted'}>{item.state === 'T' || item.state === 'F' ? <Icon name={item.state === 'T' ? 'check' : 'close'} size="sm" /> : null} {status}</Text> : null}{seen && 'field' in item.node ? <Text role="body-sm" tone="muted">saw: {seenValue(seen, item.node.field)}</Text> : null}</div>
      </div>
      {isGroup && expanded ? <ul role="group" className="condition-tree-children">{item.children.map((child, i) => render(child, level + 1, i + 1, item.children.length, item.path))}</ul> : null}
    </li>;
  }
  return <div className="condition-tree-diagram">
    <Text role="body-sm" tone="muted">{onActivate ? 'Select a node to edit it. ' : ''}Use arrow keys to navigate and Left or Right to collapse or expand groups.{onActivate ? ' Press Enter to edit.' : ''}</Text>
    <ul ref={root} role="tree" aria-label="Condition tree" className="condition-tree-root">{render(model, 1, 1, 1)}</ul>
    <Text role="body-sm">In words: {filterSentence(value)}</Text>
  </div>;
}
