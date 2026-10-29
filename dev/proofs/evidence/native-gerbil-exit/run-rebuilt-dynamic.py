from pathlib import Path
import subprocess,time,json,os
out=Path(__file__).parent;root=Path('.data/native-gerbil-exit-20261020').resolve();args=['gxi','-e','(import :weaver-native/fixture)'];env=dict(os.environ,GERBIL_PATH=str(root/'run-env-dynamic'),GERBIL_LOADPATH=str(root/'lib-clean'));Path(env['GERBIL_PATH']).mkdir(exist_ok=True)
t=time.monotonic();log=(out/'rebuilt-dynamic.log').open('w');p=subprocess.Popen(args,env=env,stdout=log,stderr=subprocess.STDOUT);gate=None
while p.poll() is None and time.monotonic()-t<35:
 if gate is None and time.monotonic()-t>15:gate=False
 time.sleep(.03)
log.close();elapsed=time.monotonic()-t
r=dict(args=args,exit=p.poll(),seconds=round(elapsed,3),acceptanceBudgetSeconds=15,withinBudget=gate is not False and elapsed<=15,nativeExitForced=False,output=(out/'rebuilt-dynamic.log').read_text(),loadpath=env['GERBIL_LOADPATH']);(out/'rebuilt-dynamic.json').write_text(json.dumps(r,indent=2)+'\n');print({k:r[k] for k in ['exit','seconds','withinBudget']})
