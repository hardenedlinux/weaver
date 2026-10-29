from pathlib import Path
import json
out=Path('proofs/evidence/llm-multi-key-registry')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 return {k:decode(v) for k,v in x.items()}
observations=[]
for p in sorted((out/'itf').glob('*.json')):
 states=[decode(x)['s'] for x in json.loads(p.read_text())['states']];s=states[-1]
 name=p.name
 if name.startswith(('duplicateOrigin','duplicateFamily','duplicateClaim')):
  field={'duplicateOrigin':'origin','duplicateFamily':'family','duplicateClaim':'claim'}[name.split('Counterexample')[0]]
  assert any(e!=f and e[field]==f[field] for e in s['rows'] for f in s['rows'])
  assert any(len(st['rows'])==1 and st['rows'][0]['origin']==10 for st in states[:-1])
 elif name.startswith('aliasRebind'):
  assert any(a!=b and a['key']==b['key'] for a in s['aliases'] for b in s['aliases'])
 elif name.startswith(('oldOwner','staleSource')):
  u=s['uses'][-1];r=u['request'];field='fence' if name.startswith('oldOwner') else 'source'
  assert r in s['pending'] and r[field]!=u[field]
  assert any(r in st['pending'] and st['fence']==r['fence'] and st['source']==r['source'] and st['revision']==r['parent'] for st in states[:-1])
 elif name.startswith('sharedBudget'):
  assert s['charged']==6 and s['calls']==1 and 12 in s['spent']
  assert any(st['charged']==3 and st['calls']==1 for st in states[:-1])
 elif name.startswith('rollback'):
  assert 12 in s['everSpent'] and 12 not in s['spent'] and s['charged']==0
  assert any(12 in st['spent'] and st['charged']==3 for st in states[:-1])
 elif name.startswith('conflictingDecision'):
  assert any(a['request']['id']==b['request']['id'] and a!=b for a in s['decisions'] for b in s['decisions'])
 elif name.startswith('droppedPending'):
  assert any(d['request'] not in s['pending'] for d in s['decisions'])
  assert any(st['pending'] and st['decisions'] for st in states[:-1])
 else:raise AssertionError(p)
 observations.append(dict(path=str(p),states=len(states),violation=name.split('Counterexample')[0],final=s))
assert len(observations)==10
(out/'counterexample-observations.json').write_text(json.dumps(observations,indent=2)+'\n')
source=Path('proofs/qunit/LlmMultiKeyRegistry.qnt').read_text();log=(out/'tests.log').read_text()
for name in ['freshReceiptStillSeesSpentClaimTest','freshReceiptStillSeesHistoryDenialTest']:
 segment=source.split('  run '+name,1)[1].split('  run ',1)[0]
 assert '.expect(fresh(' in segment and '.then(consume(' in segment,name
 assert ('ok '+name+' passed') in log,name
print('PASS: ten independently decoded counterexamples; real staged stale requests and two fresh-current source-denial controls verified')
