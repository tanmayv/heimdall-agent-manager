import { useState } from 'react';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import {
  useListLspServerConfigsQuery,
  useUpsertLspServerConfigMutation,
  useDeleteLspServerConfigMutation,
  type LspServerConfig,
} from '../../api/endpoints/settings';
import { apiErrorText } from '../../api/cookieFetch';
import { Button, FormField, Icon, Input, PageShell, Text } from '@ui';

// REQ-LSP-CFG-2: Settings > LSP panel. Only rendered when the 'lsp' experiment flag is
// enabled — AppShell gates BOTH the nav entry (SettingsSubNav) and the /settings/lsp
// route itself, so a direct visit with the flag off gets not-found rather than this
// panel. Shows per-bridge LSP server configs with language defaults and directory
// overrides. Note that a config is keyed by (bridge_id, language, dir_prefix): the
// upsert replaces by that key, which is why both language and dir_prefix are locked
// while editing a row.

type FormState = {
  language: string;
  cmd: string;
  args: string;
  fileExtensions: string;
  rootMarkers: string;
  dirPrefix: string;
};

const EMPTY_FORM: FormState = {
  language: '',
  cmd: '',
  args: '',
  fileExtensions: '',
  rootMarkers: '',
  dirPrefix: '',
};

// Strips trailing slashes and returns the normalized prefix (mirrors API normalization
// so the user sees the stored value before the round-trip).
function normalizePrefix(s: string): string {
  return s.replace(/\/+$/, '');
}

export default function LspPanel() {
  const bridgesQuery = useListBridgesQuery(undefined);
  const bridges: any[] = (bridgesQuery.data?.bridges || []).filter(
    (b: any) => String(b?.status || b?.runtime_status || '').toLowerCase() !== 'revoked' && !b?.revoked_at,
  );

  const [selectedBridgeId, setSelectedBridgeId] = useState('');
  const bridgeId = selectedBridgeId || (bridges[0] ? String(bridges[0]?.bridge_id || bridges[0]?.id || '') : '');

  const configsQuery = useListLspServerConfigsQuery(
    { bridgeId },
    { skip: !bridgeId },
  );
  const configs: LspServerConfig[] = configsQuery.data?.configs || [];

  const [upsert] = useUpsertLspServerConfigMutation();
  const [deleteConfig] = useDeleteLspServerConfigMutation();

  const [formOpen, setFormOpen] = useState(false);
  // editing stores the original (language, dirPrefix) key of the row being edited,
  // since upsert replaces by key (there is no PATCH).
  const [editing, setEditing] = useState<{ language: string; dirPrefix: string } | null>(null);
  const [form, setForm] = useState<FormState>(EMPTY_FORM);
  const [formBusy, setFormBusy] = useState(false);
  const [formError, setFormError] = useState('');
  const [deleteConfirmId, setDeleteConfirmId] = useState('');
  const [actionError, setActionError] = useState('');

  function openAdd() {
    setEditing(null);
    setForm(EMPTY_FORM);
    setFormError('');
    setFormOpen(true);
  }

  function openEdit(cfg: LspServerConfig) {
    setEditing({ language: cfg.language, dirPrefix: cfg.dir_prefix });
    setForm({
      language: cfg.language,
      cmd: cfg.cmd,
      args: cfg.args,
      fileExtensions: cfg.file_extensions,
      rootMarkers: cfg.root_markers,
      dirPrefix: cfg.dir_prefix,
    });
    setFormError('');
    setFormOpen(true);
  }

  function closeForm() {
    setFormOpen(false);
    setEditing(null);
    setForm(EMPTY_FORM);
    setFormError('');
  }

  function setField<K extends keyof FormState>(key: K, value: string) {
    setForm((f) => ({ ...f, [key]: value }));
  }

  async function handleSubmit() {
    if (!form.language.trim() || !form.cmd.trim()) {
      setFormError('Language and command are required.');
      return;
    }
    const normalizedPrefix = normalizePrefix(form.dirPrefix.trim());
    setFormBusy(true);
    setFormError('');
    try {
      await upsert({
        bridgeId,
        language: form.language.trim(),
        cmd: form.cmd.trim(),
        args: form.args.trim(),
        fileExtensions: form.fileExtensions.trim(),
        rootMarkers: form.rootMarkers.trim(),
        dirPrefix: normalizedPrefix,
      }).unwrap();
      closeForm();
    } catch (err: any) {
      setFormError(apiErrorText(err, 'Save failed. Please try again.'));
    } finally {
      setFormBusy(false);
    }
  }

  async function handleDelete(cfg: LspServerConfig) {
    setActionError('');
    try {
      await deleteConfig({ bridgeId, configId: cfg.config_id }).unwrap();
      setDeleteConfirmId('');
    } catch (err: any) {
      setActionError(apiErrorText(err, 'Delete failed.'));
    }
  }

  // Group configs by language, then split into defaults (dir_prefix="") and overrides.
  const byLanguage = new Map<string, { defaults: LspServerConfig[]; overrides: LspServerConfig[] }>();
  for (const cfg of configs) {
    if (!byLanguage.has(cfg.language)) byLanguage.set(cfg.language, { defaults: [], overrides: [] });
    const group = byLanguage.get(cfg.language)!;
    if (cfg.dir_prefix === '') group.defaults.push(cfg);
    else group.overrides.push(cfg);
  }
  // Sort overrides by prefix length descending so longer (more specific) paths appear first.
  for (const group of byLanguage.values()) {
    group.overrides.sort((a, b) => b.dir_prefix.length - a.dir_prefix.length);
  }
  const languages = Array.from(byLanguage.keys()).sort();

  const addForm = (
    <div data-debug-id="settings-lsp-form" className="mt-3 rounded-2xl border border-info/30 bg-info-soft p-4">
      <div className="text-sm font-medium text-info">
        {editing ? 'Edit LSP server config' : 'Add LSP server config'}
      </div>
      {editing && (
        <p className="mt-1 text-xs text-muted">
          Editing <span className="font-mono text-primary">{editing.language}</span>
          {editing.dirPrefix ? <> · <span className="font-mono text-primary">{editing.dirPrefix}</span></> : ' (language default)'}.
          Language and directory identify this config, so both are locked while editing —
          saving replaces this row. To move an override to a different directory, delete it
          and add a new one.
        </p>
      )}
      <div className="mt-3 grid gap-3 sm:grid-cols-2">
        <FormField label="Language *" className="sm:col-span-2">
          <Input
            data-debug-id="settings-lsp-form-language"
            value={form.language}
            onChange={(v) => setField('language', v)}
            placeholder="go"
            width="full"
            disabled={Boolean(editing)}
          />
        </FormField>
        <FormField label="Command *" className="sm:col-span-2">
          <Input
            data-debug-id="settings-lsp-form-cmd"
            value={form.cmd}
            onChange={(v) => setField('cmd', v)}
            placeholder="gopls"
            width="full"
          />
        </FormField>
        <FormField label="Args">
          <Input
            data-debug-id="settings-lsp-form-args"
            value={form.args}
            onChange={(v) => setField('args', v)}
            placeholder="-rpc.trace"
            width="full"
          />
        </FormField>
        <FormField label="File extensions">
          <Input
            data-debug-id="settings-lsp-form-extensions"
            value={form.fileExtensions}
            onChange={(v) => setField('fileExtensions', v)}
            placeholder=".go"
            width="full"
          />
        </FormField>
        <FormField label="Root markers">
          <Input
            data-debug-id="settings-lsp-form-root-markers"
            value={form.rootMarkers}
            onChange={(v) => setField('rootMarkers', v)}
            placeholder="go.mod"
            width="full"
          />
        </FormField>
        <FormField
          label="Directory override (optional)"
          hint={
            editing
              ? 'Part of this config’s identity — locked while editing.'
              : form.dirPrefix.trim()
                ? `Will be stored as: ${normalizePrefix(form.dirPrefix.trim()) || '(empty — language default)'}`
                : 'Leave empty for a language-wide default.'
          }
        >
          <Input
            data-debug-id="settings-lsp-form-dir-prefix"
            value={form.dirPrefix}
            onChange={(v) => setField('dirPrefix', v)}
            placeholder="/home/user/project"
            width="full"
            disabled={Boolean(editing)}
          />
        </FormField>
      </div>
      {formError ? (
        <p className="mt-2 text-xs text-danger" data-debug-id="settings-lsp-form-error">{formError}</p>
      ) : null}
      <div className="mt-3 flex justify-end gap-2">
        <Button variant="secondary" size="sm" data-debug-id="settings-lsp-form-cancel" onClick={closeForm}>
          Cancel
        </Button>
        <Button
          variant="primary"
          size="sm"
          data-debug-id="settings-lsp-form-submit"
          onClick={() => void handleSubmit()}
          disabled={formBusy}
        >
          {formBusy ? 'Saving…' : editing ? 'Save changes' : 'Add config'}
        </Button>
      </div>
    </div>
  );

  return (
    <PageShell
      title="Language Servers"
      description="Configure LSP servers per bridge. Overrides narrow the server to a specific directory tree; the language default catches everything else."
      actions={
        bridgeId ? (
          <Button
            variant="primary"
            data-debug-id="settings-lsp-add-btn"
            onClick={openAdd}
            leading={<Icon name="plus" size={16} />}
          >
            Add config
          </Button>
        ) : undefined
      }
    >
      <div data-debug-id="settings-lsp-panel" className="min-w-0">
        {/* Bridge picker */}
        {bridges.length > 1 ? (
          <div data-debug-id="settings-lsp-bridge-picker" className="mb-4">
            <Text as="div" role="overline" tone="muted" className="mb-2">Bridge</Text>
            <div className="flex flex-wrap gap-2">
              {bridges.map((b: any) => {
                const id = String(b?.bridge_id || b?.id || '');
                const label = String(b?.label || b?.machine_hostname || b?.hostname || id);
                const active = id === bridgeId;
                return (
                  <button
                    key={id}
                    data-debug-id={`settings-lsp-bridge-${id}`}
                    onClick={() => setSelectedBridgeId(id)}
                    className={`rounded-xl border px-3 py-1.5 text-sm font-medium ${active ? 'border-accent bg-accent text-accent-fg' : 'border-subtle bg-surface-raised/30 text-muted hover:text-primary'}`}
                  >
                    {label}
                  </button>
                );
              })}
            </div>
          </div>
        ) : bridges.length === 1 ? (
          <div className="mb-4 text-sm text-muted">
            Bridge: <span className="text-primary">{String(bridges[0]?.label || bridges[0]?.machine_hostname || bridges[0]?.hostname || bridgeId)}</span>
          </div>
        ) : null}

        {bridgesQuery.isFetching && bridges.length === 0 ? (
          <p className="text-sm text-muted">Loading bridges…</p>
        ) : bridges.length === 0 ? (
          <div data-debug-id="settings-lsp-no-bridges" className="rounded-xl border border-dashed border-subtle bg-surface-raised/30 p-4 text-center text-sm text-muted">
            No bridges connected. Add a bridge in the Bridges tab first.
          </div>
        ) : (
          <>
            {formOpen ? addForm : null}
            {actionError ? (
              <p className="mt-2 text-xs text-danger" data-debug-id="settings-lsp-action-error">{actionError}</p>
            ) : null}

            {/* Resolution rule callout */}
            <div data-debug-id="settings-lsp-resolution-note" className="mt-4 rounded-xl border border-subtle bg-surface-raised/30 px-3 py-2 text-caption text-muted">
              <span className="font-medium text-primary">Resolution: </span>
              longest-prefix-wins. When a file is opened, the override whose directory is the deepest match for that file's path is used. The language default catches any file with no matching override.
            </div>

            {/* Config list */}
            {configsQuery.isFetching && configs.length === 0 ? (
              <p className="mt-4 text-sm text-muted">Loading configs…</p>
            ) : configsQuery.isError ? (
              <p className="mt-4 text-sm text-danger" data-debug-id="settings-lsp-load-error">
                {apiErrorText(configsQuery.error, 'Unable to load configs. Check your connection and reload.')}
              </p>
            ) : configs.length === 0 && !configsQuery.isFetching ? (
              <div data-debug-id="settings-lsp-empty" className="mt-4 rounded-xl border border-dashed border-subtle bg-surface-raised/30 p-4 text-center text-sm text-muted">
                No LSP configs yet for this bridge. Add one to get started.
              </div>
            ) : (
              <div className="mt-4 space-y-6">
                {languages.map((lang) => {
                  const { defaults, overrides } = byLanguage.get(lang)!;
                  // Resolution order: overrides are tried longest-prefix-first, and the
                  // language default is the fallback, so it renders last. Do not re-sort
                  // this list (alphabetically or otherwise) — the order IS the precedence
                  // rule, and the label below tells the reader to read it that way.
                  const all = [...overrides, ...defaults];
                  return (
                    <div key={lang} data-debug-id={`settings-lsp-lang-${lang}`}>
                      <div className="mb-2 flex flex-wrap items-baseline gap-x-2">
                        <Text as="div" role="overline" tone="muted">{lang}</Text>
                        <span
                          data-debug-id={`settings-lsp-lang-order-note-${lang}`}
                          className="text-caption text-muted"
                        >
                          checked in this order, top to bottom
                        </span>
                      </div>
                      <div className="space-y-2">
                        {all.map((cfg) => {
                          const isOverride = cfg.dir_prefix !== '';
                          const isDeleting = deleteConfirmId === cfg.config_id;
                          return (
                            <div
                              key={cfg.config_id}
                              data-debug-id={`settings-lsp-config-${cfg.config_id}`}
                              className="rounded-xl border border-subtle bg-surface-raised/30 px-3 py-2.5"
                            >
                              <div className="flex items-start justify-between gap-2">
                                <div className="min-w-0">
                                  <div className="flex flex-wrap items-center gap-2">
                                    <span className="text-sm font-medium text-primary font-mono">{cfg.cmd}</span>
                                    {isOverride ? (
                                      <span
                                        data-debug-id={`settings-lsp-config-override-badge-${cfg.config_id}`}
                                        className="rounded-full border border-info/30 bg-info-soft px-2 py-0.5 text-[10px] text-info"
                                      >
                                        override
                                      </span>
                                    ) : (
                                      <span
                                        data-debug-id={`settings-lsp-config-default-badge-${cfg.config_id}`}
                                        className="rounded-full border border-subtle px-2 py-0.5 text-[10px] text-muted"
                                      >
                                        language default
                                      </span>
                                    )}
                                  </div>
                                  <div className="mt-1 flex flex-wrap gap-x-3 gap-y-0.5 text-caption text-muted">
                                    {cfg.args ? <span>args: <span className="font-mono text-primary">{cfg.args}</span></span> : null}
                                    {cfg.file_extensions ? <span>extensions: <span className="font-mono text-primary">{cfg.file_extensions}</span></span> : null}
                                    {cfg.root_markers ? <span>root markers: <span className="font-mono text-primary">{cfg.root_markers}</span></span> : null}
                                    {isOverride ? (
                                      <span>
                                        this directory, instead of the language default:{' '}
                                        <span className="font-mono text-primary">{cfg.dir_prefix}</span>
                                      </span>
                                    ) : null}
                                  </div>
                                </div>
                                <div className="flex shrink-0 items-center gap-1">
                                  {isDeleting ? (
                                    <>
                                      <Button
                                        variant="danger"
                                        size="sm"
                                        data-debug-id={`settings-lsp-config-delete-confirm-${cfg.config_id}`}
                                        onClick={() => void handleDelete(cfg)}
                                      >
                                        Confirm delete
                                      </Button>
                                      <Button
                                        variant="secondary"
                                        size="sm"
                                        data-debug-id={`settings-lsp-config-delete-cancel-${cfg.config_id}`}
                                        onClick={() => setDeleteConfirmId('')}
                                      >
                                        Cancel
                                      </Button>
                                    </>
                                  ) : (
                                    <>
                                      <Button
                                        variant="secondary"
                                        size="sm"
                                        data-debug-id={`settings-lsp-config-edit-${cfg.config_id}`}
                                        onClick={() => openEdit(cfg)}
                                      >
                                        Edit
                                      </Button>
                                      <Button
                                        variant="danger"
                                        size="sm"
                                        data-debug-id={`settings-lsp-config-delete-${cfg.config_id}`}
                                        onClick={() => { setDeleteConfirmId(cfg.config_id); setActionError(''); }}
                                      >
                                        Delete
                                      </Button>
                                    </>
                                  )}
                                </div>
                              </div>
                            </div>
                          );
                        })}
                      </div>
                    </div>
                  );
                })}
              </div>
            )}
          </>
        )}
      </div>
    </PageShell>
  );
}
