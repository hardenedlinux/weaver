from pathlib import Path
import json
out=Path('proofs/evidence/llm-bootstrap-invitation')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 if '#map' in x:return {decode(k):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
rows=[]
for p in sorted((out/'itf').glob('*InvitationCounterexampleTest*.json')):
 states=[decode(s) for s in json.loads(p.read_text())['states']];states=[s for s in states if 'invitations' in s];assert states
 last=states[-1];i,b,a,auth,source,f=[last[k] for k in ['invitations','registry','a','auth','s','f']];name=p.name.split('InvitationCounterexample')[0]
 assert all(st['s']==states[0]['s'] for st in states),name
 assert source['authority']['exposure']==3 and source['authority']['spent']==[11] and source['sourceCalls']==0
 assert a['anchor']['used']==[11] and a['anchor']['holds'][12]==2 and len(a['anchor']['applications'])==1
 assert len(f['log'])==1 and auth['grant']['inc']==0
 if name=='bearerOnly':assert 0 in b['issued'] and not i['spent']
 elif name=='lostConsumptionRecord':assert 0 in b['issued'] and not i['spent']
 elif name=='splitCommit':assert i['spent']==[0] and not b['issued'] and i['results'][0]!=i['bindings'][0]
 elif name=='replacedKeyBinding':assert 0 in b['issued'] and i['spent']==[0] and i['results'][0]!=i['bindings'][0]
 else:raise AssertionError(name)
 rows.append(dict(name=name,path=str(p),states=len(states),issued=b['issued'],spent=i['spent'],activeIncarnation=auth['grant']['inc'],unknownHold12=a['anchor']['holds'][12],providerCalls=source['sourceCalls'],actualFloorRecords=len(f['log'])))
assert len(rows)==4,len(rows)
(out/'counterexample-observations.json').write_text(json.dumps(rows,indent=2)+'\n')
print('PASS: four decoded invitation/issuance faults; pending custody only, original hold intact and zero provider calls')
