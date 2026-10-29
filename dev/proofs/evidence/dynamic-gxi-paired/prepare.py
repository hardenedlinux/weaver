from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import json,os,subprocess,hashlib,re,shutil
out=Path(__file__).parent;root=Path('.data/dynamic-gxi-paired-20261020').resolve();old=Path('.data/dynamic-gxi-exit-20261020').resolve()
assert not (out/'SHA256SUMS').exists()
for name in ['lib-native','lib-narrow']:
 if not (root/name).exists():shutil.copytree(old/name,root/name)
shutil.copyfile(old/'fixture.ss',root/'fixture.ss')
rows=json.loads((out/'official-object-build.json').read_text());assert len(rows)==98 and (out/'official-dynamic-images.json').exists(), 'Full source rebuild must complete before preparation';flags=json.loads((out/'official-compiler-options.json').read_text())['options'];env=dict(os.environ);env.pop('SDKROOT',None)
groups={}
for r in rows:groups.setdefault(str(Path(r['module']).parent),[]).append(r)
def link(task):
 gen,cell,kind,name,records=task;image=root/f'g{gen}'/cell/kind/(name+'.o1');image.parent.mkdir(parents=True,exist_ok=True)
 args=['/opt/homebrew/bin/gcc-16',*flags['FLAGS_OPT'],*flags['FLAGS_DYN'],*[r['object'] for r in records],'-isysroot','/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk','-lSystem','-o',str(image)]
 with image.with_suffix('.link.log').open('w') as f:r=subprocess.run(args,env=env,stdout=f,stderr=subprocess.STDOUT)
 assert r.returncode==0,args
 header=subprocess.check_output(['/usr/bin/otool','-l',str(image)],text=True);assert '__mod_init_func' not in header and '__mod_term_func' not in header
 uuid=re.search(r'uuid ([A-Fa-f0-9-]+)',header);assert uuid
 aliases=[]
 if kind=='packed':
  for entry in records:
   a=root/f'g{gen}'/cell/'packed-aliases'/(entry['module']+'.o1');a.parent.mkdir(parents=True,exist_ok=True);os.link(image,a);aliases.append(str(a))
 else:aliases=[str(image)]
 return dict(generation=gen,cell=cell,kind=kind,path=str(image),uuid=uuid.group(1),inode=image.stat().st_ino,sha256=hashlib.sha256(image.read_bytes()).hexdigest(),entries=[r['module'] for r in records],aliases=aliases,args=args)
tasks=[]
for gen in [0,1]:
 for cell in ['A','B']:
  for row in rows:tasks.append((gen,cell,'independent',row['module'],[row]))
 for cell in ['C','D']:
  for group,rs in groups.items():tasks.append((gen,cell,'packed',group.replace('/','-'),rs))
with ThreadPoolExecutor(max_workers=3) as pool:images=list(pool.map(link,tasks))
(out/'images.json').write_text(json.dumps(images,indent=2)+'\n')
print('PREPARED',len(images),'images; UUIDs',len(set(r['uuid'] for r in images)),flush=True)
# Complete inherited native input byte inventory plus all new artifacts. Hashing warms file data.
base=json.loads(Path('proofs/evidence/dynamic-gxi-exit/official-abi/inputs-before.json').read_text())
(out/'inherited-input-inventory.json').write_text(json.dumps(base,indent=2)+'\n')
files={str(p.resolve()):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}
(out/'inputs-before.json').write_text(json.dumps(files,indent=2)+'\n')
