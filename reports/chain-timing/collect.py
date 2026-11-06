#!/usr/bin/env python3
"""Freeze authorized CLI metadata; raw snapshots stay local (not committed)."""
import argparse,concurrent.futures,json,pathlib,subprocess,time
p=argparse.ArgumentParser();p.add_argument('--cli',required=True);p.add_argument('--out',required=True);a=p.parse_args()
out=pathlib.Path(a.out);out.mkdir(parents=True,exist_ok=True)
def call(args):
 r=subprocess.run([a.cli]+args,capture_output=True,text=True)
 try:return json.loads(r.stdout)
 except:return {'ok':False,'parse_error':r.stderr[:300]}
def save(name,args):
 j=call(args);(out/(name+'.json')).write_text(json.dumps(j,indent=2));return j
save('chain',['task-chain','show','chain_18e554c99be21d02'])
save('shell-chain',['shell','list','--chain','chain_18e554c99be21d02','--limit','10000'])
tasks=save('tasks',['task','list'])['data']['data']
jobs=[]
for t in tasks:
 tid=t['task_id'];jobs += [(tid+'-show',['task','show',tid]),(tid+'-comments',['task','comments',tid,'--last','100'])]
 for n in range(1,t['attempt_no']+1):
  for k in ['runtime','vcs','handoff']:
   jobs.append((f'{tid}-{n}-{k}',['task','fetch',tid,f'facet:{tid}:{n}:{k}']))
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
 results=list(ex.map(lambda job:save(*job),jobs))
print('Saved',len(jobs),'task records;',sum(bool(j.get('ok')) for j in results),'available')
agents=['inst_18e554c99e0743ee','inst_18e554e13ee165a7','inst_18e5568123390193','inst_18e568efd2a64539','inst_18e569b6fc61248b']
for agent in agents:
 cursor='';page=0
 while True:
  args=['shell','list','--agent',agent,'--limit','10000']
  if cursor:args+=['--cursor',cursor]
  j=save(f'shell-{agent}-{page}',args)
  print(agent,page,str(j)[:150])
  d=j.get('data',{});d=d.get('data',d) if isinstance(d,dict) else {}
  pag=d.get('page',j.get('data',{}).get('page',{})) if isinstance(d,dict) else {}
  if d.get('has_more'):raise RuntimeError('Full-page limit exceeded; cursor is known unreliable. Obtain explicit read-only metadata; do not claim completeness.')
  cursor=d.get('next_cursor') or pag.get('next_cursor');page+=1
  if not cursor or page>30:break
