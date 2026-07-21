import React, { useState, useEffect } from 'react';
import * as daemonApi from '../api/daemonApi';

export function TemplatesPage({ session, onBack, templates = [], providers = [], onRefetchTemplates }: any) {
  const [open, setOpen] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  
  // Form fields
  const [templateId, setTemplateId] = useState('');
  const [displayName, setDisplayName] = useState('');
  const [description, setDescription] = useState('');
  const [persona, setPersona] = useState('');
  const [instructions, setInstructions] = useState('');
  const [defaultProviderProfile, setDefaultProviderProfile] = useState('');
  const [suggestedModelTier, setSuggestedModelTier] = useState('normal');
  const [isEdit, setIsEdit] = useState(false);

  function reset() {
    setTemplateId('');
    setDisplayName('');
    setDescription('');
    setPersona('');
    setInstructions('');
    setDefaultProviderProfile('');
    setSuggestedModelTier('normal');
    setError('');
    setIsEdit(false);
  }

  function openEdit(template: any) {
    setTemplateId(template.template_id || template.templateId || template.id || '');
    setDisplayName(template.display_name || template.displayName || template.name || '');
    setDescription(template.description || '');
    setPersona(template.persona || '');
    setInstructions(template.instructions || '');
    setDefaultProviderProfile(template.default_provider_profile || template.defaultProviderProfile || template.provider || '');
    setSuggestedModelTier(template.suggested_model_tier || template.suggestedModelTier || template.tier || 'normal');
    setError('');
    setIsEdit(true);
    setOpen(true);
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!templateId.trim()) {
      setError('Template ID is required.');
      return;
    }
    setSaving(true);
    setError('');
    try {
      const response = await daemonApi.saveAgentTemplate({
        daemonUrl: session?.daemonUrl || '',
        template: {
          update: isEdit,
          template_id: templateId.trim(),
          display_name: displayName.trim(),
          description: description.trim(),
          persona: persona.trim(),
          instructions: instructions.trim(),
          default_provider_profile: defaultProviderProfile.trim(),
          suggested_model_tier: suggestedModelTier,
        }
      });
      if (response && !response.ok) {
        throw new Error(response.message || 'Failed to save template');
      }
      setOpen(false);
      onRefetchTemplates?.();
    } catch (err: any) {
      setError(err.message || 'An error occurred while saving.');
    } finally {
      setSaving(false);
    }
  }

  async function handleDelete(id: string) {
    if (!window.confirm('Are you sure you want to delete this template?')) return;
    try {
      const response = await daemonApi.archiveAgentTemplate({
        daemonUrl: session?.daemonUrl || '',
        templateId: id
      });
      if (response && !response.ok) {
        alert('Error: ' + response.message);
      } else {
        onRefetchTemplates?.();
      }
    } catch (err: any) {
      alert('Error deleting template: ' + (err.message || err));
    }
  }

  return (
    <div className="flex h-full flex-col bg-[#08090b] text-zinc-100">
      <div className="flex shrink-0 items-center gap-3 border-b border-white/5 bg-[#0d0f14] px-4 py-3">
        <button onClick={onBack} data-debug-id="templates-back-btn" className="flex h-8 w-8 items-center justify-center rounded-xl text-zinc-500 hover:bg-white/10 hover:text-zinc-100">←</button>
        <h1 className="text-base font-semibold">Agent Templates</h1>
      </div>
      <div className="flex-1 overflow-y-auto p-6">
        <div className="mx-auto max-w-5xl">
          <div className="mb-6 flex items-center justify-between">
            <div>
              <h2 className="text-xl font-bold">Template Registry</h2>
              <p className="mt-1 text-sm text-zinc-400">Create and manage reusable agent roles, personas, and instructions.</p>
            </div>
            <button
              data-debug-id="templates-create-btn"
              onClick={() => { reset(); setOpen(true); }}
              className="rounded-xl bg-sky-500 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-400"
            >
              + Create Template
            </button>
          </div>

          <div className="grid gap-4">
            {templates.length === 0 ? (
              <div className="rounded-xl border border-white/10 bg-black/30 p-8 text-center text-sm text-zinc-500">
                No templates found. Create one to get started.
              </div>
            ) : (
              templates.map((template: any) => {
                const id = template.template_id || template.templateId || template.id;
                return (
                  <div key={id} className="group flex items-start justify-between gap-4 rounded-2xl border border-white/10 bg-[#0d0f14] p-5 hover:border-white/20">
                    <div>
                      <div className="flex items-center gap-2">
                        <h3 className="font-semibold text-zinc-100">{template.display_name || template.displayName || template.name || id}</h3>
                        <span className="rounded-full bg-white/10 px-2 py-0.5 text-[10px] font-mono text-zinc-400">{id}</span>
                      </div>
                      <p className="mt-1 text-sm text-zinc-400">{template.description || 'No description provided.'}</p>
                      <div className="mt-3 flex items-center gap-4 text-xs text-zinc-500">
                        {template.default_provider_profile && (
                          <div className="flex items-center gap-1">
                            <span className="uppercase tracking-wider">Provider:</span>
                            <span className="font-medium text-zinc-300">{template.default_provider_profile || template.provider}</span>
                          </div>
                        )}
                        {template.suggested_model_tier && (
                          <div className="flex items-center gap-1">
                            <span className="uppercase tracking-wider">Tier:</span>
                            <span className="font-medium text-zinc-300">{template.suggested_model_tier || template.tier}</span>
                          </div>
                        )}
                      </div>
                    </div>
                    <div className="flex shrink-0 items-center gap-2 opacity-0 transition-opacity group-hover:opacity-100">
                      <button
                        data-debug-id={`template-edit-btn-${id}`}
                        onClick={() => openEdit(template)}
                        className="rounded-lg bg-white/5 px-3 py-1.5 text-xs font-medium hover:bg-white/15"
                      >
                        Edit
                      </button>
                      <button
                        data-debug-id={`template-delete-btn-${id}`}
                        onClick={() => handleDelete(id)}
                        className="rounded-lg bg-red-500/10 px-3 py-1.5 text-xs font-medium text-red-400 hover:bg-red-500/20 hover:text-red-300"
                      >
                        Delete
                      </button>
                    </div>
                  </div>
                );
              })
            )}
          </div>
        </div>
      </div>

      {open && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 px-4">
          <form onSubmit={submit} className="flex max-h-[90vh] w-full max-w-2xl flex-col rounded-3xl border border-white/10 bg-[#0d0f14] shadow-2xl">
            <div className="flex shrink-0 items-start justify-between gap-3 p-5 pb-0">
              <div>
                <h3 className="text-xl font-semibold">{isEdit ? 'Edit Template' : 'Create Template'}</h3>
                <p className="mt-1 text-sm text-zinc-500">Define the persona, instructions, and default model tier.</p>
              </div>
              <button
                type="button"
                data-debug-id="template-modal-close-btn"
                onClick={() => setOpen(false)}
                className="rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15"
              >
                Close
              </button>
            </div>
            
            <div className="flex-1 overflow-y-auto p-5 space-y-4">
              <div className="grid gap-4 sm:grid-cols-2">
                <label className="block text-sm text-zinc-300">
                  Template ID
                  <input
                    value={templateId}
                    data-debug-id="template-id-input"
                    onChange={(e) => setTemplateId(e.target.value)}
                    disabled={isEdit}
                    placeholder="e.g. frontend-expert"
                    className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400 disabled:opacity-50"
                  />
                </label>
                <label className="block text-sm text-zinc-300">
                  Display Name
                  <input
                    value={displayName}
                    data-debug-id="template-name-input"
                    onChange={(e) => setDisplayName(e.target.value)}
                    placeholder="e.g. Frontend Expert"
                    className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
                  />
                </label>
              </div>
              
              <label className="block text-sm text-zinc-300">
                Description
                <input
                  value={description}
                  data-debug-id="template-desc-input"
                  onChange={(e) => setDescription(e.target.value)}
                  placeholder="Brief summary of what this template does"
                  className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
                />
              </label>

              <label className="block text-sm text-zinc-300">
                Persona
                <textarea
                  value={persona}
                  data-debug-id="template-persona-input"
                  onChange={(e) => setPersona(e.target.value)}
                  placeholder="e.g. You are a senior frontend developer..."
                  rows={3}
                  className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
                />
              </label>

              <label className="block text-sm text-zinc-300">
                Instructions
                <textarea
                  value={instructions}
                  data-debug-id="template-instructions-input"
                  onChange={(e) => setInstructions(e.target.value)}
                  placeholder="System instructions and rules..."
                  rows={4}
                  className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm font-mono text-zinc-300 outline-none focus:border-sky-400"
                />
              </label>
              
              <div className="grid gap-4 sm:grid-cols-2">
                <label className="block text-sm text-zinc-300">
                  Default Provider
                  <select
                    value={defaultProviderProfile}
                    data-debug-id="template-provider-select"
                    onChange={(e) => setDefaultProviderProfile(e.target.value)}
                    className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
                  >
                    <option value="">(None)</option>
                    {providers?.map((provider: any) => (
                      <option key={provider.name} value={provider.name}>{provider.name}</option>
                    ))}
                  </select>
                </label>
                <label className="block text-sm text-zinc-300">
                  Suggested Model Tier
                  <select
                    value={suggestedModelTier}
                    data-debug-id="template-tier-select"
                    onChange={(e) => setSuggestedModelTier(e.target.value)}
                    className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
                  >
                    <option value="cheap">cheap</option>
                    <option value="normal">normal</option>
                    <option value="smart">smart</option>
                  </select>
                </label>
              </div>

              {error && (
                <div className="rounded-xl border border-red-400/30 bg-red-400/10 px-3 py-2 text-sm text-red-100">
                  {error}
                </div>
              )}
            </div>
            <div className="flex shrink-0 justify-end gap-2 p-5 pt-0">
              <button
                type="button"
                data-debug-id="template-modal-cancel-btn"
                onClick={() => setOpen(false)}
                className="rounded-xl bg-white/10 px-4 py-2 text-sm hover:bg-white/15"
              >
                Cancel
              </button>
              <button
                type="submit"
                data-debug-id="template-modal-submit-btn"
                disabled={saving || !templateId.trim()}
                className="rounded-xl bg-sky-500 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-400 disabled:cursor-not-allowed disabled:bg-white/10 disabled:text-zinc-500"
              >
                {saving ? 'Saving...' : (isEdit ? 'Save Changes' : 'Create Template')}
              </button>
            </div>
          </form>
        </div>
      )}
    </div>
  );
}
