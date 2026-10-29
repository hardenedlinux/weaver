from pathlib import Path
import json
out=Path('proofs/evidence/llm-wal-activation')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 if '#map' in x:return {decode(k):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
records=[]
for p in sorted((out/'itf').glob('*.json')):
 states=[decode(st) for st in json.loads(p.read_text())['states']];last=states[-1];a,w,s=last['a'],last['w'],last['s'];name=p.name.split('WalCounterexample')[0]
 assert any(st['s']['entries'] and st['s']['authority']['exposure']==3 and 11 in st['s']['authority']['spent'] for st in states[:-1]),name
 assert s['laneCalls']==1 and s['sourceCalls']==0,name
 if name=='walAsMoney':assert w['records'] and not w['candidates'] and a['anchor']['revision']==1 and a['everReleased']==1
 elif name=='acceptanceAsConfirmation':
  assert w['candidates'] and a['anchor']['revision']==0 and not a['journal'] and w['receipt']['head']['revision']==1 and w['active'] and a['qualified']
  assert w['receipt']['epoch']==a['epoch']==0 and a['local']==a['anchor']
 elif name=='truncatedWal':assert w['active'] and w['records']==[] and a['anchor']['revision']==1 and a['qualified'] and a['local']==a['anchor']
 elif name=='oldSnapshot':assert w['active'] and a['local']['revision']==0 and a['anchor']['revision']==1 and a['epoch']==1
 elif name=='staleConfirmation':
  assert w['active'] and a['qualified'] and a['local']==a['anchor'] and w['records']==a['journal']
  assert w['receipt']['epoch']==0 and a['epoch']==1 and w['receipt']['head']==a['anchor']
 elif name=='lostReplyRetry':assert len(a['journal'])==2 and all(r['proposal']['transaction']['key']['reservation']==11 for r in a['journal']) and not w['haveReceipt']
 elif name=='sharedRollback':assert a['anchor']['revision']==0 and not a['journal'] and a['everReleased']==1 and a['everCharged']==2
 elif name=='forgedWalBody':assert w['active'] and len(w['records'])==len(a['journal'])==1 and w['records'][0]['proposal']['transaction']['usage']==1 and a['journal'][0]['proposal']['transaction']['usage']==2
 elif name=='oldCandidateRetry':assert len(a['journal'])==2 and a['epoch']==1 and a['journal'][-1]['epoch']==1 and a['journal'][-1]['proposal']['worker']==0
 elif name=='unconfirmedTailRefund':assert w['records'] and not w['candidates'] and not w['haveReceipt'] and a['anchor']['revision']==1 and a['everReleased']==1
 else:raise AssertionError(name)
 records.append(dict(name=name,path=str(p),states=len(states),finalWal=w,finalAccount=a))
assert len(records)==10
(out/'counterexample-observations.json').write_text(json.dumps(records,indent=2)+'\n')
print('PASS: ten independently decoded WAL/confirmation violations; actual original execution and financial history verified')
