#!/usr/bin/env python3
"""Bound each real official pipeline phase; no heartbeat or timeout extension."""
from pathlib import Path
import subprocess,selectors,os,time,json,hashlib,re
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'dev/proofs/evidence/llm-subject-authority'
source=ROOT/'dev/proofs/quint/LlmSubjectAuthority.qnt';tests=re.findall(r'^  run (\w+Test)=',source.read_text(),re.M);assert len(tests)==42
(OUT/'api-groups.json').write_text(json.dumps([tests[n:n+3] for n in range(0,len(tests),3)],indent=2)+'\n')
(OUT/'itf').mkdir(exist_ok=True)
args=['/opt/homebrew/opt/node/bin/node','dev/proofs/run_subject_authority.cjs'];inputs=[source,ROOT/'dev/proofs/run_subject_authority.cjs',ROOT/'dev/proofs/check_subject_api.py',OUT/'bundle/LlmSubjectAuthority.qnt']
hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
p=subprocess.Popen(args,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);selector=selectors.DefaultSelector();selector.register(p.stdout,selectors.EVENT_READ)
phase='startup';limit=20;started=time.monotonic();records=[];buffer=b'';phaseLog=None;timed=False
with (OUT/'api-all.log').open('wb') as whole:
 while True:
  if time.monotonic()-started>limit:
   p.kill();timed=True;records.append(dict(label=phase,exit=124,watchdogSeconds=limit,seconds=round(time.monotonic()-started,3)));break
  events=selector.select(.2)
  if not events:
   if p.poll() is not None:break
   continue
  chunk=os.read(p.stdout.fileno(),65536)
  if not chunk:break
  whole.write(chunk);whole.flush();buffer+=chunk
  while b'\n' in buffer:
   line,buffer=buffer.split(b'\n',1);s=line.decode(errors='replace')
   if s.startswith('@@START '):
    data=json.loads(s[8:]);assert phase in ['startup','idle'],phase
    phase=data['label'];limit=data['limit'];assert limit==(55 if phase=='api-typecheck' else 20)
    started=time.monotonic();phaseLog=(OUT/(phase+'.log')).open('w')
   if phaseLog:phaseLog.write(s+'\n');phaseLog.flush()
   if s.startswith('@@DONE '):
    data=json.loads(s[7:]);assert data['label']==phase
    records.append(dict(**data,exit=0,watchdogSeconds=limit,seconds=round(time.monotonic()-started,3)));phaseLog.close();phaseLog=None
    (OUT/'api-commands.json').write_text(json.dumps(records,indent=2)+'\n');print(phase,0,flush=True)
    phase='idle';limit=20;started=time.monotonic()
 if phaseLog:phaseLog.close()
code=p.wait(timeout=5)
if not timed and code and phase not in ['startup','idle']:records.append(dict(label=phase,exit=code,watchdogSeconds=limit,seconds=round(time.monotonic()-started,3)))
(OUT/'api-commands.json').write_text(json.dumps(records,indent=2)+'\n')
assert all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in hashes.items())
(OUT/'api-invocation.json').write_text(json.dumps(dict(args=args,exit=124 if timed else code,inputs=hashes,officialPipeline='load -> parse -> typecheck -> runTests; new Evaluator per group',expectedControls=42),indent=2)+'\n')
if timed or code:raise SystemExit(124 if timed else code)
assert len(records)==16 and all(r['exit']==0 for r in records)
assert sum(len(r.get('passed',[])) for r in records)==42
print('PASS: official full type/effect analysis; 42 controls; fresh evaluators; immutable typed IR',flush=True)
