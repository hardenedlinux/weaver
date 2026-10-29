from pathlib import Path
import json
out=Path('proofs/evidence/llm-authoritative-scope')
def decode(x):
 if isinstance(x,list):return [decode(y) for y in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(y) for y in x['#set']]
 if '#map' in x:return {str(decode(k)):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
observations=[]
for p in sorted((out/'itf').glob('*.json')):
 j=json.loads(p.read_text());s=decode(j['states'][-1])['s'];rows=s['uses']
 if p.name.startswith('forgedDomain'):assert rows[0]['ticket']['scope']['budget']==99 and rows[0]['ticket']['scope']['history']==99
 elif p.name.startswith('responseDowngrade'):assert not(rows[0]['ticket']['scope']['document']) and s['record']['document']
 elif p.name.startswith('foreignClaim'):assert rows[0]['record']['claim']==12 and rows[0]['record']['input']==10
 elif p.name.startswith('staleAuthority'):assert rows[0]['ticket']['image']!=rows[0]['actual'] and rows[0]['actual']['version']==1
 elif p.name.startswith('historyAlias'):assert 9 in s['history'] and not(rows[0]['historyClear'])
 elif p.name.startswith('toolExpansion'):assert 9 in rows[0]['ticket']['scope']['tools'] and 9 not in s['record']['tools']
 elif p.name.startswith('newScopeReplay'):assert s['calls']['0']==2
 elif p.name.startswith('unknownRefund'):assert s['parentCharged'] and not(s['closed']) and s['usage']['0']== -1
 else:raise AssertionError(p)
 observations.append(dict(path=str(p),states=len(j['states']),authority=s))
assert len(observations)==8
(out/'counterexample-observations.json').write_text(json.dumps(observations,indent=2)+'\n')
print('PASS: eight independently decoded authoritative-scope counterexamples')
