from pathlib import Path
import subprocess,os,time,json,hashlib
out=Path(__file__).parent/'qualified-stable';out.mkdir(exist_ok=True);root=Path('.data/native-gerbil-exit-20261020').resolve();canary=Path('.data/native-gerbil-canary-20261020/canary.o1').resolve();binary=root/'bin/native-authoring'
checks={'scheme-object-contract','native-json-contract','native-negative-ceiling','native-boolean-ceiling','native-string-ceiling','native-null-ceiling','native-unknown-authority-field','native-changed-node','native-overflow-ceiling','native-empty-targets','native-duplicate-targets'}
rows=[]
for i in range(3):
 marker=(out/('cleanup-'+str(i)+'.txt')).resolve();assert not marker.exists()
 env=dict(os.environ,GERBIL_PATH=str(root/('run-env-'+str(i))),WEAVER_NATIVE_CANARY=str(canary),WEAVER_NATIVE_CANARY_LOG=str(marker));Path(env['GERBIL_PATH']).mkdir(exist_ok=True)
 args=[str(binary)];t=time.monotonic()
 with (out/('qualified-'+str(i)+'.log')).open('w') as log:
  p=subprocess.Popen(args,env=env,stdout=log,stderr=subprocess.STDOUT)
  try:c=p.wait(timeout=15)
  except subprocess.TimeoutExpired:c=124
 elapsed=time.monotonic()-t;text=(out/('qualified-'+str(i)+'.log')).read_text();observed={line[6:-5] for line in text.splitlines() if line.startswith('CHECK ') and line.endswith(' PASS')}
 cleanup=marker.read_text() if marker.exists() else ''
 ok=c==0 and elapsed<=15 and observed==checks and 'OBSERVATION duplicate-json-contract-accepted decoder-rejected' in text and 'NATIVE-MAIN-RETURN' in text and cleanup=='LU'
 rows.append(dict(args=args,pid=p.pid,exit=c,seconds=round(elapsed,3),budgetSeconds=15,forcedExit=False,checkNames=sorted(observed),cleanup=cleanup,qualified=ok,binarySha256=hashlib.sha256(binary.read_bytes()).hexdigest(),canarySha256=hashlib.sha256(canary.read_bytes()).hexdigest()))
 (out/'qualified-runs.json').write_text(json.dumps(rows,indent=2)+'\n');print('candidate',i,c,round(elapsed,3),repr(cleanup),ok,flush=True)
 if not ok:raise SystemExit(1)
print('PASS: three separate processes, unchanged workload plus dynamic cleanup canary; natural exits within original 15 seconds')

inputs=json.loads((out.parent/'native-inputs-before.json').read_text())
for name,expected in inputs['byteInputs'].items():assert hashlib.sha256(Path(name).read_bytes()).hexdigest()==expected,name
(out.parent/'native-inputs-after.json').write_text(json.dumps(dict(unchanged=True,byteInputs=inputs['byteInputs'],runs='qualified-stable/qualified-runs.json'),indent=2)+'\n')
print('PASS: all isolated native input bytes unchanged across the final qualification runs')
