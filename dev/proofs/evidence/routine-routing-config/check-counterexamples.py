from pathlib import Path
import json
out=Path('proofs/evidence/routine-routing-config')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 if '#map' in x:return {decode(k):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
rows=[]
for p in sorted((out/'itf').glob('*CounterexampleTest-*.json')):
 states=[decode(s) for s in json.loads(p.read_text())['states'] if 'cfg' in s and 'r' in s];assert states
 s=states[-1];n=p.name.split('-')[0];cfg=s['cfg'];r=s['r']
 if n=='weakenedConfigCounterexampleTest':assert cfg['pinned']['allowance']==20
 elif n=='replacedRoutineCounterexampleTest':assert cfg['pinned']['targets']==[6] and cfg['plans'][0]['normal']['targets']==[0,6]
 elif n=='rewrittenRootCounterexampleTest':assert any(d['plan']['root']==1 for d in r['dispatches'])
 elif n=='hiddenRetryCounterexampleTest':assert len(r['dispatches'])==2 and r['unknown']
 else:raise AssertionError(n)
 rows.append(dict(name=n,path=str(p),states=len(states),dispatchCount=len(r['dispatches']),unknown=r['unknown'],pinnedAllowance=cfg['pinned']['allowance'],pinnedTargets=cfg['pinned']['targets']))
assert len(rows)==4
(out/'counterexample-observations.json').write_text(json.dumps(rows,indent=2)+'\n')
print('PASS: four decoded config/pin/wire/retry fault traces; faults excluded from guarded step')
