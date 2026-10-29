from pathlib import Path
import subprocess,json,hashlib
out=Path('proofs/evidence/routine-routing-config');rows=json.loads((out/'source-review.json').read_text());assert len(rows)==16
for r in rows:
 assert subprocess.check_output(['git','-C',r['repository'],'rev-parse','HEAD'],text=True).strip()==r['revision'],r['id']
 blob=subprocess.check_output(['git','-C',r['repository'],'show',r['revision']+':'+r['path']]);assert hashlib.sha256(blob).hexdigest()==r['gitBlobSha256']
 current=(Path(r['repository'])/r['path']).read_bytes();assert hashlib.sha256(current).hexdigest()==r['sha256']
 for x in r['excerpts']:assert current.decode().splitlines()[x['line']-1]==x['text'],(r['id'],x)
(out/'source-check.json').write_text(json.dumps(dict(files=len(rows),allWorkingMatchHead=all(r['workingEqualsHead'] for r in rows),heads={r['repository']:r['revision'] for r in rows}),indent=2)+'\n')
print('PASS: 16 exact current working/Git blobs and all source excerpts checked')
