from pathlib import Path
import json
out=Path('proofs/evidence/llm-caller-custody')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 if '#map' in x:return {decode(k):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
records=[]
for p in sorted((out/'itf').glob('*.json')):
 states=[decode(s) for s in json.loads(p.read_text())['states']];states=[s for s in states if 'auth' in s]
 assert states
 last=states[-1];auth,c,pub,f,a,source=[last[k] for k in ['auth','custody','pub','f','a','s']]
 g=auth['grant'];name=p.name.split('CallerCounterexample')[0]
 assert all(st['s']==states[0]['s'] for st in states)
 assert source['authority']['exposure']==3 and source['authority']['spent']==[11] and source['laneCalls']==1 and source['sourceCalls']==0
 assert a['anchor']['holds'][12]==2 and a['anchor']['used']==[11] and len(a['anchor']['applications'])==1
 assert c['original']['id']==1 and c['original']['intent']==12
 if name=='sharedIdentity':assert g['inc']==1 and g['key']==200 and c['fence']==1 and c['holder']==1 and len(f['log'])==2 and not auth['checked']
 elif name=='expiry':assert auth['now']>=g['expires'] and len(f['log'])==2 and not auth['checked']
 elif name=='splitGrant':assert c['fence']==1 and pub['log'][-1]['fence']==1 and g['fence']==0 and len(auth['caps'])<len(pub['log']) and len(f['log'])==1
 elif name=='workloadMint':assert g['inc']==0 and g['key']==100 and auth['caps'][-1]['inc']==1 and len(f['log'])==1
 elif name=='redeliveryRenew':assert g['expires']==20 and auth['caps'][-1]['expires']==10 and len(f['log'])==2
 elif name=='restartReuse':assert auth['used']==[] and g['inc']==1 and len(f['log'])==1
 elif name=='rotationOldKey':assert g['inc']==0 and g['key']==101 and g['serial']==1 and not auth['checked'] and len(f['log'])==1
 else:raise AssertionError(name)
 records.append(dict(name=name,path=str(p),states=len(states),incarnation=g['inc'],key=g['key'],custodyFence=c['fence'],grantFence=g['fence'],actualFloorRecords=len(f['log']),hold12=a['anchor']['holds'][12],providerCalls=source['sourceCalls'],qualificationMonitor=auth['checked']))
assert len(records)==7
(out/'counterexample-observations.json').write_text(json.dumps(records,indent=2)+'\n')
print('PASS: seven independently decoded caller/capability violations; actual floor appends distinguished from qualification markers; original unknown hold and provider execution unchanged')
