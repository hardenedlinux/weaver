#!/usr/bin/env python3
"""Check independent enrollment authority and actual first-key/account composition."""
from pathlib import Path
import hashlib,json,os,re,subprocess,time,sys
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'dev/proofs/evidence/llm-subject-authority';PRIOR=ROOT/'dev/proofs/evidence/llm-enrollment-credential'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 records=[]
 def run(label,args,limit,env=None):
  start=time.monotonic();inputs={p:sha(ROOT/p) for p in args if p.endswith(('.py','.qnt','.lean','.cjs')) and (ROOT/p).is_file()}
  with (OUT/(label+'.log')).open('w') as log:
   try:code=subprocess.run(args,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=limit).returncode
   except subprocess.TimeoutExpired:code=124
  record=dict(label=label,args=args,sourceSha256=inputs,exit=code,seconds=round(time.monotonic()-start,3),watchdogSeconds=limit);records.append(record)
  (OUT/'commands.json').write_text(json.dumps(records,indent=2)+'\n');print(label,code,flush=True)
  assert all(sha(ROOT/p)==h for p,h in inputs.items())
  if code:raise SystemExit(code)
  return record
 for line in (PRIOR/'SHA256SUMS').read_text().splitlines():
  digest,name=line.split('  ',1);assert sha(ROOT/name)==digest,name
 ancestors=json.loads((PRIOR/'reused-lean-receipts.json').read_text())+[r for r in json.loads((PRIOR/'commands.json').read_text()) if r['label']=='LlmEnrollmentCredential'];assert len(ancestors)==34
 for r in ancestors:
  assert r['exit']==0
  for p,h in r['sourceSha256'].items():assert sha(ROOT/p)==h,(r['label'],p)
  assert Path(r['args'][-2]).is_file()
  log=next(p for p in (ROOT/'dev/proofs/evidence').glob('*/'+r['label']+'.log'));text=log.read_text();assert 'sorryAx' not in text and 'error:' not in text
 (OUT/'reused-lean-receipts.json').write_text(json.dumps(ancestors,indent=2)+'\n')
 compiled=Path(ancestors[-1]['args'][-2]).parent
 if '--reuse-current' in sys.argv:
  r=json.loads((OUT/'lean-command.json').read_text());assert r['exit']==0 and sha(Path(r['args'][-2]))==r['compiledSha256']
  for p,h in r['sourceSha256'].items():assert sha(ROOT/p)==h
  records.append(r)
 else:
  r=run('LlmSubjectAuthority',['elan','run','leanprover/lean4:v4.34.1','lean','-o',str(compiled/'LlmSubjectAuthority.olean'),'dev/proofs/lean/LlmSubjectAuthority.lean'],20,dict(os.environ,LEAN_PATH=str(compiled)))
  r['compiledSha256']=sha(compiled/'LlmSubjectAuthority.olean');(OUT/'lean-command.json').write_text(json.dumps(r,indent=2)+'\n')
 text=(OUT/'LlmSubjectAuthority.log').read_text();assert 'sorryAx' not in text and 'error:' not in text
 assert len(re.findall(r"^'Weaver.LlmSubjectAuthority\.",text,re.M))==33
 run('prepare-bundle',['python3','dev/proofs/prepare_subject_authority.py'],20)
 run('parse-raw-leaf',['/opt/homebrew/opt/node/bin/node',str((OUT/'parse-raw-leaf.cjs').relative_to(ROOT))],20)
 run('parse-bundle',['quint','parse',str((OUT/'bundle/LlmSubjectAuthority.qnt').relative_to(ROOT)),'--out',str((OUT/'bundle-parsed.json').relative_to(ROOT)),'--source-map',str((OUT/'bundle-source-map.json').relative_to(ROOT))],20)
 if '--reuse-current' not in sys.argv:run('official-api',['python3','dev/proofs/check_subject_api.py'],600)
 invocation=json.loads((OUT/'api-invocation.json').read_text());assert invocation['exit']==0 and invocation['expectedControls']==42
 for p,h in invocation['inputs'].items():assert sha(ROOT/p)==h,p
 api=json.loads((OUT/'api-commands.json').read_text());assert len(api)==16 and all(r['exit']==0 for r in api)
 assert sum(len(r.get('passed',[])) for r in api)==42
 assert all(r['typedIrUnchanged'] for r in api if r['label'].startswith('api-controls-'))
 run('verify-bundle',['python3',str((OUT/'check-bundle.py').relative_to(ROOT))],20)
 records.extend(dict(**r,currentOfficialInvocation=True) for r in api);(OUT/'commands.json').write_text(json.dumps(records,indent=2)+'\n')
 run('counterexamples',['python3',str((OUT/'check-counterexamples.py').relative_to(ROOT))],20)
 print('PASS: 33 compiled Lean declarations, 34 source-checked ancestors, 42 current official Quint controls; conditional model evidence')
if __name__=='__main__':main()
