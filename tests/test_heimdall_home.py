import os
import sys
import time
import shutil
import tempfile
import subprocess

def run_test():
    test_dir = tempfile.mkdtemp(prefix="heimdall_test_home_")
    print(f"Created temp HEIMDALL_HOME directory: {test_dir}")
    
    # Write a custom config.toml targeting port 50001
    config_content = """
[ctl]
daemon_url = "http://127.0.0.1:50001"

[daemon]
bind_host = "127.0.0.1"
data_dir = "~/.local/share/heimdall"
port = 50001

[wrapper]
agent_name = "test-agent"
agent_run_dir = "~/heimdall-agents"
command = ["true"]
"""
    config_path = os.path.join(test_dir, "config.toml")
    with open(config_path, "w") as f:
        f.write(config_content)
    print(f"Wrote config to {config_path}")

    # Set up environment
    env = os.environ.copy()
    env["HEIMDALL_HOME"] = test_dir

    # Launch daemon
    daemon_proc = None
    try:
        daemon_cmd = [
            "nix", "develop", ".#ham-daemon", "--command",
            "./ham-daemon"
        ]
        print("Starting ham-daemon...")
        daemon_proc = subprocess.Popen(
            daemon_cmd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )

        # Wait to see if the daemon starts and creates data_dir under test_dir
        expected_data_dir = os.path.join(test_dir, ".local/share/heimdall")
        print(f"Waiting for data directory to be created: {expected_data_dir}")
        
        success = False
        for _ in range(30): # wait up to 15 seconds
            if os.path.exists(expected_data_dir):
                success = True
                break
            # Check if daemon exited early
            ret = daemon_proc.poll()
            if ret is not None:
                print(f"Daemon process exited early with code {ret}")
                stdout, stderr = daemon_proc.communicate()
                print("Stdout:", stdout)
                print("Stderr:", stderr)
                break
            time.sleep(0.5)

        if not success:
            raise Exception("Daemon failed to start or did not create data directory under HEIMDALL_HOME")

        print("Data directory created successfully under HEIMDALL_HOME!")

        # Verify CLI resolves configuration using HEIMDALL_HOME
        ctl_cmd = [
            "nix", "develop", ".#ham-ctl", "--command",
            "./ham-ctl", "health"
        ]
        print("Running ham-ctl health...")
        res = subprocess.run(ctl_cmd, env=env, capture_output=True, text=True)
        print("CLI Stdout:", res.stdout)
        print("CLI Stderr:", res.stderr)
        
        if res.returncode != 0 or '"ok":true' not in res.stdout:
            raise Exception(f"CLI health check failed: {res.stdout} {res.stderr}")
            
        print("CLI health check succeeded! HEIMDALL_HOME config resolution verified successfully.")

    finally:
        if daemon_proc:
            print("Terminating daemon...")
            daemon_proc.terminate()
            try:
                daemon_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon_proc.kill()
        print("Cleaning up temp directory...")
        shutil.rmtree(test_dir)

if __name__ == "__main__":
    run_test()
