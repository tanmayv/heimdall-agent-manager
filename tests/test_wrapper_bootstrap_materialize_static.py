#!/usr/bin/env python3
"""WRP-1 static contract: the wrapper materializes the run_dir itself via the
bridge local socket (list -> per-file fetch -> place), owns provider placement
from layout override data, and makes zero hub calls.

Pairs with the bridge task's RPC contract (wrapper.bootstrap.list +
wrapper.bootstrap.file) and the e2e task (TEST-1) which asserts behavior.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = (ROOT / 'src/wrapper/bootstrap.odin').read_text(encoding='utf-8')
RUNTIME = (ROOT / 'src/wrapper/bridge_runtime.odin').read_text(encoding='utf-8')
ENDPOINT = (ROOT / 'src/bridge/wrapper_endpoint.odin').read_text(encoding='utf-8')
BRIDGE_BOOT = (ROOT / 'src/bridge/bootstrap_service.odin').read_text(encoding='utf-8')


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f'FAILED: {msg}')
        sys.exit(1)


def main() -> None:
    # (1) Wrapper drives the two-RPC, list-driven loop.
    require('wrapper.bootstrap.list' in BOOTSTRAP, 'wrapper must call wrapper.bootstrap.list')
    require('wrapper.bootstrap.file' in BOOTSTRAP, 'wrapper must call wrapper.bootstrap.file per file')
    require('wrapper_bridge_materialize_bootstrap' in BOOTSTRAP, 'materialize entrypoint must exist')

    # (2) Wrapper owns provider placement from layout override values, with the
    #     bridge relative_path as a pure fallback (PROV-1).
    require('wrapper_bootstrap_place' in BOOTSTRAP, 'wrapper must compute kind->path placement')
    for token in ['bootstrap_file_name', 'skill_dir', 'layout', 'relative_path']:
        require(token in BOOTSTRAP, f'placement must consider {token}')
    require('CLAUDE.md' in BOOTSTRAP, 'claude provider bootstrap filename default must live in the wrapper')
    require('.heimdall/bin/ham-ctl' in BOOTSTRAP, 'ctl shim placement path must live in the wrapper')

    # (3) Retriable per-file fetch (RETRY-1) and executable bit for the shim.
    require('wrapper_bridge_bootstrap_call_retry' in BOOTSTRAP, 'per-call retry/backoff required')
    require('0o755' in BOOTSTRAP, 'ctl shim must be written executable (0755)')

    # (4) Zero hub calls from the wrapper bootstrap path: no HTTP, only the local
    #     socket helpers.
    for forbidden in ['http.', 'request_with_headers_timeout', 'daemon_url', '/api/v1/']:
        require(forbidden not in BOOTSTRAP, f'wrapper bootstrap must make zero hub calls (found {forbidden})')

    # (5) Materialization runs BEFORE the agent child process starts.
    mat_idx = RUNTIME.find('wrapper_bridge_materialize_bootstrap(cfg)')
    start_idx = RUNTIME.find('os.process_start(')
    require(mat_idx != -1 and start_idx != -1 and mat_idx < start_idx,
            'run_dir must be materialized before the agent child process starts')

    # (6) Bridge exposes the two wrapper RPCs on the allowlist + dispatch.
    require('wrapper.bootstrap.list' in ENDPOINT and 'wrapper.bootstrap.file' in ENDPOINT,
            'bridge must allowlist + dispatch the two bootstrap RPCs')

    # (7) SOLE-WRITER invariant (BRG-3): on the manifest launch path the bridge
    #     ASSEMBLES + PUBLISHES the file set but does NOT write the run_dir. The old
    #     dual-write helper must be gone; publish must exist.
    require('bridge_bootstrap_publish_file_set' in BRIDGE_BOOT,
            'bridge must publish (not write) the file set on the manifest path')
    require('bridge_bootstrap_write_file_set' not in BRIDGE_BOOT,
            'bridge must NOT write the run_dir on the manifest path (wrapper is sole writer)')

    print('PASS: wrapper bootstrap materialize static')


if __name__ == '__main__':
    main()
