#!/usr/bin/env python3
"""Static regression for the Electron debug /upload-file endpoint (task-19f68af38b7).

The debug harness cannot drive a native file chooser or clipboard paste, which
blocked independent validation of UI artifact create/upload. The /upload-file
endpoint injects a synthetic File into a real artifact upload <input type=file>
and dispatches a genuine change event so the production upload path runs.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
DBG = (ROOT / "src/ui/electron/debugServer.cts").read_text(encoding="utf-8")


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


require("path: '/upload-file'," in DBG, "debug server must expose /upload-file endpoint")
require("el.type !== 'file'" in DBG, "endpoint must target a file input")
require("new File([bytes]" in DBG, "endpoint must build a File from provided/default content")
require("new DataTransfer()" in DBG, "endpoint must assign files via DataTransfer")
require("Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'files')" in DBG, "endpoint must set input.files through the native setter")
require("new Event('change', { bubbles: true })" in DBG, "endpoint must dispatch a real change event so the production onChange runs")
require("params.debug_id ?? params.debugId" in DBG, "endpoint should accept a debug_id target")
require("params.content_base64 ?? params.contentBase64" in DBG, "endpoint should accept optional base64 content")

print("PASS: debug upload-file endpoint static checks")
