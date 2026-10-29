from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import hashlib,subprocess,os,json,re,shutil
out=Path(__file__).parent;root=Path('.data/native-image-closure-20261020').resolve();assert not (out/'SHA256SUMS').exists();assert not (out/'images-complete.json').exists();sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
done=json.loads((out/'build-complete.json').read_text());assert done['objects']==238 and sha(out/'objects.json')==done['objectsSha256'] and sha(out/'partition.json')==done['partitionSha256'];rows=json.loads((out/'objects.json').read_text());by={r['module']:r for r in rows};partition=json.loads((out/'partition.json').read_text());assert len(by)==238
for r in rows:assert sha(r['object'])==r['objectSha256'] and sha(r['source'])==r['sourceSha256']
flags=json.loads((out/'compiler-options.json').read_text())['options'];env=dict(os.environ);env.pop('SDKROOT',None)
control={}
for r in rows:
 key='reuse-'+str(Path(r['module']).parent) if r['reusedVerifiedObject'] else 'solo-'+r['module'];control.setdefault(key,[]).append(r['module'])
assert len(control)==147
(out/'control-partition.json').write_text(json.dumps(list(control.values()),indent=2)+'\n')
tasks=[]
for block in range(4):
 for role,groups in [('control',list(control.values())),('candidate',partition)]:
  for number,members in enumerate(groups):tasks.append((block,role,number,members))
def one(task):
 block,role,number,members=task;records=[by[n] for n in members];defs=[s for r in records for s in r['definitions']];assert len(defs)==len(set(defs))
 target=root/f'g{block}'/role/'physical'/f'image-{number}.o1';target.parent.mkdir(parents=True,exist_ok=True);args=['/opt/homebrew/bin/gcc-16',*flags['FLAGS_OPT'],*flags['FLAGS_DYN'],'-Wl,-random_uuid',*[r['object'] for r in records],'-isysroot','/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk','-lSystem','-o',str(target)]
 with target.with_suffix('.link.log').open('w') as f:r=subprocess.run(args,env=env,stdout=f,stderr=subprocess.STDOUT)
 assert r.returncode==0,(task,args)
 headers=subprocess.check_output(['/usr/bin/otool','-l',str(target)],text=True);assert '__mod_init_func' not in headers and '__mod_term_func' not in headers
 uuid=re.search(r'uuid ([A-Fa-f0-9-]+)',headers).group(1);symbols=subprocess.check_output(['/usr/bin/nm','-gU',str(target)],text=True);entries={l.split()[-1] for l in symbols.splitlines() if 'LNK_' in l};assert entries=={r['entry'] for r in records}
 aliases=[]
 for record in records:
  alias=root/f'g{block}'/role/'aliases'/(record['module']+'.o1');alias.parent.mkdir(parents=True,exist_ok=True);os.link(target,alias);aliases.append(dict(module=record['module'],path=str(alias),entry=record['entry'],sourceSha256=record['sourceSha256'],objectSha256=record['objectSha256']))
 return dict(block=block,role=role,number=number,path=str(target),sha256=sha(target),uuid=uuid,inode=target.stat().st_ino,entries=sorted(entries),aliases=aliases,args=args,noCInitTerm=True)
with ThreadPoolExecutor(max_workers=3) as pool:images=list(pool.map(one,tasks))
assert len({r['uuid'] for r in images})==len(images) and len({r['inode'] for r in images})==len(images)
(out/'images.json').write_text(json.dumps(images,indent=2)+'\n')
shutil.copyfile('proofs/evidence/dynamic-gxi-paired/observer.c',out/'observer.c');shutil.copyfile('.data/dynamic-gxi-paired-20261020/observer.dylib',root/'observer.dylib');assert sha(root/'observer.dylib')==sha('.data/dynamic-gxi-paired-20261020/observer.dylib')
# Cover every consumed native body and interface in the actual narrowed closure.
home=Path('/opt/homebrew/Cellar/gerbil-scheme@0.19/0.19.20261009110849.1cfb032.patch618d76f9eb72/current');libs=[root/'lib-narrow',root/'lib-native',home/'lib'];observed=json.loads(Path('proofs/evidence/dynamic-gxi-exit/narrowed-0/receipt.json').read_text())['modules'];runtime={};interfaces={}
for name in observed:
 if name not in by:
  actual=next((lib/(name+'.o1') for lib in libs if (lib/(name+'.o1')).exists()),None);assert actual,name;runtime[str(actual)]=sha(actual)
 interface=next((lib/(name.split('~')[0]+'.ssi') for lib in libs if (lib/(name.split('~')[0]+'.ssi')).exists()),None);assert interface,name;interfaces[str(interface)]=sha(interface)
assert len(runtime)==22
inputs={str(f):sha(f) for f in root.rglob('*') if f.is_file()};inputs.update(runtime);inputs.update(interfaces)
for f in [home/'bin/gxi',home/'bin/gsc',home/'bin/gambuild-C',home/'include/gambit.h']:inputs[str(f.resolve())]=sha(f)
(out/'inputs-before.json').write_text(json.dumps(dict(byteInputs=inputs,excludedNativeBodies=runtime,interfaces=interfaces,selectedEntries=238,bodyClosure=260,scope='Complete actual selected/fallback Scheme body and interface closure plus owned sources/images and tool ABI; OS and foreign system dylibs remain trusted'),indent=2)+'\n')
record=dict(images=len(images),candidateImages=len(partition),controlImages=len(control),entries=238,bodyClosure=260,uniqueUUIDs=len(images),imagesSha256=sha(out/'images.json'),inputsSha256=sha(out/'inputs-before.json'),buildCommitSha256=sha(out/'build-complete.json'))
tmp=out/'images-complete.pending';tmp.write_text(json.dumps(record,indent=2)+'\n');tmp.rename(out/'images-complete.json');print('IMAGE PUBLICATION COMPLETE',record,flush=True)
