from pathlib import Path
import re,json
out=Path('proofs/evidence/llm-source-custody');base=Path('docs/40-49-admission-coordination/41-source-custody')
org=(base/'41.03-proof-and-source-evidence.org').read_text();lean=(out/'LlmSourceCustody.log').read_text();tests=(out/'tests.log').read_text();d2=(base/'41.02-source-custody.d2').read_text()
rows=[]
for i,theorem,test,node,meaning in re.findall(r'^\| (SC\d+) \| ([a-z_]+) \| (\w+Test) \| ([\w.]+) \| (.*?) \|$',org,re.M):
 assert "'Weaver.LlmSourceCustody."+theorem+"'" in lean,theorem
 assert re.search(r'\bok '+re.escape(test)+r' passed',tests),test
 assert 'run '+test+'=' in Path('proofs/qunit/LlmSourceCustody.qnt').read_text(),test
 if '.' in node:
  parent,child=node.split('.');assert re.search(r'^'+parent+r':',d2,re.M) and re.search(r'^  '+child+r':',d2,re.M),node
 rows.append(dict(id=i,theorem=theorem,test=test,node=node,meaning=meaning))
assert len(rows)==13 and len({r['id'] for r in rows})==13
(out/'four-artifacts.json').write_text(json.dumps(rows,indent=2)+'\n')
print('PASS: 13 Org / actual Lean declaration / passing Quint control / core D2 node mappings')
