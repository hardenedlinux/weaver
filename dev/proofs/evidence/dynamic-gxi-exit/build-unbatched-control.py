from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import subprocess,json,os,time
out=Path(__file__).parent
if (out/"SHA256SUMS").exists() and (out/"SHA256SUMS").stat().st_size:
 raise SystemExit("Sealed generation is immutable; reproduce in fresh isolation and evidence directories.")
root=Path('.data/dynamic-gxi-exit-20261020').resolve();rows=json.loads((out/'dynamic-object-build.json').read_text());env=dict(os.environ);env.pop('SDKROOT',None)
def link(row):
 target=root/'unbatched-images'/(row['module']+'.o1');target.parent.mkdir(parents=True,exist_ok=True);args=['/opt/homebrew/bin/gcc-16','-bundle','-undefined','dynamic_lookup',row['object'],'-isysroot','/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk','-lSystem','-o',str(target)]
 with target.with_suffix('.log').open('w') as f:r=subprocess.run(args,env=env,stdout=f,stderr=subprocess.STDOUT)
 assert r.returncode==0,row['module'];return dict(module=row['module'],object=row['object'],target=str(target),args=args,exit=r.returncode)
t=time.monotonic()
with ThreadPoolExecutor(max_workers=3) as pool:results=list(pool.map(link,rows))
(out/'unbatched-control-build.json').write_text(json.dumps(dict(modules=results,seconds=round(time.monotonic()-t,3),scope='Same regenerated native object inputs as packed candidate; one OS image per original independent linker entry'),indent=2)+'\n');print('UNBATCHED CONTROL',len(results))
