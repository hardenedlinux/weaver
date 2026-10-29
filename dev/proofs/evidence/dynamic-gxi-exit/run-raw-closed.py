from pathlib import Path
import subprocess,json,os,time,re,hashlib
out=Path(__file__).parent
if (out/"SHA256SUMS").exists() and (out/"SHA256SUMS").stat().st_size:
 raise SystemExit("Sealed generation is immutable; reproduce in fresh isolation and evidence directories.")
root=Path('.data/dynamic-gxi-exit-20261020').resolve();env=dict(os.environ,GERBIL_LOADPATH=':'.join(str(root/n) for n in ['dynamic-images','lib-narrow','lib-native']),GERBIL_PATH=str(root/'run-raw-closed'));Path(env['GERBIL_PATH']).mkdir();prefix=Path('/opt/homebrew/Cellar/gerbil-scheme@0.19/0.19.20261009110849.1cfb032.patch618d76f9eb72/current');env.update(GERBIL_PREFIX=str(prefix.parent),GERBIL_HOME=str(prefix),GAMBOPT='~~='+str(prefix)+',~~bin='+str(prefix/'bin')+',~~lib='+str(prefix/'lib'),DYLD_INSERT_LIBRARIES=str(root/'module-cleanup-observer.dylib'),WEAVER_MODULE_CLEANUP_TRACE=str((out/'raw-closed-module-cleanup.json').resolve()));args=[str(prefix/'bin/gxi'),str(root/'fixture.ss')];t=time.monotonic();late=False
with (out/'raw-closed.log').open('w') as f:
 p=subprocess.Popen(args,env=env,stdout=f,stderr=subprocess.STDOUT)
 while p.poll() is None:
  elapsed=time.monotonic()-t
  if elapsed>=15:late=True
  time.sleep(.01)
elapsed=time.monotonic()-t;text=(out/'raw-closed.log').read_text();checks=re.findall(r'^CHECK (\S+) PASS$',text,re.M);r=dict(args=args,exit=p.poll(),seconds=round(elapsed,3),gateSeconds=15,late=late,qualified=p.returncode==0 and elapsed<=15 and not late and len(checks)==11 and 'duplicate-json-contract-accepted decoder-rejected' in text,fixtureSha256=hashlib.sha256((root/'fixture.ss').read_bytes()).hexdigest(),checks=checks,forcedExit=False,scope='Exact original script through normal installed gxi launcher; no appended Scheme code; passive native cleanup observer; exact installed executable');(out/'raw-closed.json').write_text(json.dumps(r,indent=2)+'\n');print(r)
