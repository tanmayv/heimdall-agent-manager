import urllib.request
import json
import sys
import os
import time
import subprocess
import tempfile
import shutil

DAEMON_URL = "http://127.0.0.1:49326"

def request_post(path, data, extra_headers=None):
    headers = {"Content-Type": "application/json"}
    if extra_headers:
        headers.update(extra_headers)
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=json.dumps(data).encode("utf-8"),
        headers=headers,
        method="POST"
    )
    res = urllib.request.urlopen(req)
    return json.loads(res.read().decode("utf-8"))

def main():
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    temp_home = tempfile.mkdtemp()
    print(f"[*] Created temporary HEIMDALL_HOME: {temp_home}")
    test_failed = False
    
    config_path = os.path.join(temp_home, "config.toml")
    key_log_path = os.path.join(temp_home, "key_log.txt")
    
    # 1. Write config.toml
    config_content = f"""
[daemon]
bind_host = "127.0.0.1"
port = 49326
data_dir = "{temp_home}/data"
wrapper_bin = "{repo_dir}/result-wrapper/bin/ham-wrapper"

[ctl]
daemon_url = "http://127.0.0.1:49326"
ham_ctl_bin = "{repo_dir}/result-ctl/bin/ham-ctl"

[wrapper]
daemon_url = "http://127.0.0.1:49326"
credentials_path = "{temp_home}/data/wrapper-credentials.json"
agent_name = "test-agent"
default_agent = "test-agent"
display_name = "{{instance}}"
requested_access_mode = "main"
tmux_session = "ham-e2e-session"
tmux_window_prefix = "agent"
agent_run_dir = "{temp_home}/data/agent-runs"
project = "default"
memory_templates = []

[wrapper.agent-cmd.test-agent]
command = ["python3", "{repo_dir}/tests/key_logger.py", "{key_log_path}"]
"""
    with open(config_path, "w") as f:
        f.write(config_content)
        
    # Kill any existing tmux session ham-e2e-session
    subprocess.run(["tmux", "kill-session", "-t", "ham-e2e-session"], capture_output=True)
    
    # 2. Start daemon
    print("[*] Starting ham-daemon on port 49326...")
    daemon_log_path = os.path.join(temp_home, "daemon.log")
    daemon_log_file = open(daemon_log_path, "w")
    daemon_proc = subprocess.Popen(
        ["stdbuf", "-oL", "-eL", f"{repo_dir}/result-daemon/bin/ham-daemon", "--config", config_path],
        stdout=daemon_log_file,
        stderr=subprocess.STDOUT
    )
    
    # Wait for daemon
    time.sleep(1)
    for i in range(10):
        try:
            with urllib.request.urlopen(f"{DAEMON_URL}/health") as response:
                if response.status == 200:
                    print("[*] Daemon is healthy!")
                    break
        except Exception:
            pass
        time.sleep(0.5)
    else:
        print("[-] Error: Daemon failed to start")
        daemon_proc.terminate()
        daemon_log_file.close()
        with open(daemon_log_path, "r") as f:
            print("[*] Daemon Log:")
            print(f.read())
        shutil.rmtree(temp_home)
        sys.exit(1)
        
    try:
        # 3. Register user client
        user_res = request_post("/user-client/register", {
            "user_id": "operator@local",
            "client_instance_id": "test-client-e2e"
        })
        client_token = user_res.get("client_token")
        
        # Disable default user chat interrupt preference
        pref_res = request_post("/preferences", {
            "key": "msg_user_chat",
            "value": "{pending_count} User Chat Messages from {user_id}. Read with: {ctl_bin} chat fetch-user --token <your token> --user-id {user_id}",
            "interrupt": False
        }, extra_headers={"Authorization": f"Bearer {client_token}"})
        if not pref_res.get("ok"):
            print("[-] Failed to update user chat preferences:", pref_res)
            sys.exit(1)
        
        # 4. Register agent
        agent_res = request_post("/register", {
            "agent_class": "test-agent",
            "agent_instance_id": "test-agent@default",
            "display_name": "Test Agent E2E"
        })
        agent_token = agent_res.get("agent_token")
        
        # 5. Start agent (which spawns the tmux window and runner)
        print("[*] Starting agent test-agent@default...")
        start_res = request_post("/agents/start", {
            "agent_instance_id": "test-agent@default",
            "agent_token": agent_token,
            "agent": "test-agent"
        })
        if not start_res.get("ok"):
            print("[-] Failed to start agent:", start_res)
            sys.exit(1)
            
        # Wait for key logger to write the first line
        print("[*] Waiting for tmux window and key logger...")
        for i in range(20):
            if os.path.exists(key_log_path):
                with open(key_log_path, "r") as f:
                    content = f.read()
                    if "[LOG] Started key logger" in content:
                        print("[*] Key logger started successfully! Waiting for WebSocket connection...")
                        time.sleep(3.0)
                        break
            time.sleep(0.5)
        else:
            print("[-] Error: Key logger failed to start. Tmux session list:")
            subprocess.run(["tmux", "list-windows", "-a"])
            daemon_log_file.close()
            with open(daemon_log_path, "r") as f:
                print("[*] Daemon Log:")
                print(f.read())
            logs_dir = os.path.join(temp_home, "data", "logs")
            if os.path.exists(logs_dir):
                for fn in os.listdir(logs_dir):
                    if fn.startswith("wrapper"):
                        print(f"[*] Wrapper Log ({fn}):")
                        with open(os.path.join(logs_dir, fn), "r") as f:
                            print(f.read())
            sys.exit(1)
            
        # 6. Send normal message
        print("[*] Sending normal message 'hello_normal'...")
        msg_res1 = request_post("/user-rpc", {
            "client_instance_id": "test-client-e2e",
            "client_token": client_token,
            "action": "send_to_agent",
            "agent_instance_id": "test-agent@default",
            "body": "hello_normal"
        })
        if not msg_res1.get("ok"):
            print("[-] Failed to send normal message:", msg_res1)
            sys.exit(1)
            
        time.sleep(12.0)
        
        # 7. Send interrupt message (starts with ESC \u001b)
        print("[*] Sending interrupt message 'hello_interrupt'...")
        msg_res2 = request_post("/user-rpc", {
            "client_instance_id": "test-client-e2e",
            "client_token": client_token,
            "action": "send_to_agent",
            "agent_instance_id": "test-agent@default",
            "body": "hello_interrupt",
            "interrupt": True
        })
        if not msg_res2.get("ok"):
            print("[-] Failed to send interrupt message:", msg_res2)
            sys.exit(1)
            
        time.sleep(12.0)
        
        # 8. Create project, chain, and task for nudge testing
        print("[*] Creating project, chain, and task for nudge testing...")
        proj = request_post("/projects/create", {
            "agent_token": agent_token,
            "name": "Nudge Test Project",
            "description": "testing task nudge interrupts"
        })
        project_id = proj.get("project_id")
        
        chain = request_post("/task-chains/create", {
            "agent_token": agent_token,
            "project_id": project_id,
            "title": "Nudge Chain",
            "description": "test",
            "coordinator_agent_instance_id": "test-agent@default"
        })
        chain_id = chain.get("chain_id")
        
        task_res = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain_id,
            "title": "Nudge Task",
            "assignee_agent_instance_id": "test-agent@default"
        })
        task_id = task_res.get("task_id")
        
        # 9. Send normal nudge (interrupt=False)
        print("[*] Sending normal task nudge...")
        nudge_res1 = request_post("/user-rpc", {
            "client_instance_id": "test-client-e2e",
            "client_token": client_token,
            "action": "task_nudge",
            "task_id": task_id,
            "chain_id": chain_id,
            "body": "normal_nudge_body",
            "interrupt": False
        })
        if not nudge_res1.get("ok"):
            print("[-] Failed to send normal nudge:", nudge_res1)
            sys.exit(1)
            
        time.sleep(12.0)
        
        # 10. Send interrupt nudge (interrupt=True)
        print("[*] Sending interrupt task nudge...")
        nudge_res2 = request_post("/user-rpc", {
            "client_instance_id": "test-client-e2e",
            "client_token": client_token,
            "action": "task_nudge",
            "task_id": task_id,
            "chain_id": chain_id,
            "body": "interrupt_nudge_body",
            "interrupt": True
        })
        if not nudge_res2.get("ok"):
            print("[-] Failed to send interrupt nudge:", nudge_res2)
            sys.exit(1)
            
        time.sleep(12.0)

        # 11. Read and verify key_log.txt
        with open(key_log_path, "r") as f:
            log_lines = f.read().splitlines()
            
        print("[*] Verification log output:")
        for line in log_lines:
            print(f"  {line}")
            
        normal_idx = -1
        interrupt_idx = -1
        escape_before_interrupt = False

        normal_nudge_idx = -1
        interrupt_nudge_idx = -1
        escape_before_interrupt_nudge = False
        
        for i, line in enumerate(log_lines):
            if ("CHAR: 1" in line or "CHAR: 2" in line) and i + 10 < len(log_lines):
                chars = []
                for j in range(12):
                    if i+j >= len(log_lines):
                        break
                    l = log_lines[i+j]
                    if "CHAR: " in l:
                        chars.append(l.split("CHAR: ")[1][0])
                word = "".join(chars)
                if word.startswith("1 User Chat"):
                    normal_idx = i
                elif word.startswith("2 User Chat"):
                    interrupt_idx = i
                    if i > 0 and log_lines[i-1] == "KEY: ESCAPE":
                        escape_before_interrupt = True

            if ("CHAR: T" in line) and i + 60 < len(log_lines):
                chars = []
                for j in range(80):
                    if i+j >= len(log_lines):
                        break
                    l = log_lines[i+j]
                    if "CHAR: " in l:
                        chars.append(l.split("CHAR: ")[1][0])
                word = "".join(chars)
                if "normal_nudge_body" in word:
                    normal_nudge_idx = i
                elif "interrupt_nudge_body" in word:
                    interrupt_nudge_idx = i
                    if i > 0 and log_lines[i-1] == "KEY: ESCAPE":
                        escape_before_interrupt_nudge = True
                        
        print(f"[*] normal_idx={normal_idx}, interrupt_idx={interrupt_idx}, escape_before_interrupt={escape_before_interrupt}")
        print(f"[*] normal_nudge_idx={normal_nudge_idx}, interrupt_nudge_idx={interrupt_nudge_idx}, escape_before_interrupt_nudge={escape_before_interrupt_nudge}")
        
        try:
            assert normal_idx != -1, "Could not find normal message '1 User Chat' in log"
            assert interrupt_idx != -1, "Could not find interrupt message '2 User Chat' in log"
            assert escape_before_interrupt, "Expected ESCAPE key immediately before interrupt message"
            
            if normal_idx > 0:
                assert log_lines[normal_idx-1] != "KEY: ESCAPE", "Unexpected ESCAPE key before normal message"

            assert normal_nudge_idx != -1, "Could not find normal nudge message in log"
            assert interrupt_nudge_idx != -1, "Could not find interrupt nudge message in log"
            assert escape_before_interrupt_nudge, "Expected ESCAPE key immediately before interrupt nudge message"
            
            if normal_nudge_idx > 0:
                assert log_lines[normal_nudge_idx-1] != "KEY: ESCAPE", "Unexpected ESCAPE key before normal nudge message"
                
            # Verify database contents
            import sqlite3
            db_path = os.path.join(temp_home, "data", "chat", "messages.db")
            conn = sqlite3.connect(db_path)
            cursor = conn.cursor()
            cursor.execute("SELECT body, interrupt FROM messages ORDER BY created_unix_ms DESC LIMIT 2")
            rows = cursor.fetchall()
            conn.close()
            
            print(f"[*] DB rows: {rows}")
            assert len(rows) == 2, f"Expected 2 messages in DB, got {len(rows)}"
            assert rows[0][0] == "hello_interrupt", f"Expected 'hello_interrupt', got '{rows[0][0]}'"
            assert rows[0][1] == 1, f"Expected interrupt = 1, got {rows[0][1]}"
            assert rows[1][0] == "hello_normal", f"Expected 'hello_normal', got '{rows[1][0]}'"
            assert rows[1][1] == 0, f"Expected interrupt = 0, got {rows[1][1]}"
 
            print("[+] PASS: Interrupt Send E2E verification successful!")
        except AssertionError as ae:
            test_failed = True
            print("[-] Assertion failed:", ae)
            daemon_log_file.close()
            with open(daemon_log_path, "r") as f:
                print("[*] Daemon Log:")
                print(f.read())
            logs_dir = os.path.join(temp_home, "data", "logs")
            if os.path.exists(logs_dir):
                for fn in os.listdir(logs_dir):
                    if fn.startswith("wrapper"):
                        print(f"[*] Wrapper Log ({fn}):")
                        with open(os.path.join(logs_dir, fn), "r") as f:
                            print(f.read())
            raise ae
        except Exception as e:
            test_failed = True
            print("[-] Exception occurred:", e)
            raise e
        
    finally:
        print("[*] Cleaning up E2E test...")
        daemon_proc.terminate()
        daemon_proc.wait()
        try:
            daemon_log_file.close()
        except Exception:
            pass
        subprocess.run(["tmux", "kill-session", "-t", "ham-e2e-session"], capture_output=True)
        if test_failed:
            print(f"[!] Test failed. Temporary directory preserved at: {temp_home}")
        else:
            shutil.rmtree(temp_home)

if __name__ == "__main__":
    main()
