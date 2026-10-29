#!/usr/bin/env python3
"""Bundle source-equivalent local modules without recursive file imports."""
from pathlib import Path
import hashlib,json,re
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'dev/proofs/evidence/llm-bootstrap-invitation';folder=OUT/'bundle';folder.mkdir(exist_ok=True)
core=OUT/'quint-core';raw=ROOT/'dev/proofs/quint/LlmBootstrapInvitation.qnt'
(core/raw.name).write_bytes(raw.read_bytes());sources=sorted(core.glob('*.qnt'));rows=[];texts=[];names=[]
for p in sources:
 text=p.read_text();name=re.search(r'module (\w+)\s*\{',text)[1];names.append(name)
 # Only remove local file resolution clauses; preserve module names, aliases and bodies.
 transformed=re.sub(r'(\bimport [^\n]+?) from "\./[A-Za-z0-9_]+"',r'\1',text)
 rows.append(dict(source=str(p.relative_to(ROOT)),sourceSha256=hashlib.sha256(p.read_bytes()).hexdigest(),module=name,transformedSha256=hashlib.sha256(transformed.encode()).hexdigest()))
 texts.append(transformed)
assert len(names)==len(set(names))==13
path=folder/raw.name;path.write_text('\n'.join(texts))
(OUT/'bundle-certificate.json').write_text(json.dumps(dict(sources=rows,bundle=str(path.relative_to(ROOT)),bundleSha256=hashlib.sha256(path.read_bytes()).hexdigest(),onlyLocalImportClausesRemoved=True),indent=2)+'\n')
print('PASS: thirteen unique modules bundled; only local import resolution clauses removed')
