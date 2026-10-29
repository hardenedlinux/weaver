from pathlib import Path
import hashlib,json,subprocess
out=Path('proofs/evidence/llm-source-join');rows=json.loads((out/'working-source-check.json').read_text())
assert len(rows)==19 and sum(r['sameWorkingBytes'] for r in rows)==18
for r in rows:
 assert subprocess.check_output(['git','-C',r['repository'],'rev-parse','HEAD'],text=True).strip()==r['currentHead'],r['id']
 p=Path(r['repository'])/r['path']
 assert p.is_file() and hashlib.sha256(p.read_bytes()).hexdigest()==r['workingFileSha256'],r['id']
 if r['sameWorkingBytes']:assert r['workingFileSha256']==r['reviewedSha256']
 else:
  assert r['id']=='P17'
  baseline=subprocess.check_output(['git','-C',r['repository'],'show',r['pinnedRevision']+':'+r['path']],text=True)
  expected=baseline.replace(':poo-flow/modules/workflow/control-plane/runtime-protocol',':core/modules/funflow/control-plane/runtime-protocol').replace(':poo-flow/modules/workflow/control-plane/runtime-command-descriptor',':core/modules/funflow/control-plane/runtime-command-descriptor')
  assert expected==p.read_text()==(out/'P17-working-store-backend.ss').read_text()
print('PASS: 19 current working source hashes rechecked; 18 match baseline; P17 differs only in two control-plane import paths')
