from pathlib import Path
import shutil,subprocess,json,time,os
out=Path(__file__).parent
if (out/"SHA256SUMS").exists() and (out/"SHA256SUMS").stat().st_size:
 raise SystemExit("Sealed generation is immutable; reproduce in fresh isolation and evidence directories.")
old=Path('.data/native-gerbil-exit-20261020').resolve();root=Path('.data/dynamic-gxi-exit-20261020').resolve()
shutil.copytree(old/'source',root/'source',dirs_exist_ok=True)
lib=root/'lib-native';lib.mkdir(exist_ok=True)
args=['gxi',str(out/'compile-fresh.ss')]
(out/'compile-fresh.ss').write_bytes(Path('proofs/evidence/native-gerbil-exit/compile-fresh.ss').read_bytes())
extra=dict(WEAVER_NATIVE_ROOT=str(root),WEAVER_NATIVE_LIB=str(lib),GERBIL_PATH=str(root/'build-env'),GERBIL_LOADPATH=str(lib)+':'+str(root/'source'));Path(extra['GERBIL_PATH']).mkdir(exist_ok=True)
env=dict(os.environ,**extra);env.pop('SDKROOT',None)
t=time.monotonic()
with (out/'source-build.log').open('w') as f:
 p=subprocess.Popen(args,env=env,stdout=f,stderr=subprocess.STDOUT);print('builder',p.pid,flush=True);c=p.wait()
(out/'source-build.json').write_text(json.dumps(dict(args=args,env=extra,SDKROOT='removed only in child',exit=c,seconds=round(time.monotonic()-t,3)),indent=2)+'\n');print('SOURCE BUILD',c,flush=True)
raise SystemExit(c)
