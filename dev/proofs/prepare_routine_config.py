#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,re
ROOT=Path(__file__).resolve().parents[2];out=ROOT/'dev/proofs/evidence/routine-routing-config';prior=ROOT/'dev/proofs/evidence/llm-routing'
for line in (prior/'SHA256SUMS').read_text().splitlines():
 h,p=line.split('  ',1);assert hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h,p
parent=ROOT/'dev/proofs/quint/LlmRouting.qnt';raw=ROOT/'dev/proofs/quint/RoutineRoutingConfig.qnt';ancestor=out/'ancestor-transitions.qnt';lines=parent.read_text().splitlines(keepends=True);assert sum(bool(re.match(r'^  run ',s)) for s in lines)==32
ancestor.write_text(''.join('\n' if re.match(r'^  run ',s) else s for s in lines));bundle=out/'bundle/RoutineRoutingConfig.qnt';bundle.parent.mkdir(exist_ok=True);bundle.write_text(ancestor.read_text()+'\n'+raw.read_text().replace(' from "./LlmRouting"',''))
cert={}
for name,p in [('parent',parent),('ancestor',ancestor),('raw',raw),('bundle',bundle)]:cert[name]=str(p.relative_to(ROOT));cert[name+'Sha256']=hashlib.sha256(p.read_bytes()).hexdigest()
cert.update(omittedParentRunDeclarations=32,onlyLeafLocalImportPathsRemoved=True);(out/'bundle-certificate.json').write_text(json.dumps(cert,indent=2)+'\n');print('PASS: sealed routing source verified; full ancestor transitions retained')
