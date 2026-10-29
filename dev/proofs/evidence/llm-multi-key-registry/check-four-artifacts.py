from pathlib import Path
import re,json
base=Path('docs/10-19-llm-gateway/19-multi-key-registry')
org=(base/'19.03-proof-and-source-evidence.org').read_text()
q=Path('proofs/qunit/LlmMultiKeyRegistry.qnt').read_text()
l=Path('proofs/lean/LlmMultiKeyRegistry.lean').read_text()
d=(base/'19.02-multi-key-registry.d2').read_text()
rows=[]
for line in org.splitlines():
 if not re.match(r'^\| MK\d+ ',line):continue
 fields=[f.strip() for f in line.strip('|').split('|')]
 ident,design,test,theorem,node=fields
 assert re.search(r'run '+test+r'\b',q),test
 assert ('ok '+test+' passed') in Path('proofs/evidence/llm-multi-key-registry/tests.log').read_text(),test
 assert ("'Weaver.LlmMultiKeyRegistry."+theorem+"'") in Path('proofs/evidence/llm-multi-key-registry/LlmMultiKeyRegistry.log').read_text(),theorem
 assert re.search(r'theorem '+theorem+r'\b',l),theorem
 parent,child=node.split('.')
 assert re.search(r'^'+parent+r':',d,re.M) and re.search(r'^  '+child+r':',d,re.M),node
 rows.append(dict(id=ident,design=design,quint=test,lean=theorem,d2=node))
assert len(rows)==14 and len({r['id'] for r in rows})==14
Path('proofs/evidence/llm-multi-key-registry/four-artifacts.json').write_text(json.dumps(rows,indent=2)+'\n')
print('PASS: fourteen design / Quint / Lean / D2 mappings resolve to actual declarations')
