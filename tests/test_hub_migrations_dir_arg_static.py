#!/usr/bin/env python3
"""
Regression test for NRX-2 / NRX-3 / NRX-6 / NRX-7.

Asserts that the ham-hub *server* path honors `--migrations-dir` in addition to
the existing `--db` / `--listen` / `--port`, and that the no-flag default is
preserved.

The server path is `main()` -> `parse_args(&config)` (src/hub/main.odin). The
`tokens`/`users` CLI path (`parse_token_global_args`) calls `parse_args`, so
consolidating `--migrations-dir` into `parse_args` fixes the server path while
preserving CLI parity.

This is a static (source-level) regression test: it pins the parse_args
implementation so NRX-2 cannot silently regress without a test failure.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT / "src" / "hub" / "main.odin"
CONFIG_BIND = ROOT / "src" / "hub" / "app" / "config_bind.odin"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    main_src = MAIN.read_text()
    config_src = CONFIG_BIND.read_text()

    # NRX-2: server path honors --migrations-dir. parse_args is the server-path
    # parser (called directly by main()). The flag must set config.migrations_dir
    # via the value-clone pattern used by --db.
    require(
        'arg == "--migrations-dir" && i + 1 < len(os.args)' in main_src,
        "NRX-2: parse_args must handle --migrations-dir with a following value",
    )
    require(
        'config.migrations_dir = strings.clone(os.args[i + 1])' in main_src,
        "NRX-2: --migrations-dir value must be cloned into config.migrations_dir",
    )

    # NRX-3: server path still honors --db / --listen / --port.
    require(
        'arg == "--db" && i + 1 < len(os.args)' in main_src,
        "NRX-3: parse_args must still handle --db",
    )
    require(
        'config.database_path = strings.clone(os.args[i + 1])' in main_src,
        "NRX-3: --db value must still set config.database_path",
    )
    require(
        'arg == "--listen" && i + 1 < len(os.args)' in main_src,
        "NRX-3: parse_args must still handle --listen",
    )
    require(
        'arg == "--port" && i + 1 < len(os.args)' in main_src,
        "NRX-3: parse_args must still handle --port",
    )

    # Single-source-of-truth: --migrations-dir must NOT be re-parsed in the
    # tokens/users path now that parse_args owns it. A second clone() assignment
    # in parse_token_global_args would indicate the consolidation regressed.
    require(
        main_src.count("config.migrations_dir = strings.clone") == 1,
        "NRX-2: --migrations-dir must be parsed exactly once (in parse_args); "
        "duplicate handling in parse_token_global_args should be removed",
    )

    # main() (server path) must call parse_args directly (not only the CLI path).
    require(
        "parse_args(&config)" in main_src,
        "NRX-2: server main() must invoke parse_args(&config)",
    )

    # NRX-7: when --migrations-dir is NOT supplied, config retains the default
    # relative value (worktree-root default invocation unchanged).
    require(
        'migrations_dir = "src/hub/repository/sqlite/migrations"' in config_src,
        "NRX-7: default migrations_dir must remain the relative worktree-root path",
    )
    # parse_args must only OVERRIDE migrations_dir when the flag is present; i.e.
    # it must be an `else if`-style branch that only fires for the flag, leaving
    # the default otherwise.
    require(
        'do config.migrations_dir = ' not in main_src,
        "NRX-7: migrations_dir must not be set unconditionally in parse_args",
    )

    print("PASS: hub --migrations-dir server-path arg (NRX-2, NRX-3, NRX-6, NRX-7)")


if __name__ == "__main__":
    main()
