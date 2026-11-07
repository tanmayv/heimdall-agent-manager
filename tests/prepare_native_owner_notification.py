"""Prepare only inspected SessionStart invocation flags; never edit native settings."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tomllib


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--ctl", type=Path, required=True)
    parser.add_argument("--codex", type=Path, required=True)
    args = parser.parse_args()
    native_home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    config_path = native_home / "config.toml"
    config = tomllib.loads(config_path.read_text()) if config_path.exists() else {}
    if (native_home / "hooks.json").exists() or any(key[:1].isupper() for key in config.get("hooks", {})):
        raise SystemExit("unreviewed user hook source present; refuse invocation trust flag")
    source = Path(__file__).resolve().parents[1] / "extensions/codex/hooks/hooks.json"
    command = json.loads(source.read_text())["hooks"]["SessionStart"][0]["hooks"][0]["command"]
    invocation = 'hooks.SessionStart=[{hooks=[{type="command",command=' + json.dumps(command) + ',timeout=5}]}]'
    flags = ["--no-alt-screen", "--sandbox", "read-only", "-c", "check_for_update_on_startup=false",
             "--dangerously-bypass-hook-trust", "-c", invocation]
    for plugin in config.get("plugins", {}):
        flags += ["-c", "plugins." + json.dumps(plugin) + ".enabled=false"]
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(flags))
    manifest = {
        "scope": "private_test_session_only_no_saved_trust",
        "arguments": flags,
        "native_config": str(config_path),
        "native_config_sha256": hashlib.sha256(config_path.read_bytes()).hexdigest() if config_path.exists() else None,
        "sha256": {
            str(path): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in (source, args.ctl.resolve(), args.codex.resolve(), args.out)
        },
    }
    args.out.with_suffix(".manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
