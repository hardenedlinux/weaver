from pathlib import Path
import os,subprocess,time,json,re
out=Path(__file__).parent;root=Path('.data/dynamic-gxi-paired-20261020').resolve();d=out/'sampled-diagnostic';d.mkdir();prefix=Path('/opt/homebrew/Cellar/gerbil-scheme@0.19/0.19.20261009110849.1cfb032.patch618d76f9eb72');home=prefix/'current'
env=dict(os.environ,GERBIL_PREFIX=str(prefix),GERBIL_HOME=str(home),GAMBOPT=f'~~={home},~~bin={home}/bin,~~lib={home}/lib',GERBIL_LOADPATH=f'{root}/g0/A/independent:{root}/lib-native',GERBIL_PATH=str(root/'sampled-diagnostic'),DYLD_INSERT_LIBRARIES=str(root/'observer.dylib'),WEAVER_MODULE_CLEANUP_TRACE=str((d/'cleanup.json').resolve()),WEAVER_DYLD_TIMELINE=str((d/'timeline.tsv').resolve()));Path(env['GERBIL_PATH']).mkdir();args=[str(home/'bin/gxi'),str(root/'fixture.ss')];t=time.monotonic();late=False;sampled=False;samplers=[]
with (d/'native.log').open('w') as f:
 p=subprocess.Popen(args,env=env,stdout=f,stderr=subprocess.STDOUT);time.sleep(.3)
 loadArgs=['/usr/bin/sample',str(p.pid),'1','10','-mayDie','-file',str((d/'startup-stack.txt').resolve())]
 with (d/'startup-sampler.log').open('w') as s:samplers.append(subprocess.Popen(loadArgs,stdout=s,stderr=subprocess.STDOUT))
 while p.poll() is None:
  elapsed=time.monotonic()-t
  if elapsed>15:late=True
  if not sampled and 'NATIVE-AUTHORING-CHECKS-COMPLETE' in (d/'native.log').read_text():
   sampled=True;cleanupArgs=['/usr/bin/sample',str(p.pid),'1','10','-mayDie','-file',str((d/'cleanup-stack.txt').resolve())]
   with (d/'cleanup-sampler.log').open('w') as s:samplers.append(subprocess.Popen(cleanupArgs,stdout=s,stderr=subprocess.STDOUT))
  time.sleep(.02)
 code=p.wait();elapsed=time.monotonic()-t
samples=[s.wait() for s in samplers];txt=(d/'native.log').read_text();r=dict(args=args,pid=p.pid,exit=code,seconds=elapsed,gateSeconds=15,deadlineFailed=late,forcedExit=False,sampled=True,excludedFromPairedTimings=True,samplerExits=samples,checks=re.findall(r'^CHECK (\S+) PASS$',txt,re.M),cleanup=json.loads((d/'cleanup.json').read_text()));(d/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r),flush=True)
