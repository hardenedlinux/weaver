from pathlib import Path
import re,json
out=Path('proofs/evidence/routine-routing-config');base=Path('docs/40-49-admission-coordination/49-routine-routing-config')
rows=json.loads((out/'four-artifacts.json').read_text());assert len(rows)==24
log=(out/'RoutineRoutingConfig.log').read_text();assert 'sorryAx' not in log and 'error:' not in log
assert len(re.findall(r"^'Weaver.RoutineRoutingConfig\.",log,re.M))==24
commands=json.loads((out/'api-commands.json').read_text());passed=[t for r in commands for t in r.get('passed',[])];assert len(passed)==len(set(passed))==32
for row in rows:
 assert f"'Weaver.RoutineRoutingConfig.{row['lean']}'" in log,row
 assert row['quint'] in passed,row
 assert '| '+row['id']+' |' in (base/'49.03-proof-and-source-evidence.org').read_text(),row
 container,node=row['d2'].split('.');d=(base/'49.02-routine-routing-config.d2').read_text()
 assert re.search('^'+container+':',d,re.M) and re.search('^  '+node+':',d,re.M),row
print('PASS: 24 English Org / Lean / passing Quint / core D2 obligation rows')
