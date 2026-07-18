#!/usr/bin/env python3
"""Artifacts MVP backend + CLI integration regression."""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49683"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
CLIENT_ID = "artifacts-test-client"
AGENT_ID = "artifacts-test-agent@artifacts"
CHAIN_ID = "chain-artifacts-test"
PROJECT_ID = "artifacts-test-project"


class HttpError(RuntimeError):
    def __init__(self, status, payload):
        super().__init__(f"HTTP {status}: {payload}")
        self.status = status
        self.payload = payload


def bin_path(repo: Path, binary: str) -> str:
    for base in ["result-daemon", "result-ctl", "result-wrapper", "result", "result-1", "result-2"]:
        candidate = repo / base / "bin" / binary
        if candidate.exists():
            return str(candidate)
    raise FileNotFoundError(f"could not locate {binary} under result outputs")


def request_post(path: str, data: dict, token: str = ""):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=json.dumps(data).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            body = res.read().decode("utf-8")
            return res.status, json.loads(body) if body else {}
    except urllib.error.HTTPError as err:
        payload = err.read().decode("utf-8")
        try:
            return err.code, json.loads(payload)
        except json.JSONDecodeError:
            return err.code, {"raw": payload}


def request_get_json(path: str, token: str = ""):
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(f"{DAEMON_URL}{path}", headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            return res.status, json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        return err.code, json.loads(err.read().decode("utf-8"))


def request_get_bytes(path: str, token: str = ""):
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(f"{DAEMON_URL}{path}", headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            return res.status, res.read(), dict(res.headers)
    except urllib.error.HTTPError as err:
        return err.code, err.read(), dict(err.headers)


def wait_for_daemon():
    for _ in range(80):
        try:
            with urllib.request.urlopen(f"{DAEMON_URL}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.25)
    raise RuntimeError("daemon did not become healthy")


def start_daemon(daemon_bin: str, config_path: Path, log_path: Path):
    log_handle = open(log_path, "a", encoding="utf-8")
    proc = subprocess.Popen([daemon_bin, "--config", str(config_path)], stdout=log_handle, stderr=subprocess.STDOUT)
    wait_for_daemon()
    return proc, log_handle


def stop_daemon(proc, log_handle):
    if proc is not None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
    if log_handle is not None:
        log_handle.close()


def run_json(cmd: list[str]) -> dict:
    proc = subprocess.run(cmd, capture_output=True, text=True, check=True)
    output = proc.stdout.strip()
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    candidate = lines[-1] if lines else output
    try:
        return json.loads(candidate)
    except json.JSONDecodeError as exc:
        raise AssertionError(f"failed to parse JSON from {cmd}: stdout={output!r} stderr={proc.stderr!r}") from exc


def assert_ok(status: int, payload: dict, label: str):
    if status != 200 or not payload.get("ok"):
        raise AssertionError(f"{label} failed: status={status} payload={payload}")


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    daemon_bin = bin_path(repo, "ham-daemon")
    ctl_bin = bin_path(repo, "ham-ctl")
    wrapper_bin = bin_path(repo, "ham-wrapper")

    temp_home = tempfile.mkdtemp(prefix="heimdall-artifacts-test-")
    config_path = Path(temp_home) / "config.toml"
    daemon_log_path = Path(temp_home) / "daemon.log"
    daemon_proc = None
    daemon_log = None
    try:
        config_path.write_text(
            f"""[daemon]
bind_host = \"{HOST}\"
port = {PORT}
data_dir = \"{temp_home}/data\"
user_id = \"{USER_ID}\"
wrapper_bin = \"{wrapper_bin}\"
artifact_max_bytes = 128

[ctl]
daemon_url = \"{DAEMON_URL}\"
ham_ctl_bin = \"{ctl_bin}\"
""",
            encoding="utf-8",
        )
        daemon_log_path.write_text("", encoding="utf-8")
        daemon_proc, daemon_log = start_daemon(daemon_bin, config_path, daemon_log_path)

        _, agent_res = request_post("/register", {
            "agent_class": "artifacts-test-agent",
            "agent_instance_id": AGENT_ID,
            "display_name": "Artifacts Test Agent",
        })
        agent_token = agent_res.get("agent_token")
        if not agent_token:
            raise AssertionError(f"agent register failed: {agent_res}")

        _, user_res = request_post("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        user_token = user_res.get("client_token")
        if not user_token:
            raise AssertionError(f"user register failed: {user_res}")

        # Create chain/task for inline task-comment artifact creation coverage.
        status, chain_res = request_post("/user-rpc", {
            "action": "task_chain_create",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "project_id": PROJECT_ID,
            "kind": "solo",
            "title": "Artifacts automated tests",
            "chain_id": CHAIN_ID,
            "coordinator_agent_instance_id": AGENT_ID,
            "wants_vcs": False,
            "no_scaffold": True,
        })
        assert_ok(status, chain_res, "task_chain_create")
        status, task_res = request_post("/user-rpc", {
            "action": "task_create",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "chain_id": CHAIN_ID,
            "project_id": PROJECT_ID,
            "title": "Artifacts comment target",
            "description": "comment target",
            "priority": "normal",
            "assignee_agent_instance_id": AGENT_ID,
        })
        assert_ok(status, task_res, "task_create")
        task_id = task_res.get("task_id")
        if not task_id:
            raise AssertionError(f"task_create did not return task_id: {task_res}")

        markdown_bytes = b"# artifact test\nhello from cli\n"
        markdown_file = Path(temp_home) / "sample.md"
        markdown_file.write_bytes(markdown_bytes)
        fetched_file = Path(temp_home) / "fetched.md"

        create_res = run_json([
            ctl_bin, "--config", str(config_path), "--daemon-url", DAEMON_URL,
            "artifacts", "create",
            "--token", agent_token,
            "--file", str(markdown_file),
            "--project", PROJECT_ID,
            "--description", "cli artifact",
        ])
        if not create_res.get("ok"):
            raise AssertionError(f"CLI create failed: {create_res}")
        artifact = create_res.get("artifact", {})
        artifact_id = artifact.get("artifact_id")
        if not artifact_id or not str(create_res.get("link", "")).startswith("artifact://art_"):
            raise AssertionError(f"CLI create missing artifact metadata/link: {create_res}")

        fetch_res = run_json([
            ctl_bin, "--config", str(config_path), "--daemon-url", DAEMON_URL,
            "artifacts", "fetch",
            "--token", agent_token,
            "--artifact-id", create_res["link"],
            "--out", str(fetched_file),
        ])
        if not fetch_res.get("ok") or fetched_file.read_bytes() != markdown_bytes:
            raise AssertionError(f"CLI fetch did not roundtrip bytes: {fetch_res}")

        status, meta_res = request_get_json(f"/artifacts/{urllib.parse.quote(artifact_id)}", agent_token)
        assert_ok(status, meta_res, "artifact get metadata")
        if meta_res["artifact"].get("project_id") != PROJECT_ID:
            raise AssertionError(f"artifact metadata lost project_id: {meta_res}")

        status, list_res = request_get_json(f"/artifacts?project_id={urllib.parse.quote(PROJECT_ID)}&limit=20", agent_token)
        assert_ok(status, list_res, "artifact list")
        if artifact_id not in {row.get("artifact_id") for row in list_res.get("artifacts", [])}:
            raise AssertionError(f"artifact list missing created artifact: {list_res}")

        status, content_bytes, headers = request_get_bytes(f"/artifacts/{urllib.parse.quote(artifact_id)}/content", agent_token)
        if status != 200 or content_bytes != markdown_bytes:
            raise AssertionError(f"artifact content fetch failed: status={status} bytes={content_bytes!r}")
        if headers.get("Content-Type") != "text/markdown":
            raise AssertionError(f"content type incorrect: headers={headers}")
        if "inline; filename=\"sample.md\"" not in headers.get("Content-Disposition", ""):
            raise AssertionError(f"content disposition missing filename: headers={headers}")

        status, auth_fail = request_get_json(f"/artifacts/{urllib.parse.quote(artifact_id)}")
        if status != 401 or auth_fail.get("error") != "unauthorized":
            raise AssertionError(f"missing-token auth rejection not enforced: status={status} payload={auth_fail}")

        status, bad_type = request_post("/artifacts/create", {
            "name": "bad.txt",
            "kind": "markdown",
            "content_base64": base64.b64encode(b"hello").decode("ascii"),
        }, agent_token)
        if status == 200 or bad_type.get("error") not in {"unsupported_type", "invalid_request"}:
            raise AssertionError(f"unsupported type was not rejected: status={status} payload={bad_type}")

        status, oversize = request_post("/artifacts/create", {
            "name": "large.md",
            "kind": "markdown",
            "content_base64": base64.b64encode(b"x" * 256).decode("ascii"),
        }, agent_token)
        if status == 200:
            raise AssertionError(f"oversize artifact unexpectedly accepted: {oversize}")

        status, bad_magic = request_post("/artifacts/create", {
            "name": "fake.png",
            "kind": "png",
            "content_base64": base64.b64encode(b"not a png").decode("ascii"),
        }, agent_token)
        if status == 200 or bad_magic.get("error") != "unsupported_type":
            raise AssertionError(f"png magic-byte validation failed to reject bad payload: status={status} payload={bad_magic}")

        original_sha = meta_res["artifact"].get("sha256")
        original_size = meta_res["artifact"].get("size_bytes")
        replacement_bytes = b"# artifact test\nreplacement bytes after update\n"
        replacement_sha = hashlib.sha256(replacement_bytes).hexdigest()
        status, byte_update_res = request_post("/artifacts/update", {
            "artifact_id": artifact_id,
            "name": "sample.md",
            "description": "byte-replaced cli artifact",
            "content_base64": base64.b64encode(replacement_bytes).decode("ascii"),
        }, agent_token)
        assert_ok(status, byte_update_res, "artifact byte-replacement update")
        byte_updated = byte_update_res.get("artifact", {})
        if byte_updated.get("sha256") != replacement_sha or byte_updated.get("sha256") == original_sha:
            raise AssertionError(f"byte update did not change sha256 correctly: original={original_sha} payload={byte_update_res}")
        if byte_updated.get("size_bytes") != len(replacement_bytes) or byte_updated.get("size_bytes") == original_size:
            raise AssertionError(f"byte update did not change size_bytes correctly: original={original_size} payload={byte_update_res}")
        status, replaced_content, replaced_headers = request_get_bytes(f"/artifacts/{urllib.parse.quote(artifact_id)}/content", agent_token)
        if status != 200 or replaced_content != replacement_bytes or replaced_content == markdown_bytes:
            raise AssertionError(f"artifact byte update content fetch failed: status={status} bytes={replaced_content!r}")
        if replaced_headers.get("Content-Type") != "text/markdown":
            raise AssertionError(f"byte-updated content type incorrect: headers={replaced_headers}")

        status, update_res = request_post("/artifacts/update", {
            "artifact_id": artifact_id,
            "name": "sample.md",
            "description": "updated cli artifact",
            "project_id": "artifacts-test-project-updated",
        }, agent_token)
        assert_ok(status, update_res, "artifact metadata-only update")
        updated_artifact = update_res.get("artifact", {})
        if updated_artifact.get("description") != "updated cli artifact":
            raise AssertionError(f"updated artifact metadata missing description change: {update_res}")
        if updated_artifact.get("sha256") != replacement_sha or updated_artifact.get("size_bytes") != len(replacement_bytes):
            raise AssertionError(f"metadata-only update unexpectedly changed bytes metadata: {update_res}")
        status, updated_meta = request_get_json(f"/artifacts/{urllib.parse.quote(artifact_id)}", agent_token)
        assert_ok(status, updated_meta, "artifact metadata after metadata-only update")
        if updated_meta.get("artifact", {}).get("project_id") != "artifacts-test-project-updated":
            raise AssertionError(f"updated artifact metadata missing project change: {updated_meta}")
        status, metadata_only_content, _ = request_get_bytes(f"/artifacts/{urllib.parse.quote(artifact_id)}/content", agent_token)
        if status != 200 or metadata_only_content != replacement_bytes:
            raise AssertionError(f"metadata-only update did not preserve replacement bytes: status={status} bytes={metadata_only_content!r}")

        status, versions_res = request_get_json(f"/artifacts/{urllib.parse.quote(artifact_id)}/versions", agent_token)
        assert_ok(status, versions_res, "artifact versions list after initial updates")
        versions = versions_res.get("versions", [])
        version_numbers = [row.get("version_no") for row in versions]
        if version_numbers[:3] != [3, 2, 1]:
            raise AssertionError(f"unexpected retained version ordering after initial updates: {versions_res}")
        versions_by_no = {row.get("version_no"): row for row in versions}
        if versions_by_no.get(1, {}).get("project_id") != PROJECT_ID:
            raise AssertionError(f"version 1 metadata missing original project_id: {versions_res}")
        if versions_by_no.get(3, {}).get("project_id") != "artifacts-test-project-updated":
            raise AssertionError(f"metadata-only version did not capture updated project_id: {versions_res}")

        status, version1_bytes, _ = request_get_bytes(f"/artifacts/{urllib.parse.quote(artifact_id)}/content?version=1", agent_token)
        if status != 200 or version1_bytes != markdown_bytes:
            raise AssertionError(f"version 1 content mismatch: status={status} bytes={version1_bytes!r}")
        status, version2_bytes, _ = request_get_bytes(f"/artifacts/{urllib.parse.quote(artifact_id)}/content?version=2", agent_token)
        if status != 200 or version2_bytes != replacement_bytes:
            raise AssertionError(f"version 2 content mismatch: status={status} bytes={version2_bytes!r}")
        status, version3_bytes, _ = request_get_bytes(f"/artifacts/{urllib.parse.quote(artifact_id)}/content?version=3", agent_token)
        if status != 200 or version3_bytes != replacement_bytes:
            raise AssertionError(f"version 3 content mismatch: status={status} bytes={version3_bytes!r}")

        cli_versions_res = run_json([
            ctl_bin, "--config", str(config_path), "--daemon-url", DAEMON_URL,
            "artifacts", "versions",
            "--token", agent_token,
            "--artifact-id", artifact_id,
        ])
        if not cli_versions_res.get("ok") or [row.get("version_no") for row in cli_versions_res.get("versions", [])][:3] != [3, 2, 1]:
            raise AssertionError(f"CLI versions failed: {cli_versions_res}")

        version_fetch_file = Path(temp_home) / "fetched-v1.md"
        cli_fetch_res = run_json([
            ctl_bin, "--config", str(config_path), "--daemon-url", DAEMON_URL,
            "artifacts", "fetch",
            "--token", agent_token,
            "--artifact-id", artifact_id,
            "--version", "1",
            "--out", str(version_fetch_file),
        ])
        if not cli_fetch_res.get("ok") or version_fetch_file.read_bytes() != markdown_bytes:
            raise AssertionError(f"CLI version fetch did not roundtrip bytes: {cli_fetch_res}")

        cli_annotation_create = run_json([
            ctl_bin, "--config", str(config_path), "--daemon-url", DAEMON_URL,
            "artifacts", "annotate",
            "--token", agent_token,
            "--artifact-id", artifact_id,
            "--version", "2",
            "--context-type", "text",
            "--context-json", json.dumps({"type": "text", "lineStart": 2, "lineEnd": 2, "selectedText": "replacement bytes after update"}),
            "--comment", "annotation on version 2",
        ])
        if not cli_annotation_create.get("ok"):
            raise AssertionError(f"CLI annotate failed: {cli_annotation_create}")
        annotation = cli_annotation_create.get("annotation", {})
        annotation_id = annotation.get("annotation_id")
        if not annotation_id or annotation.get("version_no") != 2:
            raise AssertionError(f"CLI annotation create missing id/version linkage: {cli_annotation_create}")

        cli_annotations_res = run_json([
            ctl_bin, "--config", str(config_path), "--daemon-url", DAEMON_URL,
            "artifacts", "annotations",
            "--token", agent_token,
            "--artifact-id", artifact_id,
            "--version", "2",
        ])
        annotations = cli_annotations_res.get("annotations", [])
        if not cli_annotations_res.get("ok") or len(annotations) != 1 or annotations[0].get("annotation_id") != annotation_id:
            raise AssertionError(f"CLI annotations list missing created annotation: {cli_annotations_res}")
        if annotations[0].get("context_json", {}).get("type") != "text":
            raise AssertionError(f"CLI annotation context_json did not roundtrip as JSON: {cli_annotations_res}")

        cli_annotation_update = run_json([
            ctl_bin, "--config", str(config_path), "--daemon-url", DAEMON_URL,
            "artifacts", "annotation-update",
            "--token", agent_token,
            "--annotation-id", annotation_id,
            "--comment", "annotation updated",
        ])
        if not cli_annotation_update.get("ok") or cli_annotation_update.get("annotation", {}).get("comment") != "annotation updated":
            raise AssertionError(f"CLI annotation update failed: {cli_annotation_update}")

        rollback_res = run_json([
            ctl_bin, "--config", str(config_path), "--daemon-url", DAEMON_URL,
            "artifacts", "rollback",
            "--token", agent_token,
            "--artifact-id", artifact_id,
            "--version", "1",
            "--change-reason", "restore original bytes",
        ])
        if not rollback_res.get("ok"):
            raise AssertionError(f"CLI rollback failed: {rollback_res}")
        rolled_back = rollback_res.get("artifact", {})
        if rolled_back.get("current_version_no") != 4:
            raise AssertionError(f"rollback did not append a new head version: {rollback_res}")
        if rolled_back.get("project_id") != PROJECT_ID or rolled_back.get("description") != "cli artifact":
            raise AssertionError(f"rollback head metadata did not match target version: {rollback_res}")
        status, rollback_head_bytes, _ = request_get_bytes(f"/artifacts/{urllib.parse.quote(artifact_id)}/content", agent_token)
        if status != 200 or rollback_head_bytes != markdown_bytes:
            raise AssertionError(f"rollback head bytes mismatch: status={status} bytes={rollback_head_bytes!r}")

        for idx in range(2):
            status, extra_update = request_post("/artifacts/update", {
                "artifact_id": artifact_id,
                "name": "sample.md",
                "description": f"retention update {idx}",
                "project_id": f"artifacts-test-project-retention-{idx}",
            }, agent_token)
            assert_ok(status, extra_update, f"artifact retention update {idx}")

        status, retained_versions_res = request_get_json(f"/artifacts/{urllib.parse.quote(artifact_id)}/versions", agent_token)
        assert_ok(status, retained_versions_res, "artifact versions list after retention pruning")
        retained_versions = retained_versions_res.get("versions", [])
        retained_numbers = [row.get("version_no") for row in retained_versions]
        if retained_numbers != [6, 5, 4, 3, 2]:
            raise AssertionError(f"unexpected retained versions after pruning: {retained_versions_res}")
        status, pruned_v1_bytes, _ = request_get_bytes(f"/artifacts/{urllib.parse.quote(artifact_id)}/content?version=1", agent_token)
        if status != 404:
            raise AssertionError(f"expected version 1 to be pruned after 6th version: status={status} body={pruned_v1_bytes!r}")

        stop_daemon(daemon_proc, daemon_log)
        daemon_proc = None
        daemon_log = None
        daemon_proc, daemon_log = start_daemon(daemon_bin, config_path, daemon_log_path)

        _, agent_res = request_post("/register", {
            "agent_class": "artifacts-test-agent",
            "agent_instance_id": AGENT_ID,
            "display_name": "Artifacts Test Agent",
        })
        restarted_agent_token = agent_res.get("agent_token") or agent_token
        _, user_res = request_post("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        restarted_user_token = user_res.get("client_token") or user_token

        status, restarted_versions_res = request_get_json(f"/artifacts/{urllib.parse.quote(artifact_id)}/versions", restarted_agent_token)
        assert_ok(status, restarted_versions_res, "artifact versions list after daemon restart")
        restarted_numbers = [row.get("version_no") for row in restarted_versions_res.get("versions", [])]
        if restarted_numbers != [6, 5, 4, 3, 2]:
            raise AssertionError(f"retained versions changed across restart: {restarted_versions_res}")
        status, restarted_head_bytes, _ = request_get_bytes(f"/artifacts/{urllib.parse.quote(artifact_id)}/content", restarted_agent_token)
        if status != 200 or restarted_head_bytes != markdown_bytes:
            raise AssertionError(f"head content did not survive restart: status={status} bytes={restarted_head_bytes!r}")
        status, restarted_v2_bytes, _ = request_get_bytes(f"/artifacts/{urllib.parse.quote(artifact_id)}/content?version=2", restarted_agent_token)
        if status != 200 or restarted_v2_bytes != replacement_bytes:
            raise AssertionError(f"versioned content did not survive restart: status={status} bytes={restarted_v2_bytes!r}")
        status, restarted_annotations_res = request_get_json(f"/artifacts/{urllib.parse.quote(artifact_id)}/annotations", restarted_agent_token)
        assert_ok(status, restarted_annotations_res, "artifact annotations list after daemon restart")
        restarted_annotations = restarted_annotations_res.get("annotations", [])
        if len(restarted_annotations) != 1 or restarted_annotations[0].get("annotation_id") != annotation_id:
            raise AssertionError(f"annotation rows did not survive restart: {restarted_annotations_res}")

        cli_annotation_delete = run_json([
            ctl_bin, "--config", str(config_path), "--daemon-url", DAEMON_URL,
            "artifacts", "annotation-delete",
            "--token", restarted_agent_token,
            "--annotation-id", annotation_id,
        ])
        if not cli_annotation_delete.get("ok"):
            raise AssertionError(f"CLI annotation delete failed: {cli_annotation_delete}")
        status, deleted_annotations_res = request_get_json(f"/artifacts/{urllib.parse.quote(artifact_id)}/annotations", restarted_agent_token)
        assert_ok(status, deleted_annotations_res, "artifact annotations list after delete")
        if deleted_annotations_res.get("annotations"):
            raise AssertionError(f"soft-deleted annotation should be hidden from list: {deleted_annotations_res}")

        agent_token = restarted_agent_token
        user_token = restarted_user_token

        # Inline task-comment artifact creation.
        status, comment_res = request_post("/tasks/comment", {
            "agent_token": agent_token,
            "task_id": task_id,
            "chain_id": CHAIN_ID,
            "body": "comment with inline artifact",
            "artifact_name": "comment.md",
            "artifact_kind": "markdown",
            "artifact_content_base64": base64.b64encode(b"# comment artifact\n").decode("ascii"),
        })
        assert_ok(status, comment_res, "task comment with inline artifact")
        status, comments = request_get_json(f"/tasks/{urllib.parse.quote(task_id)}/comments?unresolved=false", user_token)
        comment_bodies = [c.get("body", "") for c in comments.get("comments", [])]
        if not any("artifact://art_" in body for body in comment_bodies):
            raise AssertionError(f"task comment inline artifact link missing from stored body: {comments}")

        # Inline send_to_user artifact creation.
        status, send_res = request_post("/agent-rpc", {
            "agent_token": agent_token,
            "action": "send_to_user",
            "user_id": USER_ID,
            "chain_id": CHAIN_ID,
            "body": "chat with inline artifact",
            "artifact_name": "chat.md",
            "artifact_kind": "markdown",
            "artifact_content_base64": base64.b64encode(b"# chat artifact\n").decode("ascii"),
        })
        assert_ok(status, send_res, "send_to_user with inline artifact")
        status, chat_res = request_post("/user-rpc", {
            "action": "fetch_chat",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "agent_instance_id": AGENT_ID,
            "unread_only": False,
            "limit": 20,
        })
        assert_ok(status, chat_res, "fetch_chat after inline send_to_user")
        if not any(msg.get("message_id") == send_res.get("message_id") and "artifact://art_" in msg.get("body", "") for msg in chat_res.get("messages", [])):
            raise AssertionError(f"inline send_to_user artifact link missing from persisted chat body: {chat_res}")

        status, delete_res = request_post("/artifacts/delete", {"artifact_id": artifact_id}, agent_token)
        assert_ok(status, delete_res, "artifact delete")
        status, deleted_meta = request_get_json(f"/artifacts/{urllib.parse.quote(artifact_id)}", agent_token)
        if status != 410 or deleted_meta.get("error") != "gone":
            raise AssertionError(f"deleted metadata did not return 410: status={status} payload={deleted_meta}")
        status, deleted_content, _ = request_get_bytes(f"/artifacts/{urllib.parse.quote(artifact_id)}/content", agent_token)
        if status != 410 or b'gone' not in deleted_content.lower():
            raise AssertionError(f"deleted content did not return 410 gone: status={status} body={deleted_content!r}")

        print("PASS: artifacts backend/cli integration")
    finally:
        stop_daemon(daemon_proc, daemon_log)
        shutil.rmtree(temp_home, ignore_errors=True)


if __name__ == "__main__":
    main()
