from pathlib import Path
import json
out=Path('proofs/evidence/llm-recovery-cas')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 return {k:decode(v) for k,v in x.items()}
observations=[]
for p in sorted((out/'itf').glob('*.json')):
 j=json.loads(p.read_text());states=[decode(x)['s'] for x in j['states']];s=states[-1]
 if p.name.startswith('tornRead'):
  d=s['decisions'][-1]
  assert d['request']['cut']['policyGeneration']==0 and d['actual']['policyGeneration']==1
  assert d['actual']['revision']==0 and not d['allowed'] and not d['historyClear']
  assert any(st['policyGeneration']==1 and st['hasPolicy'] and not st['hasExecution'] for st in states)
 elif p.name.startswith('policyABA'):
  d=s['decisions'][-1]
  assert d['request']['cut']['policyGeneration']==0 and d['actual']['policyGeneration']==2 and d['allowed']
  assert any(not st['allowed'] and st['policyGeneration']==1 for st in states)
 elif p.name.startswith('oldFence'):
  d=s['decisions'][-1];q=d['request'];permit=q['permit']
  assert q in s['requests'] and permit in s['permits'] and permit['id']==0 and permit['worker']==0
  assert d['actual']['fence']==1 and d['actual']['revision']==1 and q['cut']['fence']==0
  assert any(permit in st['permits'] and q in st['requests'] and st['fence']==0 for st in states[:-1])
 elif p.name.startswith('staleLedger'):
  d=s['decisions'][-1]
  assert d['request']['cut']['revision']==0 and d['actual']['revision']==1 and d['actual']['fence']==0
 elif p.name.startswith('lateAck'):
  assert s['calls']==2 and s['fence']==1 and len(s['confirmations'])==1 and len(s['decisions'])==2
  assert s['confirmations'][0]==s['decisions'][0] and s['decisions'][0]['request']==s['decisions'][1]['request']
  assert any(st['calls']==1 and len(st['confirmations'])==1 and st['fence']==1 for st in states[:-1])
 elif p.name.startswith('duplicate'):
  assert len(s['decisions'])==2 and s['decisions'][0]==s['decisions'][1] and s['calls']==1
 elif p.name.startswith('profileSwap'):
  d=s['decisions'][-1]
  assert d['request']['cut']['binding']['commitment']==21 and d['actual']['binding']['commitment']==20
 elif p.name.startswith('unknownRefund'):
  assert s['spent'] and s['usage']==-1 and s['hold']==0 and s['charged'] and not s['closed']
 else:raise AssertionError(p)
 observations.append(dict(path=str(p),states=len(states),authority=s))
assert len(observations)==8
(out/'counterexample-observations.json').write_text(json.dumps(observations,indent=2)+'\n')
print('PASS: eight independently decoded recovery-CAS counterexamples; mixed-read ordering, actual old issuance and late original-decision confirmation verified')
