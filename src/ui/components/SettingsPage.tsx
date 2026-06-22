import React, { useState, useEffect, useRef } from 'react';
import { useDispatch } from 'react-redux';
import { saveUserPreference } from '../store/chatSlice';
import SessionConfig from './SessionConfig';
import * as daemonApi from '../api/daemonApi';

type Preference = {
  key: string;
  value: string;
  interrupt: boolean;
  is_custom: boolean;
  default_value: string;
  default_interrupt: boolean;
};

const PLACEHOLDERS: Record<string, string[]> = {
  starter_prompt: ['{ctl_bin}', '{token}', '{daemon_url}'],
  bootstrap_header: [],
  bootstrap_title: ['{file_name}', '{profile}'],
  bootstrap_profile_guidance: ['{ctl_bin}', '{file_name}', '{profile}', '{instance}'],
  msg_agent_message: ['{pending_count}', '{from_agent_id}'],
  msg_task_updated: ['{task_id}', '{status}', '{changed_by}', '{body}'],
  msg_task_updated_empty: ['{task_id}', '{status}', '{changed_by}'],
  msg_memory_updated: ['{memory_id}', '{event}', '{changed_by}', '{subject_agent}', '{status}', '{ctl_bin}'],
  msg_memory_proposal_updated: ['{proposal_id}', '{memory_id}', '{event}', '{changed_by}', '{subject_agent}', '{ctl_bin}'],
  msg_user_chat: ['{pending_count}', '{user_id}', '{ctl_bin}'],
  msg_token_refreshed: ['{new_token}', '{ctl_bin}', '{daemon_url}'],
  msg_stop_requested: ['{time}'],
};

const KEY_LABELS: Record<string, string> = {
  starter_prompt: 'Starter Prompt',
  bootstrap_header: 'Bootstrap File Header',
  bootstrap_title: 'Bootstrap File Title',
  bootstrap_profile_guidance: 'Bootstrap Profile Guidance (Operating Rules)',
  msg_agent_message: 'Inter-Agent Message Notification',
  msg_task_updated: 'Task Status Updated (With Comment)',
  msg_task_updated_empty: 'Task Status Updated (Empty Comment)',
  msg_memory_updated: 'Memory Record Updated',
  msg_memory_proposal_updated: 'Memory Proposal Submitted',
  msg_user_chat: 'New User Chat Message Notification',
  msg_token_refreshed: 'Daemon Token Refreshed Warning',
  msg_stop_requested: 'Graceful Stop Requested Warning',
};

const KEY_DESCRIPTIONS: Record<string, string> = {
  starter_prompt: 'The very first prompt sent to the agent tmux window to kick off execution.',
  bootstrap_header: 'The HTML comment marker written at the top of all Heimdall-managed workspace files.',
  bootstrap_title: 'The primary H1 title written at the top of AGENTS.md or CLAUDE.md.',
  bootstrap_profile_guidance: 'The extensive guidelines, rules, and CLI references written into the bootstrap file.',
  msg_agent_message: 'Injected into the agent pane when another agent sends an inbox message.',
  msg_task_updated: 'Injected when an assigned task status changes, containing a comment body.',
  msg_task_updated_empty: 'Injected when an assigned task status changes, without any comment body.',
  msg_memory_updated: 'Injected when a factual memory record is added or updated.',
  msg_memory_proposal_updated: 'Injected when a new memory proposal is submitted and awaiting review.',
  msg_user_chat: 'Injected when you send a direct message to the agent from this UI.',
  msg_token_refreshed: 'Injected if the daemon restarts and re-authenticates the wrapper with a fresh token.',
  msg_stop_requested: 'Injected when you request a graceful shutdown from this UI.',
};

export default function SettingsPage({ session, onReconnect, onBack }) {
  const dispatch = useDispatch<any>();
  const [preferences, setPreferences] = useState<Preference[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [savingKey, setSavingKey] = useState<string | null>(null);
  const [resettingKey, setResettingKey] = useState<string | null>(null);
  const [knownAgents, setKnownAgents] = useState<any[]>([]);
  const [isSavingAuditing, setIsSavingAuditing] = useState(false);

  // Edit states for fields in the UI
  const [editValues, setEditValues] = useState<Record<string, string>>({});
  const [editInterrupts, setEditInterrupts] = useState<Record<string, boolean>>({});
  const [resettingSetup, setResettingSetup] = useState(false);

  const textareasRef = useRef<Record<string, HTMLTextAreaElement | null>>({});

  // Fetch preferences ONLY on component mount, satisfying the lazy-fetch constraint
  useEffect(() => {
    if (session?.daemonUrl && session?.clientToken) {
      fetchPrefs();
      fetchKnownAgents();
    }
  }, [session?.daemonUrl, session?.clientToken]);

  const fetchKnownAgents = async () => {
    try {
      const list = await daemonApi.listKnownAgents({ daemonUrl: session.daemonUrl });
      setKnownAgents(list);
    } catch (err) {
      console.error('Failed to fetch known agents:', err);
    }
  };

  const fetchPrefs = async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await daemonApi.fetchPreferences({
        daemonUrl: session.daemonUrl,
        clientToken: session.clientToken,
      });
      if (data?.preferences) {
        setPreferences(data.preferences);
        // Initialize edit buffers
        const vals: Record<string, string> = {};
        const ints: Record<string, boolean> = {};
        data.preferences.forEach((p: Preference) => {
          vals[p.key] = p.value;
          ints[p.key] = p.interrupt;
        });
        setEditValues(vals);
        setEditInterrupts(ints);
      }
    } catch (err: any) {
      setError(err?.message || 'Failed to fetch user preferences');
    } finally {
      setLoading(false);
    }
  };

  const handleSave = async (key: string) => {
    setSavingKey(key);
    try {
      const data = await daemonApi.savePreference({
        daemonUrl: session.daemonUrl,
        clientToken: session.clientToken,
        key,
        value: editValues[key] ?? '',
        interrupt: editInterrupts[key] ?? false,
      });
      if (data?.ok && data?.preference) {
        // Update local preferences list state
        setPreferences(prev =>
          prev.map(p => (p.key === key ? data.preference : p))
        );
      }
    } catch (err: any) {
      alert(`Error saving preference: ${err?.message || 'Unknown error'}`);
    } finally {
      setSavingKey(null);
    }
  };

  const handleReset = async (key: string) => {
    if (!confirm('Are you sure you want to reset this template back to its default value?')) {
      return;
    }
    setResettingKey(key);
    try {
      const data = await daemonApi.resetPreference({
        daemonUrl: session.daemonUrl,
        clientToken: session.clientToken,
        key,
      });
      if (data?.ok && data?.preference) {
        setPreferences(prev =>
          prev.map(p => (p.key === key ? data.preference : p))
        );
        setEditValues(prev => ({ ...prev, [key]: data.preference.value }));
        setEditInterrupts(prev => ({ ...prev, [key]: data.preference.interrupt }));
      }
    } catch (err: any) {
      alert(`Error resetting preference: ${err?.message || 'Unknown error'}`);
    } finally {
      setResettingKey(null);
    }
  };

  const handleBadgeClick = (key: string, badge: string) => {
    const textarea = textareasRef.current[key];
    if (!textarea) return;

    const start = textarea.selectionStart;
    const end = textarea.selectionEnd;
    const text = editValues[key] ?? '';
    const newText = text.substring(0, start) + badge + text.substring(end);

    setEditValues(prev => ({ ...prev, [key]: newText }));

    // Refocus and place cursor after the inserted badge
    setTimeout(() => {
      textarea.focus();
      textarea.setSelectionRange(start + badge.length, start + badge.length);
    }, 0);
  };

  const auditingKeys = [
    'memory_auditor_enabled',
    'memory_auditor_agent_id',
    'memory_auditor_model_tier',
    'memory_auditor_provider_profile',
    'memory_reviewer_agent_id',
    'memory_reviewer_model_tier',
    'memory_reviewer_provider_profile'
  ];

  const bootstrapPrefs = preferences.filter(p =>
    ['starter_prompt', 'bootstrap_header', 'bootstrap_title', 'bootstrap_profile_guidance'].includes(p.key)
  );

  const livePrefs = preferences.filter(p =>
    !['starter_prompt', 'bootstrap_header', 'bootstrap_title', 'bootstrap_profile_guidance', 'backup_dir', ...auditingKeys].includes(p.key)
  );

  const handleSaveAuditingConfig = async () => {
    setIsSavingAuditing(true);
    try {
      const promises = auditingKeys.map(key =>
        daemonApi.savePreference({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          key,
          value: editValues[key] ?? '',
          interrupt: false,
        })
      );
      const results = await Promise.all(promises);
      setPreferences(prev => {
        let updated = [...prev];
        results.forEach(res => {
          if (res?.ok && res?.preference) {
            updated = updated.map(p => (p.key === res.preference.key ? res.preference : p));
          }
        });
        return updated;
      });
      alert('Cognitive Memory Auditing configuration saved successfully!');
    } catch (err: any) {
      alert(`Error saving auditing config: ${err?.message || 'Unknown error'}`);
    } finally {
      setIsSavingAuditing(false);
    }
  };

  const hasAuditingChanged = auditingKeys.some(key => {
    const pref = preferences.find(p => p.key === key);
    return pref ? (editValues[key] ?? '') !== pref.value : false;
  });

  const knownAgentIds = knownAgents.map(a => a.agent_instance_id);
  const configuredAuditor = editValues['memory_auditor_agent_id'] || '';
  const configuredReviewer = editValues['memory_reviewer_agent_id'] || '';

  const isAuditorKnown = configuredAuditor !== '' && knownAgentIds.includes(configuredAuditor);
  const isReviewerKnown = configuredReviewer !== '' && knownAgentIds.includes(configuredReviewer);
  const canEnableAuditing = isAuditorKnown && isReviewerKnown;

  const auditorOptions = Array.from(new Set([...knownAgentIds, configuredAuditor])).filter(Boolean);
  const reviewerOptions = Array.from(new Set([...knownAgentIds, configuredReviewer])).filter(Boolean);

  const [backingUp, setBackingUp] = useState(false);

  const handleTriggerBackup = async () => {
    setBackingUp(true);
    try {
      const response = await fetch(`${session.daemonUrl}/backup/trigger`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          client_token: session.clientToken,
          agent_token: session.clientToken,
        }),
      });
      const data = await response.json();
      if (response.ok && data.ok) {
        alert(data.message || 'Database backup completed successfully!');
      } else {
        alert(`Backup failed: ${data.message || 'Unknown error'}`);
      }
    } catch (err: any) {
      alert(`Network error triggering backup: ${err?.message || 'Unknown error'}`);
    } finally {
      setBackingUp(false);
    }
  };

  const handleRerunSetup = async () => {
    if (!confirm('Are you sure you want to rerun the first-time setup wizard? You will be immediately redirected to the onboarding flow.')) {
      return;
    }
    setResettingSetup(true);
    try {
      await dispatch(saveUserPreference({
        key: 'setup_completed',
        value: 'false',
        interrupt: false,
      })).unwrap();
    } catch (err: any) {
      alert(`Failed to reset setup: ${err?.message || 'Unknown error'}`);
    } finally {
      setResettingSetup(false);
    }
  };

  return (
    <main className="framer-panel flex min-w-0 min-h-0 h-full flex-1 flex-col bg-[var(--fd-canvas)]">
      <header className="flex items-center justify-between border-b border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] px-6 py-4">
        <div>
          <p className="framer-topline">Settings</p>
          <h2 className="mt-1 truncate text-2xl font-bold text-white">Daemon + User preferences</h2>
          <p className="framer-subtext mt-1">Manage connection details, notification templates, and operating rules</p>
        </div>
        <button
          type="button"
          data-debug-id="settings-back-btn"
          onClick={onBack}
          className="framer-pill-secondary px-4 py-2 text-xs"
        >
          Back to chat
        </button>
      </header>

      <section className="flex-1 overflow-y-auto px-6 py-6">
        <div className="w-full max-w-3xl space-y-6">
          {/* 1. Connection Config */}
          <div className="framer-card p-6">
            <h3 className="text-sm font-semibold text-[#888] uppercase tracking-wider mb-4">Connection Config</h3>
            <SessionConfig session={session} onReconnect={onReconnect} />
            <div className="mt-4 text-[11px] text-[#777] leading-relaxed">
              <p>Session and connection details persist locally in Electron and are used across restarts.</p>
              <p className="mt-1">Changing user ID regenerates local client identity and credentials.</p>
            </div>
          </div>



          {/* 3. User Preferences */}
          <div className="framer-card p-6">
            <h3 className="text-sm font-semibold text-[#888] uppercase tracking-wider mb-2">User Preferences</h3>
            <p className="text-xs text-[#666] mb-4">Customize the templates and behaviors Heimdall uses to prompt and notify your active agents.</p>

            {loading && (
              <div className="flex items-center justify-center py-8 text-xs text-[#888]">
                <div className="animate-spin mr-2 h-4 w-4 border-2 border-t-transparent border-[var(--fd-accent)] rounded-full"></div>
                Loading preferences...
              </div>
            )}

            {error && (
              <div className="border border-red-500/20 bg-red-500/5 text-red-400 text-xs p-3 rounded mb-4">
                {error}
              </div>
            )}

            {!loading && preferences.length > 0 && (
              <div className="space-y-6">
                {/* A. Group 1: Bootstrap & Starter Templates */}
                <div>
                  <h4 className="text-xs font-bold text-white border-b border-[var(--fd-hairline)] pb-2 mb-4">
                    📁 Group 1: Workspace Bootstrap & Starter Templates
                  </h4>
                  <div className="space-y-4">
                    {bootstrapPrefs.map(pref => renderPrefCard(pref))}
                  </div>
                </div>

                {/* B. Group 2: Live Notification Templates */}
                <div className="mt-8">
                  <h4 className="text-xs font-bold text-white border-b border-[var(--fd-hairline)] pb-2 mb-4">
                    📂 Group 2: Live Active Notification Templates
                  </h4>
                  <div className="space-y-4">
                    {livePrefs.map(pref => renderPrefCard(pref, true))}
                  </div>
                </div>
              </div>
            )}
          </div>

          {/* 4. Database Backups */}
          <div className="framer-card p-6">
            <h3 className="text-sm font-semibold text-[#888] uppercase tracking-wider mb-2">🗄️ Database Backups</h3>
            <p className="text-xs text-[#666] mb-4">
              Backup all local SQLite databases (tasks, template registry, chat history, preferences, and memories) to a secure dated folder. 
              The daemon automatically takes a scheduled backup once every day in the background.
            </p>

            <div className="space-y-4">
              {/* Backup Dir Input */}
              <div className="flex flex-col gap-2">
                <label className="text-[10px] text-[#555] font-bold uppercase tracking-wider">💾 Backup Destination Directory</label>
                <div className="flex gap-2">
                  <input
                    type="text"
                    value={editValues['backup_dir'] ?? ''}
                    onChange={(e) => setEditValues(prev => ({ ...prev, backup_dir: e.target.value }))}
                    onBlur={async () => {
                      const val = editValues['backup_dir'] ?? '';
                      try {
                        await daemonApi.savePreference({
                          daemonUrl: session.daemonUrl,
                          clientToken: session.clientToken,
                          key: 'backup_dir',
                          value: val,
                          interrupt: false,
                        });
                      } catch (err) {
                        console.error('Failed to save backup_dir preference:', err);
                      }
                    }}
                    className="framer-input px-3 py-2 text-xs w-full font-mono"
                    placeholder="e.g. ~/heimdall-backups"
                  />
                </div>
                <span className="text-[10px] text-[#555] italic">Home directory (~) will be expanded automatically on the backend.</span>
              </div>

              {/* Trigger Backup Button */}
              <div className="pt-2">
                <button
                  type="button"
                  onClick={handleTriggerBackup}
                  disabled={backingUp}
                  className={`px-4 py-2.5 rounded-xl font-bold text-xs transition-[transform,colors] duration-200 ${
                    backingUp
                      ? 'bg-[#111] border border-[#222] text-[#444] pointer-events-none'
                      : 'bg-white text-black hover:bg-[#e0e0e0] active:scale-[0.98]'
                  }`}
                >
                  {backingUp ? (
                    <div className="flex items-center justify-center">
                      <div className="animate-spin mr-2 h-3.5 w-3.5 border-2 border-t-transparent border-white rounded-full"></div>
                      Backing up...
                    </div>
                  ) : (
                    'Backup Databases Now'
                  )}
                </button>
              </div>
            </div>
          </div>

          {/* 5. Onboarding & Setup */}
          <div className="framer-card p-6 border border-amber-500/10 bg-amber-500/5">
            <h3 className="text-sm font-semibold text-[#888] uppercase tracking-wider mb-2">🛡️ Setup & Onboarding</h3>
            <p className="text-xs text-[#666] mb-4">
              Rerun the interactive onboarding wizard to configure your daemon connection IP, set your friendly operator display name, specify your database backup folder, and re-verify your agent connectivity tests.
            </p>
            <div className="pt-2">
              <button
                type="button"
                onClick={handleRerunSetup}
                disabled={resettingSetup}
                 className="px-4 py-2.5 rounded-xl font-bold text-xs bg-amber-500 text-black hover:bg-amber-400 active:scale-[0.98] transition-[transform,colors] duration-200"
              >
                {resettingSetup ? 'Resetting Setup...' : 'Rerun Setup Wizard'}
              </button>
            </div>
          </div>

        </div>
      </section>
    </main>
  );

  function renderPrefCard(pref: Preference, showInterruptToggle = false) {
    const key = pref.key;
    const value = editValues[key] ?? '';
    const interrupt = editInterrupts[key] ?? false;
    const isSaving = savingKey === key;
    const isResetting = resettingKey === key;
    const hasChanged = value !== pref.value || (showInterruptToggle && interrupt !== pref.interrupt);

    return (
      <div key={key} className="framer-card bg-[#181818] p-4 border border-[var(--fd-hairline)] hover:border-[#333] transition-colors">
        <div className="flex items-start justify-between">
          <div>
            <h5 className="text-xs font-bold text-white flex items-center">
              {KEY_LABELS[key] || key}
              {pref.is_custom && (
                <span className="ml-2 bg-[var(--fd-accent)]/10 border border-[var(--fd-accent)]/20 text-[var(--fd-accent)] text-[9px] px-1.5 py-0.5 rounded font-normal uppercase">
                  Customized
                </span>
              )}
            </h5>
            <p className="text-[11px] text-[#666] mt-1">{KEY_DESCRIPTIONS[key] || ''}</p>
          </div>
          
          {pref.is_custom && (
            <button
              type="button"
              disabled={isResetting || isSaving}
              onClick={() => handleReset(key)}
              className="text-[10px] text-[#999] hover:text-red-400 transition-colors ml-4"
            >
              {isResetting ? 'Resetting...' : 'Reset Default'}
            </button>
          )}
        </div>

        {/* Placeholders helper badges */}
        {PLACEHOLDERS[key] && PLACEHOLDERS[key].length > 0 && (
          <div className="flex flex-wrap gap-1.5 mt-3 mb-2">
            <span className="text-[10px] text-[#555] self-center mr-1">Insert Badge:</span>
            {PLACEHOLDERS[key].map(placeholder => (
              <button
                key={placeholder}
                type="button"
                onClick={() => handleBadgeClick(key, placeholder)}
                className="bg-[#222] hover:bg-[#333] border border-[#2c2c2c] text-[var(--fd-accent)] text-[10px] px-2 py-0.5 rounded font-mono transition-colors"
              >
                {placeholder}
              </button>
            ))}
          </div>
        )}

        <div className="mt-3 space-y-3">
          <textarea
            ref={el => { textareasRef.current[key] = el; }}
            value={value}
            onChange={e => setEditValues(prev => ({ ...prev, [key]: e.target.value }))}
            className="w-full bg-[#101010] border border-[#222] focus:border-[var(--fd-accent)] text-xs text-white p-2.5 rounded font-mono focus:outline-none resize-y min-h-[60px] leading-relaxed"
            placeholder="Type your custom template here..."
            rows={key === 'bootstrap_profile_guidance' ? 12 : 2}
          />

          <div className="flex items-center justify-between mt-2 pt-1">
            {showInterruptToggle ? (
              <label className="flex items-center text-xs text-[#888] cursor-pointer select-none">
                <input
                  type="checkbox"
                  checked={interrupt}
                  onChange={e => setEditInterrupts(prev => ({ ...prev, [key]: e.target.checked }))}
                  className="mr-2 accent-[var(--fd-accent)]"
                />
                <span>Interrupt Active Agent (Prefix with Escape)</span>
              </label>
            ) : (
              <div></div>
            )}

            <button
              type="button"
              disabled={isSaving || isResetting || !hasChanged}
              onClick={() => handleSave(key)}
              className={`framer-pill-primary px-4 py-1.5 text-[11px] font-semibold transition-[transform,colors] duration-200 ${
                hasChanged ? 'opacity-100 hover:scale-102' : 'opacity-40 cursor-not-allowed'
              }`}
            >
              {isSaving ? 'Saving...' : 'Save Override'}
            </button>
          </div>
        </div>
      </div>
    );
  }
}
