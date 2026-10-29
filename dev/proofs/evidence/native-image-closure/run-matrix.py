from pathlib import Path
import subprocess,json,os,time,re,hashlib,csv,resource
out=Path(__file__).parent;root=Path('.data/native-image-closure-20261020').resolve();assert not (out/'SHA256SUMS').exists();plan=json.loads((out/'plan.json').read_text());published=json.loads((out/'images-complete.json').read_text());hashCache={}
def sha(p):
 f=Path(p);st=f.stat();key=(st.st_dev,st.st_ino,st.st_size,st.st_mtime_ns)
 if key not in hashCache:hashCache[key]=hashlib.sha256(f.read_bytes()).hexdigest()
 return hashCache[key]
assert sha(out/'images.json')==published['imagesSha256'] and sha(out/'inputs-before.json')==published['inputsSha256'];manifest=json.loads((out/'images.json').read_text());base=json.loads((out/'inputs-before.json').read_text());allInputs=base['byteInputs'];assert all(sha(n)==h for n,h in allInputs.items());prefix=Path('/opt/homebrew/Cellar/gerbil-scheme@0.19/0.19.20261009110849.1cfb032.patch618d76f9eb72');home=prefix/'current';results=[]
(out/'run-input-identity.json').write_text(json.dumps(dict(planSha256=sha(out/'plan.json'),controllerSha256=sha(__file__),observerSha256=sha(root/'observer.dylib'),fixtureSha256=sha(root/'fixture.ss'),publicationSha256=sha(out/'images-complete.json')),indent=2)+'\n')
for block,order in enumerate(plan['blocks']):
 for role in order:
  expected={str(Path(a['path']).resolve()) for im in manifest if im['block']==block and im['role']==role for a in im['aliases']};expected.update(str(Path(n).resolve()) for n in base['excludedNativeBodies']);assert len(expected)==260
  for use in plan['uses']:
   label=f'b{block}-{role}-{use}';d=out/label;d.mkdir();paths=[root/f'g{block}'/role/'aliases',root/'lib-narrow',root/'lib-native'];env=dict(os.environ,GERBIL_PREFIX=str(prefix),GERBIL_HOME=str(home),GAMBOPT=f'~~={home},~~bin={home}/bin,~~lib={home}/lib',GERBIL_LOADPATH=':'.join(map(str,paths)),GERBIL_PATH=str(root/label),DYLD_INSERT_LIBRARIES=str(root/'observer.dylib'),WEAVER_MODULE_CLEANUP_TRACE=str((d/'cleanup.json').resolve()),WEAVER_DYLD_TIMELINE=str((d/'timeline.tsv').resolve()));Path(env['GERBIL_PATH']).mkdir();args=[str(home/'bin/gxi'),str(root/'fixture.ss')];cpuBefore=resource.getrusage(resource.RUSAGE_CHILDREN);loadBefore=os.getloadavg();t=time.monotonic();late=False
   with (d/'native.log').open('w') as f:
    child=subprocess.Popen(args,env=env,stdout=f,stderr=subprocess.STDOUT)
    while child.poll() is None:
     if time.monotonic()-t>15 and not late:late=True;print(label,'FAIL unchanged 15 seconds; wait for natural exit',child.pid,flush=True)
     time.sleep(.005)
   code=child.wait();elapsed=time.monotonic()-t;cpuAfter=resource.getrusage(resource.RUSAGE_CHILDREN);txt=(d/'native.log').read_text();checks=re.findall(r'^CHECK (\S+) PASS$',txt,re.M);cleanup=json.loads((d/'cleanup.json').read_text()) if (d/'cleanup.json').exists() else None;trace=(d/'timeline.tsv').read_text() if (d/'timeline.tsv').exists() else '';events=list(csv.DictReader(trace.split('#')[0].splitlines(),delimiter='\t')) if trace else [];observed={str(Path(e['path']).resolve()) for e in events if e['op']=='L' and e['tracked']=='1'};api={k:sum(int(e['duration_ns']) for e in events if e['op']==k and e['tracked']=='1')/1e9 for k in ['L','U']}
   qualified=code==0 and not late and elapsed<=15 and len(checks)==11 and len(set(checks))==11 and 'duplicate-json-contract-accepted decoder-rejected' in txt and 'NATIVE-AUTHORING-CHECKS-COMPLETE' in txt and cleanup is not None and cleanup['moduleOpens']==cleanup['moduleCloses']==260 and all(cleanup[k]==0 for k in ['outstandingModuleRefs','closeErrors','overflow']) and observed==expected and '# eventOverflow=0' in trace
   r=dict(label=label,block=block,role=role,use=use,args=args,pid=child.pid,exit=code,seconds=elapsed,gateSeconds=15,deadlineFailed=late,forcedExit=False,checks=checks,cleanup=cleanup,apiSeconds=api,exactModulePaths=observed==expected,missingPaths=sorted(expected-observed),extraPaths=sorted(observed-expected),observedModulePaths=sorted(observed),cpuUserSeconds=cpuAfter.ru_utime-cpuBefore.ru_utime,cpuSystemSeconds=cpuAfter.ru_stime-cpuBefore.ru_stime,loadAverageBefore=loadBefore,loadAverageAfter=os.getloadavg(),qualified=qualified,fixtureSha256=sha(root/'fixture.ss'));(d/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');results.append(r);(out/'matrix.json').write_text(json.dumps(results,indent=2)+'\n');print(label,round(elapsed,3),qualified,api,flush=True)
assert len(results)==16
hashCache.clear()
for name,h in allInputs.items():assert sha(name)==h,name
(out/'inputs-after.json').write_text(json.dumps(dict(unchanged=True,count=len(allInputs),byteInputs=allInputs),indent=2)+'\n');print('COLLECTION COMPLETE; read typed candidate-series verdict, never collector exit code',flush=True)
