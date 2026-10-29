from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import re,shlex,json,subprocess,os,hashlib,time
out=Path(__file__).parent
if (out/'SHA256SUMS').exists() and (out/'SHA256SUMS').stat().st_size:raise SystemExit('Use a fresh generation; sealed evidence is immutable')
root=Path('.data/dynamic-gxi-exit-20261020').resolve();work=root/'image-official-build';overlay=root/'dynamic-images-official';work.mkdir();overlay.mkdir();home=Path('/opt/homebrew/Cellar/gerbil-scheme@0.19/0.19.20261009110849.1cfb032.patch618d76f9eb72/current');owner=home/'bin/gambuild-C';text=owner.read_text();vars={}
for key in ['FLAGS_OPT','FLAGS_OBJ','FLAGS_DYN','DEFS_DYN']:
 value=re.search(r'^'+key+r'="([^"]*)"',text,re.M).group(1);value=value.replace('${CORCXXFLAGS_GAMBUILD}','-pipe -foptimize-sibling-calls ').replace('${LDFLAGS_GAMBUILD}','');assert '$' not in value,key;vars[key]=shlex.split(value)
assert '-fwrapv' in vars['FLAGS_OBJ'] and '-fno-strict-aliasing' in vars['FLAGS_OBJ'] and '-D___DYNAMIC' in vars['DEFS_DYN']
(out/'official-compiler-options.json').write_text(json.dumps(dict(owner=str(owner),ownerSha256=hashlib.sha256(owner.read_bytes()).hexdigest(),configuredDefaultOverrides=dict(CORCXXFLAGS_GAMBUILD='-pipe -foptimize-sibling-calls ',LDFLAGS_GAMBUILD=''),options=vars,policy='Compiler defaults extracted from the installed owner; dynamic ABI definitions with object compile flags and dynamic link flags; no semantic option omission'),indent=2)+'\n')
old=json.loads((out/'dynamic-object-build.json').read_text());env=dict(os.environ);env.pop('SDKROOT',None)
def compile_one(r):
 name=r['module'];c=Path(r['object']).with_suffix('.c');obj=work/(name+'.o');obj.parent.mkdir(parents=True,exist_ok=True);args=['/opt/homebrew/bin/gcc-16',*vars['FLAGS_OPT'],*vars['FLAGS_OBJ'],*vars['DEFS_DYN'],'-I'+str(home/'include'),'-c',str(c),'-o',str(obj)];t=time.monotonic()
 with obj.with_suffix('.log').open('w') as f:p=subprocess.run(args,env=env,stdout=f,stderr=subprocess.STDOUT)
 assert p.returncode==0,name
 return dict(module=name,source=r['source'],sourceSha256=r['sourceSha256'],generatedC=str(c),generatedCSha256=hashlib.sha256(c.read_bytes()).hexdigest(),object=str(obj),objectSha256=hashlib.sha256(obj.read_bytes()).hexdigest(),args=args,exit=p.returncode,seconds=round(time.monotonic()-t,3))
t=time.monotonic();rows=[]
with ThreadPoolExecutor(max_workers=3) as pool:
 for r in pool.map(compile_one,old):
  rows.append(r);(out/'official-object-build.json').write_text(json.dumps(rows,indent=2)+'\n');print('OFFICIAL OBJECT',r['module'],flush=True)
groups={}
for r in rows:groups.setdefault(str(Path(r['module']).parent),[]).append(r)
images=[]
for group,records in groups.items():
 image=work/('image-'+group.replace('/','-')+'.o1');args=['/opt/homebrew/bin/gcc-16',*vars['FLAGS_OPT'],*vars['FLAGS_DYN'],*[r['object'] for r in records],'-isysroot','/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk','-lSystem','-o',str(image)]
 with image.with_suffix('.log').open('w') as f:p=subprocess.run(args,env=env,stdout=f,stderr=subprocess.STDOUT)
 assert p.returncode==0,group
 headers=subprocess.check_output(['/usr/bin/otool','-l',str(image)],text=True);assert '__mod_init_func' not in headers and '__mod_term_func' not in headers
 aliases=[]
 for r in records:
  alias=overlay/(r['module']+'.o1');alias.parent.mkdir(parents=True,exist_ok=True);os.link(image,alias);aliases.append(str(alias))
 images.append(dict(group=group,image=str(image),sha256=hashlib.sha256(image.read_bytes()).hexdigest(),aliases=aliases,linkArgs=args,noCInitializersOrDestructors=True))
(out/'official-dynamic-images.json').write_text(json.dumps(dict(exit=0,seconds=round(time.monotonic()-t,3),modules=len(rows),images=images,compilerOptions='official-compiler-options.json'),indent=2)+'\n');print('OFFICIAL IMAGE BUILD PASS',len(rows),len(images),flush=True)
