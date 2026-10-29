from pathlib import Path
import re,json
base=Path('docs/20-29-execution-authority/21-join-enqueue')
org=(base/'21.03-proof-and-source-evidence.org').read_text()
q=Path('proofs/qunit/LlmJoinEnqueue.qnt').read_text()
l=Path('proofs/lean/LlmJoinEnqueue.lean').read_text()
d=(base/'21.02-join-enqueue.d2').read_text()
rows=[]
for line in org.splitlines():
 if not re.match(r'^\| JE\d+ ',line):continue
 fields=[f.strip() for f in line.strip('|').split('|')]
 ident,design,test,theorem,node=fields
 assert re.search(r'run '+test+r'\b',q),test
 assert ('ok '+test+' passed') in Path('proofs/evidence/llm-join-enqueue/tests.log').read_text(),test
 assert ("'Weaver.LlmJoinEnqueue."+theorem+"'") in Path('proofs/evidence/llm-join-enqueue/LlmJoinEnqueue.log').read_text(),theorem
 assert re.search(r'theorem '+theorem+r'\b',l),theorem
 parent,child=node.split('.')
 assert re.search(r'^'+parent+r':',d,re.M) and re.search(r'^  '+child+r':',d,re.M),node
 rows.append(dict(id=ident,design=design,quint=test,lean=theorem,d2=node))
assert len(rows)==16 and len({r['id'] for r in rows})==16
Path('proofs/evidence/llm-join-enqueue/four-artifacts.json').write_text(json.dumps(rows,indent=2)+'\n')
print('PASS: sixteen design / Quint / Lean / D2 mappings resolve to actual declarations')
