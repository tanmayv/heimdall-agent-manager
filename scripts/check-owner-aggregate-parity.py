#!/usr/bin/env python3
"""Check that the C1 ledger accounts for every field of the original aggregate."""
from pathlib import Path
import re
import json

SOURCES = (
    "src/hub/domain/taskchain.odin",
    "src/hub/domain/taskv2.odin",
    "src/hub/domain/workflow_run.odin",
    "src/hub/domain/mixed_work.odin",
)
# Read-only projections are documented as such in the ledger introduction.
PROJECTIONS = {
    "Task_Chain_Search_Change", "Task_Comment_Page_Item", "Task_Comment_Summary",
}
expected = {}
for source in SOURCES:
    current = None
    for line_no, line in enumerate(Path(source).read_text().splitlines(), 1):
        declaration = re.match(r"(\w+) :: struct \{\s*$", line)
        if declaration:
            current = declaration[1]
            continue
        if line.strip() == "}":
            current = None
        if not current or current in PROJECTIONS or line.lstrip().startswith("//"):
            continue
        member = re.match(r"\s*([\w,]+)\s*:", line)
        if member:
            for field in member[1].split(","):
                expected[(current, field)] = f"{source}:{line_no}"

actual = {}
statuses = {}
current = None
for line in Path("docs/owner-local-aggregate-parity.md").read_text().splitlines():
    if line.startswith("### "):
        current = line[4:]
    row = re.match(r"\| `(\w+)` \| `([^\x60]+)` \|", line)
    if row:
        key = (current, row[1])
        if key in actual:
            raise SystemExit(f"Duplicate ledger field: {key}")
        actual[key] = row[2]
        statuses[key] = line
missing = expected.keys() - actual.keys()
extra = actual.keys() - expected.keys()
stale = {k for k in expected.keys() & actual.keys() if expected[k] != actual[k]}
if missing or extra or stale:
    raise SystemExit(f"Aggregate ledger mismatch: missing={sorted(missing)}, extra={sorted(extra)}, stale citations={sorted(stale)}")
# Structural evidence is a gate, not a substitute for the recorded executed
# import/export/rollback/restart tests. Fail closed on any missing field value,
# route, storage path, test anchor, or unapproved milestone.
evidence = json.loads(Path("docs/owner-local-parity-evidence.json").read_text())
fixture = json.loads(Path(evidence["fixture"]).read_text())
structs = evidence["structs"]
native_structs = {name for name, _ in expected}
if set(structs) != native_structs or set(fixture["structs"]) != native_structs:
    raise SystemExit("Native struct / fixture / evidence sets differ")
bundles = {entry["kind"]: json.loads(entry["raw"]) for entry in fixture["metadata"]}
history = json.loads(fixture["history"])
sql = "\n".join(path.read_text() for path in Path("src/lib/owner_local").glob("*.sql"))

def anchor(value):
    path, number = value.rsplit(":", 1)
    lines = Path(path).read_text().splitlines()
    if not 1 <= int(number) <= len(lines):
        raise SystemExit(f"Invalid evidence anchor: {value}")
    return lines[int(number)-1]

def records_for(key):
    if key.startswith("history:"):
        return [json.loads(raw) for raw in json.loads(history[key.split(":")[1]+"s"])]
    if key == "nested:fleet.bridge_models_json":
        return [model for row in bundles["fleet"]["records"] for model in json.loads(row["bridge_models_json"]).values()]
    if key == "nested:work_dependency.dependent":
        return [row["dependent"] for row in bundles["work_dependency"]["records"]]
    return bundles[key]["records"]

for name, item in structs.items():
    names = {field for struct, field in expected if struct == name}
    original = {field: source for (struct, field), source in expected.items() if struct == name}
    if item["status"] != "CANONICAL" or item["source"] != original or set(item["storage"]) != names:
        raise SystemExit(f"Incomplete canonical evidence: {name}")
    if item["fixture_key"] != fixture["structs"][name]:
        raise SystemExit(f"Fixture binding mismatch: {name}")
    records = records_for(item["fixture_key"])
    if not records or any(not names <= set(record) for record in records):
        raise SystemExit(f"Fixture is missing original field values: {name}")
    for field in names:
        row = statuses[(name, field)]
        if "**CANONICAL**" not in row or re.search(r"\b(?:OPEN|PARTIAL)\b", row):
            raise SystemExit(f"Unresolved required ledger row: {name}.{field}")
        table, column = item["storage"][field].split(".", 1)
        column = re.split(r"[.\[]", column, maxsplit=1)[0]
        declaration = re.search(r"CREATE TABLE "+re.escape(table)+r"\s*\((.*?)\n\);", sql, re.S)
        if not declaration or not re.search(r"\b"+re.escape(column)+r"\b", declaration[1]):
            raise SystemExit(f"Missing storage mapping: {name}.{field} -> {item['storage'][field]}")
    if "aggregate_export_compare ::" not in anchor(item["comparison"]):
        raise SystemExit(f"Missing actual all-value comparison: {name}")
    if "aggregate_rich_all_structs_import_export_exact_restart_replay_and_no_authority ::" not in anchor(item["proof"]):
        raise SystemExit(f"Missing signed round-trip/restart proof: {name}")
    anchor(item["implementation"])
    if item["import_method"] not in {"native.metadata.import", "native.history.import"}:
        raise SystemExit(f"Missing signed import route: {name}")
    if item["export_method"] not in {"native.metadata.read", "native.history.read/fetch"}:
        raise SystemExit(f"Missing bounded export route: {name}")

# The complete native brief vocabulary is present, not just an empty brief_json.
brief_line = next(line for line in Path("src/hub/service/taskv2/brief_schema.odin").read_text().splitlines() if line.startswith("BRIEF_KEYS :="))
brief_keys = set(re.findall(r'"([^"]+)"', brief_line))
if set(json.loads(fixture["operational_brief"])) != brief_keys:
    raise SystemExit("Rich fixture does not cover the full original brief vocabulary")

contracts = Path("src/contracts/owner_local.odin").read_text()
method_body = contracts.split("owner_method_valid ::")[1].split("owner_field_valid ::")[0]
methods = set(re.findall(r'"([a-z_]+(?:\.[a-z_]+)+)"', method_body))
covered = set()
tests = "\n".join(path.read_text() for path in Path("src/lib/owner_local").glob("*test.odin"))
for family in evidence["command_families"]:
    if family["status"] != "CANONICAL" or not family["methods"]:
        raise SystemExit("Unresolved command family")
    anchor(family["original"])
    if ":: proc(t:^testing.T)" not in anchor(family["proof"]):
        raise SystemExit("Command family lacks an executable test anchor")
    for method in family["methods"]:
        if f'"{method}"' not in tests:
            raise SystemExit(f"No command exercise in the executed owner test suite: {method}")
        if method not in evidence["method_exercises"] or f'"{method}"' not in anchor(evidence["method_exercises"][method]):
            raise SystemExit(f"Missing command-specific exercise anchor: {method}")
        covered.add(method)
if methods - covered:
    raise SystemExit(f"Signed methods without a canonical family: {sorted(methods-covered)}")
if "aggregate_signed_workflow_source_inventories_survive_restart_and_revoke ::" not in anchor(evidence["inventory_proof"]):
    raise SystemExit("Missing signed inventory restart/revocation proof")
milestones = evidence["external_milestones"]
if {item["id"] for item in milestones} != {"C3", "M3", "M4"} or len(milestones) != 3:
    raise SystemExit("Unapproved external disposition")
if any(item["approved_by"] != evidence["scope_decision"] or not item["scope"] for item in milestones):
    raise SystemExit("External milestone lacks explicit scope decision")
if evidence["scope_decision"] != "cmt_18e592e4d810d71a":
    raise SystemExit("Scope decision must be reviewed explicitly")
print(f"PASS: {len(expected)} original fields / {len(native_structs)} structs, exact fixture values and canonical storage/routes/proof anchors; {len(methods)} signed methods; only explicit C3/M3/M4 milestones.")
