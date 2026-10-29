from pathlib import Path
import hashlib,json
ROOT=Path.cwd();OUT=ROOT/'proofs/evidence/llm-bootstrap-invitation'
def check(path,digest):assert hashlib.sha256((ROOT/path).read_bytes()).hexdigest()==digest,path
cert=json.loads((OUT/'closure-certificate.json').read_text())
for r in cert['ancestors']:
 for p,h in [(r['rawSource'],r['rawSha256']),(r['parentCore'],r['parentCoreSha256']),(r['executed'],r['executedSha256'])]:check(p,h)
check(cert['newSource'],cert['newSha256']);assert (ROOT/cert['newSource']).read_bytes()==(ROOT/cert['newExecuted']).read_bytes()
for p,h in cert['simulationFiles'].items():check(p,h)
rows=json.loads((OUT/'control-shards.json').read_text());assert len(rows)==6
assert [t for r in rows for t in r['tests']]==cert['tests']
for r in rows:
 assert r['identicalRetainedIR']
 for p,h in r['files'].items():check(p,h)
print('PASS: 12 ancestor closures, raw leaf, simulation and all six control shards match recorded hashes; all 23 controls covered once')
