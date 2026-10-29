from pathlib import Path
import subprocess,json,os,time,re
out=Path(__file__).parent;root=Path('.data/native-image-closure-20261020').resolve();results=[]
for block in range(4):
 label=f'launcher-{block}';d=out/label;d.mkdir();env=dict(os.environ,GERBIL_LOADPATH=f'{root}/g{block}/candidate/aliases:{root}/lib-narrow:{root}/lib-native',GERBIL_PATH=str(root/label));Path(env['GERBIL_PATH']).mkdir();env.pop('DYLD_INSERT_LIBRARIES',None);args=['/opt/homebrew/bin/gxi',str(root/'fixture.ss')];t=time.monotonic();late=False
 with (d/'native.log').open('w') as f:
  child=subprocess.Popen(args,env=env,stdout=f,stderr=subprocess.STDOUT)
  while child.poll() is None:
   if time.monotonic()-t>15 and not late:late=True;print(label,'FAIL unchanged 15 seconds; wait for natural exit',flush=True)
   time.sleep(.005)
 code=child.wait();elapsed=time.monotonic()-t;txt=(d/'native.log').read_text();checks=re.findall(r'^CHECK (\S+) PASS$',txt,re.M);r=dict(label=label,args=args,pid=child.pid,exit=code,seconds=elapsed,gateSeconds=15,deadlineFailed=late,forcedExit=False,checks=checks,qualified=code==0 and not late and elapsed<=15 and len(checks)==len(set(checks))==11 and 'duplicate-json-contract-accepted decoder-rejected' in txt and 'NATIVE-AUTHORING-CHECKS-COMPLETE' in txt,handleCounterCoverage=False,coldClaim=False);(d/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');results.append(r);print(label,round(elapsed,3),r['qualified'],flush=True)
(out/'launcher.json').write_text(json.dumps(results,indent=2)+'\n')
