# Artifacts MVP independent validation report

Task: `task-19f5abc10af`
Chain: `chain-19f5ab6d938`
Status: **BLOCKED**

## Commands rerun independently
- `python3 tests/test_markdown_tables_code_newlines.py`
- `python3 tests/test_artifact_ui_static.py`
- `nix build -o result-daemon .#ham-daemon`
- `nix build -o result-ctl .#ham-ctl`
- `nix build -o result-wrapper .#ham-wrapper`
- `python3 tests/test_artifacts_backend_cli.py`
- `npm run build`

All commands above passed in the chain workspace.

## Manual validation highlights
- Created and fetched all five supported kinds (`markdown`, `png`, `jpeg`, `csv`, `html`) against an isolated daemon instance.
- Verified artifact IDs and links use `art_<hex>` / `artifact://art_<hex>`.
- Verified raw content responses preserve MIME and `Content-Disposition: inline; filename="..."`.
- Verified blob sharding and sqlite metadata under `<data_dir>/artifacts/blobs/` and `<data_dir>/artifacts/artifacts.db`.
- Verified delete removes blob bytes, retains a soft-deleted sqlite row, and returns HTTP 410 for subsequent metadata/content fetches.
- Reproduced a blocker: byte-replacement update (`POST /artifacts/update` with `content_base64`) fails with HTTP 500 `blob_write_failed` for an existing artifact, leaving old bytes in place.

Preserved blocker repro evidence:
- `/var/folders/7c/wyz3jh6j651_pzm_8j1fg29400y8lt/T/artifact-update-repro-infaxe3e/daemon.log`
- `/var/folders/7c/wyz3jh6j651_pzm_8j1fg29400y8lt/T/artifact-update-repro-infaxe3e/data/artifacts/artifacts.db`

Key daemon log line:
- `artifact_write_blob: make_directory_all failed for .../data/artifacts/blobs/33/1f/art_331f7555f357450d61bf782c4b29e42b`

## REQ-ID coverage
| REQ-ID | Result | Evidence |
|---|---|---|
| ART-1 | PASS | `tests/test_artifact_ui_static.py` pass; manual create/get/content checks for markdown/png/jpeg/csv/html all passed. |
| ART-2 | PASS | Manual create checks confirmed `art_<hex>` IDs and `artifact://art_...` links; backend/CLI integration test also passed. |
| ART-3 | PASS | Manual isolated-daemon check verified blobs under `<data_dir>/artifacts/blobs/<aa>/<bb>/art_<id>` and directory bootstrap. |
| ART-4 | PASS | Manual sqlite inspection verified rows in `artifacts.db`; delete retained soft-deleted row with `deleted=1`. |
| ART-5 | PARTIAL | Create/get/list/content/delete/auth behavior verified; update endpoint exists but byte-replacement path is broken (see ART-8 blocker). |
| ART-6 | PASS | Manual content fetches for all five kinds returned expected MIME and inline filename disposition. |
| ART-7 | PASS | `tests/test_artifacts_backend_cli.py` pass covered unsupported type, oversize rejection, and image magic-byte rejection. |
| ART-8 | **FAIL / BLOCKER** | Manual repro: `POST /artifacts/update` with replacement `content_base64` returned HTTP 500 `blob_write_failed`; requirement says update MUST overwrite metadata and/or bytes. |
| ART-9 | PASS | `tests/test_artifacts_backend_cli.py` pass covered `ham-ctl artifacts create` and `fetch` roundtrip. |
| ART-10 | PASS | `tests/test_artifacts_backend_cli.py` pass covered inline task-comment and `send_to_user` artifact creation/persistence. |
| ART-11 | PASS | Shared contracts/config present in `src/contracts/artifacts.odin` and config parsing/build paths; daemon/ctl/ui builds passed. |
| UI-1 | PASS | `tests/test_artifact_ui_static.py` pass confirmed API helper exports in `src/ui/api/daemonApi.ts`. |
| UI-2 | PASS | `tests/test_artifact_ui_static.py` pass confirmed artifact chip rendering/link recognition in shared markdown renderer. |
| UI-3 | PASS | `tests/test_artifact_ui_static.py` pass confirmed viewer debug IDs, shared markdown rendering, CSV preview, and sandboxed HTML iframe behavior. |
| TEST-1 | PASS with noted gap | Automated suite rerun passed, but validation exposed a missing automated check for byte-replacement update semantics. |
| VAL-1 | **BLOCKED** | Independent validation completed, but ART-8 is unmet so coordinator closeout should not proceed yet. |

## Recommendation
Do not close out the chain yet. Create a follow-up fix task for the ART-8 byte-replacement update bug, then re-run VAL-1 after the fix lands.
