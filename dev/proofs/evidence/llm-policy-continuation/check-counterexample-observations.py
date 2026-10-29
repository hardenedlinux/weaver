from pathlib import Path
import json
out=Path('proofs/evidence/llm-policy-continuation')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 return {k:decode(v) for k,v in x.items()}
observations=[]
for p in sorted((out/'itf').glob('*.json')):
 j=json.loads(p.read_text());states=[decode(x)['s'] for x in j['states']];s=states[-1]
 if p.name.startswith('silentRebase'):
  r=s['log'][-1];assert r['change']['root']==10 and r['change']['parent']==1 and not r['reauthorized'] and not s['approvals']
 elif p.name.startswith('lostWinner'):
  own=[r for r in s['log'] if r['change']['root']==10]
  assert len(own)==2 and own[0]['change']['id']==10 and own[1]['change']['id']==11 and s['visibleWinner']==-1
  assert own[1]['change'] in s['staged'] and any(st['winner']==10 and st['visibleWinner']==-1 for st in states[:-1])
 elif p.name.startswith('doubleContinuation'):
  own=[r for r in s['log'] if r['change']['root']==10]
  assert [r['change']['id'] for r in own]==[11,12] and own[1]['change']['parent']==2
  assert own[1]['change'] in s['staged'] and own[1]['actual']==own[1]['approval']
 elif p.name.startswith('staleApproval'):
  r=s['log'][-1];assert r['approval']['revision']==0 and r['actual']['revision']==1 and r['reauthorized']
  assert any(a['candidate']==r['change'] and a['view']==r['approval'] for a in s['approvals'])
 elif p.name.startswith('semanticSwap'):
  r=s['log'][-1];assert r['change']['profile']==21 and r['change'] in s['staged']
  assert any(c['id']==10 and c['profile']==20 for c in s['staged'])
 elif p.name.startswith('lateAck'):
  assert s['log'][-1]['generation']==3 and not s['log'][-1]['change']['allowed'] and 11 in s['acks']
  u=s['uses'][-1];permit=u['permit'];assert permit['id']==1 and permit['generation']==2
  assert u['actual']['generation']==3 and not u['allowed'] and permit in s['permits']
  assert any(permit in st['permits'] and st['generation']==2 and len(st['log'])==2 for st in states[:-1])
 elif p.name.startswith('protocolReset'):
  assert s['everSpent'] and not s['spent'] and s['usage']==-1 and s['hold']==0
  assert any(a['protocol']==2 and a['canonicalRoot']==10 for a in s['aliases'])
 elif p.name.startswith('droppedIntent'):
  assert all(c['id']!=10 for c in s['staged']) and s['approvals']
  assert any(any(c['id']==10 for c in st['staged']) and st['approvals'] for st in states[:-1])
 else:raise AssertionError(p)
 observations.append(dict(path=str(p),states=len(states),authority=s))
assert len(observations)==8
(out/'counterexample-observations.json').write_text(json.dumps(observations,indent=2)+'\n')
print('PASS: eight independently decoded continuation counterexamples; staged candidates, lost existing winner, actual old permit and newer Deny verified')
