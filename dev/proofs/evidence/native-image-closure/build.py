from pathlib import Path
from concurrent.futures import ThreadPoolExecutor,as_completed
import json,re,os,subprocess,hashlib,time,shutil
out=Path(__file__).parent;root=Path('.data/native-image-closure-20261020').resolve();assert not (out/'SHA256SUMS').exists();assert not (out/'build-complete.json').exists()
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
old=Path('proofs/evidence/dynamic-gxi-paired');home=Path('/opt/homebrew/Cellar/gerbil-scheme@0.19/0.19.20261009110849.1cfb032.patch618d76f9eb72/current');flags=json.loads((old/'official-compiler-options.json').read_text());assert sha(flags['owner'])==flags['ownerSha256'];(out/'compiler-options.json').write_text(json.dumps(flags,indent=2)+'\n');env=dict(os.environ,GAMBOPT='~~='+str(home));env.pop('SDKROOT',None)
for name in ['lib-native','lib-narrow']:
 shutil.copytree(Path('.data/dynamic-gxi-paired-20261020')/name,root/name)
shutil.copyfile('.data/dynamic-gxi-paired-20261020/fixture.ss',root/'fixture.ss')
observed=json.loads(Path('proofs/evidence/dynamic-gxi-exit/narrowed-0/receipt.json').read_text())['modules'];reuse={r['module']:r for r in json.loads((old/'official-object-build.json').read_text())};selected=[];excluded=[];inputs={};work=root/'build';work.mkdir()
for name,path in sorted(observed.items()):
 source=Path(path).with_suffix('.scm');assert source.is_file();inputs[str(source)]=sha(source)
 if re.search(r'\b(?:c-declare|c-initialize|c-lambda|c-define|foreign|ffi)\b',source.read_text()):excluded.append(dict(module=name,path=path,source=str(source),sourceSha256=sha(source)));continue
 selected.append((name,source))
assert len(selected)==238 and len(excluded)==22
(out/'admission.json').write_text(json.dumps(dict(selected=[n for n,s in selected],excluded=excluded,policy='Conservative lowered Scheme C/FFI token exclusion; no C init/term sections; all exported definitions conflict-colored; original entry names retained'),indent=2)+'\n')
# Source snapshots are inputs, not authoritative completion. The completion record
# is published only after all source/object, entry and header audits below.
def one(item):
 name,source=item;slot=work/name;slot.parent.mkdir(parents=True,exist_ok=True);snapshot=root/'lowered-source'/(name+'.scm');snapshot.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,snapshot);commands=[];t=time.monotonic()
 if name in reuse:
  r=reuse[name];assert sha(r['source'])==r['sourceSha256'] and sha(r['object'])==r['objectSha256'] and sha(r['generatedC'])==r['generatedCSha256'];c=slot.with_suffix('.c');obj=slot.with_suffix('.o');shutil.copyfile(r['generatedC'],c);shutil.copyfile(r['object'],obj);reused=True
 else:
  c=slot.with_suffix('.c');obj=slot.with_suffix('.o');reused=False
  for args in [[str(home/'bin/gsc'),'-c','-linker-name',Path(name).name+'.o1','-o',str(c),str(snapshot)],['/opt/homebrew/bin/gcc-16',*flags['options']['FLAGS_OPT'],*flags['options']['FLAGS_OBJ'],*flags['options']['DEFS_DYN'],'-I'+str(home/'include'),'-c',str(c),'-o',str(obj)]]:
   with slot.with_suffix('.log').open('a') as f:r=subprocess.run(args,env=env,stdout=f,stderr=subprocess.STDOUT)
   commands.append(dict(args=args,exit=r.returncode));assert r.returncode==0,(name,args)
 symbols=subprocess.check_output(['/usr/bin/nm','-gU',str(obj)],text=True);defs={l.split()[-1] for l in symbols.splitlines() if l.split()};links={s for s in defs if 'LNK_' in s};original=subprocess.check_output(['/usr/bin/nm','-gU',str(source.with_suffix('.o1'))],text=True);expected={l.split()[-1] for l in original.splitlines() if 'LNK_' in l};assert len(links)==1 and links==expected,(name,links,expected)
 hdr=subprocess.check_output(['/usr/bin/otool','-l',str(obj)],text=True);assert '__mod_init_func' not in hdr and '__mod_term_func' not in hdr
 undefined=subprocess.check_output(['/usr/bin/nm','-u',str(obj)],text=True);assert 'LNK_' not in undefined,name
 return dict(module=name,source=str(source),sourceSha256=sha(source),snapshot=str(snapshot),object=str(obj),objectSha256=sha(obj),generatedC=str(c),generatedCSha256=sha(c),reusedVerifiedObject=reused,definitions=sorted(defs),entry=next(iter(links)),commands=commands,seconds=time.monotonic()-t,noForeignInitializers=True,noUndefinedLinkEntries=True)
rows=[];started=time.monotonic()
with ThreadPoolExecutor(max_workers=3) as pool:
 for future in as_completed([pool.submit(one,item) for item in selected]):
  r=future.result();rows.append(r);(out/'object-progress.json').write_text(json.dumps(rows,indent=2)+'\n');print('OBJECT',len(rows),r['module'],'reused',r['reusedVerifiedObject'],flush=True)
rows.sort(key=lambda r:r['module']);(out/'objects.json').write_text(json.dumps(rows,indent=2)+'\n')
# Greedy coloring uses every exported definition, not basename guesses.
groups=[]
for row in sorted(rows,key=lambda r:(-sum(bool(set(r['definitions'])&set(q['definitions'])) for q in rows if q!=r),r['module'])):
 for group in groups:
  if not set(row['definitions']).intersection(s for r in group for s in r['definitions']):group.append(row);break
 else:groups.append([row])
assert sum(map(len,groups))==238
(out/'partition.json').write_text(json.dumps([[r['module'] for r in g] for g in groups],indent=2)+'\n')
for name,h in inputs.items():assert sha(name)==h
(out/'source-inputs.json').write_text(json.dumps(inputs,indent=2)+'\n')
record=dict(objects=238,freshCompiled=sum(not r['reusedVerifiedObject'] for r in rows),verifiedReused=sum(r['reusedVerifiedObject'] for r in rows),excluded=22,groups=len(groups),seconds=time.monotonic()-started,objectsSha256=sha(out/'objects.json'),partitionSha256=sha(out/'partition.json'),compilerOptionsSha256=sha(out/'compiler-options.json'))
tmp=out/'build-complete.pending';tmp.write_text(json.dumps(record,indent=2)+'\n');tmp.rename(out/'build-complete.json');print('BUILD COMPLETE',record,flush=True)
