#!/usr/bin/env python3
"""Reconstruct fixed-cutoff metrics from CLI snapshots and immutable Git objects.

No production mutation, command-log reads, or clock-based causal assumptions.
"""
import argparse,collections,csv,datetime as dt,hashlib,json,pathlib,re,subprocess
UTC=dt.timezone.utc
CUTOFF='2026-11-06T14:44:57Z'
CHAIN='chain_18e554c99be21d02'
WORKER='inst_18e554e13ee165a7'; SECOND='inst_18e568efd2a64539'
REVIEWERS={'inst_18e5568123390193','inst_18e569b6fc61248b'}
COORD='inst_18e554c99e0743ee'
def epoch(s): return dt.datetime.fromisoformat(s.replace('Z','+00:00')).timestamp() if s else None
def iso(n): return dt.datetime.fromtimestamp(n,UTC).isoformat().replace('+00:00','Z')
def union(xs):
 out=[]
 for a,b in sorted((a,b) for a,b in xs if b>a):
  if out and a<=out[-1][1]:out[-1][1]=max(b,out[-1][1])
  else:out.append([a,b])
 return out
def length(xs):return sum(b-a for a,b in union(xs))
def intersect(xs,ys):return union([(max(a,c),min(b,d)) for a,b in xs for c,d in ys if min(b,d)>max(a,c)])
def git(*args):
 return subprocess.run(['git',*args],check=True,capture_output=True,text=True).stdout
# Provenance: heads from immutable vcs facets; commit boundaries inspected against
# first-parent histories and task comments. Merge diffs are resolution-only.
GROUPS={
'task_18e554dbf43e7642':'f29900da 1c83a464',
'task_18e556f8ef2f0c8d':'',
'task_18e55714c3bb18ea':'b4b34929',
'task_18e55735054e37f6':'b367923a 47ee1544',
'task_18e55714d71968b1':'f4279e21 f4cd91d9',
'task_18e5571bd785f30b':'233014ae',
'task_18e55eb775acfc0f':'21072f5c',
'task_18e556f901cbcf41':'8e666616 6e87ca20',
'task_18e562f7a4bb62aa':'37495ef4',
'task_18e568efcfe3e1c6':'f3cc56d1',
'task_18e569e455cd82bb':'6bb3864d',
'task_18e569e4750fe9fd':'ec3bdaab',
'task_18e562f7b94d63bb':'47ee639f e718d41a bfc046da a1ff381b',
'task_18e56d155e88f266':'a94d452e 08aab988 c8ac5814 1145cff7 f82e9345 c04b5610',
'task_18e56a0d15295083':'b5c1b4a1 06b7b814 aadcc4a4 3b14fe5f 971a963d 6b076ac7',
'task_18e569e48d6b5532':'f2b0a40e d331951c fae3a837 a1e838d8 f437d5b7 7bb28ffc 6eea3fd5 a0f6b1c0 bfac0d0d',
'task_18e57ad52bb4ea63':'eb0053be e5722ce4 7f3e4347 610250e1 efa32cb8 d97c8d87 e9f02421 1d0ad3e2 4867e4fa d78c6c54'}
COPIES=dict(zip(GROUPS['task_18e57ad52bb4ea63'].split()[:-1],GROUPS['task_18e569e48d6b5532'].split()))
def numstat(text):
 rows=[]
 for line in text.splitlines():
  a,d,p=line.split('\t',2)
  rows.append({'path':p,'added':None if a=='-' else int(a),'deleted':None if d=='-' else int(d)})
 return rows
def category(p):
 if p.endswith(('_test.odin','_test.ts')) or p.startswith('tests/'):return 'tests'
 if p.startswith('docs/') or p.endswith('.md'):return 'docs'
 if p in {'src/contracts/owner_schema.odin','src/ui/api/ownerSchema.ts'}:return 'generated'
 return 'source/tooling'
def stat(rows):
 cats=collections.defaultdict(lambda:{'added':0,'deleted':0,'files':set()})
 for r in rows:
  z=cats[category(r['path'])];z['added']+=r['added'] or 0;z['deleted']+=r['deleted'] or 0;z['files'].add(r['path'])
 return {'files':len({r['path'] for r in rows}),'added':sum(r['added'] or 0 for r in rows),'deleted':sum(r['deleted'] or 0 for r in rows),'binary_entries':sum(r['added'] is None for r in rows),'categories':{k:{**v,'files':len(v['files'])} for k,v in cats.items()}}
def main():
 p=argparse.ArgumentParser();p.add_argument('--snapshot',required=True);p.add_argument('--out',default='reports/chain-timing');a=p.parse_args()
 raw=pathlib.Path(a.snapshot);out=pathlib.Path(a.out);out.mkdir(parents=True,exist_ok=True)
 def read(name):
  j=json.loads((raw/(name+'.json')).read_text())
  return j['data']['data'] if j.get('ok') else None
 cutoff=epoch(CUTOFF);chain=read('chain');origin=epoch(chain['created_at'])
 all_tasks=read('tasks');tasks=[t for t in all_tasks if epoch(t['created_at'])<=cutoff]
 after=[{'task_id':t['task_id'],'created_at':t['created_at'],'title':t['title']} for t in all_tasks if epoch(t['created_at'])>cutoff]
 results=[];comments={};windows=[];refs=collections.defaultdict(set);evidence=[]
 for t in tasks:
  tid=t['task_id'];cs=[c for c in read(tid+'-comments') if epoch(c['created_at'])<=cutoff];comments[tid]=cs
  worker=SECOND if tid in {'task_18e568efcfe3e1c6','task_18e569e455cd82bb','task_18e569e4750fe9fd','task_18e56d155e88f266'} else WORKER
  attempts=[]
  for n in range(1,t['attempt_no']+1):
   rt=read(f'{tid}-{n}-runtime');vc=read(f'{tid}-{n}-vcs');ho=read(f'{tid}-{n}-handoff')
   if rt:
    b=rt['body'];start=epoch(b['started_at']);end=min(epoch(b['ended_at']) or cutoff,cutoff)
    if start<=cutoff:
     windows.append({'task_id':tid,'agent':worker,'start':start,'end':end,'kind':'runtime_facet'})
     attempts.append({'attempt':n,'runtime':b,'source':f'facet:{tid}:{n}:runtime','written_at':rt['written_at'],'clipped_seconds':max(0,end-start),
      'vcs':vc if vc and epoch(vc['written_at'])<=cutoff else None,
      'handoff_summary':ho['body'].get('summary','')[:240] if ho and epoch(ho['written_at'])<=cutoff else None})
   if ho and epoch(ho['written_at'])<=cutoff:
    for sid in re.findall(r'sh_[0-9a-f]{32}',json.dumps(ho['body'])):refs[sid].add(tid)
  # Reviewer comments are grouped only inside the same gap between worker
  # facets. This prevents a clarification/rejection from spanning later rework.
  workints=union([(w['start'],w['end']) for w in windows if w['task_id']==tid and w['kind']=='runtime_facet'])
  horizon=min(epoch(t['completed_at']) or cutoff,cutoff)
  gaps=[];last=epoch(t['started_at']) or horizon
  for x,y in workints:
   if x>last:gaps.append((last,x))
   last=max(last,y)
  if horizon>last:gaps.append((last,horizon))
  reviews=[]
  for lo,hi in gaps:
   for agent in sorted(REVIEWERS):
    cc=[c for c in cs if c['author_agent_instance_id']==agent and lo<=epoch(c['created_at'])<=hi]
    if len(cc)>=2:
     st=epoch(cc[0]['created_at']);en=epoch(cc[-1]['created_at'])
     reviews.append({'start':iso(st),'end':iso(en),'source_start':cc[0]['comment_id'],'source_end':cc[-1]['comment_id'],'agent':agent})
     windows.append({'task_id':tid,'agent':agent,'start':st,'end':en,'kind':'review_comment_bound'})
  for c in cs:
   for sid in re.findall(r'sh_[0-9a-f]{32}',c['body']):refs[sid].add(tid)
  revints=[(epoch(r['start']),epoch(r['end'])) for r in reviews]
  start=epoch(t['started_at']);created=epoch(t['created_at']);finish=epoch(t['completed_at'])
  terminal=finish is not None and finish<=cutoff;end=finish if terminal else cutoff
  state=t['state'] if terminal or not finish else 'in_progress_at_cutoff'
  r={'task_id':tid,'title':t['title'],'status':state,'created_at':t['created_at'],'started_at':t['started_at'] or None,'completed_at':t['completed_at'] if terminal else None,
   'created_to_end_seconds':end-created,'first_start_to_end_seconds':end-start if start else None,
   'prestart_wait_seconds':(start or cutoff)-created,'worker_runtime_facet_union_seconds':length(workints),
   'review_comment_bound_seconds':length(revints),'unclassified_since_start_seconds':max(0,end-start-length(workints+revints)) if start else None,
   'work_intervals':union(workints),'review_intervals':reviews,'attempts':attempts,'depends_on':t['depends_on'],
   'current_reviews':[v for v in t['reviews'] if epoch(v['created_at'])<=cutoff],
   'exact_review_lease_seconds':None,'exact_hold_block_outage_seconds':None,'submission_vs_handoff_end_classification':'not fully available from runtime facet',
   'source_task_record':tid+'-show.json','worker_instance':worker,
   'checkpoint_head':next((x['vcs']['body']['head'] for x in reversed(attempts) if x['vcs']),None)}
  results.append(r)
  for c in cs:
   # Evidence is engineering commentary only, not private shell outputs.
   if any(x in c['body'].lower() for x in ['finding','collision','240','attempt','restart','conflict','baseline','hold','field','scope','connect']):
    evidence.append({k:c[k] for k in ['comment_id','task_id','created_at','author_agent_instance_id']}|{'excerpt':c['body'][:650]})
 # Full-page shell recovery: prefer large page when available; keep page0 for small agents.
 shellmap={};coverage=[]
 agents=[COORD,WORKER,'inst_18e5568123390193',SECOND,'inst_18e569b6fc61248b']
 for agent in agents:
  name='shell-'+agent+('-large' if (raw/('shell-'+agent+'-large.json')).exists() else '-0')
  d=read(name);ss=d['sessions'];assert not d['has_more'],name+' is incomplete'
  coverage.append({'agent':agent,'raw_full_page_count':len(ss),'has_more':d['has_more'],'source':name+'.json',
   'before_chain':sum(epoch(s['started_at'])<origin for s in ss),
   'after_cutoff':sum(epoch(s['started_at'])>cutoff for s in ss),
   'within_chain_time_range':sum(origin<=epoch(s['started_at'])<=cutoff for s in ss)})
  for s in ss:shellmap[s['session_id']]=s
 d=read('shell-chain');assert not d['has_more']
 for s in d['sessions']:shellmap[s['session_id']]=s
 sessions=[]
 for sid,s in shellmap.items():
  st=epoch(s['started_at'])
  if not origin<=st<=cutoff:continue
  finish=epoch(s['finished_at']);en=min(finish or cutoff,cutoff)
  if en<st:raise ValueError('negative shell span '+sid)
  candid=[w for w in windows if w['agent']==s['agent_instance_id'] and w['start']<=st<w['end']]
  matches={w['task_id'] for w in candid}
  linked=refs[sid]
  if len(matches&linked)==1:tid=next(iter(matches&linked));confidence='high_link_and_window';basis='task session reference plus matching agent interval'
  elif len(matches)==1:tid=next(iter(matches));confidence='medium_agent_window';basis='matching agent and runtime/review-comment interval; cwd unavailable'
  elif len(linked)==1:tid=next(iter(linked));confidence='medium_reference_only';basis='single task reference; may be outside active lease'
  else:tid=None;confidence='unassigned';basis='no unique task/window or reference'
  active=next((r['work_intervals'] for r in results if r['task_id']==tid),[])
  span=[(st,en)]
  sessions.append({'session_id':sid,'agent_instance_id':s['agent_instance_id'],'kind':s['kind'],'started_at':s['started_at'],
   'finished_at':s['finished_at'] if finish and finish<=cutoff else None,'end_at_cutoff':iso(en),'recorded_span_seconds':en-st,
   'status_at_cutoff':s['status'] if finish and finish<=cutoff else 'open_at_cutoff',
   'exit_code_at_cutoff':s['exit_code'] if finish and finish<=cutoff else None,
   'task_id':tid,'confidence':confidence,'basis':basis,'referenced_by_tasks':sorted(linked),
   'within_worker_facet_seconds':length(intersect(span,active)),
   'command_category':'unknown_command_metadata_unavailable','subprocess_runtime_seconds':None,'launch_queue_seconds':None})
 for r in results:
  ss=[s for s in sessions if s['task_id']==r['task_id']]
  r['shell']={'count':len(ss),'sum_recorded_span_seconds':sum(s['recorded_span_seconds'] for s in ss),
   'union_recorded_span_seconds':length([(epoch(s['started_at']),epoch(s['end_at_cutoff'])) for s in ss]),
   'worker_intersection_union_seconds':length(intersect([(epoch(s['started_at']),epoch(s['end_at_cutoff'])) for s in ss],r['work_intervals'])),
   'nonzero_exit_count':sum(s['exit_code_at_cutoff'] not in (None,0) for s in ss),
   'open_at_cutoff_count':sum(s['status_at_cutoff']=='open_at_cutoff' for s in ss),
   'confidence_counts':dict(collections.Counter(s['confidence'] for s in ss)),
   'subprocess_runtime_seconds':None,'launch_queue_seconds':None}
 # Immutable Git provenance and exact numstats.
 commits=[];seen_patch={};authored=[]
 for r in results:
  owned=[]
  for short in GROUPS.get(r['task_id'],'').split():
   h=git('rev-parse',short).strip();parents=git('show','-s','--format=%P',h).strip().split()
   merge=len(parents)>1
   text=git('show','--format=','--remerge-diff','--numstat','-M',h) if merge else git('diff','--numstat','-M',parents[0],h)
   rows=numstat(text);copy=COPIES.get(short)
   rec={'commit':h,'parents':parents,'task_id':r['task_id'],'subject':git('show','-s','--format=%s',h).strip(),
    'authored_at':git('show','-s','--format=%aI',h).strip(),'committed_at':git('show','-s','--format=%cI',h).strip(),
    'stat_mode':'remerge_resolution_only' if merge else 'first_parent_diff',
    'copied_from':git('rev-parse',copy).strip() if copy else None,'numstat':rows,'stats':stat(rows)}
   assert epoch(rec['committed_at'])<=cutoff
   if r['checkpoint_head']:
    assert subprocess.run(['git','merge-base','--is-ancestor',h,r['checkpoint_head']]).returncode==0,(h,r['checkpoint_head'])
   commits.append(rec);owned.append(rec)
   if not copy and not merge:authored.extend(rows)
  rows=[x for c in owned for x in c['numstat']]
  newrows=[x for c in owned if not c['copied_from'] and c['stat_mode']!='remerge_resolution_only' for x in c['numstat']]
  bases={'task_18e562f7b94d63bb':'ec3bdaab','task_18e56d155e88f266':'a1ff381b','task_18e56a0d15295083':'c04b5610'}
  base=git('rev-parse',bases.get(r['task_id'],owned[0]['parents'][0])).strip() if owned else None
  head=owned[-1]['commit'] if owned else None
  netrows=numstat(git('diff','--numstat','-M',base,head)) if owned else []
  newnetrows=numstat(git('diff','--numstat','-M','bfac0d0d',head)) if r['task_id']=='task_18e57ad52bb4ea63' else netrows
  r['git']={'retained_net':stat(netrows),'new_net_excluding_copied_checkpoint':stat(newnetrows),'net_base':base,'net_head':head,
    'net_numstat':netrows,'net_baseline_reason':'last accepted incoming integration parent; removes inherited work' if r['task_id'] in bases else 'first owned commit parent',
    'resolution_diff':stat([x for c in owned if c['stat_mode']=='remerge_resolution_only' for x in c['numstat']]),
    'commit_count':len(owned),'commits':[c['commit'] for c in owned],
    'retained_gross':stat(rows),'new_authored_gross':stat(newrows),
    'partial_uncommitted_state_unknown':r['task_id']=='task_18e57ad551f091b8',
    'no_change_reason':'not started' if not r['started_at'] else ('no committed checkpoint at cutoff; uncommitted state not measured' if not owned and r['task_id']=='task_18e57ad551f091b8' else ('inspection only; no implementation' if not owned else None))}
 baseline=git('rev-parse','ada2d4c8').strip();accepted=git('rev-parse','d78c6c54').strip()
 finalrows=numstat(git('diff','--numstat','-M',baseline,accepted))
 allints=[(epoch(s['started_at']),epoch(s['end_at_cutoff'])) for s in sessions]
 workints=[(w['start'],w['end']) for w in windows if w['kind']=='runtime_facet']
 unassigned=[s for s in sessions if not s['task_id']]
 data={'schema_version':1,'chain_id':CHAIN,'cutoff':CUTOFF,'chain_created_at':chain['created_at'],'chain_elapsed_seconds':cutoff-origin,
  'tasks':results,'excluded_post_cutoff_tasks':after,'shell_coverage':coverage,'shell_sessions':sorted(sessions,key=lambda s:s['started_at']),
  'git_commits':commits,'evidence':evidence,'source_snapshot_sha256':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in raw.glob('*.json')},
  'totals':{'task_count':len(results),'states':dict(collections.Counter(r['status'] for r in results)),
   'worker_runtime_facet_sum_seconds':sum(r['worker_runtime_facet_union_seconds'] for r in results),
   'worker_runtime_facet_chain_union_seconds':length(workints),
   'shell_record_count':len(sessions),'shell_span_sum_seconds':sum(s['recorded_span_seconds'] for s in sessions),
   'shell_span_union_seconds':length(allints),'shell_worker_intersection_union_seconds':length(intersect(allints,workints)),
   'attributed_shell_count':len(sessions)-len(unassigned),'unassigned_shell_count':len(unassigned),
   'unassigned_shell_sum_seconds':sum(s['recorded_span_seconds'] for s in unassigned),
   'unassigned_shell_union_seconds':length([(epoch(s['started_at']),epoch(s['end_at_cutoff'])) for s in unassigned]),
   'shell_confidence_counts':dict(collections.Counter(s['confidence'] for s in sessions)),
   'shell_status_counts':dict(collections.Counter(s['status_at_cutoff'] for s in sessions)),
   'shell_nonzero_exit_count':sum(s['exit_code_at_cutoff'] not in (None,0) for s in sessions),
   'authored_gross_deduplicated':stat(authored),'final_accepted_net':stat(finalrows),'final_accepted_baseline':baseline,'final_accepted_head':accepted},
   'missing':{'closed_review_leases':'CLI exposes current leases and latest reviews; historical exact review starts unavailable; comment bounds only',
    'hold_block_outage_intervals':'not reconstructible exactly from available task list/show/runtime facets; narrative evidence retained',
    'commands':'cmd/cwd/label blank in authorized list/show; old local spawn specs removed (one current post-cutoff spec only)',
    'actual_subprocess_runtime':'millisecond fields are Bridge-only and not persisted; Hub end stamps receipt of exit',
    'queue_runtime_split':'not separable from recorded Hub session span','unmanaged_commands':'not recorded in shell sessions; unknown','token_cost':'no token usage data'}}
 (out/'metrics.json').write_text(json.dumps(data,indent=2)+'\n')
 fields=['task_id','title','status','created_at','started_at','completed_at','created_to_end_seconds','first_start_to_end_seconds','prestart_wait_seconds','worker_runtime_facet_union_seconds','review_comment_bound_seconds','unclassified_since_start_seconds','files_net','added_net','deleted_net','new_added_gross','new_deleted_gross','shell_count','shell_sum_recorded_seconds','shell_union_recorded_seconds','shell_nonzero_exit_count']
 with (out/'tasks.csv').open('w',newline='') as f:
  w=csv.DictWriter(f,fieldnames=fields);w.writeheader()
  for r in results:
   w.writerow({**{k:r.get(k) for k in fields[:12]},'files_net':r['git']['retained_net']['files'],'added_net':r['git']['retained_net']['added'],'deleted_net':r['git']['retained_net']['deleted'],
    'new_added_gross':r['git']['new_authored_gross']['added'],'new_deleted_gross':r['git']['new_authored_gross']['deleted'],
    'shell_count':r['shell']['count'],'shell_sum_recorded_seconds':r['shell']['sum_recorded_span_seconds'],'shell_union_recorded_seconds':r['shell']['union_recorded_span_seconds'],'shell_nonzero_exit_count':r['shell']['nonzero_exit_count']})
 print(json.dumps(data['totals'],indent=2))
if __name__=='__main__':main()
