from pathlib import Path
import json
out=Path('proofs/evidence/llm-admission-floor')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 if '#map' in x:return {decode(k):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
records=[]
for p in sorted((out/'itf').glob('*.json')):
 states=[decode(st) for st in json.loads(p.read_text())['states']];last=states[-1];f,h,a,s=last['f'],last['h'],last['a'],last['s'];name=p.name.split('FloorCounterexample')[0]
 initialized=[st for st in states if 'f' in st]
 assert initialized and all(st['s']==initialized[0]['s'] for st in initialized),('provider execution changed',name)
 assert s['entries'] and s['authority']['exposure']==3 and 11 in s['authority']['spent'] and s['laneCalls']==1 and s['sourceCalls']==0,name
 assert a['anchor']['used']==[11] and len(a['anchor']['applications'])==1 and a['anchor']['holds'][12]==2 and len(a['journal'])==1,name
 head=f['log'][-1]['proposal'];local=f['local'];ids=[seg['id'] for seg in f['objects']]
 if name=='missingConfirmation':
  assert f['active'] and not f['haveReceipt'] and f['haveLocal'] and local==head['after'] and local['frontier']==1 and 11 in ids and f['bodies']
 elif name=='oldGeneration':
  assert f['active'] and f['haveReceipt'] and f['observed']['record']==f['log'][-1] and f['observed']['revision']==len(f['log'])
  assert local['appendGeneration']==0 and head['after']['appendGeneration']==h['appendGeneration']==1 and 11 in ids
 elif name=='missingTail':
  assert f['active'] and f['haveReceipt'] and local==head['after'] and local['closed'][0]['id']==11 and 11 not in ids and f['bodies']
 elif name=='oldWorker':
  assert f['active'] and f['haveLocal'] and local==head['after'] and f['observed']['record']==f['log'][-1] and f['haveReceipt']
  assert 11 in ids and f['attemptedWorker']==0 and head['after']['worker']==a['epoch']==1
 elif name=='lateResult':
  assert f['active'] and f['haveResolved'] and f['resolved']['proposal']['id']==1 and f['observed']['record']==f['resolved']
  assert f['observed']['revision']==2 and len(f['log'])==3 and local==head['after'] and head['after']['appendGeneration']==1 and 11 in ids
 elif name=='protectedPrefixRollback':
  assert len(f['log'])==1 and head['id']==0 and head['after']['appendGeneration']==0 and h['appendGeneration']==1 and h['closed'][0]['id']==11
  assert any(len(st.get('f',{}).get('log',[]))==3 for st in states[:-1])
 elif name=='oldWorkerCommit':
  assert head['id']==4 and head['parent']==4 and head['worker']==f['attemptedWorker']==0
  assert head['before']['worker']==1 and head['after']['worker']==a['epoch']==2 and f['log'][-2]['proposal']['after']==head['before']
 elif name=='duplicateOperation':
  matching=[r['proposal'] for r in f['log'] if r['proposal']['id']==1]
  assert len(matching)==2 and matching[0]['after']['appendGeneration']==0 and matching[1]['after']['appendGeneration']==1 and h['appendGeneration']==0
 else:raise AssertionError(name)
 records.append(dict(name=name,path=str(p),states=len(states),revision=len(f['log']),headOperation=head['id'],headGeneration=head['after']['appendGeneration'],localGeneration=local['appendGeneration'],objectIds=ids,currentWorker=a['epoch'],attemptedWorker=f['attemptedWorker'],actualRemainingHold=a['anchor']['holds'][12]))
assert len(records)==8
(out/'counterexample-observations.json').write_text(json.dumps(records,indent=2)+'\n')
print('PASS: eight independently decoded floor violations; current-head/image/body/caller premises isolated; actual provider execution and pending hold unchanged')
