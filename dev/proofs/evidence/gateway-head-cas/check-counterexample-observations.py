from pathlib import Path
import json,re,hashlib
out=Path('proofs/evidence/gateway-head-cas')
def decode(x):
 if isinstance(x,list):return [decode(y) for y in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(y) for y in x['#set']]
 if '#map' in x:return {str(decode(k)):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
observations=[]
for p in sorted((out/'itf').glob('*.json')):
 j=json.loads(p.read_text());last=decode(j['states'][-1]);g=last['g'];base=last['s']
 if p.name.startswith('semanticPublicationCAS'):assert any(a['job']['view']['version']!=a['at']['version'] for a in g['audits'])
 if p.name.startswith('staleHeadCAS'):assert any(a['job']['view']['version']!=a['at']['version'] for a in g['audits'])
 if p.name.startswith('oldWorkerCAS'):assert any(a['job']['view']['worker']!=a['at']['worker'] for a in g['audits'])
 if p.name.startswith('duplicateRootCompletion'):assert len(g['decisions'])==2 and len({d['view']['head']['key'] for d in g['decisions']})==1
 if p.name.startswith('preparedProjectionAsCommit'):assert len(g['rows'])==1 and g['decisions']==[]
 if p.name.startswith('staleJoinAfterNewFence'):assert g['haveJoin'] and g['joined']['view']['fence']!=g['fence']
 if p.name.startswith('redirectedFinalSend'):assert any(s['route']!=s['view']['head']['route'] for s in g['sends']) and base['messages']['0']['sends']==1
 observations.append(dict(path=str(p),states=len(j['states']),head=g['head'],version=g['version'],worker=g['worker'],fence=g['fence'],decisions=g['decisions'],rows=g['rows'],casAudits=g['audits'],joined=g['joined'],haveJoin=g['haveJoin'],sends=g['sends'],originalMessages={k:base['messages'][k] for k in ['0','1']}))
assert len(observations)==7
(out/'counterexample-observations.json').write_text(json.dumps(observations,indent=2)+'\n')
print('PASS: seven decoded logical Gateway counterexample final states')
