import urllib.request
import urllib.error
import json
import sys
import subprocess
import time
import os
import shutil

DAEMON_URL = "http://127.0.0.1:49326"
HOST = "127.0.0.1"
PORT = 49326

def request_post(path, data):
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=json.dumps(data).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    res = urllib.request.urlopen(req)
    return json.loads(res.read().decode("utf-8"))

def main():
    repo_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    test_dir = os.path.join(repo_dir, "tests", "temp_timestamp_test")
    if os.path.exists(test_dir):
        shutil.rmtree(test_dir)
    os.makedirs(test_dir)

    # 1. Write config.toml
    config_path = os.path.join(test_dir, "config.toml")
    config_content = f"""
[daemon]
port = {PORT}
db_dir = "{test_dir}/data"
user_id = "operator@local"
wrapper_bin = "{repo_dir}/result-wrapper/bin/ham-wrapper"

[ctl]
daemon_url = "{DAEMON_URL}"
ham_ctl_bin = "{repo_dir}/result-ctl/bin/ham-ctl"

[wrapper]
daemon_url = "{DAEMON_URL}"
credentials_path = "{test_dir}/data/wrapper-credentials.json"
agent_name = "test-agent"
default_agent = "test-agent"
display_name = "{{{{instance}}}}"
requested_access_mode = "main"
tmux_session = "ham-ts-session"
tmux_window_prefix = "agent"
agent_run_dir = "{test_dir}/data/agent-runs"
project = "default"
memory_templates = []

[wrapper.agent-cmd.test-agent]
command = ["sleep", "10"]
"""
    with open(config_path, "w") as f:
        f.write(config_content)

    # Kill any existing tmux session ham-ts-session
    subprocess.run(["tmux", "kill-session", "-t", "ham-ts-session"], capture_output=True)

    # 2. Start daemon
    print("[*] Starting ham-daemon...")
    daemon_log = open(os.path.join(test_dir, "daemon.log"), "w")
    daemon_proc = subprocess.Popen(
        [f"{repo_dir}/result-daemon/bin/ham-daemon", "--config", config_path],
        stdout=daemon_log,
        stderr=subprocess.STDOUT
    )

    # Wait for daemon to be healthy
    healthy = False
    for i in range(30):
        try:
            req = urllib.request.urlopen(f"{DAEMON_URL}/health")
            body = json.loads(req.read().decode("utf-8"))
            if body.get("ok"):
                healthy = True
                break
        except Exception:
            pass
        time.sleep(0.5)

    if not healthy:
        print("[-] FAIL: Daemon did not start successfully")
        daemon_proc.terminate()
        sys.exit(1)

    print("[+] Daemon is healthy!")

    try:
        # 3. Register user client
        user_res = request_post("/user-client/register", {
            "user_id": "operator@local",
            "client_instance_id": "test-client-ts"
        })
        client_token = user_res.get("client_token")

        # 4. Register agent
        print("[*] Registering test-agent@default...")
        agent_res = request_post("/register", {
            "agent_class": "test-agent",
            "agent_instance_id": "test-agent@default",
            "display_name": "Test Agent TS"
        })
        agent_token = agent_res.get("agent_token")

        # 5. Start agent (spawns tmux window and runs wrapper)
        print("[*] Starting agent...")
        start_res = request_post("/agents/start", {
            "agent_instance_id": "test-agent@default",
            "agent_token": agent_token,
            "agent": "test-agent"
        })
        if not start_res.get("ok"):
            print("[-] FAIL: Failed to start agent:", start_res)
            sys.exit(1)

        # Wait for agent to report startup and run_dir
        print("[*] Waiting for agent to go ready and report run directory...")
        run_dir = ""
        for i in range(40):
            show_res = request_post("/agents/show", {
                "agent_instance_id": "test-agent@default"
            })
            run_dir = show_res.get("agent", {}).get("run_dir", "")
            if run_dir != "":
                break
            time.sleep(0.5)

        if run_dir == "":
            print("[-] FAIL: Agent did not report run directory")
            sys.exit(1)

        print("[+] Stored agent run directory:", run_dir)
        
        # Verify run_dir ends with "-<timestamp>"
        # e.g. /path/to/test-agent-1782240773187
        parts = run_dir.split("-")
        if len(parts) < 2:
            print("[-] FAIL: run directory does not contain hyphen suffix:", run_dir)
            sys.exit(1)
            
        ts_part = parts[-1]
        if not ts_part.isdigit() or len(ts_part) < 10:
            print("[-] FAIL: suffix part is not a valid timestamp digits:", ts_part)
            sys.exit(1)

        print(f"[+] SUCCESS: Verified run directory suffix '{ts_part}' as a valid timestamp!")

    finally:
        print("[*] Terminating daemon and cleaning up...")
        daemon_proc.terminate()
        daemon_proc.wait()
        daemon_log.close()
        subprocess.run(["tmux", "kill-session", "-t", "ham-ts-session"], capture_output=True)
        shutil.rmtree(test_dir)

    print("ALL RUN DIRECTORY TIMESTAMP SUFFIX TESTS PASSED!")
    sys.exit(0)

if __name__ == "__main__":
    main()
