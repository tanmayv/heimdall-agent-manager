#!/usr/bin/env python3
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]

config = (ROOT / 'src/lib/config/config.odin').read_text()
prefs = (ROOT / 'src/daemon/user_pref_rest.odin').read_text()
team_service = (ROOT / 'src/daemon/team_service.odin').read_text()
team_kinds = (ROOT / 'src/daemon/team_kinds.odin').read_text()
runtime = (ROOT / 'src/daemon/agent_id_store.odin').read_text()
app = (ROOT / 'src/ui/components/App.tsx').read_text()
settings = (ROOT / 'src/ui/components/SettingsPage.tsx').read_text()

checks = [
    ('config defines default provider/tier', 'default_agent_provider_profile: string' in config and 'default_agent_model_tier: string' in config),
    ('preferences expose default provider/tier', '"default_agent_provider_profile"' in prefs and '"default_agent_model_tier"' in prefs),
    ('runtime resolves provider/tier from preferences', 'memory_auditor_resolve_pref("", "default_agent_provider_profile")' in runtime and 'memory_auditor_resolve_pref("", "default_agent_model_tier")' in runtime),
    ('built-in team providers inherit global default', 'default_provider = "pi"' not in team_kinds),
    ('coordinator generated name is clear', 'return fmt.tprintf("coordinator@%s", scope)' in team_service),
    ('generated names include project directory basename when available', 'team_service_path_basename(dir)' in team_service),
    ('new chain UI delegates coordinator generation to backend', 'Coordinator: generated on create as coordinator@project-chain' in app and 'disabled={creating || !title.trim()}' in app),
    ('settings exposes generated agent defaults', 'settings-default-agent-provider-select' in settings and 'settings-default-agent-tier-select' in settings),
]

failed = [name for name, ok in checks if not ok]
if failed:
    print('FAILED:')
    for name in failed:
        print('-', name)
    sys.exit(1)
print('TEST PASSED: generated team agent defaults and naming')
