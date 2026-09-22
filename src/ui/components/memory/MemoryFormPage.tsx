/**
 * MemoryFormPage — `/memory/new` and `/memory/:id/edit`.
 * ------------------------------------------------------------------
 * One page serves create and edit (REQ-UI-9). Spec: `docs/ui-rebuild/memory.md` §7,
 * as amended by A1.1 — a memory the USER writes is born `active`, so nothing here
 * says "starts as a proposal", and "Save & approve" appears only when editing an
 * existing `pending` proposal an AGENT raised.
 *
 * Two things this page exists to get right:
 *  - **Empty scope means "applies to all", not "nothing".** Three reinforcing
 *    signals, no new control: the placeholders say "All projects", a live sentence
 *    restates the whole selection in English, and clearing the last chip announces
 *    its own consequence.
 *  - **Server errors land on the field that caused them**, not in a banner.
 */
import React from 'react';
import {
  Alert,
  Button,
  Combobox,
  FormField,
  Icon,
  IconButton,
  Input,
  Modal,
  ModalBody,
  ModalFooter,
  PageShell,
  Select,
  Text,
  Textarea,
} from '@ui';
import {
  SCOPE_DIMS,
  ScopeCatalogNote,
  emptyTargeting,
  scopeCatalogEmptyLabel,
  targetingFromRecord,
  useMemoryScopeCatalog,
  type Targeting,
} from '@ui';
import {
  memoryErrorText,
  useApproveMemoryMutation,
  useCreateMemoryMutation,
  useGetMemoryQuery,
  useUpdateMemoryMutation,
} from '../../api/endpoints/memory';
import {
  MEMORY_TYPE_OPTIONS,
  TITLE_MAX_LENGTH,
  editCrumbs,
  editGateMessage,
  isEditable,
  mapServerError,
  memoryListHref,
  memoryStatus,
  memoryTitle,
  memoryViewHref,
  navigateTo,
  newCrumbs,
  type MemoryFormField,
} from './memoryModel';

interface FormState {
  title: string;
  type: string;
  description: string;
  body: string;
  evidence: string;
  targeting: Targeting;
}

const EMPTY_FORM: FormState = {
  title: '',
  type: 'fact',
  description: '',
  body: '',
  evidence: '',
  targeting: emptyTargeting(),
};

/* ------------------------------------------------------------------ *
 * The unsaved-changes guard (REQ-UI-21)
 * ------------------------------------------------------------------ */

/**
 * Raises a confirm before a dirty form is abandoned — by a breadcrumb, an in-app
 * link, the browser's back button or a reload.
 *
 * In-app navigation is hash-based, so an intercepted click is enough for links;
 * `popstate` needs the other half: the browser has ALREADY moved by the time we
 * hear about it, so the guard pushes the form's own URL back on and remembers
 * where the user was going.
 */
function useUnsavedChangesGuard(dirty: boolean) {
  const [pendingHref, setPendingHref] = React.useState('');
  const dirtyRef = React.useRef(dirty);
  dirtyRef.current = dirty;
  const selfHref = React.useRef('');

  React.useEffect(() => {
    selfHref.current = window.location.href;
  }, []);

  React.useEffect(() => {
    if (!dirty) return undefined;

    const onBeforeUnload = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      event.returnValue = '';
    };

    const onClick = (event: MouseEvent) => {
      if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey) return;
      const anchor = (event.target as HTMLElement | null)?.closest?.('a[href]') as HTMLAnchorElement | null;
      if (!anchor) return;
      const href = anchor.getAttribute('href') || '';
      if (!href.startsWith('#')) return;
      if (window.location.hash === href) return;
      event.preventDefault();
      setPendingHref(href);
    };

    const onPopState = () => {
      if (!dirtyRef.current) return;
      const attempted = window.location.hash;
      window.history.pushState(window.history.state, '', selfHref.current);
      setPendingHref(attempted);
    };

    window.addEventListener('beforeunload', onBeforeUnload);
    document.addEventListener('click', onClick, true);
    window.addEventListener('popstate', onPopState);
    return () => {
      window.removeEventListener('beforeunload', onBeforeUnload);
      document.removeEventListener('click', onClick, true);
      window.removeEventListener('popstate', onPopState);
    };
  }, [dirty]);

  return {
    pendingHref,
    keepEditing: () => setPendingHref(''),
    discard: () => {
      const href = pendingHref;
      dirtyRef.current = false;
      setPendingHref('');
      if (href) navigateTo(href);
    },
    /** Leave deliberately (a successful save), without the guard interfering. */
    leaveTo: (href: string) => {
      dirtyRef.current = false;
      navigateTo(href);
    },
  };
}

/* ------------------------------------------------------------------ *
 * The page
 * ------------------------------------------------------------------ */

export default function MemoryFormPage({ memoryId }: { memoryId?: string }) {
  const editing = Boolean(memoryId);
  const catalog = useMemoryScopeCatalog();

  const memoryQuery = useGetMemoryQuery({ memoryId: memoryId || '' }, { skip: !memoryId });
  const record = memoryQuery.data;
  const recordStatus = memoryStatus(record);
  // Only pending/active records may be edited — a RECORD-level gate, not a
  // field-level one (content_service.odin:168-188).
  const gated = editing && Boolean(record) && !isEditable(recordStatus);

  const [form, setForm] = React.useState<FormState>(EMPTY_FORM);
  const [dirty, setDirty] = React.useState(false);
  const [errors, setErrors] = React.useState<Partial<Record<MemoryFormField, string>>>({});
  const [errorDimension, setErrorDimension] = React.useState('');
  const [saving, setSaving] = React.useState<'save' | 'approve' | ''>('');

  const titleRef = React.useRef<HTMLInputElement | null>(null);
  const typeRef = React.useRef<HTMLButtonElement | null>(null);
  const bodyRef = React.useRef<HTMLTextAreaElement | null>(null);
  const scopeRef = React.useRef<HTMLDivElement | null>(null);

  const [createMemory] = useCreateMemoryMutation();
  const [updateMemory] = useUpdateMemoryMutation();
  const [approveMemory] = useApproveMemoryMutation();

  // Seed from the record once it arrives. Keyed on identity, never on the whole
  // record: re-seeding on a cache refresh would clobber edits in progress.
  React.useEffect(() => {
    if (!record) return;
    setForm({
      title: String(record.title || ''),
      type: String(record.type || 'fact'),
      description: String(record.description || ''),
      body: String(record.body || ''),
      evidence: String(record.evidence || ''),
      targeting: targetingFromRecord(record),
    });
    setDirty(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [record?.memoryId]);

  const guard = useUnsavedChangesGuard(dirty && !gated);

  function update<K extends keyof FormState>(key: K, value: FormState[K]) {
    setForm((prev) => ({ ...prev, [key]: value }));
    setDirty(true);
  }

  /** Client-side validation. Every rule here is the server's except the title cap. */
  function validate(): boolean {
    const next: Partial<Record<MemoryFormField, string>> = {};
    if (form.title.trim().length > TITLE_MAX_LENGTH) {
      next.title = `Title must be ${TITLE_MAX_LENGTH} characters or fewer.`;
    }
    if (!(MEMORY_TYPE_OPTIONS as readonly string[]).includes(form.type)) {
      next.type = 'Choose a memory type.';
    }
    if (!form.body.trim()) {
      next.body = 'Body is required — this is the text your agents will read.';
    }
    setErrors(next);
    // The first failing field is focused and scrolled into view.
    if (next.title) titleRef.current?.focus();
    else if (next.type) typeRef.current?.focus();
    else if (next.body) bodyRef.current?.focus();
    return Object.keys(next).length === 0;
  }

  function applyServerError(err: unknown) {
    const mapped = mapServerError(memoryErrorText(err));
    setErrors({ [mapped.field]: mapped.message });
    setErrorDimension(mapped.dimension || '');
    if (mapped.field === 'body') bodyRef.current?.focus();
    else if (mapped.field === 'type') typeRef.current?.focus();
    else if (mapped.field === 'title') titleRef.current?.focus();
    else if (mapped.field === 'scope') scopeRef.current?.scrollIntoView({ block: 'center' });
  }

  async function save(mode: 'save' | 'approve') {
    if (!validate()) return;
    setSaving(mode);
    setErrorDimension('');
    const payload = {
      title: form.title.trim(),
      description: form.description.trim(),
      body: form.body,
      evidence: form.evidence.trim(),
      type: form.type,
      ...form.targeting,
    };
    try {
      if (!editing) {
        // A1.1: a memory the user writes is in force immediately. `pending` is left
        // to mean exactly one thing — an agent proposed this and no human has
        // decided yet — which is what makes an empty Proposals tab the good state.
        const created = await createMemory({ ...payload, status: 'active' }).unwrap();
        const newId = String(created?.memory_id || created?.memoryId || '');
        guard.leaveTo(newId ? memoryViewHref(newId) : memoryListHref());
        return;
      }
      if (mode === 'approve') {
        // §7/F14: from a pending proposal, `POST …/approve` with the edited body
        // saves the edits AND approves in one call — "approve with my corrections".
        await approveMemory({ memoryId: memoryId as string, ...payload }).unwrap();
      } else {
        await updateMemory({ memoryId: memoryId as string, ...payload }).unwrap();
      }
      guard.leaveTo(memoryViewHref(memoryId as string));
    } catch (err) {
      applyServerError(err);
    } finally {
      setSaving('');
    }
  }

  if (editing && memoryQuery.isLoading) {
    return <PageShell rhythm="banded" title="Edit memory" breadcrumbs={editCrumbs('Loading…', memoryId || '')} loading />;
  }

  const heading = editing ? 'Edit memory' : 'New memory';
  const crumbs = editing ? editCrumbs(memoryTitle(record), memoryId || '') : newCrumbs();

  /* ---------------- The scope sentence (§7) ----------------
   * The AND is carried by the sentence's grammar — one sentence, four clauses, all
   * of which must hold — which is exactly what the backend does. */
  const scopeClauses = SCOPE_DIMS.map((dim) => {
    const ids = form.targeting[dim.key];
    if (ids.length === 0) return dim.allLabel.toLowerCase();
    const names = ids.map((id) => catalog[dim.key].byId.get(id) || id).join(', ');
    return `${dim.label.toLowerCase()} ${names}`;
  });
  const scopeSentence = `This memory applies to ${scopeClauses.slice(0, -1).join(', ')}, and ${scopeClauses[scopeClauses.length - 1]}.`;
  const scopeIsGlobal = SCOPE_DIMS.every((dim) => form.targeting[dim.key].length === 0);

  return (
    <PageShell
      rhythm="banded"
      width="content"
      title={heading}
      breadcrumbs={crumbs}
    >
      <div data-debug-id="memory-form-page" className="flex w-full max-w-3xl min-w-0 flex-col gap-4">
        {gated ? (
          <Alert tone="warning" title="This memory can't be edited">
            <div className="flex flex-col items-start gap-3">
              <span>{editGateMessage(recordStatus)}</span>
              <Button
                variant="primary"
                data-debug-id="memory-form-restore"
                onClick={async () => {
                  try {
                    await approveMemory({ memoryId: memoryId as string }).unwrap();
                    navigateTo(memoryViewHref(memoryId as string));
                  } catch (err) {
                    setErrors({ form: memoryErrorText(err) });
                  }
                }}
              >
                {recordStatus === 'rejected' ? 'Approve' : 'Restore'}
              </Button>
            </div>
          </Alert>
        ) : null}

        {errors.form ? <Alert tone="danger" title="That didn't save">{errors.form}</Alert> : null}

        <FormField
          label="Title"
          error={errors.title}
          hint={`Optional. ${TITLE_MAX_LENGTH} characters or fewer — it is the row label, the breadcrumb and the search result.`}
        >
          <Input
            ref={titleRef}
            value={form.title}
            onChange={(next) => update('title', next)}
            width="full"
            disabled={gated}
            invalid={Boolean(errors.title)}
            data-debug-id="memory-form-title"
            placeholder="A short name for this memory"
          />
        </FormField>

        <FormField label="Type" required error={errors.type}>
          <Select
            ref={typeRef}
            value={form.type}
            onChange={(next) => update('type', next)}
            width="full"
            disabled={gated}
            invalid={Boolean(errors.type)}
            data-debug-id="memory-form-type"
          >
            {MEMORY_TYPE_OPTIONS.map((type) => (
              <option key={type} value={type}>{type}</option>
            ))}
          </Select>
        </FormField>

        <FormField label="Description" hint="Optional. A one-line summary. Markdown.">
          <Textarea
            value={form.description}
            onChange={(next) => update('description', next)}
            rows={3}
            width="full"
            disabled={gated}
            data-debug-id="memory-form-description"
          />
        </FormField>

        <FormField label="Body" required error={errors.body} hint="Markdown. This is the text your agents receive.">
          <Textarea
            ref={bodyRef}
            value={form.body}
            onChange={(next) => update('body', next)}
            rows={12}
            width="full"
            disabled={gated}
            invalid={Boolean(errors.body)}
            data-debug-id="memory-form-body"
            className="font-mono"
          />
        </FormField>

        <FormField label="Evidence" hint="Optional. Links, notes or the source this came from. Markdown.">
          <Textarea
            value={form.evidence}
            onChange={(next) => update('evidence', next)}
            rows={4}
            width="full"
            disabled={gated}
            data-debug-id="memory-form-evidence"
          />
        </FormField>

        <section ref={scopeRef} data-debug-id="memory-form-scope" className="flex flex-col gap-3">
          <Text as="div" role="title">Scope</Text>
          {errors.scope ? <Alert tone="danger" title="Check this memory's scope">{errors.scope}</Alert> : null}

          <div className="grid gap-3 sm:grid-cols-2">
            {SCOPE_DIMS.map((dim) => {
              const ids = form.targeting[dim.key];
              return (
                <div key={dim.key}>
                  <div className="mb-1 flex items-center justify-between gap-2">
                    <Text as="div" role="label" tone="muted">{dim.label}</Text>
                    {ids.length ? (
                      // Removing the last chip changes the meaning to "everything",
                      // so the control that does it says so at the moment it happens.
                      <IconButton
                        icon="close"
                        size="sm"
                        label={`Clear — applies to ${dim.allLabel.toLowerCase()}`}
                        data-debug-id={`memory-form-scope-clear-${dim.debug}`}
                        onClick={() => update('targeting', { ...form.targeting, [dim.key]: [] })}
                      />
                    ) : null}
                  </div>
                  <Combobox
                    multiple
                    options={catalog[dim.key].options}
                    value={ids}
                    onChange={(next) => update('targeting', { ...form.targeting, [dim.key]: next })}
                    // The empty-state placeholder IS the meaning. Never "None", and
                    // never "Select projects…".
                    placeholder={dim.allLabel}
                    chipClassName={dim.chip}
                    loading={catalog[dim.key].loading}
                    disabled={gated}
                    invalid={errorDimension === dim.key}
                    // Three states, one wording, shared with every other scope
                    // surface: loading / empty ("No bridges available") / failed.
                    // An empty list behind an "All bridges" placeholder is what made
                    // a hub with zero bridges read as a broken selector.
                    emptyLabel={scopeCatalogEmptyLabel(catalog[dim.key], dim.label.toLowerCase())}
                    searchPlaceholder={`Search ${dim.label.toLowerCase()}…`}
                    debugId={`memory-form-scope-${dim.debug}`}
                  />
                  <ScopeCatalogNote
                    entry={catalog[dim.key]}
                    noun={dim.label.toLowerCase()}
                    debugId={`memory-form-scope-${dim.debug}-state`}
                  />
                </div>
              );
            })}
          </div>

          {scopeIsGlobal ? (
            <Alert tone="warning" title="This memory applies to every agent, on every project, bridge and template.">
              Narrow it below if that&apos;s not what you want.
            </Alert>
          ) : (
            <Text role="body-sm" tone="muted" data-debug-id="memory-form-scope-sentence">
              {scopeSentence}
            </Text>
          )}
        </section>

        <div className="flex flex-wrap items-center gap-2">
          <Button
            variant="primary"
            loading={saving === 'save'}
            disabled={gated || Boolean(saving)}
            data-debug-id="memory-form-submit"
            leading={<Icon name="save" size="sm" />}
            onClick={() => void save('save')}
          >
            {editing ? 'Save changes' : 'Create memory'}
          </Button>

          {/* Only an existing PENDING proposal offers this: it is the one case where
              a save and an approval are the same act. It never appears on create —
              a user's own memory is already active. */}
          {editing && recordStatus === 'pending' ? (
            <Button
              variant="primary"
              loading={saving === 'approve'}
              disabled={gated || Boolean(saving)}
              data-debug-id="memory-form-save-approve"
              onClick={() => void save('approve')}
            >
              Save &amp; approve
            </Button>
          ) : null}

          <Button
            variant="secondary"
            data-debug-id="memory-form-cancel"
            onClick={() => navigateTo(editing ? memoryViewHref(memoryId as string) : memoryListHref())}
          >
            Cancel
          </Button>
        </div>
      </div>

      {guard.pendingHref ? (
        <Modal
          open
          onOpenChange={(next) => { if (!next) guard.keepEditing(); }}
          title="Discard your changes to this memory?"
          size="sm"
          data-debug-id="memory-form-discard-modal"
        >
          <ModalBody>
            <Text role="body">Your edits haven&apos;t been saved yet.</Text>
          </ModalBody>
          <ModalFooter>
            <Button variant="secondary" data-debug-id="memory-form-keep-editing" onClick={guard.keepEditing}>Keep editing</Button>
            <Button variant="danger" data-debug-id="memory-form-discard" onClick={guard.discard}>Discard</Button>
          </ModalFooter>
        </Modal>
      ) : null}
    </PageShell>
  );
}
