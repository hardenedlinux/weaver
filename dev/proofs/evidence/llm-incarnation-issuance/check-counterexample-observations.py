from pathlib import Path
import json
out=Path('proofs/evidence/llm-incarnation-issuance')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 if '#map' in x:return {decode(k):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
rows=[]
for p in sorted((out/'itf').glob('*.json')):
 states=[decode(s) for s in json.loads(p.read_text())['states']];states=[s for s in states if 'registry' in s];assert states
 last=states[-1];r,c,a,auth,source,f=[last[k] for k in ['registry','custody','a','auth','s','f']];g=auth['grant'];name=p.name.split('IssuanceCounterexample')[0]
 assert all(st['s']==states[0]['s'] for st in states),name
 assert source['authority']['exposure']==3 and source['authority']['spent']==[11] and source['laneCalls']==1 and source['sourceCalls']==0,name
 assert a['anchor']['used']==[11] and a['anchor']['holds'][12]==2 and len(a['anchor']['applications'])==1,name
 assert len(f['log'])==1 and c['original']['id']==1 and c['original']['intent']==12,name
 t=r['tickets'][0]
 if name=='sharedIdentity':
  assert g['inc']==1 and g['key']==200 and g['fence']==1 and c['fence']==1 and 0 in r['outcomes'] and not r['checked']
  assert 0 in r['proofs'] and t['target']['key']!=100 and t['session']!=50
 elif name=='noProof':assert g['inc']==1 and 0 in r['outcomes'] and 0 not in r['proofs'] and not r['checked']
 elif name=='revokedProof':assert g['inc']==1 and r['epoch']==1 and t['epoch']==0 and 0 in r['proofs'] and not r['checked']
 elif name=='keySubstitution':assert g['inc']==0 and t['target']['key']==100 and r['proofTickets'][0]['target']['key']==200 and not r['checked']
 elif name=='rollbackIssue':assert g['inc']==0 and r['issued']==[] and r['launches']==[] and r['reserved']==[0] and 0 in r['proofs']
 elif name=='lostActivationResult':assert g['inc']==1 and g['key']==200 and g['fence']==1 and r['outcomes']==[] and not r['checked']
 else:raise AssertionError(name)
 rows.append(dict(name=name,path=str(p),states=len(states),activeIncarnation=g['inc'],activeKey=g['key'],custodyFence=c['fence'],issuerEpoch=r['epoch'],issued=r['issued'],proven=r['proofs'],outcomes=r['outcomes'],actualFloorRecords=len(f['log']),unknownHold12=a['anchor']['holds'][12],providerCalls=source['sourceCalls']))
assert len(rows)==6,len(rows)
(out/'counterexample-observations.json').write_text(json.dumps(rows,indent=2)+'\n')
print('PASS: six decoded issue/proof/activation violations; actual custody activation distinguished from registry/qualification mutations; floor/provider state and original unknown hold unchanged')
