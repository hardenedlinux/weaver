from pathlib import Path
import json,re
out=Path('proofs/evidence/llm-bootstrap-invitation');base=Path('docs/40-49-admission-coordination/45-bootstrap-invitation')
rows=json.loads((out/'four-artifacts.json').read_text());assert len(rows)==19
log=(out/'LlmBootstrapInvitation.log').read_text();assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmBootstrapInvitation\.",log,re.M))==19
controls='\n'.join((out/f'bundle-controls-{n}.log').read_text() for n in range(6))
for r in rows:
 assert f"'Weaver.LlmBootstrapInvitation.{r['lean']}'" in log,r
 assert f"ok {r['quint']} passed 1 test(s)" in controls,r
 assert f"| {r['id']} |" in (base/'45.03-proof-and-source-evidence.org').read_text(),r
 part,node=r['d2'].split('.')
 diagram=(base/'45.02-bootstrap-invitation.d2').read_text();assert re.search(r'^'+part+r':',diagram,re.M) and re.search(r'^  '+node+r':',diagram,re.M)
print('PASS: nineteen Org / Lean / passing Quint / core D2 obligation rows')
