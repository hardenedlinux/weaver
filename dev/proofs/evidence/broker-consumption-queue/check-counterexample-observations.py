from pathlib import Path
import json
out=Path('proofs/evidence/broker-consumption-queue')
def decode(x):
 if isinstance(x,list):return [decode(y) for y in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(y) for y in x['#set']]
 if '#map' in x:return {str(decode(k)):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
observations=[]
for p in sorted((out/'itf').glob('*.json')):
 j=json.loads(p.read_text());last=decode(j['states'][-1]);q=last['q']
 if p.name.startswith('sdkReplay'):assert q['calls']['0']==2
 elif p.name.startswith('timeoutRefund'):assert q['unknown'] and q['settled']
 elif p.name.startswith('overlappingTail'):assert any(a!=b and a['hi']>b['lo'] and b['hi']>a['lo'] for a in q['ranges'] for b in q['ranges'])
 elif p.name.startswith('restartedSpentLoss'):assert q['accepted'] and not q['spent'] and q['epoch']>0
 elif p.name.startswith('enqueueBeforeIntent'):assert q['accepted'] and not q['intent']
 elif p.name.startswith('unboundLateReceipt'):
  assert q['settled'] and q['completed'] and q['usage'] and not q['unknown'] and not q['hasPending']
  assert any(r not in q['full'] for r in q['ranges'])
 else:raise AssertionError(p)
 observations.append(dict(path=str(p),states=len(j['states']),finalQueue=q))
assert len(observations)==6
(out/'counterexample-observations.json').write_text(json.dumps(observations,indent=2)+'\n')
print('PASS: six independently decoded queue counterexample traces')
