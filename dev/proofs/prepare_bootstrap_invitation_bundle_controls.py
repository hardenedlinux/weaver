#!/usr/bin/env python3
from pathlib import Path
import json,hashlib,re
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'dev/proofs/evidence/llm-bootstrap-invitation'
a=json.loads((OUT/'bundle-parsed.json').read_text());loc=json.loads((OUT/'bundle-source-map.json').read_text());m=next(m for m in a['modules'] if m['name']=='LlmBootstrapInvitation');runs=[d for d in m['declarations'] if d.get('qualifier')=='run'];rows=[]
for n in range(0,len(runs),4):
 keep=runs[n:n+4];text=(OUT/'bundle/LlmBootstrapInvitation.qnt').read_text();spans=[]
 for d in runs:
  if d in keep:continue
  aa=loc['map'][str(d['id'])];bb=loc['map'][str(d['expr']['id'])]
  start=text.rfind('\n',0,aa[1]['index'])+1;end=bb[2]['index']+1
  assert re.fullmatch(r'\s*run\s+',text[start:aa[1]['index']]);spans.append((start,end))
 for start,end in sorted(spans,reverse=True):text=text[:start]+''.join('\n' if c=='\n' else ' ' for c in text[start:end])+text[end:]
 folder=OUT/f'bundle-controls-{n//4}';folder.mkdir(exist_ok=True);p=folder/'LlmBootstrapInvitation.qnt';p.write_text(text)
 rows.append(dict(source=str(p.relative_to(ROOT)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),tests=[d['name'] for d in keep],omittedOnlyOtherRunSpans=True))
assert len(runs)==23
(OUT/'bundle-control-shards.json').write_text(json.dumps(rows,indent=2)+'\n')
print('PASS: all current control source spans retained exactly once in six import-bundled groups')
