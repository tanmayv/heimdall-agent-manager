import React, { useEffect, useState } from 'react';
import {
  Alert,
  Button,
  FormField,
  Icon,
  Input,
  PageShell,
  Select,
  Text,
  Textarea,
} from '@ui';
import {
  useCreateIssueMutation,
  useGetIssueQuery,
  useUpdateIssueMutation,
} from '../../api/endpoints/issues';
import {
  editCrumbs,
  issueEditHref,
  issuesListHref,
  issueStatus,
  issueTitle,
  issueViewHref,
  navigateTo,
  newCrumbs,
  SCOPE_OPTIONS,
} from './issueModel';

export interface IssueFormPageProps {
  issueId?: string;
}

export function IssueFormPage({ issueId }: IssueFormPageProps) {
  const isEdit = Boolean(issueId);

  const { data: existingIssue, isLoading: isLoadingExisting } = useGetIssueQuery(
    { issueId: issueId! },
    { skip: !isEdit },
  );

  const [createIssue, { isLoading: isCreating }] = useCreateIssueMutation();
  const [updateIssue, { isLoading: isUpdating }] = useUpdateIssueMutation();

  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [scopeType, setScopeType] = useState('global');
  const [targetId, setTargetId] = useState('');
  const [chainId, setChainId] = useState('');
  const [status, setStatus] = useState('new');
  const [errorMsg, setErrorMsg] = useState('');
  const [isDirty, setIsDirty] = useState(false);

  useEffect(() => {
    if (existingIssue && isEdit) {
      setTitle(existingIssue.title || '');
      setDescription(existingIssue.description || '');
      setScopeType(existingIssue.scope_type || existingIssue.scopeType || 'global');
      setTargetId(existingIssue.target_id || existingIssue.targetId || '');
      setChainId(existingIssue.chain_id || existingIssue.chainId || '');
      setStatus(issueStatus(existingIssue));
      setIsDirty(false);
    }
  }, [existingIssue, isEdit]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!title.trim()) {
      setErrorMsg('Title is required.');
      return;
    }
    setErrorMsg('');

    try {
      if (isEdit && issueId) {
        await updateIssue({
          issueId,
          title: title.trim(),
          description: description.trim(),
          scope_type: scopeType,
          target_id: scopeType === 'global' ? '' : targetId.trim(),
          chain_id: chainId.trim(),
          status,
        }).unwrap();
        setIsDirty(false);
        navigateTo(issueViewHref(issueId));
      } else {
        const created = await createIssue({
          title: title.trim(),
          description: description.trim(),
          scope_type: scopeType,
          target_id: scopeType === 'global' ? '' : targetId.trim(),
          chain_id: chainId.trim(),
        }).unwrap();
        setIsDirty(false);
        const newId = created.issue_id || created.issueId || created.id;
        if (newId) {
          navigateTo(issueViewHref(newId));
        } else {
          navigateTo(issuesListHref());
        }
      }
    } catch (err: any) {
      setErrorMsg(String(err?.data?.message || err?.message || 'Failed to save issue.'));
    }
  };

  const handleCancel = () => {
    if (isDirty && !window.confirm('You have unsaved changes. Discard them?')) {
      return;
    }
    if (isEdit && issueId) {
      navigateTo(issueViewHref(issueId));
    } else {
      navigateTo(issuesListHref());
    }
  };

  const crumbs = isEdit && existingIssue ? editCrumbs(existingIssue) : newCrumbs();

  if (isEdit && isLoadingExisting) {
    return (
      <PageShell breadcrumbs={crumbs} title="Loading issue...">
        <div className="p-8 flex items-center justify-center text-muted">
          <Icon name="refresh" className="animate-spin mr-2" size={18} />
          <span>Loading issue for editing...</span>
        </div>
      </PageShell>
    );
  }

  const isSaving = isCreating || isUpdating;

  return (
    <PageShell
      breadcrumbs={crumbs}
      title={isEdit ? `Edit: ${title || 'Issue'}` : 'New Issue'}
      description={
        isEdit
          ? 'Update the issue description, status, or scope details.'
          : 'Report a bug, platform friction, or toolchain issue observed while working on tasks.'
      }
    >
      <div className="max-w-2xl py-4">
        {errorMsg ? (
          <Alert tone="danger" title="Validation Error" className="mb-6">
            {errorMsg}
          </Alert>
        ) : null}

        <form onSubmit={handleSubmit} className="space-y-6">
          {/* Title */}
          <FormField
            label="Title"
            required
            hint="Summarize the problem concisely (e.g. 'Odin test runner fails on arm64' or 'Missing sqlite column in migration 042')."
          >
            <Input
              value={title}
              onChange={(val) => {
                setTitle(val);
                setIsDirty(true);
              }}
              placeholder="Descriptive issue title"
              required
              data-debug-id="issue-form-title"
            />
          </FormField>

          {/* Description Markdown */}
          <FormField
            label="Description"
            hint="Full details, steps to reproduce, environment details, or error logs. Markdown formatted."
          >
            <Textarea
              value={description}
              onChange={(val) => {
                setDescription(val);
                setIsDirty(true);
              }}
              placeholder="Provide background, logs, and context..."
              rows={8}
              data-debug-id="issue-form-description"
            />
          </FormField>

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            {/* Scope Selection */}
            <FormField
              label="Scope"
              hint="Where does this issue apply?"
            >
              <Select
                value={scopeType}
                onChange={(val) => {
                  setScopeType(val);
                  setIsDirty(true);
                }}
                options={[
                  { value: 'global', label: 'Global (All workspaces)' },
                  { value: 'project', label: 'Project' },
                  { value: 'agent_id', label: 'Agent' },
                  { value: 'bridge_id', label: 'Bridge' },
                ]}
                data-debug-id="issue-form-scope"
              />
            </FormField>

            {/* Target ID (if not global) */}
            {scopeType !== 'global' ? (
              <FormField
                label="Target Identifier"
                hint={
                  scopeType === 'project'
                    ? 'Project ID or Name'
                    : scopeType === 'agent_id'
                    ? 'Agent ID (e.g. worker, coordinator)'
                    : 'Bridge ID (e.g. brg_local)'
                }
              >
                <Input
                  value={targetId}
                  onChange={(val) => {
                    setTargetId(val);
                    setIsDirty(true);
                  }}
                  placeholder={`Target ${scopeType} id`}
                  data-debug-id="issue-form-target-id"
                />
              </FormField>
            ) : null}
          </div>

          {/* Optional Task Chain Context */}
          <FormField
            label="Originating Task Chain ID (Optional)"
            hint="Task chain where this issue was encountered (e.g. chain_18d7...)."
          >
            <Input
              value={chainId}
              onChange={(val) => {
                setChainId(val);
                setIsDirty(true);
              }}
              placeholder="chain_..."
              data-debug-id="issue-form-chain-id"
            />
          </FormField>

          {/* Status (when editing) */}
          {isEdit ? (
            <FormField
              label="Status"
              hint="Lifecycle status of this issue."
            >
              <Select
                value={status}
                onChange={(val) => {
                  setStatus(val);
                  setIsDirty(true);
                }}
                options={[
                  { value: 'new', label: 'New' },
                  { value: 'fixed', label: 'Fixed' },
                  { value: 'obsolete', label: 'Obsolete' },
                ]}
                data-debug-id="issue-form-status"
              />
            </FormField>
          ) : null}

          {/* Form Actions */}
          <div className="flex items-center justify-end gap-3 pt-4 border-t border-subtle">
            <Button type="button" variant="secondary" onClick={handleCancel}>
              Cancel
            </Button>
            <Button
              type="submit"
              variant="primary"
              loading={isSaving}
              data-debug-id="issue-form-submit"
            >
              {isEdit ? 'Save Changes' : 'Create Issue'}
            </Button>
          </div>
        </form>
      </div>
    </PageShell>
  );
}

export default IssueFormPage;
