from pathlib import Path
import re,json
base=Path('docs/10-19-llm-gateway/12-semantic-contracts')
org=(base/'12.03-validation-evidence.org').read_text()
q=Path('proofs/qunit/LlmSemanticContract.qnt').read_text()
l=Path('proofs/lean/LlmSemanticContract.lean').read_text()
d=(base/'12.02-semantic-contract.d2').read_text()
rows=[]
for line in org.splitlines():
 if not re.match(r'^\| SC\d+ ',line):continue
 fields=[f.strip() for f in line.strip('|').split('|')]
 ident,design,test,theorem,node=fields
 assert re.search(r'run '+test+r'\b',q),test
 assert ('ok '+test+' passed') in Path('proofs/evidence/llm-semantic-contract/tests.log').read_text(),test
 assert ("'Weaver.LlmSemanticContract."+theorem+"'") in Path('proofs/evidence/llm-semantic-contract/LlmSemanticContract.log').read_text(),theorem
 assert re.search(r'theorem '+theorem+r'\b',l),theorem
 parent,child=node.split('.')
 assert re.search(r'^'+parent+r':',d,re.M) and re.search(r'^  '+child+r':',d,re.M),node
 rows.append(dict(id=ident,design=design,quint=test,lean=theorem,d2=node))
assert len(rows)==11 and len({r['id'] for r in rows})==11
Path('proofs/evidence/llm-semantic-contract/four-artifacts.json').write_text(json.dumps(rows,indent=2)+'\n')
print('PASS: eleven design / Quint / Lean / D2 mappings resolve to actual declarations')
