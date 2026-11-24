"""Populated, isolated SQLite action query benchmark; never opens a live DB."""
import pathlib, re, sqlite3, statistics, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
MIG = ROOT / "src/hub/repository/sqlite/migrations"
def sqls(filename):
    source = (ROOT / "src/hub/repository/sqlite" / filename).read_text()
    cols = re.search(r'PIPELINE_COLUMNS :: "([^"]+)"', source)
    result = {}
    for name, expr in re.findall(r'^(\w+)\s*::\s*((?:"[^"\n]*"|\s*\+\s*|PIPELINE_COLUMNS)+)', source, re.M):
        if cols: expr = expr.replace("PIPELINE_COLUMNS", '"' + cols[1] + '"')
        result[name] = "".join(re.findall(r'"([^"]*)"', expr))
    return result
A, P = sqls("action_repo_sqlite.odin"), sqls("pipeline_delivery_repo_sqlite.odin")
db = sqlite3.connect(":memory:")
for name in ("actions_001_reset.sql", "pipeline_001_deliveries.sql"):
    db.executescript((MIG/name).read_text())
# 1,000 actions x 200 terminal rows, plus 1,000 open runs and 20k open deliveries.
db.executemany("INSERT INTO actions(action_id,owner_user_id,prompt_text,target_kind,created_at,updated_at) VALUES(?, 'owner','p','instance','2026-01-01','2026-01-01')",
               [(f"a{i}",) for i in range(1000)])
def runs(start, count):
    return [(f"r{i:09}", f"a{i%1000}", f"o{i}", "delivered" if i < 200000 or i >= 300000 else ("queued" if i%2 else "deferred"),
             "2026-02-01" if i%4 else "2027-01-01", f"2026-01-{1+i%28:02}T00:00:00Z", "2026-01-01")
            for i in range(start,start+count)]
insert = "INSERT INTO action_runs(run_id,action_id,trigger_id,owner_user_id,occurrence_key,event_type,state,not_before,created_at,started_at) VALUES(?,?,'t','owner',?,'event',?,?,?,?)"
db.executemany(insert, runs(0,201000))
db.executemany("INSERT INTO pipeline_deliveries(delivery_id,owner_user_id,kind,bridge_id,agent_instance_id,ref,state,expires_at,created_at,updated_at) VALUES(?,'owner','prompt','bridge','instance','ref',?,'2027-01-01',?,'2026-01-01')",
               [(f"d{i:09}", "routed" if i%2 else "forwarded", f"2026-01-{1+i%28:02}T00:00:00Z") for i in range(20000)])
db.commit()
queries = [(n,A[n], p) for n,p in (
    ("ACTIONS_SQL_RUNS_DUE", ("2026-06-01",64)),
    ("ACTIONS_SQL_RUNS_DEFERRED",(64,)),
    ("ACTIONS_SQL_RUNS_LIST",("a0","",100,"")),
    ("ACTIONS_SQL_RUN_LAST_STARTED_AT",("a0",)),
    ("ACTIONS_SQL_RUNS_PRUNE",("a0","2025-01-01",200)))]
queries.append(("ACTIONS_SQL_SWEEP",A["ACTIONS_SQL_SWEEP"],("2026-01-15",128)))
queries.append(("PIPELINE_PRUNE_SQL",P["PIPELINE_PRUNE_SQL"],("2026-02-01",)))
queries.append(("PIPELINE_OPEN_BRIDGE_SQL",P["PIPELINE_OPEN_BRIDGE_SQL"],("bridge","",100)))
def report(label):
    print(label, "rows: actions=1000 runs=201000 deliveries=20000")
    for name,query,params in queries:
        print(name, "; ".join(r[3] for r in db.execute("EXPLAIN QUERY PLAN "+query,params)))
        samples=[]
        for _ in range(15):
            db.execute("SAVEPOINT bench")
            start=time.perf_counter()
            list(db.execute(query,params))
            samples.append((time.perf_counter()-start)*1000)
            db.execute("ROLLBACK TO bench"); db.execute("RELEASE bench")
        print(f"  median_ms={statistics.median(samples):.3f}")
    start=time.perf_counter()
    db.execute("SAVEPOINT writes")
    db.executemany(insert, runs(300000,10000))
    write_ms=(time.perf_counter()-start)*1000
    db.execute("ROLLBACK TO writes");db.execute("RELEASE writes")
    print(f"  10000 run inserts_ms={write_ms:.1f}; pages={db.execute('PRAGMA page_count').fetchone()[0]}")
    db.execute("SAVEPOINT delivery_writes")
    start=time.perf_counter()
    db.executemany("INSERT INTO pipeline_deliveries(delivery_id,owner_user_id,kind,bridge_id,agent_instance_id,ref,state,expires_at,created_at,updated_at) VALUES(?,'owner','prompt','bridge','instance','ref','routed','2027-01-01','2026-01-01','2026-01-01')",[(f"new{i}",) for i in range(10000)])
    print(f"  10000 delivery inserts_ms={(time.perf_counter()-start)*1000:.1f}")
    db.execute("ROLLBACK TO delivery_writes");db.execute("RELEASE delivery_writes")
report("BEFORE")
# Candidate indexes only; measured before deciding the migration.
db.executescript((MIG/"actions_003_history_performance.sql").read_text())
report("AFTER")
