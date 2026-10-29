from pathlib import Path
import json
out=Path('proofs/evidence/llm-beneficiary-registration')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 if '#map' in x:return {decode(k):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
rows=[]
def states(p):
 result=[decode(s) for s in json.loads(p.read_text())['states']]
 return [s for s in result if all(k in s for k in ['enrollment','invitations','registry','a','auth','s','f','custody'])]
def shared(st,p):
 a,auth,source,f,c=[st[k] for k in ['a','auth','s','f','custody']]
 assert source['sourceCalls']==0 and source['laneCalls']==1 and source['authority']['spent']==[11] and source['authority']['exposure']==3,p
 assert a['anchor']['used']==[11] and a['anchor']['holds'][12]==2 and len(a['anchor']['applications'])==1,p
 assert len(f['log'])==1 and c['original']['intent']==12 and auth['grant']['inc']==0,p
for p in sorted((out/'itf').glob('*RegistrationCounterexampleTest*.json')):
 trace=states(p);assert trace;last=trace[-1];e,i,issued=[last[k] for k in ['enrollment','invitations','registry']];name=p.name.split('RegistrationCounterexample')[0];shared(last,p)
 assert all(s['s']==trace[0]['s'] for s in trace),p
 assert issued['issued']==[],p
 if name=='sharedIdentity':assert e['claims'][0]['peer']['enrollmentKey']==100 and e['claims'][0]['root']['enrollmentKey']==500 and e['bindings']==[0] and i['registered']==[]
 elif name=='replacedKey':assert e['claims'][0]['ticket']['target']['key']==201 and i['bindings'][0]['target']['key']==200 and e['published']==[0]
 elif name=='missingOutcome':assert i['registered']==[0] and e['published']==[] and e['bindings']==[0]
 elif name=='splitPublication':assert i['registered']==[] and e['published']==[0] and e['bindings']==[0]
 elif name=='rollbackFirstBinding':assert i['registered']==[0] and e['published']==[0] and e['bindings']==[]
 else:raise AssertionError(name)
 rows.append(dict(name=name,path=str(p),states=len(trace),firstBindings=e['bindings'],published=e['published'],actualRegistered=i['registered'],pendingIssued=issued['issued'],unknownHold12=last['a']['anchor']['holds'][12],providerCalls=last['s']['sourceCalls'],activeIncarnation=last['auth']['grant']['inc']))
assert len(rows)==5,len(rows)
probe=list((out/'itf').glob('unjoinedImageCannotConsumeTest*.json'));assert len(probe)==1
trace=states(probe[0]);assert trace;last=trace[-1];shared(last,probe[0]);e,i,issued=[last[k] for k in ['enrollment','invitations','registry']]
assert i['registered']==[0] and e['published']==[] and i['seen']==i['revision'] and issued['issued']==[]
commands=json.loads((out/'api-commands.json').read_text());assert any('unjoinedImageCannotConsumeTest' in r.get('passed',[]) for r in commands)
result=dict(faults=rows,quarantineProbe=dict(path=str(probe[0]),classification='Fully defined pre-rejection state; terminal fail has no admitted successor',parentReadCurrent=True,publicationJoined=False,pendingIssued=[],unknownHold12=2,providerCalls=0,guardedConsumptionRejected=True))
(out/'counterexample-observations.json').write_text(json.dumps(result,indent=2)+'\n')
print('PASS: five decoded publication/identity faults and one parent-read bypass rejection; original hold retained, no new issuance or provider call')
