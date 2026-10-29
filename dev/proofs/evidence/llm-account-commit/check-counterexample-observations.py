from pathlib import Path
import json
out=Path('proofs/evidence/llm-account-commit')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 if '#map' in x:return {decode(k):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
records=[]
for p in sorted((out/'itf').glob('*.json')):
 states=[decode(x) for x in json.loads(p.read_text())['states']];last=states[-1];a,e,s=last['a'],last['e'],last['s'];name=p.name.split('AccountCounterexample')[0]
 assert any(st['s']['entries'] and st['s']['authority']['exposure']==3 and 11 in st['s']['authority']['spent'] for st in states[:-1]),name
 assert s['laneCalls']==1 and s['sourceCalls']==0,name
 image=a['anchor'];txs=image['applications'];journal=a['journal']
 if name=='idWithoutDelta':assert len(txs)==1 and txs[0]['id']==100 and image['balance']==dict(available=5,held=5,charged=0) and journal==[]
 elif name=='deltaWithoutId':assert txs==[] and image['used']==[] and image['balance']==dict(available=6,held=2,charged=2) and a['everReleased']==1
 elif name=='retryAfterLostReply':assert len(journal)==2 and all(r['proposal']['transaction']['key']['reservation']==11 for r in journal) and len(txs)==1
 elif name=='newIdSameReservation':assert {t['id'] for t in txs}=={100,999} and all(t['key']['reservation']==11 for t in txs) and len(journal)==2
 elif name=='staleSharedBalance':assert len(journal)==2 and journal[1]['proposal']['before']['revision']==0 and journal[0]['after']['revision']==1
 elif name=='oldWorker':assert a['epoch']==1 and journal[-1]['epoch']==1 and journal[-1]['proposal']['worker']==0 and journal[-1]['proposal']['before']==journal[-2]['after']
 elif name=='mixedIdBalance':assert a['qualified'] and a['local']['applications']==image['applications'] and a['local']['balance']!=image['balance'] and image['revision']==a['local']['revision']==1
 elif name=='anchorRollback':assert image['revision']==0 and image['applications']==[] and journal==[] and a['everReleased']==1 and a['everCharged']==2
 elif name=='unknownBudget':assert e['usage']==-1 and e['source']==[] and s['unknown'] and a['everReleased']==1 and txs[0]['key']['reservation']==11
 elif name=='tombstoneLoss':assert txs and txs[0]['key']['reservation']==11 and image['used']==[]
 else:raise AssertionError(name)
 records.append(dict(name=name,path=str(p),states=len(states),sourceUsage=e['usage'],dispatchCalls=s['laneCalls'],finalAccount=a))
assert len(records)==10
(out/'counterexample-observations.json').write_text(json.dumps(records,indent=2)+'\n')
print('PASS: ten independently decoded account violations; actual original source/executor history and financial observations verified')
