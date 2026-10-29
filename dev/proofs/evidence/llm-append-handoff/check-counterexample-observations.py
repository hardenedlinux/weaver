from pathlib import Path
import json
out=Path('proofs/evidence/llm-append-handoff')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 if '#map' in x:return {decode(k):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
records=[]
for p in sorted((out/'itf').glob('*.json')):
 states=[decode(st) for st in json.loads(p.read_text())['states']];last=states[-1];a,c,h,s,w=last['a'],last['c'],last['h'],last['s'],last['w'];name=p.name.split('AppendCounterexample')[0]
 initialized=[st for st in states if 'h' in st]
 assert initialized and all(st['s']==initialized[0]['s'] for st in initialized),('provider execution changed',name)
 assert s['entries'] and s['authority']['exposure']==3 and 11 in s['authority']['spent'] and s['laneCalls']==1 and s['sourceCalls']==0,name
 assert a['anchor']['used']==[11] and len(a['anchor']['applications'])==1 and a['anchor']['holds'][12]==2 and len(a['journal'])==1,name
 assert len(w['records'])==2 and c['suffix'][0]['proposal']['transaction']['key']['reservation']==12,name
 ids=[seg['id'] for seg in h['objects']]
 if name=='droppedLive':assert h['root']['id']==1 and not h['live'] and 11 in ids and not h['closed']
 elif name=='droppedClosed':
  assert not h['closed'] and not h['live'] and len(h['cut']['records'])==1 and 11 in ids
  assert any(st.get('h',{}).get('closed') and len(st['h']['cut']['records'])==2 for st in states[:-1])
 elif name=='tailDeletion':assert h['live'][0]['id']==11 and 11 not in ids and h['root']['id']==1
 elif name=='oldGeneration':assert h['attempted']['appendGeneration']==0 and h['appendGeneration']==1 and h['frontier']==1 and h['live'][0]['id']==11 and not h['lastAuthorized']
 elif name=='oldFrontier':assert h['attempted']['frontier']==0 and h['frontier']==1 and not h['lastAuthorized']
 elif name=='oldOwner':assert h['attempted']['worker']==0 and a['epoch']==1 and h['observed']['worker']==1 and not h['lastAuthorized']
 elif name=='pendingAsCommitted':
  cp=c['published'][-1];assert cp['position']==2 and cp['basis']['head']['holds'][12]==0 and sorted(cp['basis']['head']['used'])==[11,12]
  assert a['anchor']['revision']==1 and a['anchor']['holds'][12]==2 and h['live'][0]['id']==11
 elif name=='lostResponse':assert not h['haveObservation'] and not h['lastAuthorized'] and h['attempted']['appendGeneration']==1 and h['attempted']['frontier']==1
 else:raise AssertionError(name)
 records.append(dict(name=name,path=str(p),states=len(states),root=h['root']['id'],appendGeneration=h['appendGeneration'],frontier=h['frontier'],objectIds=ids,attempted=h['attempted'],actualFinancialRevision=a['anchor']['revision'],actualRemainingHold=a['anchor']['holds'][12]))
assert len(records)==8
(out/'counterexample-observations.json').write_text(json.dumps(records,indent=2)+'\n')
print('PASS: eight decoded append/cut violations; explicit stale descriptors; actual source execution unchanged and pending original hold retained')
