from pathlib import Path
import json,hashlib,os,shutil,subprocess,time
root=Path.cwd();out=root/'proofs/evidence/llm-caller-custody'
records=json.loads((out/'commands.json').read_text());row=next(r for r in records if r['label']=='LlmCallerCustody');saved=out/'pre-join-strengthening';saved.mkdir(exist_ok=True)
(saved/'leaf-command.json').write_text(json.dumps(row,indent=2)+'\n');shutil.copyfile(out/'LlmCallerCustody.log',saved/'LlmCallerCustody.log')
for r in records:
 if r['label']=='LlmCallerCustody':continue
 for p,h in r['sourceSha256'].items():assert hashlib.sha256((root/p).read_bytes()).hexdigest()==h,(r['label'],p)
source='proofs/lean/LlmCallerCustody.lean';digest=hashlib.sha256((root/source).read_bytes()).hexdigest();started=time.monotonic();compiled=Path(row['args'][-2]).parent
with (out/'LlmCallerCustody-refresh.log').open('w') as log:
 try:code=subprocess.run(row['args'],cwd=root,env=dict(os.environ,LEAN_PATH=str(compiled)),stdout=log,stderr=subprocess.STDOUT,timeout=20).returncode
 except subprocess.TimeoutExpired:code=124
assert hashlib.sha256((root/source).read_bytes()).hexdigest()==digest
text=(out/'LlmCallerCustody-refresh.log').read_text();assert code==0,text
assert 'sorryAx' not in text and 'error:' not in text
assert sum(line.startswith("'Weaver.LlmCallerCustody.") for line in text.splitlines())==22
shutil.copyfile(out/'LlmCallerCustody-refresh.log',out/'LlmCallerCustody.log')
updated=dict(row,sourceSha256={source:digest},exit=code,seconds=round(time.monotonic()-started,3),watchdogSeconds=20,verificationMode='Leaf-only proof-statement strengthening; 29 ancestors and every Quint input hash unchanged')
records=[updated if r['label']=='LlmCallerCustody' else r for r in records]
(out/'commands.json').write_text(json.dumps(records,indent=2)+'\n')
print('PASS: stronger caller / current custody / actual source join / original outcome theorem; 22 declarations; unchanged dependency and Quint receipts retained')
