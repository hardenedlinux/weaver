from pathlib import Path
import json,os,time,subprocess,sys
out=Path(__file__).parent;name=sys.argv[1];source=Path('.data/dynamic-gxi-exit-20261020/fixture.ss').resolve()
lib=Path('.data/native-gerbil-exit-20261020/lib-clean').resolve() if name=='isolated' else Path('/Users/guangtao/ghq/github.com/tao3k/poo-flow/core/.gerbil/lib')
env=dict(os.environ,GERBIL_PATH=str(Path('.data/dynamic-gxi-exit-20261020',name).resolve()),GERBIL_LOADPATH=str(lib));Path(env['GERBIL_PATH']).mkdir(exist_ok=True)
args=['gxi',str(source)];t=time.monotonic();gate=None
with (out/(name+'.log')).open('w') as f:
 p=subprocess.Popen(args,env=env,stdout=f,stderr=subprocess.STDOUT)
 while p.poll() is None:
  elapsed=time.monotonic()-t
  if elapsed>=15 and gate is None:
   gate=False;print('15 SECOND GATE FAILED; observing natural exit without terminating',flush=True)
  if elapsed>=40:
   print('diagnostic observer returning; child not terminated',flush=True);break
  time.sleep(.02)
r=dict(args=args,exit=p.poll(),seconds=round(time.monotonic()-t,3),gateSeconds=15,withinBudget=gate is not False and p.returncode==0,forcedExit=False,pid=p.pid,loadpath=str(lib));(out/(name+'.json')).write_text(json.dumps(r,indent=2)+'\n');print(r)
