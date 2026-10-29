from pathlib import Path
import json
out=Path('proofs/evidence/llm-join-enqueue')
def decode(x):
 if isinstance(x,list):return [decode(v) for v in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(v) for v in x['#set']]
 return {k:decode(v) for k,v in x.items()}
def joined(s):
 return all(s[name]['position']==len(s['log']) and s[name]['body']==s['authority'] for name in ['sourceStore','accountStore'])
observations=[]
for p in sorted((out/'itf').glob('*.json')):
 states=[decode(x)['s'] for x in json.loads(p.read_text())['states']];s=states[-1];name=p.name.split('JoinCounterexample')[0]
 assert any(st['authority']['exposure']==3 and 11 in st['authority']['spent'] for st in states[:-1]),name
 if name not in ['commitSend','queueRollback']:
  a=s['admissions'][-1];r=a['permit']
  if name!='routeSwap':
   assert r in s['permits'] and any(r in st['permits'] and joined(st) for st in states[:-1]),name
 if name=='staleJoinCommit':assert joined(s) and a['joined'] and r['position']==1 and a['position']==2 and r['body']!=a['body']
 elif name=='oldOwner':
  assert joined(s) and r['epoch']==0 and a['epoch']==1 and r['position']==a['position'] and r['body']==a['body'] and r['policy']==a['policy'] and r['queueRevision']==a['revision']
 elif name=='stalePolicy':assert r['policy']==0 and a['policy']==1 and s['denied']
 elif name in ['sdkReplay','freshKeyClone']:
  assert len(s['admissions'])==2
  original=s['admissions'][0]['permit']['operation'];retry=r['operation']
  assert original['slot']==retry['slot']==11 and r['position']==a['position'] and r['body']==a['body'] and r['epoch']==a['epoch'] and r['policy']==a['policy'] and r['queueRevision']==a['revision']
  if name=='freshKeyClone':assert original['key']==1 and retry['key']==7 and original['source']==retry['source']==1
  else:assert original==retry
 elif name=='commitSend':assert s['sourceCalls']==1 and s['calls']==0 and s['entries']==[]
 elif name=='enqueueSend':assert a['beforeCalls']==0 and a['afterCalls']==1 and s['calls']==1
 elif name=='routeSwap':assert r['operation']['route']==999 and any(p['operation']['route']==100 for p in s['permits'])
 elif name=='partialJoin':assert not joined(s) and not a['joined'] and len(s['log'])==2
 elif name=='queueRollback':assert s['epoch']==1 and s['entries']==[] and len(s['admissions'])==1 and s['queued']==[]
 else:raise AssertionError(name)
 observations.append(dict(path=str(p),states=len(states),violation=name,final=s))
assert len(observations)==10
(out/'counterexample-observations.json').write_text(json.dumps(observations,indent=2)+'\n')
source=Path('proofs/qunit/LlmJoinEnqueue.qnt').read_text();log=(out/'tests.log').read_text()
for name in ['freshQueueReceiptStillSeesOriginalClaimTest','sdkFreshKeyCannotCloneSlotTest','freshPolicyReceiptStillCannotBypassDenialTest']:
 segment=source.split('  run '+name,1)[1].split('  run ',1)[0]
 assert '.expect(gate(' in segment and '.then(enqueue(' in segment,name
 assert ('ok '+name+' passed') in log,name
print('PASS: ten independently decoded join/enqueue violations; actually issued permits, current duplicate-slot attempts and three fresh-gate denial controls verified')
