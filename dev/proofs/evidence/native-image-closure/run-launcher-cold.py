from pathlib import Path
import json,subprocess,os,time,re,hashlib
out=Path(__file__).parent;root=Path('.data/native-image-closure-20261020').resolve();images=json.loads((out/'launcher-cold-images.json').read_text());sha=lambda f:hashlib.sha256(Path(f).read_bytes()).hexdigest();assert all(sha(im['path'])==im['sha256'] for im in images);assert len({im['uuid'] for im in images})==16;results=[]
assert all(Path(a).stat().st_ino==Path(im['path']).stat().st_ino and Path(a).stat().st_dev==Path(im['path']).stat().st_dev for im in images for a in im['aliases'])
(out/'launcher-cold-input-identity.json').write_text(json.dumps(dict(planSha256=sha(out/'launcher-cold-plan.json'),controllerSha256=sha(__file__),manifestSha256=sha(out/'launcher-cold-images.json'),outerLauncherSha256=sha('/opt/homebrew/bin/gxi')),indent=2)+'\n')
for gen in range(4):
 d=out/f'launcher-cold-{gen}';d.mkdir();env=dict(os.environ,GERBIL_LOADPATH=f'{root}/launcher-cold/g{gen}/aliases:{root}/lib-narrow:{root}/lib-native',GERBIL_PATH=str(root/f'run-launcher-cold-{gen}'));env.pop('DYLD_INSERT_LIBRARIES',None);Path(env['GERBIL_PATH']).mkdir();args=['/opt/homebrew/bin/gxi',str(root/'fixture.ss')];t=time.monotonic();late=False
 with (d/'native.log').open('w') as log:
  p=subprocess.Popen(args,env=env,stdout=log,stderr=subprocess.STDOUT)
  while p.poll() is None:
   if time.monotonic()-t>15 and not late:late=True;print(gen,'FAIL unchanged 15s; wait for natural exit',flush=True)
   time.sleep(.005)
 code=p.wait();elapsed=time.monotonic()-t;txt=(d/'native.log').read_text();checks=re.findall(r'^CHECK (\S+) PASS$',txt,re.M);passed=code==0 and not late and elapsed<=15 and len(checks)==len(set(checks))==11 and 'duplicate-json-contract-accepted decoder-rejected' in txt and 'NATIVE-AUTHORING-CHECKS-COMPLETE' in txt
 r=dict(generation=gen,loadpath=env['GERBIL_LOADPATH'],privateModulePath=env['GERBIL_PATH'],args=args,pid=p.pid,exit=code,seconds=elapsed,gateSeconds=15,deadlineFailed=late,forcedExit=False,qualified=passed,checks=checks,fixtureSha256=sha(root/'fixture.ss'),newUUIDs=[im['uuid'] for im in images if im['generation']==gen],handleCounterCoverage=False,coldScope='Fresh selected image generation; installed runtime and OS caches shared');(d/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');results.append(r);print('COLD LAUNCHER',gen,round(elapsed,3),passed,flush=True)
assert all(sha(im['path'])==im['sha256'] for im in images)
(out/'launcher-cold.json').write_text(json.dumps(results,indent=2)+'\n')
