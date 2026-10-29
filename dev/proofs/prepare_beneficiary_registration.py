#!/usr/bin/env python3
"""Preserve the sealed predecessor transition source; append the new leaf."""
from pathlib import Path
import json,hashlib,re
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'dev/proofs/evidence/llm-beneficiary-registration';PRIOR=ROOT/'dev/proofs/evidence/llm-bootstrap-invitation'
parent=PRIOR/'bundle-simulation/LlmBootstrapInvitation.qnt';cert=json.loads((PRIOR/'simulation-bundle-certificate.json').read_text())
assert hashlib.sha256(parent.read_bytes()).hexdigest()==cert['sha256']
# Verify the sealed receipt that binds the parent parser and simulation source.
for line in (PRIOR/'SHA256SUMS').read_text().splitlines():
 digest,name=line.split('  ',1);assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest,name
raw=ROOT/'dev/proofs/quint/LlmBeneficiaryRegistration.qnt';text=raw.read_text();new=re.sub(r'(\bimport [^\n]+?) from "\./[A-Za-z0-9_]+"',r'\1',text)
folder=OUT/'bundle';folder.mkdir(exist_ok=True);p=folder/raw.name;p.write_text(parent.read_text()+'\n'+new)
assert len(set(re.findall(r'^module (\w+)\s*\{',p.read_text(),re.M)))==14
(OUT/'bundle-certificate.json').write_text(json.dumps(dict(parent=str(parent.relative_to(ROOT)),parentSha256=hashlib.sha256(parent.read_bytes()).hexdigest(),raw=str(raw.relative_to(ROOT)),rawSha256=hashlib.sha256(raw.read_bytes()).hexdigest(),bundle=str(p.relative_to(ROOT)),bundleSha256=hashlib.sha256(p.read_bytes()).hexdigest(),onlyLeafLocalImportPathsRemoved=True,ancestralSourceUnchanged=True),indent=2)+'\n')
print('PASS: sealed predecessor bytes verified; thirteen complete ancestor transition modules plus the raw leaf with only local import paths removed')
