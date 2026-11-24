import React from 'react';
import { Alert, Button, FormField, Input, Select, Textarea, Text, Icon } from '@ui';
import { useTestActionFilterMutation, type FilterLimits, type FilterNode, type TriggerEvent } from '../../api/endpoints/actions';
import { children, filterSentence, filterReason, groupSummary, measureFilter, operatorOptions, replaceFilter, withinLimits, type Filter, type FilterCheck, type FilterIssue } from './filterTree';
import ConditionTree from './ConditionTree';

const stack = 'flex min-w-0 flex-col gap-[var(--space-3)]';
const card = stack + ' rounded-[var(--radius-lg)] border border-subtle bg-surface-raised p-[var(--space-2)] sm:p-[var(--space-3)]';

function CheckValue({ check, onChange, onRemoveValue, values, debugId, limits }: { check: FilterCheck; onChange: (v: FilterCheck) => void; onRemoveValue?: (v: FilterCheck) => void; values: string[]; debugId: string; limits: FilterLimits }) {
  const list = check.op === 'in' || check.op === 'not_in';
  if (check.op === 'exists' || typeof check.value === 'boolean') return <Select aria-label="Condition value" data-debug-id={debugId + '-value'} value={String(check.value)} options={[{ value: 'true', label: check.op === 'exists' ? 'Present' : 'true' }, { value: 'false', label: check.op === 'exists' ? 'Missing' : 'false' }]} onChange={v => onChange({ ...check, value: v === 'true' })} />;
  if (list && Array.isArray(check.value)) {
    const items = check.value;
    return <div className={stack}>{items.map((item, index) => <div key={index} className={stack}>
      {!values.length ? <Select aria-label={'Value type ' + (index + 1)} data-debug-id={debugId + '-item-type-' + index} value={typeof item} options={['string', 'number', 'boolean'].map(value => ({ value, label: value }))} onChange={type => onChange({ ...check, value: items.map((v, i) => i === index ? type === 'boolean' ? true : type === 'number' ? 0 : '' : v) })} /> : null}
      <CheckValue check={{ ...check, op: 'eq', value: item }} values={values} limits={limits} debugId={debugId + '-item-' + index} onChange={next => onChange({ ...check, value: items.map((v, i) => i === index ? next.value as typeof item : v) })} />
      {items.length > 1 ? <Button type="button" variant="ghost" data-debug-id={debugId + '-remove-value-' + index} onClick={() => onRemoveValue?.({ ...check, value: items.filter((_, i) => i !== index) })}>Remove value {index + 1}</Button> : null}
    </div>)}<Button type="button" variant="secondary" data-debug-id={debugId + '-add-value'} disabled={items.length >= limits.max_values} onClick={() => onChange({ ...check, value: [...items, values[0] || ''] })}>Add value</Button></div>;
  }
  if (typeof check.value === 'string' && values.length && check.op !== 'prefix') return <Select aria-label="Condition value" data-debug-id={debugId + '-value'} value={check.value} options={[...new Set([check.value, ...values])].map(value => ({ value, label: value || 'Choose a value' }))} onChange={value => onChange({ ...check, value })} />;
  return <Input aria-label="Condition value" data-debug-id={debugId + '-value'} type={typeof check.value === 'number' ? 'number' : 'text'} required value={String(check.value)} onChange={value => onChange({ ...check, value: typeof check.value === 'number' ? Number(value) : value })} />;
}

/** Nested labelled fieldsets use native Tab navigation, including all embedded controls. */
export default function ConditionTreeEditor({ value, onChange, event, limits, debugId, error }: {
  value: Filter; onChange: (v: Filter) => void; event: TriggerEvent; limits: FilterLimits; debugId: string; error?: FilterIssue;
}) {
  const [testFilter, testState] = useTestActionFilterMutation();
  const [sampleOpen, setSampleOpen] = React.useState(false);
  const [sample, setSample] = React.useState('{}');
  const [sampleError, setSampleError] = React.useState('');
  const [result, setResult] = React.useState<{ matched: boolean; nodes: string; filter: Filter }>();
  const [testIssue, setTestIssue] = React.useState<FilterIssue>();
  const generation = React.useRef(0);
  const [undo, setUndo] = React.useState<Filter>();
  const [view, setView] = React.useState<'editor' | 'tree'>('editor');
  const [collapsed, setCollapsed] = React.useState<Set<string>>(() => new Set());
  const editor = React.useRef<HTMLElement>(null);
  const pendingFocus = React.useRef<string | undefined>(undefined);
  const restoredPath = React.useRef('');
  const issue = error || testIssue;
  function focusNode(path: string) {
    const node = Array.from(editor.current?.querySelectorAll<HTMLElement>('[data-node-path]') || []).find(el => el.dataset.nodePath === path);
    const control = node?.querySelector<HTMLElement>('input, [role="combobox"], button') || node;
    control?.focus();
    control?.scrollIntoView?.({ block: 'nearest' });
  }
  React.useLayoutEffect(() => {
    if (pendingFocus.current === undefined) return;
    const path = pendingFocus.current; pendingFocus.current = undefined;
    if (path === 'undo') editor.current?.querySelector<HTMLElement>('[data-condition-undo]')?.focus();
    else focusNode(path);
  });
  React.useEffect(() => {
    if (!issue) return;
    setCollapsed(new Set()); setView('editor'); pendingFocus.current = issue.path;
  }, [issue]);
  React.useEffect(() => { generation.current++; setResult(undefined); setTestIssue(undefined); setSampleError(''); }, [value, event.event_type, sample]);
  const newCheck = (): FilterCheck => ({ field: event.fields[0]?.field || 'data.value', op: 'eq', value: event.fields[0]?.values[0] || '' });
  function change(next: Filter) { setUndo(undefined); onChange(next); }
  function remove(path: string) { restoredPath.current = path; pendingFocus.current = 'undo'; setUndo(value); onChange(replaceFilter(value, path, null)); }
  function render(node: FilterNode, path: string, level = 1, position = 1, count = 1): React.ReactNode {
    const id = debugId + '-node-' + (path.replaceAll('/', '-') || 'root');
    const invalid = issue?.path === path || ('not' in node && 'any' in node.not && issue?.path === path + '/not');
    const errorText = invalid ? filterReason(issue?.reason || '') : undefined;
    const accessibleName = ('field' in node ? 'Check' : groupSummary(node)) + ' ' + position + ' of ' + count + ', level ' + level;
    if ('field' in node) {
      const field = event.fields.find(f => f.field === node.field);
      const ops = operatorOptions.filter(op => !field || field.operators.includes(op.value));
      return <fieldset key={path} tabIndex={-1} data-node-path={path} aria-label={accessibleName} aria-invalid={invalid || undefined} aria-describedby={invalid ? id + '-error' : undefined} className={card + ' condition-editor-fieldset' + (invalid ? ' border-danger' : '')}>
        <legend><Text role="label">Check</Text></legend>
        <div className="grid min-w-0 grid-cols-1 gap-[var(--space-2)] sm:grid-cols-3">
          <FormField label="Field">{event.free_data_paths ? <Input aria-label="Condition field" data-debug-id={id + '-field'} required value={node.field} onChange={field => change(replaceFilter(value, path, { ...node, field }))} />
            : <Select aria-label="Condition field" data-debug-id={id + '-field'} value={node.field} options={[...new Set([node.field, ...event.fields.map(f => f.field)])].map(value => ({ value, label: value }))} onChange={field => { const descriptor = event.fields.find(f => f.field === field); change(replaceFilter(value, path, { field, op: 'eq', value: descriptor?.values[0] || '' })); }} />}</FormField>
          <FormField label="Operator"><Select aria-label="Condition operator" data-debug-id={id + '-operator'} value={node.op} options={ops} onChange={op => {
            const next = op as FilterCheck['op'];
            const scalar = Array.isArray(node.value) ? node.value[0] || '' : node.value;
            const nextValue = next === 'exists' ? true : next === 'in' || next === 'not_in' ? [scalar] : next === 'prefix' ? String(scalar) : scalar;
            change(replaceFilter(value, path, { ...node, op: next, value: nextValue }));
          }} /></FormField>
          <div className={stack}>
            {!['exists', 'in', 'not_in', 'prefix'].includes(node.op) && !field?.values.length ? <FormField label="Value type"><Select aria-label="Condition value type" data-debug-id={id + '-value-type'} value={typeof node.value} options={['string', 'number', 'boolean'].map(value => ({ value, label: value }))} onChange={type => change(replaceFilter(value, path, { ...node, value: type === 'boolean' ? true : type === 'number' ? 0 : '' }))} /></FormField> : null}
            <FormField label={node.op === 'exists' ? 'Presence' : 'Value'}><CheckValue check={node} values={field?.values || []} limits={limits} debugId={id} onChange={next => change(replaceFilter(value, path, next))} onRemoveValue={next => { restoredPath.current = path; pendingFocus.current = 'undo'; setUndo(value); onChange(replaceFilter(value, path, next)); }} /></FormField>
          </div>
        </div>
        {node.op === 'ne' || node.op === 'not_in' ? <Text role="body-sm" tone="muted">Also matches when the field is missing. Add an exists check if it must be present.</Text> : null}
        {errorText ? <p id={id + '-error'} role="alert" className="text-danger">{errorText}</p> : null}
        <div className="condition-editor-toolbar">
          <Button type="button" variant="secondary" data-debug-id={id + '-negate'} disabled={!withinLimits(replaceFilter(value, path, { not: node }), limits)} onClick={() => change(replaceFilter(value, path, { not: node }))}>Negate check</Button>
          <Button type="button" variant="ghost" data-debug-id={id + '-remove'} onClick={() => remove(path)}>Remove check</Button>
        </div>
      </fieldset>;
    }
    const none = 'not' in node && 'any' in node.not;
    const wrapper = 'not' in node && !none;
    const group = none && 'not' in node ? node.not : node;
    const groupPath = none ? path + '/not' : path;
    const items = children(group);
    const mode = none ? 'none' : 'all' in node ? 'all' : 'any' in node ? 'any' : 'not';
    const append = (child: FilterNode): Filter => {
      const next = [...items.map(c => c.node), child];
      return replaceFilter(value, path, none ? { not: { any: next } } : 'all' in node ? { all: next } : { any: next });
    };
    const checkCandidate = append(newCheck());
    const groupCandidate = append({ all: [newCheck()] });
    const isCollapsed = collapsed.has(path);
    return <fieldset key={path} tabIndex={-1} data-node-path={path} aria-label={accessibleName} aria-invalid={invalid || undefined} aria-describedby={invalid ? id + '-error' : undefined} className={card + ' condition-editor-fieldset' + (invalid ? ' border-danger' : '')}>
      <legend><Button type="button" variant="ghost" data-debug-id={id + '-collapse'} aria-expanded={!isCollapsed} aria-controls={id + '-contents'} onClick={() => setCollapsed(prev => { const next = new Set(prev); if (next.has(path)) next.delete(path); else next.add(path); return next; })}><Icon name={isCollapsed ? 'chevron-right' : 'chevron-down'} size="md" />{groupSummary(node)}</Button></legend>
      <div id={id + '-contents'} hidden={isCollapsed} className={isCollapsed ? undefined : stack}>
      {!wrapper ? <FormField label="Group mode"><Select aria-label={'Group mode, level ' + level + ', group ' + position} data-debug-id={id + '-mode'} value={mode} options={[{ value: 'all', label: 'All of' }, { value: 'any', label: 'Any of' }, { value: 'none', label: 'None of', disabled: !withinLimits(replaceFilter(value, path, { not: { any: items.map(c => c.node) } }), limits) }]} onChange={mode => {
        const nodes = items.map(c => c.node);
        const next: FilterNode = mode === 'none' ? { not: { any: nodes } } : mode === 'all' ? { all: nodes } : { any: nodes };
        if (withinLimits(replaceFilter(value, path, next), limits)) change(replaceFilter(value, path, next));
      }} /></FormField> : <Text role="body-sm">Match when the following condition is false.</Text>}
      <div className={stack + ' sm:pl-[var(--space-2)]'}>{items.map((child, i) => render(child.node, groupPath + child.key, level + 1, i + 1, items.length))}</div>
      {!wrapper ? <div className="condition-editor-toolbar">
        <Button type="button" variant="secondary" data-debug-id={id + '-add-check'} disabled={!withinLimits(checkCandidate, limits)} onClick={() => change(checkCandidate)}>Add check</Button>
        <Button type="button" variant="secondary" data-debug-id={id + '-add-group'} disabled={!withinLimits(groupCandidate, limits)} onClick={() => change(groupCandidate)}>Add group</Button>
      </div> : null}
      {wrapper && 'not' in node ? <Button type="button" variant="secondary" data-debug-id={id + '-unnegate'} onClick={() => change(replaceFilter(value, path, node.not))}>Remove negation</Button> : null}
      <Button type="button" variant="ghost" data-debug-id={id + '-remove'} onClick={() => remove(path)}>Remove {wrapper ? 'Not wrapper' : 'group'}</Button>
      </div>
      {errorText ? <p id={id + '-error'} role="alert" className="text-danger">{errorText}</p> : null}
    </fieldset>;
  }
  async function runTest() {
    const requestGeneration = generation.current;
    setSampleError(''); setResult(undefined); setTestIssue(undefined);
    try {
      const parsed: unknown = JSON.parse(sample);
      if (!parsed || Array.isArray(parsed) || typeof parsed !== 'object') { setSampleError('Enter a JSON object: an event envelope or webhook body.'); return; }
      const response = await testFilter({ event_type: event.event_type, filter: value, event: parsed as Record<string, unknown> }).unwrap();
      if (requestGeneration !== generation.current) return;
      if (!response.valid) setTestIssue({ path: response.path, reason: response.reason });
      else setResult({ matched: response.matched, nodes: response.nodes, filter: structuredClone(value) });
    } catch (error) {
      if (requestGeneration === generation.current) setSampleError(error instanceof SyntaxError ? 'Enter valid JSON before testing.' : 'Could not test this event. Try again.');
    }
  }
  return <section ref={editor} aria-label="Event conditions" className={stack + ' condition-editor'}>
    <div role="group" aria-label="Condition view" className="condition-editor-toolbar">
      <Button type="button" variant={view === 'editor' ? 'secondary' : 'ghost'} aria-pressed={view === 'editor'} data-debug-id={debugId + '-view-editor'} onClick={() => setView('editor')}>Editor</Button>
      <Button type="button" variant={view === 'tree' ? 'secondary' : 'ghost'} aria-pressed={view === 'tree'} data-debug-id={debugId + '-view-tree'} onClick={() => setView('tree')}>Tree</Button>
    </div>
    {view === 'tree' ? <ConditionTree value={value} debugId={debugId + '-diagram'} onActivate={path => { setView('editor'); setCollapsed(new Set()); pendingFocus.current = path; }} /> : null}
    <div hidden={view !== 'editor'}>
    {Object.keys(value).length ? render(value as FilterNode, '') : <div className={card}><Text role="title">Always</Text><Text role="body-sm" tone="muted">Every event of this type matches. Add a check to narrow it down.</Text><Button type="button" variant="secondary" data-debug-id={debugId + '-add-first-check'} disabled={!withinLimits({ all: [newCheck()] }, limits)} onClick={() => change({ all: [newCheck()] })}>Add check</Button></div>}
    </div>
    {undo ? <div role="status" className="condition-editor-toolbar"><Text role="body-sm">Item removed.</Text><Button type="button" variant="secondary" data-condition-undo data-debug-id={debugId + '-undo'} onClick={() => { pendingFocus.current = restoredPath.current; change(undo); setUndo(undefined); }}>Undo removal</Button></div> : null}
    {view === 'editor' ? <Text role="body-sm">In words: {filterSentence(value)}. Deliver the action when this matches.</Text> : null}
    <Text role="caption" tone="muted">{measureFilter(value).checks} of {limits.max_checks} checks; {measureFilter(value).nodes} of {limits.max_nodes} nodes; maximum depth {limits.max_depth}. Add controls stop at these limits.</Text>
    {issue && !Object.keys(value).length ? <Alert tone="danger" title="Check conditions">{filterReason(issue.reason)}</Alert> : null}
    <Button type="button" variant="secondary" data-debug-id={debugId + '-sample-toggle'} aria-expanded={sampleOpen} onClick={() => setSampleOpen(!sampleOpen)}>Test with a sample event</Button>
    {sampleOpen ? <div className={card}>
      <FormField label="Sample event JSON" hint="Paste an event envelope or webhook body. Testing sends no event and delivers no prompt."><Textarea data-debug-id={debugId + '-sample'} aria-label="Sample event JSON" rows={6} value={sample} onChange={setSample} /></FormField>
      <Button type="button" variant="secondary" data-debug-id={debugId + '-test'} loading={testState.isLoading} onClick={runTest}>Test conditions</Button>
      <div aria-live="polite" className="condition-test-result">{testState.isLoading ? <Text role="body-sm">Testing sample event…</Text> : sampleError ? <Alert tone="danger" title="Couldn't test sample">{sampleError}</Alert> : result ? <FilterResultTree value={result.filter} nodes={result.nodes} matched={result.matched} /> : <Text role="body-sm" tone="muted">No test result yet.</Text>}</div>
    </div> : null}
  </section>;
}

/** Shared read-only view; consumes the server's full preorder trace, including wrappers. */
export function FilterResultTree({ value, nodes, matched }: { value: Filter; nodes: string; matched: boolean }) {
  return <div className={stack} aria-label="Condition test results"><Text role="title" tone={matched ? 'success' : 'danger'}>{matched ? 'Sample matches' : 'Sample does not match'}</Text><ConditionTree value={value} trace={nodes} debugId="condition-test-results" /></div>;
}
