from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
JSON = (ROOT / "src/daemon/json.odin").read_text(encoding="utf-8")


def require(condition: bool, message: str):
    if not condition:
        print(f"FAIL: {message}")
        sys.exit(1)

require('for search_start < len(body)' in JSON, 'json_value_start must continue past quoted values that are not object keys')
require('search_start = idx + len(pattern)' in JSON, 'json_value_start must advance after non-key quoted matches')
require("body[pos] == ':'" in JSON, 'json_value_start must only accept quoted matches followed by colon')

print('json_value_start_static: ok')
