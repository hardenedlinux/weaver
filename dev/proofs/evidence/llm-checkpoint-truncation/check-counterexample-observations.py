from pathlib import Path
import json
out=Path('proofs/evidence/llm-checkpoint-truncation')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 if '#map' in x:return {decode(k):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
records=[]
for p in sorted((out/'itf').glob('*.json')):
 states=[decode(st) for st in json.loads(p.read_text())['states']];last=states[-1];a,w,c,s=last['a'],last['w'],last['c'],last['s'];name=p.name.split('CheckpointCounterexample')[0]
 assert any(st['s']['entries'] and st['s']['authority']['exposure']==3 and 11 in st['s']['authority']['spent'] for st in states[:-1]),name
 assert s['laneCalls']==1 and s['sourceCalls']==0,name
 initialized=[st for st in states if 'c' in st]
 assert initialized and all(st['s']==initialized[0]['s'] for st in initialized),('metadata invented provider observations',name)
 if name in ['missingApplication','missingReservation','unknownHold']:
  cp=c['published'][0];image=cp['basis']['head'];reference=cp['basis']['journal'][-1]['after']
  assert cp['position']==1 and cp['parent']==0 and reference['applications'] and reference['used']==[11]
  if name=='missingApplication':assert image['applications']==[] and len(reference['applications'])==1
  elif name=='missingReservation':assert image['used']==[] and image['applications']==reference['applications']
  else:assert image['holds'][12]==0 and reference['holds'][12]==2
 elif name=='prepublicationTrim':assert w['active'] and not c['published'] and c['haveLocal'] and c['local']['position']==1 and not c['suffix']
 elif name=='lostReply':assert w['active'] and c['haveLocal'] and c['published'] and not c['haveObservation']
 elif name=='belowFloor':
  assert w['active'] and not c['haveLocal'] and c['published'][-1]['position']==1
  assert w['records']==a['journal'] and a['qualified'] and a['local']==a['anchor'] and len(c['suffix'])==1
 elif name=='suffixLoss':
  assert w['active'] and a['qualified'] and a['local']==a['anchor'] and a['anchor']['revision']==2
  assert c['local']['position']==1 and c['suffix']==[] and len(w['records'])==1 and len(a['journal'])==2
 elif name=='staleParent':
  assert len(c['published'])==2 and c['published'][0]['parent']==0 and c['published'][1]['parent']==0
  assert c['published'][1]['position']==2 and c['published'][0]['position']==1
 elif name=='floorRollback':
  assert c['published']==[] and c['floorSeen']==1
  assert any(st.get('c',{}).get('published') and st['c']['published'][-1]['position']==1 for st in states[:-1])
 elif name=='staleOwnerReceipt':
  assert w['active'] and a['qualified'] and a['local']==a['anchor'] and w['records']==a['journal']
  assert c['haveObservation'] and c['observed']['epoch']==0 and a['epoch']==1
  assert c['haveLocal'] and c['local']==c['published'][-1] and c['suffix']==[]
 else:raise AssertionError(name)
 records.append(dict(name=name,path=str(p),states=len(states),finalCheckpoint=c,financialRevision=a['anchor']['revision'],financialQualified=a['qualified']))
assert len(records)==10
(out/'counterexample-observations.json').write_text(json.dumps(records,indent=2)+'\n')
print('PASS: ten independently decoded checkpoint violations; complete image, suffix, parent/floor and stale-owner observations verified')
