#!/usr/bin/env python3
"""Regression test for CT-40: Default HAM_HUB_URL to http://127.0.0.1:8989 in agent run dir ham-ctl shim & wrapper."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP_ODIN = ROOT / "src" / "bridge" / "bootstrap_service.odin"
PACKAGE_SCRIPT = ROOT / "scripts" / "package-cloudtop-bundle.sh"
CITC_README = Path("/google/src/cloud/tanmayvijay/heimdall/google3/experimental/users/tanmayvijay/heimdall-bin/README.md")


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


def main() -> None:
    print("=== CT-40 Bridge Bootstrap HAM_HUB_URL Test Suite ===")

    # 1. Verify bootstrap_service.odin
    require(BOOTSTRAP_ODIN.exists(), f"bootstrap_service.odin must exist at {BOOTSTRAP_ODIN}")
    bootstrap_text = BOOTSTRAP_ODIN.read_text(encoding="utf-8")

    require("bridge_bootstrap_render_ham_ctl_shim :: proc" in bootstrap_text, "bridge_bootstrap_render_ham_ctl_shim must exist")
    require("bridge_bootstrap_write_ham_ctl_wrapper :: proc" in bootstrap_text, "bridge_bootstrap_write_ham_ctl_wrapper must exist")

    # Check that export HAM_HUB_URL=${HAM_HUB_URL:-...} is present in both procs
    render_idx = bootstrap_text.find("bridge_bootstrap_render_ham_ctl_shim :: proc")
    write_idx = bootstrap_text.find("bridge_bootstrap_write_ham_ctl_wrapper :: proc")

    render_body = bootstrap_text[render_idx:write_idx]
    write_body = bootstrap_text[write_idx:write_idx + 1500]

    for body, name in [(render_body, "bridge_bootstrap_render_ham_ctl_shim"), (write_body, "bridge_bootstrap_write_ham_ctl_wrapper")]:
        require('strings.write_string(&b, "export HAM_HUB_URL=${HAM_HUB_URL:-")' in body,
                f"{name} must write 'export HAM_HUB_URL=${{HAM_HUB_URL:-'")
        require('bridge_bootstrap_shell_quote(&b, hub_url)' in body,
                f"{name} must shell-quote hub_url")
        require('strings.write_string(&b, "}\\n")' in body,
                f"{name} must close the parameter expansion with '}}\\n'")
        require('"http://127.0.0.1:8989"' in body,
                f"{name} must default hub_url to 'http://127.0.0.1:8989'")
        require('os.get_env_alloc("HAM_HUB_URL"' in body,
                f"{name} must read HAM_HUB_URL from env")
        require('os.get_env_alloc("HEIMDALL_HUB_URL"' in body,
                f"{name} must read HEIMDALL_HUB_URL as fallback from env")

    print("[+] Verified src/bridge/bootstrap_service.odin exports dynamic HAM_HUB_URL with http://127.0.0.1:8989 default in both shim and wrapper!")

    # 2. Verify package-cloudtop-bundle.sh documentation
    require(PACKAGE_SCRIPT.exists(), f"package-cloudtop-bundle.sh must exist at {PACKAGE_SCRIPT}")
    package_text = PACKAGE_SCRIPT.read_text(encoding="utf-8")
    require("HAM_HUB_URL" in package_text and "http://127.0.0.1:8989" in package_text,
            "package-cloudtop-bundle.sh README template must document HAM_HUB_URL and http://127.0.0.1:8989")
    print("[+] Verified scripts/package-cloudtop-bundle.sh documents HAM_HUB_URL default!")

    # 3. Verify CitC depot README.md
    if CITC_README.exists():
        citc_text = CITC_README.read_text(encoding="utf-8")
        require("HAM_HUB_URL" in citc_text and "http://127.0.0.1:8989" in citc_text,
                "CitC README.md must document HAM_HUB_URL and http://127.0.0.1:8989")
        print("[+] Verified CitC depot README.md documents HAM_HUB_URL default!")

    print("[+] ALL CT-40 CHECKS PASSED")


if __name__ == "__main__":
    main()
