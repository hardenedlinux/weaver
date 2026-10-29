from pathlib import Path
import json,os,time,subprocess,sys,re,hashlib
out=Path(__file__).parent
if (out/"SHA256SUMS").exists() and (out/"SHA256SUMS").stat().st_size:
 raise SystemExit("Sealed generation is immutable; reproduce in fresh isolation and evidence directories.")
root=Path('.data/dynamic-gxi-exit-20261020').resolve();mode=sys.argv[1];label=sys.argv[2];dest=out/label;dest.mkdir();marker=(dest/'cleanup.txt').resolve();assert not marker.exists()
lib=str(root/'lib-native');loadpath=(str(root/'source-loaders')+':'+lib if mode=='source' else str(root/'lib-narrow')+':'+lib if mode=='narrow' else str(root/'dynamic-images')+':'+str(root/'lib-narrow')+':'+lib if mode=='packed' else str(root/'unbatched-images')+':'+str(root/'lib-narrow')+':'+lib if mode=='unbatched' else lib)
source=root/'fixture.ss';canary=root/'canary/canary.o1';env=dict(os.environ,GERBIL_PATH=str(root/('run-'+label)),GERBIL_LOADPATH=loadpath,WEAVER_NATIVE_CANARY=str(canary),WEAVER_NATIVE_CANARY_LOG=str(marker));Path(env['GERBIL_PATH']).mkdir(exist_ok=True)
expr='(import (only-in :gerbil/runtime/loader list-modules module-load-order)) (for-each (lambda (row) (display "MODULE ") (write row) (newline) (display "ORDER ") (write (cons (car row) (module-load-order (car row)))) (newline)) (list-modules)) (load (getenv "WEAVER_NATIVE_CANARY")) (display "DYNAMIC-GXI-RETURN\\n")'
audited=root/('audited-'+label+'.ss');audited.write_text(source.read_text()+'\n'+expr+'\n');args=['gxi',str(audited)];
if len(sys.argv)>3 and sys.argv[3]=='observe':
 prefix=Path('/opt/homebrew/Cellar/gerbil-scheme@0.19/0.19.20261009110849.1cfb032.patch618d76f9eb72');home=prefix/'current';args[0]=str(home/'bin/gxi');env['GERBIL_PREFIX']=str(prefix);env['GERBIL_HOME']=str(home);env['GAMBOPT']='~~='+str(home)+',~~bin='+str(home/'bin')+',~~lib='+str(home/'lib');env['DYLD_INSERT_LIBRARIES']=str(root/'module-cleanup-observer.dylib');env['WEAVER_MODULE_CLEANUP_TRACE']=str((dest/'module-cleanup.json').resolve())
t=time.monotonic();deadlineFailed=False
with (dest/'native.log').open('w') as f:
 p=subprocess.Popen(args,env=env,stdout=f,stderr=subprocess.STDOUT)
 while p.poll() is None:
  elapsed=time.monotonic()-t
  if elapsed>=15 and not deadlineFailed:
   deadlineFailed=True;print(label,'FAIL unchanged 15s; observing without terminating',flush=True)
  time.sleep(.01)
elapsed=time.monotonic()-t;text=(dest/'native.log').read_text();cleanup=marker.read_text() if marker.exists() else '';modules=dict(re.findall(r'^MODULE \("([^"]+)" \. "([^"]+)"\)$',text,re.M))
checkNames=re.findall(r'^CHECK (\S+) PASS$',text,re.M)
qualified=p.returncode==0 and not deadlineFailed and elapsed<=15 and len(checkNames)==11 and len(set(checkNames))==11 and 'duplicate-json-contract-accepted decoder-rejected' in text and 'DYNAMIC-GXI-RETURN' in text and cleanup=='LU'
r=dict(args=args,pid=p.pid,exit=p.poll(),seconds=round(elapsed,3),gateSeconds=15,qualified=qualified,forcedExit=False,loadpath=loadpath,checks=checkNames,cleanup=cleanup,epilogueMode="Original fixture byte prefix plus observational epilogue; installed gxi ignores trailing -e after script",auditedSource=str(audited),fixtureSha256=hashlib.sha256(source.read_bytes()).hexdigest(),modules=modules,moduleOrder=dict((name,int(order)) for name,order in re.findall(r'^ORDER \("([^"]+)" \. ([0-9]+)\)$',text,re.M)),sourceLoaderModules=sum('/source-loaders/' in path for path in modules.values()),nativeBodyModules=sum('~' in name and '.o' in path for name,path in modules.items()),canarySha256=hashlib.sha256(canary.read_bytes()).hexdigest());(dest/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');print(label,{k:r[k] for k in ['exit','seconds','qualified','cleanup','sourceLoaderModules','nativeBodyModules']},flush=True)
