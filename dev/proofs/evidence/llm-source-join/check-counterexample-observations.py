from pathlib import Path
import json
out=Path('proofs/evidence/llm-source-join')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 if '#map' in x:return {decode(k):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
records=[]
for p in sorted((out/'itf').glob('*.json')):
 states=[decode(st) for st in json.loads(p.read_text())['states']];last=states[-1];a,f,j,s=last['a'],last['f'],last['j'],last['s'];name=p.name.split('JoinCounterexample')[0]
 initialized=[st for st in states if 'j' in st]
 assert initialized and all(st['s']==initialized[0]['s'] for st in initialized),('provider execution changed',name)
 assert s['entries'] and s['authority']['exposure']==3 and 11 in s['authority']['spent'] and s['laneCalls']==1 and s['sourceCalls']==0,name
 assert not j['lastChecked'],name
 ticket=j['ticket'];attempt=j['attempted']
 if name=='sameFloorAccount':
  assert ticket['floor']==attempt['floor'] and ticket['account']['revision']==1 and attempt['account']['revision']==2
  assert len(ticket['journal'])==1 and len(attempt['journal'])==2 and a['anchor']==attempt['account']
  assert sorted(a['anchor']['used'])==[11,12] and a['anchor']['holds'][12]==0 and len(a['anchor']['applications'])==2
  assert f['log'][-1]['proposal']['id']==3 and len(f['log'])==4
 else:
  assert a['anchor']['revision']==1 and a['anchor']['used']==[11] and a['anchor']['holds'][12]==2 and len(a['anchor']['applications'])==1,name
  if name=='sourceDenied':
   assert not j['allows'] and j['revision']==1 and ticket['sourceRevision']==0 and attempt['sourceRevision']==1
   assert ticket['account']==attempt['account'] and ticket['floor']==attempt['floor'] and len(f['log'])==4
  elif name=='sourceABA':
   assert j['allows'] and j['revision']==2 and ticket['sourceRevision']==0 and attempt['sourceRevision']==2
   assert ticket['account']==attempt['account'] and ticket['floor']==attempt['floor'] and len(f['log'])==4
   assert any(st.get('j',{}).get('revision')==1 and not st['j']['allows'] for st in states[:-1])
  elif name=='differentIntent':
   assert ticket['operation']==1 and attempt['operation']==2 and ticket['floor']==attempt['floor']
   assert f['log'][-1]['proposal']['id']==2 and f['log'][-1]['proposal']['intent']==20 and len(f['log'])==2
  elif name=='lostReply':
   assert not j['haveTicket'] and f['haveResolved'] and f['resolved']['proposal']['id']==1 and len(f['log'])==2
   assert len(last['h']['live'])==1 and last['h']['frontier']==1 and not f['haveReceipt']
  elif name=='restart':
   assert not j['haveTicket'] and j['allows'] and ticket==attempt and len(f['log'])==4
  elif name=='staleWorker':
   assert not j['haveTicket'] and a['epoch']==1 and attempt['worker']==1 and attempt['proposal']['worker']==0
   assert len(f['log'])==4 and f['log'][-1]['proposal']['id']==3
  else:raise AssertionError(name)
 records.append(dict(name=name,path=str(p),states=len(states),actualFinancialRevision=a['anchor']['revision'],hold12=a['anchor']['holds'][12],sourceRevision=j['revision'],ticketOperation=ticket['operation'],attemptOperation=attempt['operation'],floorRecords=len(f['log'])))
assert len(records)==7
(out/'counterexample-observations.json').write_text(json.dumps(records,indent=2)+'\n')
print('PASS: seven decoded join violations; same-floor actual settlement distinguished from unchanged pending holds; original source execution unchanged')
