from pathlib import Path
import subprocess,json,os,time,re
out=Path(__file__).parent;root=Path('.data/dynamic-gxi-paired-20261020').resolve();results=[]
for family in ['stable','uuid']:
 for cell in ['A','D']:
  label=f'launcher-{family}-{cell}';d=out/label;d.mkdir();base=(root/'uuid' if family=='uuid' else root)/'g0'/cell
  libs=[base/('packed-aliases' if cell=='D' else 'independent')]
  if cell=='D':libs.append(root/'lib-narrow')
  libs.append(root/'lib-native');env=dict(os.environ,GERBIL_LOADPATH=':'.join(map(str,libs)),GERBIL_PATH=str(root/label));Path(env['GERBIL_PATH']).mkdir()
  env.pop('DYLD_INSERT_LIBRARIES',None);args=['/opt/homebrew/bin/gxi',str(root/'fixture.ss')];t=time.monotonic();late=False
  with (d/'native.log').open('w') as f:
   p=subprocess.Popen(args,env=env,stdout=f,stderr=subprocess.STDOUT)
   while p.poll() is None:
    if time.monotonic()-t>15 and not late:late=True;print(label,'FAILED 15 seconds; waiting for natural exit',flush=True)
    time.sleep(.005)
  code=p.wait();elapsed=time.monotonic()-t;txt=(d/'native.log').read_text();checks=re.findall(r'^CHECK (\S+) PASS$',txt,re.M)
  r=dict(label=label,args=args,exit=code,seconds=elapsed,gateSeconds=15,deadlineFailed=late,checks=checks,processGatePassed=code==0 and not late and elapsed<=15 and len(checks)==11 and len(set(checks))==11 and 'duplicate-json-contract-accepted decoder-rejected' in txt and 'NATIVE-AUTHORING-CHECKS-COMPLETE' in txt,forcedExit=False,handleCounterCoverage=False)
  results.append(r);(d/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');print(label,round(elapsed,3),r['processGatePassed'],flush=True)
(out/'launcher.json').write_text(json.dumps(results,indent=2)+'\n')
