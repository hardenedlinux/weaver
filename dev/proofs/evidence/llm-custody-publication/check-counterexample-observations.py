from pathlib import Path
import json
out=Path('proofs/evidence/llm-custody-publication')
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
 initialized=[st for st in states if 'pub' in st];assert initialized
 last=initialized[-1];a,f,c,pub,s=[last[k] for k in ['a','f','custody','pub','s']]
 name=p.name.split('PublicationCounterexample')[0];head=pub['log'][-1]
 assert all(st['s']==initialized[0]['s'] for st in initialized),name
 assert s['authority']['exposure']==3 and 11 in s['authority']['spent'] and s['laneCalls']==1 and s['sourceCalls']==0,name
 assert a['anchor']['used']==[11] and a['anchor']['holds'][12]==2 and len(a['anchor']['applications'])==1,name
 assert c['original']['id']==1 and c['original']['intent']==12,name
 if name=='splitFence':
  assert c['fence']==1 and head['fence']==0 and not c['haveOutcome'] and len(f['log'])==1 and pub['reply']>len(pub['log']),name
 elif name=='splitOutcome':
  assert c['haveOutcome'] and not head['haveOutcome'] and len(f['log'])==2 and len(head['floor'])==1 and pub['reply']>len(pub['log']),name
  assert len(last['h']['live'])==1 and last['h']['frontier']==1,name
 elif name=='lostOutcome':assert not c['haveOutcome'] and head['haveOutcome'] and len(f['log'])==2 and head['outcome']['proposal']['id']==1,name
 elif name=='droppedOriginal':assert not c['haveIntent'] and head['haveIntent'] and len(f['log'])==2,name
 elif name in ['untrustedCopy','lateAck']:
  assert pub['qualified'] and not pub['lastChecked'] and pub['copy']==head and pub['seen']==len(pub['log']) and len(f['log'])==2,name
  assert any(st['pub']['haveCopy'] and not st['pub']['qualified'] for st in initialized[:-1]),name
  if name=='lateAck':assert pub['haveReply'] and pub['reply']==1 and pub['reply']<len(pub['log']),name
 elif name=='oldWorker':
  assert c['fence']==1 and c['holder']==1 and a['epoch']==0 and not c['lastChecked'] and len(f['log'])==2,name
  assert head['fence']==c['fence'] and head['outcome']==c['outcome'] and head['floor']==f['log'],name
  assert len(last['h']['live'])==1 and last['h']['frontier']==1,name
 else:raise AssertionError(name)
 records.append(dict(name=name,path=str(p),states=len(states),custodyFence=c['fence'],journalFence=head['fence'],journalRecords=len(pub['log']),actualFloorRecords=len(f['log']),journalFloorRecords=len(head['floor']),hold12=a['anchor']['holds'][12],sourceCalls=s['sourceCalls']))
assert len(records)==7
(out/'counterexample-observations.json').write_text(json.dumps(records,indent=2)+'\n')
print('PASS: seven independently decoded publication violations; actual split writes and stale-worker append distinguished from qualification markers; original provider execution and unknown hold unchanged')
