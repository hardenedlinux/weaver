from pathlib import Path
import json
out=Path('proofs/evidence/llm-enrollment-credential')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 if '#map' in x:return {decode(k):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
def states(p):return [decode(s) for s in json.loads(p.read_text())['states'] if all(k in s for k in ['ledger','enrollment','registry','a','auth','s','f','custody'])]
def original(s):
 assert s['s']['sourceCalls']==0 and s['s']['laneCalls']==1
 assert s['s']['authority']['spent']==[11] and s['s']['authority']['exposure']==3
 assert s['a']['anchor']['used']==[11] and len(s['a']['anchor']['applications'])==1 and s['a']['anchor']['holds'][12]==2
 assert s['custody']['original']['intent']==12 and len(s['f']['log'])==1
 assert s['auth']['grant']['inc']==0 and s['registry']['issued']==[]
passed=[t for r in json.loads((out/'api-commands.json').read_text()) for t in r.get('passed',[])]
rows=[]
for p in sorted((out/'itf').glob('*CounterexampleTest-*.json')):
 trace=states(p);assert trace,p;s=trace[-1];original(s);l=s['ledger'];b=s['enrollment'];name=p.name.split('-')[0];assert name in passed
 assert all(st['s']==trace[0]['s'] for st in trace)
 if name=='forgedSubjectCounterexampleTest':assert l['rows'][0]['peer']['subjectKey']==100 and l['planRows'][0]['subjectKey']==700
 elif name=='erasedCredentialCounterexampleTest':assert l['credentials']==[] and l['activated']==[0] and b['roots']==[0]
 elif name=='erasedReleaseCounterexampleTest':assert l['released']==[] and l['activated']==[0] and b['roots']==[0]
 elif name=='missingActivationOutcomeCounterexampleTest':assert l['activated']==[] and b['roots']==[0]
 elif name=='phantomActivationOutcomeCounterexampleTest':assert l['activated']==[0] and b['roots']==[]
 else:raise AssertionError(name)
 rows.append(dict(name=name,path=str(p),states=len(trace),credentials=l['credentials'],released=l['released'],activated=l['activated'],actualRoots=b['roots'],providerCalls=0,unknownHold12=2,activeIncarnation=0))
assert len(rows)==5
p=next((out/'itf').glob('splitRecoveryCannotBindFirstKeyTest-*.json'));trace=states(p);s=trace[-1];original(s)
assert s['enrollment']['roots']==[0] and s['ledger']['activated']==[]
assert s['enrollment']['seen']==s['enrollment']['revision'] and s['enrollment']['bindings']==[]
assert 'splitRecoveryCannotBindFirstKeyTest' in passed
(out/'counterexample-observations.json').write_text(json.dumps(dict(faults=rows,quarantineProbe=dict(path=str(p),classification='Fully defined pre-rejection state; terminal fail has no admitted successor',parentReadCurrent=True,rootOutcomeJoined=False,firstBindingRejected=True,unknownHold12=2,providerCalls=0)),indent=2)+'\n')
print('PASS: five decoded credential/root faults and one fresh-parent-read bypass rejection; original unknown hold retained')
