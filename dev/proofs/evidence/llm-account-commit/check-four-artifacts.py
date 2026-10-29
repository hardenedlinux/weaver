from pathlib import Path
import re,json
out=Path('proofs/evidence/llm-account-commit');base=Path('docs/20-29-execution-authority/24-account-commit')
org=(base/'24.03-proof-and-source-evidence.org').read_text();q=Path('proofs/qunit/LlmAccountCommit.qnt').read_text();l=Path('proofs/lean/LlmAccountCommit.lean').read_text();d=(base/'24.02-account-commit.d2').read_text();rows=[]
for line in org.splitlines():
 if not re.match(r'^\| AT\d+ ',line):continue
 ident,design,test,theorem,node=[f.strip() for f in line.strip('|').split('|')]
 assert re.search(r'run '+test+r'\b',q) and 'ok '+test+' passed' in (out/'tests.log').read_text(),test
 assert re.search(r'theorem '+theorem+r'\b',l) and "'Weaver.LlmAccountCommit."+theorem+"'" in (out/'LlmAccountCommit.log').read_text(),theorem
 if '.' in node:
  parent,child=node.split('.');assert re.search(r'^'+parent+r':',d,re.M) and re.search(r'^  '+child+r':',d,re.M),node
 else:assert re.search(r'^'+node+r':',d,re.M),node
 rows.append(dict(id=ident,design=design,quint=test,lean=theorem,d2=node))
assert len(rows)==23
(out/'four-artifacts.json').write_text(json.dumps(rows,indent=2)+'\n')
print('PASS: twenty-three design / Quint / Lean / core D2 mappings resolve to checked declarations')
