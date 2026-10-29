from pathlib import Path
import subprocess,os,json,time,hashlib
out=Path(__file__).parent
if (out.parent/"SHA256SUMS").is_file() and (out.parent/"SHA256SUMS").stat().st_size:
 raise SystemExit("Sealed generation; reproduce in fresh directories.")
if (out/"SHA256SUMS").exists() and (out/"SHA256SUMS").stat().st_size:
 raise SystemExit("Sealed generation is immutable; reproduce in fresh isolation and evidence directories.")
root=Path('.data/dynamic-gxi-exit-20261020').resolve();work=root/'lazy-control-official';work.mkdir();prefix=Path('/opt/homebrew/Cellar/gerbil-scheme@0.19/0.19.20261009110849.1cfb032.patch618d76f9eb72/current');official=json.loads((out.parent/'official-compiler-options.json').read_text())['options'];defs=official['DEFS_DYN'];env=dict(os.environ,GAMBOPT='~~='+str(prefix));env.pop('SDKROOT',None);commands=[]
def call(args):
 with (out/'lazy-control-build.log').open('a') as f:r=subprocess.run(args,env=env,stdout=f,stderr=subprocess.STDOUT)
 commands.append(dict(args=args,exit=r.returncode));assert r.returncode==0,args
for name in ['a','b']:
 src=work/(name+'.scm');src.write_text('(display "INIT '+name.upper()+'\\n")\n')
 call([str(prefix/'bin/gsc'),'-c','-linker-name',name+'.o1','-o',str(work/(name+'.c')),str(src)])
 call(['/opt/homebrew/bin/gcc-16',*official['FLAGS_OPT'],*official['FLAGS_OBJ'],*defs,'-I'+str(prefix/'include'),'-c',str(work/(name+'.c')),'-o',str(work/(name+'.o'))])
image=work/'two-entries.image';call(['/opt/homebrew/bin/gcc-16','-bundle','-undefined','dynamic_lookup',str(work/'a.o'),str(work/'b.o'),'-isysroot','/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk','-lSystem','-o',str(image)])
for name in ['a','b']:os.link(image,work/(name+'.o1'))
script=work/'entry.ss';script.write_text('(load "'+str(work/'a.o1')+'")\n(display "AFTER A\\n")\n(load "'+str(work/'b.o1')+'")\n(display "AFTER B\\n")\n(load "'+str(root/'canary-official/canary.o1')+'")\n(display "LAZY-RETURN\\n")\n')
marker=(out/'lazy-cleanup.txt').resolve();trace=(out/'lazy-module-cleanup.json').resolve();assert not marker.exists()
env.update(GERBIL_PREFIX=str(prefix.parent),GERBIL_HOME=str(prefix),GAMBOPT='~~='+str(prefix)+',~~bin='+str(prefix/'bin')+',~~lib='+str(prefix/'lib'),GERBIL_PATH=str(work/'run-env'),GERBIL_LOADPATH=':'.join(str(root/x) for x in ['dynamic-images-official','lib-narrow','lib-native']),DYLD_INSERT_LIBRARIES=str(root/'module-cleanup-observer.dylib'),WEAVER_MODULE_CLEANUP_TRACE=str(trace),WEAVER_NATIVE_CANARY_LOG=str(marker));Path(env['GERBIL_PATH']).mkdir()
t=time.monotonic();args=[str(prefix/'bin/gxi'),str(script)];late=False
with (out/'lazy-control.log').open('w') as f:
 p=subprocess.Popen(args,env=env,stdout=f,stderr=subprocess.STDOUT)
 while p.poll() is None:
  if time.monotonic()-t>=15:late=True
  time.sleep(.01)
elapsed=time.monotonic()-t;lines=(out/'lazy-control.log').read_text().splitlines();expected=['INIT A','AFTER A','INIT B','AFTER B','NATIVE-DYNAMIC-CANARY-LOADED','LAZY-RETURN'];counts=json.loads(trace.read_text());ok=p.returncode==0 and not late and elapsed<=15 and lines==expected and marker.read_text()=='LU' and counts['moduleOpens']>2 and counts['moduleOpens']==counts['moduleCloses'] and counts['outstandingModuleRefs']==0
(out/'lazy-entry-control.json').write_text(json.dumps(dict(commands=commands,args=args,exit=p.returncode,seconds=round(elapsed,3),gateSeconds=15,qualified=ok,lines=lines,expected=expected,cleanup=marker.read_text(),moduleCounts=counts,sharedInode=(work/'a.o1').stat().st_ino==(work/'b.o1').stat().st_ino,forcedExit=False),indent=2)+'\n');print('LAZY ENTRY CONTROL',ok,round(elapsed,3),counts)
assert ok
