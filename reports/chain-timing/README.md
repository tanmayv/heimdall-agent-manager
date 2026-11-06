# Chain timing report

Fixed measurement cutoff: 2026-11-06T14:44:57Z. Task: task_18e57c093d7a659a, requirements revision 2.

- Primary mobile HTML bundle: artifact://art_18e57d548dfac334
- Frozen sanitized JSON data: artifact://art_18e57d584e70b423
- Standalone Markdown: artifact://art_18e57d5e4e5bb524
- CSV is included in the HTML bundle.

The report/data are a frozen snapshot, not a live dashboard. Independent task review is required.
The committed files are reports and analysis/render/validation scripts only; no application implementation changed.

## Reproduction

The raw authorized task/facet/comment and shell-list snapshots remain on the measurement Bridge at
/home/tanmay/.cache/heimdall-chain-timing-20261106. Their hashes are included in the frozen JSON.
The raw snapshots and generated JSON/CSV are intentionally not committed; no private shell output logs are packaged.

With that cache, run from the repository worktree:

~~~bash
python3 reports/chain-timing/analyze.py --snapshot /home/tanmay/.cache/heimdall-chain-timing-20261106
python3 reports/chain-timing/render.py
python3 reports/chain-timing/validate.py --metrics reports/chain-timing/metrics.json --snapshot /home/tanmay/.cache/heimdall-chain-timing-20261106
~~~

Without the cache, download the frozen JSON artifact and place it at reports/chain-timing/metrics.json,
then render and validate without --snapshot. Rendering needs tasks.csv, which can be extracted from the
HTML artifact alongside the JSON. Validation recomputes the interval unions using an independent
event-sweep algorithm and compares Git objects directly. It does not import analyze.py.

collect.py documents live collection, including the large-page shell-list workaround. A live recollection
cannot recreate historical overwritten facets, and must not replace the frozen cutoff data silently.

## Verified evidence

- Validator passes for all 25 tasks, 1,506 unique shell records, exact phase arithmetic, all 40 accepted commits
  and nine copied-commit mappings. Net task line deltas reconcile exactly to accepted chain net +20,476.
- Static links, task anchors, no-JS/no-remote constraints and packaged data equality pass.
- Chromium headless 360×1100 screenshot visually inspected; readable single-column summary/cards.
- All three artifacts downloaded successfully; JSON and Markdown compare byte-for-byte. Every HTML ZIP
  member compares to its source, and heimdall-artifact.json selects index.html.
- Final report explicitly marks unavailable exact closed-review/hold/block/outage durations, command
  categories, subprocess-runtime/launch-queue split, uncommitted C1b changes, token usage and cost.
- No application build/test rerun: this task changes reporting/scripts only. Runtime correctness claims
  are attributed to historical evidence and are not new blanket-green claims.
