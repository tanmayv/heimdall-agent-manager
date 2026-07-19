#!/usr/bin/env python3
"""Static regression for configurable federation poll/replay cadence."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG = (ROOT / 'src/lib/config/config.odin').read_text(encoding='utf-8')
PEERS = (ROOT / 'src/daemon/federation_peers.odin').read_text(encoding='utf-8')


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require('federation_poll_interval_seconds: int,' in CONFIG, 'daemon config must expose federation poll interval field')
require('case "federation_poll_interval_seconds":' in CONFIG, 'config parser must recognize federation_poll_interval_seconds')
require('cfg.daemon.federation_poll_interval_seconds = 10' in CONFIG, 'default config must preserve the existing 10s cadence')
require('FEDERATION_POLL_INTERVAL_DEFAULT_SECONDS :: 10' in PEERS, 'peer poll default constant missing')
require('FEDERATION_POLL_INTERVAL_MIN_SECONDS :: 5' in PEERS, 'peer poll minimum clamp missing')
require('FEDERATION_POLL_INTERVAL_MAX_SECONDS :: 300' in PEERS, 'peer poll maximum clamp missing')
require('peer_link_poll_sleep_duration = peer_link_poll_interval()' in PEERS, 'poller must cache the validated interval before starting')
require('interval_seconds := server_config.daemon.federation_poll_interval_seconds' in PEERS, 'poll interval helper must read daemon config')
require('FEDERATION_POLL_INTERVAL_INVALID ts_unix_ms=%d configured_seconds=%d effective_seconds=%d' in PEERS, 'invalid interval should be surfaced clearly')
require('FEDERATION_POLL_INTERVAL_CLAMP ts_unix_ms=%d configured_seconds=%d effective_seconds=%d' in PEERS, 'clamped interval should be surfaced clearly')
require('time.sleep(peer_link_poll_sleep_duration)' in PEERS, 'poll worker must use the configured effective interval')

print('federation_poll_interval_config_static: ok')
