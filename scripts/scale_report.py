#!/usr/bin/env python3
"""Render Scale H harness results (scripts/scale-harness.sh) as Markdown tables.

    python3 scripts/scale_report.py <new.json> [<old.json>]

With two files the tables compare them (new first, old second, then old/new).
The prose and the recommendation are written by hand around these tables.
"""
import json
import sys

KINDS = [
    ("lease_next_none", "lease next (none)"),
    ("lease_next_waiting", "lease next (waiting)"),
    ("lease_next_current", "lease next (current)"),
    ("lease_next_granted", "lease next (inline grant)"),
    ("submit", "submit"),
    ("review", "review approve"),
    ("grant", "grant (any event that granted)"),
    ("bridge_offline", "bridge offline (instance terminal)"),
    ("bridge_hello", "bridge hello"),
    ("timers", "timer pass"),
]


def load(path):
    with open(path) as f:
        return json.load(f)


def fmt(v, digits=1):
    if v is None:
        return "–"
    if isinstance(v, float) and digits == 0:
        return f"{v:,.0f}"
    if isinstance(v, float):
        return f"{v:,.{digits}f}"
    return f"{v:,}"


def ratio(new, old):
    if new is None or old is None or new == 0:
        return "–"
    return f"{old / new:.1f}x"


def get(d, *path):
    for p in path:
        if d is None or p not in d:
            return None
        d = d[p]
    return d


def table(headers, rows):
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join(" --- " for _ in headers) + "|"]
    out += ["| " + " | ".join(r) + " |" for r in rows]
    return "\n".join(out)


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    new = load(sys.argv[1])
    old = load(sys.argv[2]) if len(sys.argv) > 2 else None
    a, b = new["label"], (old["label"] if old else None)
    out = []
    out.append(f"Runs: **{a}**" + (f" vs **{b}**" if b else "") +
               f"; {new['chains']} chains x {new['tasks_per_chain']} tasks, {new['threads']} callers x {new['ops_per_thread']} events, "
               f"{new['serial_ops']} serial events, database `{new['db']}`.\n")

    # reads per event (serial)
    out.append("#### Reads per event (serial phase, mean per event)\n")
    rows = []
    for key, name in KINDS:
        n = get(new, "serial", key)
        o = get(old, "serial", key) if old else None
        if n is None and o is None:
            continue
        row = [name, fmt(get(n, "n"), 0) if n else "–"]
        for f in ("repo_reads", "task_rows", "selects", "vm_steps", "writes"):
            row.append(fmt(get(n, f), 0 if f == "vm_steps" else 1) if n else "–")
            if old:
                row.append(fmt(get(o, f), 0 if f == "vm_steps" else 1) if o else "–")
        rows.append(row)
    if old:
        hdr = ["event", "n", f"repo reads {a}", f"repo reads {b}", f"task rows {a}", f"task rows {b}",
               f"SELECTs {a}", f"SELECTs {b}", f"SELECT VM steps {a}", f"SELECT VM steps {b}", f"writes {a}", f"writes {b}"]
    else:
        hdr = ["event", "n", "repo reads", "task rows", "SELECTs", "SELECT VM steps", "writes"]
    out.append(table(hdr, rows) + "\n")

    def latency_table(section, title):
        out.append(f"#### {title}\n")
        rows = []
        for key, name in KINDS:
            n = get(new, *section, key)
            o = get(old, *section, key) if old else None
            if n is None and o is None:
                continue
            row = [name, f"{fmt(get(n, 'n'), 0) if n else '–'}" + (f" / {fmt(get(o, 'n'), 0)}" if o else "")]
            for f in ("p50_ms", "p95_ms", "p99_ms"):
                row.append(fmt(get(n, f), 1) if n else "–")
                if old:
                    row.append(fmt(get(o, f), 1) if o else "–")
            row.append(fmt(get(n, "lock_wait_ms"), 1) if n else "–")
            if old:
                row.append(fmt(get(o, "lock_wait_ms"), 1) if o else "–")
            rows.append(row)
        if old:
            hdr = ["event", "n", f"p50 {a}", f"p50 {b}", f"p95 {a}", f"p95 {b}", f"p99 {a}", f"p99 {b}",
                   f"mean lock wait {a}", f"mean lock wait {b}"]
        else:
            hdr = ["event", "n", "p50", "p95", "p99", "mean lock wait"]
        out.append("All times in ms.\n")
        out.append(table(hdr, rows) + "\n")

    latency_table(("concurrent", "by_kind"), "Latency under concurrent load")
    latency_table(("serial",), "Latency with one caller (serial phase)")

    # throughput + locks
    out.append("#### Throughput and lock waits (concurrent phase)\n")
    rows = []
    for label, d in ((a, new), (b, old)):
        if d is None:
            continue
        c = d["concurrent"]
        rows.append([label, fmt(c["wall_ms"] / 1000, 1), fmt(c["events"], 0), fmt(c["events_per_s"], 1), fmt(c["grants_pushed"], 0)])
    out.append(table(["run", "wall s", "events", "events/s", "grants pushed"], rows) + "\n")
    rows = []
    for label, d in ((a, new), (b, old)):
        if d is None:
            continue
        for lock, p in d["concurrent"]["locks"].items():
            rows.append([label, f"`{lock}`", fmt(p["acquisitions"], 0), fmt(p["contended"], 0), fmt(p["wait_ms"], 1), fmt(p["max_wait_ms"], 1),
                         f"{100 * p['wait_share_of_caller_time']:.2f}%", fmt(p["hold_ms"], 1), f"{100 * p['hold_share_of_wall']:.1f}%"])
    out.append(table(["run", "lock", "acquisitions", "contended", "wait ms", "max wait ms", "wait share of caller time", "hold ms", "hold share of wall"], rows) + "\n")

    # boot
    out.append("#### Boot\n")
    rows = []
    sizes = [x["done_tasks"] for x in new.get("boot", [])]
    oldboot = {x["done_tasks"]: x for x in (old.get("boot", []) if old else [])}
    for x in new.get("boot", []):
        y = oldboot.get(x["done_tasks"])
        row = [fmt(x["done_tasks"], 0), fmt(x["events"], 0)]
        for f in ("rebuild_timers_ms", "rebuild_timers_selects", "boot_ms", "boot_selects"):
            row.append(fmt(x[f], 0 if f.endswith("selects") else 1))
            if old:
                row.append(fmt(y[f], 0 if f.endswith("selects") else 1) if y else "–")
        rows.append(row)
    if old:
        hdr = ["done tasks", "events", f"rebuild_timers ms {a}", f"rebuild_timers ms {b}", f"rebuild SELECTs {a}", f"rebuild SELECTs {b}",
               f"boot ms {a}", f"boot ms {b}", f"boot SELECTs {a}", f"boot SELECTs {b}"]
    else:
        hdr = ["done tasks", "events", "rebuild_timers ms", "rebuild SELECTs", "boot ms", "boot SELECTs"]
    out.append(table(hdr, rows) + "\n")

    # Rematch storm (first timer tick after boot + 60 s)
    storms = [(r["label"], x) for r in ([new] + ([old] if old else [])) for x in r.get("boot", []) if x.get("storm_fired", -1) >= 0]
    if storms:
        out.append("#### Rematch storm (first timer tick 61 s after boot, one arena)\n")
        rows = [[lbl, fmt(x["done_tasks"], 0), fmt(x["storm_fired"], 0), fmt(x["storm_ms"], 0),
                 fmt(x["storm_ms"] / x["storm_fired"], 1) if x["storm_fired"] else "–", fmt(x["storm_rss_mb"], 0),
                 fmt(x["storm_rss_mb"] / x["storm_fired"], 2) if x["storm_fired"] else "–"] for lbl, x in storms]
        out.append(table(["run", "done tasks", "timers fired", "tick ms", "ms per timer", "RSS growth MB", "MB per timer"], rows) + "\n")

    ov = new.get("lock_profile_overhead_ns")
    if ov:
        out.append(f"Lock profile cost per uncontended lock/unlock ({a}): plain `sync.mutex_lock` {ov['plain']:.1f} ns, "
                   f"profile off {ov['profile_off']:.1f} ns, profile on {ov['profile_on']:.1f} ns.\n")
    print("\n".join(out))


if __name__ == "__main__":
    main()
