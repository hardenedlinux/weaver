"""Materialize a fresh source/native/proof generation; never rewrite a sealed one."""
from pathlib import Path
import argparse,json,re,subprocess,sys,hashlib
ap=argparse.ArgumentParser();ap.add_argument('--generation',required=True);ap.add_argument('--run',action='store_true');args=ap.parse_args();assert re.fullmatch('[a-z0-9][a-z0-9-]{2,60}',args.generation);src=Path(__file__).resolve().parent;dst=Path('proofs/evidence')/('native-image-closure-'+args.generation);root=Path('.data')/('native-image-closure-'+args.generation);assert not dst.exists() and not root.exists();dst.mkdir();root.mkdir()
steps=['build.py','prepare.py','clean-proof-build.py','check-quint.py','probe-collisions.py','check-lazy-entries.py','run-matrix.py','prepare-launcher-cold.py','run-launcher-cold.py','run-launcher.py','probe-math.py','analyze.py','check-artifacts.py']
for name in steps+['run-quint.cjs','plan.json','launcher-cold-plan.json','link-profile.json']:
 text=(src/name).read_text().replace('.data/native-image-closure-20261020',str(root)).replace('proofs/evidence/native-image-closure',str(dst));(dst/name).write_text(text)
receipt=dict(evidence=str(dst),isolation=str(root),steps=steps,gateSeconds=15,sourceAndToolchain='Exact original source artifacts, installed runtime/compiler and recorded existing workspace SDK required; no pin change or installation',nativeBoundary='Fresh selected images/processes; installed runtime and OS caches shared',formalBoundary='Fresh Lean closure and official Quint controls; native timing remains measured evidence')
(dst/'reproduction.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt),flush=True)
if not args.run:raise SystemExit(0)
sha=lambda path:hashlib.sha256(Path(path).read_bytes()).hexdigest()
for row in json.loads((src/'clean-proof-receipt.json').read_text())['modules']:
 assert sha(row['source'])==row['sourceSha256'], 'Proof source changed; create a new qualification plan'
for name,digest in json.loads((src/'api-invocation.json').read_text())['inputs'].items():
 if name.startswith('proofs/qunit/'):assert sha(name)==digest
for name in steps:
 with (dst/(name+'.log')).open('w') as log:subprocess.run(['python3',str(dst/name)],stdout=log,stderr=subprocess.STDOUT,check=True)
analysis=json.loads((dst/'analysis.json').read_text());cold=json.loads((dst/'launcher-cold.json').read_text());warm=json.loads((dst/'launcher.json').read_text());closed=analysis['candidatePasses']==8 and all(r['qualified'] for r in cold+warm);print(json.dumps(dict(collectionComplete=True,nativeRequiredSeriesClosed=closed,observedCandidates=analysis['candidatePasses'],coldLauncherPasses=sum(r['qualified'] for r in cold),controlFailuresRetained=analysis['failedSamples'])),flush=True);raise SystemExit(0 if closed else 1)
