#!/usr/bin/env python3
"""Render the frozen metrics as a mobile static report and Markdown fallback."""
import html,json,pathlib,shutil
from content import FINDINGS,IMPROVEMENTS,DEFINITIONS,LIMITS,DEMO_SOURCES
R=pathlib.Path(__file__).resolve().parent
d=json.loads((R/'metrics.json').read_text());T=d['totals'];tasks=d['tasks'];by={t['task_id']:t for t in tasks}
def e(x):return html.escape(str(x))
def dur(n):
 if n is None:return 'N/A'
 n=int(n);h,n=divmod(n,3600);m,s=divmod(n,60)
 return f'{h}h {m:02}m {s:02}s' if h else f'{m}m {s:02}s'
def mins(n):return 'N/A' if n is None else f'{n/60:.1f}'
def phases(t):return [('Pre-start wait',t['prestart_wait_seconds'],'queue'),('Attempt envelope',t['worker_runtime_facet_union_seconds'],'work'),('Review bounds',t['review_comment_bound_seconds'],'review'),('Unclassified after start',t['unclassified_since_start_seconds'] or 0,'unknown')]
def row(t):
 n=t['git']['retained_net'];s=t['shell']
 return [t['title']+' ('+t['task_id']+')',t['status'],mins(t['created_to_end_seconds']),mins(t['first_start_to_end_seconds']),mins(t['prestart_wait_seconds']),mins(t['worker_runtime_facet_union_seconds']),mins(t['review_comment_bound_seconds']),mins(t['unclassified_since_start_seconds']),str(n['files'])+(' committed; working N/A' if t['git']['partial_uncommitted_state_unknown'] else ''),str(n['added']),str(n['deleted']),str(s['count']),mins(s['sum_recorded_span_seconds']),mins(s['union_recorded_span_seconds'])]
HEAD=['Task','Status','Age min','First-start min','Pre-wait min','Attempt min','Review min','Gap min','Files','+LOC','−LOC','Shell count','Shell sum min','Shell union min']
summary="At the cutoff, the chain had elapsed11h57m26s: 15 tasks done, 2 cancelled, 7 queued and1 in progress. Its1,506 recorded shell sessions sum to3h57m26s, or3h16m20s after overlap. The accepted tree changes161 files, +20,621/−145 LOC. Scope expansion, serial implementation, real regressions and integration work explain measured delays; missing phase data prevents attributing all remaining time."
gitnote="Exact accepted net: ada2d4c8 → d78c6c54,161 files, +20,621/−145 = +20,476 lines. Integration bases remove inherited work: ec3bdaab→a1ff381b (M2c), a1ff381b→c04b5610 (compaction), c04b5610→6b076ac7 (workflow language). Other bases are the first owned commit's parent. Per-task new net line deltas reconcile to+20,476."
copynote="Old C1:6b076ac7→bfac0d0d,+2,784/−100 across49 files. Its nine commits were copied into C1a: bfac0d0d and4867e4fa have identical trees. C1a retained net is+2,875/−100; its new correction bfac0d0d→d78c6c54 is only+93/−2 across5 files. Count preserved work once."
grossnote="Deduplicated nonmerge authored gross churn:+21,234/−877 across157 unique paths. Merge resolution-only remerge diffs are separate diagnostics, not added to gross totals because they include synthetic conflict cleanup. Final accepted net is the authoritative unique-chain size."
scope="Ages run from creation to completion/cancellation or cutoff. First-start elapsed excludes pre-start wait. Attempt envelopes may span renewed leases/restarts; review bounds use comments, not exact closed leases. Task LOC rows show retained net and overlap for old C1/C1a. Queued tasks have waiting age, not completed duration."
top=sorted(d['shell_sessions'],key=lambda s:-s['recorded_span_seconds'])[:10]
fence=chr(96)*3
commands=['python3 reports/chain-timing/collect.py --cli /absolute/path/to/bin/ham-ctl --out /analysis/cache','python3 reports/chain-timing/analyze.py --snapshot /analysis/cache','python3 reports/chain-timing/render.py','python3 reports/chain-timing/validate.py --metrics reports/chain-timing/metrics.json','git diff --numstat -M ada2d4c8 d78c6c54','git diff --exit-code bfac0d0d 4867e4fa']
md=['# Where the chain time went','',summary,'','Cutoff: **2026-11-06T14:44:57Z** (20:14:57 IST). Chain: '+d['chain_id']+'.','',
'## Measured time','',
'- Chain wall age: **'+dur(d['chain_elapsed_seconds'])+'**.',
'- Shell span sum: **'+dur(T['shell_span_sum_seconds'])+'**; union: **'+dur(T['shell_span_union_seconds'])+'** ('+f'{T["shell_span_union_seconds"]/d["chain_elapsed_seconds"]:.1%}'+' of wall age).',
'- The other **'+dur(d['chain_elapsed_seconds']-T['shell_span_union_seconds'])+'** is unclassified by shell records, not measured thinking/idle time.',
'- Attempt envelopes: **'+dur(T['worker_runtime_facet_sum_seconds'])+'** summed; **'+dur(T['worker_runtime_facet_chain_union_seconds'])+'** union. Overlap duplicates **'+dur(T['worker_runtime_facet_sum_seconds']-T['worker_runtime_facet_chain_union_seconds'])+'**.',
'- Attribution: **163 high** (reference+agent window), **1,318 medium** (agent window), **25 unassigned** records (**41s** union). Known-instance/time-range totals remain provisional for ownership of the unassigned part.',
'- Shell union intersecting any attempt envelope: **'+dur(T['shell_worker_intersection_union_seconds'])+'**. Subprocess runtime, launch queue and CPU use: **N/A**.',
'','## Why it took this long','']
for title,body,source in FINDINGS:md+=['### '+title,'',body,'','Evidence: '+source+'.','']
md+=['## Every task at the cutoff','',scope,'','| '+' | '.join(HEAD)+' |','|'+'|'.join(['---']*2+['---:']*12)+'|']
for t in tasks:md.append('| '+' | '.join(row(t))+' |')
md+=['','## Git provenance and deduplication','',gitnote,'',copynote,'',grossnote,'',
'| Task | Net base → head | Files / + / − |','|---|---|---:|']
for t in tasks:
 g=t['git'];n=g['retained_net']
 if g['net_base']:md.append(f'| {t["title"]} | {g["net_base"][:8]} → {g["net_head"][:8]} | {n["files"]} / +{n["added"]} / −{n["deleted"]} |')
md+=['','| Final accepted category | Files | Added | Deleted |','|---|---:|---:|---:|']
for k,v in T['final_accepted_net']['categories'].items():md.append(f'| {k} | {v["files"]} | {v["added"]} | {v["deleted"]} |')
md+=['','## Largest ten recorded shell spans','','Nine documented real demos sum to34m12s; the tenth category is unknown (3m41s). These are wrapper spans; no nested stages are added. Context labels come from task evidence, not decrypted command metadata. Full build/test/install/Git/read category totals areN/A.','',
'| Session | Task | UTC start | Span | Exit | Evidence |','|---|---|---|---:|---:|---|']
for s in top:md.append(f'| {s["session_id"]} | {by[s["task_id"]]["title"]} | {s["started_at"]} | {dur(s["recorded_span_seconds"])} | {s["exit_code_at_cutoff"]} | {DEMO_SOURCES.get(s["session_id"],"category unavailable; agent-window only")} |')
md+=['','## Coverage and limits','','| Instance | Full page | Before chain | After cutoff | In range | has_more |','|---|---:|---:|---:|---:|---|']
for c in d['shell_coverage']:md.append(f'| {c["agent"]} | {c["raw_full_page_count"]} | {c["before_chain"]} | {c["after_cutoff"]} | {c["within_chain_time_range"]} | false |')
md+=['']+['- '+v for v in LIMITS]+['','## Metric definitions','']
md+=['- **'+k+':** '+v for k,v in DEFINITIONS]
md+=['','## Five improvements','']+[str(i)+'. **'+k+'** '+v for i,(k,v) in enumerate(IMPROVEMENTS,1)]
md+=['','## Reproduce and independently audit','',
'Frozen calculations: metrics.json; task summary: tasks.csv. Raw authorized CLI snapshots remain in the local analysis cache; SHA-256 digests are in metrics.json. Exact runtime facet IDs, review comment bounds, session IDs, Git parents/numstats and copy mappings support independent validation. No command output logs or credentials are packaged.','',fence+'bash']+commands+[fence,'',
'Collection is live and cannot recreate overwritten historical event versions. Use the frozen metrics artifact for this cutoff. Validator recomputes sums/unions and checks Git objects independently of the aggregation implementation. Independent review remains required; no self-approval is implied.']
# Improve numeral spacing without changing identifiers, source hashes or timestamps.
import re
def prose_spacing(s):
 s=re.sub(r'\b(elapsed|age|inside|contributes|to|across|and|or|Its|its|before|not|was|includes|The|their|Cutoff:|All|changes|tasks|of|after|from|with|is|sum|spans|those|are)(?=\d)',r'\1 ',s)
 s=re.sub(r'(?<=[hm])(?=\d)',' ',s)
 return s.replace('areN/A','are N/A').replace('isN/A','is N/A')
md=[prose_spacing(x) if not x.startswith(('|','python3','git ')) else x for x in md]
(R/'report.md').write_text('\n'.join(md)+'\n')
site=R/'site';site.mkdir(exist_ok=True)
for name in ['metrics.json','tasks.csv','report.md']:shutil.copyfile(R/name,site/name)
def para(s,cl=''):return '<p'+(' class="'+cl+'"' if cl else '')+'>'+e(prose_spacing(s))+'</p>'
def numbers(items):return '<div class="numbers">'+''.join('<div><strong>'+e(v)+'</strong><span>'+e(k)+'</span></div>' for k,v in items)+'</div>'
h=['<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Where the chain time went</title><link rel="stylesheet" href="style.css"></head><body><main>',
'<header><div class="eyebrow">Engineering delivery · measured snapshot</div><h1>Where the chain<br>time went</h1>'+para(summary,'lead')+'<p class="stamp">Cutoff <strong>6 November 2026 · 14:44:57 UTC</strong><br>20:14:57 IST · <code>'+e(d['chain_id'])+'</code></p></header>',
'<nav aria-label="Sections"><a href="#findings">Findings</a><a href="#tasks">All 25 tasks</a><a href="#shell">Shell evidence</a><a href="#git">Git provenance</a><a href="#limits">Limits</a><a href="#improvements">Improvements</a><a href="#data">Data &amp; audit</a></nav>',
'<section class="grid hero" aria-label="Summary metrics">']
for name,value,note in [('Chain wall-clock age','11h 57m','15 done · 2 cancelled · 7 queued · 1 active'),('Shell span, overlap removed','3h 16m','3h57m summed across1,506 session records'),('Accepted net change','161 files','+20,621 / −145 LOC · duplicate lineage excluded'),('Attribution gap','25 records','41 seconds remain unassigned')]:
 h.append('<article class="card"><span class="metric-label">'+e(name)+'</span><strong class="metric">'+e(value)+'</strong>'+para(note,'note')+'</article>')
h+=['</section><aside class="callout"><strong>Elapsed, sum and union are different.</strong> Elapsed is wall-clock age. Shell sum adds session spans; union removes overlap. Hub spans include launch and exit-delivery latency. Actual subprocess runtime, queue and CPU use are unknown. Remaining time is unclassified—not measured thinking or idle time.</aside>',
'<section id="findings"><h2>What kept the chain open</h2>']
for title,body,source in FINDINGS:h.append('<article class="card story"><h3>'+e(title)+'</h3>'+para(body)+para('Evidence: '+source,'source')+'</article>')
h+=['<h3>Measured spans compared</h3>'+para('These sets overlap. They are not slices to add together.','note')]
for name,n,cl in [('Chain elapsed',d['chain_elapsed_seconds'],'queue'),('Any worker attempt envelope',T['worker_runtime_facet_chain_union_seconds'],'work'),('Any recorded shell session',T['shell_span_union_seconds'],'review')]:
 h.append(f'<div class="rowbar"><p><span>{e(name)}</span><strong>{dur(n)}</strong></p><div class="bar"><span class="{cl}" style="width:{100*n/d["chain_elapsed_seconds"]:.3f}%"></span></div></div>')
h+=['</section><section id="tasks"><h2>Every task at the cutoff</h2>'+para(scope),
'<div class="legend"><span><i class="queue"></i>Pre-start wait</span><span><i class="work"></i>Attempt envelope</span><span><i class="review"></i>Review bounds</span><span><i class="unknown"></i>Unclassified</span></div>']
for t in tasks:
 g=t['git'];n=g['retained_net'];s=t['shell'];tid=t['task_id'];age=t['created_to_end_seconds']
 h.append('<article class="card task" id="'+tid+'"><div class="task-head"><h3>'+e(t['title'])+'</h3><span class="badge '+t['status']+'">'+e(t['status'].replace('backlog','queued').replace('_',' '))+'</span></div><code class="task-id">'+tid+'</code>')
 h.append(numbers([('Created-to-end / age',dur(age)),('First-start elapsed',dur(t['first_start_to_end_seconds'])),('Pre-start wait',dur(t['prestart_wait_seconds']))]))
 h.append('<div class="bar" role="img" aria-label="'+e('; '.join(k+': '+dur(v) for k,v,c in phases(t)))+'">'+''.join(f'<span class="{c}" style="width:{v/age*100:.3f}%"></span>' for k,v,c in phases(t) if v)+'</div>')
 h.append(numbers([('Files / + / −',f'{n["files"]} / +{n["added"]} / −{n["deleted"]}'),('Shell sum',dur(s['sum_recorded_span_seconds'])),('Shell union',dur(s['union_recorded_span_seconds']))]))
 if g['partial_uncommitted_state_unknown']:h.append(para('Partial snapshot:0 committed changes; uncommitted working delta is N/A.','note'))
 if tid=='task_18e57ad52bb4ea63':h.append(para('Copied lineage: retained row includes old C1 checkpoint. New correction only:5 files, +93/−2. Chain totals count preserved work once.','note'))
 h.append('<details><summary>Phase details and provenance</summary><ul>')
 for k,v,c in phases(t):h.append('<li>'+e(k)+': <strong>'+dur(v)+'</strong></li>')
 h.append(f'<li>{s["count"]} shell records; {s["nonzero_exit_count"]} nonzero exits. Confidence: <code>{e(json.dumps(s["confidence_counts"]))}</code>.</li><li>Shell union within attempt envelopes: {dur(s["worker_intersection_union_seconds"])}.</li>')
 h.append('<li>Created <code>'+t['created_at']+'</code>; first start <code>'+str(t['started_at'] or 'not started')+'</code>; completed/cancelled <code>'+str(t['completed_at'] or 'not terminal at cutoff')+'</code>.</li>')
 if g['net_base']:h.append('<li>Net base <code>'+g['net_base']+'</code> → head <code>'+g['net_head']+'</code>. '+e(g['net_baseline_reason'])+'.</li>')
 for att in t['attempts']:h.append(f'<li>Attempt {att["attempt"]}: <code>{att["runtime"]["started_at"]}</code> → <code>{att["runtime"]["ended_at"] or d["cutoff"]+" (clipped)"}</code>: {dur(att["clipped_seconds"])}. Source <code>{att["source"]}</code>.</li>')
 h.append('<li>Exact closed review-lease, hold/block/outage and launch/runtime splits: N/A. Review shown is comment-bound evidence only.</li></ul></details></article>')
h+=['<details><summary>Wide audit table (optional; scroll horizontally)</summary><div class="table-wrap"><table><thead><tr>'+''.join('<th>'+e(k)+'</th>' for k in HEAD)+'</tr></thead><tbody>']
for t in tasks:h.append('<tr>'+''.join('<td>'+e(x)+'</td>' for x in row(t))+'</tr>')
h+=['</tbody></table></div></details></section><section id="shell"><h2>The ten largest shell records</h2>'+para('Nine are documented real demos:34m12s of summed spans. The tenth has no command category. Each wrapper is counted once; child stages are not added.')]
for i,s in enumerate(top,1):
 h.append('<article class="top-session"><strong>'+f'{i:02} · '+dur(s['recorded_span_seconds'])+'</strong>'+para(by[s['task_id']]['title'])+'<code>'+s['session_id']+'</code>'+para(s['started_at']+' → '+s['end_at_cutoff']+' · exit '+str(s['exit_code_at_cutoff'])+' · '+s['confidence'],'source')+para('Demo evidence: '+DEMO_SOURCES.get(s['session_id'],'unknown command category; agent-window attribution only'),'source')+'</article>')
h+=['</section><section id="git"><h2>Code size without duplicate credit</h2>'+para(gitnote)+'<aside class="callout">'+para(copynote)+'</aside>'+para(grossnote)+'<div class="grid">']
for k,v in T['final_accepted_net']['categories'].items():h.append('<article class="card"><span class="metric-label">'+e(k)+'</span><strong class="metric">'+str(v['files'])+' files</strong>'+para(f'+{v["added"]:,} / −{v["deleted"]:,}')+'</article>')
h+=['</div></section><section id="limits"><h2>Coverage and honest gaps</h2><div class="grid">']
for c in d['shell_coverage']:h.append('<article class="card"><code>'+c['agent']+'</code>'+para(f'{c["raw_full_page_count"]} in full page · {c["within_chain_time_range"]} in cutoff range')+para(f'{c["after_cutoff"]} after cutoff · {c["before_chain"]} before chain · has_more=false','note')+'</article>')
h+=['</div><ul>']+['<li>'+e(prose_spacing(v))+'</li>' for v in LIMITS]+['</ul></section><section><h2>Metric definitions</h2><dl>']
for k,v in DEFINITIONS:h.append('<dt>'+e(k)+'</dt><dd>'+e(v)+'</dd>')
h+=['</dl></section><section id="improvements"><h2>Five changes worth making next</h2><ol>']
for k,v in IMPROVEMENTS:h.append('<li><strong>'+e(k)+'</strong> '+e(v)+'</li>')
h+=['</ol></section><section id="data"><h2>Data and independent audit</h2><p><a href="metrics.json">Frozen JSON metrics &amp; provenance</a> · <a href="tasks.csv">Task CSV</a> · <a href="report.md">Markdown report</a></p>'+para('JSON contains phase inputs, source IDs, shell records/confidence, Git parents/numstats, copy mappings and raw snapshot hashes. No private shell output or credentials are packaged. Reproduction commands are in the Markdown report.')+para('Independent review is the next gate; no self-approval is implied. Work on this report and later implementation activity are excluded.','note')+'</section><footer>Static HTML/CSS · no JavaScript or remote assets · UTC unless marked IST<br><code>'+d['chain_id']+'</code></footer></main></body></html>']
(site/'index.html').write_text('\n'.join(h))
print('Rendered',len(tasks),'task cards and Markdown.')
