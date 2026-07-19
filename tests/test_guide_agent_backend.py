#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
CONFIG = (ROOT / 'src/lib/config/config.odin').read_text()
SERVER = (ROOT / 'src/daemon/server.odin').read_text()
GUIDE = (ROOT / 'src/daemon/guide_service.odin').read_text()
TEMPLATES = (ROOT / 'src/daemon/agent_template_db_service.odin').read_text()
NUDGE = (ROOT / 'src/daemon/task_nudge_scheduler.odin').read_text()
FLAKE = (ROOT / 'flake.nix').read_text()
PROMPT = (ROOT / 'src/prompts/guide_instructions.md').read_text()
GUIDE_AGENT_MD = (ROOT / 'src/prompts/guide-agent.md').read_text()
WRAPPER = (ROOT / 'src/wrapper/main.odin').read_text()

checks = [
    ('config has guide_agent section and defaults', 'Guide_Agent_Config :: struct' in CONFIG and 'cfg.guide_agent.agent_instance_id = "guide@heimdall"' in CONFIG and 'cfg.guide_agent.model_tier = "smart"' in CONFIG),
    ('config parses [guide_agent]', 'if line == "[guide_agent]"' in CONFIG and 'parse_guide_agent_key' in CONFIG),
    ('guide service uses configurable singleton id', 'GUIDE_AGENT_DEFAULT_ID :: "guide@heimdall"' in GUIDE and 'guide_agent_instance_id :: proc()' in GUIDE and 'invalid_singleton_id' not in GUIDE),
    ('agent upsert permits configured guide template only', 'guide_singleton_template_mismatch' in (ROOT / 'src/daemon/agents_start.odin').read_text() and 'guide_template_reserved' not in (ROOT / 'src/daemon/agents_start.odin').read_text()),
    ('guide launches with guide_startup/daemon_startup source', 'guide_service_start(cfg.guide_agent, "daemon_startup")' in SERVER and 'source=%s' in GUIDE),
    ('guide uses guide template and heimdall-system scope', 'template_id = "guide"' in GUIDE and 'GUIDE_AGENT_DEFAULT_PROJECT_ID :: "heimdall-system"' in GUIDE),
    ('guide launch uses wrapper detached with explicit source', 'launch_wrapper_detached(agent_id, provider_profile, server_config_path, log_path, agent_token, display_name, final_tier, project_id, source' in GUIDE),
    ('guide template is seeded', 'template_id = "guide"' in TEMPLATES and 'guide_persona.md' in TEMPLATES and 'guide_instructions.md' in TEMPLATES),
    ('guide/system agents exempt from idle shutdown by configured id', 'agent_system_id_configured(rec.agent_instance_id)' in NUDGE),
    ('guide instructions reject raw user token impersonation', 'Do not use raw long-lived user-token impersonation' in PROMPT),
    ('guide handbook exists and is guide specific', 'singleton global guide' in GUIDE_AGENT_MD and 'Do not use raw long-lived user-token impersonation' in GUIDE_AGENT_MD),
    ('wrapper writes guide handbook only for configured guide singleton', '#load("../prompts/guide-agent.md", string)' in WRAPPER and 'agent_instance_id == guide_agent_instance_id' in WRAPPER and 'guide handbook: read `guide-agent.md`' in WRAPPER),
    ('daemon-with-wrapper rewrites wrapper_bin to same-build wrapper', 'HAM_WRAPPER="${self.packages.${system}.ham-wrapper}/bin/ham-wrapper"' in FLAKE and 'wrapper_bin = \\"" wrapper "\\""' in FLAKE),
]

failed = [name for name, ok in checks if not ok]
if failed:
    print('FAILED:')
    for name in failed:
        print('-', name)
    sys.exit(1)
print('TEST PASSED: guide agent backend singleton/autostart scaffolding')
