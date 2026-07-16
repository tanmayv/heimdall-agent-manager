#!/usr/bin/env python3
"""Regression for ham-ctl chat send-to-user --chain-id forwarding."""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request

HOST = "127.0.0.1"
PORT = int(os.environ.get("HEIMDALL_TEST_PORT", "49644"))
DAEMON_URL = f"http://{HOST}:{PORT}"
USER_ID = "operator@local"
CLIENT_ID = "ctl-send-user-client"
COORDINATOR_ID = "coord-chain-send-ctl@task19-e2e"
OTHER_AGENT_ID = "non-coord-chain-send-ctl@task19-e2e"
CHAIN_ID = "chain-send-to-user-ctl-primary"
OTHER_CHAIN_ID = "chain-send-to-user-ctl-secondary"


def bin_path(repo_dir, preferred, fallback, binary):
    preferred_path = os.path.join(repo_dir, preferred, "bin", binary)
    if os.path.exists(preferred_path):
        return preferred_path
    return os.path.join(repo_dir, fallback, "bin", binary)


def env_or_bin_path(env_name, repo_dir, preferred, fallback, binary):
    override = os.environ.get(env_name, "")
    if override:
        return override
    return bin_path(repo_dir, preferred, fallback, binary)


def request_post(path, data):
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=json.dumps(data).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as res:
        return res.status, json.loads(res.read().decode("utf-8"))


def request_get_json(path, token):
    sep = "&" if "?" in path else "?"
    req = urllib.request.Request(f"{DAEMON_URL}{path}{sep}token={urllib.parse.quote(token)}", method="GET")
    with urllib.request.urlopen(req, timeout=10) as res:
        return res.status, json.loads(res.read().decode("utf-8"))


def wait_for_daemon():
    for _ in range(60):
        try:
            with urllib.request.urlopen(f"{DAEMON_URL}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.25)
    raise RuntimeError("daemon did not become healthy")


def create_chain(user_token, title, chain_id, coordinator_id):
    status, res = request_post(
        "/user-rpc",
        {
            "action": "task_chain_create",
            "client_instance_id": CLIENT_ID,
            "client_token": user_token,
            "project_id": "default",
            "kind": "solo",
            "title": title,
            "chain_id": chain_id,
            "coordinator_agent_instance_id": coordinator_id,
            "wants_vcs": False,
            "no_scaffold": True,
        },
    )
    if status != 200 or not res.get("ok") or res.get("chain_id") != chain_id:
        raise AssertionError(f"task_chain_create failed: status={status} body={res}")


def run_ctl_json(ctl_bin, *args):
    proc = subprocess.run(
        [ctl_bin, "--daemon-url", DAEMON_URL, *args],
        check=False,
        capture_output=True,
        text=True,
    )
    lines = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    if not lines:
        raise AssertionError(f"ham-ctl produced no stdout for args={args!r}; rc={proc.returncode} stderr={proc.stderr}")
    try:
        payload = json.loads(lines[-1])
    except json.JSONDecodeError as err:
        raise AssertionError(
            f"ham-ctl did not emit JSON for args={args!r}: rc={proc.returncode} stdout={proc.stdout!r} stderr={proc.stderr!r}"
        ) from err
    return proc.returncode, payload


def main():
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    daemon_bin = env_or_bin_path("HEIMDALL_DAEMON_BIN", repo_dir, "result-daemon", "result", "ham-daemon")
    ctl_bin = env_or_bin_path("HEIMDALL_CTL_BIN", repo_dir, "result-ctl", "result-1", "ham-ctl")
    wrapper_bin = env_or_bin_path("HEIMDALL_WRAPPER_BIN", repo_dir, "result-wrapper", "result-2", "ham-wrapper")

    help_text = subprocess.run([ctl_bin, "--help"], check=True, capture_output=True, text=True).stdout
    expected_help = "chat send-to-user --token <agent_token> --user-id <user> [--body <text>] [--chain-id <chain>|--chain <chain>] [--type questions --data <json>]"
    if expected_help not in help_text:
        raise AssertionError(f"ham-ctl help is missing send-to-user --chain-id docs: {help_text}")

    temp_home = tempfile.mkdtemp(prefix="heimdall-ctl-send-user-")
    config_path = os.path.join(temp_home, "config.toml")
    daemon_log_path = os.path.join(temp_home, "daemon.log")
    daemon_proc = None
    daemon_log = None
    try:
        with open(config_path, "w", encoding="utf-8") as f:
            f.write(f'''
[daemon]
bind_host = "{HOST}"
port = {PORT}
data_dir = "{temp_home}/data"
user_id = "{USER_ID}"
wrapper_bin = "{wrapper_bin}"

[ctl]
daemon_url = "{DAEMON_URL}"
ham_ctl_bin = "{ctl_bin}"
''')
        daemon_log = open(daemon_log_path, "w", encoding="utf-8")
        daemon_proc = subprocess.Popen([daemon_bin, "--config", config_path], stdout=daemon_log, stderr=subprocess.STDOUT)
        wait_for_daemon()

        _, coord_res = request_post(
            "/register",
            {"agent_class": "coord-chain-send-ctl", "agent_instance_id": COORDINATOR_ID, "display_name": "Chain Send Coordinator"},
        )
        coord_token = coord_res.get("agent_token")
        if not coord_token:
            raise AssertionError(f"coordinator registration failed: {coord_res}")

        _, other_res = request_post(
            "/register",
            {"agent_class": "non-coord-chain-send-ctl", "agent_instance_id": OTHER_AGENT_ID, "display_name": "Non Coordinator Sender"},
        )
        other_token = other_res.get("agent_token")
        if not other_token:
            raise AssertionError(f"other agent registration failed: {other_res}")

        _, user_res = request_post("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        user_token = user_res.get("client_token")
        if not user_token:
            raise AssertionError(f"user registration failed: {user_res}")

        create_chain(user_token, "Primary chain", CHAIN_ID, COORDINATOR_ID)
        create_chain(user_token, "Secondary chain", OTHER_CHAIN_ID, COORDINATOR_ID)

        _, ambiguous = run_ctl_json(
            ctl_bin,
            "chat",
            "send-to-user",
            "--token",
            coord_token,
            "--user-id",
            USER_ID,
            "--body",
            "ambiguous without explicit chain",
        )
        if ambiguous.get("ok") is not False or "multiple possible active chains" not in ambiguous.get("message", ""):
            raise AssertionError(f"missing-chain send should be ambiguous with multiple active chains: {ambiguous}")

        explicit_body = "explicit chain id survives multiple active chains"
        _, explicit = run_ctl_json(
            ctl_bin,
            "chat",
            "send-to-user",
            "--token",
            coord_token,
            "--user-id",
            USER_ID,
            "--chain-id",
            CHAIN_ID,
            "--body",
            explicit_body,
        )
        if not explicit.get("ok") or not explicit.get("message_id"):
            raise AssertionError(f"explicit chain send failed: {explicit}")
        if explicit.get("chain_id") != CHAIN_ID:
            raise AssertionError(f"explicit chain send lost chain_id: {explicit}")
        if "multiple possible active chains" in explicit.get("message", ""):
            raise AssertionError(f"explicit chain send still hit ambiguous-chain error: {explicit}")

        explicit_id = explicit["message_id"]
        _, chain_fetch = request_get_json(f"/chats/{urllib.parse.quote(COORDINATOR_ID)}/messages?chain_id={CHAIN_ID}", user_token)
        explicit_matches = [m for m in chain_fetch.get("messages", []) if m.get("message_id") == explicit_id]
        if len(explicit_matches) != 1:
            raise AssertionError(f"explicit chain reply missing from chain chat: {chain_fetch}")
        explicit_msg = explicit_matches[0]
        if explicit_msg.get("body") != explicit_body or explicit_msg.get("chain_id") != CHAIN_ID:
            raise AssertionError(f"explicit chain reply lost body/chain_id: {explicit_msg}")

        redirected_body = "redirect with explicit chain context"
        _, redirected = run_ctl_json(
            ctl_bin,
            "chat",
            "send-to-user",
            "--token",
            other_token,
            "--user-id",
            USER_ID,
            "--chain-id",
            CHAIN_ID,
            "--body",
            redirected_body,
        )
        if not redirected.get("ok") or not redirected.get("redirected_to_coordinator"):
            raise AssertionError(f"non-coordinator explicit chain send was not redirected: {redirected}")
        if redirected.get("chain_id") != CHAIN_ID or redirected.get("coordinator_agent_instance_id") != COORDINATOR_ID:
            raise AssertionError(f"redirect lost chain/coordinator context: {redirected}")

        redirected_id = redirected.get("message_id")
        _, redirect_fetch = request_get_json(f"/chats/{urllib.parse.quote(COORDINATOR_ID)}/messages?chain_id={CHAIN_ID}", user_token)
        redirect_matches = [m for m in redirect_fetch.get("messages", []) if m.get("message_id") == redirected_id]
        if len(redirect_matches) != 1:
            raise AssertionError(f"redirected chain message missing from coordinator chain chat: {redirect_fetch}")
        if redirect_matches[0].get("chain_id") != CHAIN_ID:
            raise AssertionError(f"redirected chain message lost chain_id: {redirect_matches[0]}")

        print(f"USING daemon={daemon_bin} ctl={ctl_bin} wrapper={wrapper_bin}")
        print("PASS: ham-ctl chat send-to-user forwards explicit --chain-id, avoids false ambiguity across multiple active chains, documents the flag in help, and preserves chain context on coordinator redirects")
    finally:
        if daemon_proc is not None:
            daemon_proc.terminate()
            try:
                daemon_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon_proc.kill()
        if daemon_log is not None:
            daemon_log.close()
        if os.environ.get("KEEP_HEIMDALL_TEST_TMP") == "1":
            print(f"kept temp dir: {temp_home}")
        else:
            shutil.rmtree(temp_home, ignore_errors=True)


if __name__ == "__main__":
    main()
