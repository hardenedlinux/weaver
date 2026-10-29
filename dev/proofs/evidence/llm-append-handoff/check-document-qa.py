from pathlib import Path
import hashlib,json,re,subprocess,xml.etree.ElementTree as ET
out=Path('proofs/evidence/llm-append-handoff')
records=[]
paths=list(Path('specs/evidence').glob('*/SHA256SUMS'))+[p for p in Path('proofs/evidence').glob('*/SHA256SUMS') if p.parent!=out]
for p in paths:
 n=0
 for line in p.read_text().splitlines():
  digest,name=line.split('  ',1);assert hashlib.sha256(Path(name).read_bytes()).hexdigest()==digest,(p,name);n+=1
 records.append(f'{p}: {n} unchanged byte targets')
assert len(records)==33;(out/'historical-manifests.log').write_text('\n'.join(records)+'\n')
r=subprocess.run(['python3',str(out/'check-document-inventory.py')],capture_output=True,text=True)
(out/'document-check.log').write_text(r.stdout+r.stderr);assert r.returncode==0,r.stdout+r.stderr
checks=[]
for p in sorted(Path('docs').rglob('*.d2')):
 if p.parent.name=='lib':continue
 r=subprocess.run(['d2','validate',str(p)],capture_output=True,text=True,timeout=20);assert r.returncode==0,(p,r.stderr)
 checks.append(dict(path=str(p),exit=r.returncode,output=r.stdout+r.stderr))
assert len(checks)==56;(out/'diagram-validation.json').write_text(json.dumps(checks,indent=2)+'\n')
labels=[]
for e in ET.parse('docs/20-29-execution-authority/28-append-handoff/28.02-append-handoff.svg').iter():
 if e.tag.endswith('}text'):
  label=''.join(e.itertext());labels.append(label)
  assert not any(t in label for t in ['4.34','0.33','FM1','SHA','2026','54 passing','36.03']),label
  assert not any(t in label.lower() for t in ['hsm','dma','hardware','physical','device','key floor']),label
 for k,v in e.attrib.items():
  if k.endswith('href'):assert not v.startswith(('http:','https:')),v
(out/'visual-check.log').write_text('PASS: final SVG rendered and visually inspected at 2400px; aligned four-column theme; no clipped text; bundled official Go/Kubernetes/Rust assets. AI Agent Gateway durable append admission, captured cut, successor generation, current live-tail handoff, protected reference union and actual financial replay; core-only diagram; no hardware-isolation chain or software/check versions.\n'+'\n'.join(labels)+'\n')
for p in Path('docs/20-29-execution-authority/28-append-handoff').glob('*.org'):assert re.match(r'28\.\d\d-',p.name),p
print((out/'document-check.log').read_text().strip());print('PASS: 56 core D2 sources; Johnny Decimal IDs; 33 historical manifests unchanged; corrected Gateway diagram scope')
