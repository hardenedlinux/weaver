from pathlib import Path
import json
out=Path('proofs/evidence/llm-routing')
def decode(x):
 if isinstance(x,list):return [decode(y) for y in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(y) for y in x['#set']]
 if '#map' in x:return {str(decode(k)):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
observations=[]
for p in sorted((out/'itf').glob('*.json')):
 j=json.loads(p.read_text());r=decode(j['states'][-1])['r']
 if p.name.startswith('stalePolicy'):assert any(d['plan']['view']!=d['snapshot'] for d in r['dispatches'])
 elif p.name.startswith('quotaBypass'):assert any(d['plan']['target']==5 for d in r['dispatches'])
 elif p.name.startswith('foreignWire'):assert any(d['plan']['manifest']!=100+d['plan']['target'] for d in r['dispatches'])
 elif p.name.startswith('unknownRetry'):assert len(r['dispatches'])==2 and r['unknown']
 elif p.name.startswith('mixedStream'):assert any(not any(d['plan']==p for d in r['dispatches']) for p in r['responses'])
 elif p.name.startswith('newAliasRoot'):assert any(d['plan']['root']!=0 for d in r['dispatches'])
 else:raise AssertionError(p)
 observations.append(dict(path=str(p),states=len(j['states']),router=r))
assert len(observations)==6,len(observations)
(out/'counterexample-observations.json').write_text(json.dumps(observations,indent=2)+'\n')
print('PASS: six independently decoded LLM routing counterexamples')
