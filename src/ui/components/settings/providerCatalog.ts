import { emptyForm, type ProviderForm } from './providerManagement.ts';

export type ProviderPreset = {
  name: string;
  label: string;
  defaultCommand: string[];
  modelsFlag: string;
  availableModels: string[];
  defaultTiers: {
    cheap: string;
    normal: string;
    smart: string;
  };
  promptFlags: string[];
  yoloFlags: string[];
  starterPrompt: string;
  promptDelivery: string;
  skillDir: string;
  bootstrapFileName: string;
};

export const SUPPORTED_PROVIDER_PRESETS: Record<string, ProviderPreset> = {
  claude: {
    name: 'claude',
    label: 'Anthropic Claude Code',
    defaultCommand: ['claude'],
    modelsFlag: '--model',
    availableModels: [
      'claude-fable-5',
      'claude-opus-5',
      'claude-sonnet-4-8',
      'claude-3-7-sonnet-latest',
      'claude-3-5-sonnet-latest',
      'claude-3-5-haiku-latest',
      'claude-3-opus-latest',
      'claude-3-5-sonnet-20241022',
      'claude-3-5-haiku-20241022',
      'claude-3-opus-20240229',
    ],
    defaultTiers: {
      cheap: 'claude-sonnet-4-8',
      normal: 'claude-opus-5',
      smart: 'claude-fable-5',
    },
    promptFlags: ['--prompt', '-p'],
    yoloFlags: ['--dangerously-skip-permissions'],
    starterPrompt: 'First, run: {ctl_bin} agent start-success. Then read your bootstrap file (CLAUDE.md) for context.',
    promptDelivery: 'flag-injection',
    skillDir: '.claude/skills',
    bootstrapFileName: 'CLAUDE.md',
  },
  jetski: {
    name: 'jetski',
    label: 'Jetski (Google Gemini)',
    defaultCommand: ['jetski'],
    modelsFlag: '--model',
    availableModels: [
      'Gemini 3.5 Flash',
      'Gemini 3.1 Pro',
      'Gemini 3.0 Flash',
      'Gemini 3.0 Pro',
      'Gemini 2.5 Flash',
      'Gemini 2.5 Pro',
    ],
    defaultTiers: {
      cheap: 'Gemini 3.5 Flash',
      normal: 'Gemini 3.5 Flash',
      smart: 'Gemini 3.1 Pro',
    },
    promptFlags: [],
    yoloFlags: [],
    starterPrompt: 'First, run: {ctl_bin} agent start-success. Then read AGENTS.md for context.',
    promptDelivery: 'flag-injection',
    skillDir: '.agents/skills',
    bootstrapFileName: 'AGENTS.md',
  },
  antigravity: {
    name: 'antigravity',
    label: 'Google Antigravity (agy)',
    defaultCommand: ['agy'],
    modelsFlag: '--model',
    availableModels: [
      'Gemini 3.5 Flash (Medium)',
      'Gemini 3.1 Pro (High)',
      'Gemini 3.0 Flash',
      'Gemini 3.0 Pro',
    ],
    defaultTiers: {
      cheap: 'Gemini 3.5 Flash (Medium)',
      normal: 'Gemini 3.5 Flash (Medium)',
      smart: 'Gemini 3.1 Pro (High)',
    },
    promptFlags: ['--prompt-interactive', '-i'],
    yoloFlags: ['--dangerously-skip-permissions'],
    starterPrompt: 'First, run: {ctl_bin} agent start-success. Then read AGENTS.md for context.',
    promptDelivery: 'flag-injection',
    skillDir: '.agents/skills',
    bootstrapFileName: 'AGENTS.md',
  },
  codex: {
    name: 'codex',
    label: 'OpenAI Codex CLI',
    defaultCommand: ['codex'],
    modelsFlag: '-m',
    availableModels: [
      'gpt-5',
      'gpt-5-pro',
      'gpt-4o',
      'gpt-4o-mini',
      'o1',
      'o1-mini',
      'o3-mini',
    ],
    defaultTiers: {
      cheap: 'gpt-4o-mini',
      normal: 'gpt-4o',
      smart: 'gpt-5-pro',
    },
    promptFlags: [],
    yoloFlags: ['--approval-policy=never', '--yolo'],
    starterPrompt: 'First, run: {ctl_bin} agent start-success. Then read AGENTS.md for context.',
    promptDelivery: 'flag-injection',
    skillDir: '.codex/skills',
    bootstrapFileName: 'AGENTS.md',
  },
  copilot: {
    name: 'copilot',
    label: 'GitHub Copilot CLI',
    defaultCommand: ['copilot'],
    modelsFlag: '--model',
    availableModels: [
      'claude-sonnet-4.6',
      'claude-opus-4.6',
      'gpt-4o',
      'o1-mini',
    ],
    defaultTiers: {
      cheap: 'claude-sonnet-4.6',
      normal: 'claude-sonnet-4.6',
      smart: 'claude-opus-4.6',
    },
    promptFlags: ['-i'],
    yoloFlags: ['--yolo'],
    starterPrompt: 'First, run: {ctl_bin} agent start-success. Then read AGENTS.md for context.',
    promptDelivery: 'flag-injection',
    skillDir: '.copilot/skills',
    bootstrapFileName: 'AGENTS.md',
  },
};

export const PRESET_OPTIONS: Array<{ key: string; label: string }> = [
  { key: 'custom', label: 'Custom' },
  { key: 'claude', label: 'Claude' },
  { key: 'jetski', label: 'Jetski' },
  { key: 'antigravity', label: 'Antigravity' },
  { key: 'codex', label: 'Codex' },
  { key: 'copilot', label: 'Copilot' },
];

export function getProviderPreset(nameOrCmd: string): ProviderPreset | null {
  if (!nameOrCmd) return null;
  const raw = nameOrCmd.trim().toLowerCase();
  if (!raw || raw === 'custom') return null;

  if (SUPPORTED_PROVIDER_PRESETS[raw]) return SUPPORTED_PROVIDER_PRESETS[raw];

  const base = raw.split(/[/\\]/).pop() || raw;
  if (SUPPORTED_PROVIDER_PRESETS[base]) return SUPPORTED_PROVIDER_PRESETS[base];

  for (const preset of Object.values(SUPPORTED_PROVIDER_PRESETS)) {
    if (preset.name.toLowerCase() === raw || preset.name.toLowerCase() === base) {
      return preset;
    }
    if (
      preset.defaultCommand.some((cmd) => {
        const cLower = cmd.toLowerCase();
        const cBase = cLower.split(/[/\\]/).pop() || cLower;
        return cLower === raw || cBase === base;
      })
    ) {
      return preset;
    }
  }

  if (raw.includes('-copy')) {
    const stripped = raw.replace(/-copy.*$/, '').trim();
    if (stripped && stripped !== raw && stripped !== 'custom') {
      return getProviderPreset(stripped);
    }
  }

  return null;
}

export type ProviderFlagSuggestions = {
  modelsFlag: string[];
  promptFlags: string[];
  yoloFlags: string[];
};

export function getModelSuggestions(presetOrName: ProviderPreset | string | null): string[] {
  const preset = typeof presetOrName === 'string' ? getProviderPreset(presetOrName) : presetOrName;
  return preset ? [...preset.availableModels] : [];
}

export function getFlagSuggestions(presetOrName: ProviderPreset | string | null): ProviderFlagSuggestions {
  const preset = typeof presetOrName === 'string' ? getProviderPreset(presetOrName) : presetOrName;
  if (!preset) {
    return {
      modelsFlag: [],
      promptFlags: [],
      yoloFlags: [],
    };
  }
  return {
    modelsFlag: Array.from(new Set([preset.modelsFlag, '--model', '-m'].filter(Boolean))),
    promptFlags: [...preset.promptFlags],
    yoloFlags: [...preset.yoloFlags],
  };
}

export function formFromPreset(preset: ProviderPreset): ProviderForm {
  return {
    ...emptyForm,
    name: preset.name,
    enabled: true,
    command: [...preset.defaultCommand],
    modelsFlag: preset.modelsFlag,
    modelsCheap: preset.defaultTiers.cheap,
    modelsNormal: preset.defaultTiers.normal,
    modelsSmart: preset.defaultTiers.smart,
    promptFlags: [...preset.promptFlags],
    yoloFlags: [...preset.yoloFlags],
    starterPrompt: preset.starterPrompt,
    promptDelivery: preset.promptDelivery,
    skillDir: preset.skillDir,
    bootstrapFileName: preset.bootstrapFileName,
  };
}
