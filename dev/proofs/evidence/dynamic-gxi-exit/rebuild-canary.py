from pathlib import Path
import json,subprocess,os,time,hashlib
out=Path(__file__).parent
if (out/"SHA256SUMS").exists() and (out/"SHA256SUMS").stat().st_size:
 raise SystemExit("Sealed generation is immutable; reproduce in fresh isolation and evidence directories.")
old=Path('.data/native-gerbil-canary-20261020').resolve();root=Path('.data/dynamic-gxi-exit-20261020/canary').resolve();root.mkdir(exist_ok=True)
for name in ['canary.scm','cleanup.c']:(root/name).write_bytes((old/name).read_bytes())
original=json.loads(Path('proofs/evidence/native-gerbil-exit/canary-build.json').read_text());commands=[]
for item in original['commands']:
 args=[x.replace(str(old),str(root)) for x in item['args']];env=dict(os.environ,GAMBOPT='~~='+str(Path(original['commands'][0]['args'][0]).parent.parent));env.pop('SDKROOT',None);t=time.monotonic()
 with (out/'canary-build.log').open('a') as f:r=subprocess.run(args,env=env,stdout=f,stderr=subprocess.STDOUT)
 commands.append(dict(args=args,exit=r.returncode,seconds=round(time.monotonic()-t,3)))
 if r.returncode:break
(out/'canary-build.json').write_text(json.dumps(dict(commands=commands,exit=r.returncode,sha256=hashlib.sha256((root/'canary.o1').read_bytes()).hexdigest() if (root/'canary.o1').exists() else None),indent=2)+'\n');print('CANARY',r.returncode)
raise SystemExit(r.returncode)
