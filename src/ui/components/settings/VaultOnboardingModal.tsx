import React, { useState, useEffect, useCallback, type FormEvent } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import {
  Modal,
  Button,
  Input,
  Textarea,
  Checkbox,
  Badge,
  Icon,
  Text,
} from '@ui';
import {
  selectIsVaultConfigured,
  selectIsVaultUnlocked,
  setVaultConfigured,
  setVaultUnlocked,
  importLocalKey,
  readOnboardingDismissed,
  writeOnboardingDismissed,
} from '../../store/vaultSlice';
import {
  useGetUserVaultQuery,
  useSetUserVaultMutation,
} from '../../api/endpoints/userVault';
import {
  generateVaultKey,
  exportRawKeyHex,
  importRawKeyHex,
  deriveKeyFromPassword,
  generate12RecoveryWords,
  validateRecoveryWords,
  deriveKeyFromRecoveryWords,
  encryptVaultKeyEnvelope,
  decryptVaultKeyEnvelope,
  generateSaltHex,
  DEFAULT_KDF_ITERATIONS,
} from '../../utils/vaultCrypto';

export interface VaultOnboardingModalProps {
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  onDismiss?: () => void;
}

async function copyTextToClipboard(text: string): Promise<boolean> {
  try {
    if (navigator?.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {}
  try {
    const el = document.createElement('textarea');
    el.value = text;
    el.style.position = 'fixed';
    el.style.opacity = '0';
    document.body.appendChild(el);
    el.focus();
    el.select();
    const ok = document.execCommand('copy');
    document.body.removeChild(el);
    return ok;
  } catch {
    return false;
  }
}

function extractVaultRecord(record: any) {
  if (!record) return null;
  return {
    encryptedVaultKey: record.encrypted_vault_key || record.encryptedVaultKey || '',
    vaultKeyNonce: record.vault_key_nonce || record.vaultKeyNonce || '',
    vaultKeyTag: record.vault_key_tag || record.vaultKeyTag || '',
    kdfSalt: record.kdf_salt || record.kdfSalt || '',
    kdfIterations: Number(record.kdf_iterations || record.kdfIterations || DEFAULT_KDF_ITERATIONS),
    recoveryEncryptedVaultKey: record.recovery_encrypted_vault_key || record.recoveryEncryptedVaultKey || '',
    recoveryNonce: record.recovery_nonce || record.recoveryNonce || '',
    recoveryTag: record.recovery_tag || record.recoveryTag || '',
    recoverySalt: record.recovery_salt || record.recoverySalt || '',
  };
}

export default function VaultOnboardingModal({
  open: controlledOpen,
  onOpenChange,
  onDismiss,
}: VaultOnboardingModalProps) {
  const dispatch = useDispatch();
  const isVaultConfiguredInRedux = useSelector(selectIsVaultConfigured);
  const isUnlocked = useSelector(selectIsVaultUnlocked);

  const { data: vaultData, refetch: refetchVault } = useGetUserVaultQuery();
  const [setUserVault, { isLoading: isSavingVault }] = useSetUserVaultMutation();

  const isConfigured = Boolean(vaultData?.isConfigured || isVaultConfiguredInRedux);

  // Sync Redux configured state with server query
  useEffect(() => {
    if (vaultData?.isConfigured !== undefined) {
      dispatch(setVaultConfigured(vaultData.isConfigured));
    }
  }, [vaultData?.isConfigured, dispatch]);

  // Internal open state for uncontrolled usage
  const [internalOpen, setInternalOpen] = useState(false);

  useEffect(() => {
    if (controlledOpen === undefined) {
      const dismissed = readOnboardingDismissed();
      if (!isUnlocked && !dismissed) {
        setInternalOpen(true);
      } else {
        setInternalOpen(false);
      }
    }
  }, [controlledOpen, isUnlocked]);

  const isOpen = controlledOpen !== undefined ? controlledOpen : internalOpen;

  // Active Tab: setup | unlock | import
  const [activeTab, setActiveTab] = useState<'setup' | 'unlock' | 'import'>(() => {
    return isConfigured ? 'unlock' : 'setup';
  });

  useEffect(() => {
    if (isConfigured && activeTab === 'setup') {
      setActiveTab('unlock');
    }
  }, [isConfigured]);

  // Session persistence preference (checkbox)
  const [rememberSession, setRememberSession] = useState(true);

  // Error message
  const [errorMessage, setErrorMessage] = useState('');

  // Setup Wizard State
  const [masterPassword, setMasterPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [recoveryWords, setRecoveryWords] = useState<string[]>([]);
  const [confirmedBackup, setConfirmedBackup] = useState(false);
  const [isSubmittingSetup, setIsSubmittingSetup] = useState(false);
  const [copiedWords, setCopiedWords] = useState(false);

  // Unlock State
  const [unlockMode, setUnlockMode] = useState<'password' | 'recovery'>('password');
  const [unlockPassword, setUnlockPassword] = useState('');
  const [recoveryPhraseInput, setRecoveryPhraseInput] = useState('');
  const [isUnlocking, setIsUnlocking] = useState(false);

  // Direct Hex Key Import State
  const [directHexKey, setDirectHexKey] = useState('');
  const [isImporting, setIsImporting] = useState(false);

  // Initialize recovery words
  useEffect(() => {
    if (recoveryWords.length === 0) {
      const generated = generate12RecoveryWords();
      setRecoveryWords(generated.words);
    }
  }, [recoveryWords.length]);

  const handleRegenerateWords = useCallback(() => {
    const generated = generate12RecoveryWords();
    setRecoveryWords(generated.words);
    setConfirmedBackup(false);
  }, []);

  const handleCopyWords = useCallback(async () => {
    if (recoveryWords.length === 0) return;
    const ok = await copyTextToClipboard(recoveryWords.join(' '));
    if (ok) {
      setCopiedWords(true);
      setTimeout(() => setCopiedWords(false), 2000);
    }
  }, [recoveryWords]);

  const handleClose = useCallback(() => {
    if (onOpenChange) {
      onOpenChange(false);
    } else {
      setInternalOpen(false);
    }
    onDismiss?.();
  }, [onOpenChange, onDismiss]);

  const handleSkip = useCallback(() => {
    writeOnboardingDismissed(true);
    handleClose();
  }, [handleClose]);

  // Close when vault is successfully unlocked
  useEffect(() => {
    if (isUnlocked && isOpen) {
      handleClose();
    }
  }, [isUnlocked, isOpen, handleClose]);

  // Setup Wizard Submit Handler
  async function handleSetupSubmit(e: FormEvent) {
    e.preventDefault();
    setErrorMessage('');

    if (!masterPassword) {
      setErrorMessage('Master Password is required.');
      return;
    }
    if (masterPassword.length < 8) {
      setErrorMessage('Master Password must be at least 8 characters long.');
      return;
    }
    if (masterPassword !== confirmPassword) {
      setErrorMessage('Passwords do not match. Please re-enter.');
      return;
    }
    if (!confirmedBackup) {
      setErrorMessage('Please confirm that you have securely saved your 12 recovery words.');
      return;
    }
    if (recoveryWords.length !== 12) {
      setErrorMessage('Invalid recovery words. Please regenerate the phrase.');
      return;
    }

    try {
      setIsSubmittingSetup(true);

      // 1. Generate 256-bit symmetric AES-GCM Vault Key (KV)
      const vaultKey = await generateVaultKey();
      const rawHex = await exportRawKeyHex(vaultKey);

      // 2. Derive Master Wrapping Key (KM) from Master Password
      const kdfSalt = generateSaltHex(16);
      const wrappingKey = await deriveKeyFromPassword(masterPassword, kdfSalt, DEFAULT_KDF_ITERATIONS);
      const envelope = await encryptVaultKeyEnvelope(wrappingKey, vaultKey);

      // 3. Derive Recovery Wrapping Key (KR) from 12 recovery words
      const recoverySalt = generateSaltHex(16);
      const recoveryWrappingKey = await deriveKeyFromRecoveryWords(recoveryWords, recoverySalt, DEFAULT_KDF_ITERATIONS);
      const recoveryEnvelope = await encryptVaultKeyEnvelope(recoveryWrappingKey, vaultKey);

      // 4. Persist encrypted envelopes to Hub SQLite backend
      await setUserVault({
        encrypted_vault_key: envelope.ciphertextHex,
        vault_key_nonce: envelope.nonceHex,
        vault_key_tag: envelope.tagHex,
        kdf_algorithm: 'PBKDF2-SHA256',
        kdf_salt: kdfSalt,
        kdf_iterations: DEFAULT_KDF_ITERATIONS,
        recovery_encrypted_vault_key: recoveryEnvelope.ciphertextHex,
        recovery_nonce: recoveryEnvelope.nonceHex,
        recovery_tag: recoveryEnvelope.tagHex,
        recovery_salt: recoverySalt,
      }).unwrap();

      // 5. Update Redux store
      dispatch(setVaultConfigured(true));
      dispatch(setVaultUnlocked({ rawVaultKeyHex: rawHex, rememberSession }));

      // Reset sensitive password inputs
      setMasterPassword('');
      setConfirmPassword('');
      void refetchVault();
      handleClose();
    } catch (err: any) {
      setErrorMessage(String(err?.message || err?.error || err || 'Failed to initialize vault'));
    } finally {
      setIsSubmittingSetup(false);
    }
  }

  // Unlock with Master Password
  async function handleUnlockWithPassword(e?: FormEvent) {
    if (e) e.preventDefault();
    setErrorMessage('');

    if (!unlockPassword) {
      setErrorMessage('Please enter your Master Password.');
      return;
    }

    const record = extractVaultRecord(vaultData?.vault);
    if (!record || !record.encryptedVaultKey) {
      setErrorMessage('No encrypted vault envelope found on server.');
      return;
    }

    try {
      setIsUnlocking(true);
      const wrappingKey = await deriveKeyFromPassword(unlockPassword, record.kdfSalt, record.kdfIterations);
      const vaultKey = await decryptVaultKeyEnvelope(
        wrappingKey,
        record.encryptedVaultKey,
        record.vaultKeyNonce,
        record.vaultKeyTag,
      );
      const rawHex = await exportRawKeyHex(vaultKey);
      dispatch(setVaultUnlocked({ rawVaultKeyHex: rawHex, rememberSession }));
      setUnlockPassword('');
      handleClose();
    } catch (_err) {
      setErrorMessage('Incorrect Master Password. Decryption failed.');
    } finally {
      setIsUnlocking(false);
    }
  }

  // Unlock with 12 Recovery Words
  async function handleUnlockWithRecovery(e?: FormEvent) {
    if (e) e.preventDefault();
    setErrorMessage('');

    const words = recoveryPhraseInput.trim().toLowerCase().split(/\s+/).filter(Boolean);
    if (words.length !== 12) {
      setErrorMessage(`Expected 12 recovery words, but found ${words.length}.`);
      return;
    }

    if (!validateRecoveryWords(words)) {
      setErrorMessage('Invalid recovery words or checksum. Please verify all 12 words.');
      return;
    }

    const record = extractVaultRecord(vaultData?.vault);
    if (!record || !record.recoveryEncryptedVaultKey) {
      setErrorMessage('No recovery envelope found on server.');
      return;
    }

    try {
      setIsUnlocking(true);
      const recoveryWrappingKey = await deriveKeyFromRecoveryWords(words, record.recoverySalt, record.kdfIterations);
      const vaultKey = await decryptVaultKeyEnvelope(
        recoveryWrappingKey,
        record.recoveryEncryptedVaultKey,
        record.recoveryNonce,
        record.recoveryTag,
      );
      const rawHex = await exportRawKeyHex(vaultKey);
      dispatch(setVaultUnlocked({ rawVaultKeyHex: rawHex, rememberSession }));
      setRecoveryPhraseInput('');
      handleClose();
    } catch (_err) {
      setErrorMessage('Failed to unlock vault with recovery words. Verification failed.');
    } finally {
      setIsUnlocking(false);
    }
  }

  // Direct 64-Hex Key Import Handler
  async function handleDirectKeyImport(e: FormEvent) {
    e.preventDefault();
    setErrorMessage('');

    const clean = directHexKey.trim().toLowerCase();
    if (!clean) {
      setErrorMessage('Please enter a 64-character hexadecimal Vault Key.');
      return;
    }

    if (!/^[0-9a-f]{64}$/.test(clean)) {
      setErrorMessage(
        `Invalid vault key format: expected 64 hexadecimal characters (256-bit), got ${clean.length} characters.`,
      );
      return;
    }

    try {
      setIsImporting(true);
      // Validate by importing via WebCrypto AES-GCM
      await importRawKeyHex(clean);

      // Dispatch Redux importLocalKey action
      dispatch(importLocalKey(clean, rememberSession));
      setDirectHexKey('');
      handleClose();
    } catch (err: any) {
      setErrorMessage(String(err?.message || err || 'Failed to import vault key'));
    } finally {
      setIsImporting(false);
    }
  }

  if (!isOpen) {
    return null;
  }

  return (
    <Modal
      open={isOpen}
      onOpenChange={(next) => {
        if (!next) handleClose();
      }}
      title="Zero-Knowledge User Vault"
      size="lg"
      data-debug-id="vault-onboarding-modal"
    >
      <Modal.Body className="space-y-4">
        {/* Navigation Tabs */}
        <div className="flex flex-wrap items-center justify-between gap-2 border-b border-subtle pb-3">
          <div className="inline-flex rounded-xl bg-surface-raised p-1 gap-1">
            <button
              type="button"
              data-debug-id="vault-onboarding-tab-setup"
              className={`rounded-lg px-3 py-1.5 text-xs font-semibold transition-colors ${
                activeTab === 'setup'
                  ? 'bg-accent text-accent-fg shadow-sm'
                  : 'text-muted hover:text-primary'
              }`}
              onClick={() => {
                setActiveTab('setup');
                setErrorMessage('');
              }}
            >
              Setup New Vault
            </button>
            <button
              type="button"
              data-debug-id="vault-onboarding-tab-unlock"
              className={`rounded-lg px-3 py-1.5 text-xs font-semibold transition-colors ${
                activeTab === 'unlock'
                  ? 'bg-accent text-accent-fg shadow-sm'
                  : 'text-muted hover:text-primary'
              }`}
              onClick={() => {
                setActiveTab('unlock');
                setErrorMessage('');
              }}
            >
              Unlock Vault
            </button>
            <button
              type="button"
              data-debug-id="vault-onboarding-tab-import"
              className={`rounded-lg px-3 py-1.5 text-xs font-semibold transition-colors ${
                activeTab === 'import'
                  ? 'bg-accent text-accent-fg shadow-sm'
                  : 'text-muted hover:text-primary'
              }`}
              onClick={() => {
                setActiveTab('import');
                setErrorMessage('');
              }}
            >
              Direct Key Import
            </button>
          </div>

          <Badge tone={isConfigured ? 'neutral' : 'warning'}>
            {isConfigured ? 'Vault Configured' : 'Unconfigured'}
          </Badge>
        </div>

        {/* Tab 1: Setup New Vault */}
        {activeTab === 'setup' && (
          <form
            data-debug-id="vault-onboarding-setup-form"
            onSubmit={handleSetupSubmit}
            className="space-y-4"
          >
            <div>
              <p className="text-xs text-muted">
                Create a new client vault encrypted with a Master Password and a 12-word recovery phrase.
              </p>
            </div>

            {/* Master Password Section */}
            <div className="space-y-3">
              <Text as="div" role="overline" tone="muted">1. Master Password</Text>
              <div className="grid gap-3 sm:grid-cols-2">
                <label className="text-xs font-medium text-primary">
                  Master Password
                  <Input
                    type="password"
                    data-debug-id="vault-onboarding-master-password-input"
                    value={masterPassword}
                    onChange={setMasterPassword}
                    placeholder="Min 8 characters"
                    width="full"
                    className="mt-1 min-h-[40px]"
                    disabled={isSubmittingSetup}
                    required
                  />
                </label>
                <label className="text-xs font-medium text-primary">
                  Confirm Password
                  <Input
                    type="password"
                    data-debug-id="vault-onboarding-confirm-password-input"
                    value={confirmPassword}
                    onChange={setConfirmPassword}
                    placeholder="Repeat password"
                    width="full"
                    className="mt-1 min-h-[40px]"
                    disabled={isSubmittingSetup}
                    required
                  />
                </label>
              </div>
            </div>

            {/* 12 Recovery Words Section */}
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <Text as="div" role="overline" tone="muted">2. 12-Word Recovery Phrase</Text>
                <div className="flex items-center gap-2">
                  <Button
                    type="button"
                    size="sm"
                    variant="ghost"
                    data-debug-id="vault-onboarding-regenerate-words-btn"
                    onClick={handleRegenerateWords}
                    disabled={isSubmittingSetup}
                  >
                    <Icon name="refresh" size="sm" />
                    Regenerate
                  </Button>
                  <Button
                    type="button"
                    size="sm"
                    variant="secondary"
                    data-debug-id="vault-onboarding-copy-words-btn"
                    onClick={handleCopyWords}
                    disabled={isSubmittingSetup}
                  >
                    <Icon name="copy" size="sm" />
                    {copiedWords ? 'Copied!' : 'Copy Words'}
                  </Button>
                </div>
              </div>

              <div
                data-debug-id="vault-onboarding-recovery-words-grid"
                className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-2 pt-1"
              >
                {recoveryWords.map((word, idx) => (
                  <div
                    key={idx}
                    data-debug-id={`vault-onboarding-recovery-word-${idx + 1}`}
                    className="flex items-center gap-1.5 rounded-lg border border-subtle bg-surface px-2.5 py-1.5 text-xs font-mono"
                  >
                    <span className="text-[10px] text-muted select-none w-4 text-right">{idx + 1}.</span>
                    <span className="font-semibold text-primary">{word}</span>
                  </div>
                ))}
              </div>
            </div>

            {/* Checkbox confirmation */}
            <div className="rounded-xl border border-subtle bg-surface/50 p-3">
              <Checkbox
                data-debug-id="vault-onboarding-setup-backup-checkbox"
                checked={confirmedBackup}
                onChange={setConfirmedBackup}
                label="I have securely saved these 12 recovery words in a safe offline location."
                disabled={isSubmittingSetup}
              />
            </div>

            {/* Remember Session Checkbox */}
            <div className="pt-1">
              <Checkbox
                data-debug-id="vault-onboarding-remember-checkbox"
                checked={rememberSession}
                onChange={setRememberSession}
                label="Remember in this browser session (keeps vault unlocked across page refreshes)"
                disabled={isSubmittingSetup}
              />
            </div>

            <div className="flex justify-end pt-2">
              <Button
                type="submit"
                variant="primary"
                data-debug-id="vault-onboarding-setup-submit-btn"
                disabled={isSubmittingSetup || isSavingVault || !masterPassword || !confirmPassword || !confirmedBackup}
              >
                <Icon name="lock" size="sm" />
                {isSubmittingSetup ? 'Initializing Vault…' : 'Initialize & Unlock Vault'}
              </Button>
            </div>
          </form>
        )}

        {/* Tab 2: Unlock Vault */}
        {activeTab === 'unlock' && (
          <div data-debug-id="vault-onboarding-unlock-form" className="space-y-4">
            <div className="flex border-b border-subtle pb-2">
              <div className="inline-flex rounded-xl bg-surface-raised p-1 gap-1">
                <button
                  type="button"
                  data-debug-id="vault-onboarding-unlock-mode-password-btn"
                  className={`rounded-lg px-2.5 py-1 text-xs font-semibold transition-colors ${
                    unlockMode === 'password'
                      ? 'bg-accent text-accent-fg shadow-sm'
                      : 'text-muted hover:text-primary'
                  }`}
                  onClick={() => {
                    setUnlockMode('password');
                    setErrorMessage('');
                  }}
                >
                  Master Password
                </button>
                <button
                  type="button"
                  data-debug-id="vault-onboarding-unlock-mode-recovery-btn"
                  className={`rounded-lg px-2.5 py-1 text-xs font-semibold transition-colors ${
                    unlockMode === 'recovery'
                      ? 'bg-accent text-accent-fg shadow-sm'
                      : 'text-muted hover:text-primary'
                  }`}
                  onClick={() => {
                    setUnlockMode('recovery');
                    setErrorMessage('');
                  }}
                >
                  12 Recovery Words
                </button>
              </div>
            </div>

            {unlockMode === 'password' ? (
              <form onSubmit={handleUnlockWithPassword} className="space-y-4">
                <label className="block text-xs font-medium text-primary">
                  Master Password
                  <Input
                    type="password"
                    data-debug-id="vault-onboarding-unlock-password-input"
                    value={unlockPassword}
                    onChange={setUnlockPassword}
                    placeholder="Enter your Master Password"
                    width="full"
                    className="mt-1 min-h-[40px]"
                    disabled={isUnlocking}
                    autoFocus
                  />
                </label>
                <Checkbox
                  data-debug-id="vault-onboarding-remember-checkbox"
                  checked={rememberSession}
                  onChange={setRememberSession}
                  label="Remember in this browser session (keeps vault unlocked across page refreshes)"
                  disabled={isUnlocking}
                />
                <div className="flex justify-end pt-2">
                  <Button
                    type="submit"
                    variant="primary"
                    data-debug-id="vault-onboarding-unlock-submit-btn"
                    disabled={isUnlocking || !unlockPassword}
                  >
                    <Icon name="lock" size="sm" />
                    {isUnlocking ? 'Decrypting…' : 'Unlock Vault'}
                  </Button>
                </div>
              </form>
            ) : (
              <form onSubmit={handleUnlockWithRecovery} className="space-y-4">
                <label className="block text-xs font-medium text-primary">
                  12-Word Recovery Phrase
                  <Textarea
                    data-debug-id="vault-onboarding-unlock-recovery-input"
                    value={recoveryPhraseInput}
                    onChange={setRecoveryPhraseInput}
                    placeholder="Enter your 12 recovery words separated by spaces…"
                    width="full"
                    rows={3}
                    className="mt-1 font-mono text-xs"
                    disabled={isUnlocking}
                    autoFocus
                  />
                </label>
                <Checkbox
                  data-debug-id="vault-onboarding-remember-checkbox"
                  checked={rememberSession}
                  onChange={setRememberSession}
                  label="Remember in this browser session (keeps vault unlocked across page refreshes)"
                  disabled={isUnlocking}
                />
                <div className="flex justify-end pt-2">
                  <Button
                    type="submit"
                    variant="primary"
                    data-debug-id="vault-onboarding-unlock-submit-btn"
                    disabled={isUnlocking || !recoveryPhraseInput.trim()}
                  >
                    <Icon name="lock" size="sm" />
                    {isUnlocking ? 'Recovering…' : 'Recover & Unlock'}
                  </Button>
                </div>
              </form>
            )}
          </div>
        )}

        {/* Tab 3: Direct Key Import */}
        {activeTab === 'import' && (
          <form
            data-debug-id="vault-onboarding-import-form"
            onSubmit={handleDirectKeyImport}
            className="space-y-4"
          >
            <div>
              <h4 className="text-sm font-semibold text-primary">Direct 64-Hex Key Import</h4>
              <p className="mt-1 text-xs text-muted">
                Paste a 64-character hexadecimal Vault Key directly (matching{' '}
                <code className="rounded bg-neutral-soft px-1 font-mono text-accent">ham-ctl vault show --reveal</code> or
                a bridge host key). This unlocks your vault immediately in browser memory.
              </p>
            </div>

            <label className="block text-xs font-medium text-primary">
              Hexadecimal Vault Key (64 chars)
              <Textarea
                data-debug-id="vault-onboarding-hex-key-input"
                value={directHexKey}
                onChange={setDirectHexKey}
                placeholder="e.g. 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                width="full"
                rows={3}
                className="mt-1 font-mono text-xs select-all"
                disabled={isImporting}
                autoFocus
              />
            </label>

            <Checkbox
              data-debug-id="vault-onboarding-remember-checkbox"
              checked={rememberSession}
              onChange={setRememberSession}
              label="Remember in this browser session (persists key in sessionStorage across reloads)"
              disabled={isImporting}
            />

            <div className="flex justify-end pt-2">
              <Button
                type="submit"
                variant="primary"
                data-debug-id="vault-onboarding-import-btn"
                disabled={isImporting || !directHexKey.trim()}
              >
                <Icon name="lock" size="sm" />
                {isImporting ? 'Importing…' : 'Import & Unlock Vault'}
              </Button>
            </div>
          </form>
        )}

        {/* Error message banner */}
        {errorMessage ? (
          <div
            data-debug-id="vault-onboarding-error"
            className="rounded-xl border border-danger/30 bg-danger-soft px-4 py-2.5 text-xs text-danger"
          >
            {errorMessage}
          </div>
        ) : null}
      </Modal.Body>

      <Modal.Footer className="flex items-center justify-between">
        <Button
          type="button"
          variant="ghost"
          data-debug-id="vault-onboarding-skip-btn"
          onClick={handleSkip}
        >
          Skip for now
        </Button>
        <span className="text-[11px] text-muted">
          You can configure or unlock your vault anytime from the header badge.
        </span>
      </Modal.Footer>
    </Modal>
  );
}
