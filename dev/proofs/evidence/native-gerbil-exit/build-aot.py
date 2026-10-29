from pathlib import Path
import subprocess,os,json,time
out=Path(__file__).parent;root=Path('.data/native-gerbil-exit-20261020').resolve()
env=dict(os.environ,GERBIL_PATH=str(root/'build-env'),GERBIL_LOADPATH=str(root/'lib-clean'));env.pop('SDKROOT',None);env['GERBIL_GCC']=str(Path(__file__).with_name('gcc-link.py').resolve())
sdk=subprocess.check_output(['/opt/homebrew/bin/gcc-16','-print-sysroot'],env=env,text=True).strip();assert Path(sdk).is_dir()
args=['gxc','-exe','-d',str(root/'lib-clean'),'-ld-options','-isysroot '+sdk+' -lSystem','-o',str(root/'bin/native-authoring'),str(root/'source/weaver-native/entry.ss')]
with (out/'link-aot.log').open('w') as log:
 t=time.monotonic();p=subprocess.Popen(args,env=env,stdout=log,stderr=subprocess.STDOUT);print('AOT builder',p.pid,flush=True);c=p.wait()
(out/'link-aot.json').write_text(json.dumps(dict(args=args,exit=c,seconds=round(time.monotonic()-t,3),sdk=sdk,sdkRootRemoved=True,linkage='Scheme AOT; ordinary shared system libraries; no cleanup bypass'),indent=2)+'\n');print('AOT link',c)
raise SystemExit(c)
