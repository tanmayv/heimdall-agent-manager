import React, { useState, useCallback, type FormEvent } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import {
  Button,
  Input,
  StatusPill,
  Icon,
  Modal,
  ModalBody,
  ModalFooter,
} from '@ui';
import {
  type Bridge,
  useListBridgesQuery,
} from '../../api/endpoints/bridgeSupport';
import {
  useGetUserVaultQuery,
} from '../../api/endpoints/userVault';
import {
  selectIsVaultConfigured,
  selectIsVaultUnlocked,
  setVaultUnlocked,
  lockVault,
  resolveVaultStatus,
  type VaultStatus,
  getActiveVaultKey,
} from '../../store/vaultSlice';
import {
  fetchBridgePublicKey,
  unsealBridgeE2EE,
  lockBridge,
  unsealAllConnectedBridges,
  lockAllConnectedBridges,
} from '../../api/endpoints/bridges';
import {
  deriveKeyFromPassword,
  decryptVaultKeyEnvelope,
  DEFAULT_KDF_ITERATIONS,
} from '../../utils/vaultCrypto';
import VaultOnboardingModal from './VaultOnboardingModal';

export interface BridgeSettingsPanelProps {
  bridges?: Bridge[];
  selectedBridgeId?: string;
  onOpenVaultSetup?: () => void;
}

export default function BridgeSettingsPanel({
  bridges: propBridges,
  selectedBridgeId,
  onOpenVaultSetup,
}: BridgeSettingsPanelProps) {
  const dispatch = useDispatch();
  const queryBridgesResult = useListBridgesQuery(undefined, { skip: Boolean(propBridges && propBridges.length > 0) });
  const bridges: Bridge[] = (propBridges && propBridges.length > 0) ? propBridges : (queryBridgesResult.data?.bridges || []);

  const isConfigured = useSelector(selectIsVaultConfigured);
  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const userVaultQuery = useGetUserVaultQuery();
  const vaultEnvelope = userVaultQuery.data?.vault;

  // Tri-state vault status: 'Disabled' | 'Locked' | 'Unlocked'
  const vaultStatus: VaultStatus = resolveVaultStatus({
    isConfigured: Boolean(isConfigured || vaultEnvelope?.encrypted_vault_key),
    isUnlocked,
  });

  const [unlockModalOpen, setUnlockModalOpen] = useState(false);
  const [onboardingOpen, setOnboardingOpen] = useState(false);
  const [masterPassword, setMasterPassword] = useState('');
  const [rememberSession, setRememberSession] = useState(true);
  const [unlockBusy, setUnlockBusy] = useState(false);
  const [unlockError, setUnlockError] = useState('');
  const [lockBusy, setLockBusy] = useState(false);
  const [unsealSuccessMsg, setUnsealSuccessMsg] = useState('');

  // Target bridges to unseal/lock (either selectedBridgeId or all online bridges)
  const targetBridges = bridges.filter((b: Bridge) => {
    const id = String(b?.bridge_id || b?.bridgeId || b?.id || '');
    if (!id) return false;
    if (selectedBridgeId) return id === selectedBridgeId;
    const status = String(b?.status || b?.runtime_status || '').toLowerCase();
    return status !== 'revoked';
  });

  const handleUnlockClick = useCallback(async () => {
    setUnlockError('');
    setUnsealSuccessMsg('');

    // If key is already in memory/unlocked in UI, directly unseal connected bridges
    const activeKey = getActiveVaultKey();
    if (isUnlocked && activeKey) {
      setUnlockBusy(true);
      try {
        let unsealedCount = 0;
        const candidates = targetBridges.length > 0 ? targetBridges : bridges;
        for (const bridge of candidates) {
          const bridgeId = String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
          if (!bridgeId) continue;
          try {
            const pubKey = await fetchBridgePublicKey(bridgeId);
            if (pubKey) {
              await unsealBridgeE2EE(bridgeId, pubKey, activeKey);
              unsealedCount++;
            }
          } catch (bridgeErr) {
            console.warn(`[BridgeSettingsPanel] failed unsealing bridge ${bridgeId}:`, bridgeErr);
          }
        }
        if (unsealedCount === 0 && candidates.length === 0) {
          unsealedCount = await unsealAllConnectedBridges(activeKey);
        }
        setUnsealSuccessMsg(
          unsealedCount > 0
            ? `Successfully unsealed ${unsealedCount} bridge${unsealedCount === 1 ? '' : 's'}.`
            : 'Bridge unseal payload dispatched.'
        );
      } catch (err: any) {
        setUnlockError(err?.message || 'Failed to unseal bridge');
      } finally {
        setUnlockBusy(false);
      }
      return;
    }

    // Otherwise, prompt for master password
    setMasterPassword('');
    setUnlockModalOpen(true);
  }, [isUnlocked, targetBridges, bridges]);

  const handlePasswordUnlockSubmit = useCallback(async (e: FormEvent) => {
    e.preventDefault();
    if (!masterPassword || !vaultEnvelope) return;

    setUnlockBusy(true);
    setUnlockError('');

    try {
      const derivedKey = await deriveKeyFromPassword(
        masterPassword,
        vaultEnvelope.kdf_salt,
        vaultEnvelope.kdf_iterations || DEFAULT_KDF_ITERATIONS
      );

      const decryptedVaultKey = await decryptVaultKeyEnvelope(
        derivedKey,
        vaultEnvelope.encrypted_vault_key,
        vaultEnvelope.vault_key_nonce,
        vaultEnvelope.vault_key_tag,
        true
      );

      dispatch(setVaultUnlocked({ key: decryptedVaultKey, rememberSession }));

      // Now unseal target bridges with the decrypted master key
      let unsealedCount = 0;
      const candidates = targetBridges.length > 0 ? targetBridges : bridges;
      for (const bridge of candidates) {
        const bridgeId = String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
        if (!bridgeId) continue;
        try {
          const pubKey = await fetchBridgePublicKey(bridgeId);
          if (pubKey) {
            await unsealBridgeE2EE(bridgeId, pubKey, decryptedVaultKey);
            unsealedCount++;
          }
        } catch (bridgeErr) {
          console.warn(`[BridgeSettingsPanel] failed unsealing bridge ${bridgeId}:`, bridgeErr);
        }
      }
      if (unsealedCount === 0 && candidates.length === 0) {
        unsealedCount = await unsealAllConnectedBridges(decryptedVaultKey);
      }

      setUnlockModalOpen(false);
      setMasterPassword('');
      setUnsealSuccessMsg(
        unsealedCount > 0
          ? `Successfully unsealed ${unsealedCount} bridge${unsealedCount === 1 ? '' : 's'}.`
          : 'Bridge unlocked and unseal dispatched.'
      );
    } catch (err: any) {
      setUnlockError(err?.message || 'Incorrect master password. Failed to unlock vault.');
    } finally {
      setUnlockBusy(false);
    }
  }, [masterPassword, vaultEnvelope, rememberSession, dispatch, targetBridges, bridges]);

  const handleLockClick = useCallback(async () => {
    setLockBusy(true);
    setUnlockError('');
    setUnsealSuccessMsg('');

    try {
      // 1. Lock target bridges first over network
      const candidates = targetBridges.length > 0 ? targetBridges : bridges;
      for (const bridge of candidates) {
        const bridgeId = String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
        if (!bridgeId) continue;
        try {
          await lockBridge(bridgeId);
        } catch (err) {
          console.warn(`[BridgeSettingsPanel] lock request failed for bridge ${bridgeId}:`, err);
        }
      }
      if (candidates.length === 0) {
        await lockAllConnectedBridges();
      }

      // 2. Purge UI vault key from Redux and memory
      dispatch(lockVault());

      setUnsealSuccessMsg('Bridge locked and memory purged.');
    } catch (err: any) {
      setUnlockError(err?.message || 'Failed to lock bridge');
    } finally {
      setLockBusy(false);
    }
  }, [dispatch, targetBridges, bridges]);

  return (
    <div
      data-debug-id="bridge-settings-panel"
      className="w-full max-w-full overflow-hidden rounded-xl border border-subtle bg-surface-raised/40 p-3.5 sm:p-4 my-3"
    >
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-sm font-semibold text-primary">Bridge Encryption & Vault</span>
            {vaultStatus === 'Disabled' && (
              <StatusPill tone="neutral" data-debug-id="bridge-vault-status-pill">
                Encryption: Disabled (Optional)
              </StatusPill>
            )}
            {vaultStatus === 'Locked' && (
              <StatusPill tone="warning" data-debug-id="bridge-vault-status-pill">
                Bridge Locked
              </StatusPill>
            )}
            {vaultStatus === 'Unlocked' && (
              <StatusPill tone="success" data-debug-id="bridge-vault-status-pill">
                Bridge Unlocked
              </StatusPill>
            )}
          </div>
          <p className="mt-1 text-xs text-muted leading-relaxed break-words">
            {vaultStatus === 'Disabled' &&
              'End-to-end encrypted storage and terminal streaming are currently optional and disabled for this bridge. Files and terminal streams execute without encryption.'}
            {vaultStatus === 'Locked' &&
              'Bridge vault is locked. File reads/writes are suspended and terminal streams are encrypted until unsealed with your master password.'}
            {vaultStatus === 'Unlocked' &&
              'Bridge vault is unsealed. All files and terminal streaming chunks are securely encrypted with AES-256-GCM.'}
          </p>
        </div>

        <div className="flex flex-wrap items-center gap-2 pt-1 sm:pt-0">
          {vaultStatus === 'Disabled' && (
            <Button
              variant="secondary"
              size="sm"
              data-debug-id="bridge-vault-setup-btn"
              className="min-h-[44px] min-w-[44px] touch-manipulation w-full sm:w-auto"
              onClick={() => {
                if (onOpenVaultSetup) onOpenVaultSetup();
                else setOnboardingOpen(true);
              }}
            >
              <Icon name="lock" size="sm" className="mr-1.5" />
              Enable Encryption
            </Button>
          )}

          {vaultStatus === 'Locked' && (
            <Button
              variant="primary"
              size="sm"
              loading={unlockBusy}
              data-debug-id="bridge-vault-unlock-btn"
              className="min-h-[44px] min-w-[44px] touch-manipulation w-full sm:w-auto"
              onClick={() => void handleUnlockClick()}
            >
              <Icon name="lock" size="sm" className="mr-1.5" />
              Unlock Bridge
            </Button>
          )}

          {vaultStatus === 'Unlocked' && (
            <Button
              variant="secondary"
              size="sm"
              loading={lockBusy}
              data-debug-id="bridge-vault-lock-btn"
              className="min-h-[44px] min-w-[44px] touch-manipulation w-full sm:w-auto text-danger hover:border-danger/40"
              onClick={() => void handleLockClick()}
            >
              <Icon name="lock" size="sm" className="mr-1.5" />
              Lock Bridge
            </Button>
          )}
        </div>
      </div>

      {unsealSuccessMsg ? (
        <div
          data-debug-id="bridge-vault-success-msg"
          className="mt-3 rounded-lg border border-success/30 bg-success-soft p-2.5 text-xs text-success flex items-center gap-1.5"
        >
          <Icon name="check" size="sm" />
          <span>{unsealSuccessMsg}</span>
        </div>
      ) : null}

      {unlockError ? (
        <div
          data-debug-id="bridge-vault-error-msg"
          className="mt-3 rounded-lg border border-danger/30 bg-danger-soft p-2.5 text-xs text-danger flex items-center gap-1.5"
        >
          <Icon name="alert" size="sm" />
          <span>{unlockError}</span>
        </div>
      ) : null}

      {/* Unlock Bridge Modal (Master Password prompt) */}
      {unlockModalOpen ? (
        <Modal
          open={unlockModalOpen}
          onOpenChange={(open) => {
            if (!open) {
              setUnlockModalOpen(false);
              setMasterPassword('');
              setUnlockError('');
            }
          }}
          title="Unlock Bridge Vault"
          data-debug-id="bridge-unlock-modal"
        >
          <form onSubmit={(e) => void handlePasswordUnlockSubmit(e)}>
            <ModalBody className="space-y-4">
              <div className="flex items-center gap-2">
                <Icon name="lock" size="md" className="text-accent" />
                <h3 className="text-base font-semibold text-primary">Unlock Bridge Vault</h3>
              </div>

              <p className="text-xs text-muted leading-relaxed">
                Enter your master password to decrypt the vault key and dispatch an authenticated E2EE unseal payload to the bridge.
              </p>

              <div>
                <label className="block text-xs font-medium text-primary mb-1.5">
                  Master Password
                </label>
                <Input
                  type="password"
                  value={masterPassword}
                  onChange={setMasterPassword}
                  placeholder="Enter your master password"
                  autoFocus
                  required
                  data-debug-id="bridge-unlock-password-input"
                  className="min-h-[44px] w-full"
                />
              </div>

              <label className="flex items-center gap-2 text-xs text-muted cursor-pointer min-h-[44px]">
                <input
                  type="checkbox"
                  checked={rememberSession}
                  onChange={(e) => setRememberSession(e.target.checked)}
                  className="rounded text-accent focus:ring-accent min-h-[20px] min-w-[20px]"
                />
                <span>Remember key for this browser session</span>
              </label>

              {unlockError ? (
                <div
                  data-debug-id="bridge-unlock-modal-error"
                  className="rounded-lg border border-danger/30 bg-danger-soft p-2.5 text-xs text-danger"
                >
                  {unlockError}
                </div>
              ) : null}
            </ModalBody>

            <ModalFooter>
              <Button
                variant="secondary"
                onClick={() => {
                  setUnlockModalOpen(false);
                  setMasterPassword('');
                  setUnlockError('');
                }}
                disabled={unlockBusy}
                className="min-h-[44px] min-w-[44px] touch-manipulation"
              >
                Cancel
              </Button>
              <Button
                type="submit"
                variant="primary"
                loading={unlockBusy}
                disabled={!masterPassword}
                data-debug-id="bridge-unlock-modal-submit"
                className="min-h-[44px] min-w-[44px] touch-manipulation"
              >
                Unlock & Unseal
              </Button>
            </ModalFooter>
          </form>
        </Modal>
      ) : null}

      {/* Vault Onboarding Modal if user clicked Enable Encryption */}
      {onboardingOpen ? (
        <VaultOnboardingModal
          open={onboardingOpen}
          onOpenChange={setOnboardingOpen}
          onDismiss={() => setOnboardingOpen(false)}
        />
      ) : null}
    </div>
  );
}
