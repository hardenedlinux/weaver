from pathlib import Path
import subprocess,tempfile,os,json,time,hashlib
out=Path(__file__).parent;failure=out/'native-natural-exit-timeout';failure.mkdir(exist_ok=True)
for n in ['native-authoring.ss','native-authoring.json','native-authoring.log']:(failure/n).write_bytes((out/n).read_bytes())
controls={
'version-only':'(display (gerbil-version-string)) (newline) (display "CONTROL-COMPLETE\\n")\n',
'json-only':'(import :std/encoding/json)\n(call-with-input-string "{\\"node\\":\\"infer\\"}" read-json)\n(display "CONTROL-COMPLETE\\n")\n',
'core-value-contract-only':(out/'native-probe.ss').read_text().replace('NATIVE-CONTRACT-PROBE-PASS','CONTROL-COMPLETE')}
rows=[]
for name,source in controls.items():
 script=out/(name+'.ss');script.write_text(source);args=['gxi',str(script)]
 env=dict(os.environ,GERBIL_PATH=tempfile.mkdtemp(prefix='weaver-native-control-'),GERBIL_LOADPATH='/Users/guangtao/ghq/github.com/tao3k/poo-flow/core/.gerbil/lib:/Users/guangtao/.gerbil/lib')
 t=time.monotonic()
 with (out/(name+'.log')).open('w') as log:
  try:c=subprocess.run(args,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=15).returncode
  except subprocess.TimeoutExpired:c=124
 text=(out/(name+'.log')).read_text();rows.append(dict(name=name,args=args,exit=c,seconds=round(time.monotonic()-t,3),watchdogSeconds=15,completedOutput='CONTROL-COMPLETE' in text,sourceSha256=hashlib.sha256(script.read_bytes()).hexdigest()))
 (out/'native-exit-controls.json').write_text(json.dumps(rows,indent=2)+'\n');print(name,c,flush=True)
