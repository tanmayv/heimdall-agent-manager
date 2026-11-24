"""Print EXPLAIN plans for production action/delivery SQL on an empty schema.

Run from the checkout root; no production DB access or data writes.
"""
import pathlib
import re
import sqlite3

root = pathlib.Path(__file__).resolve().parents[1]
db = sqlite3.connect(":memory:")
for name in ("actions_001_reset.sql", "pipeline_001_deliveries.sql", "events_001_outbox.sql"):
    db.executescript((root / "src/hub/repository/sqlite/migrations" / name).read_text())
for filename, prefix in (("action_repo_sqlite.odin", "ACTIONS_SQL_"), ("pipeline_delivery_repo_sqlite.odin", "PIPELINE_")):
    source = (root / "src/hub/repository/sqlite" / filename).read_text()
    columns = re.search(r'PIPELINE_COLUMNS :: "([^"]+)"', source)
    for name, expression in re.findall(r'^(\w+)\s*::\s*((?:"[^"\n]*"|\s*\+\s*|PIPELINE_COLUMNS)+)', source, re.M):
        if not name.startswith(prefix) or "SELECT " not in expression and "DELETE " not in expression:
            continue
        if columns:
            expression = expression.replace("PIPELINE_COLUMNS", '"' + columns[1] + '"')
        query = "".join(re.findall(r'"([^"]*)"', expression))
        if not query.startswith(("SELECT ", "DELETE ")):
            continue
        parameters = max([int(n) for n in re.findall(r'\?(\d+)', query)] or [0])
        print(name)
        for row in db.execute("EXPLAIN QUERY PLAN " + query, [""] * parameters):
            print("  ", row[3])
