export type AutoEnterPair = { pattern: string; preKey: string };
export type ReasonMapping = { key: string; reason: string };

export type ProviderForm = {
  name: string;
  enabled: boolean;
  command: string[];
  modelsFlag: string;
  modelsCheap: string;
  modelsNormal: string;
  modelsSmart: string;
  promptFlags: string[];
  yoloFlags: string[];
  starterPrompt: string;
  promptDelivery: string;
  skillDir: string;
  bootstrapFileName: string;
  startupEnabled: boolean;
  startupProbeSeconds: string;
  startupCaptureIntervalMs: string;
  startupBlockedPatterns: string[];
  startupAutoEnterPairs: AutoEnterPair[];
  startupUnknownIsBlocked: boolean;
  startupReasonMappings: ReasonMapping[];
  activityEnabled: boolean;
  activitySampleLines: string;
  activityIgnoreBottomLines: string;
  activityCheckIntervalSeconds: string;
  activityMinGapMs: string;
  activityMaxGapMs: string;
};

export const emptyForm: ProviderForm = {
  name: '',
  enabled: true,
  command: [],
  modelsFlag: '--model',
  modelsCheap: '',
  modelsNormal: '',
  modelsSmart: '',
  promptFlags: [],
  yoloFlags: [],
  starterPrompt: '',
  promptDelivery: 'flag-injection',
  skillDir: '',
  bootstrapFileName: '',
  startupEnabled: false,
  startupProbeSeconds: '20',
  startupCaptureIntervalMs: '500',
  startupBlockedPatterns: [],
  startupAutoEnterPairs: [],
  startupUnknownIsBlocked: false,
  startupReasonMappings: [],
  activityEnabled: false,
  activitySampleLines: '20',
  activityIgnoreBottomLines: '0',
  activityCheckIntervalSeconds: '2',
  activityMinGapMs: '250',
  activityMaxGapMs: '5000',
};

export function bridgeId(bridge: any): string {
  return String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
}

export function shellHash(path: string): string {
  return `#${path.startsWith('/') ? path : `/${path}`}`;
}

export function asArray(value: any): string[] {
  return Array.isArray(value)
    ? value.map(String).filter(Boolean)
    : String(value || '').split(/\s+/).map((part) => part.trim()).filter(Boolean);
}

export function asLines(value: any): string[] {
  return Array.isArray(value)
    ? value.map(String).filter(Boolean)
    : String(value || '').split(/\r?\n/).map((part) => part.trim()).filter(Boolean);
}

export function intValue(value: string, fallback: number): number {
  const n = Number.parseInt(value, 10);
  return Number.isFinite(n) ? n : fallback;
}

export function configuredTiers(profile: any): string[] {
  return ['cheap', 'normal', 'smart'].filter((tier) => Boolean(profile.models?.[tier]));
}

export function providerDefault(data: any, providers: any[]): { provider: string; tier: string } {
  const provider = String(
    data?.default_provider ||
    data?.defaultProvider ||
    providers.find((profile: any) => profile.enabled && configuredTiers(profile).length)?.name ||
    ''
  );
  const profile =
    providers.find((item: any) => String(item.name || '') === provider) ||
    providers.find((item: any) => item.enabled && configuredTiers(item).length);
  const tiers = configuredTiers(profile || {});
  const tier = String(data?.default_tier || data?.defaultTier || (tiers.includes('normal') ? 'normal' : tiers[0] || ''));
  return { provider, tier };
}

export function parseReasonMappings(value: any): ReasonMapping[] {
  return asLines(value).map((line) => {
    const idx = line.indexOf('=');
    return idx >= 0
      ? { key: line.slice(0, idx), reason: line.slice(idx + 1) }
      : { key: line, reason: '' };
  });
}

export function formFromProfile(profile: any): ProviderForm {
  const startup = profile.startup_detection || {};
  const activity = profile.activity_detection || {};
  const patterns = asLines(startup.auto_enter_patterns);
  const preKeys = asLines(startup.auto_enter_pre_keys);
  return {
    ...emptyForm,
    name: String(profile.name || ''),
    enabled: Boolean(profile.enabled ?? true),
    command: asArray(profile.command),
    modelsFlag: String(profile.models?.flag || ''),
    modelsCheap: String(profile.models?.cheap || ''),
    modelsNormal: String(profile.models?.normal || ''),
    modelsSmart: String(profile.models?.smart || ''),
    promptFlags: asArray(profile.prompt_flags),
    yoloFlags: asArray(profile.yolo_flags),
    starterPrompt: String(profile.starter_prompt || ''),
    promptDelivery: String(profile.prompt_delivery || ''),
    skillDir: String(profile.skill_dir || ''),
    bootstrapFileName: String(profile.bootstrap_file_name || ''),
    startupEnabled: Boolean(startup.enabled),
    startupProbeSeconds: String(startup.startup_probe_seconds ?? startup.probe_seconds ?? '20'),
    startupCaptureIntervalMs: String(startup.capture_interval_ms ?? '500'),
    startupBlockedPatterns: asLines(startup.blocked_patterns),
    startupAutoEnterPairs: Array.from(
      { length: Math.max(patterns.length, preKeys.length) },
      (_, i) => ({ pattern: patterns[i] || '', preKey: preKeys[i] || '' })
    ),
    startupUnknownIsBlocked: Boolean(startup.startup_unknown_is_blocked),
    startupReasonMappings: parseReasonMappings(startup.sanitized_reason_mapping),
    activityEnabled: Boolean(activity.enabled),
    activitySampleLines: String(activity.sample_line_count ?? '20'),
    activityIgnoreBottomLines: String(activity.ignore_bottom_lines ?? '0'),
    activityCheckIntervalSeconds: String(activity.check_interval_seconds ?? '2'),
    activityMinGapMs: String(activity.min_gap_ms ?? '250'),
    activityMaxGapMs: String(activity.max_gap_ms ?? '5000'),
  };
}

export function profileFromForm(form: ProviderForm): any {
  return {
    name: form.name.trim(),
    enabled: form.enabled,
    command: form.command,
    models: {
      flag: form.modelsFlag.trim(),
      cheap: form.modelsCheap.trim(),
      normal: form.modelsNormal.trim(),
      smart: form.modelsSmart.trim(),
    },
    prompt_flags: form.promptFlags,
    yolo_flags: form.yoloFlags,
    starter_prompt: form.starterPrompt,
    prompt_delivery: form.promptDelivery,
    skill_dir: form.skillDir.trim(),
    bootstrap_file_name: form.bootstrapFileName.trim(),
    startup_detection: {
      enabled: form.startupEnabled,
      startup_probe_seconds: intValue(form.startupProbeSeconds, 20),
      capture_interval_ms: intValue(form.startupCaptureIntervalMs, 500),
      blocked_patterns: form.startupBlockedPatterns,
      auto_enter_patterns: form.startupAutoEnterPairs.map((pair) => pair.pattern),
      auto_enter_pre_keys: form.startupAutoEnterPairs.map((pair) => pair.preKey),
      startup_unknown_is_blocked: form.startupUnknownIsBlocked,
      sanitized_reason_mapping: form.startupReasonMappings.map((row) => `${row.key}=${row.reason}`),
    },
    activity_detection: {
      enabled: form.activityEnabled,
      sample_line_count: intValue(form.activitySampleLines, 20),
      ignore_bottom_lines: intValue(form.activityIgnoreBottomLines, 0),
      check_interval_seconds: intValue(form.activityCheckIntervalSeconds, 2),
      min_gap_ms: intValue(form.activityMinGapMs, 250),
      max_gap_ms: intValue(form.activityMaxGapMs, 5000),
    },
  };
}

export function parseProviderUrlParams(search: string): { bridge: string; duplicateFrom: string } {
  const query = search.startsWith('?') ? search.slice(1) : search;
  const params = new URLSearchParams(query);
  return {
    bridge: params.get('bridge') || '',
    duplicateFrom: params.get('duplicateFrom') || '',
  };
}

export function buildDuplicateForm(profile: any, duplicateFrom: string): ProviderForm {
  const base = formFromProfile(profile);
  return {
    ...base,
    name: `${duplicateFrom}-copy`,
  };
}

export type RenamePlan = {
  isRenamed: boolean;
  oldName: string;
  newName: string;
  shouldDeleteOld: boolean;
  shouldUpdateDefault: boolean;
  defaultTier: string;
};

export function planSaveProvider({
  isEdit,
  providerName,
  formName,
  currentProfile,
  providersData,
  providersList,
  profile,
}: {
  isEdit: boolean;
  providerName: string;
  formName: string;
  currentProfile?: any;
  providersData?: any;
  providersList: any[];
  profile: any;
}): RenamePlan {
  const oldName = isEdit ? providerName.trim() : '';
  const newName = formName.trim();
  const isRenamed = isEdit && Boolean(oldName) && newName !== oldName;

  const shouldDeleteOld = Boolean(isRenamed && currentProfile?.source === 'store');

  const defaultInfo = providerDefault(providersData, providersList);
  const wasDefault = Boolean(
    isRenamed && (
      providersData?.default_provider === oldName ||
      providersData?.defaultProvider === oldName ||
      defaultInfo.provider === oldName
    )
  );

  let defaultTier = 'normal';
  if (wasDefault) {
    const nextTiers = configuredTiers(profile);
    defaultTier = defaultInfo.tier && nextTiers.includes(defaultInfo.tier)
      ? defaultInfo.tier
      : (nextTiers[0] || defaultInfo.tier || 'normal');
  }

  return {
    isRenamed,
    oldName,
    newName,
    shouldDeleteOld,
    shouldUpdateDefault: wasDefault,
    defaultTier,
  };
}
