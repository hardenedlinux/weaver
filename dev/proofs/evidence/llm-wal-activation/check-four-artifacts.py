from pathlib import Path
import re,json
out=Path('proofs/evidence/llm-wal-activation');base=Path('docs/20-29-execution-authority/25-wal-activation')
org=(base/'25.03-proof-and-source-evidence.org').read_text();q=Path('proofs/qunit/LlmWalActivation.qnt').read_text();l=Path('proofs/lean/LlmWalActivation.lean').read_text();d=(base/'25.02-wal-activation.d2').read_text();rows=[]
for line in org.splitlines():
 if not re.match(r'^\| WA\d+ ',line):continue
 ident,design,test,theorem,node=[f.strip() for f in line.strip('|').split('|')]
 assert re.search(r'run '+test+r'\b',q) and 'ok '+test+' passed' in (out/'tests.log').read_text(),test
 assert re.search(r'theorem '+theorem+r'\b',l) and "'Weaver.LlmWalActivation."+theorem+"'" in (out/'LlmWalActivation.log').read_text(),theorem
 if '.' in node:
  parent,child=node.split('.');assert re.search(r'^'+parent+r':',d,re.M) and re.search(r'^  '+child+r':',d,re.M),node
 else:assert re.search(r'^'+node+r':',d,re.M),node
 rows.append(dict(id=ident,design=design,quint=test,lean=theorem,d2=node))
assert len(rows)==17
(out/'four-artifacts.json').write_text(json.dumps(rows,indent=2)+'\n')
print('PASS: seventeen design / Quint / Lean / core D2 mappings resolve to checked declarations')
