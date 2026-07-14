import urllib.request
import json
import sys
import subprocess
import time
import os
import shutil

HOST = "127.0.0.1"
BASE_PORT = 49326


def request_post(daemon_url, path, data):
    req = urllib.request.Request(
        f"{daemon_url}{path}",
        data=json.dumps(data).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    res = urllib.request.urlopen(req)
    return json.loads(res.read().decode("utf-8"))


def wait_healthy(daemon_url):
    for _ in range(30):
        try:
            req = urllib.request.urlopen(f"{daemon_url}/health")
            body = json.loads(req.read().decode("utf-8"))
            if body.get("ok"):
                return True
        except Exception:
            pass
        time.sleep(0.5)
    return False


def bin_path(repo_dir, preferred, fallback, binary):
    preferred_path = os.path.join(repo_dir, preferred, "bin", binary)
    if os.path.exists(preferred_path):
        return preferred_path
    return os.path.join(repo_dir, fallback, "bin", binary)


def write_config(repo_dir, test_dir, port, tmux_session, use_random_dir):
    daemon_url = f"http://{HOST}:{port}"
    config_path = os.path.join(test_dir, "config.toml")
    wrapper_bin = bin_path(repo_dir, "result-wrapper", "result-1", "ham-wrapper")
    ctl_bin = bin_path(repo_dir, "result-ctl", "result-2", "ham-ctl")
    random_line = "use_random_dir = true" if use_random_dir else "use_random_dir = false"
    config_content = f"""
[daemon]
port = {port}
db_dir = "{test_dir}/data"
user_id = "operator@local"
wrapper_bin = "{wrapper_bin}"

[ctl]
daemon_url = "{daemon_url}"
ham_ctl_bin = "{ctl_bin}"

[wrapper]
daemon_url = "{daemon_url}"
credentials_path = "{test_dir}/data/wrapper-credentials.json"
agent_name = "test-agent"
default_agent = "test-agent"
display_name = "{{{{instance}}}}"
requested_access_mode = "main"
tmux_session = "{tmux_session}"
tmux_window_prefix = "agent"
agent_run_dir = "{test_dir}/data/agent-runs"
{random_line}
project = ""
memory_templates = []

[wrapper.agent-cmd.test-agent]
command = ["sleep", "10"]
"""
    with open(config_path, "w") as f:
        f.write(config_content)
    return config_path, daemon_url


def run_case(repo_dir, root_dir, port, use_random_dir):
    label = "random" if use_random_dir else "timestamp"
    test_dir = os.path.join(root_dir, label)
    os.makedirs(test_dir)
    tmux_session = f"ham-ts-{label}"
    agent_id = f"test-agent@{label}"
    config_path, daemon_url = write_config(repo_dir, test_dir, port, tmux_session, use_random_dir)

    subprocess.run(["tmux", "kill-session", "-t", tmux_session], capture_output=True)
    daemon_log = open(os.path.join(test_dir, "daemon.log"), "w")
    daemon_proc = subprocess.Popen(
        [bin_path(repo_dir, "result-daemon", "result", "ham-daemon"), "--config", config_path],
        stdout=daemon_log,
        stderr=subprocess.STDOUT
    )

    try:
        if not wait_healthy(daemon_url):
            print(f"[-] FAIL: Daemon did not start for {label}")
            sys.exit(1)

        request_post(daemon_url, "/user-client/register", {
            "user_id": "operator@local",
            "client_instance_id": f"test-client-{label}"
        })

        start_res = request_post(daemon_url, "/agents/start", {
            "agent_instance_id": agent_id,
            "agent": "test-agent"
        })
        if not start_res.get("ok"):
            print(f"[-] FAIL: Failed to start agent for {label}:", start_res)
            sys.exit(1)

        run_dir = ""
        for _ in range(40):
            show_res = request_post(daemon_url, "/agents/show", {"agent_instance_id": agent_id})
            run_dir = show_res.get("agent", {}).get("run_dir", "")
            if run_dir:
                break
            time.sleep(0.5)

        if not run_dir:
            print(f"[-] FAIL: Agent did not report run directory for {label}")
            sys.exit(1)

        print(f"[+] {label} run directory:", run_dir)
        expected_prefix = os.path.join(test_dir, "data", "agent-runs", "default")
        if not run_dir.startswith(expected_prefix + os.sep):
            print(f"[-] FAIL: run_dir outside expected project dir for {label}:", run_dir)
            sys.exit(1)

        basename = os.path.basename(run_dir)
        if use_random_dir:
            if "test-agent" in basename or label in basename:
                print("[-] FAIL: random basename leaked agent instance id:", basename)
                sys.exit(1)
            if not basename.startswith("run-") or len(basename) < 20:
                print("[-] FAIL: random basename shape invalid:", basename)
                sys.exit(1)
        else:
            parts = basename.split("-")
            if len(parts) < 2 or not parts[-1].isdigit() or len(parts[-1]) < 10:
                print("[-] FAIL: timestamp basename shape invalid:", basename)
                sys.exit(1)
            if not basename.startswith("test-agent-"):
                print("[-] FAIL: default basename no longer includes agent id:", basename)
                sys.exit(1)

    finally:
        daemon_proc.terminate()
        daemon_proc.wait()
        daemon_log.close()
        subprocess.run(["tmux", "kill-session", "-t", tmux_session], capture_output=True)


def main():
    repo_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    root_dir = os.path.join(repo_dir, "tests", "temp_timestamp_test")
    if os.path.exists(root_dir):
        shutil.rmtree(root_dir)
    os.makedirs(root_dir)

    try:
        run_case(repo_dir, root_dir, BASE_PORT, False)
        run_case(repo_dir, root_dir, BASE_PORT + 1, True)
    finally:
        shutil.rmtree(root_dir, ignore_errors=True)

    print("ALL RUN DIRECTORY TESTS PASSED!")
    sys.exit(0)


if __name__ == "__main__":
    main()
