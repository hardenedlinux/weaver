from pathlib import Path
import json,subprocess,os,shutil,hashlib
out=Path(__file__).parent
if any(q.is_file() and q.stat().st_size for q in [out/"SHA256SUMS",out.parent/"SHA256SUMS"]):
 raise SystemExit("Sealed generation; reproduce in fresh directories.")
root=Path('.data/dynamic-gxi-exit-20261020').resolve();work=root/'canary-official';work.mkdir();home=Path('/opt/homebrew/Cellar/gerbil-scheme@0.19/0.19.20261009110849.1cfb032.patch618d76f9eb72/current');flags=json.loads((out/'official-compiler-options.json').read_text())['options'];env=dict(os.environ);env.pop('SDKROOT',None);commands=[]
for name in ['canary.scm','canary.c','cleanup.c']:shutil.copy2(root/'canary'/name,work/name)
for name in ['canary','cleanup']:
 args=['/opt/homebrew/bin/gcc-16',*flags['FLAGS_OPT'],*flags['FLAGS_OBJ'],*flags['DEFS_DYN'],'-I'+str(home/'include'),'-c',str(work/(name+'.c')),'-o',str(work/(name+'.o'))]
 with (out/'official-canary-build.log').open('a') as f:r=subprocess.run(args,env=env,stdout=f,stderr=subprocess.STDOUT)
 commands.append(dict(args=args,exit=r.returncode));assert r.returncode==0
args=['/opt/homebrew/bin/gcc-16',*flags['FLAGS_OPT'],*flags['FLAGS_DYN'],'-undefined','dynamic_lookup',str(work/'canary.o'),str(work/'cleanup.o'),'-isysroot','/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk','-lSystem','-o',str(work/'canary.o1')]
with (out/'official-canary-build.log').open('a') as f:r=subprocess.run(args,env=env,stdout=f,stderr=subprocess.STDOUT)
commands.append(dict(args=args,exit=r.returncode));assert r.returncode==0
(out/'official-canary-build.json').write_text(json.dumps(dict(commands=commands,exit=0,binarySha256=hashlib.sha256((work/'canary.o1').read_bytes()).hexdigest()),indent=2)+'\n');print('OFFICIAL CANARY PASS')
