from pathlib import Path
import json
out=Path('proofs/evidence/llm-semantic-contract')
def decode(x):
 if isinstance(x,list):return [decode(y) for y in x]
 if not isinstance(x,dict):return x
 if '#bigint' in x:return int(x['#bigint'])
 if '#set' in x:return [decode(y) for y in x['#set']]
 if '#map' in x:return {str(decode(k)):decode(v) for k,v in x['#map']}
 return {k:decode(v) for k,v in x.items()}
observations=[]
for p in sorted((out/'itf').glob('*.json')):
 j=json.loads(p.read_text());s=decode(j['states'][-1])['s']
 if p.name.startswith('roleDrop'):assert s['sealed'] and s['wire']['projection']['roles']==[3]
 elif p.name.startswith('targetSwap'):assert s['sealed'] and s['wire']['target']==0
 elif p.name.startswith('mixedWinner'):assert s['outputs'][-1]['attempt']==2
 elif p.name.startswith('partialTool'):assert len(s['proposals'])==1 and not(s['proposals'][0]['finished'])
 elif p.name.startswith('partialSchema'):assert s['outputs'][-1]['kind']==2 and not(s['outputs'][-1]['complete'])
 elif p.name.startswith('bufferOverflow'):assert len(s['buffers']['0'])==5
 else:raise AssertionError(p)
 observations.append(dict(path=str(p),states=len(j['states']),protocol=s))
assert len(observations)==6
(out/'counterexample-observations.json').write_text(json.dumps(observations,indent=2)+'\n')
print('PASS: six independently decoded semantic-contract counterexamples')
