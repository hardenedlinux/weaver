from pathlib import Path
import json
out=Path('proofs/evidence/llm-manifest-switch')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 if '#map' in x:return {decode(k):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
records=[]
for p in sorted((out/'itf').glob('*.json')):
 states=[decode(st) for st in json.loads(p.read_text())['states']];last=states[-1];a,c,m,s=last['a'],last['c'],last['m'],last['s'];name=p.name.split('ManifestCounterexample')[0]
 assert any(st['s']['entries'] and st['s']['authority']['exposure']==3 and 11 in st['s']['authority']['spent'] for st in states[:-1]),name
 initialized=[st for st in states if 'm' in st]
 assert initialized and all(st['s']==initialized[0]['s'] for st in initialized),('provider state changed',name)
 assert s['laneCalls']==1 and s['sourceCalls']==0,name
 assert a['anchor']['used']==([11,12] if name in ['interruptedDelete','suffixLoss'] else [11]),name
 assert len(a['anchor']['applications'])==(2 if name in ['interruptedDelete','suffixLoss'] else 1),name
 assert a['anchor']['holds'][12]==(0 if name in ['interruptedDelete','suffixLoss'] else 2),name
 ids=[seg['id'] for seg in m['objects']];root=m['root']
 if name=='beforeSwitch':assert root['id']==0 and root['segments'][0]['id']==10 and 10 not in ids and any(x['id']==1 for x in m['manifests'])
 elif name=='interruptedDelete':assert root['id']==1 and root['segments'][0]['id']==11 and not ids and len(c['suffix'])==1
 elif name=='lostAck':assert root['id']==1 and not m['haveObservation'] and not m['lastDeleteAuthorized'] and 10 not in ids
 elif name=='staleOwner':assert a['epoch']==1 and m['observed']['worker']==1 and not m['lastDeleteAuthorized'] and root['id']==1
 elif name=='staleGeneration':assert m['generation']==1 and m['observed']['generation']==1 and not m['lastDeleteAuthorized']
 elif name=='rootRollback':assert root['id']==0 and 10 not in ids and c['haveLocal'] and c['local']['id']==1 and any(st.get('m',{}).get('root',{}).get('id')==1 for st in states[:-1])
 elif name=='suffixLoss':assert root['id']==1 and not root['segments'] and len(c['suffix'])==1 and a['anchor']['revision']==2
 elif name=='pathnameRebind':assert root['id']==0 and ids==[10] and m['objects'][0]['records']!=root['segments'][0]['records']
 else:raise AssertionError(name)
 records.append(dict(name=name,path=str(p),states=len(states),finalRoot=root,generation=m['generation'],objectIds=ids,financialRevision=a['anchor']['revision'],remainingHold=a['anchor']['holds'][12]))
assert len(records)==8
(out/'counterexample-observations.json').write_text(json.dumps(records,indent=2)+'\n')
print('PASS: eight decoded manifest violations; actual provider state unchanged; original application/reservation/hold history retained')
