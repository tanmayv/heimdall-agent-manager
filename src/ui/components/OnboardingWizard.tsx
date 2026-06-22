import React, { useState, useEffect } from 'react';
import { useDispatch } from 'react-redux';
import { registerSession, fetchPreferences, setDaemonUrl } from '../store/chatSlice';
import * as daemonApi from '../api/daemonApi';

interface OnboardingWizardProps {
  onComplete: () => void;
}

export default function OnboardingWizard({ onComplete }: OnboardingWizardProps) {
  const dispatch = useDispatch<any>();
  const [step, setStep] = useState<number>(1);
  const [loading, setLoading] = useState<boolean>(false);
  const [error, setError] = useState<string | null>(null);

  // Form Fields
  const [daemonIp, setDaemonIp] = useState<string>('http://127.0.0.1:49322');
  const [displayName, setDisplayName] = useState<string>('');
  const [backupDir, setBackupDir] = useState<string>('~/heimdall-backups');
  const [provisionMemoryAgents, setProvisionMemoryAgents] = useState<boolean>(true);

  // New Smoke Test & Curation Agents State
  const [availableProviders, setAvailableProviders] = useState<any[]>([]);
  const [selectedProvidersToTest, setSelectedProvidersToTest] = useState<string[]>([]);
  
  const [memoryAuditorProvider, setMemoryAuditorProvider] = useState<string>('');
  const [memoryAuditorTier, setMemoryAuditorTier] = useState<string>('smart');
  const [memoryReviewerProvider, setMemoryReviewerProvider] = useState<string>('');
  const [memoryReviewerTier, setMemoryReviewerTier] = useState<string>('smart');

  // Test Results State
  const [testResults, setTestResults] = useState<any[]>([]);
  const [testingAgents, setTestingAgents] = useState<boolean>(false);

  // Step 1: Connect to Daemon
  const handleConnectDaemon = async () => {
    setLoading(true);
    setError(null);
    try {
      dispatch(setDaemonUrl(daemonIp));
      await dispatch(registerSession()).unwrap();
      await dispatch(fetchPreferences()).unwrap();
      setStep(2);
    } catch (err: any) {
      setError(err.message || 'Failed to connect to Heimdall Daemon. Please check the IP address and ensure the daemon is running.');
    } finally {
      setLoading(false);
    }
  };

  // Load configured providers when entering Step 4
  useEffect(() => {
    if (step >= 4 && daemonIp && availableProviders.length === 0) {
      daemonApi.listAgentProviders({ daemonUrl: daemonIp })
        .then((list) => {
          setAvailableProviders(list);
          setSelectedProvidersToTest(list.map((p: any) => p.name));
          if (list.length > 0) {
            setMemoryAuditorProvider(list[0].name);
            setMemoryReviewerProvider(list[0].name);
          }
        })
        .catch((err) => console.error('Failed to load providers:', err));
    }
  }, [step, daemonIp, availableProviders.length]);

  // Step 4: Run Agent Tests
  const handleTestAgents = async () => {
    setTestingAgents(true);
    setError(null);
    try {
      const res = await daemonApi.testAgentConnectivity({
        daemonUrl: daemonIp,
        clientToken: window.localStorage.getItem('odin.clientToken') || '',
        providers: selectedProvidersToTest.join(','),
      });
      if (res?.results) {
        setTestResults(res.results);
      }
    } catch (err: any) {
      setError('Failed to run agent connectivity tests: ' + (err.message || 'unknown error'));
    } finally {
      setTestingAgents(false);
    }
  };

  // Step 5: Finalize Setup
  const handleFinalizeSetup = async () => {
    setLoading(true);
    setError(null);
    try {
      const token = window.localStorage.getItem('odin.clientToken') || '';

      // 1. Save preferences
      await daemonApi.savePreference({
        daemonUrl: daemonIp,
        clientToken: token,
        key: 'user_display_name',
        value: displayName,
        interrupt: false,
      });

      await daemonApi.savePreference({
        daemonUrl: daemonIp,
        clientToken: token,
        key: 'backup_dir',
        value: backupDir,
        interrupt: false,
      });

      // 2. Provision memory auditor & reviewer agents if requested
      if (provisionMemoryAgents) {
        // Create Memory Auditor Agent
        await daemonApi.createAgent({
          daemonUrl: daemonIp,
          agentInstanceId: 'memory-auditor@heimdall-system',
          displayName: 'Memory Auditor',
          templateId: 'memory_auditor',
          providerProfile: memoryAuditorProvider || 'pi',
          modelTier: memoryAuditorTier,
          projectId: 'default',
        });

        // Create Memory Reviewer Agent
        await daemonApi.createAgent({
          daemonUrl: daemonIp,
          agentInstanceId: 'memory-reviewer@heimdall-system',
          displayName: 'Memory Reviewer',
          templateId: 'memory_reviewer',
          providerProfile: memoryReviewerProvider || 'pi',
          modelTier: memoryReviewerTier,
          projectId: 'default',
        });
      }

      // 3. Save setup completed preference
      await daemonApi.savePreference({
        daemonUrl: daemonIp,
        clientToken: token,
        key: 'setup_completed',
        value: 'true',
        interrupt: false,
      });

      // 4. Refresh preferences and state in Redux
      await dispatch(fetchPreferences()).unwrap();
      onComplete();
    } catch (err: any) {
      setError(err.message || 'Failed to complete setup configuration.');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-[var(--fd-canvas)] p-6 text-white overflow-y-auto">
      <div className="framer-panel w-full max-w-xl rounded-[var(--fd-radius-xl)] border border-[var(--fd-hairline)] bg-[var(--fd-surface-1)] p-8 shadow-2xl">
        
        {/* Header */}
        <div className="mb-8 text-center">
          <p className="framer-topline tracking-[0.3em]">WELCOME TO HEIMDALL</p>
          <h2 className="mt-2 text-3xl font-extrabold text-white">First-Time Setup Wizard</h2>
          <div className="mt-4 flex justify-center gap-2">
            {[1, 2, 3, 4, 5].map((idx) => (
              <div
                key={idx}
                className={`h-1.5 w-8 rounded-full transition-colors duration-300 ${
                  step === idx ? 'bg-[var(--fd-accent-blue)]' : idx < step ? 'bg-emerald-400' : 'bg-[var(--fd-surface-3)]'
                }`}
              />
            ))}
          </div>
        </div>

        {error && (
          <div className="mb-6 rounded-[var(--fd-radius-lg)] border border-rose-500/30 bg-rose-500/10 p-4 text-sm text-rose-200 animate-bubble-pop">
            {error}
          </div>
        )}

        {/* Step 1: Daemon Connection */}
        {step === 1 && (
          <div className="space-y-6">
            <div>
              <h3 className="text-lg font-semibold text-white">Connect to Heimdall Daemon</h3>
              <p className="framer-subtext mt-1">
                Enter the address where your Heimdall daemon is running. This allows the UI to connect even if the daemon runs on a remote cloud top or virtual machine.
              </p>
            </div>
            <div className="space-y-2">
              <label className="block text-xs font-semibold uppercase tracking-wider text-[#aaa]">Daemon IP / URL</label>
              <input
                type="text"
                value={daemonIp}
                onChange={(e) => setDaemonIp(e.target.value)}
                placeholder="http://127.0.0.1:49322"
                className="w-full rounded-[var(--fd-radius-md)] border border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] px-4 py-2.5 text-white transition focus:border-[var(--fd-accent-blue)] focus:outline-none"
              />
            </div>
            <button
              onClick={handleConnectDaemon}
              disabled={loading || !daemonIp.trim()}
              className="w-full rounded-[var(--fd-radius-lg)] bg-[var(--fd-accent-blue)] py-3.5 font-semibold text-white transition hover:bg-[var(--fd-accent-blue)]/80 disabled:opacity-50"
            >
              {loading ? 'Connecting...' : 'Connect Daemon →'}
            </button>
          </div>
        )}

        {/* Step 2: User Profile Setup */}
        {step === 2 && (
          <div className="space-y-6">
            <div>
              <h3 className="text-lg font-semibold text-white">Operator Profile Identity</h3>
              <p className="framer-subtext mt-1">
                Tell us your display name. Heimdall will display this alongside your operator ID throughout the workspace.
              </p>
            </div>
            <div className="space-y-2">
              <label className="block text-xs font-semibold uppercase tracking-wider text-[#aaa]">Display Name</label>
              <input
                type="text"
                value={displayName}
                onChange={(e) => setDisplayName(e.target.value)}
                placeholder="e.g., Jane Doe"
                className="w-full rounded-[var(--fd-radius-md)] border border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] px-4 py-2.5 text-white transition focus:border-[var(--fd-accent-blue)] focus:outline-none"
              />
            </div>
            <div className="flex gap-4">
              <button
                onClick={() => setStep(1)}
                className="flex-1 rounded-[var(--fd-radius-lg)] border border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] py-3 font-semibold text-white transition hover:bg-[var(--fd-surface-3)]"
              >
                ← Back
              </button>
              <button
                onClick={() => setStep(3)}
                disabled={!displayName.trim()}
                className="flex-1 rounded-[var(--fd-radius-lg)] bg-[var(--fd-accent-blue)] py-3 font-semibold text-white transition hover:bg-[var(--fd-accent-blue)]/80 disabled:opacity-50"
              >
                Continue →
              </button>
            </div>
          </div>
        )}

        {/* Step 3: Database Backup Storage */}
        {step === 3 && (
          <div className="space-y-6">
            <div>
              <h3 className="text-lg font-semibold text-white">Database Backup Storage</h3>
              <p className="framer-subtext mt-1">
                Provide a path where your database backups will be saved on the host machine. If this directory path doesn't exist, the daemon will automatically create it.
              </p>
            </div>
            <div className="space-y-2">
              <label className="block text-xs font-semibold uppercase tracking-wider text-[#aaa]">Backup Directory Path</label>
              <input
                type="text"
                value={backupDir}
                onChange={(e) => setBackupDir(e.target.value)}
                placeholder="~/heimdall-backups"
                className="w-full rounded-[var(--fd-radius-md)] border border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] px-4 py-2.5 text-white transition focus:border-[var(--fd-accent-blue)] focus:outline-none"
              />
              <span className="text-[11px] text-emerald-400">✓ Path will be resolved and created remotely by the daemon.</span>
            </div>
            <div className="flex gap-4">
              <button
                onClick={() => setStep(2)}
                className="flex-1 rounded-[var(--fd-radius-lg)] border border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] py-3 font-semibold text-white transition hover:bg-[var(--fd-surface-3)]"
              >
                ← Back
              </button>
              <button
                onClick={() => setStep(4)}
                disabled={!backupDir.trim()}
                className="flex-1 rounded-[var(--fd-radius-lg)] bg-[var(--fd-accent-blue)] py-3 font-semibold text-white transition hover:bg-[var(--fd-accent-blue)]/80 disabled:opacity-50"
              >
                Continue →
              </button>
            </div>
          </div>
        )}

        {/* Step 4: Optional Agent Connectivity Test */}
        {step === 4 && (
          <div className="space-y-6">
            <div>
              <h3 className="text-lg font-semibold text-white">Verify Configured Agents</h3>
              <p className="framer-subtext mt-1">
                Select the agent providers you want to verify. We will run a quick check on the host to ensure their executable commands are runnable.
              </p>
            </div>

            <div className="space-y-3 max-h-56 overflow-y-auto pr-1">
              {availableProviders.map((provider) => {
                const isChecked = selectedProvidersToTest.includes(provider.name);
                return (
                  <div key={provider.name} className="framer-card p-3.5 flex items-center justify-between bg-[var(--fd-surface-2)]">
                    <label className="flex items-center gap-3 cursor-pointer select-none">
                      <input
                        type="checkbox"
                        checked={isChecked}
                        onChange={(e) => {
                          if (e.target.checked) {
                            setSelectedProvidersToTest([...selectedProvidersToTest, provider.name]);
                          } else {
                            setSelectedProvidersToTest(selectedProvidersToTest.filter((name) => name !== provider.name));
                          }
                        }}
                        className="h-4 w-4 rounded border-[var(--fd-hairline)] bg-[var(--fd-surface-3)] accent-[var(--fd-accent-blue)]"
                      />
                      <div>
                        <div className="font-semibold text-white capitalize text-sm">{provider.name}</div>
                        <div className="text-[10px] text-[#999] mt-0.5 font-mono">
                          {provider.command?.join(' ') || provider.name}
                        </div>
                      </div>
                    </label>
                    
                    <div className="text-right">
                      <div className="flex gap-1">
                        {['cheap', 'normal', 'smart'].map((tier) => {
                          const modelName = provider.tiers?.[tier];
                          if (!modelName) return null;
                          return (
                            <span key={tier} className="text-[9px] bg-[var(--fd-surface-3)] text-[#999] px-1.5 py-0.5 rounded border border-[var(--fd-hairline)] font-medium capitalize" title={modelName}>
                              {tier}
                            </span>
                          );
                        })}
                      </div>
                    </div>
                  </div>
                );
              })}
              {availableProviders.length === 0 && (
                <div className="text-sm text-[#999] italic p-4 text-center">Loading agent providers from daemon...</div>
              )}
            </div>

            {testResults.length > 0 && (
              <div className="space-y-2 rounded-[var(--fd-radius-lg)] border border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] p-4 max-h-36 overflow-y-auto">
                {testResults.map((res) => (
                  <div key={res.name} className="flex items-start gap-3 text-sm">
                    <span className={res.ok ? 'text-emerald-400 font-bold' : 'text-rose-400 font-bold'}>
                      {res.ok ? '✓' : '✗'}
                    </span>
                    <div>
                      <div className="font-semibold text-white capitalize">{res.name}</div>
                      <div className="text-xs text-[#aaa]">{res.message}</div>
                    </div>
                  </div>
                ))}
              </div>
            )}

            <button
              onClick={handleTestAgents}
              disabled={testingAgents || selectedProvidersToTest.length === 0}
              className="w-full rounded-[var(--fd-radius-lg)] border border-[var(--fd-accent-blue)] bg-[var(--fd-accent-blue)]/10 py-3 font-semibold text-[var(--fd-accent-blue)] transition hover:bg-[var(--fd-accent-blue)]/20 disabled:opacity-40"
            >
              {testingAgents ? 'Running Smoke Tests...' : '🔍 Run Selected Smoke Tests'}
            </button>

            <div className="flex gap-4 border-t border-[var(--fd-hairline)] pt-4">
              <button
                onClick={() => setStep(3)}
                className="flex-1 rounded-[var(--fd-radius-lg)] border border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] py-3 font-semibold text-white transition hover:bg-[var(--fd-surface-3)]"
              >
                ← Back
              </button>
              <button
                onClick={() => setStep(5)}
                className="flex-1 rounded-[var(--fd-radius-lg)] bg-[var(--fd-accent-blue)] py-3 font-semibold text-white transition hover:bg-[var(--fd-accent-blue)]/80"
              >
                Continue →
              </button>
            </div>
          </div>
        )}

        {/* Step 5: Provision Memory Agents & Finalize */}
        {step === 5 && (
          <div className="space-y-6">
            <div>
              <h3 className="text-lg font-semibold text-white">Background Curation Agents</h3>
              <p className="framer-subtext mt-1">
                Configure the default background agents that automatically audit your task chains and write structured, clean memories into your PKM folder.
              </p>
            </div>

            <label className="framer-card flex items-start gap-3 border border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] p-4 rounded-[var(--fd-radius-lg)] cursor-pointer select-none transition hover:border-[var(--fd-accent-blue)]/40">
              <input
                type="checkbox"
                checked={provisionMemoryAgents}
                onChange={(e) => setProvisionMemoryAgents(e.target.checked)}
                className="mt-1 h-4 w-4 rounded border-[var(--fd-hairline)] bg-[var(--fd-surface-3)] text-[var(--fd-accent-blue)] focus:ring-[var(--fd-accent-blue)]"
              />
              <div>
                <span className="block text-sm font-semibold text-white">Provision Curation Agents</span>
                <span className="framer-subtext mt-1 block text-xs">
                  Automatically spins up background auditor & reviewer agents on setup complete.
                </span>
              </div>
            </label>

            {provisionMemoryAgents && (
              <div className="space-y-4 p-4 border border-[var(--fd-hairline)] rounded-[var(--fd-radius-lg)] bg-[var(--fd-surface-2)] max-h-60 overflow-y-auto">
                {/* Memory Auditor Config */}
                <div className="space-y-3">
                  <div className="text-xs font-bold uppercase tracking-wider text-[var(--fd-accent-blue)]">
                    Agent: memory-auditor@heimdall-system
                  </div>
                  <div className="grid grid-cols-2 gap-3">
                    <div>
                      <label className="block text-[10px] font-semibold uppercase text-[#999] mb-1">Provider Profile</label>
                      <select
                        value={memoryAuditorProvider}
                        onChange={(e) => setMemoryAuditorProvider(e.target.value)}
                        className="w-full rounded bg-[var(--fd-surface-3)] border border-[var(--fd-hairline)] px-3 py-2 text-xs text-white focus:outline-none"
                      >
                        {availableProviders.map((p) => <option key={p.name} value={p.name}>{p.name}</option>)}
                      </select>
                    </div>
                    <div>
                      <label className="block text-[10px] font-semibold uppercase text-[#999] mb-1">Model Tier</label>
                      <select
                        value={memoryAuditorTier}
                        onChange={(e) => setMemoryAuditorTier(e.target.value)}
                        className="w-full rounded bg-[var(--fd-surface-3)] border border-[var(--fd-hairline)] px-3 py-2 text-xs text-white focus:outline-none"
                      >
                        <option value="smart">smart (recommended)</option>
                        <option value="normal">normal</option>
                        <option value="cheap">cheap</option>
                      </select>
                    </div>
                  </div>
                </div>

                <div className="border-t border-[var(--fd-hairline)] my-4" />

                {/* Memory Reviewer Config */}
                <div className="space-y-3">
                  <div className="text-xs font-bold uppercase tracking-wider text-[var(--fd-accent-blue)]">
                    Agent: memory-reviewer@heimdall-system
                  </div>
                  <div className="grid grid-cols-2 gap-3">
                    <div>
                      <label className="block text-[10px] font-semibold uppercase text-[#999] mb-1">Provider Profile</label>
                      <select
                        value={memoryReviewerProvider}
                        onChange={(e) => setMemoryReviewerProvider(e.target.value)}
                        className="w-full rounded bg-[var(--fd-surface-3)] border border-[var(--fd-hairline)] px-3 py-2 text-xs text-white focus:outline-none"
                      >
                        {availableProviders.map((p) => <option key={p.name} value={p.name}>{p.name}</option>)}
                      </select>
                    </div>
                    <div>
                      <label className="block text-[10px] font-semibold uppercase text-[#999] mb-1">Model Tier</label>
                      <select
                        value={memoryReviewerTier}
                        onChange={(e) => setMemoryReviewerTier(e.target.value)}
                        className="w-full rounded bg-[var(--fd-surface-3)] border border-[var(--fd-hairline)] px-3 py-2 text-xs text-white focus:outline-none"
                      >
                        <option value="smart">smart (recommended)</option>
                        <option value="normal">normal</option>
                        <option value="cheap">cheap</option>
                      </select>
                    </div>
                  </div>
                </div>
              </div>
            )}

            <div className="flex gap-4 border-t border-[var(--fd-hairline)] pt-4">
              <button
                onClick={() => setStep(4)}
                disabled={loading}
                className="flex-1 rounded-[var(--fd-radius-lg)] border border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] py-3 font-semibold text-white transition hover:bg-[var(--fd-surface-3)] disabled:opacity-50"
              >
                ← Back
              </button>
              <button
                onClick={handleFinalizeSetup}
                disabled={loading}
                className="flex-1 rounded-[var(--fd-radius-lg)] bg-emerald-500 py-3 font-semibold text-white transition hover:bg-emerald-600 disabled:opacity-50 shadow-[0_0_15px_rgba(16,185,129,0.3)]"
              >
                {loading ? 'Finalizing Setup...' : '🎉 Complete Setup!'}
              </button>
            </div>
          </div>
        )}

      </div>
    </div>
  );
}
