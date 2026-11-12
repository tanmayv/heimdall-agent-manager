# Editor setup

Open the checkout root so the editor can find `ols.json`, `odinfmt.json`, and the
TypeScript configuration. The OLS configuration maps the `odin_test` collection
to `src/` and checks the package being edited. It does not launch the application
or recursively check every package in this repository.

## Native prerequisites

Without Nix, install a current Odin compiler, OLS (including `odinfmt`), Node/npm,
Rust/Cargo, `rust-analyzer`, Python 3, and Git. OLS live diagnostics require an Odin
compiler with `-overlay` and `-export-semantics`. Keep OLS and Odin reasonably close
in release date. Use the repository's `ols.json` with any LSP-capable editor.

For Neovim, use `vtsls` for the React/TypeScript frontend and `rust-analyzer` for
`tools/pty_host`. Install frontend dependencies with `npm ci` when needed; no extra
ESLint or formatting policy is imposed by this setup. `.editorconfig` and
`odinfmt.json` describe indentation without reformatting existing source files.

## Odin commands

The helper resolves paths relative to its own checkout, supplies
`-collection:odin_test=<checkout>/src` and the curl version define from
`nix/libcurl-pin.json`, and creates unique binaries beneath
`$HOME/.cache/heimdall-tests/`:

```bash
scripts/dev-odin.sh check src/lib/jsonx
scripts/dev-odin.sh test src/lib/jsonx
scripts/dev-odin.sh build-debug src/ctl
scripts/dev-odin.sh run src/ctl -- --help
```

`check` supports library packages without a `main` procedure. Extra Odin flags can
follow the package; program arguments for `run` follow `--`. `build-debug` prints
the executable path on stdout and compiler output on stderr. Keep its output
directory while debugging; old `editor-*` directories in the cache can be removed
when their processes and debugger sessions have ended.

This helper does not replace the pinned native libraries. Executables that import
`src/lib/httpc` still require the exact libcurl version and linking environment
described in [the HTTP client guide](../src/lib/httpc/README.md#linking). A system
or Homebrew libcurl with another version is not a substitute. Use the existing
Nix environment or provision that pinned library before running these binaries;
the helper preserves the runtime version check.

When acting as a Heimdall-managed agent, invoke these commands through
`ham-ctl shell run`, as described in [AGENTS.md](../AGENTS.md).

## Neovim tasks and debugging

With `nvim-dap`, `nvim-dap-ui`, and CodeLLDB installed, register an Odin launch
configuration whose program is the path printed by `build-debug`, with the
checkout root as `cwd`. Build with `-debug -o:none` (already supplied by the helper)
for source breakpoints and local variables. Set application arguments and the
normal runtime environment explicitly; do not launch another Hub or Bridge against
an existing data directory just to test the debugger. Attaching to a running
process may require additional OS ptrace permissions.

For Rust, `rustaceanvim` plus CodeLLDB can discover Cargo debug targets and tests
from `tools/pty_host/Cargo.toml`. Run its tests serially:

```bash
cd tools/pty_host
cargo test -- --test-threads=1
```

Useful task-runner entries (for example, in Overseer) are:

- The current Odin package's `check`, `test`, and `build-debug` commands above.
- `npm run typecheck` and `npm test`, from the checkout root.
- `npm run dev:preview`, using the existing [preview workflow](dev-preview.md).
- `bash scripts/check-http-boundary.sh`.
- The Rust test command above, from `tools/pty_host`.

For changes to the helper itself, run `python3 tests/test_dev_odin.py`.
