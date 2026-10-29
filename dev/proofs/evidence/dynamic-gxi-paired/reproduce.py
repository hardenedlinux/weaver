"""Create a fresh native experiment generation; never modify sealed evidence."""
from pathlib import Path
import argparse,json,subprocess,re
ap=argparse.ArgumentParser();ap.add_argument('--generation',required=True);ap.add_argument('--run',action='store_true');args=ap.parse_args();assert re.fullmatch('[a-z0-9][a-z0-9-]{2,60}',args.generation)
source=Path(__file__).resolve().parent;dest=Path('proofs/evidence')/('dynamic-gxi-paired-'+args.generation);root=Path('.data')/('dynamic-gxi-paired-'+args.generation);assert not dest.exists() and not root.exists();dest.mkdir();root.mkdir()
steps=['rebuild-official.py','prepare.py','prepare-uuid.py','audit-identity.py','run-matrix.py','run-launcher.py','analyze.py']
for name in steps+['plan.json','observer.c']:
 text=(source/name).read_text().replace('.data/dynamic-gxi-paired-20261020',str(root)).replace('proofs/evidence/dynamic-gxi-paired',str(dest));(dest/name).write_text(text)
recipe=dict(source=str(source),evidence=str(dest),isolation=str(root),steps=steps,priorSealedGeneratedC='proofs/evidence/dynamic-gxi-exit/dynamic-object-build.json',gateSeconds=15,sourceRebuild='Generated native C rebuilt; high-level source closure and original fixture reused from sealed source qualification',systemRuntime='Installed runtime/stdlib remain trusted external prerequisites; OS cache state uncontrolled')
(dest/'reproduction.json').write_text(json.dumps(recipe,indent=2)+'\n');print(json.dumps(recipe),flush=True)
if not args.run:raise SystemExit(0)
# Use the same SDK handling as the qualified observer build.
import os
env=dict(os.environ);env.pop('SDKROOT',None)
with (dest/'observer-build.log').open('w') as f:subprocess.run(['/usr/bin/clang','-O1','-Wall','-Wextra','-dynamiclib',str(dest/'observer.c'),'-o',str(root/'observer.dylib')],env=env,stdout=f,stderr=subprocess.STDOUT,check=True)
for name in steps:
 with (dest/(name+'.log')).open('w') as f:subprocess.run(['python3',str(dest/name)],stdout=f,stderr=subprocess.STDOUT,check=True)

summary=json.loads((dest/'analysis.json').read_text())
print(json.dumps(dict(collectionComplete=True,nativePasses=summary['passes'],nativeFailures=summary['failures'],nativeAcceptance='Read each typed verdict; successful collection is not an all-native-pass verdict')),flush=True)
