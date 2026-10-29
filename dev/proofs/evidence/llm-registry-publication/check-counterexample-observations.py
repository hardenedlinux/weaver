from pathlib import Path
import json
out=Path('proofs/evidence/llm-registry-publication')
def decode(x):
 if isinstance(x,list):return [decode(y) for y in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(y) for y in x['#set']]
 return {k:decode(v) for k,v in x.items()}
observations=[]
for p in sorted((out/'itf').glob('*.json')):
 j=json.loads(p.read_text());states=[decode(st)['s'] for st in j['states']];s=states[-1]
 if p.name.startswith('replacedIntent'):
  assert s['locked'] and s['first']==20 and s['binding']['blob']['commitment']==21 and not s['binding']['blob']['document']
 elif p.name.startswith('localAbsenceReplay'):
  assert s['journal']==2 and s['visible']==0 and s['binding']['blob']['commitment']==20
 elif p.name.startswith('prematureCertificate'):
  assert s['certified'] and s['journal']==0 and s['locked']
 elif p.name.startswith('foreignSnapshot'):
  assert s['active'] and s['projection']['binding']['blob']['commitment']==21 and s['binding']['blob']['commitment']==20
 elif p.name.startswith('oldWorker'):
  u=s['uses'][0];permit=u['permit']
  assert permit['id']==0 and permit['worker']==0 and permit['image']['fence']==0 and permit['image']['revision']==0
  assert permit in s['permits'] and any(permit in st['permits'] and st['fence']==0 for st in states[:-1])
  assert u['actual']['fence']==s['fence']==1 and u['actual']['revision']==s['revision']==2
 elif p.name.startswith('staleExecution'):
  assert s['active'] and s['projection']['revision']==0 and s['revision']==1 and s['offered']
  assert any(p['id']==0 and p['image']==s['projection'] for p in s['permits'])
 elif p.name.startswith('missingBlob'):
  assert s['active'] and s['readable']==[] and s['blobs'] and s['certified']
 elif p.name.startswith('unknownRefund'):
  assert s['charged'] and not s['closed'] and s['usage']==-1 and s['allocated']==6 and s['calls']==1
 else:raise AssertionError(p)
 observations.append(dict(path=str(p),states=len(states),authority=s))
assert len(observations)==8
(out/'counterexample-observations.json').write_text(json.dumps(observations,indent=2)+'\n')
print('PASS: eight independently decoded registry-publication counterexamples; actual prior issuance and newer owner/revision verified')
