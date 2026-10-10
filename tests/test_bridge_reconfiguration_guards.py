"""Guard ordering regressions in the production stop and replacement paths."""
from pathlib import Path
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'src/bridge/hub_runtime_client.odin').read_text()

class ReconfigurationGuards(unittest.TestCase):
    def test_stop_never_claims_success_after_failed_transport_or_close(self):
        stop = SOURCE.split('bridge_runtime_stop_agent :: proc', 1)[1].split('bridge_runtime_ensure_local_endpoint :: proc', 1)[0]
        terminal = stop.index('bridge_runtime_set_status(instance_id, "stopped", "idle")')
        for guard in ('if !daemon_ok do return false', 'if !list_ok do return false',
                      'if registered && !bridge_pty_host_close(socket, instance_id) do return false'):
            self.assertLess(stop.index(guard), terminal)
        self.assertLess(stop.index('pty_host_reply_delete(reply)'), terminal)

    def test_replacement_cannot_spawn_after_failed_close(self):
        launch = SOURCE.split('bridge_runtime_launch_agent_pty_host :: proc', 1)[1].split('bridge_runtime_stop_agent :: proc', 1)[0]
        close_failure = launch.split('if !bridge_pty_host_close(socket, instance_id) {', 1)[1].split('}', 1)[0]
        self.assertIn('return false, "failed to close existing instance before respawn"', close_failure)
        self.assertLess(launch.index('failed to close existing instance before respawn'), launch.index('pid, ok = bridge_pty_host_spawn'))

if __name__ == '__main__':
    unittest.main()
