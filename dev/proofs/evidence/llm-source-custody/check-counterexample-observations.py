from pathlib import Path
import json
out=Path('proofs/evidence/llm-source-custody')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 if '#map' in x:return {decode(k):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
records=[]
for p in sorted((out/'itf').glob('*.json')):
 states=[decode(st) for st in json.loads(p.read_text())['states']]
 initialized=[st for st in states if 'custody' in st];assert initialized
 last=initialized[-1];a,f,j,s,c=[last[k] for k in ['a','f','j','s','custody']]
 name=p.name.split('CustodyCounterexample')[0]
 assert all(st['s']==initialized[0]['s'] for st in initialized),name
 assert s['authority']['exposure']==3 and 11 in s['authority']['spent'] and s['laneCalls']==1 and s['sourceCalls']==0,name
 assert a['anchor']['used']==[11] and a['anchor']['holds'][12]==2 and len(a['anchor']['applications'])==1,name
 assert all(st['custody']['original']['id']==1 for st in initialized if st['custody']['haveIntent']),name
 if name=='oldPermit':
  assert c['fence']==1 and c['holder']==1 and a['epoch']==0 and not c['lastChecked'] and len(f['log'])==2,name
  assert f['log'][-1]['proposal']==c['attempt'] and len(last['h']['live'])==1 and last['h']['frontier']==1,name
 elif name=='unknownClose':assert c['phase']==4 and not c['haveOutcome'] and not c['resolved'] and len(f['log'])==1,name
 elif name=='unresolvedClose':assert c['phase']==4 and c['haveOutcome'] and not c['resolved'] and len(f['log'])==2,name
 elif name=='droppedIntent':assert c['fence']==1 and not c['haveIntent'] and len(f['log'])==1,name
 elif name=='wrongResult':assert c['outcome']['proposal']['id']==2 and c['original']['id']==1 and len(f['log'])==1,name
 elif name=='armedMutation':assert c['phase']==2 and j['revision']==1 and not c['lastChecked'] and len(f['log'])==1,name
 elif name=='rolledBackFence':
  assert c['fence']==0 and not c['lastChecked'] and any(st['custody']['fence']==1 for st in initialized[:-1]),name
 else:raise AssertionError(name)
 records.append(dict(name=name,path=str(p),states=len(states),custodyFence=c['fence'],custodyHolder=c['holder'],floorRecords=len(f['log']),hold12=a['anchor']['holds'][12],sourceCalls=s['sourceCalls']))
assert len(records)==7
witness=json.loads((out/'preliminary-closed-restart.itf.json').read_text())
last=decode(witness['states'][-1]);c=last['custody']
assert c['phase']==4 and c['haveOutcome'] and not c['resolved'] and c['lastChecked']
assert last['a']['anchor']['holds'][12]==2 and last['s']['sourceCalls']==0
(out/'counterexample-observations.json').write_text(json.dumps(records,indent=2)+'\n')
print('PASS: seven independently decoded custody violations; actual stale-custody append distinguished from descriptor mutations; original provider execution and unknown hold unchanged')
