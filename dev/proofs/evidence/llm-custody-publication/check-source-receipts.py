from pathlib import Path
import hashlib,json,subprocess
out=Path('proofs/evidence/llm-custody-publication');checked=[]
for name,count in [('source-review.json',19)]:
 rows=json.loads((out/name).read_text());assert len(rows)==count
 for r in rows:
  blob=subprocess.check_output(['git','-C',r['repository'],'show',r['revision']+':'+r['path']])
  assert hashlib.sha256(blob).hexdigest()==r['sha256'],r['id']
  lines=blob.decode().splitlines()
  for excerpt in r['excerpts']:assert lines[excerpt['line']-1]==excerpt['text'],(r['id'],excerpt)
  checked.append(dict(id=r['id'],revision=r['revision'],path=r['path'],sha256=r['sha256'],excerpts=len(r['excerpts'])))
(out/'source-receipt-check.json').write_text(json.dumps(checked,indent=2)+'\n')
print('PASS: 19 pinned source blobs and every recorded excerpt freshly verified')
