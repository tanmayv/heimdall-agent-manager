import urllib.request
import json
import sys
import os
import tempfile
import shutil
import time
import subprocess

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

def request_get(path, extra_headers=None):
    headers = {}
    if extra_headers:
        headers.update(extra_headers)
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        headers=headers,
        method="GET"
    )
    res = urllib.request.urlopen(req)
    return json.loads(res.read().decode("utf-8"))

def main():
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    temp_home = tempfile.mkdtemp()
    print(f"[*] Created temporary HEIMDALL_HOME: {temp_home}")
    
    config_path = os.path.join(temp_home, "config.toml")
    
    # Write config.toml
    config_data = f"""
[daemon]
bind_host = "127.0.0.1"
port = 49326
data_dir = "{temp_home}/data"
wrapper_bin = "{repo_dir}/result-wrapper/bin/ham-wrapper"

[wrapper]
agent_commands = []
"""
    with open(config_path, "w") as f:
        f.write(config_data)
        
    # Start daemon
    print("[*] Starting ham-daemon on port 49326...")
    daemon_log_path = os.path.join(temp_home, "daemon.log")
    daemon_log_file = open(daemon_log_path, "w")
    daemon_proc = subprocess.Popen(
        ["stdbuf", "-oL", "-eL", f"{repo_dir}/result-daemon/bin/ham-daemon", "--config", config_path],
        stdout=daemon_log_file,
        stderr=subprocess.STDOUT
    )
    
    test_failed = False
    
    try:
        # Wait for daemon
        time.sleep(1.0)
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
            raise RuntimeError("Daemon failed to start")
            
        # 1. Register user client
        user_res = request_post("/user-client/register", {
            "user_id": "operator@local",
            "client_instance_id": "test-client-refs"
        })
        client_token = user_res.get("client_token")
        
        # 2. Register agent
        agent_res = request_post("/register", {
            "agent_class": "test-agent",
            "agent_instance_id": "test-agent@default",
            "display_name": "Test Agent References"
        })
        agent_token = agent_res.get("agent_token")
        
        # 3. Create a task chain
        print("[*] Creating task chain...")
        chain_res = request_post("/task-chains/create", {
            "agent_token": agent_token,
            "title": "Reference Card Test Chain",
            "coordinator_agent_instance_id": "test-agent@default"
        })
        chain_id = chain_res.get("chain_id")
        
        # Activate task chain (moves status from planning to in_progress)
        print("[*] Activating task chain...")
        act_res = request_post("/task-chains/activate", {
            "agent_token": agent_token,
            "chain_id": chain_id
        })
        if not act_res.get("ok"):
            raise RuntimeError(f"Failed to activate task chain: {act_res}")
            
        # 4. Create a task in the chain
        print("[*] Creating task...")
        task_res = request_post("/tasks/create", {
            "agent_token": agent_token,
            "chain_id": chain_id,
            "title": "Reference Card Test Task",
            "assignee_agent_instance_id": "test-agent@default"
        })
        task_id = task_res.get("task_id")
        
        # 5. Fetch task chain details via REST route
        print("[*] Simulating UI fetchTaskChain GET request...")
        headers = {"Authorization": f"Bearer {client_token}"}
        chain_fetch = request_get(f"/task-chains/{chain_id}", extra_headers=headers)
        assert chain_fetch.get("chain") is not None, "Expected 'chain' object in response"
        chain_data = chain_fetch["chain"]
        assert chain_data["chain_id"] == chain_id, f"Expected chain_id '{chain_id}', got '{chain_data['chain_id']}'"
        assert chain_data["title"] == "Reference Card Test Chain", "Incorrect chain title"
        assert chain_data["status"] == "in_progress", f"Expected status 'in_progress', got '{chain_data['status']}'"
        print("[+] fetchTaskChain verification PASS!")
        
        # 6. Fetch task details via REST route
        print("[*] Simulating UI fetchTask GET request...")
        task_fetch = request_get(f"/tasks/{task_id}", extra_headers=headers)
        assert task_fetch.get("task") is not None, "Expected 'task' object in response"
        task_data = task_fetch["task"]
        assert task_data["task_id"] == task_id, f"Expected task_id '{task_id}', got '{task_data['task_id']}'"
        assert task_data["title"] == "Reference Card Test Task", "Incorrect task title"
        assert task_data["status"] == "planning", f"Expected status 'planning', got '{task_data['status']}'"
        print("[+] fetchTask verification PASS!")
        
        print("[+] PASS: Entity Reference REST API E2E verification successful!")
        
    except AssertionError as ae:
        test_failed = True
        print("[-] Assertion failed:", ae)
        daemon_log_file.close()
        with open(daemon_log_path, "r") as f:
            print("[*] Daemon Log:")
            print(f.read())
        raise ae
    except Exception as e:
        test_failed = True
        print("[-] Exception occurred:", e)
        daemon_log_file.close()
        with open(daemon_log_path, "r") as f:
            print("[*] Daemon Log:")
            print(f.read())
        raise e
    finally:
        print("[*] Cleaning up E2E test...")
        daemon_proc.terminate()
        daemon_proc.wait()
        try:
            daemon_log_file.close()
        except Exception:
            pass
        if test_failed:
            print(f"[!] Test failed. Temporary directory preserved at: {temp_home}")
        else:
            shutil.rmtree(temp_home)

if __name__ == "__main__":
    main()
