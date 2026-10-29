from pathlib import Path
import json
out=Path('proofs/evidence/llm-result-projection')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 return {k:decode(v) for k,v in x.items()}
observations=[]
for p in sorted((out/'itf').glob('*.json')):
 states=[decode(x)['s'] for x in json.loads(p.read_text())['states']];s=states[-1]
 name=p.name.split('Counterexample')[0]
 assert any(st['log'] and st['authority']['exposure']==3 and 11 in st['authority']['spent'] for st in states[:-1]),name
 if name=='resultReplacement':
  assert s['log'][0]['after']['exposure']==0 and s['authority']['exposure']==3
 elif name=='duplicateConsumption':assert s['authority']['exposure']==6
 elif name=='accountDeltaRetry':
  assert s['accountStore']['position']==1 and s['accountStore']['body']['exposure']==6 and s['log'][0]['after']['exposure']==3
 elif name=='tornSourceRow':assert s['sourceStore']['position']==1 and s['sourceStore']['body']['spent']==[] and 11 in s['authority']['spent']
 elif name=='oldOwnerApplication':
  a=s['applications'][-1];assert a['worker']==0 and a['epoch']==s['epoch']==1
  assert a['before']['body']==a['result']['before'] and a['result']['position']==a['before']['position']+1
 elif name=='skippedPrefix':
  a=s['applications'][-1];assert a['before']['position']==0 and a['result']['position']==2 and a['result'] in s['log']
 elif name=='unknownRefund':assert s['authority']['exposure']==0 and s['everExposure']==3 and 11 in s['authority']['spent']
 elif name=='mixedSnapshotActivation':assert s['open'] and s['activations'][-1] is False and s['sourceStore']['position']==0 and len(s['log'])==1
 elif name=='lateObservationResend':
  assert s['queued']==[1] and s['calls']==2 and s['observed']==[1]
  assert any(st['queued']==[1] and st['calls']==1 for st in states[:-1])
 elif name=='profileReplacement':assert s['authority']['profile']==99 and s['log'][0]['after']['profile']==30
 else:raise AssertionError(name)
 observations.append(dict(path=str(p),states=len(states),violation=name,final=s))
assert len(observations)==10
(out/'counterexample-observations.json').write_text(json.dumps(observations,indent=2)+'\n')
print('PASS: ten independently decoded result-projection violations; real original commits, application bodies, retirement and queued operation verified')
