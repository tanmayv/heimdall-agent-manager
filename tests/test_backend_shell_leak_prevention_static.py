#!/usr/bin/env python3
"""Static verification guard for backend shell sessions and preview proxy leak prevention.

Requirements covered:
- REQ-AUDIT-SHELL-BE-LEAKS:
  1. src/hub/transport/http/shell_session_handlers.odin:
     - shell_session_stream_handler frees session via `defer domain.shell_session_destroy(session)`.
     - shell_session_preview_proxy_handler frees session via `defer domain.shell_session_destroy(session)`.
     - pump_thread is joined before returning from preview proxy handler (commit db0db5c3 invariant).
  2. src/hub/service/shell_session/shell_session_service.odin:
     - shell_session_tunnel_unregister uses runtime.heap_allocator() for k, chunk, and stream deallocations.
  3. src/bridge/pty_host_runtime.odin:
     - pty_host_daemon_socket is cached under mutex to prevent repeated socket path allocations across polled calls.
  4. src/bridge/pty_host_events.odin:
     - bridge_pty_host_events_worker frees socket string in reconnection loop with `delete(socket)`.
  5. src/bridge/shell_cmd.odin:
     - bridge_shell_cmd_exec frees session_id, output_path, and start_time via defer delete.
     - bridge_shell_jobs_dir deallocates expanded data_dir.
     - bridge_shell_output_path deallocates jobs_dir.
  6. src/bridge/wrapper_endpoint.odin:
     - bridge_local_extract_json_object frees needle string.
     - unix and tcp client loops free resp and resp_line strings on every iteration.
  7. Commit db0db5c3 socket ownership invariants:
     - bridge_hub_handle_tunnel_close shuts down receive rather than closing out from under reader thread.
     - bridge_tunnel_tcp_to_ws_worker closes local_tcp_conn as the blocked reader owner.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHELL_SESSION_HANDLERS_FILE = ROOT / "src" / "hub" / "transport" / "http" / "shell_session_handlers.odin"
SHELL_SESSION_SERVICE_FILE = ROOT / "src" / "hub" / "service" / "shell_session" / "shell_session_service.odin"
PTY_HOST_RUNTIME_FILE = ROOT / "src" / "bridge" / "pty_host_runtime.odin"
PTY_HOST_EVENTS_FILE = ROOT / "src" / "bridge" / "pty_host_events.odin"
SHELL_CMD_FILE = ROOT / "src" / "bridge" / "shell_cmd.odin"
WRAPPER_ENDPOINT_FILE = ROOT / "src" / "bridge" / "wrapper_endpoint.odin"
BRIDGE_HUB_RUNTIME_FILE = ROOT / "src" / "bridge" / "hub_runtime_client.odin"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def test_hub_shell_session_handlers():
    require(SHELL_SESSION_HANDLERS_FILE.is_file(), f"File missing: {SHELL_SESSION_HANDLERS_FILE}")
    src = SHELL_SESSION_HANDLERS_FILE.read_text(encoding="utf-8")

    # Domain session cleanup in raw upgrade routes where allocator is heap
    require("defer domain.shell_session_destroy(session)" in src,
            "shell_session_handlers.odin must defer domain.shell_session_destroy(session)")
    count = src.count("defer domain.shell_session_destroy(session)")
    require(count >= 2,
            f"Expected at least 2 instances of domain.shell_session_destroy(session), found {count}")

    # Commit db0db5c3 invariant: pump_thread must be joined before handler returns
    require("thread.join(pump_thread)" in src,
            "shell_session_preview_proxy_handler must join pump_thread before return")
    require("thread.destroy(pump_thread)" in src,
            "shell_session_preview_proxy_handler must destroy pump_thread before return")


def test_hub_shell_session_service():
    require(SHELL_SESSION_SERVICE_FILE.is_file(), f"File missing: {SHELL_SESSION_SERVICE_FILE}")
    src = SHELL_SESSION_SERVICE_FILE.read_text(encoding="utf-8")

    # Tunnel unregister heap allocator consistency
    require("shell_session_tunnel_unregister" in src,
            "shell_session_service.odin must have shell_session_tunnel_unregister")
    require("heap := runtime.heap_allocator()" in src,
            "shell_session_tunnel_unregister must use runtime.heap_allocator()")
    require("delete(k, heap)" in src,
            "shell_session_tunnel_unregister must delete stream key using heap allocator")
    require("delete(chunk, heap)" in src,
            "shell_session_tunnel_unregister must delete chunk using heap allocator")
    require("free(stream, heap)" in src,
            "shell_session_tunnel_unregister must free stream using heap allocator")


def test_bridge_pty_host_runtime():
    require(PTY_HOST_RUNTIME_FILE.is_file(), f"File missing: {PTY_HOST_RUNTIME_FILE}")
    src = PTY_HOST_RUNTIME_FILE.read_text(encoding="utf-8")

    # Socket string caching to avoid per-poll allocations
    require("pty_host_daemon_socket:  string" in src or "pty_host_daemon_socket: string" in src,
            "pty_host_runtime.odin must declare cached pty_host_daemon_socket")
    require("pty_host_daemon_socket = pty_host_socket_path()" in src,
            "pty_host_runtime.odin must initialize cached pty_host_daemon_socket under lock")


def test_bridge_pty_host_events():
    require(PTY_HOST_EVENTS_FILE.is_file(), f"File missing: {PTY_HOST_EVENTS_FILE}")
    src = PTY_HOST_EVENTS_FILE.read_text(encoding="utf-8")

    # Events reconnect loop cleanup
    require("bridge_pty_host_events_worker" in src,
            "pty_host_events.odin must have bridge_pty_host_events_worker")
    require("delete(socket)" in src,
            "bridge_pty_host_events_worker must delete socket string in reconnection loop")


def test_bridge_shell_cmd():
    require(SHELL_CMD_FILE.is_file(), f"File missing: {SHELL_CMD_FILE}")
    src = SHELL_CMD_FILE.read_text(encoding="utf-8")

    # Defer cleanup of strings in exec
    require("defer delete(session_id)" in src,
            "bridge_shell_cmd_exec must defer delete(session_id)")
    require("defer delete(output_path)" in src,
            "bridge_shell_cmd_exec must defer delete(output_path)")
    require("defer delete(start_time)" in src,
            "bridge_shell_cmd_exec must defer delete(start_time)")

    # Data dir & output path cleanup
    require("bridge_shell_jobs_dir" in src,
            "shell_cmd.odin must have bridge_shell_jobs_dir")
    require("delete(data_dir)" in src,
            "bridge_shell_jobs_dir must deallocate expanded data_dir")
    require("defer delete(jobs_dir)" in src,
            "bridge_shell_output_path must deallocate jobs_dir")


def test_bridge_wrapper_endpoint():
    require(WRAPPER_ENDPOINT_FILE.is_file(), f"File missing: {WRAPPER_ENDPOINT_FILE}")
    src = WRAPPER_ENDPOINT_FILE.read_text(encoding="utf-8")

    # JSON extraction needle deallocation
    require("defer delete(needle)" in src,
            "bridge_local_extract_json_object must defer delete(needle)")

    # Unix & TCP client thread loop response string deallocations
    count_resp = src.count("defer delete(resp)")
    require(count_resp >= 2,
            f"Expected at least 2 occurrences of defer delete(resp), found {count_resp}")
    count_resp_line = src.count("defer delete(resp_line)")
    require(count_resp_line >= 2,
            f"Expected at least 2 occurrences of defer delete(resp_line), found {count_resp_line}")


def test_bridge_hub_runtime_socket_invariants():
    require(BRIDGE_HUB_RUNTIME_FILE.is_file(), f"File missing: {BRIDGE_HUB_RUNTIME_FILE}")
    src = BRIDGE_HUB_RUNTIME_FILE.read_text(encoding="utf-8")

    # Commit db0db5c3 socket ownership invariant:
    # Handler must shut down receive, reader worker owns net.close
    require("net.shutdown(stream.tcp_conn, .Receive)" in src,
            "bridge_hub_handle_tunnel_close must shut down receive, not call net.close directly")
    require("net.close(local_tcp_conn)" in src,
            "bridge_tunnel_tcp_to_ws_worker must own closing local_tcp_conn")


def main():
    test_hub_shell_session_handlers()
    test_hub_shell_session_service()
    test_bridge_pty_host_runtime()
    test_bridge_pty_host_events()
    test_bridge_shell_cmd()
    test_bridge_wrapper_endpoint()
    test_bridge_hub_runtime_socket_invariants()
    print("PASS: test_backend_shell_leak_prevention_static")


if __name__ == "__main__":
    main()
