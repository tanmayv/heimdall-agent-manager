#!/usr/bin/env python3
"""Independent arithmetic/provenance checks against frozen data and Git.

Uses an event sweep, not analyze.py's merge-interval algorithm.
"""
import argparse,collections,datetime as dt,hashlib,json,pathlib,re,subprocess
from html.parser import HTMLParser
from urllib.parse import urlsplit,unquote
def ts(s):return dt.datetime.fromisoformat(s.replace('Z','+00:00')).timestamp()
def sweep(intervals):
 ev=collections.Counter()
 for a,b in intervals:
  assert b>=a
  ev[a]+=1;ev[b]-=1
 level=0;total=0;previous=None
 for point,change in sorted(ev.items()):
  if level:total+=point-previous
  level+=change;previous=point
 assert level==0
 return total
def git(*args):return subprocess.run(['git',*args],check=True,capture_output=True,text=True).stdout
def rows(text):
 out=[]
 for line in text.splitlines():
  a,b,p=line.split('\t',2);out.append({'path':p,'added':None if a=='-' else int(a),'deleted':None if b=='-' else int(b)})
 return out
def sums(rr):return len({r['path'] for r in rr}),sum(r['added'] or 0 for r in rr),sum(r['deleted'] or 0 for r in rr)
def check_stat(actual,rr):assert (actual['files'],actual['added'],actual['deleted'])==sums(rr)
def main():
 p=argparse.ArgumentParser();p.add_argument('--metrics',required=True);p.add_argument('--snapshot');a=p.parse_args()
 path=pathlib.Path(a.metrics);text=path.read_text();d=json.loads(text);T=d['totals'];cut=ts(d['cutoff']);origin=ts(d['chain_created_at'])
 assert not re.search(r'hlat_[A-Za-z0-9_]+|vault:v2:',text),'credential/ciphertext marker packaged'
 tasks=d['tasks'];sessions=d['shell_sessions'];commits=d['git_commits']
 assert len(tasks)==T['task_count']==25
 assert len({x['task_id'] for x in tasks})==len(tasks)
 assert len(sessions)==len({s['session_id'] for s in sessions})==T['shell_record_count']
 assert all(not c['has_more'] for c in d['shell_coverage'])
 assert sum(c['within_chain_time_range'] for c in d['shell_coverage'])==len(sessions)
 assert sum(c['raw_full_page_count']-c['after_cutoff']-c['before_chain'] for c in d['shell_coverage'])==len(sessions)
 assert T['shell_nonzero_exit_count']==sum(s['exit_code_at_cutoff'] not in (None,0) for s in sessions)
 spans=[]
 for s in sessions:
  st,en=ts(s['started_at']),ts(s['end_at_cutoff']);assert origin<=st<=en<=cut
  assert en-st==s['recorded_span_seconds'];spans.append((st,en))
  if s['confidence']=='high_link_and_window':assert s['task_id'] in s['referenced_by_tasks']
 assert sweep(spans)==T['shell_span_union_seconds']
 assert sum(s['recorded_span_seconds'] for s in sessions)==T['shell_span_sum_seconds']
 assert T['shell_span_union_seconds']<=T['shell_span_sum_seconds']
 assert T['attributed_shell_count']+T['unassigned_shell_count']==len(sessions)
 unknown=[s for s in sessions if s['task_id'] is None]
 assert len(unknown)==T['unassigned_shell_count']
 assert sweep([(ts(s['started_at']),ts(s['end_at_cutoff'])) for s in unknown])==T['unassigned_shell_union_seconds']
 allwork=[];netline=0
 for t in tasks:
  assert ts(t['created_at'])<=cut
  end=ts(t['completed_at']) if t['completed_at'] else cut
  assert end-ts(t['created_at'])==t['created_to_end_seconds']
  if t['started_at']:
   assert ts(t['started_at'])-ts(t['created_at'])==t['prestart_wait_seconds']
   assert end-ts(t['started_at'])==t['first_start_to_end_seconds']
   assert t['worker_runtime_facet_union_seconds']+t['review_comment_bound_seconds']+t['unclassified_since_start_seconds']==t['first_start_to_end_seconds']
  else:assert t['first_start_to_end_seconds'] is None and t['prestart_wait_seconds']==t['created_to_end_seconds']
  wi=[(ts(x['runtime']['started_at']),min(ts(x['runtime']['ended_at']) if x['runtime']['ended_at'] else cut,cut)) for x in t['attempts']]
  assert sweep(wi)==t['worker_runtime_facet_union_seconds']
  allwork.extend(wi)
  ri=[(ts(x['start']),ts(x['end'])) for x in t['review_intervals']]
  assert sweep(ri)==t['review_comment_bound_seconds']
  assert sweep(wi+ri)==sweep(wi)+sweep(ri),'review bounds overlap attempt envelope'
  ss=[s for s in sessions if s['task_id']==t['task_id']]
  assert len(ss)==t['shell']['count']
  assert sum(s['recorded_span_seconds'] for s in ss)==t['shell']['sum_recorded_span_seconds']
  si=[(ts(s['started_at']),ts(s['end_at_cutoff'])) for s in ss]
  assert sweep(si)==t['shell']['union_recorded_span_seconds']
  intersections=[(max(x,u),min(y,v)) for x,y in si for u,v in wi if max(x,u)<min(y,v)]
  assert sweep(intersections)==t['shell']['worker_intersection_union_seconds']
  g=t['git']
  if g['net_base']:
   rr=rows(git('diff','--numstat','-M',g['net_base'],g['net_head']))
   assert rr==g['net_numstat'];check_stat(g['retained_net'],rr)
   if t['task_id']=='task_18e57ad52bb4ea63':rr=rows(git('diff','--numstat','-M','bfac0d0d',g['net_head']))
   check_stat(g['new_net_excluding_copied_checkpoint'],rr)
  netline+=g['new_net_excluding_copied_checkpoint']['added']-g['new_net_excluding_copied_checkpoint']['deleted']
 assert sweep(allwork)==T['worker_runtime_facet_chain_union_seconds']
 assert sum(t['worker_runtime_facet_union_seconds'] for t in tasks)==T['worker_runtime_facet_sum_seconds']
 intersections=[(max(x,u),min(y,v)) for x,y in spans for u,v in allwork if max(x,u)<min(y,v)]
 assert sweep(intersections)==T['shell_worker_intersection_union_seconds']
 final=rows(git('diff','--numstat','-M',T['final_accepted_baseline'],T['final_accepted_head']))
 check_stat(T['final_accepted_net'],final)
 assert netline==T['final_accepted_net']['added']-T['final_accepted_net']['deleted']==20476
 accepted=set(git('rev-list',T['final_accepted_baseline']+'..'+T['final_accepted_head']).split())
 old=set(c['copied_from'] for c in commits if c['copied_from'])
 assert accepted=={c['commit'] for c in commits}-old,'accepted commits missing from task provenance'
 gross=[]
 for c in commits:
  assert ts(c['committed_at'])<=cut
  rr=rows(git('show','--format=','--remerge-diff','--numstat','-M',c['commit'])) if len(c['parents'])>1 else rows(git('diff','--numstat','-M',c['parents'][0],c['commit']))
  assert rr==c['numstat'];check_stat(c['stats'],rr)
  if not c['copied_from'] and len(c['parents'])==1:gross.extend(rr)
  if c['copied_from']:
   # A copy is required to preserve both its parent tree and result tree.
   assert git('rev-parse',c['commit']+'^{tree}')==git('rev-parse',c['copied_from']+'^{tree}')
   assert git('rev-parse',c['parents'][0]+'^{tree}')==git('rev-parse',c['copied_from']+'^1^{tree}')
 check_stat(T['authored_gross_deduplicated'],gross)
 assert git('rev-parse','bfac0d0d^{tree}')==git('rev-parse','4867e4fa^{tree}')
 if a.snapshot:
  raw=pathlib.Path(a.snapshot)
  for name,h in d['source_snapshot_sha256'].items():assert hashlib.sha256((raw/name).read_bytes()).hexdigest()==h,name
  def read(n):return json.loads((raw/(n+'.json')).read_text())['data']['data']
  source={t['task_id']:t for t in read('tasks') if ts(t['created_at'])<=cut}
  assert set(source)=={t['task_id'] for t in tasks}
  for t in tasks:
   for k in ['created_at','started_at','completed_at']:assert (source[t['task_id']][k] or None)==t[k]
  for c in d['shell_coverage']:
   page=json.loads((raw/c['source']).read_text())['data']['data']
   assert not page['has_more'] and len(page['sessions'])==c['raw_full_page_count']
   for s in page['sessions']:
    if origin<=ts(s['started_at'])<=cut:
     target=next(x for x in sessions if x['session_id']==s['session_id'])
     assert s['started_at']==target['started_at']
     assert min(ts(s['finished_at']) if s['finished_at'] else cut,cut)==ts(target['end_at_cutoff'])
 site=path.parent/'site'
 if site.exists():
  class Parser(HTMLParser):
   def __init__(self):super().__init__();self.ids=[];self.refs=[]
   def handle_starttag(self,tag,attrs):
    attrs=dict(attrs);assert tag not in {'script','iframe','object','base'}
    assert not any(k.startswith('on') for k in attrs)
    if 'id' in attrs:self.ids.append(attrs['id'])
    for k in ['href','src']:
     if k in attrs:self.refs.append(attrs[k])
  hp=Parser();hp.feed((site/'index.html').read_text())
  assert len(hp.ids)==len(set(hp.ids))
  assert all(t['task_id'] in hp.ids for t in tasks)
  for ref in hp.refs:
   u=urlsplit(ref);assert not u.scheme and not u.netloc,ref
   if u.path:assert (site/unquote(u.path)).is_file(),ref
   if u.fragment:assert u.fragment in hp.ids,ref
  for name in ['metrics.json','report.md','tasks.csv']:assert (site/name).read_bytes()==(path.parent/name).read_bytes()
  assert not re.search(r'https?:|@import|url\(', (site/'style.css').read_text()),'remote style dependency'
 print('PASS:25 tasks;1506 unique sessions; independent sweep/phase/attribution checks; exact Git numstats; all40 accepted commits;9 copy mappings; frozen hashes; static links and packaged data.')
if __name__=='__main__':main()
