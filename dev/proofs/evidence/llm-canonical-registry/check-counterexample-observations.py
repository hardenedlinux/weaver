from pathlib import Path
import json
out=Path('proofs/evidence/llm-canonical-registry')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 return {k:decode(v) for k,v in x.items()}
observations=[]
for p in sorted((out/'itf').glob('*.json')):
 j=json.loads(p.read_text());states=[decode(x)['s'] for x in j['states']];s=states[-1]
 if p.name.startswith('lostRegistration'):
  assert s['registered'] and s['registrationCount']==2 and s['registration']['root']==99 and sorted(s['families'])==[10,99]
  assert not s['registryVisible'] and any(st['registered'] and st['registration']['root']==10 for st in states[:-1])
 elif p.name.startswith('aliasRebind'):
  assert any(a['key']==b['key'] and a['target']['root']==10 and b['target']['root']==99 for a in s['aliases'] for b in s['aliases'])
 elif p.name.startswith('newTaskFamily'):
  assert s['spent'] and s['calls']==1 and s['usage']==-1 and 61 in s['families']
  assert any(a['key']['protocol']==2 and a['key']['task']==61 and a['target']['root']==61 for a in s['aliases'])
 elif p.name.startswith('snapshotRollback'):
  assert s['everSpent'] and not s['spent'] and s['calls']==0 and s['hold']==0 and s['sourceRevision']==0
  assert any(st['spent'] and st['calls']==1 and st['sourceRevision']==1 for st in states[:-1])
  assert s['registration']['root']==10 and s['registrationCount']==1
 elif p.name.startswith('oldOwner'):
  u=s['uses'][-1];r=u['resolution']
  assert r['id']==0 and r in s['resolutions'] and r['image']['fence']==0 and u['actual']['fence']==s['fence']==1
  assert any(r in st['resolutions'] and st['fence']==0 and st['online'] for st in states[:-1])
 elif p.name.startswith('staleResolution'):
  u=s['uses'][-1];r=u['resolution']
  assert r in s['resolutions'] and r['image']['revision']==2 and u['actual']['revision']==3
  assert r['image']['sourceRevision']==u['actual']['sourceRevision']==0 and r['image']['fence']==u['actual']['fence']==0
  assert any(a['key']['protocol']==2 and a['target']['root']==10 for a in s['aliases'])
 elif p.name.startswith('claimReset'):
  assert s['everSpent'] and not s['spent'] and s['calls']==1 and s['hold']==0 and s['usage']==-1
  assert any(a['key']['protocol']==2 and a['target']['root']==10 for a in s['aliases'])
 elif p.name.startswith('droppedPending'):
  assert s['registered'] and s['registration']['root']==10 and not s['pending'] and s['registryVisible']
  assert any(st['pending'] and len(st['aliases'])==2 for st in states[:-1])
 else:raise AssertionError(p)
 observations.append(dict(path=str(p),states=len(states),authority=s))
assert len(observations)==8
(out/'counterexample-observations.json').write_text(json.dumps(observations,indent=2)+'\n')
# These controls must pass current identity admission before testing the original source denial.
source=Path('proofs/qunit/LlmCanonicalRegistry.qnt').read_text()
for name,receipt,sourceGuard in [('originalClaimCannotBeConsumedTwiceTest','spentResolution','s.spent'),
 ('freshNewTaskResolutionCannotResetClaimTest','newTaskResolution','s.spent'),
 ('originalHistoryDenialStillAppliesTest','deniedResolution','s.historyDenied')]:
 line=next(line for line in source.splitlines() if 'run '+name+'=' in line)
 assert '.expect(gate('+receipt+') and '+sourceGuard+')' in line,name
 assert ('ok '+name+' passed') in (out/'tests.log').read_text(),name
print('PASS: eight independently decoded canonical-registry counterexamples; actual old resolution issuance and three passing fresh-current identity/source-denial controls verified')
