from pathlib import Path
import subprocess,json,os,time,re,hashlib,csv,resource
out=Path(__file__).parent;root=Path('.data/dynamic-gxi-paired-20261020').resolve();plan=json.loads((out/'plan.json').read_text());assert not(out/'SHA256SUMS').exists()
prefix=Path('/opt/homebrew/Cellar/gerbil-scheme@0.19/0.19.20261009110849.1cfb032.patch618d76f9eb72');home=prefix/'current';results=[]
for family,block in plan['familyBlockOrder']:
 order=plan['blocks'][block]
 for cell in order:
  for use in plan['uses']:
   label=f'{family}-b{block}-{cell}-{use}';d=out/label;d.mkdir();libs=[]
   libs.append((root/'uuid' if family=='uuid' else root)/f'g{block}'/cell/('packed-aliases' if cell in 'CD' else 'independent'))
   if cell in 'BD':libs.append(root/'lib-narrow')
   libs.append(root/'lib-native');env=dict(os.environ,GERBIL_PREFIX=str(prefix),GERBIL_HOME=str(home),GAMBOPT=f'~~={home},~~bin={home}/bin,~~lib={home}/lib',GERBIL_LOADPATH=':'.join(map(str,libs)),GERBIL_PATH=str(root/label),DYLD_INSERT_LIBRARIES=str(root/'observer.dylib'),WEAVER_MODULE_CLEANUP_TRACE=str((d/'cleanup.json').resolve()),WEAVER_DYLD_TIMELINE=str((d/'timeline.tsv').resolve()))
   Path(env['GERBIL_PATH']).mkdir();args=[str(home/'bin/gxi'),str(root/'fixture.ss')];cpuBefore=resource.getrusage(resource.RUSAGE_CHILDREN);loadBefore=os.getloadavg();t=time.monotonic();late=False;markers={};buf=b''
   # Pipe lets the controller timestamp real fixture output without modifying it.
   p=subprocess.Popen(args,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);os.set_blocking(p.stdout.fileno(),False)
   with (d/'native.log').open('wb') as f:
    while True:
     try:chunk=os.read(p.stdout.fileno(),65536)
     except BlockingIOError:chunk=None
     now=time.monotonic()-t
     if chunk:
      f.write(chunk);f.flush();buf+=chunk
      for marker in [b'CHECK ',b'NATIVE-AUTHORING-CHECKS-COMPLETE']:
       if marker in buf and marker.decode() not in markers:markers[marker.decode()]=now
     if now>15 and not late:late=True;print(label,'DEADLINE FAILED; retaining child until natural exit',p.pid,flush=True)
     if p.poll() is not None and chunk==b'':break
     time.sleep(.005)
   code=p.wait();elapsed=time.monotonic()-t;cpuAfter=resource.getrusage(resource.RUSAGE_CHILDREN);txt=buf.decode(errors='replace');checks=re.findall(r'^CHECK (\S+) PASS$',txt,re.M)
   cleanup=json.loads((d/'cleanup.json').read_text()) if (d/'cleanup.json').exists() else None
   rows=list(csv.DictReader((d/'timeline.tsv').read_text().split('#')[0].splitlines(),delimiter='\t')) if (d/'timeline.tsv').exists() else []
   sums={k:sum(int(r['duration_ns']) for r in rows if r['op']==k and r['tracked']=='1')/1e9 for k in ['L','U']}
   r=dict(label=label,cpuUserSeconds=cpuAfter.ru_utime-cpuBefore.ru_utime,cpuSystemSeconds=cpuAfter.ru_stime-cpuBefore.ru_stime,loadAverageBefore=loadBefore,loadAverageAfter=os.getloadavg(),family=family,block=block,cell=cell,use=use,args=args,pid=p.pid,exit=code,seconds=elapsed,deadlineFailed=late,gateSeconds=15,forcedExit=False,checks=checks,markers=markers,cleanup=cleanup,apiSeconds=sums,loadpath=env['GERBIL_LOADPATH'],fixtureSha256=hashlib.sha256((root/'fixture.ss').read_bytes()).hexdigest(),qualified=code==0 and not late and elapsed<=15 and len(checks)==11 and len(set(checks))==11 and 'duplicate-json-contract-accepted decoder-rejected' in txt and 'NATIVE-AUTHORING-CHECKS-COMPLETE' in txt and cleanup is not None and cleanup['moduleOpens']==cleanup['moduleCloses'] and all(cleanup[k]==0 for k in ['outstandingModuleRefs','closeErrors','overflow']) and '# eventOverflow=0' in (d/'timeline.tsv').read_text())
   (d/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');results.append(r);(out/'matrix.json').write_text(json.dumps(results,indent=2)+'\n');print(label,round(elapsed,3),r['qualified'],sums,flush=True)
