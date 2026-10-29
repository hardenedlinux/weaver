#!/usr/bin/env python3
"""Partition control declarations without changing retained declaration IR."""
from pathlib import Path
import hashlib,json,re,subprocess
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'dev/proofs/evidence/llm-bootstrap-invitation'
def norm(x):
 if isinstance(x,list):return [norm(v) for v in x]
 if isinstance(x,dict):return {k:norm(v) for k,v in x.items() if k!='id'}
 return x
def canon(x):return json.dumps(norm(x),sort_keys=True)
a=json.loads((OUT/'executed-parsed.json').read_text());locs=json.loads((OUT/'executed-source-map.json').read_text())
module=next(m for m in a['modules'] if m['name']=='LlmBootstrapInvitation');runs=[d for d in module['declarations'] if d.get('qualifier')=='run'];rows=[]
for n in range(0,len(runs),4):
 keep=runs[n:n+4];folder=OUT/f'controls-{n//4}';folder.mkdir(exist_ok=True)
 for p in (OUT/'quint-core').glob('*.qnt'):(folder/p.name).write_bytes(p.read_bytes())
 p=folder/'LlmBootstrapInvitation.qnt';text=p.read_text();spans=[]
 for d in runs:
  if d in keep:continue
  aa=locs['map'][str(d['id'])];bb=locs['map'][str(d['expr']['id'])]
  start=text.rfind('\n',0,aa[1]['index'])+1;end=bb[2]['index']+1
  assert re.fullmatch(r'\s*run\s+',text[start:aa[1]['index']]);spans.append((start,end))
 for start,end in sorted(spans,reverse=True):text=text[:start]+''.join('\n' if c=='\n' else ' ' for c in text[start:end])+text[end:]
 p.write_text(text)
 parsed=folder/'parsed.json';subprocess.run(['quint','parse',str(p),'--out',str(parsed)],check=True,timeout=20)
 b=json.loads(parsed.read_text());assert not b.get('errors')
 expected={m['name']:m['declarations'] for m in a['modules']};expected['LlmBootstrapInvitation']=[d for d in module['declarations'] if d.get('qualifier')!='run' or d in keep]
 for m in b['modules']:assert sorted(map(canon,m['declarations']))==sorted(map(canon,expected[m['name']])),m['name']
 rows.append(dict(source=str(p.relative_to(ROOT)),tests=[d['name'] for d in keep],identicalRetainedIR=True,files={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in folder.glob('*.qnt')}))
assert [t for row in rows for t in row['tests']]==[d['name'] for d in runs]
(OUT/'control-shards.json').write_text(json.dumps(rows,indent=2)+'\n')
print('PASS: all 23 controls partitioned once; every retained declaration IR unchanged')
