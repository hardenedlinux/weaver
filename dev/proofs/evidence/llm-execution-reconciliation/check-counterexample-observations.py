from pathlib import Path
import json
out=Path('proofs/evidence/llm-execution-reconciliation')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 return {k:decode(v) for k,v in x.items()}
records=[]
for p in sorted((out/'itf').glob('*.json')):
 states=[decode(x) for x in json.loads(p.read_text())['states']]
 s,e=states[-1]['s'],states[-1]['e'];name=p.name.split('ReconciliationCounterexample')[0]
 assert any(st['s']['entries'] and st['s']['authority']['exposure']==3 and 11 in st['s']['authority']['spent'] for st in states[:-1]),name
 if name=='sourceZero':assert s['sourceCalls']==0 and s['laneCalls']==1 and s['submitted'] and e['decisions'][0]['kind']==1
 elif name=='burnOnly':assert s['burns'] and s['laneCalls']==0 and not s['submitted'] and e['decisions'][0]['kind']==1
 elif name=='fullAsTerminal':assert s['full'] and s['receipts'] and not e['terminalEvidence'] and e['decisions'][0]['kind']==2
 elif name=='unknownRefund':assert s['unknown'] and s['laneCalls']==1 and e['released']==3 and not e['payments']
 elif name=='duplicateSource':assert len(e['source'])==2 and e['source'][0]['decision']==e['source'][1]['decision']==e['decisions'][0]
 elif name=='changedClaim':assert e['source'][0]['decision']['key']['claim']==12 and e['decisions'][0]['key']['claim']==11
 elif name=='missingUsage':assert e['usage']==-1 and len(e['source'])==1 and e['payments'][0]['released']==3
 elif name=='lateUsage':assert e['usage']==0 and e['payments'][0]['amount']==2 and e['released']==1
 elif name=='oldWorker':assert e['epoch']==1 and e['payments'][0]['epoch']==1 and e['payments'][0]['worker']==0
 elif name=='duplicatePayment':assert len(e['payments'])==2 and all(r['decision']==e['decisions'][0] for r in e['payments'])
 else:raise AssertionError(name)
 records.append(dict(name=name,path=str(p),states=len(states),finalSourceCalls=s['sourceCalls'],finalDispatchCalls=s['laneCalls'],final=e))
assert len(records)==10
(out/'counterexample-observations.json').write_text(json.dumps(records,indent=2)+'\n')
print('PASS: ten independently decoded violations; every trace contains original queued/spent/exposure history')
