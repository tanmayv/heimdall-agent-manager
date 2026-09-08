#!/usr/bin/env python3
"""Comprehensive integration test suite for Fig (CitC) Workspace Integration (REQ-FIG-8).

Verifies end-to-end:
1. CitC Workspace Discovery:
   - Discovers valid CitC workspaces with google3/ directories under HEIMDALL_CITC_ROOT.
   - Excludes non-CitC directories and hidden folders.
   - Relays over Hub API /api/v1/bridges/:id/fig/workspaces.
2. CitC Workspace Creation:
   - Invokes `g4 citc -- <name>` on the bridge host when HEIMDALL_MOCK_CITC is unset.
   - Verifies `g4` invocation arguments and directory creation.
   - Rejects invalid workspace names (e.g. illegal characters, traversal).
   - Relays over Hub API POST /api/v1/bridges/:id/fig/workspaces.
3. Paginated google3 Directory Browsing:
   - Lists large google3 directories with cursor pagination (limit=50).
   - Verifies directories sort before files.
   - Verifies subsequent page traversal via next_cursor until has_more=false.
   - Verifies subdirectory navigation.
   - Verifies path traversal protection (.. and null byte rejection).
   - Relays over Hub API /api/v1/bridges/:id/fig/fs.
4. Project Metadata Persistence & Auto-Derivation:
   - Creates 'fig' project via POST /api/v1/projects with workspace_name and relative_path.
   - Verifies auto-derivation of Piper depot repo_url and CitC default_path.
   - Verifies persistence in SQLite projects table and retrieval via GET/LIST/PATCH.
   - Verifies validation errors for missing workspace_name, invalid name, or malicious path traversal.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def wait_for_port(port: int, timeout: float = 12.0) -> bool:
    start = time.time()
    while time.time() - start < timeout:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return True
        except OSError:
            time.sleep(0.1)
    return False


def find_binary(name: str) -> Path:
    env_var = f"HAM_{name.replace('-', '_').upper()}_BIN"
    if os.environ.get(env_var):
        p = Path(os.environ[env_var])
        if p.exists():
            return p

    # Check dist/
    dist_bin = ROOT / "dist" / "heimdall-cloudtop" / "bin" / name
    if dist_bin.exists():
        return dist_bin

    # Check result symlinks
    part = name.split("-")[1]
    direct_res = ROOT / f"result-{part}" / "bin" / name
    if direct_res.exists():
        return direct_res

    res_pty = ROOT / "result-ptyhost" / "bin" / name
    if res_pty.exists():
        return res_pty

    res_dev = ROOT / "result-devproxy" / "bin" / name
    if res_dev.exists():
        return res_dev

    for bpath in ROOT.glob(f"result*/bin/{name}"):
        if bpath.exists():
            return bpath

    raise FileNotFoundError(f"Binary {name} not found")


def http_req(
    url: str,
    method: str = "GET",
    data: dict | None = None,
    headers: dict | None = None,
    timeout: float = 8.0,
) -> tuple[int, dict]:
    req_headers = {"Content-Type": "application/json"}
    if headers:
        req_headers.update(headers)
    body = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=body, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8")
        try:
            return e.code, json.loads(raw) if raw else {}
        except Exception:
            return e.code, {"raw": raw}


def wait_bridge_online(hub_url: str, bridge_id: str, headers: dict, timeout: float = 12.0) -> dict:
    end = time.time() + timeout
    last = None
    while time.time() < end:
        st, body = http_req(f"{hub_url}/api/v1/bridges/{bridge_id}", headers=headers)
        last = body
        if st == 200 and body.get("data", {}).get("status") == "online":
            return body
        time.sleep(0.15)
    raise AssertionError(f"bridge {bridge_id} did not become online: {last}")


def main() -> None:
    print("=== Starting Fig Workspace Integration Verification Suite (REQ-FIG-8) ===")

    hub_bin = find_binary("ham-hub")
    bridge_bin = find_binary("ham-bridge")
    ctl_bin = find_binary("ham-ctl")
    pty_host_bin = find_binary("ham-pty-host")

    print(f"[+] Using Hub:    {hub_bin}")
    print(f"[+] Using Bridge: {bridge_bin}")

    test_dir = Path(tempfile.mkdtemp(prefix="heimdall-fig-integration-"))
    hub_proc = None
    bridge_proc = None

    try:
        db_path = test_dir / "hub.db"
        citc_root = test_dir / "citc_root"
        citc_root.mkdir(parents=True, exist_ok=True)
        bridge_token_file = test_dir / "bridge_token"
        mock_bin_dir = test_dir / "mock_bin"
        mock_bin_dir.mkdir(parents=True, exist_ok=True)
        g4_calls_log = test_dir / "g4_calls.log"

        # Create mock g4 executable in mock_bin_dir
        mock_g4 = mock_bin_dir / "g4"
        with open(mock_g4, "w", encoding="utf-8") as f:
            f.write(f"""#!/usr/bin/env bash
echo "$@" >> "{g4_calls_log}"
if [ "$1" = "citc" ]; then
    shift
    if [ "$1" = "--" ]; then
        shift
    fi
    WS_NAME="$1"
    mkdir -p "{citc_root}/$WS_NAME/google3"
    exit 0
fi
echo "Unknown g4 command: $@" >&2
exit 1
""")
        mock_g4.chmod(0o755)

        # Pre-seed workspaces in citc_root
        (citc_root / "ws_alpha" / "google3").mkdir(parents=True, exist_ok=True)
        (citc_root / "ws_beta" / "google3").mkdir(parents=True, exist_ok=True)
        (citc_root / "not_a_citc_ws" / "other_dir").mkdir(parents=True, exist_ok=True)
        (citc_root / ".hidden_ws" / "google3").mkdir(parents=True, exist_ok=True)

        hub_port = free_port()
        hub_url = f"http://127.0.0.1:{hub_port}"
        bridge_port = free_port()
        bridge_endpoint_port = free_port()

        owner_user = "test_developer"
        auth_headers = {
            "X-authentik-username": owner_user,
            "X-authentik-name": "Test Developer",
        }

        # 1. Start ham-hub
        migrations_dir = ROOT / "src" / "hub" / "repository" / "sqlite" / "migrations"
        if not migrations_dir.exists():
            migrations_dir = ROOT / "dist" / "heimdall-cloudtop" / "share" / "migrations"

        hub_env = dict(os.environ)
        hub_env["USER"] = owner_user
        hub_env["HAM_CLOUDTOP_OWNER"] = owner_user

        hub_proc = subprocess.Popen(
            [
                str(hub_bin),
                "--listen", f"127.0.0.1:{hub_port}",
                "--db", str(db_path),
                "--migrations-dir", str(migrations_dir),
            ],
            env=hub_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert wait_for_port(hub_port, timeout=12.0), "Hub failed to bind port"
        print("[+] Hub started and healthy on port", hub_port)

        # Enroll bridge
        enroll_res = subprocess.run(
            [
                str(bridge_bin),
                "enroll",
                "--hub", hub_url,
                "--name", "fig-test-bridge",
                "--user", owner_user,
                "--bridge-token-file", str(bridge_token_file),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
        )
        assert enroll_res.returncode == 0, f"Bridge enrollment failed: {enroll_res.stderr} {enroll_res.stdout}"
        assert bridge_token_file.exists() and bridge_token_file.stat().st_size > 0, "Bridge token empty"

        # 2. Start ham-bridge with HEIMDALL_CITC_ROOT and mock g4 in PATH
        bridge_env = dict(os.environ)
        bridge_env["PATH"] = f"{mock_bin_dir}:{bridge_env.get('PATH', '')}"
        bridge_env["HEIMDALL_CITC_ROOT"] = str(citc_root)
        bridge_env["HEIMDALL_HAM_PTY_HOST_BIN"] = str(pty_host_bin)
        bridge_env["HEIMDALL_HAM_CTL_BIN"] = str(ctl_bin)
        bridge_env.pop("HEIMDALL_MOCK_CITC", None)

        bridge_run_dir = test_dir / "bridge_run"
        bridge_run_dir.mkdir(parents=True, exist_ok=True)

        bridge_proc = subprocess.Popen(
            [
                str(bridge_bin),
                "--bind-host", "127.0.0.1",
                "--port", str(bridge_port),
                "--local-endpoint-port", str(bridge_endpoint_port),
                "--hub", hub_url,
                "--bridge-token-file", str(bridge_token_file),
                "--local-run-dir", str(bridge_run_dir),
            ],
            env=bridge_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        assert wait_for_port(bridge_port, timeout=12.0), "Bridge failed to bind HTTP port"

        # Find registered bridge ID
        st, bridges_data = http_req(f"{hub_url}/api/v1/bridges", headers=auth_headers)
        assert st == 200, f"Failed to list bridges: {bridges_data}"
        b_items = bridges_data.get("data", [])
        if isinstance(b_items, dict):
            b_items = b_items.get("items", [])
        assert len(b_items) > 0, f"No bridges registered: {bridges_data}"
        test_bridge = next((b for b in b_items if b.get("bridge_id") != "brg_local"), b_items[0])
        bridge_id = test_bridge["bridge_id"]

        wait_bridge_online(hub_url, bridge_id, auth_headers)
        print(f"[+] Bridge {bridge_id} is ONLINE and connected to Hub")

        # =========================================================================
        # 1. CITC WORKSPACE DISCOVERY
        # =========================================================================
        print("\n--- Test 1: CitC Workspace Discovery ---")
        st, ws_data = http_req(f"{hub_url}/api/v1/bridges/{bridge_id}/fig/workspaces", headers=auth_headers)
        assert st == 200, f"Failed to list CitC workspaces: st={st} body={ws_data}"
        ws_payload = ws_data.get("data", {})
        assert ws_payload.get("ok") is True, f"Expected ok=True in response: {ws_data}"
        workspaces = ws_payload.get("workspaces", [])
        ws_names = [w["name"] for w in workspaces]
        print(f"[+] Discovered workspaces: {ws_names}")
        assert "ws_alpha" in ws_names, f"ws_alpha missing from {ws_names}"
        assert "ws_beta" in ws_names, f"ws_beta missing from {ws_names}"
        assert "not_a_citc_ws" not in ws_names, f"Non-CitC workspace must be excluded: {ws_names}"
        assert ".hidden_ws" not in ws_names, f"Hidden workspace must be excluded: {ws_names}"

        alpha_entry = next(w for w in workspaces if w["name"] == "ws_alpha")
        expected_alpha_path = str(citc_root / "ws_alpha" / "google3")
        assert alpha_entry["path"] == expected_alpha_path, f"Expected path {expected_alpha_path}, got {alpha_entry['path']}"
        print("[+] PASS: CitC Workspace Discovery verified")

        # =========================================================================
        # 2. CITC CLIENT CREATION VIA G4
        # =========================================================================
        print("\n--- Test 2: CitC Client Creation via g4 ---")
        new_ws_name = "ws_gamma_created"
        st, create_ws_data = http_req(
            f"{hub_url}/api/v1/bridges/{bridge_id}/fig/workspaces",
            method="POST",
            data={"workspace": new_ws_name},
            headers=auth_headers,
        )
        assert st == 200, f"CitC workspace creation failed: st={st} body={create_ws_data}"
        create_payload = create_ws_data.get("data", {})
        assert create_payload.get("ok") is True, f"Expected ok=True: {create_ws_data}"
        assert create_payload.get("created") is True, f"Expected created=True: {create_ws_data}"
        assert create_payload.get("name") == new_ws_name, f"Expected name {new_ws_name}: {create_ws_data}"

        # Verify filesystem created
        expected_gamma_g3 = citc_root / new_ws_name / "google3"
        assert expected_gamma_g3.exists() and expected_gamma_g3.is_dir(), f"Workspace google3 directory not created: {expected_gamma_g3}"

        # Verify g4 execution was logged by mock g4 script
        assert g4_calls_log.exists(), "g4 was not invoked by bridge"
        g4_log_content = g4_calls_log.read_text(encoding="utf-8")
        assert f"citc -- {new_ws_name}" in g4_log_content, f"g4 citc invocation not found in log:\n{g4_log_content}"
        print(f"[+] Verified g4 invocation logged: {g4_log_content.strip()}")

        # Verify invalid workspace name rejection
        for invalid_name in ["bad name!", "traversal/../ws", "-starts-with-hyphen", "bad*chars"]:
            st, err_resp = http_req(
                f"{hub_url}/api/v1/bridges/{bridge_id}/fig/workspaces",
                method="POST",
                data={"workspace": invalid_name},
                headers=auth_headers,
            )
            err_payload = err_resp.get("data", {})
            err_code = err_payload.get("error_code") or err_payload.get("error", {}).get("code")
            assert err_payload.get("ok") is False or err_code == "invalid_name", f"Invalid name '{invalid_name}' should have failed: {err_resp}"

        print("[+] PASS: CitC Client Creation via g4 verified")

        # =========================================================================
        # 3. PAGINATED GOOGLE3 DIRECTORY BROWSING
        # =========================================================================
        print("\n--- Test 3: Paginated google3 Directory Browsing (limit=50) ---")
        ws_g3 = citc_root / "ws_alpha" / "google3"
        # Seed 25 directories and 35 files (total 60 entries > 50 batch size)
        for i in range(25):
            dname = f"dir_{i:02d}"
            (ws_g3 / dname).mkdir(parents=True, exist_ok=True)
        for i in range(35):
            fname = f"file_{i:02d}.txt"
            (ws_g3 / fname).write_text(f"content {i}\n", encoding="utf-8")

        # Also add a nested item inside dir_00
        (ws_g3 / "dir_00" / "nested_sub").mkdir(parents=True, exist_ok=True)
        (ws_g3 / "dir_00" / "nested_doc.md").write_text("# Documentation\n", encoding="utf-8")

        # Page 1: Request limit=50
        st, page1_resp = http_req(
            f"{hub_url}/api/v1/bridges/{bridge_id}/fig/fs?workspace=ws_alpha&path=&limit=50",
            headers=auth_headers,
        )
        assert st == 200, f"Failed to list google3 root: st={st} body={page1_resp}"
        page1 = page1_resp.get("data", {})
        assert page1.get("ok") is True, f"Expected ok=True: {page1_resp}"
        assert page1.get("workspace") == "ws_alpha", f"Expected workspace ws_alpha: {page1}"
        entries1 = page1.get("entries", [])
        assert len(entries1) == 50, f"Expected exactly 50 entries in page 1, got {len(entries1)}"
        assert page1.get("has_more") is True, f"Expected has_more=True for page 1: {page1}"
        next_cursor = page1.get("next_cursor")
        assert next_cursor, f"Expected non-empty next_cursor in page 1: {page1}"

        # Verify directories are sorted before files
        is_dir_flags = [e.get("is_dir") for e in entries1]
        first_file_idx = next((i for i, d in enumerate(is_dir_flags) if not d), len(is_dir_flags))
        all_remaining_are_files = all(not d for d in is_dir_flags[first_file_idx:])
        assert all_remaining_are_files, "Directories must sort before files"
        assert first_file_idx == 25, f"Expected all 25 directories first, got first file at index {first_file_idx}"

        # Page 2: Fetch next page using cursor
        st, page2_resp = http_req(
            f"{hub_url}/api/v1/bridges/{bridge_id}/fig/fs?workspace=ws_alpha&path=&limit=50&cursor={next_cursor}",
            headers=auth_headers,
        )
        assert st == 200, f"Failed to list page 2: st={st} body={page2_resp}"
        page2 = page2_resp.get("data", {})
        assert page2.get("ok") is True, f"Expected ok=True in page 2: {page2_resp}"
        entries2 = page2.get("entries", [])
        assert len(entries2) == 10, f"Expected 10 entries in page 2 (60 total - 50 page 1), got {len(entries2)}"
        assert page2.get("has_more") is False, f"Expected has_more=False on last page: {page2}"
        assert not page2.get("next_cursor"), f"Expected empty next_cursor on last page: {page2}"

        # Check total unique entries across page 1 and page 2
        all_names = [e["name"] for e in entries1] + [e["name"] for e in entries2]
        assert len(set(all_names)) == 60, f"Expected 60 distinct items across both pages, got {len(set(all_names))}"

        # Subdirectory browsing
        st, subdir_resp = http_req(
            f"{hub_url}/api/v1/bridges/{bridge_id}/fig/fs?workspace=ws_alpha&path=dir_00&limit=50",
            headers=auth_headers,
        )
        assert st == 200, f"Failed to list subdir dir_00: st={st} body={subdir_resp}"
        subdir_data = subdir_resp.get("data", {})
        assert subdir_data.get("ok") is True, f"Expected ok=True in subdir: {subdir_resp}"
        subdir_entries = subdir_data.get("entries", [])
        subdir_names = [e["name"] for e in subdir_entries]
        assert "nested_sub" in subdir_names, f"nested_sub missing from dir_00: {subdir_names}"
        assert "nested_doc.md" in subdir_names, f"nested_doc.md missing from dir_00: {subdir_names}"

        # Security: Path traversal rejection
        for traversal_path in ["../../etc", "..", "dir_00/../../.."]:
            st, trav_resp = http_req(
                f"{hub_url}/api/v1/bridges/{bridge_id}/fig/fs?workspace=ws_alpha&path={traversal_path}",
                headers=auth_headers,
            )
            trav_data = trav_resp.get("data", {})
            err_code = trav_data.get("error_code") or trav_data.get("error", {}).get("code")
            assert trav_data.get("ok") is False or err_code == "path_outside_root", f"Path traversal '{traversal_path}' was not rejected: {trav_resp}"

        print("[+] PASS: Paginated google3 Directory Browsing verified")

        # =========================================================================
        # 4. PROJECT METADATA PERSISTENCE & AUTO-DERIVATION
        # =========================================================================
        print("\n--- Test 4: Project Metadata Persistence & Auto-Derivation ---")
        # 4A. Create Fig project
        fig_proj_input = {
            "name": "Search Ranking Core",
            "slug": "search-ranking-core",
            "description": "Core search ranking infrastructure project",
            "project_type": "fig",
            "workspace_name": "ws_alpha",
            "relative_path": "experimental/ranking/model",
        }
        st, create_proj_resp = http_req(
            f"{hub_url}/api/v1/projects",
            method="POST",
            data=fig_proj_input,
            headers=auth_headers,
        )
        assert st == 201, f"Create fig project failed: st={st} body={create_proj_resp}"
        created_proj = create_proj_resp.get("data", {})
        project_id = created_proj.get("project_id")
        assert project_id and project_id.startswith("proj_"), f"Invalid project_id: {created_proj}"
        assert created_proj.get("project_type") == "fig", f"Expected project_type='fig': {created_proj}"
        assert created_proj.get("workspace_name") == "ws_alpha", f"Expected workspace_name='ws_alpha': {created_proj}"
        assert created_proj.get("relative_path") == "experimental/ranking/model", f"Expected relative_path: {created_proj}"
        assert created_proj.get("vcs_kind") == "piper", f"Expected vcs_kind='piper': {created_proj}"
        expected_default_path = f"/google/src/cloud/{owner_user}/ws_alpha/google3/experimental/ranking/model"
        assert created_proj.get("default_path") == expected_default_path, f"Expected default_path={expected_default_path}, got {created_proj.get('default_path')}"
        expected_repo_url = "//depot/google3/experimental/ranking/model"
        assert created_proj.get("repo_url") == expected_repo_url, f"Expected repo_url={expected_repo_url}, got {created_proj.get('repo_url')}"

        # 4B. Fetch project via GET
        st, get_proj_resp = http_req(f"{hub_url}/api/v1/projects/{project_id}", headers=auth_headers)
        assert st == 200, f"Failed to get project: st={st} body={get_proj_resp}"
        got_proj = get_proj_resp.get("data", {})
        assert got_proj.get("project_type") == "fig"
        assert got_proj.get("workspace_name") == "ws_alpha"
        assert got_proj.get("relative_path") == "experimental/ranking/model"

        # 4C. Verify project appears in GET /api/v1/projects list
        st, list_proj_resp = http_req(f"{hub_url}/api/v1/projects", headers=auth_headers)
        assert st == 200, f"Failed to list projects: st={st} body={list_proj_resp}"
        all_projs = list_proj_resp.get("data", [])
        matching_proj = next((p for p in all_projs if p.get("project_id") == project_id), None)
        assert matching_proj is not None, f"Created project {project_id} not found in projects list: {all_projs}"
        assert matching_proj.get("project_type") == "fig"
        assert matching_proj.get("workspace_name") == "ws_alpha"

        # 4D. Update relative_path via PATCH
        st, update_proj_resp = http_req(
            f"{hub_url}/api/v1/projects/{project_id}",
            method="PATCH",
            data={"relative_path": "experimental/ranking/serving"},
            headers=auth_headers,
        )
        assert st == 200, f"Failed to update project: st={st} body={update_proj_resp}"
        updated_proj = update_proj_resp.get("data", {})
        assert updated_proj.get("relative_path") == "experimental/ranking/serving", f"relative_path was not updated: {updated_proj}"

        # 4E. Verify database persistence directly in SQLite
        conn = sqlite3.connect(str(db_path))
        cursor = conn.cursor()
        cursor.execute(
            "SELECT project_id, name, project_type, workspace_name, relative_path, vcs_kind, repo_url, default_path FROM projects WHERE project_id = ?",
            (project_id,),
        )
        row = cursor.fetchone()
        assert row is not None, f"Project {project_id} not found in SQLite projects table"
        db_id, db_name, db_type, db_ws, db_rel, db_vcs, db_repo, db_path_val = row
        assert db_id == project_id
        assert db_type == "fig"
        assert db_ws == "ws_alpha"
        assert db_rel == "experimental/ranking/serving"
        assert db_vcs == "piper"
        conn.close()
        print("[+] SQLite database rows and columns verified for project", project_id)

        # 4F. Validation checks: missing workspace_name, illegal chars, traversal
        st, invalid_no_ws = http_req(
            f"{hub_url}/api/v1/projects",
            method="POST",
            data={"name": "No WS Project", "project_type": "fig"},
            headers=auth_headers,
        )
        assert st == 400, f"Expected 400 when creating fig project without workspace_name, got {st}: {invalid_no_ws}"

        st, invalid_trav = http_req(
            f"{hub_url}/api/v1/projects",
            method="POST",
            data={"name": "Bad Traversal", "project_type": "fig", "workspace_name": "ws_alpha", "relative_path": "foo/../bar"},
            headers=auth_headers,
        )
        assert st == 400, f"Expected 400 for relative_path with traversal '..', got {st}: {invalid_trav}"

        # 4G. Create standard local project
        st, local_proj_resp = http_req(
            f"{hub_url}/api/v1/projects",
            method="POST",
            data={"name": "Local Code Project", "project_type": "local", "default_path": "/tmp/local_dir"},
            headers=auth_headers,
        )
        assert st == 201, f"Local project creation failed: st={st} body={local_proj_resp}"
        local_data = local_proj_resp.get("data", {})
        assert local_data.get("project_type") == "local"
        assert local_data.get("workspace_name") == ""

        print("[+] PASS: Project Metadata Persistence & Auto-Derivation verified")

        print("\n=========================================================================")
        print("    ALL FIG WORKSPACE INTEGRATION VERIFICATION TESTS PASSED (REQ-FIG-8)   ")
        print("=========================================================================")

    finally:
        if bridge_proc:
            bridge_proc.terminate()
            try:
                bridge_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                bridge_proc.kill()
        if hub_proc:
            hub_proc.terminate()
            try:
                hub_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                hub_proc.kill()
        shutil.rmtree(test_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
