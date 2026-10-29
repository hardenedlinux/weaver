from pathlib import Path
import re,json
base=Path('docs/10-19-llm-gateway/15-recovery-cas')
org=(base/'15.03-validation-evidence.org').read_text()
q=Path('proofs/qunit/LlmRecoveryCAS.qnt').read_text()
l=Path('proofs/lean/LlmRecoveryCAS.lean').read_text()
d=(base/'15.02-recovery-cas.d2').read_text()
rows=[]
for line in org.splitlines():
 if not re.match(r'^\| RC\d+ ',line):continue
 fields=[f.strip() for f in line.strip('|').split('|')]
 ident,design,test,theorem,node=fields
 assert re.search(r'run '+test+r'\b',q),test
 assert ('ok '+test+' passed') in Path('proofs/evidence/llm-recovery-cas/tests.log').read_text(),test
 assert ("'Weaver.LlmRecoveryCAS."+theorem+"'") in Path('proofs/evidence/llm-recovery-cas/LlmRecoveryCAS.log').read_text(),theorem
 assert re.search(r'theorem '+theorem+r'\b',l),theorem
 parent,child=node.split('.')
 assert re.search(r'^'+parent+r':',d,re.M) and re.search(r'^  '+child+r':',d,re.M),node
 rows.append(dict(id=ident,design=design,quint=test,lean=theorem,d2=node))
assert len(rows)==12 and len({r['id'] for r in rows})==12
Path('proofs/evidence/llm-recovery-cas/four-artifacts.json').write_text(json.dumps(rows,indent=2)+'\n')
print('PASS: twelve design / Quint / Lean / D2 mappings resolve to actual declarations')
