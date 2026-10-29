from pathlib import Path
import re,json
out=Path('proofs/evidence/llm-subject-authority');base=Path('docs/40-49-admission-coordination/48-subject-authority')
rows=json.loads((out/'four-artifacts.json').read_text());assert len(rows)==33
log=(out/'LlmSubjectAuthority.log').read_text();assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmSubjectAuthority\.",log,re.M))==33
commands=json.loads((out/'api-commands.json').read_text());passed=[t for r in commands for t in r.get('passed',[])];assert len(passed)==len(set(passed))==42
for row in rows:
 assert f"'Weaver.LlmSubjectAuthority.{row['lean']}'" in log,row
 assert row['quint'] in passed,row
 assert '| '+row['id']+' |' in (base/'48.03-proof-and-source-evidence.org').read_text(),row
 container,node=row['d2'].split('.');d=(base/'48.02-subject-authority.d2').read_text()
 assert re.search('^'+container+':',d,re.M) and re.search('^  '+node+':',d,re.M),row
print('PASS: 33 English Org / Lean / passing Quint / core D2 obligation rows')
