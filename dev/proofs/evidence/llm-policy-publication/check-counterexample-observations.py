from pathlib import Path
import json
out=Path('proofs/evidence/llm-policy-publication')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 return {k:decode(v) for k,v in x.items()}
observations=[]
for p in sorted((out/'itf').glob('*.json')):
 j=json.loads(p.read_text());states=[decode(x)['s'] for x in j['states']];s=states[-1]
 if p.name.startswith('prematureAck'):
  assert len(s['acks'])==1 and s['log']==[] and s['acks'][0]['change'] in s['staged']
 elif p.name.startswith('lostReplyReplay'):
  assert len(s['log'])==2 and s['log'][0]['change']==s['log'][1]['change'] and s['visible']==0
  assert s['log'][0]['generation']==1 and s['log'][1]['generation']==2
 elif p.name.startswith('staleParent'):
  assert len(s['log'])==2
  first,last=s['log'];assert first['change']['id']==10 and last['change']['id']==11
  assert last['generation']==2 and last['change']['parentGeneration']==0 and last['change']['parentTip']==0
 elif p.name.startswith('lateAckRollback'):
  assert len(s['log'])==2 and not s['log'][-1]['change']['allowed'] and s['log'][-1]['generation']==2
  assert s['acks']==[s['log'][0]] and s['acks'][0]['change']['allowed'] and s['generation']==1
  u=s['uses'][-1];permit=u['permit']
  assert permit['id']==1 and permit['generation']==1 and u['actualGeneration']==2 and not u['allowed']
  assert permit in s['permits'] and any(permit in st['permits'] and st['generation']==1 and len(st['log'])==1 for st in states[:-1])
 elif p.name.startswith('oldPublisher'):
  r=s['log'][-1];assert r['worker']==0 and r['acceptedFence']==s['fence']==1
  assert r['change'] in s['staged'] and any(st['fence']==0 and r['change'] in st['staged'] for st in states[:-1])
 elif p.name.startswith('tornRecovery'):
  assert s['visible']==0 and not s['stageVisible'] and not s['ackVisible']
  assert len(s['log'])==1 and not s['log'][0]['change']['allowed']
  u=s['uses'][-1];permit=u['permit'];assert permit['generation']==0 and u['actualGeneration']==1 and not u['allowed']
  assert permit in s['permits'] and permit in states[0]['permits']
 elif p.name.startswith('idAlias'):
  c=s['log'][-1]['change'];assert c['id']==10 and c['content']==101 and c['allowed']
  assert c not in s['staged'] and any(old['id']==10 and old['content']==100 and not old['allowed'] for old in s['staged'])
 elif p.name.startswith('unknownRefund'):
  assert s['spent'] and s['calls']==1 and s['usage']==-1 and s['hold']==0 and s['charged'] and s['acks']
 else:raise AssertionError(p)
 observations.append(dict(path=str(p),states=len(states),authority=s))
assert len(observations)==8
(out/'counterexample-observations.json').write_text(json.dumps(observations,indent=2)+'\n')
print('PASS: eight independently decoded Policy-publication counterexamples; actual prior old-permit issuance, newer durable Deny and historical Allow acknowledgement verified')
