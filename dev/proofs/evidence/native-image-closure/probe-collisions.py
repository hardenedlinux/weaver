from pathlib import Path
import json,subprocess,os,time,hashlib,shutil
out=Path(__file__).parent;root=Path('.data/native-image-closure-20261020').resolve();work=root/'collision-probe';work.mkdir();home=Path('/opt/homebrew/Cellar/gerbil-scheme@0.19/0.19.20261009110849.1cfb032.patch618d76f9eb72/current');flags=json.loads((out/'compiler-options.json').read_text())['options'];env=dict(os.environ,GAMBOPT='~~='+str(home));env.pop('SDKROOT',None);build=[]
for letter in ['A','B']:
 source=work/(letter+'.scm');source.write_text('(display "INITIALIZE-'+letter+'\\n")\n');c=source.with_suffix('.c');obj=source.with_suffix('.o');target=work/letter/'collision.o1';target.parent.mkdir()
 commands=[[str(home/'bin/gsc'),'-c','-linker-name','collision.o1','-o',str(c),str(source)],['/opt/homebrew/bin/gcc-16',*flags['FLAGS_OPT'],*flags['FLAGS_OBJ'],*flags['DEFS_DYN'],'-I'+str(home/'include'),'-c',str(c),'-o',str(obj)],['/opt/homebrew/bin/gcc-16',*flags['FLAGS_OPT'],*flags['FLAGS_DYN'],'-Wl,-random_uuid',str(obj),'-isysroot',json.loads((out/'link-profile.json').read_text())['sdk'],'-lSystem','-o',str(target)]]
 for args in commands:
  with (out/'probe-build.log').open('a') as f:r=subprocess.run(args,env=env,stdout=f,stderr=subprocess.STDOUT)
  build.append(dict(args=args,exit=r.returncode));assert r.returncode==0
# A direct merge must fail before any native module can be admitted.
args=['/opt/homebrew/bin/gcc-16',*flags['FLAGS_OPT'],*flags['FLAGS_DYN'],str(work/'A.o'),str(work/'B.o'),'-isysroot',json.loads((out/'link-profile.json').read_text())['sdk'],'-lSystem','-o',str(work/'rejected-merge.o1')]
with (out/'duplicate-link-rejected.log').open('w') as f:r=subprocess.run(args,env=env,stdout=f,stderr=subprocess.STDOUT)
assert r.returncode!=0 and 'duplicate' in (out/'duplicate-link-rejected.log').read_text().lower();build.append(dict(args=args,exit=r.returncode,expected='duplicate linker-entry rejection'))
(out/'probe-build.json').write_text(json.dumps(build,indent=2)+'\n')
# Equal basenames stay separated by their native image handle.
wrong=work/'wrong'/'collision.o1';wrong.parent.mkdir();os.link(work/'A/collision.o1',wrong)
for role,pathB in [('qualified',work/'B/collision.o1'),('wrong-alias',wrong)]:
 fixture=work/(role+'.ss');fixture.write_text('(load "'+str(work/'A/collision.o1')+'")\n(display "AFTER-A\\n")\n(load "'+str(pathB)+'")\n(display "AFTER-B\\n")\n');d=out/('probe-'+role);d.mkdir();prefix=home.parent;runenv=dict(os.environ,GERBIL_PREFIX=str(prefix),GERBIL_HOME=str(home),GAMBOPT=f'~~={home},~~bin={home}/bin,~~lib={home}/lib',GERBIL_PATH=str(work/role),DYLD_INSERT_LIBRARIES=str(root/'observer.dylib'),WEAVER_MODULE_CLEANUP_TRACE=str((d/'cleanup.json').resolve()),WEAVER_DYLD_TIMELINE=str((d/'timeline.tsv').resolve()));Path(runenv['GERBIL_PATH']).mkdir();t=time.monotonic();late=False
 with (d/'native.log').open('w') as f:
  child=subprocess.Popen([str(home/'bin/gxi'),str(fixture)],env=runenv,stdout=f,stderr=subprocess.STDOUT)
  while child.poll() is None:
   if time.monotonic()-t>15:late=True
   time.sleep(.005)
 code=child.wait();elapsed=time.monotonic()-t;txt=(d/'native.log').read_text();observations=[x for x in txt.splitlines() if x.startswith(('INITIALIZE-','AFTER-'))];identityPreserved=observations==['INITIALIZE-A','AFTER-A','INITIALIZE-B','AFTER-B'];cleanup=json.loads((d/'cleanup.json').read_text());assert (code==0 if role=='qualified' else code>=0) and cleanup['moduleOpens']==cleanup['moduleCloses'] and cleanup['outstandingModuleRefs']==cleanup['closeErrors']==0
 assert identityPreserved==(role=='qualified'),(role,txt)
 (d/'receipt.json').write_text(json.dumps(dict(role=role,pid=child.pid,exit=code,seconds=elapsed,gateSeconds=15,deadlineFailed=late,forcedExit=False,identityPreserved=identityPreserved,observations=observations,cleanup=cleanup,scope='Native qualified-handle identity control; wrong alias is expected to fail identity even with successful native return'),indent=2)+'\n');print(role,elapsed,identityPreserved,flush=True)
