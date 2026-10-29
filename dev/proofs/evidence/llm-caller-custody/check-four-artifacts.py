from pathlib import Path
import re,json
out=Path('proofs/evidence/llm-caller-custody');base=Path('docs/40-49-admission-coordination/43-caller-custody')
org=(base/'43.03-proof-and-source-evidence.org').read_text();lean=(out/'LlmCallerCustody.log').read_text();tests=(out/'tests.log').read_text();d2=(base/'43.02-caller-custody.d2').read_text()
rows=[]
for i,theorem,test,node,meaning in re.findall(r'^\| (CC\d+) \| ([a-z_]+) \| (\w+Test) \| ([\w.]+) \| (.*?) \|$',org,re.M):
 assert "'Weaver.LlmCallerCustody."+theorem+"'" in lean,theorem
 assert re.search(r'\bok '+re.escape(test)+r' passed',tests),test
 assert 'run '+test+'=' in Path('proofs/qunit/LlmCallerCustody.qnt').read_text(),test
 if '.' in node:
  parent,child=node.split('.');assert re.search(r'^'+parent+r':',d2,re.M) and re.search(r'^  '+child+r':',d2,re.M),node
 rows.append(dict(id=i,theorem=theorem,test=test,node=node,meaning=meaning))
assert len(rows)==22 and len({r['id'] for r in rows})==22
(out/'four-artifacts.json').write_text(json.dumps(rows,indent=2)+'\n')
print('PASS: 22 Org / actual Lean declaration / passing Quint control / core D2 node mappings')
