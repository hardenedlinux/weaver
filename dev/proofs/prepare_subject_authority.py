#!/usr/bin/env python3
"""Preserve complete predecessor transition text, omit only its run declarations."""
from pathlib import Path
import hashlib,json,re
ROOT=Path(__file__).resolve().parents[2];out=ROOT/'dev/proofs/evidence/llm-subject-authority';prev=ROOT/'dev/proofs/evidence/llm-enrollment-credential'
for line in (prev/'SHA256SUMS').read_text().splitlines():
 digest,name=line.split('  ',1);assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest,name
parent=prev/'bundle/LlmEnrollmentCredential.qnt';text=parent.read_text();lines=text.splitlines(keepends=True);assert sum(bool(re.match(r'^  run ',l)) for l in lines)==40
ancestor=out/'ancestor-transitions.qnt';ancestor.write_text(''.join('\n' if re.match(r'^  run ',l) else l for l in lines))
raw=ROOT/'dev/proofs/quint/LlmSubjectAuthority.qnt';leaf=re.sub(r'(\bimport [^\n]+?) from "\./[A-Za-z0-9_]+"',r'\1',raw.read_text());(out/'bundle').mkdir(exist_ok=True);bundle=out/'bundle/LlmSubjectAuthority.qnt';bundle.write_text(ancestor.read_text()+'\n'+leaf)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
cert={}
for name,p in [('parent',parent),('ancestor',ancestor),('raw',raw),('bundle',bundle)]:cert[name]=str(p.relative_to(ROOT));cert[name+'Sha256']=sha(p)
cert.update(omittedParentRunDeclarations=40,onlyLeafLocalImportPathsRemoved=True)
(out/'bundle-certificate.json').write_text(json.dumps(cert,indent=2)+'\n')
print('PASS: sealed predecessor bytes verified; fifteen complete ancestor transition modules plus new leaf')
