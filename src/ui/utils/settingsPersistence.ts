/**
 * Persistence layer for General Settings in the Settings Modal.
 * Stores settings in window.localStorage under the key 'heimdall:settings:general'.
 */

export const SETTINGS_STORAGE_KEY = 'heimdall:settings:general';

export type QueuedMessagesOption = 'queue' | 'send_immediately';
export type PermissionPresetOption = 'default' | 'permissive' | 'strict' | 'custom';
export type PlanReviewPolicyOption = 'always_ask' | 'only_for_plan' | 'never_ask';
export type BrowserJsExecutionPolicyOption = 'request_review' | 'automatic' | 'disabled';

export interface GeneralSettings {
  queuedMessages: QueuedMessagesOption;
  permissionPreset: PermissionPresetOption;
  planReviewPolicy: PlanReviewPolicyOption;
  browserJsExecutionPolicy: BrowserJsExecutionPolicyOption;
  commandSetupScript: string;
  advancedExpanded?: boolean;
}

export const DEFAULT_GENERAL_SETTINGS: GeneralSettings = {
  queuedMessages: 'queue',
  permissionPreset: 'default',
  planReviewPolicy: 'always_ask',
  browserJsExecutionPolicy: 'request_review',
  commandSetupScript: 'example:\nsource ~/.profile',
  advancedExpanded: true,
};

export const defaultValues = DEFAULT_GENERAL_SETTINGS;

export function loadSettings(): GeneralSettings {
  if (typeof window === 'undefined') {
    return { ...DEFAULT_GENERAL_SETTINGS };
  }
  try {
    const raw = window.localStorage.getItem(SETTINGS_STORAGE_KEY);
    if (!raw) {
      return { ...DEFAULT_GENERAL_SETTINGS };
    }
    const parsed = JSON.parse(raw);
    return {
      ...DEFAULT_GENERAL_SETTINGS,
      ...parsed,
    };
  } catch (err) {
    console.warn('Failed to load general settings from localStorage', err);
    return { ...DEFAULT_GENERAL_SETTINGS };
  }
}

export const loadGeneralSettings = loadSettings;

export function saveSettings(settings: Partial<GeneralSettings>): void {
  if (typeof window === 'undefined') return;
  try {
    const current = loadSettings();
    const updated: GeneralSettings = {
      ...current,
      ...settings,
    };
    window.localStorage.setItem(SETTINGS_STORAGE_KEY, JSON.stringify(updated));
  } catch (err) {
    console.warn('Failed to save general settings to localStorage', err);
  }
}

export const saveGeneralSettings = saveSettings;
