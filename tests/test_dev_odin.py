"""Exercise editor command routing without building the application or starting services."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/dev-odin.sh"


class DevOdinTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.tmpdir = Path(self.tmp.name)
        self.capture = self.tmpdir / "args.json"
        stub = self.tmpdir / "odin"
        stub.write_text(
            '#!/usr/bin/env python3\n'
            'import json, os, sys\n'
            'from pathlib import Path\n'
            'Path(os.environ["ODIN_CAPTURE"]).write_text(json.dumps({"args": sys.argv[1:], "cwd": os.getcwd()}))\n'
            'sys.exit(int(os.environ.get("ODIN_EXIT", "0")))\n'
        )
        stub.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.tmpdir}:{os.environ['PATH']}", ODIN_CAPTURE=str(self.capture))

    def run_script(self, *args, **env):
        return subprocess.run(
            ["bash", str(SCRIPT), *args], cwd=self.tmpdir,
            env=dict(self.env, **env), text=True, capture_output=True,
        )

    def test_check_resolves_collection_and_pin_from_any_cwd(self):
        result = self.run_script("check", "src/lib/jsonx", "-vet")
        self.assertEqual(result.returncode, 0, result.stderr)
        call = json.loads(self.capture.read_text())
        self.assertEqual(call["cwd"], str(ROOT))
        self.assertEqual(call["args"][:2], ["check", str(ROOT / "src/lib/jsonx")])
        self.assertIn(f"-collection:odin_test={ROOT}/src", call["args"])
        self.assertIn("-no-entry-point", call["args"])
        pin = json.loads((ROOT / "nix/libcurl-pin.json").read_text())["curl"]["version"]
        self.assertIn(f"-define:HAM_CURL_VERSION={pin}", call["args"])
        self.assertEqual(call["args"][-1], "-vet")

    def test_concurrent_output_paths_are_unique_and_under_home(self):
        outputs = []
        for _ in range(2):
            result = self.run_script("test", "src/lib/jsonx")
            self.assertEqual(result.returncode, 0, result.stderr)
            args = json.loads(self.capture.read_text())["args"]
            output = Path(next(arg[5:] for arg in args if arg.startswith("-out:")))
            self.addCleanup(output.parent.rmdir)
            self.assertTrue(output.is_relative_to(Path.home() / ".cache/heimdall-tests"))
            outputs.append(output)
        self.assertNotEqual(*outputs)

    def test_debug_build_prints_path_and_has_debug_symbols(self):
        result = self.run_script("build-debug", "src/lib/jsonx")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(self.capture.read_text())["args"]
        self.assertEqual(args[0], "build")
        self.assertIn("-debug", args)
        self.assertIn("-o:none", args)
        self.assertIn(f"-out:{result.stdout.strip()}", args)
        self.addCleanup(Path(result.stdout.strip()).parent.rmdir)

    def test_run_preserves_arguments_and_compiler_exit_status(self):
        result = self.run_script("run", "src/ctl", "--", "--help", ODIN_EXIT="7")
        self.assertEqual(result.returncode, 7)
        args = json.loads(self.capture.read_text())["args"]
        self.assertEqual(args[-2:], ["--", "--help"])
        self.addCleanup(Path(next(arg[5:] for arg in args if arg.startswith("-out:"))).parent.rmdir)

    def test_invalid_action_or_outside_package_never_runs_odin(self):
        for args in [("delete", "src/ctl"), ("check", str(self.tmpdir)), ("check", "missing")]:
            result = self.run_script(*args)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertFalse(self.capture.exists())


if __name__ == "__main__":
    unittest.main()
