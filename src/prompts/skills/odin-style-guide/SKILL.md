---
name: odin-style-guide
description: Heimdall Odin coding conventions. Load when writing or reviewing Odin code in this repo.
---

# Odin Style Guide (Heimdall)

## Naming
- `snake_case` for procs, variables, struct fields.
- `Pascal_Case` for struct/union/enum types.
- `SCREAMING_SNAKE_CASE` for package-level constants (#load consts, magic strings).

## Proc signatures
- Keep proc signatures narrow; pass what you need, not the whole service.
- Named return values only when they improve clarity at the call site.
- Always use `defer delete(...)` for owned heap strings returned from procs.

## Error handling
- Use `domain.Domain_Error` for all service-layer errors; never panic on user input.
- Return `(value, bool, Domain_Error)` triples — the bool signals presence, not just error absence.

## Testing
- Dir-style `@(test)` procs in `*_test.odin` within the same package.
- Use `testing.expect_value(t, got, want)` for scalar comparisons.
- Temp files go in `/tmp/`; clean up with `os.remove` in the test proc.

## Build
- Always pass `-collection:odin_test=src` so `odin_test:` imports resolve.
- Use the 2026-05 store odin (`/nix/store/vchib3sshhfhmizi3cfv6hjwizmd0z03-odin-dev-2026-05/bin/odin`); the 2026-07a build has a pre-existing .Haiku enum error in wrapper_endpoint.odin.
