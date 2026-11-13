"""Exercise the built CLI against an isolated JSONL endpoint; no live Hub mutations."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading

def call(binary, args, response=None):
    with tempfile.TemporaryDirectory(prefix="ctl-controls-") as directory:
        endpoint = str(Path(directory) / "rpc.sock")
        server = socket.socket(socket.AF_UNIX)
        server.bind(endpoint)
        server.listen(1)
        server.settimeout(10)
        received = []
        errors = []
        def serve():
            try:
                with server.accept()[0] as connection:
                    request = connection.makefile("rb").readline()
                    received.append(json.loads(request))
                    reply = response or {"v": 1, "id": "ham-ctl-agent", "ok": True, "data": {}}
                    connection.sendall((json.dumps(reply, separators=(",", ":")) + "\n").encode())
            except Exception as error:
                errors.append(error)
        thread = threading.Thread(target=serve)
        thread.start()
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("HEIMDALL_", "HAM_"))}
        env.update(HEIMDALL_VAULT_KEYRING="invalid-isolated-test-key",
                   HEIMDALL_AGENT_TOKEN="isolated-test-token",
                   HEIMDALL_BRIDGE_ENDPOINT="unix:" + endpoint)
        result = subprocess.run([binary, *args], env=env, text=True, capture_output=True, timeout=15)
        thread.join(12)
        server.close()
        assert not errors and not thread.is_alive(), errors
        assert len(received) == 1, result.stdout + result.stderr
        return received[0], result

def main():
    binary = sys.argv[1]
    count = 0
    common = ["--reason", "integration check", "--request-id", "request-7", "--expected-generation", "7"]
    for operation in ["inspect", "cancel", "reopen", "hold", "resume", "unblock",
                      "release-owner", "rereview", "force-complete", "recheck"]:
        args = ["task", "control", "task_test", "--operation", operation, "--chain", "chain_test", *common]
        if operation == "force-complete":
            args += ["--obligation", "review pending"]
        request, result = call(binary, args)
        assert result.returncode == 0, result.stdout + result.stderr
        assert request["method"] == "agent.rest.request", request
        params = request["params"]
        assert params["http_method"] == "POST" and params["path"].endswith("/task-chains/chain_test/tasks/task_test/control"), params
        body = json.loads(params["body"])
        assert body["operation"] == operation and body["expected_generation"] == 7, body
        assert body["reason"] == "integration check" and body["request_id"] == "request-7", body
        if operation == "force-complete":
            assert body["obligations"] == ["review pending"], body
        count += 1
    for verb in ["claim", "transfer", "recover"]:
        args = ["lease", "task_test"] if verb == "claim" else ["lease", verb, "task_test"]
        request, result = call(binary, [*args, "--instance", "inst_target", *common])
        assert result.returncode == 0, result.stdout + result.stderr
        assert request["method"] == "agent.lease." + verb, request
        assert request["params"]["instance_id"] == "inst_target", request
        assert request["params"]["task_id"] == "task_test", request
        count += 1
    request, result = call(binary, ["lease", "task_test"],
        {"v": 1, "id": "ham-ctl-agent", "ok": False, "error": {"code": "conflict", "message": "use explicit transfer"}})
    assert result.returncode != 0 and "use explicit transfer" in result.stdout, result
    print(f"{count + 1} CLI control/claim/refusal checks passed (isolated JSONL endpoint)")

if __name__ == "__main__":
    main()
