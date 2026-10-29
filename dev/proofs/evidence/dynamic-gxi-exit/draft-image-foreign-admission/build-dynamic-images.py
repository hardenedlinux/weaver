from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import json,subprocess,os,hashlib,re,time
out=Path(__file__).parent;root=Path('.data/dynamic-gxi-exit-20261020').resolve();build=root/'image-build';overlay=root/'dynamic-images';build.mkdir(exist_ok=True);overlay.mkdir(exist_ok=True)
observed=json.loads((out/'narrowed-0/receipt.json').read_text())['modules'];prefix=Path('/opt/homebrew/Cellar/gerbil-scheme@0.19/0.19.20261009110849.1cfb032.patch618d76f9eb72/current');gsc=prefix/'bin/gsc';gcc='/opt/homebrew/bin/gcc-16';sdk='/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk';defs=json.loads(Path('proofs/evidence/native-gerbil-exit/canary-build.json').read_text())['abiDefinitions'];env=dict(os.environ,GAMBOPT='~~='+str(prefix));env.pop('SDKROOT',None)
modules=[]
for name,path in sorted(observed.items()):
 if not name.startswith(('gerbil/','core/','clan/poo/')):continue
 src=Path(path).with_suffix('.scm');assert src.is_file(),src;text=src.read_text()
 assert not re.search(r'\b(?:c-declare|c-initialize|c-lambda|c-define|foreign|ffi)\b',text),name
 modules.append((name,src))
assert len(modules)>75
# Each original linker entry remains independent and lazy. Only the OS mapping
# is shared. Modules with C/FFI forms or C init/term sections are not admitted.
def compile_one(item):
 name,src=item;slot=build/name;slot.parent.mkdir(parents=True,exist_ok=True);c=slot.with_suffix('.c');obj=slot.with_suffix('.o');commands=[]
 for args in [[str(gsc),'-c','-linker-name',Path(name).name+'.o1','-o',str(c),str(src)],[gcc,'-O1','-fPIC','-foptimize-sibling-calls',*defs,'-I'+str(prefix/'include'),'-c',str(c),'-o',str(obj)]]:
  t=time.monotonic()
  with slot.with_suffix('.log').open('a') as f:r=subprocess.run(args,env=env,stdout=f,stderr=subprocess.STDOUT)
  commands.append(dict(args=args,exit=r.returncode,seconds=round(time.monotonic()-t,3)))
  if r.returncode:raise RuntimeError((name,args,r.returncode))
 return dict(module=name,source=str(src),sourceSha256=hashlib.sha256(src.read_bytes()).hexdigest(),object=str(obj),objectSha256=hashlib.sha256(obj.read_bytes()).hexdigest(),commands=commands)
t=time.monotonic();records=[]
with ThreadPoolExecutor(max_workers=3) as pool:
 for record in pool.map(compile_one,modules):
  records.append(record);(out/'dynamic-object-build.json').write_text(json.dumps(records,indent=2)+'\n');print('BUILT',record['module'],flush=True)
groups={}
for r in records:groups.setdefault(str(Path(r['module']).parent),[]).append(r)
images=[]
for name,rows in groups.items():
 image=build/('image-'+name.replace('/','-')+'.o1');args=[gcc,'-bundle','-undefined','dynamic_lookup',*[r['object'] for r in rows],'-isysroot',sdk,'-lSystem','-o',str(image)]
 with image.with_suffix('.log').open('w') as f:r=subprocess.run(args,env=env,stdout=f,stderr=subprocess.STDOUT)
 assert r.returncode==0,(name,r.returncode)
 headers=subprocess.check_output(['/usr/bin/otool','-l',str(image)],text=True)
 assert '__mod_init_func' not in headers and '__mod_term_func' not in headers,name
 aliases=[]
 for row in rows:
  dest=overlay/(row['module']+'.o1');dest.parent.mkdir(parents=True,exist_ok=True);assert not dest.exists();os.link(image,dest);assert dest.stat().st_ino==image.stat().st_ino;aliases.append(str(dest))
 images.append(dict(group=name,image=str(image),sha256=hashlib.sha256(image.read_bytes()).hexdigest(),linkArgs=args,aliases=aliases,noCInitializersOrDestructors=True,inode=image.stat().st_ino))
(out/'dynamic-images.json').write_text(json.dumps(dict(exit=0,seconds=round(time.monotonic()-t,3),modules=len(records),images=images,bodyPolicy='Distinct original Gambit linker entries; lazy module initialization and all dlopen/dlclose references retained; shared OS image only',excluded='Foreign/C modules; any native C init/term sections'),indent=2)+'\n');print('DYNAMIC IMAGE BUILD PASS',len(records),'entries',len(images),'images',flush=True)
