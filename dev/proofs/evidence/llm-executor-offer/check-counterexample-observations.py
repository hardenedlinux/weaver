from pathlib import Path
import json
out=Path('proofs/evidence/llm-executor-offer')
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
 states=[decode(x)['s'] for x in json.loads(p.read_text())['states']];s=states[-1];name=p.name.split('ExecutorCounterexample')[0]
 assert any(st['entries'] and st['authority']['exposure']==3 and 11 in st['authority']['spent'] for st in states[:-1]),name
 if name in ['stalePolicy','oldOwner','stalePrefix','partialRetry']:
  a=s['executions'][-1];t=a['ticket']
  assert t in s['tickets'] and any(t in st['tickets'] and t in st['burns'] and st['laneCalls']==0 for st in states[:-1]),name
 if name=='stalePolicy':assert a['ticket']['view']['policy']==0 and a['actual']['policy']==1 and not a['allowed'] and s['denied']
 elif name=='oldOwner':assert a['worker']==0 and a['owner']==1 and a['ticket']['view']['epoch']==0 and not s['executionQualified']
 elif name=='unfencedRange':
  a=s['executions'][-1]
  assert a['ticket']['view']==a['actual'] and a['worker']==a['owner']==1 and a['laneOwner']==0
  assert a['ticket']['rangeEpoch']==a['rangeEpoch'] and a['ticket']['revision']==a['revision']
 elif name=='stalePrefix':assert joined(s) and a['ticket']['view']['position']==1 and a['actual']['position']==2 and a['ticket']['view']['body']!=a['actual']['body']
 elif name=='partialRetry':
  assert s['laneCalls']==2 and len(s['executions'])==2 and any(r['bytes']==2 and not r['full'] for r in s['receipts'])
  assert s['executions'][0]['ticket']==s['executions'][1]['ticket']
 elif name=='snapshotReset':assert s['laneCalls']==0 and not s['submitted'] and len(s['executions'])==1 and s['epoch']==1
 elif name=='unknownRefund':assert s['unknown'] and s['submitted'] and s['authority']['exposure']==0 and s['everExposure']==3 and len(s['executions'])==1
 elif name=='forgedCompletion':assert s['full'] and not s['unknown'] and s['receipts'][-1]['bytes']==2 and s['receipts'][-1]['full']
 elif name=='tailRewrite':assert s['executions'][-1]['ticket']['view']['operation']['lo']==2 and s['executions'][-1]['actual']['operation']['lo']==0
 elif name=='dequeueSend':assert s['dequeued'] and s['laneCalls']==1 and s['executions']==[] and not s['submitted']
 else:raise AssertionError(name)
 observations.append(dict(path=str(p),states=len(states),violation=name,final=s))
assert len(observations)==10
(out/'counterexample-observations.json').write_text(json.dumps(observations,indent=2)+'\n')
source=Path('proofs/qunit/LlmExecutorOffer.qnt').read_text();log=(out/'tests.log').read_text()
for name in ['freshTicketStillChecksEffectivePolicyTest','oldWorkerCannotUseFreshRangeTicketTest','currentTicketNeedsFinalOfferAllowTest']:
 segment=source.split('  run '+name,1)[1].split('  run ',1)[0]
 assert '.expect(executionGate(' in segment and ('.then(burn(' in segment or '.then(submit(' in segment),name
 assert ('ok '+name+' passed') in log,name
print('PASS: ten independently decoded executor violations; actual queued/burned tickets, partial progress and three current-gate denial controls verified')
