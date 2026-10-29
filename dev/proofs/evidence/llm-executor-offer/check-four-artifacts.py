from pathlib import Path
import re,json
base=Path('docs/20-29-execution-authority/22-executor-offer')
org=(base/'22.03-proof-and-source-evidence.org').read_text()
q=Path('proofs/qunit/LlmExecutorOffer.qnt').read_text()
l=Path('proofs/lean/LlmExecutorOffer.lean').read_text()
d=(base/'22.02-executor-offer.d2').read_text()
rows=[]
for line in org.splitlines():
 if not re.match(r'^\| EO\d+ ',line):continue
 fields=[f.strip() for f in line.strip('|').split('|')]
 ident,design,test,theorem,node=fields
 assert re.search(r'run '+test+r'\b',q),test
 assert ('ok '+test+' passed') in Path('proofs/evidence/llm-executor-offer/tests.log').read_text(),test
 assert ("'Weaver.LlmExecutorOffer."+theorem+"'") in Path('proofs/evidence/llm-executor-offer/LlmExecutorOffer.log').read_text(),theorem
 assert re.search(r'theorem '+theorem+r'\b',l),theorem
 parent,child=node.split('.')
 assert re.search(r'^'+parent+r':',d,re.M) and re.search(r'^  '+child+r':',d,re.M),node
 rows.append(dict(id=ident,design=design,quint=test,lean=theorem,d2=node))
assert len(rows)==18 and len({r['id'] for r in rows})==18
Path('proofs/evidence/llm-executor-offer/four-artifacts.json').write_text(json.dumps(rows,indent=2)+'\n')
print('PASS: eighteen design / Quint / Lean / D2 mappings resolve to actual declarations')
