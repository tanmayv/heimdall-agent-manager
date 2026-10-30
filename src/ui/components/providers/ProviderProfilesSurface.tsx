import { useEffect, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { Button, Spinner } from '@ui';
import { heimdallApi } from '../../api/heimdallApi';
import { apiErrorText, cookieMutation } from '../../api/cookieFetch';
import { selectIsVaultUnlocked } from '../../store/vaultSlice';
import { encryptVaultText } from '../../utils/vaultCrypto';
import { providerSetupApi, type BridgeProviderStatus } from './providerSetupApi';
import {
  decodeProfileArgs,
  encodeProfileArgs,
  environmentForSave,
  generateProfileId,
  profileIdentityError,
  profileLabel,
  providerProfilesApi,
  type ProfileMetadata,
  type ProviderProfile,
  type ProfileEnv,
} from './providerProfiles';
import ProviderExtensionInstallAction from '../extension/ProviderExtensionInstallAction';
import ProviderTestRunModal, { type ProviderTestTarget } from './ProviderTestRunModal';

const fieldClass =
  'w-full rounded-lg border border-subtle bg-surface px-3 py-2 text-sm text-primary disabled:opacity-50';
const newProfile = (provider: string, used: string[]): ProviderProfile => ({
  profile_id: generateProfileId(provider, used),
  provider,
  label_enc: '',
  accent: '#7c6af7',
  enabled: true,
  environment: [],
  config: {},
});

export function ProfileRuntimeEditor({
  profile,
  onChange,
  disabled = false,
}: {
  profile: ProviderProfile;
  onChange: (p: ProviderProfile) => void;
  disabled?: boolean;
}) {
  const config = (key: keyof ProviderProfile['config'], value: unknown) =>
    onChange({ ...profile, config: { ...profile.config, [key]: value } });
  const row = (
    key: keyof ProviderProfile['config'],
    label: string,
    help: string,
    secret = false,
  ) => (
    <label className="block space-y-1">
      <span className="text-sm font-medium">{label}</span>
      <input
        className={fieldClass}
        data-debug-id={'profile-config-' + key}
        type={secret ? 'password' : 'text'}
        autoComplete="off"
        disabled={disabled}
        value={String(profile.config[key] || '')}
        placeholder={
          secret && profile.config.api_key_redacted
            ? 'Stored secret, enter a new value to replace'
            : undefined
        }
        onChange={(e) => {
          if (secret)
            onChange({
              ...profile,
              config: {
                ...profile.config,
                api_key: e.target.value,
                api_key_redacted: profile.config.api_key_redacted,
              },
            });
          else config(key, e.target.value);
        }}
      />
      <span className="block text-xs text-muted">{help}</span>
      {secret && profile.config.api_key_redacted ? (
        <button
          type="button"
          disabled={disabled}
          className="text-xs text-danger"
          data-debug-id="profile-api-key-clear"
          onClick={() =>
            onChange({
              ...profile,
              config: { ...profile.config, api_key: '', api_key_redacted: false },
            })
          }
        >
          Clear stored secret
        </button>
      ) : null}
    </label>
  );
  const [args, setArgs] = useState(() => decodeProfileArgs(profile.config.launch_args));
  const changeArgs = (next: string[]) => {
    setArgs(next);
    config('launch_args', encodeProfileArgs(next, false));
  };
  const env = (index: number, patch: Partial<ProfileEnv>) =>
    onChange({
      ...profile,
      environment: profile.environment.map((e, i) => (i === index ? { ...e, ...patch } : e)),
    });
  return (
    <fieldset disabled={disabled} className="space-y-5">
      <section className="space-y-3">
        <h3 className="font-semibold">Runtime</h3>
        {row('binary_path', 'Binary', 'Optional executable name or absolute path on this bridge.')}
        {profile.provider === 'claude'
          ? row(
              'config_dir',
              'Config directory',
              'Sets CLAUDE_CONFIG_DIR for this profile. Leave blank to inherit.',
            )
          : null}
        {profile.provider === 'codex' ? (
          <>
            {row('home_path', 'Codex home', 'Sets CODEX_HOME. Leave blank to inherit.')}
            {row(
              'shadow_home_path',
              'Shadow home',
              'Optional private Codex overlay with its own authentication and state.',
            )}
          </>
        ) : null}
        {profile.provider === 'antigravity' ? (
          <>
            <label className="block text-sm">
              Authentication
              <select
                className={fieldClass}
                data-debug-id="profile-auth-method"
                value={profile.config.auth_method || ''}
                onChange={(e) => config('auth_method', e.target.value)}
              >
                <option value="">Default</option>
                {['oauth-personal', 'oauth-business', 'gemini-api-key', 'agent-platform'].map(
                  (m) => (
                    <option key={m}>{m}</option>
                  ),
                )}
              </select>
            </label>
            {row('api_key', 'API key', 'Stored as a secret on this bridge.', true)}
            {row('gcp_project', 'Google Cloud project', 'Used with agent-platform authentication.')}
            {row(
              'gcp_location',
              'Google Cloud location',
              'Used with agent-platform authentication.',
            )}
          </>
        ) : (
          <section className="space-y-2">
            <h4 className="text-sm font-medium">Launch arguments</h4>
            <p className="text-xs text-muted">
              One literal argument per row. No shell expansion; up to 32 arguments.
            </p>
            {args.map((arg, i) => (
              <div className="flex gap-2" key={i}>
                <input
                  aria-label={'Argument ' + (i + 1)}
                  data-debug-id={'profile-arg-' + i}
                  className={fieldClass}
                  value={arg}
                  onChange={(e) => changeArgs(args.map((a, j) => (j === i ? e.target.value : a)))}
                />
                <button
                  type="button"
                  data-debug-id={'profile-arg-remove-' + i}
                  aria-label={'Remove argument ' + (i + 1)}
                  onClick={() => changeArgs(args.filter((_, j) => j !== i))}
                >
                  Remove
                </button>
              </div>
            ))}
            <button
              type="button"
              data-debug-id="profile-arg-add"
              disabled={args.length >= 32}
              className="text-sm text-accent"
              onClick={() => changeArgs([...args, ''])}
            >
              Add argument
            </button>
          </section>
        )}
      </section>
      <section className="space-y-3">
        <h3 className="font-semibold">Environment</h3>
        {profile.environment.map((entry, i) => (
          <div
            key={i}
            className="space-y-2 rounded-lg border border-subtle p-3"
            data-debug-id={'profile-env-row-' + i}
          >
            <div className="grid gap-2 sm:grid-cols-2">
              <input
                aria-label={'Variable name ' + (i + 1)}
                className={fieldClass}
                data-debug-id={'profile-env-name-' + i}
                value={entry.name}
                disabled={disabled || Boolean(entry.value_redacted)}
                onChange={(e) => env(i, { name: e.target.value })}
              />
              <input
                aria-label={'Variable value ' + (i + 1)}
                type={entry.sensitive ? 'password' : 'text'}
                autoComplete="off"
                className={fieldClass}
                data-debug-id={'profile-env-value-' + i}
                placeholder={
                  entry.value_redacted ? 'Stored secret, enter a new value to replace' : 'Value'
                }
                value={entry.value}
                onChange={(e) => env(i, { value: e.target.value })}
              />
            </div>
            <div className="flex flex-wrap items-center gap-3 text-xs">
              <label className="flex items-center gap-1">
                <input
                  type="checkbox"
                  data-debug-id={'profile-env-sensitive-' + i}
                  checked={entry.sensitive}
                  disabled={disabled || Boolean(entry.value_redacted && !entry.value)}
                  onChange={(e) => env(i, { sensitive: e.target.checked, value_redacted: false })}
                />
                Sensitive
              </label>
              {entry.value_redacted ? (
                <button
                  type="button"
                  className="text-danger"
                  data-debug-id={'profile-env-clear-' + i}
                  onClick={() => env(i, { value: '', value_redacted: false, keep: false })}
                >
                  Clear stored secret
                </button>
              ) : null}
              <button
                type="button"
                className="text-danger"
                data-debug-id={'profile-env-remove-' + i}
                onClick={() =>
                  onChange({
                    ...profile,
                    environment: profile.environment.filter((_, j) => j !== i),
                  })
                }
              >
                Remove variable
              </button>
            </div>
          </div>
        ))}
        <button
          type="button"
          className="text-sm text-accent"
          data-debug-id="profile-env-add"
          onClick={() =>
            onChange({
              ...profile,
              environment: [...profile.environment, { name: '', value: '', sensitive: true }],
            })
          }
        >
          Add variable
        </button>
        <p className="text-xs text-muted">
          Stored on this bridge only; never sent to or kept by the hub. Empty replacement keeps a
          stored secret; use Clear to erase it.
        </p>
      </section>
      {profile.provider !== 'antigravity' ? (
        <section className="space-y-2">
          <h3 className="font-semibold">Models</h3>
          <label className="block text-sm">
            Custom model IDs
            <textarea
              className={fieldClass}
              rows={3}
              data-debug-id="profile-custom-models"
              value={(profile.config.custom_models || []).join('\n')}
              onChange={(e) => config('custom_models', e.target.value.split('\n'))}
            />
            <span className="text-xs text-muted">
              One model ID per line, in addition to discovered models.
            </span>
          </label>
        </section>
      ) : null}
    </fieldset>
  );
}

export default function ProviderProfilesSurface({ bridge }: { bridge: any }) {
  const bridgeId = String(bridge?.bridge_id || bridge?.id || '');
  const unlocked = useSelector(selectIsVaultUnlocked);
  const editable = unlocked && bridge?.status === 'online' && bridge?.vault_status === 'unlocked';
  const dispatch = useDispatch();
  const [profiles, setProfiles] = useState<ProfileMetadata[]>([]);
  const [statuses, setStatuses] = useState<BridgeProviderStatus[]>([]);
  const [labels, setLabels] = useState<Record<string, string>>({});
  const [selected, setSelected] = useState('');
  const [draft, setDraft] = useState<ProviderProfile | null>(null);
  const [label, setLabel] = useState('');
  const [step, setStep] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState('');
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [testTarget, setTestTarget] = useState<ProviderTestTarget | null>(null);
  const [revision, setRevision] = useState(0);
  const refresh = () => {
    setRevision((v) => v + 1);
    dispatch(heimdallApi.util.invalidateTags([{ type: 'BridgeProviders', id: bridgeId }]));
  };
  useEffect(() => {
    let cancelled = false;
    setLoaded(false);
    void Promise.all([providerProfilesApi.list(bridgeId), providerSetupApi.get(bridgeId, true)])
      .then(async ([metadata, status]) => {
        const rows = [...metadata];
        for (const s of status.providers)
          if (!rows.some((p) => p.profile_id === (s.profile_id || s.provider)))
            rows.push({
              profile_id: s.profile_id || s.provider,
              provider: s.provider,
              label_enc: s.label_enc || '',
              accent: s.accent || '',
              enabled: s.enabled,
              state: s.profile_state,
            });
        const names = await Promise.all(
          rows.map(async (p) => [
            p.profile_id,
            await profileLabel(
              p,
              p.profile_id === p.provider
                ? status.providers.find((s) => s.provider === p.provider)?.display_name
                : '',
            ),
          ]),
        );
        if (!cancelled) {
          setProfiles(rows);
          setStatuses(status.providers);
          setLabels(Object.fromEntries(names));
          setLoaded(true);
        }
      })
      .catch((e) => {
        if (!cancelled) {
          setError(apiErrorText(e));
          setLoaded(true);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [bridgeId, revision, unlocked]);
  useEffect(() => {
    if (!editable) {
      setDraft(null);
      setSelected('');
      setStep(null);
      setLabel('');
    }
  }, [editable]);
  async function edit(p: ProfileMetadata) {
    setBusy(true);
    setError('');
    setDraft(null);
    setConfirmDelete(false);
    setSelected(p.profile_id);
    setStep(null);
    try {
      const full = await providerProfilesApi.operate(bridgeId, p.profile_id, 'get');
      if (full) {
        setDraft({
          ...full,
          enabled:
            statuses.find((s) => (s.profile_id || s.provider) === p.profile_id)?.enabled ??
            p.enabled,
        });
        setLabel(labels[p.profile_id] || p.profile_id);
      }
    } catch (e) {
      setError(apiErrorText(e));
    } finally {
      setBusy(false);
    }
  }
  async function save() {
    if (!draft) return;
    setBusy(true);
    setError('');
    try {
      const identityError = profileIdentityError(
        draft.profile_id,
        label,
        draft.accent,
        step !== null ? profiles.map((p) => p.profile_id) : [],
        step !== null ? drivers : [],
      );
      if (
        identityError &&
        !(
          step === null &&
          draft.profile_id === draft.provider &&
          identityError.includes('reserved')
        )
      )
        throw new Error(identityError);
      await providerProfilesApi.operate(bridgeId, draft.profile_id, 'upsert', {
        ...draft,
        profile_id: undefined,
        label_enc: await encryptVaultText(label.trim()),
        environment: environmentForSave(draft.environment),
        config: {
          ...draft.config,
          api_key_redacted: Boolean(draft.config.api_key_redacted && !draft.config.api_key),
          launch_args: encodeProfileArgs(decodeProfileArgs(draft.config.launch_args)),
          custom_models: (draft.config.custom_models || []).map((s) => s.trim()).filter(Boolean),
        },
      });
      const saved = draft;
      setDraft(null);
      setLabel('');
      setSelected('');
      setStep(null);
      refresh();
      // The legacy enable setting can override registry metadata. Existing rows
      // need its enablement updated too; new custom profiles default to enabled.
      if (step === null && currentStatus && currentStatus.enabled !== saved.enabled) {
        try {
          if (saved.enabled)
            await cookieMutation(
              '/bridges/' + encodeURIComponent(bridgeId) + '/providers/discover',
              'POST',
              { stage: 'providers', provider: saved.provider, profile_id: saved.profile_id },
            );
          await cookieMutation(
            '/bridges/' +
              encodeURIComponent(bridgeId) +
              '/providers/' +
              encodeURIComponent(saved.provider),
            'PUT',
            { enabled: saved.enabled, profile_id: saved.profile_id },
          );
        } catch (e) {
          setError('Profile saved, but enablement could not be updated: ' + apiErrorText(e));
        }
      }
      refresh();
      const id = saved.profile_id;
      // Fetch a redacted view after save so replacement secrets leave React state.
      const full = await providerProfilesApi.operate(bridgeId, id, 'get');
      if (full) {
        setDraft(full);
        setLabel(await profileLabel(full));
        setSelected(id);
      }
    } catch (e) {
      setError(apiErrorText(e));
    } finally {
      setBusy(false);
    }
  }
  async function removeOrReset() {
    if (!draft) return;
    setBusy(true);
    setError('');
    try {
      await providerProfilesApi.operate(
        bridgeId,
        draft.profile_id,
        draft.profile_id === draft.provider ? 'reset' : 'remove',
      );
      setDraft(null);
      setLabel('');
      setSelected('');
      setConfirmDelete(false);
      refresh();
    } catch (e: any) {
      setError(
        e?.code === 'profile_in_use'
          ? 'This profile is in use. Change the referenced agents and fleet rows before deleting it. ' +
              JSON.stringify(e.details || {})
          : apiErrorText(e),
      );
    } finally {
      setBusy(false);
    }
  }
  async function discover(stage: string) {
    setBusy(true);
    setError('');
    try {
      await cookieMutation(
        '/bridges/' + encodeURIComponent(bridgeId) + '/providers/discover',
        'POST',
        { stage, ...(draft ? { provider: draft.provider, profile_id: draft.profile_id } : {}) },
      );
      refresh();
    } catch (e) {
      setError(apiErrorText(e));
    } finally {
      setBusy(false);
    }
  }
  const drivers = Array.from(new Set(statuses.map((s) => s.provider))).sort();
  const currentStatus = statuses.find(
    (s) => s.provider === draft?.provider && (s.profile_id || s.provider) === draft?.profile_id,
  );
  return (
    <div data-debug-id="provider-profiles" className="space-y-4">
      <div className="flex items-center justify-between gap-2">
        <div>
          <h2 className="text-lg font-semibold">Provider profiles</h2>
          <p className="text-sm text-muted">
            Separate accounts and runtime settings on this bridge.
          </p>
        </div>
        <Button
          data-debug-id="profile-add"
          disabled={!editable || busy || !drivers.length}
          onClick={() => {
            const p = newProfile(
              drivers[0],
              profiles.map((p) => p.profile_id),
            );
            setDraft(p);
            setLabel('');
            setSelected('');
            setStep(0);
            setError('');
          }}
        >
          Add provider
        </Button>
      </div>
      {!editable ? (
        <p
          className="rounded-lg bg-neutral-soft p-3 text-sm text-muted"
          data-debug-id="profile-locked"
        >
          Connect and unseal this bridge, and unlock this device, to edit profiles.
        </p>
      ) : null}
      {error ? (
        <p role="alert" className="rounded-lg border border-danger/30 p-3 text-sm text-danger">
          {error}
        </p>
      ) : null}
      {!loaded ? <Spinner size="sm" /> : null}
      <div className="grid gap-4 md:grid-cols-[minmax(12rem,1fr)_minmax(0,2fr)]">
        <aside className="space-y-3">
          {drivers.map((driver) => (
            <section key={driver}>
              <h3 className="mb-2 text-xs font-semibold uppercase text-muted">{driver}</h3>
              {profiles
                .filter((p) => p.provider === driver)
                .map((p) => {
                  const s = statuses.find((s) => (s.profile_id || s.provider) === p.profile_id);
                  return (
                    <button
                      key={p.profile_id}
                      type="button"
                      data-debug-id={'profile-select-' + p.profile_id}
                      disabled={!editable || busy}
                      aria-pressed={selected === p.profile_id}
                      onClick={() => void edit(p)}
                      className={
                        'mb-2 block w-full rounded-xl border p-3 text-left ' +
                        (selected === p.profile_id ? 'border-accent bg-accent/10' : 'border-subtle')
                      }
                    >
                      <span className="flex items-center gap-2">
                        <span
                          className="h-2 w-2 rounded-full"
                          style={{ backgroundColor: p.accent || '#888888' }}
                        />
                        <span className="font-medium">{labels[p.profile_id] || p.profile_id}</span>
                      </span>
                      <span className="block text-xs text-muted">
                        {p.enabled && s?.enabled ? 'Enabled' : 'Disabled'} ·{' '}
                        {p.state && p.state !== 'ok' ? p.state : s?.state || 'Not checked'}
                        {s?.version_text ? ' · ' + s.version_text : ''}
                      </span>
                    </button>
                  );
                })}
            </section>
          ))}
          <Button
            variant="secondary"
            size="sm"
            data-debug-id="profiles-refresh"
            disabled={!editable || busy}
            onClick={() => void discover('providers')}
          >
            Scan providers
          </Button>
        </aside>
        <main>
          {draft ? (
            <div
              className="space-y-5 rounded-xl border border-subtle p-4"
              data-debug-id="profile-editor"
            >
              {step !== null ? (
                <div className="text-sm font-medium" data-debug-id="profile-wizard-step">
                  {['Provider', 'Identity', 'Config']
                    .map((s, i) => (i === step ? '● ' : '') + s)
                    .join(' → ')}
                </div>
              ) : (
                <h3 className="font-semibold">{labels[draft.profile_id] || draft.profile_id}</h3>
              )}
              {step === 0 ? (
                <label className="block text-sm">
                  Provider
                  <select
                    className={fieldClass}
                    data-debug-id="profile-driver"
                    value={draft.provider}
                    onChange={(e) => {
                      setDraft(
                        newProfile(
                          e.target.value,
                          profiles.map((p) => p.profile_id),
                        ),
                      );
                      setLabel('');
                    }}
                  >
                    {drivers.map((d) => (
                      <option key={d}>{d}</option>
                    ))}
                  </select>
                </label>
              ) : null}
              {step === 1 || step === null ? (
                <div className="space-y-3">
                  <label className="block text-sm">
                    Label
                    <input
                      className={fieldClass}
                      data-debug-id="profile-label"
                      value={label}
                      maxLength={256}
                      disabled={busy}
                      onChange={(e) => setLabel(e.target.value)}
                    />
                  </label>
                  <label className="block text-sm">
                    Profile ID
                    <input
                      className={fieldClass}
                      data-debug-id="profile-id"
                      value={draft.profile_id}
                      disabled={step === null || busy}
                      onChange={(e) => setDraft({ ...draft, profile_id: e.target.value })}
                    />
                    <span className="text-xs text-muted">
                      The profile ID is visible to the hub; the label is encrypted.
                    </span>
                  </label>
                  <label className="block text-sm">
                    Accent
                    <input
                      type="color"
                      data-debug-id="profile-accent"
                      disabled={busy}
                      value={draft.accent || '#7c6af7'}
                      onChange={(e) => setDraft({ ...draft, accent: e.target.value })}
                    />
                  </label>
                  <label className="flex items-center gap-2 text-sm">
                    <input
                      type="checkbox"
                      data-debug-id="profile-enabled"
                      disabled={busy}
                      checked={draft.enabled}
                      onChange={(e) => setDraft({ ...draft, enabled: e.target.checked })}
                    />
                    Enabled for new launches
                  </label>
                </div>
              ) : null}
              {step === 2 || step === null ? (
                <>
                  <ProfileRuntimeEditor
                    key={draft.profile_id}
                    profile={draft}
                    onChange={setDraft}
                    disabled={busy}
                  />
                  {step === null ? (
                    <section className="space-y-2">
                      <h3 className="font-semibold">Status / Setup</h3>
                      <p className="text-sm text-muted">
                        {currentStatus?.state || 'Not checked'} ·{' '}
                        {currentStatus?.version_text || 'No version reported'}
                      </p>
                      <p className="text-xs text-muted">
                        Sign in with the provider CLI using this profile’s runtime directory. Then
                        scan again.
                      </p>
                      <div className="flex gap-2">
                        <Button
                          size="sm"
                          variant="secondary"
                          data-debug-id="profile-discover"
                          disabled={busy || !draft.enabled}
                          onClick={() => void discover('providers')}
                        >
                          Check provider
                        </Button>
                        <Button
                          size="sm"
                          variant="secondary"
                          data-debug-id="profile-model-refresh"
                          disabled={busy || !draft.enabled}
                          onClick={() => void discover('models')}
                        >
                          Refresh models
                        </Button>
                      </div>
                      {currentStatus?.models.map((m) => (
                        <button
                          key={m.model_id}
                          type="button"
                          data-debug-id={'profile-model-test-' + m.model_id}
                          className="mr-2 text-xs text-accent"
                          disabled={
                            busy || !currentStatus.enabled || currentStatus.state !== 'present'
                          }
                          onClick={() =>
                            setTestTarget({
                              provider: draft.provider,
                              profileId: draft.profile_id,
                              providerLabel: label,
                              modelId: m.model_id,
                              modelLabel: m.label,
                              binaryPath: '',
                            })
                          }
                        >
                          {m.label} · Test
                        </button>
                      ))}
                      <ProviderExtensionInstallAction
                        bridgeId={bridgeId}
                        provider={draft.provider}
                        profileId={draft.profile_id}
                        extension={currentStatus?.extension || null}
                        online={editable}
                        disabled={busy}
                        onComplete={refresh}
                        onRetryDiscovery={() => discover('providers')}
                      />
                    </section>
                  ) : null}
                </>
              ) : null}
              <div className="flex flex-wrap items-center gap-2 border-t border-subtle pt-3">
                {step !== null && step > 0 ? (
                  <Button
                    variant="secondary"
                    data-debug-id="profile-back"
                    disabled={busy}
                    onClick={() => setStep(step - 1)}
                  >
                    Back
                  </Button>
                ) : null}
                {step !== null && step < 2 ? (
                  <Button
                    data-debug-id="profile-next"
                    disabled={busy}
                    onClick={() => {
                      const err =
                        step === 1
                          ? profileIdentityError(
                              draft.profile_id,
                              label,
                              draft.accent,
                              profiles.map((p) => p.profile_id),
                              drivers,
                            )
                          : '';
                      setError(err);
                      if (!err) setStep(step + 1);
                    }}
                  >
                    Next
                  </Button>
                ) : (
                  <Button
                    data-debug-id="profile-save"
                    disabled={busy || !editable}
                    onClick={() => void save()}
                  >
                    {busy ? 'Saving…' : 'Save profile'}
                  </Button>
                )}
                <Button
                  variant="secondary"
                  data-debug-id="profile-cancel"
                  disabled={busy}
                  onClick={() => {
                    setDraft(null);
                    setLabel('');
                    setStep(null);
                    setSelected('');
                    setConfirmDelete(false);
                  }}
                >
                  Cancel
                </Button>
                {step === null ? (
                  <Button
                    variant="secondary"
                    data-debug-id="profile-delete-reset"
                    disabled={busy}
                    onClick={() => setConfirmDelete(true)}
                  >
                    {draft.profile_id === draft.provider ? 'Reset overrides' : 'Delete profile'}
                  </Button>
                ) : null}
              </div>
              {confirmDelete ? (
                <div className="space-y-2 text-sm">
                  <p>
                    {draft.profile_id === draft.provider
                      ? 'Clear runtime, environment and label overrides? Enablement is kept.'
                      : 'Delete this profile and its stored secrets? Runtime directories are kept.'}
                  </p>
                  <Button
                    variant="danger"
                    data-debug-id="profile-delete-confirm"
                    disabled={busy}
                    onClick={() => void removeOrReset()}
                  >
                    Confirm
                  </Button>
                  <Button
                    variant="secondary"
                    data-debug-id="profile-delete-cancel"
                    disabled={busy}
                    onClick={() => setConfirmDelete(false)}
                  >
                    Keep profile
                  </Button>
                </div>
              ) : null}
            </div>
          ) : (
            <p className="p-4 text-sm text-muted">
              {busy ? 'Loading profile…' : 'Choose a profile to edit its runtime and environment.'}
            </p>
          )}
        </main>
      </div>
      {testTarget ? (
        <ProviderTestRunModal
          target={testTarget}
          setup={{ bridge: { bridge_id: bridgeId }, providers: statuses } as any}
          onClose={() => setTestTarget(null)}
        />
      ) : null}
    </div>
  );
}
