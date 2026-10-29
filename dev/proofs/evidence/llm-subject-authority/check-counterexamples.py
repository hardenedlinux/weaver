from pathlib import Path
import json
out=Path('proofs/evidence/llm-subject-authority')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 if '#map' in x:return {decode(k):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
def states(p):return [decode(s) for s in json.loads(p.read_text())['states'] if all(k in s for k in ['authority','ledger','enrollment','registry','a','auth','s','f','custody'])]
def original(s):
 assert s['s']['sourceCalls']==0 and s['s']['laneCalls']==1
 assert s['s']['authority']['spent']==[11] and s['s']['authority']['exposure']==3
 assert s['a']['anchor']['used']==[11] and len(s['a']['anchor']['applications'])==1 and s['a']['anchor']['holds'][12]==2
 assert s['custody']['original']['intent']==12 and len(s['f']['log'])==1
 assert s['auth']['grant']['inc']==0 and s['registry']['issued']==[]
 assert s['ledger']['credentials']==[] and s['enrollment']['roots']==[]
passed=[t for r in json.loads((out/'api-commands.json').read_text()) for t in r.get('passed',[])]
rows=[]
for p in sorted((out/'itf').glob('*CounterexampleTest-*.json')):
 trace=states(p);assert trace,p;s=trace[-1];original(s);v=s['authority'];l=s['ledger'];name=p.name.split('-')[0];assert name in passed
 assert all(st['s']==trace[0]['s'] for st in trace)
 if name=='forgedAuthorityCounterexampleTest':assert v['subject']['authority']==2
 elif name=='replacedEnrollmentCounterexampleTest':assert v['assignment']['plan']['root']['enrollmentKey']==501 and l['planRows'][0]['root']['enrollmentKey']==500
 elif name=='erasedAssignmentCounterexampleTest':assert not v['assigned'] and l['plans']==[0]
 elif name=='missingPlanOutcomeCounterexampleTest':assert not v['published'] and l['plans']==[0]
 elif name=='phantomPlanOutcomeCounterexampleTest':assert v['published'] and l['plans']==[]
 else:raise AssertionError(name)
 rows.append(dict(name=name,path=str(p),states=len(trace),assignmentPresent=v['assigned'],publicationOutcome=v['published'],actualPlans=l['plans'],providerCalls=0,unknownHold12=2,activeIncarnation=0))
assert len(rows)==5
p=next((out/'itf').glob('splitRecoveryCannotIssueTest-*.json'));trace=states(p);s=trace[-1];original(s)
assert s['ledger']['plans']==[0] and not s['authority']['published']
assert s['ledger']['seen']==s['ledger']['revision'] and s['authority']['seen']==s['authority']['revision']
assert 'splitRecoveryCannotIssueTest' in passed
(out/'counterexample-observations.json').write_text(json.dumps(dict(faults=rows,quarantineProbe=dict(path=str(p),classification='Fully defined pre-rejection state; terminal fail has no admitted successor',childReadCurrent=True,outerReadCurrent=True,planOutcomeJoined=False,newCredentialIssuanceRejected=True,unknownHold12=2,providerCalls=0)),indent=2)+'\n')
print('PASS: five decoded source/assignment/Plan faults and one fresh-read bypass rejection; original unknown hold retained')
