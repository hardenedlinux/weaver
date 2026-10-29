from pathlib import Path
import re,json
base=Path('docs/10-19-llm-gateway/11-attempts-and-failover')
org=(base/'11.03-validation-evidence.org').read_text()
q=Path('proofs/qunit/LlmAttemptLedger.qnt').read_text()
l=Path('proofs/lean/LlmAttemptLedger.lean').read_text()
d=(base/'11.02-attempt-ledger.d2').read_text()
rows=[]
for line in org.splitlines():
 if not re.match(r'^\| AT\d+ ',line):continue
 fields=[f.strip() for f in line.strip('|').split('|')]
 ident,design,test,theorem,node=fields
 assert re.search(r'run '+test+r'\b',q),test
 assert ('ok '+test+' passed') in Path('proofs/evidence/llm-attempt-ledger/tests.log').read_text(),test
 assert ("'Weaver.LlmAttemptLedger."+theorem+"'") in Path('proofs/evidence/llm-attempt-ledger/LlmAttemptLedger.log').read_text(),theorem
 assert re.search(r'theorem '+theorem+r'\b',l),theorem
 parent,child=node.split('.')
 assert re.search(r'^'+parent+r':',d,re.M) and re.search(r'^  '+child+r':',d,re.M),node
 rows.append(dict(id=ident,design=design,quint=test,lean=theorem,d2=node))
assert len(rows)==10 and len({r['id'] for r in rows})==10
Path('proofs/evidence/llm-attempt-ledger/four-artifacts.json').write_text(json.dumps(rows,indent=2)+'\n')
print('PASS: ten design / Quint / Lean / D2 mappings resolve to actual declarations')
