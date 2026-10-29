from pathlib import Path
import re,json
out=Path('proofs/evidence/llm-incarnation-issuance');base=Path('docs/40-49-admission-coordination/44-incarnation-issuance')
org=(base/'44.03-proof-and-source-evidence.org').read_text();lean=(out/'LlmIncarnationIssuance.log').read_text();tests=(out/'tests.log').read_text();d2=(base/'44.02-incarnation-issuance.d2').read_text()
rows=[]
for i,theorem,test,node,meaning in re.findall(r'^\| (EI\d+) \| ([a-z_]+) \| (\w+Test) \| ([\w.]+) \| (.*?) \|$',org,re.M):
 assert "'Weaver.LlmIncarnationIssuance."+theorem+"'" in lean,theorem
 assert re.search(r'\bok '+re.escape(test)+r' passed',tests),test
 assert 'run '+test+'=' in Path('proofs/qunit/LlmIncarnationIssuance.qnt').read_text(),test
 if '.' in node:
  parent,child=node.split('.');assert re.search(r'^'+parent+r':',d2,re.M) and re.search(r'^  '+child+r':',d2,re.M),node
 rows.append(dict(id=i,theorem=theorem,test=test,node=node,meaning=meaning))
assert len(rows)==23 and len({r['id'] for r in rows})==23
(out/'four-artifacts.json').write_text(json.dumps(rows,indent=2)+'\n')
print('PASS: 23 Org / actual Lean declaration / passing Quint control / core D2 node mappings')
