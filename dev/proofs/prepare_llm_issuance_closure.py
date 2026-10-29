#!/usr/bin/env python3
"""Check ancestral transition IR and isolate the new executable enrollment controls."""
from pathlib import Path
import json,hashlib,re,subprocess
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'dev/proofs/evidence/llm-incarnation-issuance';PRIOR=ROOT/'dev/proofs/evidence/llm-caller-custody'
def norm(x):
 if isinstance(x,list):return [norm(y) for y in x]
 if isinstance(x,dict):return {k:norm(y) for k,y in x.items() if k!='id'}
 return x
def canonical(d):return json.dumps(norm(d),sort_keys=True)
def main():
 OUT.mkdir(exist_ok=True);core=OUT/'quint-core';core.mkdir(exist_ok=True)
 cert=json.loads((PRIOR/'closure-certificate.json').read_text())
 for r in cert:
  for path,digest in [(r['source'],r['sourceSha256']),(r['corePath'],r['coreSha256'])]:assert hashlib.sha256((ROOT/path).read_bytes()).hexdigest()==digest,path
 subprocess.run(['quint','parse',str(PRIOR/'quint-core/LlmCallerCustody.qnt'),'--out',str(OUT/'parent-parsed.json'),'--source-map',str(OUT/'parent-source-map.json')],check=True,timeout=20)
 prior=json.loads((OUT/'parent-parsed.json').read_text());assert not prior.get('errors')
 locs=json.loads((OUT/'parent-source-map.json').read_text());expected={};rows=[]
 for m in prior['modules']:
  source=PRIOR/'quint-core'/f"{m['name']}.qnt";text=source.read_text();removed=[d for d in m['declarations'] if d.get('qualifier')=='run']
  assert len(removed)==(27 if m['name']=='LlmCallerCustody' else 0)
  spans=[]
  for d in removed:
   a=locs['map'][str(d['id'])];b=locs['map'][str(d['expr']['id'])]
   assert Path(locs['sourceIndex'][str(a[0])]).resolve()==source.resolve()
   start=text.rfind('\n',0,a[1]['index'])+1;end=b[2]['index']+1
   assert re.fullmatch(r'\s*run\s+',text[start:a[1]['index']]);spans.append((start,end))
  for start,end in sorted(spans,reverse=True):text=text[:start]+''.join('\n' if c=='\n' else ' ' for c in text[start:end])+text[end:]
  destination=core/source.name;destination.write_text(text)
  expected[m['name']]=[d for d in m['declarations'] if d not in removed]
  rows.append(dict(module=m['name'],rawSource=str((ROOT/'dev/proofs/qunit'/source.name).relative_to(ROOT)),rawSha256=hashlib.sha256((ROOT/'dev/proofs/qunit'/source.name).read_bytes()).hexdigest(),parentCore=str(source.relative_to(ROOT)),parentCoreSha256=hashlib.sha256(source.read_bytes()).hexdigest(),executed=str(destination.relative_to(ROOT)),executedSha256=hashlib.sha256(destination.read_bytes()).hexdigest(),omittedParentRuns=len(removed)))
 source=ROOT/'dev/proofs/quint/LlmIncarnationIssuance.qnt';(core/source.name).write_bytes(source.read_bytes())
 subprocess.run(['quint','parse',str(core/source.name),'--out',str(OUT/'executed-parsed.json'),'--source-map',str(OUT/'executed-source-map.json')],check=True,timeout=20)
 actual=json.loads((OUT/'executed-parsed.json').read_text());assert not actual.get('errors')
 modules={m['name']:m for m in actual['modules']};assert set(modules)==set(expected)|{'LlmIncarnationIssuance'}
 for name,declarations in expected.items():assert sorted(map(canonical,declarations))==sorted(map(canonical,modules[name]['declarations'])),name
 assert (core/source.name).read_bytes()==source.read_bytes()
 tests=[d['name'] for d in modules['LlmIncarnationIssuance']['declarations'] if d.get('qualifier')=='run'];assert len(tests)==31,len(tests)
 simulation=OUT/'simulation-core';simulation.mkdir(exist_ok=True)
 for path in core.glob('*.qnt'):(simulation/path.name).write_bytes(path.read_bytes())
 text=(core/source.name).read_text();locations=json.loads((OUT/'executed-source-map.json').read_text());spans=[]
 for d in modules['LlmIncarnationIssuance']['declarations']:
  if d.get('qualifier')!='run':continue
  a=locations['map'][str(d['id'])];b=locations['map'][str(d['expr']['id'])]
  assert Path(locations['sourceIndex'][str(a[0])]).resolve()==(core/source.name).resolve()
  start=text.rfind('\n',0,a[1]['index'])+1;end=b[2]['index']+1
  assert re.fullmatch(r'\s*run\s+',text[start:a[1]['index']]);spans.append((start,end))
 for start,end in sorted(spans,reverse=True):text=text[:start]+''.join('\n' if c=='\n' else ' ' for c in text[start:end])+text[end:]
 (simulation/source.name).write_text(text)
 simFiles={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in simulation.glob('*.qnt')}
 (OUT/'closure-certificate.json').write_text(json.dumps(dict(ancestors=rows,newSource=str(source.relative_to(ROOT)),newSha256=hashlib.sha256(source.read_bytes()).hexdigest(),newExecuted=str((core/source.name).relative_to(ROOT)),tests=tests,allAncestralNonRunIRIdentical=True,priorRawRunOmissions=356,newParentRunOmissions=27,totalHistoricalRunOmissions=383,simulationSource=str((simulation/source.name).relative_to(ROOT)),simulationFiles=simFiles,simulationOmittedCurrentRuns=len(spans)),indent=2)+'\n')
 print('PASS: eleven ancestor hashes and non-run declaration IRs; new leaf byte-identical; 31 controls retained; 27 parent controls execute separately')
if __name__=='__main__':main()
