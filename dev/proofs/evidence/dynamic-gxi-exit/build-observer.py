from pathlib import Path
import subprocess,json,os
out=Path(__file__).parent
if (out/"SHA256SUMS").exists() and (out/"SHA256SUMS").stat().st_size:
 raise SystemExit("Sealed generation is immutable; reproduce in fresh isolation and evidence directories.")
target=Path('.data/dynamic-gxi-exit-20261020/module-cleanup-observer.dylib').resolve();args=['/usr/bin/clang','-O1','-Wall','-Wextra','-dynamiclib',str(out/'module-cleanup-observer.c'),'-o',str(target)];env=dict(os.environ);env.pop('SDKROOT',None)
with (out/'observer-build.log').open('w') as f:r=subprocess.run(args,env=env,stdout=f,stderr=subprocess.STDOUT)
(out/'observer-build.json').write_text(json.dumps(dict(args=args,exit=r.returncode,target=str(target)),indent=2)+'\n');print('OBSERVER BUILD',r.returncode);raise SystemExit(r.returncode)
