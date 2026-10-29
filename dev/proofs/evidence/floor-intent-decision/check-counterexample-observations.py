from pathlib import Path
import json,hashlib,re
out=Path('proofs/evidence/floor-intent-decision')
def decode(x):
 if isinstance(x,list):return [decode(y) for y in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(y) for y in x['#set']]
 if '#map' in x:return {str(decode(k)):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
observations=[]
for p in sorted((out/'itf').glob('*.json')):
 j=json.loads(p.read_text());s=decode(j['states'][-1]);f=s['f'];d=s['d'];slot=f['slot'];decisions=f['decisions']
 if p.name.startswith(('timeoutUnlock','negativeResolution')):
  assert not f['haveSlot'] and slot in f['accepted'] and not any(r['intent']==slot and r['kind']==1 for r in decisions)
 if p.name.startswith('lateCommitAfterFence'):
  assert len([r for r in decisions if r['intent']==slot])==2 and slot['cut'] not in d['journal']
 if p.name.startswith('rollbackDecisionPrefix'):
  assert not f['haveSlot'] and decisions==[] and len(f['accepted'])==2
 if p.name.startswith('oldWorkerReceipt'):
  assert f['observed'] and f['receipt']['intent']!=slot
 observations.append(dict(path=str(p),states=len(j['states']),worker=f['worker'],fence=f['fence'],haveSlot=f['haveSlot'],slot=slot,accepted=f['accepted'],decisions=decisions,observed=f['observed'],receipt=f['receipt'],floorJournal=d['journal']))
assert len(observations)==5
(out/'counterexample-observations.json').write_text(json.dumps(observations,indent=2)+'\n')
print('PASS: five decoded counterexample final states')
