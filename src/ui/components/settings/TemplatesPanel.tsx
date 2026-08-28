// TemplatesPanel — manage agent templates (personas) used at agent creation.
//
// Templates are DB-backed on the hub (GET/POST /api/v1/templates, plus PATCH and
// DELETE for user templates). The built-in "System Reviewer" is read-only and
// cannot be edited/deleted. This panel exposes create / edit / delete so users
// can define their own personas (researcher, bug-fixer, …) that then appear in
// the create-agent template picker.

import { useEffect, useState } from 'react';
import {
  useListAgentTemplatesQuery,
  useCreateAgentTemplateMutation,
  useUpdateAgentTemplateMutation,
  useDeleteAgentTemplateMutation,
} from '../../api/endpoints/agents';
import Icon from '../Icon';

function str(v: any): string { return String(v ?? '').trim(); }
function errMsg(e: any, fallback: string): string {
  if (!e) return fallback;
  if (typeof e === 'string') return e;
  const data = e.data ?? e;
  return str(e.message || data?.error?.message || (typeof data?.error === 'string' ? data.error : '') || data?.message || e.error) || fallback;
}

type TemplateForm = { name: string; description: string; persona: string; instructions: string };
const EMPTY: TemplateForm = { name: '', description: '', persona: '', instructions: '' };

export default function TemplatesPanel() {
  const templatesQuery = useListAgentTemplatesQuery();
  const [createTemplate, createState] = useCreateAgentTemplateMutation();
  const [updateTemplate, updateState] = useUpdateAgentTemplateMutation();
  const [deleteTemplate] = useDeleteAgentTemplateMutation();

  const templates: any[] = (templatesQuery.data?.templates || []) as any[];

  // editingId: '' = none, 'new' = create form, else = existing template id.
  const [editingId, setEditingId] = useState('');
  const [form, setForm] = useState<TemplateForm>(EMPTY);
  const [error, setError] = useState('');
  const [confirmDeleteId, setConfirmDeleteId] = useState('');

  useEffect(() => { setError(''); }, [editingId]);

  function beginCreate() { setForm(EMPTY); setEditingId('new'); }
  function beginEdit(t: any) {
    setForm({ name: str(t.name), description: str(t.description), persona: str(t.persona), instructions: str(t.instructions) });
    setEditingId(str(t.template_id || t.templateId || t.id));
  }
  function cancel() { setEditingId(''); setForm(EMPTY); }

  async function save() {
    setError('');
    if (!form.name.trim()) { setError('Name is required.'); return; }
    try {
      if (editingId === 'new') {
        await createTemplate({ name: form.name.trim(), description: form.description.trim(), persona: form.persona, instructions: form.instructions }).unwrap();
      } else {
        await updateTemplate({ templateId: editingId, name: form.name.trim(), description: form.description.trim(), persona: form.persona, instructions: form.instructions }).unwrap();
      }
      cancel();
    } catch (e: any) {
      setError(errMsg(e, 'Save failed'));
    }
  }

  async function remove(id: string) {
    try {
      await deleteTemplate({ templateId: id }).unwrap();
      setConfirmDeleteId('');
    } catch (e: any) {
      setError(errMsg(e, 'Delete failed'));
    }
  }

  return (
    <div data-debug-id="settings-templates-panel" className="w-full">
      <div className="mb-5 flex items-center justify-between gap-3">
        <div>
          <h2 className="text-xl font-semibold text-white">Templates</h2>
          <p className="mt-1 max-w-2xl text-sm text-zinc-400">Reusable personas + instructions applied when creating an agent. Built-in templates are read-only.</p>
        </div>
        <button data-debug-id="settings-templates-new-btn" type="button" onClick={beginCreate} className="inline-flex min-h-10 items-center gap-2 rounded-2xl bg-sky-400 px-4 py-2 text-sm font-black text-black hover:bg-sky-300">
          <Icon name="plus" size={16} /> New template
        </button>
      </div>

      {editingId === 'new' ? <TemplateEditor form={form} setForm={setForm} onSave={save} onCancel={cancel} saving={createState.isLoading} error={error} title="New template" /> : null}

      <div data-debug-id="settings-templates-list" className="space-y-2">
        {templatesQuery.isLoading ? (
          <div className="p-4 text-sm text-zinc-500">Loading templates…</div>
        ) : templates.length === 0 ? (
          <div data-debug-id="settings-templates-empty" className="rounded-2xl border border-white/10 bg-white/[0.02] p-6 text-sm text-zinc-500">No templates yet.</div>
        ) : templates.map((t) => {
          const id = str(t.template_id || t.templateId || t.id);
          const isSystem = Boolean(t.is_system ?? t.isSystem);
          if (editingId === id) {
            return <TemplateEditor key={id} form={form} setForm={setForm} onSave={save} onCancel={cancel} saving={updateState.isLoading} error={error} title={`Edit ${str(t.name) || id}`} />;
          }
          return (
            <div key={id} data-debug-id={`settings-template-row-${id}`} className="rounded-2xl border border-white/10 bg-white/[0.03] p-4">
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <h3 className="font-semibold text-white">{str(t.name) || id}</h3>
                    {isSystem ? <span className="rounded-full bg-zinc-500/15 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-zinc-400">built-in</span> : null}
                  </div>
                  {str(t.description) ? <p className="mt-1 text-sm text-zinc-400">{t.description}</p> : null}
                  {str(t.persona) ? <p className="mt-2 line-clamp-2 text-[13px] text-zinc-300"><span className="text-zinc-500">Persona: </span>{t.persona}</p> : null}
                  {str(t.instructions) ? <p className="mt-1 line-clamp-2 text-[13px] text-zinc-300"><span className="text-zinc-500">Instructions: </span>{t.instructions}</p> : null}
                  <p className="mt-2 font-mono text-[11px] text-zinc-600">{id}</p>
                </div>
                {!isSystem ? (
                  <div className="flex shrink-0 gap-2">
                    <button data-debug-id={`settings-template-edit-btn-${id}`} type="button" onClick={() => beginEdit(t)} className="rounded-lg border border-white/10 px-2.5 py-1 text-xs text-zinc-300 hover:bg-white/10">Edit</button>
                    {confirmDeleteId === id ? (
                      <>
                        <button data-debug-id={`settings-template-delete-confirm-${id}`} type="button" onClick={() => remove(id)} className="rounded-lg border border-red-400/30 px-2.5 py-1 text-xs font-bold text-red-200 hover:bg-red-400/10">Confirm</button>
                        <button data-debug-id={`settings-template-delete-cancel-${id}`} type="button" onClick={() => setConfirmDeleteId('')} className="rounded-lg border border-white/10 px-2.5 py-1 text-xs text-zinc-400 hover:bg-white/10">Cancel</button>
                      </>
                    ) : (
                      <button data-debug-id={`settings-template-delete-btn-${id}`} type="button" onClick={() => setConfirmDeleteId(id)} className="rounded-lg border border-rose-400/20 px-2.5 py-1 text-xs text-rose-200 hover:bg-rose-400/10">Delete</button>
                    )}
                  </div>
                ) : null}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function TemplateEditor({ form, setForm, onSave, onCancel, saving, error, title }: { form: TemplateForm; setForm: (f: TemplateForm) => void; onSave: () => void; onCancel: () => void; saving: boolean; error: string; title: string }) {
  const set = (patch: Partial<TemplateForm>) => setForm({ ...form, ...patch });
  return (
    <div data-debug-id="settings-template-editor" className="mb-4 rounded-2xl border border-sky-400/25 bg-sky-400/[0.04] p-4">
      <h3 className="mb-3 text-sm font-semibold text-white">{title}</h3>
      <div className="grid gap-3">
        <label className="block text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500">Name
          <input data-debug-id="settings-template-name-input" value={form.name} onChange={(e) => set({ name: e.target.value })} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2.5 text-sm text-white" placeholder="e.g. Researcher" />
        </label>
        <label className="block text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500">Description
          <input data-debug-id="settings-template-description-input" value={form.description} onChange={(e) => set({ description: e.target.value })} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2.5 text-sm text-white" placeholder="Short summary shown in the picker" />
        </label>
        <label className="block text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500">Persona
          <textarea data-debug-id="settings-template-persona-input" value={form.persona} onChange={(e) => set({ persona: e.target.value })} rows={3} className="mt-1 w-full resize-y rounded-xl border border-white/10 bg-black/30 px-3 py-2.5 text-sm leading-6 text-white" placeholder="Who the agent is (identity/voice)." />
        </label>
        <label className="block text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500">Instructions
          <textarea data-debug-id="settings-template-instructions-input" value={form.instructions} onChange={(e) => set({ instructions: e.target.value })} rows={4} className="mt-1 w-full resize-y rounded-xl border border-white/10 bg-black/30 px-3 py-2.5 text-sm leading-6 text-white" placeholder="How the agent should work (defaults layered under per-agent instructions)." />
        </label>
      </div>
      {error ? <p data-debug-id="settings-template-editor-error" className="mt-2 text-xs text-red-300">{error}</p> : null}
      <div className="mt-3 flex gap-2">
        <button data-debug-id="settings-template-save-btn" type="button" disabled={saving} onClick={onSave} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-bold text-black hover:bg-sky-300 disabled:opacity-50">{saving ? 'Saving…' : 'Save'}</button>
        <button data-debug-id="settings-template-cancel-btn" type="button" onClick={onCancel} className="rounded-xl border border-white/10 px-4 py-2 text-sm text-zinc-300 hover:bg-white/10">Cancel</button>
      </div>
    </div>
  );
}
