from pathlib import Path
import re,json
out=Path('proofs/evidence/llm-enrollment-credential');base=Path('docs/40-49-admission-coordination/47-enrollment-credential')
rows=json.loads((out/'four-artifacts.json').read_text());assert len(rows)==32
log=(out/'LlmEnrollmentCredential.log').read_text();assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.LlmEnrollmentCredential\.",log,re.M))==32
commands=json.loads((out/'api-commands.json').read_text());passed=[t for r in commands for t in r.get('passed',[])];assert len(passed)==len(set(passed))==40
for row in rows:
 assert f"'Weaver.LlmEnrollmentCredential.{row['lean']}'" in log,row
 assert row['quint'] in passed,row
 assert '| '+row['id']+' |' in (base/'47.03-proof-and-source-evidence.org').read_text(),row
 container,node=row['d2'].split('.');d=(base/'47.02-enrollment-credential.d2').read_text()
 assert re.search('^'+container+':',d,re.M) and re.search('^  '+node+':',d,re.M),row
print('PASS: 32 English Org / Lean / passing Quint / core D2 obligation rows')
