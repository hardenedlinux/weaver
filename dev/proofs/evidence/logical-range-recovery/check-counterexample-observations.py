from pathlib import Path
import json
out=Path('proofs/evidence/logical-range-recovery')
def decode(x):
 if isinstance(x,list):return [decode(y) for y in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(y) for y in x['#set']]
 if '#map' in x:return {str(decode(k)):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
observations=[]
for p in sorted((out/'itf').glob('*.json')):
 j=json.loads(p.read_text());last=decode(j['states'][-1]);x=last['x'];q=last['q']
 if p.name.startswith('stalePermit'):assert x['havePermit'] and x['permit']['epoch']!=x['epoch']
 elif p.name.startswith('recoveryReplay'):assert x['calls']==2 and q['calls']['0']==1
 elif p.name.startswith('resetConsumedSlot'):assert x['calls']==0 and q['calls']['0']==1 and x['unknown']
 elif p.name.startswith('staleNoCallCut'):assert x['calls']==1 and x['havePermit']
 elif p.name.startswith('timeoutAsFull'):assert x['calls']==1 and x['unknown'] and x['full']
 elif p.name.startswith('foreignReceipt'):assert any(r['call']['scope']!=x['invocation']['scope'] for r in x['receipts'])
 else:raise AssertionError(p)
 observations.append(dict(path=str(p),states=len(j['states']),recovery=x,parentQueue=q))
assert len(observations)==6,len(observations)
(out/'counterexample-observations.json').write_text(json.dumps(observations,indent=2)+'\n')
print('PASS: six independently decoded logical recovery counterexamples')
