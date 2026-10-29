from pathlib import Path
import json,re,hashlib
out=Path('proofs/evidence/fenced-intent-continuation')
def decode(x):
 if isinstance(x,list):return [decode(y) for y in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(y) for y in x['#set']]
 if '#map' in x:return {str(decode(k)):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
observations=[]
for p in sorted((out/'itf').glob('*.json')):
 j=json.loads(p.read_text());s=decode(j['states'][-1]);f=s['f'];d=s['d'];slot=f['slot']
 if p.name.startswith('recutUnlock'):
  assert not f['haveSlot'] and slot in f['accepted'] and not any(l['root']==slot for l in f['commits'])
 if p.name.startswith('newRootLaundering'):assert any(l['root'] not in f['accepted'] for l in f['links'])
 if p.name.startswith('duplicateRootCommit'):assert len(f['commits'])==2 and f['commits'][0]['root']==f['commits'][1]['root'] and f['commits'][0]!=f['commits'][1]
 if p.name.startswith('lostFenceLineage'):assert len(f['links'])==2 and f['retired']==[] and any(l['parent']==0 for l in f['links'])
 if p.name.startswith('rollbackCommittedContinuation'):assert len(f['commits'])==1 and d['journal']==[]
 observations.append(dict(path=str(p),states=len(j['states']),worker=f['worker'],fence=f['fence'],phase=f['phase'],haveSlot=f['haveSlot'],slot=slot,accepted=f['accepted'],originalDecisions=f['decisions'],links=f['links'],retired=f['retired'],commits=f['commits'],floorJournal=d['journal']))
assert len(observations)==5
(out/'counterexample-observations.json').write_text(json.dumps(observations,indent=2)+'\n')
print('PASS: five decoded continuation counterexample final states')
