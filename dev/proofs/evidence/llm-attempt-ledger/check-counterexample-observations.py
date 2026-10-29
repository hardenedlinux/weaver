from pathlib import Path
import json
out=Path('proofs/evidence/llm-attempt-ledger')
def decode(x):
 if isinstance(x,list):return [decode(y) for y in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(y) for y in x['#set']]
 if '#map' in x:return {str(decode(k)):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
observations=[]
for p in sorted((out/'itf').glob('*.json')):
 j=json.loads(p.read_text());a=decode(j['states'][-1])['a']
 if p.name.startswith('resetAllowance'):assert a['allocated']==0 and sum(t['bound'] for t in a['attempts'])==6
 elif p.name.startswith('sdkReplay'):assert a['calls']['0']==2
 elif p.name.startswith('switchWinner'):assert len(a['winners'])==2 and a['winner']==0
 elif p.name.startswith('closeUnknown'):assert a['closed'] and any(a['usage'][str(t['id'])]== -1 for t in a['attempts'])
 elif p.name.startswith('duplicateUsage'):assert a['charged']==1 and a['usage']['0']==0
 elif p.name.startswith('foreignRoot'):assert any(t['root']==9 for t in a['attempts'])
 else:raise AssertionError(p)
 observations.append(dict(path=str(p),states=len(j['states']),ledger=a))
assert len(observations)==6
(out/'counterexample-observations.json').write_text(json.dumps(observations,indent=2)+'\n')
print('PASS: six independently decoded attempt-ledger counterexamples')
